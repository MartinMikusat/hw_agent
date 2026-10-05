package compact

// Runnable check: find_cut never orphans a tool result, and maybe_compact
// splices [summary + verbatim tail] while reporting the record for the log.

import "core:mem"
import "core:strings"
import "core:testing"

import "../agent"
import "../ai"

mk :: proc(role: agent.Agent_Role, text: string) -> agent.Agent_Message {
	return agent.Agent_Message{role = role, text = text}
}

// stream fn that answers every call with a fixed summary
sum_stream :: proc(
	model: ai.Model,
	ctx: ai.Context,
	api_key: string,
	cancel: ^ai.Cancellation,
	allocator: mem.Allocator,
) -> (
	ai.Stream,
	ai.Error,
) {
	fs := new(Sum_Stream, allocator)
	fs.msg = ai.Message{role = .Assistant, text = "SUMMARY-OF-HEAD", stop_reason = .Stop}
	return ai.Stream{data = fs, next = sum_next, result = sum_result, close = sum_close}, nil
}

Sum_Stream :: struct {
	msg:  ai.Message,
	done: bool,
}

sum_next :: proc(s: ^ai.Stream) -> (ai.Event, bool) {
	fs := cast(^Sum_Stream)s.data
	if fs.done {
		return {}, false
	}
	fs.done = true
	return ai.Event{kind = .Done, reason = .Stop, partial = &fs.msg}, true
}

sum_result :: proc(s: ^ai.Stream) -> ai.Message {
	return (cast(^Sum_Stream)s.data).msg
}

sum_close :: proc(s: ^ai.Stream) {}

@(test)
test_cut_never_orphans_tool_result :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator // records and helper strings are scratch here
	// assistant call + two results + a user message; keep_chars tuned so the
	// natural cut lands inside the tool-result block — must snap forward.
	msgs := []agent.Agent_Message{
		mk(.User, strings.repeat("a", 200)),
		{role = .Assistant, text = "", tool_calls = {
			{id = "c1", name = "bash", arguments = `{}`},
			{id = "c2", name = "bash", arguments = `{}`},
		}},
		{role = .Tool_Result, tool_call_id = "c1", text = strings.repeat("r", 100)},
		{role = .Tool_Result, tool_call_id = "c2", text = strings.repeat("r", 100)},
		mk(.User, strings.repeat("b", 50)),
		{role = .Assistant, text = strings.repeat("x", 50)},
	}
	cut := find_cut(msgs, 120) // keeps roughly the last 2 messages → cut lands on a result
	testing.expect(t, cut > 0)
	testing.expect(t, msgs[cut].role != .Tool_Result, "cut must not orphan a tool result")
	// every tool call in the retained tail must have its result present
	for m in msgs[cut:] {
		if m.role == .Tool_Result {
			found := false
			for o in msgs[cut:] {
				if o.role == .Assistant {
					for c in o.tool_calls {
						if c.id == m.tool_call_id {
							found = true
						}
					}
				}
			}
			testing.expect(t, found, "tail contains result without its call")
		}
	}
}

@(test)
test_maybe_compact_splices :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator // records and helper strings are scratch here
	ctx := new(agent.Context, context.temp_allocator)
	// head must exceed KEEP_CHARS (80k) so find_cut has something to cut
	append(&ctx.messages, mk(.User, strings.repeat("h", 30_000)))
	append(&ctx.messages, mk(.Assistant, strings.repeat("a", 30_000)))
	append(&ctx.messages, mk(.User, strings.repeat("h", 30_000)))
	append(&ctx.messages, mk(.Assistant, strings.repeat("a", 30_000)))
	append(&ctx.messages, mk(.User, "recent question"))
	append(&ctx.messages, mk(.Assistant, "recent answer"))

	cfg := new(agent.Loop_Config, context.temp_allocator)
	cfg.model = ai.Model{id = "fake", context_window = 200_000}
	// est ≈ 30k tokens > 200k-16k? no — need the threshold under the estimate
	cfg.model.context_window = 40_000 // est ~30k > 40k-16k=24k → triggers
	cfg.stream = sum_stream

	before := len(ctx.messages)
	data := maybe_compact(ctx, cfg, nil, nil)
	testing.expect(t, data != nil, "should compact over threshold")
	testing.expect_value(t, ctx.messages[0].role, agent.Agent_Role.Compaction_Summary)
	testing.expect(t, strings.contains(ctx.messages[0].text, "SUMMARY-OF-HEAD"))
	testing.expect(t, len(ctx.messages) < before, "context shrank")
	// tail preserved verbatim
	last := ctx.messages[len(ctx.messages) - 1]
	testing.expect_value(t, last.text, "recent answer")
	// persisted record carries the tail
	testing.expect_value(t, data.tail[len(data.tail) - 1].text, "recent answer")
}

