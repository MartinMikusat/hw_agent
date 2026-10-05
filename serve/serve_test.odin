package serve

// Two clients on one daemon, scripted stream: A creates and prompts; B lists,
// attaches mid-run (snapshot has A's prompt, running=true), steers, and both
// see the steered turn live. A reads the whole run before B reads anything, so
// B's unread backlog must not stall A.

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import "core:thread"
import "core:time"

import "../agent"
import "../ai"

Gate :: struct {
	release: sync.Sema,
	calls:   int, // atomic
}

Stub_Stream :: struct {
	msg:  ai.Message,
	step: int,
}

stub_next :: proc(s: ^ai.Stream) -> (ai.Event, bool) {
	st := cast(^Stub_Stream)s.data
	st.step += 1
	switch st.step {
	case 1: return ai.Event{kind = .Text_Delta, text = st.msg.text, partial = &st.msg}, true
	case 2: return ai.Event{kind = .Done, reason = .Stop, partial = &st.msg}, true
	}
	return {}, false
}

stub_result :: proc(s: ^ai.Stream) -> ai.Message { return (cast(^Stub_Stream)s.data).msg }
stub_close :: proc(s: ^ai.Stream) {}

// First call waits for the test to release it; replies are "reply 1", "reply 2", …
stub_stream :: proc(model: ai.Model, ctx: ai.Context, api_key: string, cancel: ^ai.Cancellation, allocator: mem.Allocator) -> (ai.Stream, ai.Error) {
	g := cast(^Gate)model.data
	n := sync.atomic_add(&g.calls, 1) + 1
	if n == 1 { sync.sema_wait(&g.release) }
	st := new(Stub_Stream, allocator)
	// Padded past a socket buffer so a client that is not reading would stall a
	// blocking fan-out (each update and end event repeats the text).
	text := fmt.aprintf("reply %d %s", n, strings.repeat("x", 256 * 1024, allocator), allocator = allocator)
	st.msg = ai.Message{role = .Assistant, text = text, stop_reason = .Stop}
	return ai.Stream{data = st, next = stub_next, result = stub_result, close = stub_close}, nil
}

no_tools :: proc(allocator: mem.Allocator) -> []agent.Tool_Definition { return nil }

Client :: struct {
	fd:  posix.FD,
	buf: [dynamic]u8,
}

dial :: proc(path: string) -> Client {
	addr: posix.sockaddr_un
	addr.sun_family = .UNIX
	addr.sun_len = size_of(addr)
	copy(addr.sun_path[:], path)
	fd := posix.socket(.UNIX, .STREAM)
	assert(posix.connect(fd, cast(^posix.sockaddr)&addr, size_of(addr)) == .OK)
	tv := posix.timeval{tv_sec = 5}
	posix.setsockopt(fd, posix.SOL_SOCKET, .RCVTIMEO, &tv, size_of(tv))
	return Client{fd = fd, buf = make([dynamic]u8, context.temp_allocator)}
}

send_line :: proc(c: ^Client, line: string) {
	s := strings.concatenate({line, "\n"}, context.temp_allocator)
	posix.send(c.fd, raw_data(s), len(s), {})
}

// Next line whose "type" matches; fails the read (returns nil) on timeout.
expect_type :: proc(c: ^Client, type: string) -> json.Object {
	for {
		if nl := index_newline(c.buf[:]); nl >= 0 {
			line := strings.clone(string(c.buf[:nl]), context.temp_allocator)
			remove_range(&c.buf, 0, nl + 1)
			v, _ := json.parse_string(line, allocator = context.temp_allocator)
			obj := v.(json.Object) or_continue
			if t, _ := obj["type"].(json.String); string(t) == type { return obj }
			continue
		}
		chunk: [4096]u8
		n := posix.recv(c.fd, &chunk, len(chunk), {})
		if n <= 0 { return nil }
		append(&c.buf, ..chunk[:n])
	}
}

index_newline :: proc(b: []u8) -> int {
	for ch, i in b { if ch == '\n' { return i } }
	return -1
}

