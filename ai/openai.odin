package ai

// OpenAI-compatible streaming over `curl -N` (SSE via child process).
// ponytail: one curl process per request, error granularity is exit status +
// stderr file. Upgrade path is a real HTTP/TLS client behind the same
// Stream_Fn signature; nothing else changes.

import "core:bufio"
import "core:encoding/json"
import "core:fmt"
import "core:io"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"

CURL_URL :: "https://openrouter.ai/api/v1/chat/completions"

OpenAI_Stream :: struct {
	process:    os.Process,
	pipe_out:   ^os.File,
	reader:     bufio.Reader,
	stderr_log: string,
	partial:    Message,
	arg_bufs:   [dynamic]strings.Builder, // tool-call argument assembly, by index
	call_meta:  [dynamic]Tool_Call,       // id/name for each in-flight tool call
	final:      Message,
	reason:     Stop_Reason,
	usage:      Usage,
	emitted:    bool, // terminal event delivered
	allocator:  mem.Allocator,
	cancel:     ^Cancellation,
}

is_cancelled :: proc(cancel: ^Cancellation) -> bool {
	if cancel == nil {
		return false
	}
	return sync.atomic_load(&cancel.flag)
}

request_json :: proc(model: Model, ctx: Context, allocator: mem.Allocator) -> (string, Error) {
	context.allocator = allocator

	messages := make([dynamic]json.Value, 0, len(ctx.messages) + 1)
	if len(ctx.system_prompt) > 0 {
		m := make(map[string]json.Value, 2)
		m["role"] = json.String("system")
		m["content"] = json.String(strings.clone(ctx.system_prompt))
		append(&messages, json.Value(json.Object(m)))
	}
	for msg in ctx.messages {
		m := make(map[string]json.Value, 4)
		switch msg.role {
		case .System:
			m["role"] = json.String("system")
			m["content"] = json.String(strings.clone(msg.text))
		case .User:
			m["role"] = json.String("user")
			m["content"] = json.String(strings.clone(msg.text))
		case .Assistant:
			m["role"] = json.String("assistant")
			if len(msg.text) > 0 {
				m["content"] = json.String(strings.clone(msg.text))
			}
			if len(msg.tool_calls) > 0 {
				calls := make([dynamic]json.Value, 0, len(msg.tool_calls))
				for call in msg.tool_calls {
					fn := make(map[string]json.Value, 2)
					fn["name"] = json.String(strings.clone(call.name))
					fn["arguments"] = json.String(strings.clone(call.arguments))
					c := make(map[string]json.Value, 3)
					c["id"] = json.String(strings.clone(call.id))
					c["type"] = json.String("function")
					c["function"] = json.Value(json.Object(fn))
					append(&calls, json.Value(json.Object(c)))
				}
				m["tool_calls"] = json.Value(json.Array(calls))
			}
		case .Tool:
			m["role"] = json.String("tool")
			m["tool_call_id"] = json.String(strings.clone(msg.tool_call_id))
			m["content"] = json.String(strings.clone(msg.text))
		}
		append(&messages, json.Value(json.Object(m)))
	}

	tools := make([dynamic]json.Value, 0, len(ctx.tools))
	for tool in ctx.tools {
		schema, perr := json.parse_string(tool.parameters_json, .JSON, false, allocator)
		if perr != nil {
			return "", .Parse
		}
		fn := make(map[string]json.Value, 3)
		fn["name"] = json.String(strings.clone(tool.name))
		fn["description"] = json.String(strings.clone(tool.description))
		fn["parameters"] = schema
		t := make(map[string]json.Value, 2)
		t["type"] = json.String("function")
		t["function"] = json.Value(json.Object(fn))
		append(&tools, json.Value(json.Object(t)))
	}

	root := make(map[string]json.Value, 5)
	root["model"] = json.String(strings.clone(model.id))
	root["stream"] = json.Boolean(true)
	opts := make(map[string]json.Value, 1)
	opts["include_usage"] = json.Boolean(true)
	root["stream_options"] = json.Value(json.Object(opts))
	root["messages"] = json.Value(json.Array(messages))
	if len(ctx.tools) > 0 {
		root["tools"] = json.Value(json.Array(tools))
	}

	text, uerr := json.unparse(json.Value(json.Object(root)), {}, allocator)
	if uerr != nil {
		return "", .Parse
	}
	return text, nil
}

write_temp_file :: proc(contents: string, allocator: mem.Allocator) -> (path: string, err: os.Error) {
	dir := os.get_env("TMPDIR", allocator)
	if len(dir) == 0 {
		dir = "/tmp"
	}
	path = fmt.aprintf(
		"%s/hw_agent_req_%d_%d.json",
		strings.trim_right(dir, "/"),
		os.get_pid(),
		time.to_unix_nanoseconds(time.now()),
		allocator = allocator,
	)
	handle, oerr := os.open(path, {.Write, .Create, .Trunc}, os.perm(0o600))
	if oerr != nil {
		return "", oerr
	}
	defer os.close(handle)
	_, werr := os.write(handle, transmute([]u8)contents)
	if werr != nil {
		return "", werr
	}
	return path, nil
}

