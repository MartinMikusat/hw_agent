package fff

// The bridge contract: an index over a real directory answers fff-mcp's three
// tools, shares one index per root, and reports bad arguments as errors.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

@(test)
test_tools_on_a_project :: proc(t: ^testing.T) {
	tmp := strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/")
	root := fmt.tprintf("%s/hwfff_%d", tmp, time.to_unix_nanoseconds(time.now()))
	defer os.remove_all(root)
	_ = os.make_directory_all(fmt.tprintf("%s/src", root))
	_ = os.make_directory_all(fmt.tprintf("%s/docs", root))
	_ = os.write_entire_file(fmt.tprintf("%s/src/alpha.odin", root), transmute([]u8)string("package alpha\n\nUniqueMarkerIdent :: 42\n"))
	_ = os.write_entire_file(fmt.tprintf("%s/docs/readme.md", root), transmute([]u8)string("# Docs\n"))

	index, ok := index_for(root)
	defer shutdown()
	if !testing.expect(t, ok) { return }
	same, _ := index_for(root)
	testing.expect(t, same == index, "one index per root")

	text, is_error := call(index, "grep", `{"query":"UniqueMarkerIdent"}`, context.temp_allocator)
	testing.expectf(t, !is_error && strings.contains(text, "alpha.odin"), "grep: %s", text)

	text, is_error = call(index, "find_files", `{"query":"readme"}`, context.temp_allocator)
	testing.expectf(t, !is_error && strings.contains(text, "readme.md"), "find_files: %s", text)

	text, is_error = call(index, "multi_grep", `{"patterns":["nothing_matches_this","UniqueMarkerIdent"]}`, context.temp_allocator)
	testing.expectf(t, !is_error && strings.contains(text, "alpha.odin"), "multi_grep: %s", text)

	text, is_error = call(index, "grep", `{"nope":1}`, context.temp_allocator)
	testing.expectf(t, is_error, "missing query must be an error, got: %s", text)

	tools := tools_json(context.temp_allocator)
	for name in ([]string{`"find_files"`, `"grep"`, `"multi_grep"`}) {
		testing.expectf(t, strings.contains(tools, name), "tool %s missing", name)
	}
	testing.expect(t, strings.contains(instructions(), "multi_grep"))
}
