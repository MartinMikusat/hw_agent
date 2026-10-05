package tools

// File tools: read / write / edit, all resolved against a fixed working dir.
// edit is exact-string replacement; old_string must occur exactly once unless
// replace_all is set — every occurrence is replaced.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

import "../agent"
import "../ai"

File_Tool_State :: struct {
	working_dir: string,
}

READ_SCHEMA :: `{
	"type": "object",
	"properties": {
		"path": {"type": "string", "description": "File path, absolute or relative to the working directory"},
		"offset": {"type": "number", "description": "1-based line to start from (default 1)"},
		"limit": {"type": "number", "description": "Maximum number of lines to return"}
	},
	"required": ["path"]
}`

WRITE_SCHEMA :: `{
	"type": "object",
	"properties": {
		"path": {"type": "string", "description": "File path, absolute or relative to the working directory"},
		"content": {"type": "string", "description": "Complete file content to write"}
	},
	"required": ["path", "content"]
}`

EDIT_SCHEMA :: `{
	"type": "object",
	"properties": {
		"path": {"type": "string", "description": "File path, absolute or relative to the working directory"},
		"old_string": {"type": "string", "description": "Exact text to replace; must occur exactly once unless replace_all is set"},
		"new_string": {"type": "string", "description": "Replacement text"},
		"replace_all": {"type": "boolean", "description": "Replace every occurrence of old_string"}
	},
	"required": ["path", "old_string", "new_string"]
}`

file_tool_state :: proc(working_dir: string, allocator := context.allocator) -> ^File_Tool_State {
	state := new(File_Tool_State, allocator)
	state.working_dir = strings.clone(working_dir, allocator)
	return state
}

read_tool :: proc(state: ^File_Tool_State) -> agent.Tool_Definition {
	return {
		name = "read",
		description = "Read a file's contents as numbered lines.",
		parameters_json = READ_SCHEMA,
		execute = read_execute,
		userdata = state,
	}
}

write_tool :: proc(state: ^File_Tool_State) -> agent.Tool_Definition {
	return {
		name = "write",
		description = "Write a file, creating parent directories as needed.",
		parameters_json = WRITE_SCHEMA,
		sequential = true,
		execute = write_execute,
		userdata = state,
	}
}

edit_tool :: proc(state: ^File_Tool_State) -> agent.Tool_Definition {
	return {
		name = "edit",
		description = "Replace exact text in a file.",
		parameters_json = EDIT_SCHEMA,
		sequential = true,
		execute = edit_execute,
		userdata = state,
	}
}

MAX_READ_BYTES :: 16 * 1024 * 1024

// read_file reads a whole file into temp memory, refusing one too large to hold.
read_file :: proc(path: string) -> (data: []u8, err: string) {
	handle, open_error := os.open(path)
	if open_error != nil { return nil, fmt.tprintf("%v", open_error) }
	size, size_error := os.file_size(handle)
	os.close(handle)
	if size_error != nil { return nil, fmt.tprintf("%v", size_error) }
	if size > MAX_READ_BYTES {
		return nil, fmt.tprintf("the file is %d bytes, over the %d byte limit; use bash (head, sed -n, grep) for part of it", size, MAX_READ_BYTES)
	}
	contents, read_error := os.read_entire_file(path, context.temp_allocator)
	if read_error != nil { return nil, fmt.tprintf("%v", read_error) }
	return contents, ""
}

resolve_path :: proc(state: ^File_Tool_State, path: string) -> string {
	if len(path) == 0 {
		return ""
	}
	if strings.has_prefix(path, "/") {
		return path
	}
	return fmt.tprintf("%s/%s", strings.trim_right(state.working_dir, "/"), path)
}

json_str :: proc(obj: json.Object, key: string) -> (string, bool) {
	v, has := obj[key]
	if !has {
		return "", false
	}
	s, ok := v.(json.String)
	return string(s), ok
}

json_num :: proc(obj: json.Object, key: string) -> (int, bool) {
	v, has := obj[key]
	if !has {
		return 0, false
	}
	#partial switch n in v {
	case json.Integer:
		return int(n), true
	case json.Float:
		return int(n), true
	}
	return 0, false
}

json_bool :: proc(obj: json.Object, key: string) -> bool {
	v, has := obj[key]
	if !has {
		return false
	}
	b, ok := v.(json.Boolean)
	return ok && bool(b)
}

