// serve — shared background daemon on a Unix domain socket. Every connection
// speaks JSONL and sees every session; each live session runs the stdio RPC
// loop (rpc.Server + rpc.run_loop) on its own thread and fans its events out
// to the connections attached to it.
//
//   in:  {"cmd":"list"}                          → {"type":"sessions","sessions":[...]}
//        {"cmd":"create","model"?:"...","cwd"?:"/abs/dir"}
//                                                → {"type":"created","session":id,"model","cwd",
//                                                  "instructions":[paths loaded into the prompt]} (attaches)
//        {"cmd":"attach","session":id}           → {"type":"snapshot","session":id,"running":bool,"messages":[...]}
//                                                  then live events
//        {"cmd":"detach","session":id}
//        {"cmd":"delete","session":id}           → {"type":"deleted","session":id} to the caller
//                                                  and every attached client; refused while running
//        {"cmd":"prompt"|"steer"|"follow_up"|"abort","session":id,"text"?:"..."}
//                                                  stdio RPC semantics per session
//   out: every stdio RPC event plus "session":id; failures are
//        {"type":"error","session"?:id,"text":"..."}. Any command may carry
//        "req", echoed on its direct reply.
//
// A session's mutex orders "persist + fan-out" against attach's file replay,
// so an attaching client sees each message exactly once: in the snapshot or
// live. Socket mode 0600 in a 0700 directory is the access control.
//
// Each connection has an outbound queue drained by its own writer thread, so a
// client that stops reading never stalls a session's fan-out; one that falls
// MAX_OUTBOUND_BYTES behind is disconnected.
//
// ponytail: live sessions stay resident; add eviction when session counts grow.
#+feature dynamic-literals
package serve

import "base:runtime"
import "core:crypto"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sync/chan"
import "core:sys/posix"
import "core:thread"
import devlog "devlog:."

import "../agent"
import "../ai"
import "../instructions"
import "../rpc"
import "../session"

Config :: struct {
	socket_path:   string,
	sessions_dir:  string,
	traces_dir:    string, // per-session raw provider traces; "" when tracing is off
	default_model: string,
	default_cwd:   string, // for sessions created without one and logs that predate cwd
	home:          string, // for the global instruction file
	system_prompt: string,
	base:          agent.Loop_Config, // per-session copy; model.id is replaced
	make_tools:    proc(allocator: mem.Allocator, cwd: string) -> []agent.Tool_Definition,
}

Daemon :: struct {
	cfg:       Config,
	listen_fd: posix.FD,
	mu:        sync.Mutex,
	sessions:  map[string]^Live_Session,
	closing:   bool, // under mu: refusing new work while an update installs
	allocator: mem.Allocator, // thread-safe; owns everything the daemon keeps
}

Conn :: struct {
	fd:        posix.FD,
	allocator: mem.Allocator,
	writer:    ^thread.Thread,
	mu:        sync.Mutex,
	cond:      sync.Cond,
	queue:     [dynamic][]u8, // owned line copies, under mu
	queued:    int,           // bytes in queue, under mu
	dead:      bool,          // under mu: send failed or client fell too far behind
	closed:    bool,          // under mu: reader finished; writer drops the rest and exits
}

// Message updates repeat the whole text so far, so a stalled client's backlog grows
// fast; past this it is dropped rather than buffered without bound.
MAX_OUTBOUND_BYTES :: 16 * 1024 * 1024

Live_Session :: struct {
	id:      string,
	path:    string,
	cwd:     string,
	instructions: []string, // paths of the instruction files in the prompt
	ctx:     agent.Context,
	cfg:     agent.Loop_Config,
	cancel:  ai.Cancellation,
	srv:     rpc.Server,
	sess:    ^session.Session,
	persist: session.Emit_Session,
	sink:    rpc.Line_Sink,
	mu:      sync.Recursive_Mutex,
	subs:    [dynamic]^Conn,
}

Listen_Error :: enum {
	None,
	Path_Too_Long,
	Already_Running,
	Directory,
	Socket,
}

ID_BYTES :: 8