stream_openai :: proc(
	model: Model,
	ctx: Context,
	api_key: string,
	cancel: ^Cancellation,
	allocator: mem.Allocator,
) -> (
	Stream,
	Error,
) {
	assert(len(api_key) > 0, "stream_openai requires an API key")
	assert(len(model.id) > 0, "stream_openai requires a model id")

	body, berr := request_json(model, ctx, allocator)
	if berr != nil {
		return {}, berr
	}
	body_path, perr := write_temp_file(body, allocator)
	if perr != nil {
		return {}, .Transport
	}

	stdout_r, stdout_w, pipe_err := os.pipe()
	if pipe_err != nil {
		return {}, .Transport
	}

	stderr_path := fmt.aprintf("%s.stderr", body_path, allocator = allocator)
	stderr_handle, serr := os.open(stderr_path, {.Write, .Create, .Trunc}, os.perm(0o600))
	if serr != nil {
		os.close(stdout_r)
		os.close(stdout_w)
		return {}, .Transport
	}

	auth_header := fmt.aprintf("Authorization: Bearer %s", api_key, allocator = allocator)
	data_arg := fmt.aprintf("@%s", body_path, allocator = allocator)

	process, spawn_err := os.process_start(os.Process_Desc {
		command = {
			"curl",
			"-sS",
			"-N",
			"--fail-with-body",
			"-X",
			"POST",
			CURL_URL,
			"-H",
			"Content-Type: application/json",
			"-H",
			auth_header,
			"-H",
			"HTTP-Referer: https://github.com/MartinMikusat/hw_agent",
			"-H",
			"X-Title: hw_agent",
			"--data-binary",
			data_arg,
		},
		stdout = stdout_w,
		stderr = stderr_handle,
	})
	os.close(stdout_w)
	os.close(stderr_handle)
	if spawn_err != nil {
		os.close(stdout_r)
		return {}, .Transport
	}

	impl := new(OpenAI_Stream, allocator)
	impl.process = process
	impl.pipe_out = stdout_r
	impl.stderr_log = stderr_path
	impl.allocator = allocator
	impl.cancel = cancel
	impl.partial.role = .Assistant
	impl.reason = .None
	bufio.reader_init(&impl.reader, os.to_reader(stdout_r))

	return Stream {
		data = impl,
		next = openai_stream_next,
		result = openai_stream_result,
		close = openai_stream_close,
	}, nil
}

openai_stream_result :: proc(s: ^Stream) -> Message {
	impl := cast(^OpenAI_Stream)s.data
	return impl.final
}

openai_stream_close :: proc(s: ^Stream) {
	impl := cast(^OpenAI_Stream)s.data
	if impl.pipe_out != nil {
		os.close(impl.pipe_out)
	}
	_ = os.process_kill(impl.process)
	_, _ = os.process_wait(impl.process)
}

// Pull one logical line from the buffered pipe reader. bufio.Reader keeps
// returning the leftover bytes after EOF, then reports .EOF with an empty
// line on the next call, so no extra drain bookkeeping is needed here.
next_line :: proc(impl: ^OpenAI_Stream) -> (line: string, ok: bool) {
	raw, _ := bufio.reader_read_string(&impl.reader, '\n', impl.allocator)
	if len(raw) == 0 {
		return "", false
	}
	return strings.trim_right(raw, "\r\n"), true
}

openai_stream_next :: proc(s: ^Stream) -> (Event, bool) {
	impl := cast(^OpenAI_Stream)s.data
	if impl.emitted {
		return {}, false
	}
	if is_cancelled(impl.cancel) {
		impl.emitted = true
		finalize_partial(impl)
		impl.final.stop_reason = .Aborted
		return Event{kind = .Error, text = "aborted", reason = .Aborted, partial = &impl.final}, true
	}

	for {
		line, has_line := next_line(impl)
		if !has_line {
			state, _ := os.process_wait(impl.process)
			impl.emitted = true
			finalize_partial(impl)
			if state.exit_code != 0 {
				impl.final.stop_reason = .Error
				msg := fmt.aprintf(
					"curl exited %d (stderr: %s)",
					state.exit_code,
					impl.stderr_log,
					allocator = impl.allocator,
				)
				return Event{kind = .Error, text = msg, reason = .Error, partial = &impl.final}, true
			}
			if impl.reason == .None {
				impl.reason = .Stop
			}
			impl.final.stop_reason = impl.reason
			impl.final.usage = impl.usage
			return Event {
				kind = .Done,
				reason = impl.final.stop_reason,
				usage = impl.usage,
				partial = &impl.final,
			}, true
		}
		if len(os.get_env("HW_DEBUG", context.temp_allocator)) > 0 {
			fmt.eprintfln("[sse] %s", line)
		}
		event, has := handle_sse_line(impl, line)
		if has {
			if event.kind == .Done || event.kind == .Error {
				impl.emitted = true
			}
			return event, true
		}
	}
}

