package tools

// bash: one command per call in its own process group, stdout and stderr merged
// in arrival order. The call ends when the command does, when the run is aborted
// or when its timeout passes; in the last two the whole process group is stopped
// (SIGTERM, then SIGKILL), so no grandchild outlives the call. Processes still
// running after bash exits are stopped too.

import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"
import devlog "devlog:."

import "../agent"
import "../ai"
import "../textutil"

BASH_DEFAULT_TIMEOUT_S :: 120
BASH_MAX_TIMEOUT_S :: 3600
BASH_KEEP_BYTES :: 30_000           // tail of the output returned to the model
BASH_MAX_OUTPUT_BYTES :: 32_000     // loop-side limit: above KEEP plus the notes below
BASH_POLL_MS :: 100
BASH_TERM_GRACE :: 2 * time.Second
BASH_STRAGGLER_GRACE :: 50 * time.Millisecond

Bash_Tool_State :: struct {
	working_dir: string,
}

BASH_SCHEMA :: `{
	"type": "object",
	"properties": {
		"command": {"type": "string", "description": "The bash command to execute"},
		"timeout": {"type": "number", "description": "Timeout in seconds (default 120, at most 3600). The command is killed when it passes."}
	},
	"required": ["command"]
}`

bash_tool :: proc(working_dir: string, allocator := context.allocator) -> agent.Tool_Definition {
	state := new(Bash_Tool_State, allocator)
	state.working_dir = strings.clone(working_dir, allocator)
	return agent.Tool_Definition {
		name = "bash",
		description = "Execute a bash command and return its combined stdout/stderr output (the last 30000 bytes when longer). Commands run for at most the timeout, and background processes are stopped when the command exits.",
		parameters_json = BASH_SCHEMA,
		max_output_bytes = BASH_MAX_OUTPUT_BYTES,
		sequential = true,
		execute = bash_execute,
		userdata = state,
	}
}

foreign import libc "system:c"

// posix_spawn attribute and file-action setters; both handle types are opaque
// pointers on Darwin.
@(default_calling_convention = "c")
foreign libc {
	posix_spawnattr_init :: proc(attr: ^rawptr) -> c.int ---
	posix_spawnattr_destroy :: proc(attr: ^rawptr) -> c.int ---
	posix_spawnattr_setflags :: proc(attr: ^rawptr, flags: c.short) -> c.int ---
	posix_spawnattr_setpgroup :: proc(attr: ^rawptr, pgroup: posix.pid_t) -> c.int ---
	posix_spawnattr_setsigdefault :: proc(attr: ^rawptr, set: ^posix.sigset_t) -> c.int ---
	posix_spawnattr_setsigmask :: proc(attr: ^rawptr, set: ^posix.sigset_t) -> c.int ---
	posix_spawn_file_actions_init :: proc(actions: ^rawptr) -> c.int ---
	posix_spawn_file_actions_destroy :: proc(actions: ^rawptr) -> c.int ---
	posix_spawn_file_actions_adddup2 :: proc(actions: ^rawptr, fd, newfd: c.int) -> c.int ---
	posix_spawn_file_actions_addopen :: proc(actions: ^rawptr, fd: c.int, path: cstring, oflag: c.int, mode: c.ushort) -> c.int ---
	posix_spawn_file_actions_addchdir_np :: proc(actions: ^rawptr, path: cstring) -> c.int ---
}

POSIX_SPAWN_SETPGROUP :: 0x0002
POSIX_SPAWN_SETSIGDEF :: 0x0004
POSIX_SPAWN_SETSIGMASK :: 0x0008
POSIX_SPAWN_CLOEXEC_DEFAULT :: 0x4000 // children inherit only the fds set up below

Bash_End :: enum {
	Exited,
	Timed_Out,
	Aborted,
}

