package ai

import "core:mem"

// Wire-level types shared by provider adapters. Provider-neutral where
// practical; the shape follows the OpenAI chat-completions model since
// OpenRouter is the default transport.

Stop_Reason :: enum {
	None,
	Stop,
	Length,
	Tool_Calls,
	Error,
	Aborted,
}

Usage :: struct {
	input:  int,
	output: int,
	total:  int, // provider-reported total incl. cache; 0 when unreported
	cost_usd: f64,
	cost_reported: bool,
	complete: bool,
}

Role :: enum {
	System,
	User,
	Assistant,
	Tool,
}

Tool_Call :: struct {
	id:        string,
	name:      string,
	arguments: string, // raw JSON text
}

Message :: struct {
	role:         Role,
	text:         string,        // assembled text content
	thinking:     string,        // assembled reasoning content, when reported
	reasoning_details_json: string,
	tool_calls:   []Tool_Call,   // role == .Assistant
	tool_call_id: string,        // role == .Tool
	usage:        Usage,         // role == .Assistant, set on done
	stop_reason:  Stop_Reason,   // role == .Assistant
}

Tool_Definition :: struct {
	name:            string,
	description:     string,
	parameters_json: string, // JSON Schema object as text
}

Context :: struct {
	system_prompt: string,
	messages:      []Message,
	tools:         []Tool_Definition,
}

Model :: struct {
	id:             string,
	context_window: int,
	max_output:     int,
	data:           rawptr, // provider- or caller-specific routing hint
	provider_options: Provider_Options,
}

Provider_Options :: struct {
	require_parameters: bool,
	data_collection_deny: bool,
	zdr: bool,
	timeout_ms: int,
	endpoint: string, // trusted caller configuration; empty uses OpenRouter
}

Error :: enum {
	None,
	Transport, // process/IO failure
	HTTP,      // non-2xx response
	Parse,     // malformed stream data
	Aborted,
}

Event_Kind :: enum {
	Start,
	Text_Delta,
	Thinking_Delta,
	Tool_Call_Delta,
	Done,
	Error,
}

Event :: struct {
	kind:    Event_Kind,
	text:    string,      // delta text, or error message on .Error
	partial: ^Message,    // assistant message assembled so far; valid until the next call
	usage:   Usage,       // valid on .Done when the provider reports it
	reason:  Stop_Reason, // valid on .Done/.Error
}

// Proc-table iterator over a provider response stream.
// next returns ok=false once the stream is exhausted or a terminal
// event (.Done/.Error) has been delivered.
Stream :: struct {
	data:   rawptr,
	next:   proc(s: ^Stream) -> (Event, bool),
	result: proc(s: ^Stream) -> Message, // final assembled assistant message
	close:  proc(s: ^Stream),
}

// Cancellation checked at stream/tool boundaries. The flag is atomic because
// writers live on other threads (UI, RPC reader).
Cancellation :: struct {
	flag: bool,
}

Stream_Fn :: proc(
	model: Model,
	ctx: Context,
	api_key: string,
	cancel: ^Cancellation,
	allocator: mem.Allocator,
) -> (
	Stream,
	Error,
)
