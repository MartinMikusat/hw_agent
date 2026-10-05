package rpc

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:sync/chan"
import "core:testing"
import "core:thread"
import "core:time"
import "../agent"
import "../ai"
import "../permissions"

mk_srv :: proc() -> ^Server {
	srv := new(Server, context.temp_allocator)
	srv.allocator = context.temp_allocator
	srv.cancel = new(ai.Cancellation, context.temp_allocator)
	srv.steer_q = make([dynamic]agent.Agent_Message, 0, 8, context.temp_allocator)
	srv.follow_q = make([dynamic]agent.Agent_Message, 0, 8, context.temp_allocator)
	ch, _ := chan.create_buffered(chan.Chan(string), 8, context.temp_allocator)
	srv.prompt_ch = ch
	return srv
}

cmd :: proc(srv: ^Server, c, text: string) {
	s := fmt.aprintf(`{{"cmd":"%s","text":"%s"}}`, c, text, allocator = context.temp_allocator)
	v, _ := json.parse_string(s, allocator = context.temp_allocator)
	handle_command(srv, v)
}

@(test)
test_command_routing :: proc(t: ^testing.T) {
	srv := mk_srv()

	// prompt while idle → prompt channel
	cmd(srv, "prompt", "first")
	got, ok := chan.try_recv(srv.prompt_ch)
	testing.expect(t, ok && got == "first")

	// prompt while running → steering queue instead
	sync.atomic_store(&srv.running, true)
	cmd(srv, "prompt", "mid-run")
	testing.expect_value(t, len(srv.steer_q), 1)
	testing.expect_value(t, srv.steer_q[0].text, "mid-run")
	testing.expect_value(t, srv.steer_q[0].role, agent.Agent_Role.User)

	// steer + follow_up → their queues
	cmd(srv, "steer", "interject")
	cmd(srv, "follow_up", "later")
	testing.expect_value(t, len(srv.steer_q), 2)
	testing.expect_value(t, srv.steer_q[1].text, "interject")
	testing.expect_value(t, srv.follow_q[0].text, "later")

	// drains return contents and clear
	steer := drain_steering(srv, context.temp_allocator)
	testing.expect_value(t, len(steer), 2)
	testing.expect_value(t, len(srv.steer_q), 0)
	testing.expect_value(t, len(drain_steering(srv, context.temp_allocator)), 0)
	follow := drain_follow_up(srv, context.temp_allocator)
	testing.expect_value(t, len(follow), 1)

	// abort sets the shared cancel flag
	cmd(srv, "abort", "")
	testing.expect(t, sync.atomic_load(&srv.cancel.flag))

	// quit flags + sends the wakeup sentinel
	cmd(srv, "quit", "")
	testing.expect(t, sync.atomic_load(&srv.quitting))
	sentinel, sok := chan.try_recv(srv.prompt_ch)
	testing.expect(t, sok && len(sentinel) == 0)
}

// ---- permission approvals ----

Capture :: struct {
	mu:        sync.Mutex,
	lines:     [dynamic]string,
	listening: bool,
}

capture_write :: proc(line: []u8, userdata: rawptr) {
	context.allocator = runtime.heap_allocator() // also called from the hook's thread
	c := cast(^Capture)userdata
	sync.mutex_lock(&c.mu)
	defer sync.mutex_unlock(&c.mu)
	append(&c.lines, strings.clone(strings.trim_space(string(line)), runtime.heap_allocator()))
}

capture_listening :: proc(userdata: rawptr) -> bool {
	return (cast(^Capture)userdata).listening
}

// wait_line returns the first captured line containing text, waiting for it.
wait_line :: proc(c: ^Capture, text: string) -> string {
	for _ in 0 ..< 200 {
		sync.mutex_lock(&c.mu)
		for line in c.lines {
			if strings.contains(line, text) {
				sync.mutex_unlock(&c.mu)
				return line
			}
		}
		sync.mutex_unlock(&c.mu)
		time.sleep(10 * time.Millisecond)
	}
	return ""
}

Hook_Run :: struct {
	srv:    ^Server,
	call:   ai.Tool_Call,
	block:  bool,
	reason: string,
}

start_hook :: proc(run: ^Hook_Run) -> ^thread.Thread {
	return thread.create_and_start_with_data(run, proc(data: rawptr) {
		run := cast(^Hook_Run)data
		run.block, run.reason = run.srv.cfg.before_tool_call(run.call, run.srv)
	})
}

