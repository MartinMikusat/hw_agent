package ai

// Runnable check for SSE tool-call fragment assembly — the non-trivial piece:
// id/name land once on the first delta, arguments arrive split across chunks,
// and [DONE] must yield a terminal event with the completed Tool_Call.

import "core:testing"
import "core:mem"
import "core:encoding/json"
import "core:bufio"
import "core:os"
import "core:sync"
import "core:thread"
import "core:time"
import "core:strings"

@(test)
test_sse_tool_call_fragments :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	impl := new(OpenAI_Stream)
	impl.allocator = context.allocator
	impl.partial.role = .Assistant

	lines := []string {
		`data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"bash","arguments":""}}]},"finish_reason":null}]}`,
		`data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"command\": \"ls"}}]},"finish_reason":null}]}`,
		`data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":" -la /tmp\"}"}}]},"finish_reason":null}]}`,
		`data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}`,
		`data: [DONE]`,
	}

	last: Event
	got_done := false
	for line in lines {
		ev, has := handle_sse_line(impl, line)
		if has {
			last = ev
			if ev.kind == .Done {
				got_done = true
			}
		}
	}

	testing.expect(t, got_done, "stream must terminate on [DONE]")
	testing.expect_value(t, last.reason, Stop_Reason.Tool_Calls)
	testing.expect_value(t, len(impl.final.tool_calls), 1)
	call := impl.final.tool_calls[0]
	testing.expect_value(t, call.id, "call_1")
	testing.expect_value(t, call.name, "bash")
	testing.expect_value(t, call.arguments, `{"command": "ls -la /tmp"}`)
	testing.expect_value(t, impl.final.usage.total, 15)
}

@(test)
test_sse_combined_deltas_and_request_contract :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	impl := new(OpenAI_Stream)
	impl.allocator = context.allocator
	impl.partial.role = .Assistant
	event, has := handle_sse_line(impl, `data: {"choices":[{"delta":{"content":"answer", "reasoning":"think", "reasoning_details":[{"type":"reasoning.encrypted","data":"opaque","index":0}],"tool_calls":[{"index":0,"id":"a","function":{"name":"search","arguments":"{}"}},{"index":1,"id":"b","function":{"name":"read","arguments":"{\"id\":1}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":2,"completion_tokens":3,"total_tokens":5,"cost":0.001}}`)
	testing.expect(t, has)
	testing.expect_value(t, event.kind, Event_Kind.Text_Delta)
	expected := []Event_Kind{.Thinking_Delta, .Tool_Call_Delta, .Tool_Call_Delta}
	for kind in expected {
		delta, found := next_pending(impl)
		testing.expect(t, found)
		testing.expect_value(t, delta.kind, kind)
	}
	_, more := next_pending(impl)
	testing.expect(t, !more)
	done, _ := handle_sse_line(impl, "data: [DONE]")
	testing.expect_value(t, done.kind, Event_Kind.Done)
	testing.expect_value(t, impl.final.text, "answer")
	testing.expect_value(t, impl.final.thinking, "think")
	testing.expect_value(t, len(impl.final.tool_calls), 2)
	testing.expect_value(t, impl.final.tool_calls[1].arguments, `{"id":1}`)
	testing.expect(t, impl.final.usage.complete && impl.final.usage.cost_reported)
	testing.expect_value(t, impl.final.usage.cost_usd, 0.001)
	model := Model {
		id = "fixture", max_output = 123,
		provider_options = {require_parameters = true, data_collection_deny = true, zdr = true},
	}
	body, err := request_json(model, Context{messages = []Message{impl.final}}, context.allocator)
	testing.expect_value(t, err, Error.None)
	value, perr := json.parse_string(body, .JSON, false)
	testing.expect(t, perr == nil)
	root := value.(json.Object)
	testing.expect_value(t, json_int(root["max_completion_tokens"]), 123)
	provider := root["provider"].(json.Object)
	testing.expect_value(t, bool(provider["require_parameters"].(json.Boolean)), true)
	testing.expect_value(t, string(provider["data_collection"].(json.String)), "deny")
	testing.expect_value(t, bool(provider["zdr"].(json.Boolean)), true)
	messages := root["messages"].(json.Array)
	message := messages[0].(json.Object)
	testing.expect_value(t, string(message["reasoning"].(json.String)), "think")
	details := message["reasoning_details"].(json.Array)
	testing.expect_value(t, len(details), 1)
	testing.expect_value(t, string(details[0].(json.Object)["data"].(json.String)), "opaque")
	invalid_lines := []string {
		`data: {"choices":[{"delta":{"tool_calls":[{"index":-1}]}}]}`,
		`data: {"choices":[{"delta":{"tool_calls":[{"index":64}]}}]}`,
		`data: {"choices":[{"delta":{"tool_calls":[{"index":0.5}]}}]}`,
	}
	for line in invalid_lines {
		bad, _ := handle_sse_line(impl, line)
		testing.expect_value(t, bad.kind, Event_Kind.Error)
	}
	oversized, _ := handle_sse_line(impl, strings.repeat("x", MAX_SSE_LINE_BYTES + 1))
	testing.expect_value(t, oversized.kind, Event_Kind.Error)
	impl.response_bytes = MAX_STREAM_BYTES
	exhausted, _ := handle_sse_line(impl, ": keepalive")
	testing.expect_value(t, exhausted.kind, Event_Kind.Error)
}

