#+test
package document

import "core:strings"
import "core:testing"
import "kadai:task"
import "kadai:yaml"

@(test)
scalar_patch_changes_only_the_requested_token :: proc(t: ^testing.T) {
	fixtures :: "../../tests/fixtures/v1/cases/patch/"
	// The decoded key and the byte offset of its value both differ from the raw spelling.
	prefix :: "\uFEFF---\r\nkadai: task\nid: T\nstatus: todo\r\n\"ti\\u0074le\": "
	suffix :: "  # café\r\ncustom: {x: [1, true, null]}\n---\r\n# Body\n---\nend"
	// Marker-like lines (and the tab after the block indentation) are scalar data.
	block ::
		"---\r\nkadai: task\nid: T\r\nstatus: todo\ncustom:\r\n  example: >2- # sample\r\n" +
		"    \t# sample comment\n    title: &name *ref\r\n    ---\n\"ti\\u0074le\": "
	end   :: " # atual\r\n---"
	cases := []struct {
		source  : string,
		field   : Scalar_Field,
		value   : Maybe(string),
		expected: string,
	} {
		{block + "Old" + end, .Title, "New", block + "New" + end},
		{
			string(#load(fixtures + "scalar-status-comment/input/project/tasks/T.md")),
			.Status,
			"done",
			string(#load(fixtures + "scalar-status-comment/expected/T.md")),
		},
		{
			string(#load(fixtures + "crlf-bom/input/project/tasks/T.md")),
			.Status,
			"done",
			string(#load(fixtures + "crlf-bom/expected/T.md")),
		},
		{
			string(#load(fixtures + "mixed-line-endings/input/project/tasks/T.md")),
			.Status,
			"done",
			string(#load(fixtures + "mixed-line-endings/expected/T.md")),
		},
		{
			string(#load(fixtures + "no-final-newline/input/project/tasks/T.md")),
			.Status,
			"done",
			string(#load(fixtures + "no-final-newline/expected/T.md")),
		},
		{
			string(#load(fixtures + "quoted-title/input/project/tasks/T.md")),
			.Title,
			"New title",
			string(#load(fixtures + "quoted-title/expected/T.md")),
		},
		{
			string(#load(fixtures + "scalar-quoted-escape/input/project/tasks/T.md")),
			.Title,
			"New title",
			string(#load(fixtures + "scalar-quoted-escape/expected/T.md")),
		},
		{
			string(#load(fixtures + "clear-null-parent/input/project/tasks/T.md")),
			.Parent,
			nil,
			string(#load(fixtures + "clear-null-parent/expected/T.md")),
		},
		{
			string(#load(fixtures + "repair-invalid-status/input/project/tasks/T.md")),
			.Status,
			"todo",
			string(#load(fixtures + "repair-invalid-status/expected/T.md")),
		},
		{
			prefix + "Old" + suffix,
			.Title,
			"A: B # user's note",
			prefix + "'A: B # user''s note'" + suffix,
		},
		{prefix + "Old" + suffix, .Title, "0007", prefix + "0007" + suffix},
		{prefix + "Old" + suffix, .Title, "NULL", prefix + "'NULL'" + suffix},
		{prefix + "'Old'" + suffix, .Title, " É d'Ana ", prefix + "' É d''Ana '" + suffix},
		{
			prefix + "\"Old\"" + suffix,
			.Title,
			"say \"yes\"\\ok",
			prefix + "\"say \\\"yes\\\"\\\\ok\"" + suffix,
		},
		{prefix + "\"\\x41\"" + suffix, .Title, "A", prefix + "\"\\x41\"" + suffix},
	}
	for c in cases {
		// A same-length replacement can match the golden even if it overwrites its input.
		source := strings.clone(c.source)
		defer delete(source)
		edited, err := plan_scalar_patch(source, c.field, c.value)
		defer delete(edited)
		testing.expect_value(t, source, c.source)
		if !testing.expectf(t, err == nil, "%v", err) {
			if d, ok := err.(yaml.Diagnostic); ok {
				yaml.destroy_diagnostic(&d)
			}
			continue
		}
		testing.expect_value(t, edited, c.expected)
	}
}

@(test)
required_quoting_preserves_bytes_outside_the_scalar :: proc(t: ^testing.T) {
	source := string(
		#load("../../tests/fixtures/v1/cases/patch/quote-required/input/project/tasks/T.md"),
	)
	title :: "A: B # text"
	prefix, old, suffix := strings.partition(source, "Old")
	if !testing.expect_value(t, old, "Old") {
		return
	}
	input := strings.clone(source)
	defer delete(input)
	edited, err := plan_scalar_patch(input, .Title, title)
	defer delete(edited)
	testing.expect_value(t, input, source)
	if !testing.expectf(t, err == nil, "%v", err) {
		if d, ok := err.(yaml.Diagnostic); ok {
			yaml.destroy_diagnostic(&d)
		}
		return
	}
	doc := decode_task(edited)
	defer destroy(&doc)
	if !testing.expect_value(t, doc.status, .Decoded) {
		return
	}
	if !testing.expect_value(t, doc.fields.title, title) {
		return
	}
	token := yaml.lookup(&doc.root, "title")
	span := markdown_location(doc.parts.header, token.location).span
	testing.expect_value(t, edited[:span.start], prefix)
	testing.expect_value(t, edited[span.end:], suffix)
}

@(test)
scalar_patch_refuses_unsafe_or_invalid_changes :: proc(t: ^testing.T) {
	fixtures :: "../../tests/fixtures/v1/cases/patch/"
	prefix   :: "---\nkadai: task\nid: T\nstatus: todo\n"
	cases := []struct {
		source: string,
		field : Scalar_Field,
		value : Maybe(string),
		code  : string,
	} {
		{
			string(#load(fixtures + "ambiguous-duplicate-scalar/input/project/tasks/T.md")),
			.Status,
			"done",
			"duplicate_mapping_key",
		},
		{
			string(#load(fixtures + "invalid-yaml/input/project/tasks/T.md")),
			.Status,
			"done",
			"yaml_syntax",
		},
		{
			string(#load(fixtures + "unsupported-anchor/input/project/tasks/T.md")),
			.Status,
			"done",
			"unsupported_anchor",
		},
		{
			string(#load(fixtures + "unsupported-future-schema/input/project/tasks/T.md")),
			.Status,
			"done",
			"unsupported_task_schema",
		},
		{
			string(#load(fixtures + "unrelated-update-invalid-status/input/project/tasks/T.md")),
			.Priority,
			"high",
			"unrelated_invalid_field",
		},
		{"---\nkadai: task\nid: _bad\nstatus: todo\ntitle: T\n---", .Title, "X", "invalid_id"},
		// LibYAML accepts this indentation in flow context. Kadai forbids editing it.
		{prefix + "title: T\ncustom: {\n\tkey: value}\n---", .Title, "X", "invalid_indentation"},
		{prefix + "title: T\n---", .Priority, "high", "missing_field"},
		{prefix + "title: T\n---", .Title, nil, "required_null"},
		{prefix + "title: T\n---", .Title, "evil\nstatus: done", "invalid_title"},
		{prefix + "title: T\n---", .Title, "bad\xff", "invalid_utf8"},
		{prefix + "title: T\ndue: null\n---", .Due, "2025-02-29", "invalid_due"},
		{prefix + "title: |-\n  hello\n---", .Title, "X", "unsafe_source_patch"},
		{prefix + "title: one\n  two\n---", .Title, "X", "unsafe_source_patch"},
		{prefix + "title: [old]\n---", .Title, "X", "unsafe_source_patch"},
		{prefix + "title: # no token\n---", .Title, "X", "unsafe_source_patch"},
		{
			"---\n{kadai: task, id: T, status: todo, title: T}\n---",
			.Title,
			"X",
			"unsafe_source_patch",
		},
	}
	for c in cases {
		source := strings.clone(c.source)
		defer delete(source)
		edited, err := plan_scalar_patch(source, c.field, c.value, path = "tasks/T.md")
		defer delete(edited)
		testing.expect_value(t, source, c.source)
		testing.expect_value(t, edited, "")
		d, ok := err.(yaml.Diagnostic)
		if !testing.expect(t, ok) {
			continue
		}
		defer yaml.destroy_diagnostic(&d)
		testing.expect_value(t, d.path, "tasks/T.md")
		testing.expect_value(t, d.code, c.code)
	}
}

@(test)
scalar_patch_reparses_with_the_same_policy :: proc(t: ^testing.T) {
	prefix :: "---\nkadai: task\nid: T\ntitle: T\nstatus: review\npriority: "
	// A directed repair leaves the unrelated due error in place.
	suffix :: "\ndue: tomorrow\n---"
	source :: prefix + "urgent" + suffix
	vocab := task.Vocabulary {
		additional_statuses = {"review"},
		priorities          = {"first"},
	}
	edited, err := plan_scalar_patch(source, .Priority, "first", vocab)
	defer delete(edited)
	if !testing.expect(t, err == nil) {
		if d, ok := err.(yaml.Diagnostic); ok {
			yaml.destroy_diagnostic(&d)
		}
		return
	}
	testing.expect_value(t, edited, prefix + "first" + suffix)

	header :: "kadai: task\nid: T\nstatus: todo\ntitle: old\n"
	limits := yaml.DEFAULT_LIMITS
	limits.bytes = len(header)
	// The requested text fits, but its required quotes exceed the header budget.
	refused, size_err := plan_scalar_patch(
		"---\n" + header + "---",
		.Title,
		"a: ",
		yaml_limits = limits,
	)
	defer delete(refused)
	testing.expect_value(t, refused, "")
	d, ok := size_err.(yaml.Diagnostic)
	if testing.expect(t, ok) {
		defer yaml.destroy_diagnostic(&d)
		testing.expect_value(t, d.code, "limit_exceeded")
		testing.expect_value(t, d.field, "yaml_document_bytes")
		testing.expect_value(t, d.observed, len(header) + 2)
	}
}
