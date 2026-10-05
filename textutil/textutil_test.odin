package textutil

import "core:encoding/json"
import "core:testing"
import "core:unicode/utf8"

@(test)
test_clean_cut_and_tail_keep_text_encodable :: proc(t: ^testing.T) {
	raw := []u8{'a', 0xff, 0xfe, 'b', 0xe2, 0x82, 0xac, 0xed, 0xa0, 0x80, 'c', 0xe2, 0x82} // junk, a euro sign, a surrogate, a cut character
	cleaned := clean(string(raw), context.temp_allocator)
	testing.expect_value(t, cleaned, "a��b€���c��")
	testing.expect(t, utf8.valid_string(cleaned))
	testing.expect_value(t, scrub("plain €", context.temp_allocator), "plain €")

	// the encoder emits "\xNN" for invalid bytes; cleaned text must round-trip
	m := make(map[string]json.Value, context.temp_allocator)
	m["c"] = json.String(cleaned)
	data, _ := json.marshal(m, {}, context.temp_allocator)
	parsed, err := json.parse(data, allocator = context.temp_allocator)
	testing.expect(t, err == nil)
	if obj, ok := parsed.(json.Object); ok {
		text, _ := obj["c"].(json.String)
		testing.expect_value(t, string(text), cleaned)
	}

	euro := "x€y" // x, 3-byte character, y
	testing.expect_value(t, cut(euro, 2), "x")
	testing.expect_value(t, cut(euro, 4), "x€")
	testing.expect_value(t, cut(euro, 99), euro)
	testing.expect_value(t, tail(euro, 2), "y")
	testing.expect_value(t, tail(euro, 4), "€y")
	testing.expect_value(t, tail(euro, 99), euro)
}
