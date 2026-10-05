package main

// Print mode: `hw_agent "<prompt>" [-model=<id>]`
// Streams the run to stdout — text deltas raw, tool boundaries marked.

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:time"

import "agent"
import "ai"
import "compact"
import "keychain"
import "rpc"
import "session"
import "tools"

DEFAULT_MODEL :: "deepseek/deepseek-v4.1-flash"
DEFAULT_CONTEXT_WINDOW :: 1_000_000

SYSTEM_PROMPT :: `You are a coding agent running inside hw_agent, a minimal harness.
Use the bash tool to inspect the environment and complete the user's task.
Be concise.`

USAGE :: `usage: hw_agent "<prompt>" [-model=<id>] [-session=<path>]
       hw_agent -rpc [-model=<id>] [-session=<path>]
       hw_agent -serve [-model=<id>]       shared daemon on the agent socket
       hw_agent -login                     store the OpenRouter key in the Keychain
       hw_agent -install [-model=<id>]     LaunchAgent for -serve
       hw_agent -uninstall`

API_KEY_ENV :: "OPENROUTER_API_KEY"

main :: proc() {
	model_id := DEFAULT_MODEL
	session_path := ""
	prompt := ""
	rpc_mode := false
	mode := ""
	for arg in os.args[1:] {
		if arg == "-rpc" {
			rpc_mode = true
		} else if arg == "-serve" || arg == "-install" || arg == "-uninstall" || arg == "-login" {
			mode = arg
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
	switch mode {
	case "-install":
		os.exit(install(model_id))
	case "-login":
		os.exit(login())
	case "-uninstall":
		os.exit(uninstall())
	}
	if len(prompt) == 0 && !rpc_mode && mode == "" {
		fmt.eprintln(USAGE)
		os.exit(1)
	}

	api_key := os.get_env(API_KEY_ENV, context.allocator)
	if len(api_key) == 0 {
		api_key, _ = keychain.read(KEYCHAIN_ACCOUNT)
	}
	if len(api_key) == 0 {
		fmt.eprintln("no OpenRouter API key: run hw_agent -login (or set OPENROUTER_API_KEY)")
		os.exit(1)
	}

	cfg := base_config(model_id, api_key)
	if mode == "-serve" {
		os.exit(serve_daemon(cfg))
	}
	ctx := agent.Context {
		system_prompt = SYSTEM_PROMPT,
		tools = make_tools(context.allocator),
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

base_config :: proc(model_id, api_key: string) -> agent.Loop_Config {
	return {
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
}

// Tools resolve paths against the process working directory.
make_tools :: proc(allocator: mem.Allocator) -> []agent.Tool_Definition {
	cwd, _ := os.get_working_directory(allocator)
	file_state := tools.file_tool_state(cwd, allocator)
	list := make([]agent.Tool_Definition, 4, allocator)
	list[0] = tools.bash_tool(cwd, allocator)
	list[1] = tools.read_tool(file_state)
	list[2] = tools.write_tool(file_state)
	list[3] = tools.edit_tool(file_state)
	return list
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
