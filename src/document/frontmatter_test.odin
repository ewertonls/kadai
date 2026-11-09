#+test
package document

import "core:fmt"
import "core:testing"

@(test)
frontmatter_byte_ranges :: proc(t: ^testing.T) {
	crlf := string(#load("../../tests/fixtures/v1/cases/recognition/crlf-bom/input/project/tasks/crlf.md"))
	mixed_header :: "custom: |\r\n  ---\n--- # comment\n--- \r\n"
	raw_body :: "\n---\n```\r\n---\n```\rtext\u0085\u2028\u2029"
	cases := []struct {source, bom, opening, header, closing, body: string}{
		{crlf, "\uFEFF", "---\r\n", "kadai: task\r\nid: BOM\r\ntitle: Olá mundo\r\nstatus: todo\r\n", "---\r\n", "# Corpo\r\n"},
		{"---\n" + mixed_header + "---\r\n" + raw_body, "", "---\n", mixed_header, "---\r\n", raw_body},
		{"---\n---", "", "---\n", "", "---", ""},
	}
	for c in cases {
		parts, status := extract_frontmatter(c.source)
		if !testing.expect_value(t, status, .Present) do continue
		spans := [?]Byte_Range{parts.bom, parts.opening, parts.header, parts.closing, parts.body}
		expected := [?]string{c.bom, c.opening, c.header, c.closing, c.body}
		cursor := 0
		for span, i in spans {
			end := cursor + len(expected[i])
			testing.expect_value(t, span, Byte_Range{cursor, end})
			testing.expect_value(t, c.source[span.start:span.end], expected[i])
			cursor = end
		}
		testing.expect_value(t, cursor, len(c.source))
	}
}

@(test)
frontmatter_absence_and_errors :: proc(t: ^testing.T) {
	missing := string(#load("../../tests/fixtures/v1/cases/recognition/missing-close/input/project/tasks/open.md"))
	lone_cr := string(#load("../../tests/fixtures/v1/cases/yaml/lone-cr/input/project/tasks/cr.md"))
	cases := []struct {source: string, status: Frontmatter_Status}{
		{"", .Absent},
		{"\uFEFF# notes\n---\n", .Absent},
		{" ---\n", .Absent},
		{"--- \n", .Absent},
		{"---", .Missing_Close},
		{missing, .Missing_Close},
		{"---\n---suffix", .Missing_Close},
		{lone_cr, .Unsupported_Line_Break},
		{"---\n---\r", .Unsupported_Line_Break},
		{"---\ninvalid: \xff\n---", .Invalid_UTF8},
		{"---\n---\nbody\xff", .Invalid_UTF8},
	}
	for c in cases {
		parts, status := extract_frontmatter(c.source)
		testing.expect_value(t, status, c.status)
		testing.expect_value(t, parts, Frontmatter{})
	}
	unsupported := [?]string{"\r", "\u0085", "\u2028", "\u2029"}
	for ending in unsupported {
		_, status := extract_frontmatter(fmt.tprintf("\uFEFF---%skadai: task", ending))
		testing.expect_value(t, status, .Unsupported_Line_Break)
	}
}

@(test)
frontmatter_byte_limits :: proc(t: ^testing.T) {
	source :: "\uFEFF---\r\nabc\r\n---\r\nx"
	cases := []struct {input: string, limits: Frontmatter_Limits, status: Frontmatter_Status}{
		{source, {len(source), 5}, .Present},
		{source, {len(source)-1, 5}, .Task_Source_Too_Large},
		{source, {len(source), 4}, .YAML_Document_Too_Large},
		{"---\nabc", {8, 3}, .Missing_Close},
		{"---\nabcd", {8, 3}, .YAML_Document_Too_Large},
		{"---\nabc\n---x", {16, 4}, .YAML_Document_Too_Large},
		{"---\nabc\n---\r", {16, 4}, .YAML_Document_Too_Large},
		{"# notes\n---\n\xff", {1, 1}, .Absent},
		{"", {0, 1}, .Invalid_Limits},
		{"", {1, 0}, .Invalid_Limits},
		{"", {MAX_FRONTMATTER_LIMITS.task_source_bytes + 1, 1}, .Invalid_Limits},
		{"", {1, MAX_FRONTMATTER_LIMITS.yaml_document_bytes + 1}, .Invalid_Limits},
	}
	testing.expect_value(t, DEFAULT_FRONTMATTER_LIMITS, Frontmatter_Limits{16 << 20, 256 << 10})
	testing.expect_value(t, MAX_FRONTMATTER_LIMITS, Frontmatter_Limits{256 << 20, 4 << 20})
	for c in cases {
		_, status := extract_frontmatter(c.input, c.limits)
		testing.expect_value(t, status, c.status)
	}
}
