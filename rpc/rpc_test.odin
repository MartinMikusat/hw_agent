package rpc

import "core:encoding/json"
import "core:fmt"
import "core:sync"
import "core:sync/chan"
import "core:testing"
import "../agent"
import "../ai"

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
	v, _ := json.parse_string(s)
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
	steer := drain_steering(srv)
	testing.expect_value(t, len(steer), 2)
	testing.expect_value(t, len(srv.steer_q), 0)
	testing.expect_value(t, len(drain_steering(srv)), 0)
	follow := drain_follow_up(srv)
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
