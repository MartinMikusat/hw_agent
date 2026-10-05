package main

// -serve / -install / -uninstall: the shared socket daemon and its LaunchAgent.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"

import "agent"
import "keychain"
import "serve"

LAUNCH_LABEL :: "com.halwayland.hw_agent"
KEYCHAIN_ACCOUNT :: "openrouter"

support_dir :: proc() -> string {
	home := os.get_env("HOME", context.allocator)
	return fmt.aprintf("%s/Library/Application Support/hw_agent", home)
}

serve_daemon :: proc(base: agent.Loop_Config) -> int {
	dir := support_dir()
	cfg := serve.Config {
		socket_path   = fmt.aprintf("%s/agent.sock", dir),
		sessions_dir  = fmt.aprintf("%s/sessions", dir),
		default_model = base.model.id,
		system_prompt = SYSTEM_PROMPT,
		base          = base,
		make_tools    = make_tools,
	}
	d, err := serve.listen(cfg, context.allocator)
	if err != .None {
		fmt.eprintfln("hw_agent -serve: %v (%s)", err, cfg.socket_path)
		return 1
	}
	fmt.eprintfln("hw_agent -serve: listening on %s", cfg.socket_path)
	serve.run(d)
	return 0
}

plist_path :: proc() -> string {
	return fmt.aprintf("%s/Library/LaunchAgents/%s.plist", os.get_env("HOME", context.allocator), LAUNCH_LABEL)
}

install :: proc(model_id: string) -> int {
	if existing, _ := keychain.read(KEYCHAIN_ACCOUNT); len(existing) == 0 {
		fmt.eprintln("no key in the Keychain: run hw_agent -login first")
		return 1
	}

	exe, eerr := os.get_executable_path(context.allocator)
	if eerr != nil {
		fmt.eprintfln("cannot resolve executable path: %v", eerr)
		return 1
	}
	dir := support_dir()
	if err := os.make_directory_all(dir, os.perm(0o700)); err != nil && !os.is_dir(dir) {
		fmt.eprintfln("cannot create %s: %v", dir, err)
		return 1
	}
	home := os.get_env("HOME", context.allocator)
	plist := fmt.aprintf(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>%s</string>
	<key>ProgramArguments</key>
	<array><string>%s</string><string>-serve</string><string>-model=%s</string></array>
	<key>WorkingDirectory</key><string>%s</string>
	<key>RunAtLoad</key><true/>
	<key>KeepAlive</key><true/>
	<key>StandardErrorPath</key><string>%s/daemon.log</string>
</dict>
</plist>
`, LAUNCH_LABEL, xml_escape(exe), xml_escape(model_id), xml_escape(home), xml_escape(dir))
	path := plist_path()
	launchctl("bootout", path) // replace a previous install; failure means none was loaded
	if err := os.write_entire_file(path, transmute([]u8)plist); err != nil {
		fmt.eprintfln("cannot write %s: %v", path, err)
		return 1
	}
	if !launchctl("bootstrap", path) { return 1 }
	fmt.printfln("installed %s → %s -serve", path, exe)
	return 0
}

// login reads the key from the terminal with echo off and stores it.
login :: proc() -> int {
	stdin := posix.FD(0)
	saved: posix.termios
	is_tty := posix.tcgetattr(stdin, &saved) == .OK
	if is_tty {
		quiet := saved
		quiet.c_lflag -= {.ECHO}
		posix.tcsetattr(stdin, .TCSAFLUSH, &quiet)
	}
	fmt.eprint("OpenRouter API key: ")
	buf: [1024]u8
	n, _ := os.read(os.stdin, buf[:])
	if is_tty {
		posix.tcsetattr(stdin, .TCSAFLUSH, &saved)
		fmt.eprintln()
	}
	key := strings.trim_space(string(buf[:max(n, 0)]))
	if len(key) == 0 {
		fmt.eprintln("no key entered")
		return 1
	}
	if status := keychain.write(KEYCHAIN_ACCOUNT, key); status != 0 {
		fmt.eprintfln("Keychain write failed: OSStatus %d", status)
		return 1
	}
	fmt.eprintln("stored in the Keychain (service hw_agent, account openrouter)")
	return 0
}

uninstall :: proc() -> int {
	path := plist_path()
	launchctl("bootout", path)
	if os.exists(path) {
		if err := os.remove(path); err != nil {
			fmt.eprintfln("cannot remove %s: %v", path, err)
			return 1
		}
	}
	fmt.printfln("removed %s (Keychain item kept)", path)
	return 0
}

launchctl :: proc(verb, plist: string) -> bool {
	domain := fmt.aprintf("gui/%d", os.get_uid())
	state, _, stderr, err := os.process_exec(os.Process_Desc{command = {"/bin/launchctl", verb, domain, plist}}, context.allocator)
	ok := err == nil && state.exit_code == 0
	if !ok && verb == "bootstrap" {
		fmt.eprintfln("launchctl bootstrap failed: %v %s", err, stderr)
	}
	return ok
}

xml_escape :: proc(s: string) -> string {
	out, _ := strings.replace_all(s, "&", "&amp;")
	out, _ = strings.replace_all(out, "<", "&lt;")
	out, _ = strings.replace_all(out, ">", "&gt;")
	return out
}