// spawn_bash starts bash -c in a new process group with stdin from /dev/null and
// stdout+stderr on write_fd. Signals the daemon ignores (SIGPIPE) are restored to
// default so pipelines behave as in a terminal.
spawn_bash :: proc(command, working_dir: string, write_fd: posix.FD) -> (pid: posix.pid_t, ok: bool) {
	attr: rawptr
	actions: rawptr
	if posix_spawnattr_init(&attr) != 0 { return 0, false }
	defer posix_spawnattr_destroy(&attr)
	if posix_spawn_file_actions_init(&actions) != 0 { return 0, false }
	defer posix_spawn_file_actions_destroy(&actions)

	default_signals: posix.sigset_t
	default_signals = posix.sigset_t(1) << (u32(posix.Signal.SIGPIPE) - 1)
	no_mask: posix.sigset_t
	if posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT) != 0 ||
	   posix_spawnattr_setpgroup(&attr, 0) != 0 ||
	   posix_spawnattr_setsigdefault(&attr, &default_signals) != 0 ||
	   posix_spawnattr_setsigmask(&attr, &no_mask) != 0 ||
	   posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", posix.O_RDONLY, 0) != 0 ||
	   posix_spawn_file_actions_adddup2(&actions, c.int(write_fd), 1) != 0 ||
	   posix_spawn_file_actions_adddup2(&actions, c.int(write_fd), 2) != 0 ||
	   posix_spawn_file_actions_addchdir_np(&actions, strings.clone_to_cstring(working_dir, context.temp_allocator)) != 0 {
		return 0, false
	}

	argv := [4]cstring{"bash", "-c", strings.clone_to_cstring(command, context.temp_allocator), nil}
	environment, env_error := os.environ(context.temp_allocator)
	if env_error != nil { return 0, false }
	envp := make([]cstring, len(environment) + 1, context.temp_allocator)
	for entry, i in environment {
		envp[i] = strings.clone_to_cstring(entry, context.temp_allocator)
	}
	result := posix.posix_spawnp(&pid, "bash", &actions, &attr, raw_data(argv[:]), raw_data(envp))
	return pid, result == .NONE
}

// reap returns the wait status once the child has exited.
reap :: proc(pid: posix.pid_t, status: ^c.int, block: bool) -> bool {
	return posix.waitpid(pid, status, block ? {} : {.NOHANG}) == pid
}

// stop_group ends the whole process group: SIGTERM, then SIGKILL after the grace
// period. The group leader's exit status goes to status when it is still unreaped.
stop_group :: proc(pid: posix.pid_t, status: ^c.int, reaped: ^bool) {
	posix.killpg(pid, .SIGTERM)
	deadline := time.tick_add(time.tick_now(), BASH_TERM_GRACE)
	for !reaped^ && time.tick_diff(time.tick_now(), deadline) > 0 {
		reaped^ = reap(pid, status, false)
		if !reaped^ { time.sleep(10 * time.Millisecond) }
	}
	posix.killpg(pid, .SIGKILL) // also ends grandchildren that ignored SIGTERM
	if !reaped^ { reaped^ = reap(pid, status, true) }
}

