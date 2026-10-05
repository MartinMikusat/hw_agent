package textutil

// UTF-8 safety for text that ends up in JSON. Odin's JSON encoder writes invalid
// bytes as "\xNN", which is not JSON, so every string that reaches a transcript,
// a client or a provider request must be valid UTF-8 first.

import "core:mem"
import "core:strings"
import "core:unicode/utf8"

REPLACEMENT :: "�"

// clean returns text as a new string with each invalid byte replaced by U+FFFD.
clean :: proc(text: string, allocator: mem.Allocator) -> string {
	if utf8.valid_string(text) { return strings.clone(text, allocator) }
	b := strings.builder_make(0, len(text) + 8, allocator)
	rest := text
	for len(rest) > 0 {
		r, width := utf8.decode_rune_in_string(rest)
		if r == utf8.RUNE_ERROR && width <= 1 {
			strings.write_string(&b, REPLACEMENT)
			width = 1
		} else {
			strings.write_string(&b, rest[:width])
		}
		rest = rest[width:]
	}
	return strings.to_string(b)
}

// scrub is clean without the copy when the text is already valid.
scrub :: proc(text: string, allocator: mem.Allocator) -> string {
	if utf8.valid_string(text) { return text }
	return clean(text, allocator)
}

// cut is the longest prefix of at most max_bytes that ends on a character boundary.
cut :: proc(text: string, max_bytes: int) -> string {
	if len(text) <= max_bytes { return text }
	end := max_bytes
	for end > 0 && text[end] & 0xC0 == 0x80 { end -= 1 }
	return text[:end]
}

// tail is the longest suffix of at most max_bytes that starts on a character boundary.
tail :: proc(text: string, max_bytes: int) -> string {
	if len(text) <= max_bytes { return text }
	start := len(text) - max_bytes
	for start < len(text) && text[start] & 0xC0 == 0x80 { start += 1 }
	return text[start:]
}
