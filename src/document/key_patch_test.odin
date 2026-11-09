#+test
package document

import "core:testing"
import "kadai:yaml"

@(test)
key_patch_changes_only_the_requested_entry :: proc(t: ^testing.T) {
	fixtures :: "../../tests/fixtures/v1/cases/patch/"
	header :: "kadai: task\nid: T\ntitle: T\nstatus: todo\n"
	prefix :: "---\n" + header
	// Both adjacent lines use CRLF. The rest of this document mixes conventions.
	anchor :: "\uFEFF---\r\n  kadai: task\n  id: T\r\n  'title': café # résumé\r\n"
	suffix :: "  status: todo\r\n---\n# Body\r\n---\nend"
	cases := []struct {source: string, field: Metadata_Field, edit: Key_Edit, expected: string}{
		{string(#load(fixtures + "insert-priority/input/project/tasks/T.md")), .Priority, Insert_Field{"high", "status"},
		 string(#load(fixtures + "insert-priority/expected/T.md"))},
		{string(#load(fixtures + "remove-priority/input/project/tasks/T.md")), .Priority, Unset_Field{},
		 string(#load(fixtures + "remove-priority/expected/T.md"))},
		{anchor + suffix, .Parent, Insert_Field{"NULL", "title"}, anchor + "  parent: 'NULL'\r\n" + suffix},
		{anchor + "  \"par\\u0065nt\":\t~  \r\n" + suffix, .Parent, Unset_Field{}, anchor + suffix},
		{prefix + "---", .Due, Insert_Field{}, prefix + "due: null\n---"},
		{prefix + "due:   \n---", .Due, Unset_Field{}, prefix + "---"},
		{prefix + "---", .Tags, Insert_Field{value = Inline_Collection{"[cli, docs]"}}, prefix + "tags: [cli, docs]\n---"},
		{prefix + "custom: {key: 'a # b'}\n---", .Custom, Unset_Field{}, prefix + "---"},
		// Block collection end marks extend past blank lines to the next key.
		{prefix + "depends_on:\n  - A\n  - B\n\ndue: null\n---", .Depends_On, Unset_Field{}, prefix + "\ndue: null\n---"},
		// Inserting the missing title repairs only that field. The due error is preserved.
		{"---\nkadai: task\nid: T\nstatus: todo\ndue: tomorrow\n---", .Title, Insert_Field{"A: B", "id"},
		 "---\nkadai: task\nid: T\ntitle: 'A: B'\nstatus: todo\ndue: tomorrow\n---"},
	}
	for c in cases {
		edited, err := plan_key_patch(c.source, c.field, c.edit)
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
key_patch_refuses_collisions_and_invalid_proposals :: proc(t: ^testing.T) {
	fixtures :: "../../tests/fixtures/v1/cases/patch/"
	prefix :: "---\nkadai: task\nid: T\ntitle: T\nstatus: todo\n"
	cases := []struct {source: string, field: Metadata_Field, edit: Key_Edit, code: string}{
		{string(#load(fixtures + "required-unset/input/project/tasks/T.md")), .Status, Unset_Field{}, "required_field_unset"},
		{prefix + "'priority': low\n---", .Priority, Insert_Field{value = "high"}, "field_already_present"},
		{prefix + "---", .Priority, Insert_Field{"high", "parent"}, "missing_field"},
		{prefix + "---", .Priority, Unset_Field{}, "missing_field"},
		{prefix + "---", .Priority, Insert_Field{value = "urgent"}, "invalid_priority"},
		{prefix + "due: bad\n---", .Priority, Insert_Field{value = "high"}, "unrelated_invalid_field"},
		{prefix + "---", .Tags, Insert_Field{value = Inline_Collection{"[cli, cli]"}}, "duplicate_tag"},
		// An alias introduced by the proposed value must fail during the candidate reparse.
		{prefix + "---", .Custom, Insert_Field{value = Inline_Collection{"{link: *ref}"}}, "unsupported_alias"},
		{prefix + "---", .Custom, Insert_Field{value = Inline_Collection{"{} # trailing"}}, "unsafe_source_patch"},
		{prefix + "---", .Custom, Insert_Field{value = Inline_Collection{"{}\npriority: high"}}, "unsafe_source_patch"},
		{prefix + "tags:\n  - cli # note\n  - more\n---", .Tags, Unset_Field{}, "comment_ownership_ambiguous"},
		{prefix + "due: null # keep\n---", .Due, Unset_Field{}, "comment_ownership_ambiguous"},
		// Removing this line would let the preceding scalar absorb another newline.
		{prefix + "custom:\n  note: |+\n    text\npriority: low\n\n---", .Priority, Unset_Field{}, "unsafe_source_patch"},
	}
	for c in cases {
		edited, err := plan_key_patch(c.source, c.field, c.edit, path = "tasks/T.md")
		defer delete(edited)
		testing.expect_value(t, edited, "")
		d, ok := err.(yaml.Diagnostic)
		if testing.expect(t, ok) {
			defer yaml.destroy_diagnostic(&d)
			testing.expect_value(t, d.path, "tasks/T.md")
			testing.expect_value(t, d.code, c.code)
		}
	}
}

@(test)
key_patch_preserves_ambiguous_boundaries_or_refuses :: proc(t: ^testing.T) {
	fixtures :: "../../tests/fixtures/v1/cases/patch/"
	mixed :: "---\r\nkadai: task\nid: T\r\ntitle: T\nstatus: todo\r\n"
	comment :: "---\nkadai: task\nid: T\ntitle: T\nstatus: todo\n# Keep discussion associated with priority?\n"
	cases := []struct {source: string, edit: Key_Edit, code, expected, alternate: string}{
		{string(#load(fixtures + "unsafe-line-ending-insert/input/project/tasks/T.md")), Insert_Field{value = "high"},
		 "unsafe_line_ending", mixed + "priority: high\r\n---\n", mixed + "priority: high\n---\n"},
		{string(#load(fixtures + "remove-key-with-leading-comment/input/project/tasks/T.md")), Unset_Field{},
		 "comment_ownership_ambiguous", comment + "---\n", ""},
	}
	for c in cases {
		edited, err := plan_key_patch(c.source, .Priority, c.edit)
		defer delete(edited)
		if err == nil {
			testing.expect(t, edited != "" && (edited == c.expected || edited == c.alternate))
			continue
		}
		testing.expect_value(t, edited, "")
		d, ok := err.(yaml.Diagnostic)
		if testing.expect(t, ok) {
			defer yaml.destroy_diagnostic(&d)
			testing.expect_value(t, d.code, c.code)
		}
	}
}

@(test)
inserting_a_key_charges_syntax_bytes_and_nodes :: proc(t: ^testing.T) {
	source :: "---\nkadai: task\nid: T\nstatus: todo\n---"
	expected :: "---\nkadai: task\nid: T\nstatus: todo\ntitle: 'A: B'\n---"
	header_bytes :: len(expected) - len("---\n") - len("---")
	cases := []struct {bytes, nodes: int, budget: string}{
		{header_bytes, 9, ""}, {header_bytes-1, 9, "yaml_document_bytes"}, {header_bytes, 8, "yaml_nodes_document"},
	}
	for c in cases {
		limits := yaml.Limits{bytes = c.bytes, nodes = c.nodes, depth = 8}
		edited, err := plan_key_patch(source, .Title, Insert_Field{value = "A: B"}, yaml_limits = limits)
		defer delete(edited)
		if err == nil {
			testing.expect_value(t, c.budget, "")
			testing.expect_value(t, edited, expected)
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
