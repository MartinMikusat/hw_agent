package ai

// Runnable check for SSE tool-call fragment assembly — the non-trivial piece:
// id/name land once on the first delta, arguments arrive split across chunks,
// and [DONE] must yield a terminal event with the completed Tool_Call.

import "core:testing"

@(test)
test_sse_tool_call_fragments :: proc(t: ^testing.T) {
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
