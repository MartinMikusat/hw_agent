package agent

// Runnable check for the agent loop itself, no network: a scripted Stream_Fn
// plays canned assistant responses; a fake tool records executions. Covers
// the tool round-trip, steering injection, follow-up drain, before_tool_call
// blocking, and abort — the full Loop_Config seam surface.

import "core:encoding/json"
import "core:mem"
import "core:sync"
import "core:testing"

import "../ai"

Fake :: struct {
	responses:   []ai.Message, // one scripted assistant message per stream call
	call_idx:    int,
	contexts:    [dynamic][]ai.Message, // request snapshots for assertions
	tools_ran:   [dynamic]string,
	steer:       []Agent_Message,
	steer_sent:  bool,
	follow:      []Agent_Message,
	follow_sent: bool,
	block_tools: bool,
	allocator:   mem.Allocator,
}

Fake_Stream :: struct {
	f:    ^Fake,
	msg:  ai.Message,
	step: int,
}

fake_next :: proc(s: ^ai.Stream) -> (ai.Event, bool) {
	fs := cast(^Fake_Stream)s.data
	fs.step += 1
	switch fs.step {
	case 1:
		if len(fs.msg.text) > 0 {
			return ai.Event{kind = .Text_Delta, text = fs.msg.text, partial = &fs.msg}, true
		}
		if len(fs.msg.tool_calls) > 0 {
			return ai.Event{kind = .Tool_Call_Delta, partial = &fs.msg}, true
		}
		return fake_next(s) // no text → jump straight to Done
	case 2:
		if fs.msg.stop_reason == .Error || fs.msg.stop_reason == .Aborted {
			return ai.Event{kind = .Error, text = fs.msg.text, reason = fs.msg.stop_reason, partial = &fs.msg}, true
		}
		return ai.Event {
			kind    = .Done,
			reason  = fs.msg.stop_reason,
			usage   = fs.msg.usage,
			partial = &fs.msg,
		}, true
	}
	return {}, false
}

fake_result :: proc(s: ^ai.Stream) -> ai.Message {
	return (cast(^Fake_Stream)s.data).msg
}

fake_close :: proc(s: ^ai.Stream) {}

rig_stream :: proc(
	model: ai.Model,
	ctx: ai.Context,
	api_key: string,
	cancel: ^ai.Cancellation,
	allocator: mem.Allocator,
) -> (
	ai.Stream,
	ai.Error,
) {
	f := cast(^Fake)model.data
	snap := make([]ai.Message, len(ctx.messages), f.allocator)
	for m, i in ctx.messages {
		snap[i] = m
	}
	append(&f.contexts, snap)

	fs := new(Fake_Stream, f.allocator)
	fs.f = f
	if ai.is_cancelled(cancel) {
		fs.msg = ai.Message{role = .Assistant, stop_reason = .Aborted}
		fs.step = 1
	} else {
		assert(f.call_idx < len(f.responses), "fake ran out of scripted responses")
		fs.msg = f.responses[f.call_idx]
		f.call_idx += 1
	}
	return ai.Stream{data = fs, next = fake_next, result = fake_result, close = fake_close}, nil
}

rig_tool :: proc(
	call_id: string,
	args: json.Value,
	cancel: ^ai.Cancellation,
	on_update: proc(text: string, userdata: rawptr),
	userdata: rawptr,
) -> Tool_Result {
	f := cast(^Fake)userdata
	append(&f.tools_ran, call_id)
	return {text = "fake-out"}
}

rig_steer :: proc(userdata: rawptr) -> []Agent_Message {
	f := cast(^Fake)userdata
	if f.steer_sent {
		return nil
	}
	f.steer_sent = true
	return f.steer
}

rig_follow :: proc(userdata: rawptr) -> []Agent_Message {
	f := cast(^Fake)userdata
	if f.follow_sent {
		return nil
	}
	f.follow_sent = true
	return f.follow
}

rig_block :: proc(call: ai.Tool_Call, userdata: rawptr) -> (bool, string) {
	f := cast(^Fake)userdata
	return f.block_tools, "blocked by test"
}