test_cancel_worker :: proc(data: rawptr) {
	time.sleep(20 * time.Millisecond)
	sync.atomic_store(&(cast(^Cancellation)data).flag, true)
}

@(test)
test_stalled_stream_cancellation_deadline_and_cleanup :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	abort_cases := []bool{false, true}
	for aborted in abort_cases {
		cancel: Cancellation
		reader, writer, pipe_err := os.pipe()
		testing.expect(t, pipe_err == nil)
		process, err := os.process_start({command = {"sleep", "10"}, stdout = writer})
		os.close(writer)
		testing.expect(t, err == nil)
		impl := new(OpenAI_Stream)
		impl.allocator = context.allocator
		impl.process = process
		impl.pipe_out = reader
		impl.cancel = &cancel
		impl.started_at = time.tick_now()
		impl.timeout = 50 * time.Millisecond
		impl.partial.role = .Assistant
		impl.request_path, _ = write_temp_file("fixture", context.allocator)
		impl.config_path, _ = write_temp_file("fixture", context.allocator)
		impl.stderr_log, _ = write_temp_file("fixture", context.allocator)
		bufio.reader_init(&impl.reader, os.to_reader(reader))
		impl.watcher = thread.create_and_start_with_data(impl, openai_watch)
		canceller: ^thread.Thread
		if aborted {
			canceller = thread.create_and_start_with_data(&cancel, test_cancel_worker)
		}
		stream := Stream{data = impl, next = openai_stream_next, result = openai_stream_result, close = openai_stream_close}
		event, has := stream.next(&stream)
		testing.expect(t, has)
		testing.expect_value(t, event.kind, Event_Kind.Error)
		testing.expect_value(t, event.reason, aborted ? Stop_Reason.Aborted : Stop_Reason.Error)
		testing.expect(t, time.tick_since(impl.started_at) < time.Second)
		paths := [3]string{impl.request_path, impl.config_path, impl.stderr_log}
		if canceller != nil {
			thread.join(canceller)
			thread.destroy(canceller)
		}
		stream.close(&stream)
		for path in paths {
			testing.expect(t, !os.exists(path))
		}
		stream.close(&stream)
	}
	stream, err := stream_openai(Model{id = "fixture", provider_options = {endpoint = "http://127.0.0.1:1", timeout_ms = 200}}, {}, "fixture-secret", nil, context.allocator)
	testing.expect_value(t, err, Error.None)
	impl := cast(^OpenAI_Stream)stream.data
	config, _ := os.read_entire_file(impl.config_path, context.allocator)
	testing.expect(t, strings.contains(string(config), "Authorization: Bearer fixture-secret"))
	paths := [3]string{impl.request_path, impl.config_path, impl.stderr_log}
	event, _ := stream.next(&stream)
	testing.expect_value(t, event.kind, Event_Kind.Error)
	stream.close(&stream)
	for path in paths {
		testing.expect(t, !os.exists(path))
	}
}
