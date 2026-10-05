package agent

// The agent loop, mirroring pi's agent-loop.ts: an inner loop over tool
// calls and steering messages inside an outer loop that drains the
// follow-up queue when the run would otherwise settle.

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import "../ai"
import "../textutil"

TOOL_OUTPUT_MAX_CHARS :: 30_000
MAX_TURNS :: 200 // hard bound on inner iterations per run; defensive, not a feature

Error :: enum {
	None,
	Stream_Failed,
	Aborted,
	Overturned, // hit MAX_TURNS
}

run :: proc(
	ctx: ^Context,
	cfg: ^Loop_Config,
	prompts: []Agent_Message,
	emit: Emit,
	emit_userdata: rawptr,
	cancel: ^ai.Cancellation,
	allocator: mem.Allocator,
) -> Error {
	assert(ctx != nil)
	assert(cfg != nil && cfg.stream != nil)
	if ctx.messages.allocator.procedure == nil {
		ctx.messages.allocator = allocator
	}
	for p in prompts {
		assert(p.role == .User || p.role == .Custom)
	}

	for p in prompts {
		msg := p
		msg.text = textutil.scrub(msg.text, allocator)
		if msg.timestamp == 0 { msg.timestamp = time.to_unix_seconds(time.now()) }
		append(&ctx.messages, msg)
		emit(Event_Message_Start{message = &ctx.messages[len(ctx.messages) - 1]}, emit_userdata)
		emit(Event_Message_End{message = &ctx.messages[len(ctx.messages) - 1]}, emit_userdata)
	}

	emit(Event_Agent_Start{}, emit_userdata)
	emit(Event_Turn_Start{}, emit_userdata)

	pending := mark(drain(cfg.get_steering, cfg.userdata, allocator), .Steer)
	turns := 0
	for {
		has_more := true
		for has_more || len(pending) > 0 {
			turns += 1
			if turns > MAX_TURNS {
				emit(Event_Agent_End{}, emit_userdata)
				return .Overturned
			}
			for p in pending {
				msg := p
				msg.text = textutil.scrub(msg.text, allocator)
				if msg.timestamp == 0 { msg.timestamp = time.to_unix_seconds(time.now()) }
				append(&ctx.messages, msg)
				emit(Event_Message_Start{message = &ctx.messages[len(ctx.messages) - 1]}, emit_userdata)
				emit(Event_Message_End{message = &ctx.messages[len(ctx.messages) - 1]}, emit_userdata)
			}
			pending = nil

			msg_index, stream_err := stream_assistant(ctx, cfg, emit, emit_userdata, cancel, allocator)
			if stream_err != nil {
				emit(Event_Agent_End{}, emit_userdata)
				return stream_err
			}
			msg := &ctx.messages[msg_index]
			if msg.stop_reason == .Error || msg.stop_reason == .Aborted {
				emit(Event_Turn_End{message = msg}, emit_userdata)
				emit(Event_Agent_End{}, emit_userdata)
				return msg.stop_reason == .Aborted ? .Aborted : .Stream_Failed
			}

			has_more = false
			if len(msg.tool_calls) > 0 {
				if msg.stop_reason == .Length {
					// Truncated output can mean truncated tool arguments; fail
					// every call instead of executing possibly-borked input.
					for call in msg.tool_calls {
						emit(Event_Tool_Start{id = call.id, name = call.name, arguments = call.arguments}, emit_userdata)
						text := fmt.aprintf(
							`Tool call "%s" was not executed: the response hit the output token limit, so its arguments may be truncated. Re-issue the tool call with complete arguments.`,
							call.name,
							allocator = allocator,
						)
						append_result(ctx, call.id, text, true)
						emit(Event_Tool_End{id = call.id, name = call.name, text = text, is_error = true}, emit_userdata)
					}
					has_more = true
				} else {
					has_more = execute_tool_calls(ctx, msg, cfg, emit, emit_userdata, cancel, allocator)
				}
			}

			msg = &ctx.messages[msg_index]
			emit(Event_Turn_End{message = msg}, emit_userdata)
			if cfg.should_stop != nil && cfg.should_stop(cfg.userdata) {
				emit(Event_Agent_End{}, emit_userdata)
				return nil
			}
			pending = mark(drain(cfg.get_steering, cfg.userdata, allocator), .Steer)
			if len(pending) > 0 || has_more {
				emit(Event_Turn_Start{}, emit_userdata)
			}
		}

		follow_up := mark(drain(cfg.get_follow_up, cfg.userdata, allocator), .Follow_Up)
		if len(follow_up) == 0 {
			break
		}
		pending = follow_up
		emit(Event_Turn_Start{}, emit_userdata)
	}

	emit(Event_Agent_End{}, emit_userdata)
	return nil
}

