// rpc — JSONL stdio front-end. One JSON object per line in, one event per line
// out. Lets a parent process (hw_launcher, tests, scripts) drive the harness.
//
//   in:  {"cmd":"prompt","text":"..."}     start a run (mid-run: steers)
//        {"cmd":"steer","text":"..."}      inject before next generation
//        {"cmd":"follow_up","text":"..."}  run after the agent settles
//        {"cmd":"abort"}                   cancel the in-flight run
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
//        {"type":"error","text":"..."}
//
// Architecture: a reader thread parses stdin into queues; the main thread runs
// agent.run and drains the queues through Loop_Config hooks — no shared state
// with the model path beyond mutexed queues + the atomic cancel flag. All
// stdout writes happen on the loop thread, so events are ordered.
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
import "core:strings"
import "core:sync"
import "core:sync/chan"
import "core:thread"
import "../agent"
import "../ai"

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
	allocator: mem.Allocator,
}

// serve runs until stdin closes or {"cmd":"quit"} arrives. Takes ownership of
// cfg's steering/follow-up hooks and userdata.
serve :: proc(
	ctx: ^agent.Context,
	cfg: ^agent.Loop_Config,
	emit: agent.Emit,
	emit_userdata: rawptr,
	cancel: ^ai.Cancellation,
	allocator: mem.Allocator,
) {
	srv := new(Server, allocator)
	srv.ctx = ctx
	srv.cfg = cfg
	srv.cancel = cancel
	srv.allocator = allocator
	ch, cerr := chan.create_buffered(chan.Chan(string), 8, allocator)
	assert(cerr == nil)
	srv.prompt_ch = ch
	srv.steer_q = make([dynamic]agent.Agent_Message, 0, 8, allocator)
	srv.follow_q = make([dynamic]agent.Agent_Message, 0, 8, allocator)
	cfg.get_steering = drain_steering
	cfg.get_follow_up = drain_follow_up
	cfg.userdata = srv

	// No join: serve returning means process exit, and a blocking stdin read
	// can't be interrupted — joining here would hang a quit-with-open-stdin.
	thread.create_and_start_with_data(srv, reader_main)

	emit_control("ready", nil)
	for {
		text, ok := chan.recv(srv.prompt_ch)
		if !ok { break }
		// "" is quit's wakeup sentinel — prompts queued before it still run
		if len(text) == 0 {
			if sync.atomic_load(&srv.quitting) { break }
			continue
		}
		emit_control("prompt", map[string]json.Value{"text" = text})
		sync.atomic_store(&srv.running, true)
		sync.atomic_store(&cancel.flag, false) // clear a stale abort
		err := agent.run(ctx, cfg, []agent.Agent_Message{{role = .User, text = text}}, emit, emit_userdata, cancel, allocator)
		sync.atomic_store(&srv.running, false)
		if err != .None {
			emit_control("error", map[string]json.Value{"text" = fmt.tprint(err)})
		}
		emit_control("ready", nil)
	}
}

// emit_json is the agent.Event sink for rpc mode — one JSONL line per event.
emit_json :: proc(event: agent.Event, userdata: rawptr) {
	_ = userdata
	#partial switch e in event {
	case agent.Event_Agent_Start:
		emit_control("agent_start", nil)
	case agent.Event_Agent_End:
		emit_control("agent_end", nil)
	case agent.Event_Turn_Start:
		emit_control("turn_start", nil)
	case agent.Event_Turn_End:
		emit_control("turn_end", nil)
	case agent.Event_Message_Start:
		emit_control("message_start", map[string]json.Value{"role" = fmt.tprint(e.message.role)})
	case agent.Event_Message_Update:
		emit_control("message_update", map[string]json.Value{
			"role"     = fmt.tprint(e.message.role),
			"text"     = e.message.text,
			"thinking" = e.message.thinking,
		})
	case agent.Event_Message_End:
		emit_control("message_end", map[string]json.Value{
			"role" = fmt.tprint(e.message.role),
			"text" = e.message.text,
		})
	case agent.Event_Tool_Start:
		emit_control("tool_start", map[string]json.Value{
			"id" = e.id, "name" = e.name, "arguments" = e.arguments,
		})
	case agent.Event_Tool_End:
		emit_control("tool_end", map[string]json.Value{
			"id" = e.id, "name" = e.name, "text" = e.text, "is_error" = e.is_error,
		})
	case agent.Event_Compaction:
		emit_control("compaction", map[string]json.Value{
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

emit_control :: proc(type: string, fields: map[string]json.Value) {
	m := map[string]json.Value{"type" = type}
	for k, v in fields {
		m[k] = v
	}
	data, _ := json.marshal(m)
	fmt.printfln("%s", data)
}
