#+test
package document

import "base:runtime"
import "core:mem"
import "core:strings"
import "core:testing"
import "kadai:yaml"

@(test)
metadata_edit_preserves_markdown_body :: proc(t: ^testing.T) {
	no_newline := string(#load("../../tests/fixtures/v1/cases/patch/no-final-newline/input/project/tasks/T.md"))
	no_newline_expected := string(#load("../../tests/fixtures/v1/cases/patch/no-final-newline/expected/T.md"))
	prefix :: "\uFEFF---\r\nkadai: task\nid: T\r\ntitle: Café\nstatus: "
	suffix :: " # keep\r\n---"
	body :: "\r\n# Heading  \r\n\n[link](./café.md)\t \n\n```yaml\r\n---\nstatus: todo\n```\r\n" +
	        "opaque\rtext\u0085\u2028\u2029\r\n\r\n"
	cases := []struct {source, value, expected: string}{
		{no_newline, "done", no_newline_expected},
		{prefix + "todo" + suffix + "\r\n" + body, "in_progress", prefix + "in_progress" + suffix + "\r\n" + body},
		{prefix + "in_progress" + suffix, "todo", prefix + "todo" + suffix},
	}
	for c in cases {
		doc := decode_task(c.source)
		defer destroy(&doc)
		if !testing.expect_value(t, doc.status, .Decoded) {
			continue
		}
		status := yaml.lookup(&doc.root, "status")
		candidate, err := compose_header_edit(&doc, status.span, c.value)
		defer delete(candidate)
		if !testing.expect(t, err == nil) {
			if diagnostic, ok := err.(yaml.Diagnostic); ok {
				yaml.destroy_diagnostic(&diagnostic)
			}
			continue
		}
		testing.expect_value(t, candidate, c.expected)
		edited := decode_task(candidate)
		defer destroy(&edited)
		testing.expect_value(t, edited.status, .Decoded)
		testing.expect_value(t, edited.fields.status, c.value)
		testing.expect_value(t, candidate[edited.parts.body.start:], doc.source[doc.parts.body.start:])
	}
}

@(test)
metadata_edit_refuses_unsafe_spans_and_growth :: proc(t: ^testing.T) {
	header :: "kadai: task\nid: T\ntitle: Café\nstatus: todo\n"
	source :: "---\n" + header + "---\n# Body\nend"
	inside_rune := strings.index(header, "é") + 1
	status := strings.index(header, "todo")
	cases := []struct {span: Byte_Range, replacement: string, file_limit, header_limit: int, code, field: string}{
		{{-1, 0}, "", 256, 128, "unsafe_source_patch", ""},
		{{len(header), len(header) + 1}, "", 256, 128, "unsafe_source_patch", ""},
		{{inside_rune, inside_rune}, "", 256, 128, "unsafe_source_patch", ""},
		{{status, status + 4}, "\xff", 256, 128, "invalid_utf8", ""},
		{{status, status + 4}, "done\n---\nextra", 256, 128, "unsafe_source_patch", ""},
		{{len(header) - 1, len(header)}, "", 256, 128, "unsafe_source_patch", ""},
		{{len(header) - 1, len(header)}, "", 256, len(header), "unsafe_source_patch", ""},
		{{status, status + 4}, "in_progress", 256, len(header), "limit_exceeded", "yaml_document_bytes"},
		{{status, status + 4}, "in_progress", len(source), 128, "limit_exceeded", "task_source_bytes"},
	}
	for c in cases {
		limits := yaml.DEFAULT_LIMITS
		limits.bytes = c.header_limit
		doc := decode_task(source, task_source_bytes = c.file_limit, yaml_limits = limits, path = "tasks/T.md")
		defer destroy(&doc)
		if !testing.expect_value(t, doc.status, .Decoded) {
			continue
		}
		candidate, err := compose_header_edit(&doc, c.span, c.replacement)
		defer delete(candidate)
		testing.expect_value(t, candidate, "")
		diagnostic, ok := err.(yaml.Diagnostic)
		if !testing.expect(t, ok) {
			continue
		}
		defer yaml.destroy_diagnostic(&diagnostic)
		testing.expect_value(t, diagnostic.code, c.code)
		testing.expect_value(t, diagnostic.field, c.field)
		testing.expect_value(t, diagnostic.path, "tasks/T.md")
	}
}

@(test)
metadata_edit_propagates_allocation_failure :: proc(t: ^testing.T) {
	source :: "---\nkadai: task\nid: T\ntitle: T\nstatus: todo\n---"
	doc := decode_task(source)
	defer destroy(&doc)
	if !testing.expect_value(t, doc.status, .Decoded) {
		return
	}
	span := yaml.lookup(&doc.root, "status").span
	// This arena fits the invalid candidate exactly. Only its diagnostic fails to allocate.
	storage: [len(source)]byte
	arena := mem.Arena{data = storage[:]}
	cases := [?]struct {allocator: runtime.Allocator, replacement: string}{
		{runtime.nil_allocator(), "done"}, {mem.nil_allocator(), "done"}, {mem.arena_allocator(&arena), "\xffxxx"},
	}
	for c in cases {
		candidate: string
		err: Header_Edit_Error
		{
			context.allocator = c.allocator
			candidate, err = compose_header_edit(&doc, span, c.replacement)
		}
		defer delete(candidate)
		testing.expect_value(t, candidate, "")
		allocation_error, ok := err.(runtime.Allocator_Error)
		if testing.expect(t, ok) {
			testing.expect_value(t, allocation_error, .Out_Of_Memory)
		}
	}
	testing.expect_value(t, arena.peak_used, len(source))
}