mark :: proc(messages: []Agent_Message, delivery: Delivery) -> []Agent_Message {
	for &m in messages {
		if m.role == .User { m.delivery = delivery }
	}
	return messages
}

drain :: proc(get: proc(rawptr) -> []Agent_Message, userdata: rawptr, allocator: mem.Allocator) -> []Agent_Message {
	if get == nil {
		return nil
	}
	return get(userdata)
}

// Stream one assistant response, updating the in-context partial message.
// Returns the index of the finalized message in ctx.messages.
// Proactive compaction runs before each attempt; a provider-side context
// overflow compacts once and retries.
stream_assistant :: proc(
	ctx: ^Context,
	cfg: ^Loop_Config,
	emit: Emit,
	emit_userdata: rawptr,
	cancel: ^ai.Cancellation,
	allocator: mem.Allocator,
) -> (
	int,
	Error,
) {
	// The assistant message is appended lazily on the first stream event —
	// keeping it out of ctx.messages until then means compaction and context
	// transforms never see an empty placeholder, and on overflow retry we can
	// simply drop the partial before compacting.
	idx := -1
	started := false
	overflow_retried := false

	for {
		if cfg.compact != nil {
			if data := cfg.compact(ctx, cfg, cfg.userdata); data != nil {
				emit(Event_Compaction{data = data}, emit_userdata)
			}
		}

		messages := ctx.messages[:]
		if cfg.transform_context != nil {
			messages = cfg.transform_context(messages, cfg.userdata)
		}
		llm_messages := convert_to_llm(messages, allocator)
		llm_ctx := ai.Context {
			system_prompt = ctx.system_prompt,
			messages = llm_messages,
		}
		tool_defs := make([dynamic]ai.Tool_Definition, 0, len(ctx.tools), allocator)
		for t in ctx.tools {
			append(&tool_defs, ai.Tool_Definition {
				name = t.name,
				description = t.description,
				parameters_json = t.parameters_json,
			})
		}
		llm_ctx.tools = tool_defs[:]

		attempt_started := time.tick_now()
		stream, serr := cfg.stream(cfg.model, llm_ctx, cfg.api_key, cancel, allocator)
		if serr != nil {
			return -1, serr == .Aborted ? .Aborted : .Stream_Failed
		}

		retry := false
		finished := false
		for {
			ev, ok := stream.next(&stream)
			if !ok {
				finished = true
				break
			}
			switch ev.kind {
			case .Start:
			case .Text_Delta, .Thinking_Delta, .Tool_Call_Delta:
				if idx < 0 {
					append(&ctx.messages, Agent_Message {
						role = .Assistant,
						timestamp = time.to_unix_seconds(time.now()),
					})
					idx = len(ctx.messages) - 1
				}
				sync_partial(&ctx.messages[idx], ev.partial)
				if !started {
					started = true
					emit(Event_Message_Start{message = &ctx.messages[idx]}, emit_userdata)
				}
				emit(Event_Message_Update{message = &ctx.messages[idx]}, emit_userdata)
			case .Done:
				if idx < 0 {
					append(&ctx.messages, Agent_Message {
						role = .Assistant,
						timestamp = time.to_unix_seconds(time.now()),
					})
					idx = len(ctx.messages) - 1
				}
				final := stream.result(&stream)
				ctx.messages[idx] = assistant_from_wire(final, ctx.messages[idx].timestamp)
				stamp(&ctx.messages[idx], cfg, attempt_started)
				if !started {
					emit(Event_Message_Start{message = &ctx.messages[idx]}, emit_userdata)
				}
				emit(Event_Message_End{message = &ctx.messages[idx]}, emit_userdata)
				finished = true
			case .Error:
				// ponytail: overflow detected by substring — providers phrase
				// it differently ("context length", "maximum tokens"). One
				// retry; a second overflow fails the turn.
				if !overflow_retried && cfg.compact != nil && strings.contains(ev.text, "context") {
					overflow_retried = true
					retry = true
					break
				}
				if idx < 0 {
					append(&ctx.messages, Agent_Message {
						role = .Assistant,
						timestamp = time.to_unix_seconds(time.now()),
					})
					idx = len(ctx.messages) - 1
				}
				if ev.partial != nil {
					sync_partial(&ctx.messages[idx], ev.partial)
					ctx.messages[idx].usage = ev.partial.usage
				}
				ctx.messages[idx].stop_reason = ev.reason == .Aborted ? .Aborted : .Error
				ctx.messages[idx].tool_calls = nil
				ctx.messages[idx].text = ev.text
				stamp(&ctx.messages[idx], cfg, attempt_started)
				if !started {
					emit(Event_Message_Start{message = &ctx.messages[idx]}, emit_userdata)
				}
				emit(Event_Message_End{message = &ctx.messages[idx]}, emit_userdata)
				finished = true
			}
			if finished || retry {
				break
			}
		}
		stream.close(&stream)

		if retry {
			if idx >= 0 {
				assert(idx == len(ctx.messages) - 1)
				_ = pop(&ctx.messages)
				idx = -1
				started = false
			}
			continue
		}
		if !finished {
			// stream ended without a terminal event — treat what we have as final
			if idx < 0 {
				append(&ctx.messages, Agent_Message {
					role = .Assistant,
					timestamp = time.to_unix_seconds(time.now()),
				})
				idx = len(ctx.messages) - 1
			}
			final := stream.result(&stream)
			ctx.messages[idx] = assistant_from_wire(final, ctx.messages[idx].timestamp)
			stamp(&ctx.messages[idx], cfg, attempt_started)
			if !started {
				emit(Event_Message_Start{message = &ctx.messages[idx]}, emit_userdata)
			}
			emit(Event_Message_End{message = &ctx.messages[idx]}, emit_userdata)
		}
		return idx, nil
	}
}

