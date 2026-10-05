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
		testing.expect(t, append_header(s, "test/model", "/tmp/project") == nil)
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
	testing.expect_value(t, s.cwd, "/tmp/project")
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

@(test)
test_torn_tail_is_dropped_and_middle_corruption_is_refused :: proc(t: ^testing.T) {
	dir := os.get_env("TMPDIR", context.temp_allocator)
	if len(dir) == 0 { dir = "/tmp" }
	path := fmt.aprintf("%s/hw_agent_torn_%d.jsonl", strings.trim_right(dir, "/"), time.to_unix_nanoseconds(time.now()), allocator = context.temp_allocator)
	defer os.remove(path)

	{
		s, _, _ := open(path, context.temp_allocator)
		_ = append_message(s, {role = .User, text = "one"})
		_ = append_message(s, {role = .Assistant, text = "two"})
		close(s)
	}
	// a crash left half an entry with no newline
	data, _ := os.read_entire_file(path, context.temp_allocator)
	whole := len(data)
	_ = os.write_entire_file(path, transmute([]u8)strings.concatenate({string(data), `{"id":"e2","parent_id":"e1","seq":2,"ki`}, context.temp_allocator))

	s, msgs, err := open(path, context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect_value(t, len(msgs), 2)
	after, _ := os.read_entire_file(path, context.temp_allocator)
	testing.expect_value(t, len(after), whole) // the torn bytes are gone
	_ = append_message(s, {role = .User, text = "three"})
	close(s)
	again, _, err2 := replay(path, context.temp_allocator)
	testing.expect(t, err2 == nil && len(again) == 3 && again[2].text == "three", "the log must keep working after the repair")

	// a last entry that is whole but lacks its newline must not fuse with the next append
	whole_log, _ := os.read_entire_file(path, context.temp_allocator)
	_ = os.write_entire_file(path, whole_log[:len(whole_log) - 1])
	s, _, _ = open(path, context.temp_allocator)
	_ = append_message(s, {role = .User, text = "four"})
	close(s)
	again, _, err2 = replay(path, context.temp_allocator)
	testing.expect(t, err2 == nil && len(again) == 4, "entries must stay on their own lines")

	// damage that is not at the end is corruption: refuse, and say where
	log, _ := os.read_entire_file(path, context.temp_allocator)
	lines := strings.split(string(log), "\n", context.temp_allocator)
	lines[1] = "{not json"
	_ = os.write_entire_file(path, transmute([]u8)strings.join(lines, "\n", context.temp_allocator))
	_, _, err3 := open(path, context.temp_allocator)
	testing.expect_value(t, err3, os.General_Error.Invalid_File)
}