@(test)
test_prune_clears_old_tool_output :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator // records and helper strings are scratch here
	// old big results + recent small result — only the old ones get cleared
	msgs := []agent.Agent_Message{
		mk(.User, "go"),
		{role = .Assistant, tool_calls = {{id = "c1", name = "bash", arguments = `{}`}}},
		{role = .Tool_Result, tool_call_id = "c1", text = strings.repeat("o", 30_000)},
		{role = .Assistant, tool_calls = {{id = "c2", name = "bash", arguments = `{}`}}},
		{role = .Tool_Result, tool_call_id = "c2", text = strings.repeat("o", 30_000)},
		{role = .Assistant, tool_calls = {{id = "c3", name = "bash", arguments = `{}`}}},
		{role = .Tool_Result, tool_call_id = "c3", text = "small"},
	}
	out := prune(msgs, nil)
	testing.expect_value(t, out[2].text, PRUNED_MARKER) // 5 + 30k + 30k = 60k > 40k horizon
	testing.expect(t, len(out[4].text) == 30_000)       // 5 + 30k = 30k — still protected
	testing.expect_value(t, out[6].text, "small")
	// stored slice untouched
	testing.expect(t, len(msgs[2].text) == 30_000)

	// below reclaim threshold → pass-through
	small := []agent.Agent_Message{
		{role = .Tool_Result, tool_call_id = "c1", text = "tiny"},
	}
	testing.expect_value(t, prune(small, nil)[0].text, "tiny")
}

@(test)
test_compact_noop_below_threshold :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator // records and helper strings are scratch here
	ctx := new(agent.Context, context.temp_allocator)
	append(&ctx.messages, mk(.User, "hi"))
	cfg := new(agent.Loop_Config, context.temp_allocator)
	cfg.model = ai.Model{id = "fake", context_window = 200_000}
	cfg.stream = sum_stream
	testing.expect(t, maybe_compact(ctx, cfg, nil, nil) == nil)
	testing.expect_value(t, len(ctx.messages), 1)
}

probed_cancel: ^ai.Cancellation

probe_stream :: proc(model: ai.Model, ctx: ai.Context, api_key: string, cancel: ^ai.Cancellation, allocator: mem.Allocator) -> (ai.Stream, ai.Error) {
	probed_cancel = cancel
	return sum_stream(model, ctx, api_key, cancel, allocator)
}

@(test)
test_abort_reaches_the_summary_request_and_keeps_the_conversation :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator // records and helper strings are scratch here
	ctx := new(agent.Context, context.temp_allocator)
	for _ in 0 ..< 4 {
		append(&ctx.messages, mk(.User, strings.repeat("h", 30_000)))
		append(&ctx.messages, mk(.Assistant, strings.repeat("a", 30_000)))
	}
	append(&ctx.messages, mk(.User, "recent"))
	cfg := new(agent.Loop_Config, context.temp_allocator)
	cfg.model = ai.Model{id = "fake", context_window = 40_000}
	cfg.stream = probe_stream
	cancel := ai.Cancellation{}
	before := len(ctx.messages)

	// the request carries the run's cancel flag, so an abort can stop it mid-request
	testing.expect(t, maybe_compact(ctx, cfg, &cancel, nil) != nil)
	testing.expect(t, probed_cancel == &cancel, "the summary request must be cancellable")

	// aborted: nothing is spliced, the conversation stays as it was
	ctx2 := new(agent.Context, context.temp_allocator)
	for _ in 0 ..< 4 {
		append(&ctx2.messages, mk(.User, strings.repeat("h", 30_000)))
		append(&ctx2.messages, mk(.Assistant, strings.repeat("a", 30_000)))
	}
	append(&ctx2.messages, mk(.User, "recent"))
	cancel.flag = true
	testing.expect(t, maybe_compact(ctx2, cfg, &cancel, nil) == nil)
	testing.expect_value(t, len(ctx2.messages), before)
}