// stamp records which model answered and how long the request took.
stamp :: proc(msg: ^Agent_Message, cfg: ^Loop_Config, started: time.Tick) {
	msg.model = cfg.model.id
	msg.duration_ms = i64(time.duration_milliseconds(time.tick_since(started)))
}

sync_partial :: proc(dst: ^Agent_Message, src: ^ai.Message) {
	dst.text = src.text
	dst.thinking = src.thinking
	dst.reasoning_details_json = src.reasoning_details_json
	dst.tool_calls = src.tool_calls
}

append_result :: proc(ctx: ^Context, call_id: string, text: string, is_error: bool, duration_ms: i64 = 0) {
	append(&ctx.messages, Agent_Message {
		role = .Tool_Result,
		tool_call_id = call_id,
		text = text,
		is_error = is_error,
		duration_ms = duration_ms,
		timestamp = time.to_unix_seconds(time.now()),
	})
}

Tool_Job :: struct {
	tool:   ^Tool_Definition, // nil => result already filled (unresolved/blocked)
	call:   ai.Tool_Call,
	cancel: ^ai.Cancellation,
	wg:     ^sync.Wait_Group,
	result: Tool_Result,
}

tool_worker :: proc(data: rawptr) {
	job := cast(^Tool_Job)data
	defer sync.wait_group_done(job.wg)
	job.result = run_tool(job.tool, job.call, job.cancel, context.allocator)
}