@(test)
test_two_clients_share_session :: proc(t: ^testing.T) {
	tmp := strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/")
	if len(tmp) == 0 { tmp = "/tmp" }
	root := fmt.aprintf("%s/hwa%d", tmp, time.to_unix_nanoseconds(time.now()) % 1e9, allocator = context.temp_allocator)
	defer os.remove_all(root)

	gate := new(Gate, runtime.heap_allocator())
	cfg := Config {
		socket_path   = fmt.aprintf("%s/s", root, allocator = context.temp_allocator),
		sessions_dir  = fmt.aprintf("%s/sessions", root, allocator = context.temp_allocator),
		default_model = "stub/model",
		make_tools    = no_tools,
		base          = {stream = stub_stream, model = {data = gate, context_window = 100_000}},
	}
	d, lerr := listen(cfg, runtime.heap_allocator())
	if !testing.expect_value(t, lerr, Listen_Error.None) { return }
	_, again := listen(cfg, runtime.heap_allocator())
	testing.expect_value(t, again, Listen_Error.Already_Running)
	acceptor := thread.create_and_start_with_data(d, proc(p: rawptr) { run(cast(^Daemon)p) })
	defer {
		shutdown(d)
		thread.join(acceptor)
		thread.destroy(acceptor)
	}

	a := dial(cfg.socket_path)
	defer posix.close(a.fd)
	send_line(&a, `{"cmd":"create","req":7}`)
	created := expect_type(&a, "created")
	if !testing.expect(t, created != nil) { return }
	testing.expect_value(t, created["req"].(json.Float), 7)
	id := string(created["session"].(json.String))
	testing.expect_value(t, string(created["model"].(json.String)), "stub/model")

	send_line(&a, fmt.tprintf(`{{"cmd":"prompt","session":"%s","text":"hello"}}`, id))
	testing.expect(t, expect_type(&a, "agent_start") != nil)

	b := dial(cfg.socket_path)
	defer posix.close(b.fd)
	send_line(&b, `{"cmd":"list"}`)
	list := expect_type(&b, "sessions")
	sessions := list["sessions"].(json.Array)
	testing.expect_value(t, len(sessions), 1)
	testing.expect_value(t, string(sessions[0].(json.Object)["id"].(json.String)), id)

	send_line(&b, fmt.tprintf(`{{"cmd":"attach","session":"%s"}}`, id))
	snap := expect_type(&b, "snapshot")
	testing.expect_value(t, snap["running"].(json.Boolean), true)
	msgs := snap["messages"].(json.Array)
	testing.expect_value(t, len(msgs), 1)
	testing.expect_value(t, string(msgs[0].(json.Object)["text"].(json.String)), "hello")

	send_line(&b, fmt.tprintf(`{{"cmd":"prompt","session":"%s","text":"mid-run"}}`, id))
	time.sleep(50 * time.Millisecond) // let B's reader queue the steer before the turn ends
	testing.expect(t, !close_if_idle(d), "an update must not interrupt a running session")
	sync.sema_post(&gate.release)

	for c in ([]^Client{&a, &b}) {
		texts := make([dynamic]string, context.temp_allocator)
		for len(texts) < 3 {
			end := expect_type(c, "message_end")
			if !testing.expect(t, end != nil) { return }
			testing.expect_value(t, string(end["session"].(json.String)), id)
			append(&texts, string(end["text"].(json.String)))
		}
		testing.expect(t, strings.has_prefix(texts[0], "reply 1 "))
		testing.expect_value(t, texts[1], "mid-run")
		testing.expect(t, strings.has_prefix(texts[2], "reply 2 "))
	}

	expect_type(&a, "ready")
	testing.expect(t, close_if_idle(d))
	send_line(&a, `{"cmd":"create"}`)
	refused := expect_type(&a, "error")
	testing.expect(t, refused != nil && strings.contains(string(refused["text"].(json.String)), "restarting"))
	reopen(d)

	send_line(&a, fmt.tprintf(`{{"cmd":"delete","session":"%s"}}`, id))
	testing.expect(t, expect_type(&b, "deleted") != nil, "attached clients learn the session is gone")
	testing.expect(t, expect_type(&a, "deleted") != nil)
	testing.expect(t, !os.exists(fmt.tprintf("%s/%s.jsonl", cfg.sessions_dir, id)))
	send_line(&b, fmt.tprintf(`{{"cmd":"attach","session":"%s"}}`, id))
	testing.expect_value(t, string(expect_type(&b, "error")["text"].(json.String)), "no such session")

	send_line(&b, `{"cmd":"attach","session":"../../etc"}`)
	bad := expect_type(&b, "error")
	testing.expect_value(t, string(bad["text"].(json.String)), "invalid session id")
}
