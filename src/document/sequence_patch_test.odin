#+test
package document

import "core:testing"
import "core:strings"
import "kadai:yaml"

@(test)
sequence_patch_preserves_source_and_item_order :: proc(t: ^testing.T) {
	fixtures :: "../../tests/fixtures/v1/cases/patch/"
	base :: "\uFEFF---\r\nkadai: task\nid: T\r\ntitle: café\r\nstatus: todo\r\n"
	body :: "---\r\n# Markdown\n---\r\nend"
	cases := []struct {source: string, field: Sequence_Field, edit: Sequence_Edit, item, expected: string}{
		{string(#load(fixtures + "flow-sequence-add/input/project/tasks/T.md")), .Tags, .Append, "docs",
		 string(#load(fixtures + "flow-sequence-add/expected/T.md"))},
		{string(#load(fixtures + "flow-sequence-remove/input/project/tasks/T.md")), .Tags, .Remove, "cli",
		 string(#load(fixtures + "flow-sequence-remove/expected/T.md"))},
		{string(#load(fixtures + "block-sequence-add/input/project/tasks/T.md")), .Tags, .Append, "docs",
		 string(#load(fixtures + "block-sequence-add/expected/T.md"))},
		{string(#load(fixtures + "block-sequence-remove/input/project/tasks/T.md")), .Tags, .Remove, "cli",
		 string(#load(fixtures + "block-sequence-remove/expected/T.md"))},
		{base + "depends_on: [aB,  'B',] # keep\r\n" + body, .Depends_On, .Remove, "AB",
		 base + "depends_on: ['B',] # keep\r\n" + body},
		{base + "depends_on: [aB,  'B',]\r\n" + body, .Depends_On, .Append, "Null",
		 base + "depends_on: [aB,  'B',  'Null',]\r\n" + body},
		{base + "tags: [ v1, ]\r\n" + body, .Tags, .Remove, "v1", base + "tags: [  ]\r\n" + body},
		{base + "'tags': []\r\n" + body, .Tags, .Append, "-", base + "'tags': ['-']\r\n" + body},
		{base + "tags: # keep\r\n  -  cli # item\r\n\r\npriority: low\n" + body, .Tags, .Append, "docs",
		 base + "tags: # keep\r\n  -  cli # item\r\n  -  docs\r\n\r\npriority: low\n" + body},
		{base + "tags: # keep\r\n- cli  \r\n" + body, .Tags, .Remove, "cli", base + "tags: # keep\r\n  []  \r\n" + body},
		{base + body, .Depends_On, .Append, "T-2", base + "depends_on: [T-2]\r\n" + body},
		{base + "tags:  ~ # keep\r\n" + body, .Tags, .Append, "null", base + "tags:  ['null'] # keep\r\n" + body},
		{base + "tags: # keep\r\n" + body, .Tags, .Append, "cli", base + "tags: [cli] # keep\r\n" + body},
		// Repair the invalid item. The unrelated due error and its bytes survive.
		{base + "tags: [cli, 'bad, tag']\r\ndue: tomorrow\r\n" + body, .Tags, .Remove, "bad, tag",
		 base + "tags: [cli]\r\ndue: tomorrow\r\n" + body},
	}
	for c in cases {
		edited, err := plan_sequence_patch(c.source, c.field, c.edit, c.item)
		defer delete(edited)
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
sequence_patch_refuses_invalid_or_ambiguous_items :: proc(t: ^testing.T) {
	base :: "---\nkadai: task\nid: T\ntitle: T\nstatus: todo\n"
	cases := []struct {header: string, field: Sequence_Field, edit: Sequence_Edit, item, code: string}{
		{"depends_on: [Ab]\n", .Depends_On, .Append, "aB", "duplicate_dependency"},
		{"tags: [cli]\n", .Tags, .Append, "x, y", "invalid_tags"},
		{"depends_on: [AB, ab]\n", .Depends_On, .Remove, "aB", "ambiguous_sequence_item"},
		{"depends_on: ['K']\n", .Depends_On, .Remove, "K", "missing_sequence_item"},
		{"tags: [cli]\n", .Tags, .Remove, "CLI", "missing_sequence_item"},
		{"tags: null\n", .Tags, .Remove, "cli", "missing_sequence_item"},
		{"tags: {}\n", .Tags, .Append, "cli", "unsafe_source_patch"},
		{"due: tomorrow\n", .Tags, .Append, "cli", "unrelated_invalid_field"},
	}
	for c in cases {
		source := strings.concatenate({base, c.header, "---"})
		defer delete(source)
		edited, err := plan_sequence_patch(source, c.field, c.edit, c.item, path = "tasks/T.md")
		defer delete(edited)
		testing.expect_value(t, edited, "")
		d, ok := err.(yaml.Diagnostic)
		if testing.expect(t, ok) {
			defer yaml.destroy_diagnostic(&d)
			testing.expect_value(t, d.code, c.code)
			testing.expect_value(t, d.path, "tasks/T.md")
		}
	}
}

@(test)
sequence_patch_keeps_item_comments_or_refuses :: proc(t: ^testing.T) {
	fixtures :: "../../tests/fixtures/v1/cases/patch/"
	base :: "---\nkadai: task\nid: T\ntitle: T\nstatus: todo\n"
	cases := []struct {source, comment, suffix: string}{
		{string(#load(fixtures + "unsafe-comment-removal/input/project/tasks/T.md")), "# owner note", "  - cli\n---\n"},
		{string(#load(fixtures + "unsupported-flow-comment/input/project/tasks/T.md")), "# ambiguous", "  cli]\n---\n"},
	}
	for c in cases {
		edited, err := plan_sequence_patch(c.source, .Tags, .Remove, "backend")
		defer delete(edited)
		if err == nil {
			testing.expect(t, strings.has_prefix(edited, base + "tags:"))
			testing.expect(t, strings.has_suffix(edited, c.suffix))
			testing.expect_value(t, strings.count(edited, c.comment), 1)
			doc := decode_task(edited)
			defer destroy(&doc)
			if testing.expect_value(t, len(doc.fields.tags), 1) {
				testing.expect_value(t, doc.fields.tags[0], "cli")
			}
			continue
		}
		testing.expect_value(t, edited, "")
		d, ok := err.(yaml.Diagnostic)
		if testing.expect(t, ok) {
			defer yaml.destroy_diagnostic(&d)
			testing.expect_value(t, d.code, "unsafe_source_patch")
		}
	}
}

@(test)
sequence_patch_charges_the_new_item_and_its_syntax :: proc(t: ^testing.T) {
	header :: "kadai: task\nid: T\ntitle: T\nstatus: todo\ntags: []\n"
	source :: "---\n" + header + "---"
	encoded :: "'null'"
	cases := []struct {bytes, nodes: int, budget: string}{
		{len(header)+len(encoded), 12, ""}, {len(header)+len(encoded)-1, 12, "yaml_document_bytes"},
		{len(header)+len(encoded), 11, "yaml_nodes_document"},
	}
	for c in cases {
		limits := yaml.Limits{bytes = c.bytes, nodes = c.nodes, depth = 8}
		edited, err := plan_sequence_patch(source, .Tags, .Append, "null", yaml_limits = limits)
		defer delete(edited)
		if err == nil {
			testing.expect_value(t, c.budget, "")
			testing.expect_value(t, len(edited), len(source) + len(encoded))
			continue
		}
		testing.expect_value(t, edited, "")
		d, ok := err.(yaml.Diagnostic)
		if testing.expect(t, ok) {
			defer yaml.destroy_diagnostic(&d)
			testing.expect_value(t, d.code, "limit_exceeded")
			testing.expect_value(t, d.field, c.budget)
		}
	}
}
