#+test
package yaml

import "core:testing"

@(test)
bounded_mapping_events :: proc(t: ^testing.T) {
	// {a: [b]} has four nodes, including its mapping key. b is at depth 3.
	source :: "{a: [b]}"
	cases := []struct {s: string, limits: Limits, err: Error}{
		{source, {8, 4, 3}, .None}, {source, {7, 4, 3}, .Too_Large},
		{source, {8, 3, 3}, .Too_Many_Nodes}, {source, {8, 4, 2}, .Too_Deep},
		{source, {8, 0, 3}, .Invalid_Limits}, {source, {8, 4, MAX_LIMITS.depth + 1}, .Invalid_Limits},
		{"a: [one", DEFAULT_LIMITS, .Syntax},
		// A nested block requires three spaces. After them a tab may separate flow tokens.
		{"a:\n  b: [one,\r\n   \t'two']", DEFAULT_LIMITS, .None},
		{"a:\n  b: 'one\r\n  \t#two'", DEFAULT_LIMITS, .Invalid_Indentation},
		{"a: {s: 1, \"\\x73\": 2}", DEFAULT_LIMITS, .Duplicate_Key},
		{"a: &unsafe [1]", DEFAULT_LIMITS, .Anchor}, {"a: [*ref]", DEFAULT_LIMITS, .Alias},
		{"a: !!str word", DEFAULT_LIMITS, .Tag}, {"%YAML 1.2\n---\na: b", DEFAULT_LIMITS, .Directive},
		{"a: b\n...\n---\nc: d", DEFAULT_LIMITS, .Multiple_Documents},
		{"[a, b]", DEFAULT_LIMITS, .Not_Mapping}, {"? [x, y]\n: v", DEFAULT_LIMITS, .Invalid_Key},
		{"a: 'x\u0085y'", DEFAULT_LIMITS, .Unsupported_Line_Break},
		{"\uFEFFa: b", DEFAULT_LIMITS, .Unexpected_BOM},
		{"# comment\n\uFEFFa: b", DEFAULT_LIMITS, .Unexpected_BOM},
		{"a: '\uFEFFcontent'", DEFAULT_LIMITS, .None},
	}
	for c in cases {
		root, err := parse_mapping(c.s, c.limits)
		defer destroy(&root)
		testing.expect_value(t, err, c.err)
		if err != .None do testing.expect_value(t, root.kind, .Absent)
	}
	testing.expect_value(t, DEFAULT_LIMITS, Limits{256 << 10, 10_000, 32})
	testing.expect_value(t, MAX_LIMITS, Limits{4 << 20, 100_000, 128})
}
