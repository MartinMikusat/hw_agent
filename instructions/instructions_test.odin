package instructions

// Layering, precedence and limits of project instruction loading on a real tree.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

write :: proc(path, text: string) {
	_ = os.make_directory_all(path[:strings.last_index_byte(path, '/')])
	_ = os.write_entire_file(path, transmute([]u8)text)
}

@(test)
test_layers_from_global_to_working_directory :: proc(t: ^testing.T) {
	tmp := strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/")
	base := fmt.tprintf("%s/hwi_%d", tmp, time.to_unix_nanoseconds(time.now()))
	defer os.remove_all(base)
	home := fmt.tprintf("%s/home", base)
	repo := fmt.tprintf("%s/work/repo", base)
	write(fmt.tprintf("%s/%s", home, GLOBAL_FILE), "global rules")
	write(fmt.tprintf("%s/.git/HEAD", repo), "ref")
	write(fmt.tprintf("%s/AGENTS.md", repo), "root rules")
	write(fmt.tprintf("%s/CLAUDE.md", repo), "ignored: AGENTS.md wins")
	write(fmt.tprintf("%s/pkg/CLAUDE.md", repo), "pkg rules from CLAUDE")
	write(fmt.tprintf("%s/pkg/inner/AGENTS.md", repo), "   \n") // empty: skipped
	write(fmt.tprintf("%s/work/AGENTS.md", base), "above the repo: must not load")

	sources := load(fmt.tprintf("%s/pkg/inner", repo), home, context.temp_allocator)
	texts := make([dynamic]string, context.temp_allocator)
	for s in sources { append(&texts, s.text) }
	testing.expect_value(t, strings.join(texts[:], "|", context.temp_allocator), "global rules|root rules|pkg rules from CLAUDE")

	prompt := render("BASE", sources, context.temp_allocator)
	testing.expect(t, strings.has_prefix(prompt, "BASE\n\n# Project instructions"))
	testing.expect(t, strings.index(prompt, "root rules") < strings.index(prompt, "pkg rules from CLAUDE"), "specific comes last")
	testing.expect_value(t, render("BASE", nil, context.temp_allocator), "BASE")
}

@(test)
test_no_repo_uses_only_the_working_directory_and_caps_size :: proc(t: ^testing.T) {
	tmp := strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/")
	base := fmt.tprintf("%s/hwi2_%d", tmp, time.to_unix_nanoseconds(time.now()))
	defer os.remove_all(base)
	write(fmt.tprintf("%s/AGENTS.md", base), "parent: must not load")
	// multi-byte text longer than the cap: truncation must not split a character
	big := strings.repeat("é", MAX_FILE_BYTES, context.temp_allocator)
	write(fmt.tprintf("%s/proj/AGENTS.md", base), big)

	sources := load(fmt.tprintf("%s/proj", base), "", context.temp_allocator)
	if !testing.expect_value(t, len(sources), 1) { return }
	testing.expect(t, strings.has_suffix(sources[0].text, "\n[truncated]"))
	body := strings.trim_suffix(sources[0].text, "\n[truncated]")
	testing.expect(t, len(body) <= MAX_FILE_BYTES && len(strings.trim(body, "é")) == 0, "whole characters only")
}