noop_emit :: proc(event: Event, userdata: rawptr) {}

new_rig :: proc(responses: []ai.Message, allocator: mem.Allocator) -> ^Fake {
	f := new(Fake, allocator)
	f.responses = responses
	f.allocator = allocator
	f.contexts = make([dynamic][]ai.Message, 0, 8, allocator)
	f.tools_ran = make([dynamic]string, 0, 8, allocator)
	return f
}

rig_ctx :: proc(f: ^Fake, allocator: mem.Allocator) -> (^Context, ^Loop_Config) {
	tools := make([]Tool_Definition, 1, allocator) // heap — stack literal would dangle past rig_ctx's return
	tools[0] = Tool_Definition {
		name            = "fake",
		description     = "test tool",
		parameters_json = `{"type":"object","properties":{}}`,
		execute         = rig_tool,
		userdata        = f,
	}
	ctx := new(Context, allocator)
	ctx.system_prompt = "test"
	ctx.tools = tools
	cfg := new(Loop_Config, allocator)
	cfg.model = ai.Model{id = "fake", data = rawptr(f)}
	cfg.stream = rig_stream
	cfg.get_steering = rig_steer
	cfg.get_follow_up = rig_follow
	cfg.before_tool_call = rig_block
	cfg.userdata = f
	return ctx, cfg
}

@(test)
test_tool_round_trip :: proc(t: ^testing.T) {
	f := new_rig([]ai.Message{
		{role = .Assistant, thinking = "trace", reasoning_details_json = `[{"type":"reasoning.encrypted","data":"opaque"}]`, tool_calls = {{id = "c1", name = "fake", arguments = `{}`}}, stop_reason = .Tool_Calls},
		{role = .Assistant, text = "done", stop_reason = .Stop},
	}, context.temp_allocator)
	ctx, cfg := rig_ctx(f, context.temp_allocator)
	cancel := ai.Cancellation{}

	err := run(ctx, cfg, {{role = .User, text = "go"}}, noop_emit, nil, &cancel, context.temp_allocator)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, len(f.tools_ran), 1)
	testing.expect_value(t, f.tools_ran[0], "c1")

	testing.expect(t, len(f.contexts) == 2, "expected two model calls")
	testing.expect_value(t, f.contexts[1][1].thinking, "trace")
	testing.expect_value(t, f.contexts[1][1].reasoning_details_json, `[{"type":"reasoning.encrypted","data":"opaque"}]`)
	last := f.contexts[1][len(f.contexts[1]) - 1]
	testing.expect_value(t, last.role, ai.Role.Tool)
	testing.expect_value(t, last.tool_call_id, "c1")
	testing.expect_value(t, last.text, "fake-out")
}

@(test)
test_steering_and_followup :: proc(t: ^testing.T) {
	f := new_rig([]ai.Message{
		{role = .Assistant, text = "ack", stop_reason = .Stop},
		{role = .Assistant, text = "done", stop_reason = .Stop},
	}, context.temp_allocator)
	f.steer = []Agent_Message{{role = .User, text = "steered"}}
	f.follow = []Agent_Message{{role = .User, text = "followed"}}
	ctx, cfg := rig_ctx(f, context.temp_allocator)
	cancel := ai.Cancellation{}

	err := run(ctx, cfg, {{role = .User, text = "go"}}, noop_emit, nil, &cancel, context.temp_allocator)
	testing.expect_value(t, err, Error.None)

	// steering drained before first generation → request 1 must contain it
	found_steer := false
	for m in f.contexts[0] {
		if m.text == "steered" {
			found_steer = true
		}
	}
	testing.expect(t, found_steer, "steering message must reach the model")

	// follow-up triggers a second call after the run would settle
	testing.expect(t, len(f.contexts) == 2, "expected second model call")
	found_follow := false
	for m in f.contexts[1] {
		if m.text == "followed" {
			found_follow = true
		}
	}
	testing.expect(t, found_follow, "follow-up message must reach the model")

	// the transcript records how each user message arrived and who answered
	for m in ctx.messages {
		switch m.role {
		case .User:
			want := Delivery.Prompt
			if m.text == "steered" { want = .Steer }
			if m.text == "followed" { want = .Follow_Up }
			testing.expect_value(t, m.delivery, want)
		case .Assistant:
			testing.expect_value(t, m.model, "fake")
		case .Tool_Result, .Bash_Execution, .Custom, .Branch_Summary, .Compaction_Summary:
		}
	}
}

