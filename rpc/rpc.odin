// rpc — JSONL stdio front-end. One JSON object per line in, one event per line
// out. Lets a parent process (hw_launcher, tests, scripts) drive the harness.
//
//   in:  {"cmd":"prompt","text":"..."}     start a run (mid-run: steers)
//        {"cmd":"steer","text":"..."}      inject before next generation
//        {"cmd":"follow_up","text":"..."}  run after the agent settles
//        {"cmd":"abort"}                   cancel the in-flight run
//        {"cmd":"permission","id":"p1","decision":"allow|allow_session|deny","text"?:"reason"}
//                                          answer a permission_request
//        {"cmd":"quit"}                    exit after current run settles
//
//   out: {"type":"ready"}
//        {"type":"prompt","text":"..."}
//        {"type":"agent_start"} / {"type":"agent_end"}
//        {"type":"turn_start"}   / {"type":"turn_end"}
//        {"type":"message_start","role":"..."}
//        {"type":"message_update","role":"...","text":"...","thinking":"..."}
//        {"type":"message_end","role":"...","text":"..."}
//        {"type":"tool_start","id":"...","name":"...","arguments":"..."}
//        {"type":"tool_end","id":"...","name":"...","text":"...","is_error":bool}
//        {"type":"compaction","summary":"...","tokens_before":int}
//        {"type":"permission_request","id":"p1","tool":"...","target":"...","arguments":"...","rule":"..."}
//                                          a tool call needs approval; the run waits
//        {"type":"permission_resolved","id":"p1","decision":"allow|allow_session|deny|timeout|aborted"}
//        {"type":"error","text":"..."}
//
// Architecture: a reader thread parses stdin into queues; the main thread runs
// agent.run and drains the queues through Loop_Config hooks — no shared state
// with the model path beyond mutexed queues + the atomic cancel flag. All
// stdout writes happen on the loop thread, so events are ordered.
//
// Server + run_loop + emit_json are transport-neutral: the socket daemon
// (serve/) drives one Server per session and routes lines through a Line_Sink.
//
// ponytail: no set_model / get_state / fork commands yet — the seams exist
// (cfg.model swap, ctx.messages dump) but aren't needed until a real client
// asks. Commands are trusted-local IPC so lines aren't length-capped.
#+feature dynamic-literals
package rpc

import "core:bufio"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "base:runtime"
import "core:strings"
import "core:sync"
import "core:sync/chan"
import "core:thread"
import "core:time"
import "../agent"
import "../ai"
import "../permissions"

Server :: struct {
	ctx:       ^agent.Context,
	cfg:       ^agent.Loop_Config,
	cancel:    ^ai.Cancellation,
	prompt_ch: chan.Chan(string),
	steer_q:   [dynamic]agent.Agent_Message,
	follow_q:  [dynamic]agent.Agent_Message,
	mu:        sync.Mutex,
	running:   bool, // atomic
	quitting:  bool, // atomic
	sink:      ^Line_Sink, // nil = stdout
	allocator: mem.Allocator,
	owner:     rawptr, // for the transport that embeds this server

	gate:        ^permissions.Gate, // nil: every tool call is allowed
	approval:    Approval,
	ask_timeout: time.Duration,      // 0 = PERMISSION_TIMEOUT
}

PERMISSION_TIMEOUT :: 5 * time.Minute

Decision_Kind :: enum {
	Deny,
	Allow,
	Allow_Session,
}

// Approval is the one permission request a run can have open: tool calls are
// checked in order on the loop thread, which waits for the answer.
Approval :: struct {
	mu:       sync.Mutex,
	cond:     sync.Cond,
	counter:  int,
	active:   bool,
	id:       string, // strings below are owned by Server.allocator
	tool:     string,
	target:   string,
	arguments: string,
	rule:     string,
	answered: bool,
	decision: Decision_Kind,
	reason:   string,
}

// Where JSONL lines go. session != "" adds a "session" field to every line.
Line_Sink :: struct {
	write:    proc(line: []u8, userdata: rawptr),
	userdata: rawptr,
	session:  string,
	// listening reports whether anyone can answer a permission request; nil
	// means yes (stdout has a reader).
	listening: proc(userdata: rawptr) -> bool,
}

// Queues + cancel for one agent context; cfg's steering/follow-up hooks and
// userdata now belong to it. allocator must be thread-safe: command threads
// clone text into it.
init_server :: proc(srv: ^Server, cfg: ^agent.Loop_Config, cancel: ^ai.Cancellation, sink: ^Line_Sink, allocator: mem.Allocator) {
	srv.cfg = cfg
	srv.cancel = cancel
	srv.sink = sink
	srv.allocator = allocator
	ch, cerr := chan.create_buffered(chan.Chan(string), 8, allocator)
	assert(cerr == nil)
	srv.prompt_ch = ch
	srv.steer_q = make([dynamic]agent.Agent_Message, 0, 8, allocator)
	srv.follow_q = make([dynamic]agent.Agent_Message, 0, 8, allocator)
	cfg.get_steering = drain_steering
	cfg.get_follow_up = drain_follow_up
	cfg.userdata = srv
}