// drain reads whatever is available on fd right now into buffer, keeping the
// last BASH_KEEP_BYTES; returns false at EOF.
drain :: proc(fd: posix.FD, buffer: ^[dynamic]u8, dropped: ^int, first_wait_ms: c.int) -> (open: bool) {
	chunk: [8192]u8
	wait_ms := first_wait_ms
	for {
		fds := [1]posix.pollfd{{fd = fd, events = {.IN}}}
		if posix.poll(raw_data(fds[:]), 1, wait_ms) <= 0 { return true }
		n := posix.read(fd, raw_data(chunk[:]), len(chunk))
		if n <= 0 { return false }
		append(buffer, ..chunk[:n])
		if len(buffer) > 2 * BASH_KEEP_BYTES {
			cut := len(buffer) - BASH_KEEP_BYTES
			dropped^ += cut
			copy(buffer[:], buffer[cut:])
			resize(buffer, BASH_KEEP_BYTES)
		}
		wait_ms = 0 // after the first wait, only take what is already there
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
	timeout_s := BASH_DEFAULT_TIMEOUT_S
	if requested, has := json_num(obj, "timeout"); has {
		timeout_s = clamp(requested, 1, BASH_MAX_TIMEOUT_S)
	}

	site := devlog.Site{feature = "tools", operation = "bash"}
	started := time.tick_now()
	defer devlog.sample_since(devlog.global(), site, started)

	pipe_fds: [2]posix.FD
	if posix.pipe(&pipe_fds) != .OK {
		devlog.failed(devlog.global(), site, {reason = "output pipe could not be created"})
		return {text = "failed to create an output pipe", is_error = true}
	}
	read_fd, write_fd := pipe_fds[0], pipe_fds[1]
	defer posix.close(read_fd)
	pid, spawned := spawn_bash(string(command), state.working_dir, write_fd)
	posix.close(write_fd) // the child holds the only writer now
	if !spawned {
		devlog.failed(devlog.global(), site, {reason = "bash could not be started"})
		return {text = "failed to start bash", is_error = true}
	}

	buffer := make([dynamic]u8, 0, 4096, context.temp_allocator)
	dropped := 0
	status: c.int
	reaped, eof := false, false
	end := Bash_End.Exited
	deadline := time.tick_add(started, time.Duration(timeout_s) * time.Second)
	for !reaped {
		if ai.is_cancelled(cancel) { end = .Aborted; break }
		if time.tick_diff(time.tick_now(), deadline) <= 0 { end = .Timed_Out; break }
		if eof {
			time.sleep(20 * time.Millisecond) // closed its output but still running
		} else {
			eof = !drain(read_fd, &buffer, &dropped, BASH_POLL_MS)
		}
		reaped = reap(pid, &status, false)
	}

	stragglers := false
	if end != .Exited {
		stop_group(pid, &status, &reaped)
	} else {
		// bash is gone; take its last output, then stop anything it left running
		eof = eof || !drain(read_fd, &buffer, &dropped, c.int(BASH_STRAGGLER_GRACE / time.Millisecond))
		if !eof {
			stragglers = true
			discard: c.int
			already := true
			stop_group(pid, &discard, &already)
			eof = !drain(read_fd, &buffer, &dropped, 0)
		}
	}
	_ = drain(read_fd, &buffer, &dropped, 0)
	if len(buffer) > BASH_KEEP_BYTES {
		dropped += len(buffer) - BASH_KEEP_BYTES
		copy(buffer[:], buffer[len(buffer) - BASH_KEEP_BYTES:])
		resize(&buffer, BASH_KEEP_BYTES)
	}

	out := strings.builder_make(context.temp_allocator)
	output := textutil.scrub(string(buffer[:]), context.temp_allocator) // the tail may start inside a character
	if dropped > 0 {
		fmt.sbprintf(&out, "[earlier output omitted: %d bytes]\n", dropped)
	}
	strings.write_string(&out, strings.trim_right(output, "\n"))
	if len(buffer) == 0 && dropped == 0 {
		strings.write_string(&out, "(no output)")
	}
	failed := false
	switch end {
	case .Timed_Out:
		fmt.sbprintf(&out, "\n[timed out after %ds; command stopped]", timeout_s)
		failed = true
		devlog.failed(devlog.global(), site, {reason = "command timed out and was stopped", severity = .Warning})
	case .Aborted:
		strings.write_string(&out, "\n[aborted; command stopped]")
		failed = true
	case .Exited:
		if posix.WIFSIGNALED(status) {
			fmt.sbprintf(&out, "\n[killed by signal %d]", posix.WTERMSIG(status))
			failed = true
		} else if code := posix.WEXITSTATUS(status); code != 0 {
			fmt.sbprintf(&out, "\n[exit %d]", code)
			failed = true
		}
		if stragglers {
			strings.write_string(&out, "\n[background processes were stopped when the command exited]")
		}
	}
	return {text = strings.to_string(out), is_error = failed}
}

