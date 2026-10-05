package tools

// find_files / grep / multi_grep: fff-mcp's tools, run in-process on the
// session's shared fff index. Names, descriptions and schemas come from fff.

import "core:encoding/json"
import "core:strings"

import "../agent"
import "../ai"
import "../fff"

Search_Tool_State :: struct {
	index: fff.Index,
	name:  string,
}

// search_tools opens (or reuses) the fff index covering working_dir and returns
// its tools; nil when the index cannot be opened (recorded in the dev log).
search_tools :: proc(working_dir: string, allocator := context.allocator) -> []agent.Tool_Definition {
	index, ok := fff.index_for(working_dir)
	if !ok { return nil }
	Tool :: struct {
		name:         string,
		description:  string,
		input_schema: json.Value `json:"inputSchema"`,
	}
	defs: []Tool
	if json.unmarshal_string(fff.tools_json(context.temp_allocator), &defs, allocator = context.temp_allocator) != nil { return nil }
	list := make([dynamic]agent.Tool_Definition, 0, len(defs), allocator)
	for d in defs {
		schema, _ := json.marshal(d.input_schema, {}, allocator)
		state := new(Search_Tool_State, allocator)
		state^ = {index = index, name = strings.clone(d.name, allocator)}
		append(&list, agent.Tool_Definition {
			name            = state.name,
			description     = strings.clone(d.description, allocator),
			parameters_json = string(schema),
			execute         = search_execute,
			userdata        = state,
		})
	}
	return list[:]
}

search_execute :: proc(
	call_id: string,
	args: json.Value,
	cancel: ^ai.Cancellation,
	on_update: proc(text: string, userdata: rawptr),
	userdata: rawptr,
) -> agent.Tool_Result {
	state := cast(^Search_Tool_State)userdata
	encoded, err := json.marshal(args, {}, context.temp_allocator)
	if err != nil {
		return {text = "invalid arguments", is_error = true}
	}
	text, is_error := fff.call(state.index, state.name, string(encoded))
	return {text = text, is_error = is_error}
}
