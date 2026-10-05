package tools

// bash against real processes: output order and status, working directory,
// SIGPIPE behaviour under a daemon that ignores it, timeout and abort stopping
// the whole process group, and background processes not outliving the call.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import "core:thread"
import "core:time"

import "../ai"

run_bash :: proc(command: string, timeout_s := 0, cancel: ^ai.Cancellation = nil, dir := "/tmp") -> (text: string, is_error: bool, elapsed: time.Duration) {
	state := Bash_Tool_State{working_dir = dir}
	args := make(json.Object, context.temp_allocator)
	args["command"] = json.String(command)
	if timeout_s > 0 { args["timeout"] = json.Integer(timeout_s) }
	started := time.tick_now()
	result := bash_execute("t", args, cancel, nil, &state)
	return result.text, result.is_error, time.tick_since(started)
}

// pid_alive waits for the process to disappear: a killed process lingers as a
// zombie until its parent (launchd, for an orphan) reaps it.
pid_alive :: proc(pid_text: string) -> bool {
	pid, ok := strconv_pid(pid_text)
	if !ok { return true }
	for _ in 0 ..< 100 {
		if posix.kill(pid, nil) != .OK { return false }
		time.sleep(20 * time.Millisecond)
	}
	return true
}

strconv_pid :: proc(text: string) -> (posix.pid_t, bool) {
	n := 0
	trimmed := strings.trim_space(text)
	if len(trimmed) == 0 { return 0, false }
	for ch in transmute([]u8)trimmed {
		if ch < '0' || ch > '9' { return 0, false }
		n = n * 10 + int(ch - '0')
	}
	return posix.pid_t(n), true
}

pid_file :: proc(name: string) -> string {
	tmp := strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/")
	return fmt.tprintf("%s/hwbash_%s_%d", tmp, name, time.to_unix_nanoseconds(time.now()))
}

@(test)
test_output_status_directory_and_sigpipe :: proc(t: ^testing.T) {
	text, is_error, elapsed := run_bash("echo out1; echo err >&2; echo out2; exit 3")
	testing.expect_value(t, text, "out1\nerr\nout2\n[exit 3]")
	testing.expect(t, is_error)

	text, is_error, _ = run_bash("pwd", dir = "/usr")
	testing.expect_value(t, text, "/usr")
	testing.expect(t, !is_error)

	text, _, _ = run_bash("true")
	testing.expect_value(t, text, "(no output)")

	// a stray byte or a cut character must not leave the output unencodable
	text, _, _ = run_bash(`printf 'a\377b\342\202'`)
	testing.expect_value(t, text, "a\uFFFDb\uFFFD\uFFFD")

	// the daemon ignores SIGPIPE; a child must get the default back
	posix.signal(.SIGPIPE, auto_cast posix.SIG_IGN)
	text, is_error, elapsed = run_bash("yes | head -n 1")
	testing.expect_value(t, text, "y")
	testing.expect(t, !is_error && elapsed < 5 * time.Second, "yes must die of SIGPIPE, not spin")

	// output beyond the cap keeps the tail
	text, _, _ = run_bash("seq 1 20000")
	testing.expect(t, strings.has_prefix(text, "[earlier output omitted:") && strings.has_suffix(text, "20000"))
	testing.expect(t, len(text) <= BASH_MAX_OUTPUT_BYTES)
}

@(test)
test_timeout_and_abort_stop_the_process_group :: proc(t: ^testing.T) {
	file := pid_file("timeout")
	defer os.remove(file)
	text, is_error, elapsed := run_bash(fmt.tprintf("sleep 60 & echo $! > %s; wait", file), timeout_s = 1)
	testing.expect(t, is_error && strings.contains(text, "timed out after 1s"), text)
	testing.expect(t, elapsed < 6 * time.Second, "returns shortly after the timeout")
	data, _ := os.read_entire_file(file, context.temp_allocator)
	testing.expect(t, !pid_alive(string(data)), "the grandchild must be gone")

	file2 := pid_file("abort")
	defer os.remove(file2)
	cancel := ai.Cancellation{}
	aborter := thread.create_and_start_with_data(&cancel, proc(data: rawptr) {
		time.sleep(400 * time.Millisecond)
		sync.atomic_store(&(cast(^ai.Cancellation)data).flag, true)
	})
	defer thread.destroy(aborter)
	text, is_error, elapsed = run_bash(fmt.tprintf("sleep 60 & echo $! > %s; wait", file2), cancel = &cancel)
	thread.join(aborter)
	testing.expect(t, is_error && strings.contains(text, "aborted"), text)
	testing.expect(t, elapsed < 6 * time.Second)
	data, _ = os.read_entire_file(file2, context.temp_allocator)
	testing.expect(t, !pid_alive(string(data)), "the grandchild must be gone after abort")
}

@(test)
test_background_processes_do_not_outlive_the_call :: proc(t: ^testing.T) {
	file := pid_file("background")
	defer os.remove(file)
	text, is_error, elapsed := run_bash(fmt.tprintf("sleep 60 & echo $! > %s; echo started", file))
	testing.expect(t, !is_error && strings.has_prefix(text, "started"), text)
	testing.expect(t, strings.contains(text, "background processes were stopped"), text)
	testing.expect(t, elapsed < 5 * time.Second, "must not wait for the background process")
	data, _ := os.read_entire_file(file, context.temp_allocator)
	testing.expect(t, !pid_alive(string(data)), "the background process must be gone")
}
