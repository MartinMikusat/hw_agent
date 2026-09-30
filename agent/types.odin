package agent

import "core:encoding/json"

import "../ai"

// Harness-level message model: a superset of the provider wire shape.
// convert_to_llm folds the harness-only roles into user-role text at the
// provider boundary, so the loop never thinks in provider dialect.

Agent_Role :: enum {
	User,
	Assistant,
	Tool_Result,
	Bash_Execution,
	Custom,
	Branch_Summary,
	Compaction_Summary,
}

Agent_Message :: struct {
	role:         Agent_Role,
	text:         string,          // user text, tool output, summary text, bash output
	thinking:     string,          // assistant reasoning content
	reasoning_details_json: string,
	tool_calls:   []ai.Tool_Call,  // role == .Assistant
	tool_call_id: string,          // role == .Tool_Result
	is_error:     bool,            // role == .Tool_Result
	usage:        ai.Usage,        // role == .Assistant
	stop_reason:  ai.Stop_Reason,  // role == .Assistant
	timestamp:    i64,             // unix seconds
}

Context :: struct {
	system_prompt: string,
	messages:      [dynamic]Agent_Message,
	tools:         []Tool_Definition,
}

Tool_Definition :: struct {
	name:            string,
	description:     string,
	parameters_json: string, // JSON Schema object as text
	sequential:      bool,   // force sequential execution within a batch
	max_output_bytes: int,
	execute:         proc(
		call_id: string,
		args: json.Value,
		cancel: ^ai.Cancellation,
		on_update: proc(text: string, userdata: rawptr),
		userdata: rawptr,
	) -> Tool_Result,
	userdata:        rawptr,
}

Tool_Result :: struct {
	text:      string,
	is_error:  bool,
	terminate: bool, // tool asks the loop to stop after this batch
}

Event :: union {
	Event_Agent_Start,
	Event_Turn_Start,
	Event_Message_Start,
	Event_Message_Update,
	Event_Message_End,
	Event_Tool_Start,
	Event_Tool_End,
	Event_Turn_End,
	Event_Agent_End,
	Event_Compaction,
}

// What a compaction produced — enough for the session log to persist it
// self-contained (pi-style: the retained tail travels with the entry so
// replay doesn't need seq bookkeeping).
Compaction :: struct {
	summary:        string,
	tokens_before:  int,
	files_read:     []string,
	files_modified: []string,
	tail:           []Agent_Message,
}

Event_Agent_Start :: struct {}
Event_Agent_End :: struct {}
Event_Turn_Start :: struct {}

Event_Compaction :: struct {
	data: ^Compaction,
}

Event_Turn_End :: struct {
	message: ^Agent_Message, // into ctx.messages; valid during the callback
}

Event_Message_Start :: struct {
	message: ^Agent_Message,
}

Event_Message_Update :: struct {
	message: ^Agent_Message,
}

Event_Message_End :: struct {
	message: ^Agent_Message,
}

Event_Tool_Start :: struct {
	id:        string,
	name:      string,
	arguments: string,
}

Event_Tool_End :: struct {
	id:       string,
	name:     string,
	text:     string,
	is_error: bool,
}

Emit :: proc(event: Event, userdata: rawptr)

// Extension points mirroring pi's AgentLoopConfig.
Loop_Config :: struct {
	model:             ai.Model,
	stream:            ai.Stream_Fn,
	api_key:           string,
	get_steering:      proc(userdata: rawptr) -> []Agent_Message,  // drained before each generation
	get_follow_up:     proc(userdata: rawptr) -> []Agent_Message,  // drained when the run would settle
	before_tool_call:  proc(call: ai.Tool_Call, userdata: rawptr) -> (block: bool, reason: string),
	transform_context: proc(messages: []Agent_Message, userdata: rawptr) -> []Agent_Message,
	compact:           proc(ctx: ^Context, cfg: ^Loop_Config, userdata: rawptr) -> ^Compaction, // nil = no compaction needed/done
	should_stop:       proc(userdata: rawptr) -> bool,             // checked after each turn
	userdata:          rawptr,
}
