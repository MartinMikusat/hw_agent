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
import "fff"
import "instructions"
import devlog "devlog:."
import "rpc"
import "session"
import "tools"

DEFAULT_MODEL :: "deepseek/deepseek-v4.1-flash"
DEFAULT_CONTEXT_WINDOW :: 1_000_000

SYSTEM_PROMPT :: `You are a coding agent running inside hw_agent, a minimal harness.
Use find_files, grep and multi_grep to locate code, read/edit/write for files,
and bash for everything else. Be concise.`

USAGE :: `usage: hw_agent "<prompt>" [-model=<id>] [-session=<path>]
       hw_agent -rpc [-model=<id>] [-session=<path>]
       hw_agent -serve [-model=<id>]       shared daemon on the agent socket
       hw_agent -login                     store the OpenRouter key in the Keychain
       hw_agent -install [-model=<id>]     LaunchAgent for -serve
       hw_agent -uninstall
       hw_agent -sessions                  list daemon sessions, newest first
       hw_agent -show=<id|path>            readable transcript
       hw_agent -export=<id|path> [-json]  full Markdown (or JSON) transcript
       hw_agent -rm=<id|path>              delete a session and its traces
       hw_agent -version`

API_KEY_ENV :: "OPENROUTER_API_KEY"

main :: proc() {
	model_id := DEFAULT_MODEL
	session_path := ""
	prompt := ""
	rpc_mode := false
	mode := ""
	target := ""
	as_json := false
	for arg in os.args[1:] {
		if arg == "-version" {
			fmt.println(APP_VERSION)
			return
		} else if arg == "-rpc" {
			rpc_mode = true
		} else if arg == "-serve" || arg == "-install" || arg == "-uninstall" || arg == "-login" || arg == "-sessions" {
			mode = arg
		} else if strings.has_prefix(arg, "-show=") || strings.has_prefix(arg, "-export=") || strings.has_prefix(arg, "-rm=") {
			eq := strings.index_byte(arg, '=')
			mode, target = arg[:eq], arg[eq + 1:]
		} else if arg == "-json" {
			as_json = true
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
	// The daemon and one-shot commands keep separate journals: each owns its run marker.
	config := devlog.DEFAULT_CONFIG
	config.profile = devlog.profile_from_env()
	if devlog.global_start(devlog.default_directory("hw_agent", mode == "-serve" ? "daemon" : "cli"), config) {
		context.assertion_failure_proc = devlog.fatal_hook()
	}
	defer devlog.global_destroy()

	switch mode {
	case "-install":
		exit(install(model_id))
	case "-login":
		exit(login())
	case "-uninstall":
		exit(uninstall())
	case "-sessions":
		exit(cmd_sessions())
	case "-show":
		exit(cmd_show(target))
	case "-export":
		exit(cmd_export(target, as_json))
	case "-rm":
		exit(cmd_rm(target))
	}
	if len(prompt) == 0 && !rpc_mode && mode == "" {
		fmt.eprintln(USAGE)
		exit(1)
	}

	api_key := os.get_env(API_KEY_ENV, context.allocator)
	if len(api_key) == 0 {
		api_key, _ = keychain.read(KEYCHAIN_ACCOUNT)
	}
	if len(api_key) == 0 {
		fmt.eprintln("no OpenRouter API key: run hw_agent -login (or set OPENROUTER_API_KEY)")
		exit(1)
	}

	cfg := base_config(model_id, api_key)
	if mode == "-serve" {
		exit(serve_daemon(cfg))
	}
	if tracing_enabled() {
		cfg.model.provider_options.trace_dir = cli_trace_dir()
		start_trace_pruning(traces_dir(), false)
	}
	cwd, _ := os.get_working_directory(context.allocator)
	ctx := agent.Context {
		system_prompt = instructions.render(system_prompt(context.allocator), instructions.load(cwd, os.get_env("HOME", context.allocator))),
		tools = make_tools(context.allocator, cwd),
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
			exit(1)
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
		exit(1)
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

// Tools resolve paths against cwd; search runs on the fff index covering it.
make_tools :: proc(allocator: mem.Allocator, cwd: string) -> []agent.Tool_Definition {
	file_state := tools.file_tool_state(cwd, allocator)
	list := make([dynamic]agent.Tool_Definition, 0, 8, allocator)
	append(&list, tools.bash_tool(cwd, allocator), tools.read_tool(file_state), tools.write_tool(file_state), tools.edit_tool(file_state))
	append(&list, ..tools.search_tools(cwd, allocator))
	return list[:]
}

// system_prompt adds fff's search guidance, as fff-mcp gives Claude Code.
system_prompt :: proc(allocator: mem.Allocator) -> string {
	return strings.concatenate({SYSTEM_PROMPT, "\n\n# File search\n\n", fff.instructions()}, allocator)
}

// exit closes the dev log first, so a deliberate exit is never read as a crash.
exit :: proc(code: int) -> ! {
	devlog.global_destroy()
	os.exit(code)
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
