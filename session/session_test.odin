package session

// Runnable check for the JSONL round-trip: append entries, reopen, and verify
// linear replay restores messages in order with linked ids.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

import "../agent"

@(test)
test_append_reopen_replays :: proc(t: ^testing.T) {
	dir := os.get_env("TMPDIR", context.temp_allocator)
	if len(dir) == 0 {
		dir = "/tmp"
	}
	path := fmt.aprintf(
		"%s/hw_agent_sess_test_%d.jsonl",
		strings.trim_right(dir, "/"),
		time.to_unix_nanoseconds(time.now()),
		allocator = context.temp_allocator,
	)
	defer os.remove(path)

	{
		s, msgs, err := open(path, context.temp_allocator)
		testing.expect(t, err == nil, "open should succeed")
		testing.expect_value(t, len(msgs), 0)
		testing.expect(t, append_header(s, "test/model") == nil)
		_ = append_message(s, agent.Agent_Message{role = .User, text = "hello"})
		_ = append_message(s, agent.Agent_Message {
			role       = .Assistant,
			text       = "running ls",
			tool_calls = {{id = "c1", name = "bash", arguments = `{"command":"ls"}`}},
		})
		_ = append_message(s, agent.Agent_Message{role = .Tool_Result, tool_call_id = "c1", text = "file.txt"})
		close(s)
	}

	s, msgs, err := open(path, context.temp_allocator)
	testing.expect(t, err == nil, "reopen should succeed")
	defer close(s)

	testing.expect_value(t, len(msgs), 3)
	testing.expect_value(t, s.model, "test/model")
	testing.expect_value(t, msgs[0].role, agent.Agent_Role.User)
	testing.expect_value(t, msgs[0].text, "hello")
	testing.expect_value(t, msgs[1].role, agent.Agent_Role.Assistant)
	testing.expect_value(t, len(msgs[1].tool_calls), 1)
	testing.expect_value(t, msgs[1].tool_calls[0].name, "bash")
	testing.expect_value(t, msgs[2].role, agent.Agent_Role.Tool_Result)
	testing.expect_value(t, msgs[2].tool_call_id, "c1")
	testing.expect_value(t, msgs[2].text, "file.txt")

	// resume appends continue the chain, not restart it
	_ = append_message(s, agent.Agent_Message{role = .User, text = "and again"})
	testing.expect_value(t, s.next_seq, 5)
	testing.expect_value(t, s.tip_id, "e4")
}

@(test)
test_compaction_replay_resets :: proc(t: ^testing.T) {
	dir := os.get_env("TMPDIR", context.temp_allocator)
	if len(dir) == 0 {
		dir = "/tmp"
	}
	path := fmt.aprintf(
		"%s/hw_agent_compact_test_%d.jsonl",
		strings.trim_right(dir, "/"),
		time.to_unix_nanoseconds(time.now()),
		allocator = context.temp_allocator,
	)
	defer os.remove(path)

	{
		s, _, err := open(path, context.temp_allocator)
		testing.expect(t, err == nil)
		// old head — should be dropped by replay
		_ = append_message(s, {role = .User, text = "old question"})
		_ = append_message(s, {role = .Assistant, text = "old answer"})
		// compaction covering it: summary + retained tail
		compaction := agent.Compaction {
			summary = "SUM: user asked X",
			tail = {
				{role = .User, text = "recent q"},
				{role = .Assistant, text = "recent a"},
			},
		}
		_ = append_compaction(s, &compaction)
		// post-compaction traffic
		_ = append_message(s, {role = .User, text = "next q"})
		close(s)
	}

	s, msgs, err := open(path, context.temp_allocator)
	testing.expect(t, err == nil)
	defer close(s)

	testing.expect_value(t, len(msgs), 4)
	testing.expect_value(t, msgs[0].role, agent.Agent_Role.Compaction_Summary)
	testing.expect_value(t, msgs[0].text, "SUM: user asked X")
	testing.expect_value(t, msgs[1].text, "recent q")
	testing.expect_value(t, msgs[2].text, "recent a")
	testing.expect_value(t, msgs[3].text, "next q")
}