// serve runs until stdin closes or {"cmd":"quit"} arrives. Takes ownership of
// cfg's steering/follow-up hooks and userdata.
serve :: proc(
	ctx: ^agent.Context,
	cfg: ^agent.Loop_Config,
	emit: agent.Emit,
	emit_userdata: rawptr,
	cancel: ^ai.Cancellation,
	gate: ^permissions.Gate,
	allocator: mem.Allocator,
) {
	srv := new(Server, allocator)
	srv.ctx = ctx
	init_server(srv, cfg, cancel, nil, allocator)
	set_permissions(srv, gate)

	// No join: serve returning means process exit, and a blocking stdin read
	// can't be interrupted — joining here would hang a quit-with-open-stdin.
	thread.create_and_start_with_data(srv, reader_main)

	run_loop(srv, emit, emit_userdata)
}

// run_loop runs prompts until prompt_ch closes or quit is requested.
run_loop :: proc(srv: ^Server, emit: agent.Emit, emit_userdata: rawptr) {
	emit_line(srv.sink, "ready", nil)
	for {
		text, ok := chan.recv(srv.prompt_ch)
		if !ok { break }
		// "" is quit's wakeup sentinel — prompts queued before it still run
		if len(text) == 0 {
			if sync.atomic_load(&srv.quitting) { break }
			continue
		}
		emit_line(srv.sink, "prompt", map[string]json.Value{"text" = text})
		sync.atomic_store(&srv.running, true)
		sync.atomic_store(&srv.cancel.flag, false) // clear a stale abort
		err := agent.run(srv.ctx, srv.cfg, []agent.Agent_Message{{role = .User, text = text}}, emit, emit_userdata, srv.cancel, srv.allocator)
		sync.atomic_store(&srv.running, false)
		if err != .None {
			emit_line(srv.sink, "error", map[string]json.Value{"text" = fmt.tprint(err)})
		}
		emit_line(srv.sink, "ready", nil)
	}
}

// emit_json is the agent.Event sink — one JSONL line per event. userdata is a
// ^Line_Sink, or nil for stdout.
emit_json :: proc(event: agent.Event, userdata: rawptr) {
	sink := cast(^Line_Sink)userdata
	#partial switch e in event {
	case agent.Event_Agent_Start:
		emit_line(sink, "agent_start", nil)
	case agent.Event_Agent_End:
		emit_line(sink, "agent_end", nil)
	case agent.Event_Turn_Start:
		emit_line(sink, "turn_start", nil)
	case agent.Event_Turn_End:
		emit_line(sink, "turn_end", nil)
	case agent.Event_Message_Start:
		emit_line(sink, "message_start", map[string]json.Value{"role" = fmt.tprint(e.message.role)})
	case agent.Event_Message_Update:
		emit_line(sink, "message_update", map[string]json.Value{
			"role"     = fmt.tprint(e.message.role),
			"text"     = e.message.text,
			"thinking" = e.message.thinking,
		})
	case agent.Event_Message_End:
		emit_line(sink, "message_end", map[string]json.Value{
			"role" = fmt.tprint(e.message.role),
			"text" = e.message.text,
		})
	case agent.Event_Tool_Start:
		emit_line(sink, "tool_start", map[string]json.Value{
			"id" = e.id, "name" = e.name, "arguments" = e.arguments,
		})
	case agent.Event_Tool_End:
		emit_line(sink, "tool_end", map[string]json.Value{
			"id" = e.id, "name" = e.name, "text" = e.text, "is_error" = e.is_error,
		})
	case agent.Event_Compaction:
		emit_line(sink, "compaction", map[string]json.Value{
			"summary"       = e.data.summary,
			"tokens_before" = json.Integer(e.data.tokens_before),
		})
	}
}

reader_main :: proc(data: rawptr) {
	srv := cast(^Server)data
	// thread-local scratch: parsed commands die after dispatch; queued text is
	// cloned into srv.allocator inside handle_command.
	arena: virtual.Arena
	scratch := virtual.arena_allocator(&arena)
	defer virtual.arena_destroy(&arena)
	r: bufio.Reader
	bufio.reader_init(&r, os.to_reader(os.stdin))
	for {
		line, rerr := bufio.reader_read_string(&r, '\n', scratch)
		trimmed := strings.trim_space(line)
		if len(trimmed) > 0 {
			v, jerr := json.parse_string(trimmed, allocator = scratch)
			if jerr != nil {
				fmt.eprintfln("rpc: bad json: %v", jerr)
			} else {
				handle_command(srv, v)
			}
			free_all(scratch)
		}
		if rerr != nil { break } // .EOF or a read error — either way stdin is done
	}
	chan.close(srv.prompt_ch)
}