// listen binds the socket, replacing a stale one left by a dead daemon.
listen :: proc(cfg: Config, allocator: mem.Allocator) -> (^Daemon, Listen_Error) {
	addr: posix.sockaddr_un
	if len(cfg.socket_path) >= len(addr.sun_path) { return nil, .Path_Too_Long }
	addr.sun_family = .UNIX
	addr.sun_len = size_of(addr)
	copy(addr.sun_path[:], cfg.socket_path)

	for dir in ([]string{dir_of(cfg.socket_path), cfg.sessions_dir}) {
		if os.make_directory_all(dir, os.perm(0o700)) != nil && !os.is_dir(dir) {
			return nil, .Directory
		}
	}
	if os.exists(cfg.socket_path) {
		probe := posix.socket(.UNIX, .STREAM)
		live := posix.connect(probe, cast(^posix.sockaddr)&addr, size_of(addr)) == .OK
		posix.close(probe)
		if live { return nil, .Already_Running }
		os.remove(cfg.socket_path)
	}

	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 { return nil, .Socket }
	cpath := strings.clone_to_cstring(cfg.socket_path, context.temp_allocator)
	old_mask := posix.umask({.IRGRP, .IWGRP, .IXGRP, .IROTH, .IWOTH, .IXOTH})
	bound := posix.bind(fd, cast(^posix.sockaddr)&addr, size_of(addr)) == .OK
	posix.umask(old_mask)
	if !bound || posix.chmod(cpath, {.IRUSR, .IWUSR}) != .OK || posix.listen(fd, 16) != .OK {
		posix.close(fd)
		return nil, .Socket
	}

	d := new(Daemon, allocator)
	d.cfg = cfg
	d.listen_fd = fd
	d.allocator = allocator
	d.sessions = make(map[string]^Live_Session, allocator)
	return d, .None
}

// run accepts connections until the listening socket is closed.
run :: proc(d: ^Daemon) {
	posix.signal(.SIGPIPE, auto_cast posix.SIG_IGN) // dead clients surface as send errors
	for {
		fd := posix.accept(d.listen_fd, nil, nil)
		if fd < 0 {
			if posix.errno() == .EINTR { continue }
			return
		}
		c := new(Conn, d.allocator)
		c.fd = fd
		c.allocator = d.allocator
		c.queue = make([dynamic][]u8, 0, 64, d.allocator)
		c.writer = thread.create_and_start_with_data(c, conn_writer)
		args := new(Conn_Args, d.allocator)
		args^ = {d, c}
		thread.create_and_start_with_data(args, conn_main, self_cleanup = true)
	}
}

// close_if_idle starts refusing new work when no session is running or has a
// prompt queued, so the caller can replace the executable and exit. reopen undoes it.
close_if_idle :: proc(d: ^Daemon) -> bool {
	sync.mutex_lock(&d.mu)
	defer sync.mutex_unlock(&d.mu)
	for _, ls in d.sessions {
		if sync.atomic_load(&ls.srv.running) || chan.len(ls.srv.prompt_ch) > 0 { return false }
	}
	d.closing = true
	return true
}

reopen :: proc(d: ^Daemon) {
	sync.mutex_lock(&d.mu)
	defer sync.mutex_unlock(&d.mu)
	d.closing = false
}

@(private)
is_closing :: proc(d: ^Daemon) -> bool {
	sync.mutex_lock(&d.mu)
	defer sync.mutex_unlock(&d.mu)
	return d.closing
}

// shutdown stops accepting; live sessions and connections end with the process.
shutdown :: proc(d: ^Daemon) {
	posix.shutdown(d.listen_fd, .RDWR)
	posix.close(d.listen_fd)
	os.remove(d.cfg.socket_path)
}

@(private)
Conn_Args :: struct {
	d: ^Daemon,
	c: ^Conn,
}