execute_tool_calls :: proc(
	ctx: ^Context,
	msg: ^Agent_Message,
	cfg: ^Loop_Config,
	emit: Emit,
	emit_userdata: rawptr,
	cancel: ^ai.Cancellation,
	allocator: mem.Allocator,
) -> bool {
	calls := msg.tool_calls
	jobs := make([]Tool_Job, len(calls), allocator)

	// Resolve and permission-check on the loop thread; runnable calls get a
	// tool pointer, everything else gets its (error) result up front.
	runnable := 0
	for call, i in calls {
		jobs[i] = Tool_Job{call = call, cancel = cancel}
		tool: ^Tool_Definition
		for &t in ctx.tools {
			if t.name == call.name {
				tool = &t
				break
			}
		}
		if tool == nil {
			jobs[i].result = Tool_Result {
				text     = fmt.aprintf("Tool %s not found", call.name, allocator = allocator),
				is_error = true,
			}
			continue
		}
		if cfg.before_tool_call != nil {
			block, reason := cfg.before_tool_call(call, cfg.userdata)
			if block {
				jobs[i].result = Tool_Result {
					text     = len(reason) > 0 ? reason : "Tool execution was blocked",
					is_error = true,
				}
				continue
			}
		}
		jobs[i].tool = tool
		runnable += 1
	}

	// Parallel only when the whole batch opts in — any `sequential` tool or a
	// pending cancel keeps the in-order path.
	parallel := runnable > 1 && !ai.is_cancelled(cancel)
	for &job in jobs {
		if job.tool != nil && job.tool.sequential {
			parallel = false
		}
	}

	if parallel {
		for &job in jobs {
			emit(Event_Tool_Start{id = job.call.id, name = job.call.name, arguments = job.call.arguments}, emit_userdata)
		}
		wg: sync.Wait_Group
		for &job in jobs {
			if job.tool == nil {
				continue
			}
			job.wg = &wg
			sync.wait_group_add(&wg, 1)
			thread.run_with_data(&job, tool_worker)
		}
		sync.wait_group_wait(&wg)
		// ponytail: the loop cannot interrupt a running tool thread; a tool must
		// watch cancel itself (bash does, and stops its process group).
	} else {
		for &job in jobs {
			emit(Event_Tool_Start{id = job.call.id, name = job.call.name, arguments = job.call.arguments}, emit_userdata)
			if job.tool != nil {
				if ai.is_cancelled(cancel) {
					job.result = Tool_Result{text = "aborted", is_error = true}
				} else {
					job.result = run_tool(job.tool, job.call, cancel, allocator)
				}
			}
			append_result(ctx, job.call.id, job.result.text, job.result.is_error, job.result.duration_ms)
			emit(Event_Tool_End{id = job.call.id, name = job.call.name, text = job.result.text, is_error = job.result.is_error, duration_ms = job.result.duration_ms}, emit_userdata)
		}
		return all_continue(jobs)
	}

	has_more := true
	for &job in jobs {
		if job.result.terminate {
			has_more = false
		}
		append_result(ctx, job.call.id, job.result.text, job.result.is_error, job.result.duration_ms)
		emit(Event_Tool_End{id = job.call.id, name = job.call.name, text = job.result.text, is_error = job.result.is_error, duration_ms = job.result.duration_ms}, emit_userdata)
	}
	return has_more
}

all_continue :: proc(jobs: []Tool_Job) -> bool {
	for &job in jobs {
		if job.result.terminate {
			return false
		}
	}
	return true
}

// run_tool executes one call. A tool may return text from the temp allocator
// (a worker thread's is freed when it exits); the result is always copied to
// allocator, made valid UTF-8 and capped on a character boundary here.
run_tool :: proc(tool: ^Tool_Definition, call: ai.Tool_Call, cancel: ^ai.Cancellation, allocator: mem.Allocator) -> Tool_Result {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	args, perr := json.parse_string(call.arguments, .JSON, false, context.temp_allocator)
	if perr != nil {
		return Tool_Result{text = fmt.aprintf("Invalid tool arguments: %v", perr, allocator = allocator), is_error = true}
	}
	started := time.tick_now()
	result := tool.execute(call.id, args, cancel, nil, tool.userdata)
	result.duration_ms = i64(time.duration_milliseconds(time.tick_since(started)))
	output_limit := tool.max_output_bytes > 0 ? tool.max_output_bytes : TOOL_OUTPUT_MAX_CHARS
	if len(result.text) > output_limit {
		kept := textutil.scrub(textutil.cut(result.text, output_limit), context.temp_allocator)
		result.text = fmt.aprintf("%s\n[output truncated at %d chars]", kept, output_limit, allocator = allocator)
	} else {
		result.text = textutil.clean(result.text, allocator)
	}
	return result
}
