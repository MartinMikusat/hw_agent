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
import "core:thread"
import "core:time"
import devlog "devlog:."
import "core:unicode/utf8"

CURL_URL :: "https://openrouter.ai/api/v1/chat/completions"
MAX_SSE_LINE_BYTES :: 1 << 20
MAX_STREAM_BYTES :: 16 << 20
MAX_TOOL_CALLS :: 64

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
	pending: [MAX_TOOL_CALLS + 3]Event,
	pending_count: int,
	pending_cursor: int,
	text_buf: strings.Builder,
	thinking_buf: strings.Builder,
	reasoning_details: [dynamic]string,
	response_bytes: int,
	request_path: string,
	config_path: string,
	watcher: ^thread.Thread,
	watch_stop: bool,
	timed_out: bool,
	started_at: time.Tick,
	timeout: time.Duration,
	waited: bool,
	read_error: io.Error,
	// Dev log: cause is the stable reason of a failed stream (a source literal),
	// http_* the provider's error body, which --fail-with-body puts on stdout.
	cause: string,
	http_code: i32,
	http_message: string,
	trace: ^os.File, // nil unless provider_options.trace_dir is set
}

// MAX_ERROR_DETAIL bounds the provider message kept for replies and the dev log.
MAX_ERROR_DETAIL :: 300

is_cancelled :: proc(cancel: ^Cancellation) -> bool {
	if cancel == nil {
		return false
	}
	return sync.atomic_load(&cancel.flag)
}

response_schema_valid :: proc(source: string) -> bool {
	if len(source) > 64 * 1024 || !utf8.valid_string(source) {return false}
	tokenizer := json.make_tokenizer(source, spec = .JSON)
	depth, started, closed := 0, false, false
	for iteration in 0..=len(source) {
		token, error := json.get_token(&tokenizer)
		if error == .EOF || token.kind == .EOF {return started && closed && depth == 0}
		if error != .None || closed || !started && token.kind != .Open_Brace {return false}
		started = true
		if token.kind == .Open_Brace || token.kind == .Open_Bracket {depth += 1}
		if depth > 64 {return false}
		if token.kind == .Close_Brace || token.kind == .Close_Bracket {depth -= 1}
		if depth < 0 {return false}
		closed = depth == 0
	}
	return false
}