finalize_partial :: proc(impl: ^OpenAI_Stream) {
	if len(impl.call_meta) > 0 {
		calls := make([]Tool_Call, len(impl.call_meta), impl.allocator)
		for meta, i in impl.call_meta {
			calls[i] = meta
			calls[i].arguments = strings.to_string(impl.arg_bufs[i])
		}
		impl.partial.tool_calls = calls
	}
	impl.final = impl.partial
}

handle_sse_line :: proc(impl: ^OpenAI_Stream, line: string) -> (Event, bool) {
	if len(line) == 0 || line[0] == ':' {
		return {}, false
	}
	if !strings.has_prefix(line, "data:") {
		return {}, false
	}
	data := strings.trim_space(line[5:])
	if data == "[DONE]" {
		finalize_partial(impl)
		if impl.reason == .None {
			impl.reason = .Stop
		}
		impl.final.stop_reason = impl.reason
		impl.final.usage = impl.usage
		return Event {
			kind = .Done,
			reason = impl.final.stop_reason,
			usage = impl.usage,
			partial = &impl.final,
		}, true
	}

	value, perr := json.parse_string(data, .JSON, false, impl.allocator)
	if perr != nil {
		return Event{kind = .Error, text = "malformed SSE chunk", reason = .Error}, true
	}
	obj, is_obj := value.(json.Object)
	if !is_obj {
		return {}, false
	}

	if usage_v, has := obj["usage"]; has {
		if usage_obj, uok := usage_v.(json.Object); uok {
			impl.usage.input = json_int(usage_obj["prompt_tokens"])
			impl.usage.output = json_int(usage_obj["completion_tokens"])
			impl.usage.total = json_int(usage_obj["total_tokens"])
		}
	}

	if err_v, has := obj["error"]; has {
		if err_obj, eok := err_v.(json.Object); eok {
			msg := "provider error"
			if s, sok := err_obj["message"].(json.String); sok {
				msg = string(s)
			}
			return Event {
				kind = .Error,
				text = strings.clone(msg, impl.allocator),
				reason = .Error,
			}, true
		}
	}

	choices_v, has_choices := obj["choices"]
	if !has_choices {
		return {}, false
	}
	choices, arr_ok := choices_v.(json.Array)
	if !arr_ok || len(choices) == 0 {
		return {}, false
	}
	choice, ch_ok := choices[0].(json.Object)
	if !ch_ok {
		return {}, false
	}

	if fr, has := choice["finish_reason"]; has {
		if s, sok := fr.(json.String); sok {
			impl.reason = map_finish_reason(string(s))
		}
	}

	delta_v, has_delta := choice["delta"]
	if !has_delta {
		return {}, false
	}
	delta, d_ok := delta_v.(json.Object)
	if !d_ok {
		return {}, false
	}

	if cv, has := delta["content"]; has {
		if s, sok := cv.(json.String); sok && len(s) > 0 {
			b := strings.builder_make(impl.allocator)
			strings.write_string(&b, impl.partial.text)
			strings.write_string(&b, string(s))
			impl.partial.text = strings.to_string(b)
			return Event {
				kind = .Text_Delta,
				text = string(s),
				partial = &impl.partial,
			}, true
		}
	}

	if rv, has := delta["reasoning"]; has {
		if s, sok := rv.(json.String); sok && len(s) > 0 {
			b := strings.builder_make(impl.allocator)
			strings.write_string(&b, impl.partial.thinking)
			strings.write_string(&b, string(s))
			impl.partial.thinking = strings.to_string(b)
			return Event {
				kind = .Thinking_Delta,
				text = string(s),
				partial = &impl.partial,
			}, true
		}
	}

	if tcv, has := delta["tool_calls"]; has {
		if arr, aok := tcv.(json.Array); aok {
			for item in arr {
				tc, tok := item.(json.Object)
				if !tok {
					continue
				}
				idx := json_int(tc["index"])
				for len(impl.call_meta) <= idx {
					append(&impl.call_meta, Tool_Call{})
					append(&impl.arg_bufs, strings.builder_make(impl.allocator))
				}
				meta := &impl.call_meta[idx]
				if idv, has := tc["id"]; has {
					if s, sok := idv.(json.String); sok {
						meta.id = strings.clone(string(s), impl.allocator)
					}
				}
				if fnv, has := tc["function"]; has {
					if fn, fok := fnv.(json.Object); fok {
						if nv, has := fn["name"]; has {
							if s, sok := nv.(json.String); sok {
								meta.name = strings.clone(string(s), impl.allocator)
							}
						}
						if av, has := fn["arguments"]; has {
							if s, sok := av.(json.String); sok {
								strings.write_string(&impl.arg_bufs[idx], string(s))
								return Event {
									kind = .Tool_Call_Delta,
									text = string(s),
									partial = &impl.partial,
								}, true
							}
						}
					}
				}
			}
		}
	}

	return {}, false
}

json_int :: proc(v: json.Value) -> int {
	#partial switch n in v {
	case json.Integer:
		return int(n)
	case json.Float:
		return int(n)
	}
	return 0
}

map_finish_reason :: proc(s: string) -> Stop_Reason {
	switch s {
	case "stop":
		return .Stop
	case "length":
		return .Length
	case "tool_calls":
		return .Tool_Calls
	case "error":
		return .Error
	}
	return .Stop
}
