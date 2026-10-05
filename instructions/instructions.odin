package instructions

// Project instructions for the system prompt: the user's global AGENTS.md, then
// each AGENTS.md (or CLAUDE.md when a directory has no AGENTS.md) from the
// project root down to the session's working directory, general first and most
// specific last. The root is the nearest ancestor holding .git; without one
// only the working directory counts.

import "core:fmt"
import "core:os"
import "core:strings"

import devlog "devlog:."
import "../textutil"

MAX_FILE_BYTES :: 32 * 1024
GLOBAL_FILE :: ".agents/AGENTS.md" // under the home directory

Source :: struct {
	path: string,
	text: string,
}

// load reads the instruction files that apply to cwd. A file that exists but
// cannot be read is recorded and skipped; absent files are normal.
load :: proc(cwd, home: string, allocator := context.allocator) -> []Source {
	sources := make([dynamic]Source, 0, 4, allocator)
	if len(home) > 0 {
		add(&sources, fmt.tprintf("%s/%s", strings.trim_right(home, "/"), GLOBAL_FILE), allocator)
	}
	dirs := make([dynamic]string, context.temp_allocator)
	root := find_root(cwd)
	for dir := cwd; ; dir = parent(dir) {
		append(&dirs, dir)
		if dir == root || dir == "/" { break }
	}
	#reverse for dir in dirs {
		for name in ([]string{"AGENTS.md", "CLAUDE.md"}) {
			if add(&sources, fmt.tprintf("%s/%s", strings.trim_right(dir, "/"), name), allocator) { break }
		}
	}
	return sources[:]
}

// render appends the loaded files to the base prompt.
render :: proc(base: string, sources: []Source, allocator := context.allocator) -> string {
	if len(sources) == 0 { return base }
	b := strings.builder_make(allocator)
	strings.write_string(&b, base)
	strings.write_string(&b, "\n\n# Project instructions\n\nThese instruction files apply to the working directory, general first, most specific last.\n")
	for s in sources {
		fmt.sbprintf(&b, "\n## %s\n\n%s\n", s.path, s.text)
	}
	return strings.to_string(b)
}

paths :: proc(sources: []Source, allocator := context.allocator) -> []string {
	out := make([]string, len(sources), allocator)
	for s, i in sources { out[i] = s.path }
	return out
}

// add appends the file when it exists and is not already listed; true when the
// path was a regular file, even if it was empty or unreadable.
@(private)
add :: proc(sources: ^[dynamic]Source, path: string, allocator := context.allocator) -> bool {
	if !os.is_file(path) { return false }
	for s in sources { if s.path == path { return true } }
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		devlog.failed(devlog.global(), {feature = "instructions", operation = "load"}, {reason = "instruction file could not be read", detail = basename(path), severity = .Warning})
		return true
	}
	text := textutil.scrub(strings.trim_space(string(data)), context.temp_allocator)
	if len(text) == 0 { return true }
	truncated := len(text) > MAX_FILE_BYTES
	if truncated { text = textutil.cut(text, MAX_FILE_BYTES) }
	append(sources, Source {
		path = strings.clone(path, allocator),
		text = truncated ? strings.concatenate({text, "\n[truncated]"}, allocator) : strings.clone(text, allocator),
	})
	return true
}

@(private)
basename :: proc(path: string) -> string {
	return path[strings.last_index_byte(path, '/') + 1:]
}

// find_root is the project root for cwd: the nearest ancestor holding .git,
// else cwd itself.
find_root :: proc(cwd: string) -> string {
	for dir := cwd; ; dir = parent(dir) {
		if os.exists(fmt.tprintf("%s/.git", strings.trim_right(dir, "/"))) { return dir }
		if dir == "/" { break }
	}
	return cwd
}

@(private)
parent :: proc(dir: string) -> string {
	i := strings.last_index_byte(strings.trim_right(dir, "/"), '/')
	return i <= 0 ? "/" : dir[:i]
}