@(test)
test_blocked_tool :: proc(t: ^testing.T) {
	f := new_rig([]ai.Message{
		{role = .Assistant, tool_calls = {{id = "c1", name = "fake", arguments = `{}`}}, stop_reason = .Tool_Calls},
		{role = .Assistant, text = "done", stop_reason = .Stop},
	}, context.temp_allocator)
	f.block_tools = true
	ctx, cfg := rig_ctx(f, context.temp_allocator)
	cancel := ai.Cancellation{}

	err := run(ctx, cfg, {{role = .User, text = "go"}}, noop_emit, nil, &cancel, context.temp_allocator)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, len(f.tools_ran), 0)
	last := f.contexts[1][len(f.contexts[1]) - 1]
	testing.expect_value(t, last.role, ai.Role.Tool)
	testing.expect_value(t, last.text, "blocked by test")
}

@(test)
test_abort :: proc(t: ^testing.T) {
	f := new_rig([]ai.Message{
		{role = .Assistant, text = "never", stop_reason = .Stop},
	}, context.temp_allocator)
	ctx, cfg := rig_ctx(f, context.temp_allocator)
	cancel := ai.Cancellation{}
	sync.atomic_store(&cancel.flag, true)

	err := run(ctx, cfg, {{role = .User, text = "go"}}, noop_emit, nil, &cancel, context.temp_allocator)
	testing.expect_value(t, err, Error.Aborted)
}

@(test)
test_failed_tool_stream_followup :: proc(t: ^testing.T) {
	reasons := []ai.Stop_Reason{.Error, .Aborted}
	for reason in reasons {
		usage := ai.Usage{input = 19, output = 7, total = 26, cost_usd = 0.01, cost_reported = true}
		f := new_rig([]ai.Message{
			{role = .Assistant, tool_calls = {{id = "complete", name = "fake", arguments = `{}`}}, stop_reason = .Tool_Calls},
			{role = .Assistant, thinking = "partial trace", tool_calls = {{id = "unfinished", name = "fake", arguments = `{"query":`}}, usage = usage, stop_reason = reason},
			{role = .Assistant, text = "recovered", stop_reason = .Stop},
		}, context.temp_allocator)
		ctx, cfg := rig_ctx(f, context.temp_allocator)
		cancel := ai.Cancellation{}

		err := run(ctx, cfg, {{role = .User, text = "go"}}, noop_emit, nil, &cancel, context.temp_allocator)
		testing.expect_value(t, err, reason == .Aborted ? Error.Aborted : Error.Stream_Failed)
		testing.expect_value(t, len(f.tools_ran), 1)
		testing.expect_value(t, f.tools_ran[0], "complete")
		failed := ctx.messages[len(ctx.messages) - 1]
		testing.expect_value(t, failed.stop_reason, reason)
		testing.expect_value(t, len(failed.tool_calls), 0)
		testing.expect_value(t, failed.thinking, "partial trace")
		testing.expect_value(t, failed.usage, usage)

		err = run(ctx, cfg, {{role = .User, text = "try again"}}, noop_emit, nil, &cancel, context.temp_allocator)
		testing.expect_value(t, err, Error.None)
		testing.expect_value(t, len(f.tools_ran), 1)
		testing.expect_value(t, len(f.contexts), 3)
		request := f.contexts[2]
		testing.expect_value(t, len(request[1].tool_calls), 1)
		testing.expect_value(t, request[1].tool_calls[0].id, "complete")
		testing.expect_value(t, request[2].role, ai.Role.Tool)
		testing.expect_value(t, request[2].tool_call_id, "complete")
		testing.expect_value(t, request[2].text, "fake-out")
		testing.expect_value(t, len(request[3].tool_calls), 0)
	}
}