read_execute :: proc(
	call_id: string,
	args: json.Value,
	cancel: ^ai.Cancellation,
	on_update: proc(text: string, userdata: rawptr),
	userdata: rawptr,
) -> agent.Tool_Result {
	state := cast(^File_Tool_State)userdata
	obj, ok := args.(json.Object)
	if !ok {
		return {text = "arguments must be an object", is_error = true}
	}
	path, pok := json_str(obj, "path")
	if !pok || len(path) == 0 {
		return {text = `missing required argument "path"`, is_error = true}
	}
	full := resolve_path(state, path)
	data, rerr := read_file(full)
	if rerr != "" {
		return {text = fmt.tprintf("cannot read %s: %s", path, rerr), is_error = true}
	}

	text := string(data)
	offset, _ := json_num(obj, "offset")
	limit, has_limit := json_num(obj, "limit")
	if offset <= 0 && !has_limit {
		return {text = text}
	}

	lines := strings.split_lines(text, context.temp_allocator)
	start := max(offset - 1, 0)
	if start >= len(lines) {
		return {text = fmt.tprintf("offset %d past end of file (%d lines)", offset, len(lines)), is_error = true}
	}
	end := len(lines)
	if has_limit && limit > 0 {
		end = min(start + limit, end)
	}
	out := strings.builder_make(context.temp_allocator)
	for line, i in lines[start:end] {
		strings.write_string(&out, fmt.tprintf("%d\t%s\n", start + i + 1, line))
	}
	return {text = strings.to_string(out)}
}

write_execute :: proc(
	call_id: string,
	args: json.Value,
	cancel: ^ai.Cancellation,
	on_update: proc(text: string, userdata: rawptr),
	userdata: rawptr,
) -> agent.Tool_Result {
	state := cast(^File_Tool_State)userdata
	obj, ok := args.(json.Object)
	if !ok {
		return {text = "arguments must be an object", is_error = true}
	}
	path, pok := json_str(obj, "path")
	content, cok := json_str(obj, "content")
	if !pok || len(path) == 0 {
		return {text = `missing required argument "path"`, is_error = true}
	}
	if !cok {
		return {text = `missing required argument "content"`, is_error = true}
	}
	full := resolve_path(state, path)
	if dir := dir_of(full); len(dir) > 0 && !os.is_dir(dir) {
		if merr := os.make_directory_all(dir, os.perm(0o755)); merr != nil {
			return {text = fmt.tprintf("cannot create %s: %v", dir, merr), is_error = true}
		}
	}
	if werr := os.write_entire_file(full, transmute([]u8)content); werr != nil {
		return {text = fmt.tprintf("cannot write %s: %v", path, werr), is_error = true}
	}
	return {text = fmt.tprintf("wrote %s (%d bytes)", path, len(content))}
}

edit_execute :: proc(
	call_id: string,
	args: json.Value,
	cancel: ^ai.Cancellation,
	on_update: proc(text: string, userdata: rawptr),
	userdata: rawptr,
) -> agent.Tool_Result {
	state := cast(^File_Tool_State)userdata
	obj, ok := args.(json.Object)
	if !ok {
		return {text = "arguments must be an object", is_error = true}
	}
	path, pok := json_str(obj, "path")
	old_s, ook := json_str(obj, "old_string")
	new_s, _ := json_str(obj, "new_string")
	if !pok || len(path) == 0 {
		return {text = `missing required argument "path"`, is_error = true}
	}
	if !ook || len(old_s) == 0 {
		return {text = `missing required argument "old_string"`, is_error = true}
	}
	full := resolve_path(state, path)
	data, rerr := read_file(full)
	if rerr != "" {
		return {text = fmt.tprintf("cannot read %s: %s", path, rerr), is_error = true}
	}
	text := string(data)
	count := strings.count(text, old_s)
	replace_all := json_bool(obj, "replace_all")
	if count == 0 {
		return {text = fmt.tprintf("old_string not found in %s", path), is_error = true}
	}
	if count > 1 && !replace_all {
		return {
			text = fmt.tprintf("old_string occurs %d times in %s; pass replace_all or a more specific string", count, path),
			is_error = true,
		}
	}
	n := replace_all ? -1 : 1
	replaced, _ := strings.replace(text, old_s, new_s, n, context.temp_allocator)
	if werr := os.write_entire_file(full, transmute([]u8)replaced); werr != nil {
		return {text = fmt.tprintf("cannot write %s: %v", path, werr), is_error = true}
	}
	return {text = fmt.tprintf("edited %s (%d replacement%s)", path, replace_all ? count : 1, replace_all && count > 1 ? "s" : "")}
}

dir_of :: proc(path: string) -> string {
	idx := strings.last_index(path, "/")
	if idx <= 0 {
		return ""
	}
	return path[:idx]
}
