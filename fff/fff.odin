package fff

// Bindings to fff_bridge (fff-mcp's search tools as a static library) and a
// process-wide registry that shares one index per project root.

import "core:os"
import "core:strings"
import "core:sync"
import devlog "devlog:."

foreign import bridge {
	"../build/fff/target/release/libhw_fff_bridge.a",
	"system:CoreServices.framework",
	"system:CoreFoundation.framework",
	"system:Security.framework",
	"system:iconv",
	"system:z",
}

Index :: distinct rawptr

@(default_calling_convention = "c")
foreign bridge {
	hwfff_resolve_root :: proc(base_path: cstring) -> cstring ---
	hwfff_open :: proc(base_path, frecency_db: cstring, error: ^cstring) -> Index ---
	hwfff_root :: proc(index: Index) -> cstring ---
	hwfff_call :: proc(index: Index, tool, args: cstring, is_error: ^bool) -> cstring ---
	hwfff_tools :: proc() -> cstring ---
	hwfff_instructions :: proc() -> cstring ---
	hwfff_free_string :: proc(s: cstring) ---
	hwfff_close :: proc(index: Index) ---
}

@(private)
registry: struct {
	mu:      sync.Mutex,
	indexes: map[string]Index, // project root → index; lives for the process
}

// frecency_db follows fff's own convention: FFF_FRECENCY_DB, else fff.nvim's
// database when present (shared with the editor), else ~/.local/share/fff.
frecency_db :: proc(allocator := context.allocator) -> string {
	if env := os.get_env("FFF_FRECENCY_DB", allocator); len(env) > 0 { return env }
	home := os.get_env("HOME", context.temp_allocator)
	nvim := strings.concatenate({home, "/.cache/nvim/fff_nvim"}, allocator)
	if os.exists(nvim) { return nvim }
	return strings.concatenate({home, "/.local/share/fff/frecency"}, allocator)
}

// index_for returns the shared index covering cwd (its git root, or cwd),
// opening it on first use. The scan runs in the background; tools wait for it.
index_for :: proc(cwd: string) -> (Index, bool) {
	ccwd := strings.clone_to_cstring(cwd, context.temp_allocator)
	raw_root := hwfff_resolve_root(ccwd)
	root := strings.clone(string(raw_root))
	hwfff_free_string(raw_root)

	sync.mutex_lock(&registry.mu)
	defer sync.mutex_unlock(&registry.mu)
	if index, ok := registry.indexes[root]; ok {
		delete(root)
		return index, true
	}
	err: cstring
	index := hwfff_open(ccwd, strings.clone_to_cstring(frecency_db(context.temp_allocator), context.temp_allocator), &err)
	if index == nil {
		devlog.failed(devlog.global(), {feature = "search", operation = "open"}, {reason = "fff index could not be opened", detail = string(err)[:min(len(err), 200)]})
		hwfff_free_string(err)
		delete(root)
		return nil, false
	}
	devlog.succeeded(devlog.global(), {feature = "search", operation = "open"})
	registry.indexes[root] = index
	return index, true
}

// shutdown closes every index (stopping its watcher) and frees the registry.
shutdown :: proc() {
	sync.mutex_lock(&registry.mu)
	defer sync.mutex_unlock(&registry.mu)
	for root, index in registry.indexes {
		hwfff_close(index)
		delete(root)
	}
	delete(registry.indexes)
	registry.indexes = nil
}

// call runs one fff tool; the text is allocated with allocator.
call :: proc(index: Index, tool, args_json: string, allocator := context.allocator) -> (text: string, is_error: bool) {
	raw := hwfff_call(index, strings.clone_to_cstring(tool, context.temp_allocator), strings.clone_to_cstring(args_json, context.temp_allocator), &is_error)
	text = strings.clone(string(raw), allocator)
	hwfff_free_string(raw)
	return
}

tools_json :: proc(allocator := context.allocator) -> string {
	raw := hwfff_tools()
	defer hwfff_free_string(raw)
	return strings.clone(string(raw), allocator)
}

instructions :: proc() -> string {
	return string(hwfff_instructions())
}

root_of :: proc(index: Index) -> string {
	return string(hwfff_root(index))
}