@(private)
conn_main :: proc(data: rawptr) {
	args := cast(^Conn_Args)data
	d, c := args.d, args.c
	free(args, d.allocator)

	arena: virtual.Arena
	scratch := virtual.arena_allocator(&arena)
	defer virtual.arena_destroy(&arena)
	pending := make([dynamic]u8, 0, 4096, d.allocator)
	defer delete(pending)
	chunk: [16 * 1024]u8
	for {
		n := posix.recv(c.fd, &chunk, len(chunk), {})
		if n <= 0 {
			if n < 0 && posix.errno() == .EINTR { continue }
			break
		}
		append(&pending, ..chunk[:n])
		start := 0
		for i in 0 ..< len(pending) {
			if pending[i] != '\n' { continue }
			line := strings.trim_space(string(pending[start:i]))
			start = i + 1
			if len(line) == 0 { continue }
			v, jerr := json.parse_string(line, allocator = scratch)
			if jerr != nil {
				reply_error(c, nil, "", fmt.tprintf("bad json: %v", jerr))
			} else {
				handle(d, c, v)
			}
			free_all(scratch)
		}
		remove_range(&pending, 0, start)
	}

	if sync.mutex_guard(&d.mu) {
		for _, ls in d.sessions {
			unsubscribe(ls, c)
		}
	}
	sync.mutex_lock(&c.mu)
	c.closed = true
	sync.cond_signal(&c.cond)
	sync.mutex_unlock(&c.mu)
	thread.join(c.writer)
	thread.destroy(c.writer)
	posix.close(c.fd)
	delete(c.queue)
	free(c, d.allocator)
}

@(private)
conn_writer :: proc(data: rawptr) {
	c := cast(^Conn)data
	batch := make([dynamic][]u8, 0, 64, c.allocator)
	defer delete(batch)
	for {
		sync.mutex_lock(&c.mu)
		for len(c.queue) == 0 && !c.closed {
			sync.cond_wait(&c.cond, &c.mu)
		}
		batch, c.queue = c.queue, batch
		c.queued = 0
		skip := c.dead || c.closed
		finished := c.closed
		sync.mutex_unlock(&c.mu)
		for line in batch {
			if !skip && !send_all(c.fd, line) {
				skip = true
				sync.mutex_lock(&c.mu)
				c.dead = true
				sync.mutex_unlock(&c.mu)
				posix.shutdown(c.fd, .RDWR) // wakes the reader so it unsubscribes
			}
			delete(line, c.allocator)
		}
		clear(&batch)
		if finished { return }
	}
}

@(private)
send_all :: proc(fd: posix.FD, line: []u8) -> bool {
	rest := line
	for len(rest) > 0 {
		n := posix.send(fd, raw_data(rest), len(rest), {})
		if n < 0 {
			if posix.errno() == .EINTR { continue }
			return false
		}
		rest = rest[n:]
	}
	return true
}

@(private)
handle :: proc(d: ^Daemon, c: ^Conn, v: json.Value) {
	obj, is_obj := v.(json.Object)
	if !is_obj {
		reply_error(c, nil, "", "command must be an object")
		return
	}
	req := obj["req"]
	cmd, _ := obj["cmd"].(json.String)
	id, _ := obj["session"].(json.String)
	switch cmd {
	case "create", "prompt", "steer", "follow_up":
		if is_closing(d) {
			reply_error(c, req, string(id), "hw_agent is restarting to install an update; retry shortly")
			return
		}
	}
	switch cmd {
	case "list":
		reply_list(d, c, req)
	case "create":
		model, _ := obj["model"].(json.String)
		if len(model) == 0 { model = json.String(d.cfg.default_model) }
		cwd, _ := obj["cwd"].(json.String)
		if len(cwd) == 0 { cwd = json.String(d.cfg.default_cwd) }
		if !strings.has_prefix(string(cwd), "/") || !os.is_dir(string(cwd)) {
			reply_error(c, req, "", "cwd must be an existing absolute directory")
			return
		}
		ls, err := create_session(d, string(model), string(cwd))
		if err != "" {
			reply_error(c, req, "", err)
			return
		}
		sync.recursive_mutex_lock(&ls.mu)
		append(&ls.subs, c)
		loaded := make(json.Array, 0, len(ls.instructions), context.temp_allocator)
		for p in ls.instructions { append(&loaded, json.Value(p)) }
		reply(c, req, "created", map[string]json.Value{"session" = ls.id, "model" = ls.cfg.model.id, "cwd" = ls.cwd, "instructions" = loaded})
		sync.recursive_mutex_unlock(&ls.mu)
	case "attach":
		ls, err := live(d, string(id))
		if err != "" {
			reply_error(c, req, string(id), err)
			return
		}
		attach(ls, c, req)
	case "detach":
		ls, err := live(d, string(id))
		if err != "" {
			reply_error(c, req, string(id), err)
			return
		}
		unsubscribe(ls, c)
	case "prompt", "steer", "follow_up", "abort":
		ls, err := live(d, string(id))
		if err != "" {
			reply_error(c, req, string(id), err)
			return
		}
		rpc.handle_command(&ls.srv, v)
	case "delete":
		if err := delete_session(d, string(id), c); err != "" {
			reply_error(c, req, string(id), err)
			return
		}
		reply(c, req, "deleted", map[string]json.Value{"session" = strings.clone(string(id), context.temp_allocator)})
	case "quit":
		reply_error(c, req, "", "quit is stdio-only; stop the daemon with launchctl")
	case:
		reply_error(c, req, string(id), fmt.tprintf("unknown cmd %q", cmd))
	}
}

