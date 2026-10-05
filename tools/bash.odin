package tools

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import devlog "devlog:."

import "../agent"
import "../ai"

Bash_Tool_State :: struct {
	working_dir: string,
}

BASH_SCHEMA :: `{
	"type": "object",
	"properties": {
		"command": {"type": "string", "description": "The bash command to execute"},
		"timeout": {"type": "number", "description": "Optional timeout in seconds"}
	},
	"required": ["command"]
}`

bash_tool :: proc(working_dir: string, allocator := context.allocator) -> agent.Tool_Definition {
	state := new(Bash_Tool_State, allocator)
	state.working_dir = strings.clone(working_dir, allocator)
	return agent.Tool_Definition {
		name = "bash",
		description = "Execute a bash command and return its combined stdout/stderr output.",
		parameters_json = BASH_SCHEMA,
		execute = bash_execute,
		userdata = state,
	}
}

bash_execute :: proc(
	call_id: string,
	args: json.Value,
	cancel: ^ai.Cancellation,
	on_update: proc(text: string, userdata: rawptr),
	userdata: rawptr,
) -> agent.Tool_Result {
	state := cast(^Bash_Tool_State)userdata
	assert(state != nil)

	obj, ok := args.(json.Object)
	if !ok {
		return {text = "arguments must be an object", is_error = true}
	}
	command, cok := obj["command"].(json.String)
	if !cok || len(command) == 0 {
		return {text = `missing required argument "command"`, is_error = true}
	}

	// ponytail: no timeout enforcement yet — the loop's cancel flag is the only
	// interrupt. Add a deadline watcher when parallel tool threads land.
	started := time.tick_now()
	defer devlog.sample_since(devlog.global(), {feature = "tools", operation = "bash"}, started)
	proc_state, stdout, stderr, err := os.process_exec(os.Process_Desc {
		command = {"bash", "-c", string(command)},
		working_dir = state.working_dir,
	}, context.allocator)
	if err != nil {
		devlog.failed(devlog.global(), {feature = "tools", operation = "bash"}, {reason = "bash could not be started"})
		return {text = fmt.tprintf("failed to spawn bash: %v", err), is_error = true}
	}
	out := strings.builder_make()
	strings.write_string(&out, string(stdout))
	strings.write_string(&out, string(stderr))
	text := strings.to_string(out)
	if len(strings.trim_space(text)) == 0 {
		text = "(no output)"
	}
	if proc_state.exit_code != 0 {
		return {
			text = fmt.tprintf("%s\n[exit %d]", text, proc_state.exit_code),
			is_error = true,
		}
	}
	return {text = text}
}
