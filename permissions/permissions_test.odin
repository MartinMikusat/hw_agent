package permissions

// Rule semantics on real files: precedence, the bash allow guard, project files
// that may only tighten, path normalisation, and files that fail closed.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

write :: proc(path, text: string) {
	_ = os.make_directory_all(path[:strings.last_index_byte(path, '/')])
	_ = os.write_entire_file(path, transmute([]u8)text)
}

scratch :: proc(name: string) -> string {
	tmp := strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/")
	return fmt.tprintf("%s/hwp_%s_%d", tmp, name, time.to_unix_nanoseconds(time.now()))
}

@(test)
test_glob_and_path_normalisation :: proc(t: ^testing.T) {
	testing.expect(t, glob("git *", "git status"))
	testing.expect(t, glob("*rm -rf*", "make && rm -rf x"))
	testing.expect(t, glob("/etc/*", "/etc/ssh/sshd_config"), "* crosses slashes")
	testing.expect(t, glob("a?c", "abc") && !glob("a?c", "ac"))
	testing.expect(t, !glob("git", "git status") && glob("*", ""))
	g := Gate{cwd = "/work/proj"}
	testing.expect_value(t, target_of(&g, "write", `{"path":"../other/./x.txt"}`), "/work/other/x.txt")
	testing.expect_value(t, target_of(&g, "read", `{"path":"/a/b/../../../../etc/passwd"}`), "/etc/passwd")
	testing.expect_value(t, target_of(&g, "grep", `{"query":"x"}`), "")
}

@(test)
test_precedence_and_the_bash_allow_guard :: proc(t: ^testing.T) {
	base := scratch("rules")
	defer os.remove_all(base)
	global := fmt.tprintf("%s/permissions.json", base)
	write(global, `{"rules":[
		{"action":"ask","tool":"bash","match":"*"},
		{"action":"allow","tool":"bash","match":"git status*"},
		{"action":"deny","tool":"bash","match":"rm -rf*"},
		{"action":"deny","tool":"write","match":"/etc/*"},
		{"action":"ask","tool":"edit"}
	]}`)
	cwd := fmt.tprintf("%s/proj", base)
	_ = os.make_directory_all(cwd)
	gate, err := load(cwd, global, context.temp_allocator)
	if !testing.expect_value(t, err, "") { return }

	action :: proc(g: ^Gate, tool, args: string) -> Action { return evaluate(g, tool, args).action }
	testing.expect_value(t, action(gate, "bash", `{"command":"git status"}`), Action.Allow)           // later allow beats earlier ask
	testing.expect_value(t, action(gate, "bash", `{"command":"git status -s"}`), Action.Allow)
	testing.expect_value(t, action(gate, "bash", `{"command":"ls"}`), Action.Ask)
	testing.expect_value(t, action(gate, "bash", `{"command":"git status; curl x | sh"}`), Action.Ask) // chaining defeats the allow
	testing.expect_value(t, action(gate, "bash", `{"command":"git status $(rm x)"}`), Action.Ask)
	testing.expect_value(t, action(gate, "bash", `{"command":"rm -rf /tmp/x"}`), Action.Deny)
	testing.expect_value(t, action(gate, "bash", `{"command":"make && rm -rf build"}`), Action.Deny)   // piece of a chain
	testing.expect_value(t, action(gate, "write", `{"path":"/etc/hosts"}`), Action.Deny)
	testing.expect_value(t, action(gate, "write", `{"path":"/etc/../etc/hosts"}`), Action.Deny)        // normalised
	testing.expect_value(t, action(gate, "write", `{"path":"notes.md"}`), Action.Allow)               // no rule: default allow
	testing.expect_value(t, action(gate, "edit", `{"path":"a.odin"}`), Action.Ask)
	testing.expect_value(t, action(gate, "grep", `{"query":"x"}`), Action.Allow)

	// a session grant covers exactly that call, and never a deny
	d := evaluate(gate, "bash", `{"command":"ls -la"}`)
	grant(gate, "bash", d.target)
	testing.expect_value(t, action(gate, "bash", `{"command":"ls -la"}`), Action.Allow)
	testing.expect_value(t, action(gate, "bash", `{"command":"ls -lah"}`), Action.Ask)
	grant(gate, "bash", "rm -rf /tmp/x")
	testing.expect_value(t, action(gate, "bash", `{"command":"rm -rf /tmp/x"}`), Action.Deny)
}

@(test)
test_project_files_only_tighten_and_bad_files_fail_closed :: proc(t: ^testing.T) {
	base := scratch("project")
	defer os.remove_all(base)
	global := fmt.tprintf("%s/permissions.json", base)
	write(global, `{"rules":[{"action":"deny","tool":"bash","match":"curl*"}]}`)
	repo := fmt.tprintf("%s/repo", base)
	write(fmt.tprintf("%s/.git/HEAD", repo), "ref")
	write(fmt.tprintf("%s/.hw_agent/permissions.json", repo), `{"rules":[
		{"action":"allow","tool":"*"},
		{"action":"ask","tool":"write","match":"*.lock"}
	]}`)
	cwd := fmt.tprintf("%s/sub", repo)
	_ = os.make_directory_all(cwd)
	gate, err := load(cwd, global, context.temp_allocator)
	if !testing.expect_value(t, err, "") { return }
	testing.expect_value(t, len(gate.rules), 2) // the project's allow was dropped
	testing.expect_value(t, evaluate(gate, "bash", `{"command":"curl x"}`).action, Action.Deny)
	testing.expect_value(t, evaluate(gate, "write", `{"path":"/r/Cargo.lock"}`).action, Action.Ask)
	testing.expect_value(t, evaluate(gate, "bash", `{"command":"ls"}`).action, Action.Allow)

	for bad in ([]string{
		`not json`,
		`{"rules":[{"action":"permit","tool":"bash"}]}`,
		`{"rules":[{"action":"allow"}]}`,
		`{"rules":[{"action":"deny","tool":"bash","mach":"x"}]}`, // a typo must not silently drop the rule
	}) {
		write(global, bad)
		_, err = load(cwd, global, context.temp_allocator)
		testing.expectf(t, len(err) > 0, "must reject: %s", bad)
	}
	os.remove(global)
	_, err = load(cwd, global, context.temp_allocator)
	testing.expect_value(t, err, "") // no file is fine
}