// live returns the resident session, loading it from disk on first use.
@(private)
live :: proc(d: ^Daemon, id: string) -> (^Live_Session, string) {
	if !valid_id(id) { return nil, "invalid session id" }
	sync.mutex_lock(&d.mu)
	defer sync.mutex_unlock(&d.mu)
	if ls, ok := d.sessions[id]; ok { return ls, "" }
	path := session_path(d, id, context.temp_allocator)
	if !os.exists(path) { return nil, "no such session" }
	return start_session(d, id, path, "", "")
}

// delete_session removes a session's log and traces. A live session is stopped
// first and its subscribers are told; a running one is refused.
//
// ponytail: a deleted live session's memory is not reclaimed (its loop thread
// may still be returning); bounded by deletes per daemon lifetime.
@(private)
delete_session :: proc(d: ^Daemon, id: string, caller: ^Conn) -> string {
	if !valid_id(id) { return "invalid session id" }
	sync.mutex_lock(&d.mu)
	defer sync.mutex_unlock(&d.mu)
	path := session_path(d, id, context.temp_allocator)
	ls, live := d.sessions[id]
	if live {
		if sync.atomic_load(&ls.srv.running) || chan.len(ls.srv.prompt_ch) > 0 {
			return "session is running; abort it first"
		}
	} else if !os.exists(path) {
		return "no such session"
	}
	if err := os.remove(path); err != nil {
		devlog.failed(devlog.global(), {feature = "session", operation = "delete"}, {reason = "session log could not be removed", detail = id})
		return "session log could not be removed"
	}
	if len(d.cfg.traces_dir) > 0 {
		os.remove_all(fmt.tprintf("%s/%s", d.cfg.traces_dir, id))
	}
	if live {
		chan.close(ls.srv.prompt_ch) // run_loop returns
		session.close(ls.sess)
		delete_key(&d.sessions, id)
		sync.recursive_mutex_lock(&ls.mu)
		unsubscribe(ls, caller) // the caller gets the direct reply instead
		rpc.emit_line(&ls.sink, "deleted", nil)
		clear(&ls.subs)
		sync.recursive_mutex_unlock(&ls.mu)
	}
	return ""
}

@(private)
create_session :: proc(d: ^Daemon, model, cwd: string) -> (^Live_Session, string) {
	raw: [ID_BYTES]u8
	crypto.rand_bytes(raw[:])
	id := string(hex.encode(raw[:], context.temp_allocator))
	sync.mutex_lock(&d.mu)
	defer sync.mutex_unlock(&d.mu)
	return start_session(d, id, session_path(d, id, context.temp_allocator), model, cwd)
}