handle_command :: proc(srv: ^Server, v: json.Value) {
	obj, is_obj := v.(json.Object)
	if !is_obj { return }
	cmd, is_str := obj["cmd"].(json.String)
	if !is_str { return }
	raw_text, _ := obj["text"].(json.String)
	// raw_text lives in the reader's temp_allocator, freed after this proc —
	// clone into the server's allocator before it can reach a queue.
	text := strings.clone(string(raw_text), srv.allocator)
	switch cmd {
	case "prompt":
		if sync.atomic_load(&srv.running) {
			// a prompt mid-run steers — the model sees it next generation
			if sync.mutex_guard(&srv.mu) {
				defer sync.mutex_unlock(&srv.mu)
				append(&srv.steer_q, agent.Agent_Message{role = .User, text = text})
			}
		} else {
			chan.send(srv.prompt_ch, text)
		}
	case "steer":
		if sync.mutex_guard(&srv.mu) {
			defer sync.mutex_unlock(&srv.mu)
			append(&srv.steer_q, agent.Agent_Message{role = .User, text = text})
		}
	case "follow_up":
		if sync.mutex_guard(&srv.mu) {
			defer sync.mutex_unlock(&srv.mu)
			append(&srv.follow_q, agent.Agent_Message{role = .User, text = text})
		}
	case "abort":
		sync.atomic_store(&srv.cancel.flag, true)
	case "permission":
		id, _ := obj["id"].(json.String)
		decision, _ := obj["decision"].(json.String)
		answer_permission(srv, string(id), string(decision), text)
	case "quit":
		sync.atomic_store(&srv.quitting, true)
		chan.send(srv.prompt_ch, "")
	}
}

drain_steering :: proc(userdata: rawptr) -> []agent.Agent_Message {
	return drain(cast(^Server)userdata, &(cast(^Server)userdata).steer_q)
}

drain_follow_up :: proc(userdata: rawptr) -> []agent.Agent_Message {
	return drain(cast(^Server)userdata, &(cast(^Server)userdata).follow_q)
}

drain :: proc(srv: ^Server, q: ^[dynamic]agent.Agent_Message) -> []agent.Agent_Message {
	if sync.mutex_guard(&srv.mu) {
		defer sync.mutex_unlock(&srv.mu)
		if len(q^) == 0 { return nil }
		out := make([]agent.Agent_Message, len(q^), context.allocator)
		copy(out, q^[:])
		clear(q)
		return out
	}
	return nil
}

// emit_line writes {"type":type, ...fields} and takes ownership of fields.
emit_line :: proc(sink: ^Line_Sink, type: string, fields: map[string]json.Value) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	fields := fields
	defer delete(fields)
	fields["type"] = type
	if sink != nil && len(sink.session) > 0 {
		fields["session"] = sink.session
	}
	data, _ := json.marshal(fields, {}, context.temp_allocator)
	write_line(sink, data)
}

// write_line sends one already-encoded JSON object plus the newline.
write_line :: proc(sink: ^Line_Sink, data: []u8) {
	if sink == nil {
		fmt.printfln("%s", data)
		return
	}
	line := make([]u8, len(data) + 1, context.temp_allocator)
	copy(line, data)
	line[len(data)] = '\n'
	sink.write(line, sink.userdata)
}

// set_permissions gates every tool call of this server's runs on the rules; nil
// leaves them all allowed.
set_permissions :: proc(srv: ^Server, gate: ^permissions.Gate) {
	srv.gate = gate
	srv.cfg.before_tool_call = gate == nil ? nil : permission_hook
}

// permission_hook is Loop_Config.before_tool_call: rules decide, and an ask is put
// to a client. Block reasons reach the model as the tool result, so they are
// allocated for the transcript, not the temp allocator.
permission_hook :: proc(call: ai.Tool_Call, userdata: rawptr) -> (block: bool, reason: string) {
	srv := cast(^Server)userdata
	decision := permissions.evaluate(srv.gate, call.name, call.arguments)
	switch decision.action {
	case .Allow:
		return false, ""
	case .Deny:
		return true, fmt.aprintf("Blocked by a permission rule (%s). Do not retry this call; choose another approach.", decision.rule, allocator = srv.allocator)
	case .Ask:
		if srv.gate.auto_approve { return false, "" }
		outcome, answer := ask(srv, call, decision)
		switch outcome {
		case .Allow:
			return false, ""
		case .Allow_Session:
			permissions.grant(srv.gate, call.name, decision.target)
			return false, ""
		case .Deny:
			return true, answer
		}
	}
	return true, "permission check failed"
}