approval_srv :: proc(capture: ^Capture, rule: permissions.Rule) -> ^Server {
	srv := mk_srv()
	srv.allocator = runtime.heap_allocator() // used from the hook's thread too
	srv.cfg = new(agent.Loop_Config, context.temp_allocator)
	srv.sink = new_clone(Line_Sink{write = capture_write, userdata = capture, listening = capture_listening}, context.temp_allocator)
	rules := make([]permissions.Rule, 1, context.temp_allocator)
	rules[0] = rule
	srv.gate = new_clone(permissions.Gate{rules = rules, cwd = "/work", allocator = runtime.heap_allocator()}, context.temp_allocator)
	set_permissions(srv, srv.gate)
	return srv
}

@(test)
test_permission_round_trip :: proc(t: ^testing.T) {
	capture := Capture{listening = true}
	srv := approval_srv(&capture, {.Ask, "bash", "git push*", .Global})
	push := ai.Tool_Call{id = "c1", name = "bash", arguments = `{"command":"git push origin main"}`}

	// rules that do not match never ask
	block, _ := srv.cfg.before_tool_call(ai.Tool_Call{id = "c0", name = "bash", arguments = `{"command":"ls"}`}, srv)
	testing.expect(t, !block && len(capture.lines) == 0)

	// deny with a reason reaches the model
	run := Hook_Run{srv = srv, call = push}
	th := start_hook(&run)
	request := wait_line(&capture, "permission_request")
	testing.expect(t, strings.contains(request, `"id":"p1"`) && strings.contains(request, "git push origin main"), request)
	testing.expect(t, pending_permission(srv) != nil, "a late attacher sees the open request")
	cmd(srv, "permission", "") // no id: ignored
	handle_command(srv, json_of(`{"cmd":"permission","id":"p1","decision":"deny","text":"not now"}`))
	thread.join(th)
	thread.destroy(th)
	testing.expect(t, run.block && strings.contains(run.reason, "not now"), run.reason)
	testing.expect(t, wait_line(&capture, `"decision":"deny"`) != "")
	testing.expect(t, pending_permission(srv) == nil)

	// allow_session: this exact call is not asked again, a different one is
	run = Hook_Run{srv = srv, call = push}
	th = start_hook(&run)
	wait_line(&capture, `"id":"p2"`)
	handle_command(srv, json_of(`{"cmd":"permission","id":"p2","decision":"allow_session"}`))
	thread.join(th)
	thread.destroy(th)
	testing.expect(t, !run.block)
	before := len(capture.lines)
	block, _ = srv.cfg.before_tool_call(push, srv)
	testing.expect(t, !block && len(capture.lines) == before, "granted call must not ask again")

	// a stale answer to a closed request changes nothing
	handle_command(srv, json_of(`{"cmd":"permission","id":"p2","decision":"deny"}`))
	testing.expect(t, pending_permission(srv) == nil)
}

@(test)
test_permission_without_an_answer :: proc(t: ^testing.T) {
	capture := Capture{listening = false}
	srv := approval_srv(&capture, {.Ask, "bash", "", .Global})
	call := ai.Tool_Call{id = "c1", name = "bash", arguments = `{"command":"ls"}`}

	// nobody attached: denied at once, nothing emitted
	block, reason := srv.cfg.before_tool_call(call, srv)
	testing.expect(t, block && strings.contains(reason, "no client is connected"), reason)
	testing.expect_value(t, len(capture.lines), 0)

	// -yes answers every ask
	srv.gate.auto_approve = true
	block, _ = srv.cfg.before_tool_call(call, srv)
	testing.expect(t, !block)
	srv.gate.auto_approve = false

	// nobody answers: denied after the timeout
	capture.listening = true
	srv.ask_timeout = 250 * time.Millisecond
	started := time.tick_now()
	block, reason = srv.cfg.before_tool_call(call, srv)
	testing.expect(t, block && strings.contains(reason, "No approval was given"), reason)
	testing.expect(t, time.tick_since(started) < 3 * time.Second)

	// abort ends the wait at once
	srv.ask_timeout = time.Minute
	run := Hook_Run{srv = srv, call = call}
	th := start_hook(&run)
	wait_line(&capture, `"id":"p2"`)
	sync.atomic_store(&srv.cancel.flag, true)
	thread.join(th)
	thread.destroy(th)
	testing.expect(t, run.block && strings.contains(run.reason, "aborted"), run.reason)
}

json_of :: proc(text: string) -> json.Value {
	v, _ := json.parse_string(text, allocator = context.temp_allocator)
	return v
}