// start_session opens the log and launches the session's loop thread. A
// non-empty new_model creates the log with that model. Caller holds d.mu.
@(private)
start_session :: proc(d: ^Daemon, id, path, new_model, new_cwd: string) -> (^Live_Session, string) {
	a := d.allocator
	sess, messages, err := session.open(path, a)
	if err != nil { return nil, fmt.tprintf("session open failed: %v", err) } // recorded by session.open
	if len(new_model) > 0 {
		if herr := session.append_header(sess, new_model, new_cwd); herr != nil {
			devlog.failed(devlog.global(), {feature = "session", operation = "create"}, {reason = "session header could not be written"})
			session.close(sess)
			return nil, fmt.tprintf("session create failed: %v", herr)
		}
	}

	ls := new(Live_Session, a)
	ls.id = strings.clone(id, a)
	ls.path = strings.clone(path, a)
	ls.sess = sess
	ls.subs = make([dynamic]^Conn, 0, 4, a)
	ls.cwd = len(sess.cwd) > 0 ? sess.cwd : strings.clone(d.cfg.default_cwd, a)
	sources := instructions.load(ls.cwd, d.cfg.home, a)
	ls.instructions = instructions.paths(sources, a)
	ls.ctx.system_prompt = instructions.render(d.cfg.system_prompt, sources, a)
	ls.ctx.tools = d.cfg.make_tools(a, ls.cwd)
	ls.ctx.messages = make([dynamic]agent.Agent_Message, 0, len(messages) + 16, a)
	append(&ls.ctx.messages, ..messages)
	ls.cfg = d.cfg.base
	ls.cfg.model.id = len(sess.model) > 0 ? sess.model : d.cfg.default_model
	if len(d.cfg.traces_dir) > 0 {
		ls.cfg.model.provider_options.trace_dir = fmt.aprintf("%s/%s", d.cfg.traces_dir, ls.id, allocator = a)
	}
	ls.sink = {write = fan_out, userdata = ls, session = ls.id}
	rpc.init_server(&ls.srv, &ls.cfg, &ls.cancel, &ls.sink, a)
	ls.srv.ctx = &ls.ctx
	ls.persist = {session = sess, inner = rpc.emit_json, inner_userdata = &ls.sink}
	d.sessions[ls.id] = ls
	thread.create_and_start_with_data(ls, session_main, self_cleanup = true)
	return ls, ""
}

@(private)
session_main :: proc(data: rawptr) {
	ls := cast(^Live_Session)data
	rpc.run_loop(&ls.srv, session_emit, ls)
}

// Persist and fan out as one step so attach's replay can't interleave.
@(private)
session_emit :: proc(event: agent.Event, userdata: rawptr) {
	ls := cast(^Live_Session)userdata
	sync.recursive_mutex_lock(&ls.mu)
	defer sync.recursive_mutex_unlock(&ls.mu)
	session.emit(event, &ls.persist)
}

@(private)
fan_out :: proc(line: []u8, userdata: rawptr) {
	ls := cast(^Live_Session)userdata
	sync.recursive_mutex_lock(&ls.mu)
	defer sync.recursive_mutex_unlock(&ls.mu)
	for c in ls.subs {
		conn_write(c, line)
	}
}

@(private)
attach :: proc(ls: ^Live_Session, c: ^Conn, req: json.Value) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	sync.recursive_mutex_lock(&ls.mu)
	defer sync.recursive_mutex_unlock(&ls.mu)
	messages, _, err := session.replay(ls.path, context.temp_allocator)
	if err != nil {
		reply_error(c, req, ls.id, fmt.tprintf("session replay failed: %v", err))
		return
	}
	if !subscribed(ls, c) {
		append(&ls.subs, c)
	}
	Snapshot :: struct {
		type:     string,
		session:  string,
		model:    string,
		cwd:      string,
		instructions: []string,
		running:  bool,
		messages: []agent.Agent_Message,
		req:      json.Value `json:"req,omitempty"`,
	}
	data, _ := json.marshal(Snapshot {
		type = "snapshot",
		session = ls.id,
		model = ls.cfg.model.id,
		cwd = ls.cwd,
		instructions = ls.instructions,
		running = sync.atomic_load(&ls.srv.running),
		messages = messages,
		req = req,
	}, {}, context.temp_allocator)
	write_encoded(c, data)
}

@(private)
subscribed :: proc(ls: ^Live_Session, c: ^Conn) -> bool {
	for s in ls.subs {
		if s == c { return true }
	}
	return false
}

@(private)
unsubscribe :: proc(ls: ^Live_Session, c: ^Conn) {
	sync.recursive_mutex_lock(&ls.mu)
	defer sync.recursive_mutex_unlock(&ls.mu)
	for s, i in ls.subs {
		if s == c {
			unordered_remove(&ls.subs, i)
			return
		}
	}
}