request_json :: proc(model: Model, ctx: Context, allocator: mem.Allocator) -> (string, Error) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	request_allocator := context.allocator
	response_schema: json.Value
	if model.response_schema_json != "" {
		if !response_schema_valid(model.response_schema_json) {return "", .Parse}
		parsed, parse_error := json.parse_string(model.response_schema_json, .JSON, false, request_allocator)
		if parse_error != nil {return "", .Parse}
		if _, object := parsed.(json.Object); !object {return "", .Parse}
		response_schema = parsed
	}

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
			if len(msg.thinking) > 0 {
				m["reasoning"] = json.String(strings.clone(msg.thinking))
			}
			if len(msg.reasoning_details_json) > 0 {
				details, perr := json.parse_string(msg.reasoning_details_json, .JSON, false, request_allocator)
				if perr != nil {
					return "", .Parse
				}
				if _, ok := details.(json.Array); !ok {
					return "", .Parse
				}
				m["reasoning_details"] = details
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
		schema, perr := json.parse_string(tool.parameters_json, .JSON, false, request_allocator)
		if perr != nil {
			return "", .Parse
		}
		if _, ok := schema.(json.Object); !ok {
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
	if model.response_schema_json != "" {
		schema := make(map[string]json.Value, 3)
		schema["name"] = json.String("agent_result")
		schema["strict"] = json.Boolean(true)
		schema["schema"] = response_schema
		format := make(map[string]json.Value, 2)
		format["type"] = json.String("json_schema")
		format["json_schema"] = json.Object(schema)
		root["response_format"] = json.Object(format)
	}
	if model.max_output > 0 {
		root["max_completion_tokens"] = json.Integer(model.max_output)
	}
	provider_options := model.provider_options
	if provider_options.require_parameters || provider_options.data_collection_deny || provider_options.zdr {
		provider := make(map[string]json.Value, 3)
		if provider_options.require_parameters {
			provider["require_parameters"] = json.Boolean(true)
		}
		if provider_options.data_collection_deny {
			provider["data_collection"] = json.String("deny")
		}
		if provider_options.zdr {
			provider["zdr"] = json.Boolean(true)
		}
		root["provider"] = json.Value(json.Object(provider))
	}
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
	handle, oerr := os.open(path, {.Write, .Create, .Excl}, os.perm(0o600))
	if oerr != nil {
		return "", oerr
	}
	defer os.close(handle)
	n, werr := os.write(handle, transmute([]u8)contents)
	if werr != nil || n != len(contents) {
		_ = os.remove(path)
		if werr == nil {
			werr = io.Error.Short_Write
		}
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
	stream: Stream,
	err: Error,
) {
	defer if err != nil && err != .Aborted {
		devlog.failed(devlog.global(), {feature = "provider", operation = "start"}, {reason = "provider request could not start", code = i32(err)})
	}
	assert(len(api_key) > 0, "stream_openai requires an API key")
	assert(len(model.id) > 0, "stream_openai requires a model id")
	if is_cancelled(cancel) {
		return {}, .Aborted
	}
	for c in api_key {
		if c < 0x20 || c == 0x7f || c == '"' || c == '\\' {
			return {}, .Parse
		}
	}
	if model.provider_options.timeout_ms < 0 || model.provider_options.timeout_ms > 86_400_000 {
		return {}, .Parse
	}
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	request_allocator := mem.dynamic_arena_allocator(&arena)
	retained := false

	body, berr := request_json(model, ctx, request_allocator)
	if berr != nil {
		return {}, berr
	}
	body_path, perr := write_temp_file(body, request_allocator)
	if perr != nil {
		return {}, .Transport
	}
	defer if !retained {
		remove_temp_file(body_path)
	}
	config := fmt.aprintf("header = \"Authorization: Bearer %s\"\n", api_key, allocator = request_allocator)
	config_path, cerr := write_temp_file(config, request_allocator)
	if cerr != nil {
		return {}, .Transport
	}
	defer if !retained {
		remove_temp_file(config_path)
	}

	stdout_r, stdout_w, pipe_err := os.pipe()
	if pipe_err != nil {
		return {}, .Transport
	}
	defer os.close(stdout_w)
	defer if !retained {
		os.close(stdout_r)
	}

	stderr_path := fmt.aprintf("%s.stderr", body_path, allocator = request_allocator)
	stderr_handle, serr := os.open(stderr_path, {.Write, .Create, .Excl}, os.perm(0o600))
	if serr != nil {
		return {}, .Transport
	}
	defer os.close(stderr_handle)
	defer if !retained {
		remove_temp_file(stderr_path)
	}

	data_arg := fmt.aprintf("@%s", body_path, allocator = request_allocator)
	endpoint := model.provider_options.endpoint
	if len(endpoint) == 0 {
		endpoint = CURL_URL
	}

	process, spawn_err := os.process_start(os.Process_Desc {
		command = {
			"curl",
			"-q",
			"--config",
			config_path,
			"-sS",
			"-N",
			"--fail-with-body",
			"-X",
			"POST",
			endpoint,
			"-H",
			"Content-Type: application/json",
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
	if spawn_err != nil {
		return {}, .Transport
	}

	impl := new(OpenAI_Stream, allocator)
	impl.process = process
	impl.pipe_out = stdout_r
	impl.stderr_log = strings.clone(stderr_path, allocator)
	impl.request_path = strings.clone(body_path, allocator)
	impl.config_path = strings.clone(config_path, allocator)
	impl.allocator = allocator
	impl.cancel = cancel
	impl.partial.role = .Assistant
	impl.reason = .None
	impl.started_at = time.tick_now()
	impl.timeout = time.Duration(model.provider_options.timeout_ms) * time.Millisecond
	bufio.reader_init(&impl.reader, os.to_reader(stdout_r), MAX_SSE_LINE_BYTES + 1, allocator)
	if cancel != nil || impl.timeout > 0 {
		impl.watcher = thread.create_and_start_with_data(impl, openai_watch)
		if impl.watcher == nil {
			_ = os.process_kill(process)
			_, _ = os.process_wait(process)
			bufio.reader_destroy(&impl.reader)
			free(impl, allocator)
			return {}, .Transport
		}
	}
	retained = true
	devlog.started(devlog.global(), {feature = "provider", operation = "stream"})
	if len(model.provider_options.trace_dir) > 0 {
		impl.trace = open_trace(model.provider_options.trace_dir, body)
	}

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
	if s.data == nil {
		return
	}
	impl := cast(^OpenAI_Stream)s.data
	stop_watcher(impl)
	if impl.pipe_out != nil {
		os.close(impl.pipe_out)
	}
	if !impl.waited {
		_ = os.process_kill(impl.process)
		_, _ = os.process_wait(impl.process)
	}
	bufio.reader_destroy(&impl.reader)
	if impl.trace != nil { os.close(impl.trace) }
	remove_temp_file(impl.request_path)
	remove_temp_file(impl.config_path)
	remove_temp_file(impl.stderr_log)
	free(impl, impl.allocator)
	s.data = nil
}

// open_trace creates <dir>/<unix-ms>-<n>.jsonl (owner-only) and writes the
// request body as its first line. Tracing is a debugging aid: a failure is
// recorded and the request proceeds untraced.
trace_counter: u64

open_trace :: proc(dir, body: string) -> ^os.File {
	if err := os.make_directory_all(dir, os.perm(0o700)); err != nil && !os.is_dir(dir) {
		devlog.failed(devlog.global(), {feature = "provider", operation = "trace"}, {reason = "trace directory could not be created", severity = .Warning})
		return nil
	}
	n := sync.atomic_add(&trace_counter, 1)
	path := fmt.tprintf("%s/%d-%d.jsonl", dir, time.to_unix_nanoseconds(time.now()) / 1e6, n)
	f, err := os.open(path, {.Write, .Create, .Excl}, os.perm(0o600))
	if err != nil {
		devlog.failed(devlog.global(), {feature = "provider", operation = "trace"}, {reason = "trace file could not be created", severity = .Warning})
		return nil
	}
	_, _ = os.write_string(f, body)
	_, _ = os.write_string(f, "\n")
	return f
}

remove_temp_file :: proc(path: string) {
	if err := os.remove(path); err != nil {
		fmt.eprintfln("hw_agent: cannot remove temporary file %s: %v", path, err)
	}
}

openai_watch :: proc(data: rawptr) {
	impl := cast(^OpenAI_Stream)data
	for !sync.atomic_load(&impl.watch_stop) {
		if is_cancelled(impl.cancel) {
			_ = os.process_kill(impl.process)
			return
		}
		if impl.timeout > 0 && time.tick_since(impl.started_at) >= impl.timeout {
			sync.atomic_store(&impl.timed_out, true)
			_ = os.process_kill(impl.process)
			return
		}
		time.sleep(10 * time.Millisecond)
	}
}

stop_watcher :: proc(impl: ^OpenAI_Stream) {
	sync.atomic_store(&impl.watch_stop, true)
	if impl.watcher != nil {
		thread.join(impl.watcher)
		thread.destroy(impl.watcher)
		impl.watcher = nil
	}
}

// Pull one logical line from the buffered pipe reader. bufio.Reader keeps
// returning the leftover bytes after EOF, then reports .EOF with an empty
// line on the next call, so no extra drain bookkeeping is needed here.
next_line :: proc(impl: ^OpenAI_Stream) -> (line: string, ok: bool) {
	raw, err := bufio.reader_read_slice(&impl.reader, '\n')
	if err != nil && err != .EOF {
		impl.read_error = err
		return "", false
	}
	if len(raw) == 0 {
		return "", false
	}
	return strings.trim_right(string(raw), "\r\n"), true
}

// openai_stream_next records each request's outcome in the dev log once, at the
// stream's terminal event.
openai_stream_next :: proc(s: ^Stream) -> (Event, bool) {
	impl := cast(^OpenAI_Stream)s.data
	was_emitted := impl.emitted
	event, ok := stream_next(s)
	if !ok || was_emitted || !impl.emitted { return event, ok }
	site := devlog.Site{feature = "provider", operation = "stream"}
	metrics := devlog.Metrics{duration_ms = i64(time.duration_milliseconds(time.tick_since(impl.started_at)))}
	switch {
	case event.kind == .Done:
		devlog.succeeded(devlog.global(), site, metrics = metrics)
	case event.reason == .Aborted:
		devlog.stopped(devlog.global(), site, metrics = metrics)
	case:
		devlog.failed(devlog.global(), site, {reason = impl.cause, detail = impl.http_message, code = impl.http_code})
	}
	return event, ok
}

stream_next :: proc(s: ^Stream) -> (Event, bool) {
	impl := cast(^OpenAI_Stream)s.data
	if impl.emitted {
		return {}, false
	}
	if is_cancelled(impl.cancel) {
		impl.emitted = true
		return stream_error(impl, "aborted", .Aborted), true
	}
	if event, has := next_pending(impl); has {
		return event, true
	}

	for {
		line, has_line := next_line(impl)
		if !has_line {
			impl.emitted = true
			if is_cancelled(impl.cancel) {
				return stream_error(impl, "aborted", .Aborted), true
			}
			if sync.atomic_load(&impl.timed_out) {
				return stream_error(impl, "provider request timed out"), true
			}
			if impl.read_error != nil {
				return stream_error(impl, "provider response read failed or exceeded line limit"), true
			}
			stop_watcher(impl)
			state, wait_err := os.process_wait(impl.process)
			impl.waited = wait_err == nil
			if wait_err != nil {
				return stream_error(impl, "cannot wait for provider process"), true
			}
			if state.exit_code != 0 {
				if impl.http_code != 0 {
					impl.cause = "provider rejected the request"
					msg := fmt.aprintf("provider error %d: %s", impl.http_code, impl.http_message, allocator = impl.allocator)
					return stream_error(impl, msg), true
				}
				impl.cause = "provider process failed"
				impl.http_code = i32(state.exit_code)
				msg := fmt.aprintf("curl exited %d", state.exit_code, allocator = impl.allocator)
				return stream_error(impl, msg), true
			}
			return stream_error(impl, "provider stream ended without [DONE]"), true
		}
		if len(os.get_env("HW_DEBUG", context.temp_allocator)) > 0 {
			fmt.eprintfln("[sse] %s", line)
		}
		if impl.trace != nil {
			_, _ = os.write_string(impl.trace, line)
			_, _ = os.write_string(impl.trace, "\n")
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
	if len(impl.reasoning_details) > 0 {
		b := strings.builder_make(impl.allocator)
		strings.write_string(&b, "[")
		for detail, i in impl.reasoning_details {
			if i > 0 {
				strings.write_string(&b, ",")
			}
			strings.write_string(&b, detail)
		}
		strings.write_string(&b, "]")
		impl.partial.reasoning_details_json = strings.to_string(b)
	}
	impl.final = impl.partial
}

next_pending :: proc(impl: ^OpenAI_Stream) -> (Event, bool) {
	if impl.pending_cursor >= impl.pending_count {
		impl.pending_cursor = 0
		impl.pending_count = 0
		return {}, false
	}
	event := impl.pending[impl.pending_cursor]
	impl.pending_cursor += 1
	return event, true
}

queue_delta :: proc(impl: ^OpenAI_Stream, kind: Event_Kind, text: string) {
	assert(impl.pending_count < len(impl.pending))
	impl.pending[impl.pending_count] = Event {
		kind = kind,
		text = strings.clone(text, impl.allocator),
		partial = &impl.partial,
	}
	impl.pending_count += 1
}

// stream_error ends the stream. Call sites pass literal text, which doubles as
// the dev-log cause unless the site set impl.cause to a literal first.
stream_error :: proc(impl: ^OpenAI_Stream, text: string, reason: Stop_Reason = .Error) -> Event {
	if len(impl.cause) == 0 { impl.cause = text }
	finalize_partial(impl)
	impl.final.stop_reason = reason
	impl.final.usage = impl.usage
	impl.final.usage.complete = false
	return Event {kind = .Error, text = text, reason = reason, partial = &impl.final}
}

// capture_http_error keeps the {"error":{"message","code"}} body of a rejected
// request, which arrives outside the SSE framing.
capture_http_error :: proc(impl: ^OpenAI_Stream, line: string) {
	value, perr := json.parse_string(line, .JSON, false, impl.allocator)
	if perr != nil { return }
	defer json.destroy_value(value, impl.allocator)
	obj, _ := value.(json.Object)
	err_obj, is_err := obj["error"].(json.Object)
	if !is_err { return }
	msg, _ := err_obj["message"].(json.String)
	impl.http_message = strings.clone(string(msg)[:min(len(msg), MAX_ERROR_DETAIL)], impl.allocator)
	#partial switch code in err_obj["code"] {
	case json.Integer: impl.http_code = i32(code)
	case json.Float:   impl.http_code = i32(code)
	}
	if impl.http_code == 0 { impl.http_code = -1 }
}

handle_sse_line :: proc(impl: ^OpenAI_Stream, line: string) -> (Event, bool) {
	context.allocator = impl.allocator
	assert(impl.pending_cursor == impl.pending_count)
	impl.pending_cursor = 0
	impl.pending_count = 0
	if len(line) > MAX_SSE_LINE_BYTES || len(line) > MAX_STREAM_BYTES - impl.response_bytes {
		return stream_error(impl, "provider response exceeded byte limit"), true
	}
	impl.response_bytes += len(line)
	if len(line) == 0 || line[0] == ':' {
		return {}, false
	}
	if !strings.has_prefix(line, "data:") {
		if strings.has_prefix(line, "{") { capture_http_error(impl, line) }
		return {}, false
	}
	data := strings.trim_space(line[5:])
	if data == "[DONE]" {
		for call, i in impl.call_meta {
			if len(call.id) == 0 || len(call.name) == 0 {
				return stream_error(impl, "incomplete provider tool call"), true
			}
			for previous in impl.call_meta[:i] {
				if previous.id == call.id {
					return stream_error(impl, "duplicate provider tool-call id"), true
				}
			}
		}
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
		return stream_error(impl, "malformed SSE chunk"), true
	}
	defer json.destroy_value(value, impl.allocator)
	obj, is_obj := value.(json.Object)
	if !is_obj {
		return {}, false
	}

	if usage_v, has := obj["usage"]; has {
		if usage_obj, uok := usage_v.(json.Object); uok {
			input, has_input := usage_token_count(usage_obj["prompt_tokens"])
			output, has_output := usage_token_count(usage_obj["completion_tokens"])
			total, has_total := usage_token_count(usage_obj["total_tokens"])
			impl.usage.input = input
			impl.usage.output = output
			impl.usage.total = total
			impl.usage.complete = has_input && has_output && has_total
			if cost, has := usage_obj["cost"]; has {
				#partial switch n in cost {
				case json.Float:
					if n >= 0 && n <= 1_000_000 {
						impl.usage.cost_usd = f64(n)
						impl.usage.cost_reported = true
					}
				case json.Integer:
					if n >= 0 && n <= 1_000_000 {
						impl.usage.cost_usd = f64(n)
						impl.usage.cost_reported = true
					}
				}
			}
		}
	}

	if err_v, has := obj["error"]; has {
		if err_obj, eok := err_v.(json.Object); eok {
			msg := "provider error"
			if s, sok := err_obj["message"].(json.String); sok {
				msg = string(s)
			}
			impl.cause = "provider reported a stream error"
			impl.http_message = strings.clone(msg[:min(len(msg), MAX_ERROR_DETAIL)], impl.allocator)
			return stream_error(impl, strings.clone(msg, impl.allocator)), true
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
			if len(impl.partial.text) == 0 {
				impl.text_buf = strings.builder_make(impl.allocator)
			}
			strings.write_string(&impl.text_buf, string(s))
			impl.partial.text = strings.to_string(impl.text_buf)
			queue_delta(impl, .Text_Delta, string(s))
		}
	}

	if rv, has := delta["reasoning"]; has {
		if s, sok := rv.(json.String); sok && len(s) > 0 {
			if len(impl.partial.thinking) == 0 {
				impl.thinking_buf = strings.builder_make(impl.allocator)
			}
			strings.write_string(&impl.thinking_buf, string(s))
			impl.partial.thinking = strings.to_string(impl.thinking_buf)
			queue_delta(impl, .Thinking_Delta, string(s))
		}
	}
	if rv, has := delta["reasoning_content"]; has {
		if _, has_reasoning := delta["reasoning"]; !has_reasoning {
			if s, sok := rv.(json.String); sok && len(s) > 0 {
				if len(impl.partial.thinking) == 0 {
					impl.thinking_buf = strings.builder_make(impl.allocator)
				}
				strings.write_string(&impl.thinking_buf, string(s))
				impl.partial.thinking = strings.to_string(impl.thinking_buf)
				queue_delta(impl, .Thinking_Delta, string(s))
			}
		}
	}
	if rdv, has := delta["reasoning_details"]; has {
		if details, aok := rdv.(json.Array); aok {
			for detail in details {
				text, uerr := json.unparse(detail, {}, impl.allocator)
				if uerr != nil {
					return stream_error(impl, "malformed reasoning details"), true
				}
				append(&impl.reasoning_details, text)
			}
		}
	}

	if tcv, has := delta["tool_calls"]; has {
		if arr, aok := tcv.(json.Array); aok {
			if len(arr) > MAX_TOOL_CALLS {
				return stream_error(impl, "provider tool-call count exceeded limit"), true
			}
			for item in arr {
				tc, tok := item.(json.Object)
				if !tok {
					continue
				}
				idx, valid_index := tool_call_index(tc["index"])
				if !valid_index {
					return stream_error(impl, "invalid provider tool-call index"), true
				}
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
								queue_delta(impl, .Tool_Call_Delta, string(s))
							}
						}
					}
				}
			}
		}
	}

	return next_pending(impl)
}

tool_call_index :: proc(value: json.Value) -> (int, bool) {
	#partial switch n in value {
	case json.Integer:
		if n >= 0 && n < MAX_TOOL_CALLS {
			return int(n), true
		}
	case json.Float:
		if n >= 0 && n < MAX_TOOL_CALLS && json.Float(int(n)) == n {
			return int(n), true
		}
	}
	return 0, false
}

usage_token_count :: proc(value: json.Value) -> (int, bool) {
	#partial switch n in value {
	case json.Integer:
		if n >= 0 && n <= 1_000_000_000 {
			return int(n), true
		}
	case json.Float:
		if n >= 0 && n <= 1_000_000_000 && json.Float(int(n)) == n {
			return int(n), true
		}
	}
	return 0, false
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