@(private)
has_listener :: proc(srv: ^Server) -> bool {
	return srv.sink == nil || srv.sink.listening == nil || srv.sink.listening(srv.sink.userdata)
}

// ask puts one tool call to the clients and waits for the first answer, the
// timeout, an abort or a quit. The returned text is the model-facing reason when
// the call is denied.
@(private)
ask :: proc(srv: ^Server, call: ai.Tool_Call, decision: permissions.Decision) -> (Decision_Kind, string) {
	a := srv.allocator
	if !has_listener(srv) {
		return .Deny, fmt.aprintf("This call needs approval (%s) but no client is connected to give it.", decision.rule, allocator = a)
	}
	ap := &srv.approval
	sync.mutex_lock(&ap.mu)
	ap.counter += 1
	ap.id = fmt.aprintf("p%d", ap.counter, allocator = a)
	ap.tool = strings.clone(call.name, a)
	ap.target = strings.clone(decision.target, a)
	ap.arguments = strings.clone(call.arguments, a)
	ap.rule = strings.clone(decision.rule, a)
	ap.answered = false
	ap.reason = ""
	ap.active = true
	id := strings.clone(ap.id, context.temp_allocator) // ap.id is freed below
	sync.mutex_unlock(&ap.mu)

	emit_line(srv.sink, "permission_request", map[string]json.Value{
		"id" = id, "tool" = ap.tool, "target" = ap.target, "arguments" = ap.arguments, "rule" = ap.rule,
	})

	timeout := srv.ask_timeout > 0 ? srv.ask_timeout : PERMISSION_TIMEOUT
	deadline := time.tick_add(time.tick_now(), timeout)
	outcome := "timeout"
	sync.mutex_lock(&ap.mu)
	for !ap.answered {
		if sync.atomic_load(&srv.cancel.flag) { outcome = "aborted"; break }
		if sync.atomic_load(&srv.quitting) { outcome = "aborted"; break }
		if time.tick_diff(time.tick_now(), deadline) <= 0 { break }
		sync.cond_wait_with_timeout(&ap.cond, &ap.mu, 100 * time.Millisecond)
	}
	kind := Decision_Kind.Deny
	reason := ""
	if ap.answered {
		kind = ap.decision
		reason = ap.reason
		outcome = kind == .Allow ? "allow" : kind == .Allow_Session ? "allow_session" : "deny"
	}
	ap.active = false
	delete(ap.id, a)
	delete(ap.tool, a)
	delete(ap.target, a)
	delete(ap.arguments, a)
	delete(ap.rule, a)
	sync.mutex_unlock(&ap.mu)

	emit_line(srv.sink, "permission_resolved", map[string]json.Value{"id" = id, "decision" = outcome})
	if kind != .Deny { return kind, "" }
	switch outcome {
	case "timeout": return .Deny, fmt.aprintf("No approval was given within %v; the call was denied.", timeout, allocator = a)
	case "aborted": return .Deny, "The run was aborted before this call was approved."
	}
	if len(reason) > 0 { return .Deny, fmt.aprintf("The user denied this call: %s", reason, allocator = a) }
	return .Deny, "The user denied this call."
}

// answer_permission records the first answer to the open request; stale or
// unknown ids and unknown decisions are ignored.
@(private)
answer_permission :: proc(srv: ^Server, id, decision, reason: string) {
	kind: Decision_Kind
	switch decision {
	case "allow":         kind = .Allow
	case "allow_session": kind = .Allow_Session
	case "deny":          kind = .Deny
	case: return
	}
	ap := &srv.approval
	sync.mutex_lock(&ap.mu)
	defer sync.mutex_unlock(&ap.mu)
	if !ap.active || ap.answered || ap.id != id { return }
	ap.answered = true
	ap.decision = kind
	ap.reason = reason
	sync.cond_signal(&ap.cond)
}

// pending_permission describes the open request for clients that attach while
// it waits; nil when there is none. Strings are temp-allocated.
pending_permission :: proc(srv: ^Server) -> json.Value {
	ap := &srv.approval
	sync.mutex_lock(&ap.mu)
	defer sync.mutex_unlock(&ap.mu)
	if !ap.active { return nil }
	return json.Object{
		"id" = strings.clone(ap.id, context.temp_allocator),
		"tool" = strings.clone(ap.tool, context.temp_allocator),
		"target" = strings.clone(ap.target, context.temp_allocator),
		"arguments" = strings.clone(ap.arguments, context.temp_allocator),
		"rule" = strings.clone(ap.rule, context.temp_allocator),
	}
}