@(private)
reply_list :: proc(d: ^Daemon, c: ^Conn, req: json.Value) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	Entry :: struct {
		id:      string,
		model:   string,
		cwd:     string,
		running: bool,
		updated: i64, // unix seconds of the last log write
	}
	entries := make([dynamic]Entry, 0, 16, context.temp_allocator)
	files, _ := os.read_all_directory_by_path(d.cfg.sessions_dir, context.temp_allocator)
	sync.mutex_lock(&d.mu)
	for f in files {
		id := strings.trim_suffix(f.name, ".jsonl")
		if id == f.name || !valid_id(id) { continue }
		e := Entry{id = id, updated = f.modification_time._nsec / 1e9}
		if ls, ok := d.sessions[id]; ok {
			e.model = ls.cfg.model.id
			e.cwd = ls.cwd
			e.running = sync.atomic_load(&ls.srv.running)
		} else {
			e.model, e.cwd = header_of(f.fullpath)
		}
		append(&entries, e)
	}
	sync.mutex_unlock(&d.mu)
	Sessions :: struct {
		type:     string,
		sessions: []Entry,
		req:      json.Value `json:"req,omitempty"`,
	}
	data, _ := json.marshal(Sessions{type = "sessions", sessions = entries[:], req = req}, {}, context.temp_allocator)
	write_encoded(c, data)
}

// Model and cwd from a log's first line; "" for logs without a header.
@(private)
header_of :: proc(path: string) -> (model, cwd: string) {
	f, err := os.open(path)
	if err != nil { return }
	defer os.close(f)
	buf: [4096]u8
	n, _ := os.read(f, buf[:])
	line := string(buf[:n])
	if nl := strings.index_byte(line, '\n'); nl >= 0 { line = line[:nl] }
	entry: session.Entry
	if json.unmarshal_string(line, &entry, allocator = context.temp_allocator) != nil || entry.kind != .Header { return }
	return entry.model, entry.cwd
}

@(private)
reply :: proc(c: ^Conn, req: json.Value, type: string, fields: map[string]json.Value) {
	fields := fields
	if req != nil {
		if fields == nil { fields = make(map[string]json.Value) }
		fields["req"] = req
	}
	sink := rpc.Line_Sink{write = conn_write_proc, userdata = c}
	rpc.emit_line(&sink, type, fields)
}

@(private)
reply_error :: proc(c: ^Conn, req: json.Value, id, text: string) {
	fields := map[string]json.Value{"text" = text}
	if len(id) > 0 { fields["session"] = id }
	reply(c, req, "error", fields)
}

@(private)
write_encoded :: proc(c: ^Conn, data: []u8) {
	sink := rpc.Line_Sink{write = conn_write_proc, userdata = c}
	rpc.write_line(&sink, data)
}

@(private)
conn_write_proc :: proc(line: []u8, userdata: rawptr) {
	conn_write(cast(^Conn)userdata, line)
}

// conn_write queues one line for the connection's writer and never blocks on
// the client.
@(private)
conn_write :: proc(c: ^Conn, line: []u8) {
	sync.mutex_lock(&c.mu)
	defer sync.mutex_unlock(&c.mu)
	if c.dead || c.closed { return }
	if c.queued + len(line) > MAX_OUTBOUND_BYTES {
		devlog.failed(devlog.global(), {feature = "daemon", operation = "send"}, {reason = "client fell too far behind and was disconnected", severity = .Warning})
		c.dead = true
		posix.shutdown(c.fd, .RDWR)
		sync.cond_signal(&c.cond)
		return
	}
	copy_line := make([]u8, len(line), c.allocator)
	copy(copy_line, line)
	append(&c.queue, copy_line)
	c.queued += len(line)
	sync.cond_signal(&c.cond)
}

valid_id :: proc(id: string) -> bool {
	if len(id) != ID_BYTES * 2 { return false }
	for ch in transmute([]u8)id {
		if !(ch >= '0' && ch <= '9' || ch >= 'a' && ch <= 'f') { return false }
	}
	return true
}

@(private)
session_path :: proc(d: ^Daemon, id: string, allocator: mem.Allocator) -> string {
	return fmt.aprintf("%s/%s.jsonl", d.cfg.sessions_dir, id, allocator = allocator)
}

@(private)
dir_of :: proc(path: string) -> string {
	i := strings.last_index_byte(path, '/')
	return i > 0 ? path[:i] : "."
}
