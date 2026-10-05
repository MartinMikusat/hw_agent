package tools

// File tools: which ones may run in parallel, and the read size limit.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "core:encoding/json"

@(test)
test_only_mutating_tools_are_sequential_and_reads_are_capped :: proc(t: ^testing.T) {
	tmp := strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/")
	dir := fmt.tprintf("%s/hwfile_%d", tmp, time.to_unix_nanoseconds(time.now()))
	_ = os.make_directory_all(dir)
	defer os.remove_all(dir)
	state := File_Tool_State{working_dir = dir}

	testing.expect(t, bash_tool(dir, context.temp_allocator).sequential)
	testing.expect(t, write_tool(&state).sequential && edit_tool(&state).sequential)
	testing.expect(t, !read_tool(&state).sequential, "reads may overlap")

	big := fmt.tprintf("%s/big.bin", dir)
	f, _ := os.open(big, {.Write, .Create}, os.perm(0o600))
	_ = os.truncate(f, MAX_READ_BYTES + 1) // sparse: no real 16 MiB written
	os.close(f)
	args := make(json.Object, context.temp_allocator)
	args["path"] = json.String("big.bin")
	result := read_execute("c", args, nil, nil, &state)
	testing.expect(t, result.is_error && strings.contains(result.text, "byte limit"), result.text)
}
