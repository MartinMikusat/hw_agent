package main

// Print mode: `hw_agent "<prompt>" [-model=<id>]`
// Streams the run to stdout — text deltas raw, tool boundaries marked.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

import "agent"
import "ai"
import "compact"
import "rpc"
import "session"
import "tools"

DEFAULT_MODEL :: "anthropic/claude-haiku-4.5"
DEFAULT_CONTEXT_WINDOW :: 200_000

SYSTEM_PROMPT :: `You are a coding agent running inside hw_agent, a minimal harness.
Use the bash tool to inspect the environment and complete the user's task.
Be concise.`

main :: proc() {
	model_id := DEFAULT_MODEL
	session_path := ""
	prompt := ""
	rpc_mode := false
	for arg in os.args[1:] {
		if arg == "-rpc" {
			rpc_mode = true
		} else if strings.has_prefix(arg, "-model=") {
			model_id = arg[7:]
		} else if strings.has_prefix(arg, "-session=") {
			session_path = arg[9:]
		} else if len(arg) > 0 {
			if len(prompt) > 0 {
				prompt = fmt.tprintf("%s %s", prompt, arg)
			} else {
				prompt = arg
			}
		}
	}
	if len(prompt) == 0 && !rpc_mode {
		fmt.eprintln("usage: hw_agent \"<prompt>\" [-model=<id>] [-session=<path>]\n       hw_agent -rpc [-model=<id>] [-session=<path>]")
		os.exit(1)
	}

	api_key := os.get_env("OPENROUTER_API_KEY", context.allocator)
	if len(api_key) == 0 {
		fmt.eprintln("no OpenRouter API key: set OPENROUTER_API_KEY")
		os.exit(1)
	}

	cwd, _ := os.get_working_directory(context.allocator)
	file_state := tools.file_tool_state(cwd)
	tool_list := []agent.Tool_Definition {
		tools.bash_tool(cwd),
		tools.read_tool(file_state),
		tools.write_tool(file_state),
		tools.edit_tool(file_state),
	}

	ctx := agent.Context {
		system_prompt = SYSTEM_PROMPT,
		tools = tool_list,
	}
	cfg := agent.Loop_Config {
		model = ai.Model {
			id = model_id,
			context_window = DEFAULT_CONTEXT_WINDOW,
			max_output = 16_000,
		},
		stream = ai.stream_openai,
		api_key = api_key,
		compact = compact.maybe_compact,
		transform_context = compact.prune,
	}
	cancel := ai.Cancellation{}

	sink := rpc_mode ? agent.Emit(rpc.emit_json) : agent.Emit(print_sink)
	emit := sink
	emit_userdata: rawptr = nil
	sess: ^session.Session
	defer if sess != nil { session.close(sess) }
	sess_wrap: session.Emit_Session
	if len(session_path) > 0 {
		messages: []agent.Agent_Message
		serr: os.Error
		sess, messages, serr = session.open(session_path, context.allocator)
		if serr != nil {
			fmt.eprintfln("session open failed: %v", serr)
			os.exit(1)
		}
		if len(messages) > 0 {
			if !rpc_mode {
				fmt.printfln("[resumed %s — %d prior messages]", session_path, len(messages))
			}
			for m in messages {
				append(&ctx.messages, m)
			}
		}
		sess_wrap = session.Emit_Session{session = sess, inner = sink}
		emit = session.emit
		emit_userdata = &sess_wrap
	}

	if rpc_mode {
		rpc.serve(&ctx, &cfg, emit, emit_userdata, &cancel, context.allocator)
		return
	}

	prompts := []agent.Agent_Message{{
		role = .User,
		text = prompt,
		timestamp = time.to_unix_seconds(time.now()),
	}}
	err := agent.run(&ctx, &cfg, prompts, emit, emit_userdata, &cancel, context.allocator)
	fmt.println()
	if err != nil {
		fmt.eprintfln("run failed: %v", err)
		os.exit(1)
	}
}

print_sink :: proc(event: agent.Event, userdata: rawptr) {
	switch e in event {
	case agent.Event_Agent_Start:
	case agent.Event_Agent_End:
	case agent.Event_Turn_Start:
	case agent.Event_Message_Start:
	case agent.Event_Message_Update:
		_ = e
	case agent.Event_Message_End:
		if len(e.message.text) > 0 {
			fmt.printfln("%s", e.message.text)
		}
	case agent.Event_Tool_Start:
		fmt.printfln("\n$ %s %s", e.name, e.arguments)
	case agent.Event_Tool_End:
		status := "ok"
		if e.is_error {
			status = "err"
		}
		fmt.printfln("[%s] %s", status, e.text)
	case agent.Event_Turn_End:
	case agent.Event_Compaction:
		fmt.printfln("\n[compacted — %d tokens before, kept %d messages]", e.data.tokens_before, len(e.data.tail))
	}
}
