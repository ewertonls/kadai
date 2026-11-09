#+test
package document

import "core:fmt"
import "core:slice"
import "core:testing"
import "kadai:task"
import "kadai:yaml"

@(test)
decode_fields_and_original_source :: proc(t: ^testing.T) {
	header :: "# café\r\n'kadai': task\nid: 0001\r\ntitle: 123\nstatus: review\npriority: first\n" +
	          "parent: Base\ndue: 2024-02-29T18:30:00-03:00\ntags: [v0.1, cli/parser]\n" +
	          "depends_on:\n  - 001\n  - Two\nschema_version: 0x01\n" +
	          "'future key': {note: \"olá\"} # retained\r\n"
	body :: "\n---\n# text\r\n\x60\x60\x60\n---\n\x60\x60\x60"
	source :: "\uFEFF---\r\n" + header + "---\r\n" + body
	doc := decode_task(source, task.Vocabulary{[]string{"review"}, []string{"first"}})
	defer destroy(&doc)
	if !testing.expect_value(t, doc.status, .Invalid_Fields) do return
	testing.expect(t, slice.equal(doc.field_errors[:], []Field_Error{{"future key", .Unknown_Field}}))
	f := doc.fields
	testing.expect_value(t, f.id, "0001")
	testing.expect_value(t, f.title, "123")
	testing.expect_value(t, f.status, "review")
	testing.expect_value(t, f.priority, "first")
	testing.expect_value(t, f.schema_version, yaml.Integer{"1", 16, false})
	testing.expect_value(t, f.parent, "Base")
	testing.expect_value(t, f.due, "2024-02-29T18:30:00-03:00")
	testing.expect(t, slice.equal(f.tags[:], []string{"v0.1", "cli/parser"}))
	testing.expect(t, slice.equal(f.depends_on[:], []string{"001", "Two"}))
	testing.expect_value(t, doc.source[doc.parts.header.start:doc.parts.header.end], header)
	testing.expect_value(t, doc.source[doc.parts.body.start:doc.parts.body.end], body)
	raw_header := doc.source[doc.parts.header.start:doc.parts.header.end]
	entry := doc.root.entries[len(doc.root.entries)-1]
	testing.expect_value(t, raw_header[entry.key.span.start:entry.key.span.end], "'future key'")
	testing.expect_value(t, raw_header[entry.value.span.start:entry.value.span.end], "{note: \"olá\"}")
}

@(test)
decode_nulls_and_schema_envelope :: proc(t: ^testing.T) {
	nulls := string(#load("../../tests/fixtures/v1/cases/yaml/null-optional/input/project/tasks/null.md"))
	doc := decode_task(nulls)
	defer destroy(&doc)
	if !testing.expect_value(t, doc.status, .Decoded) do return
	testing.expect_value(t, doc.fields.id, "NULL")
	testing.expect_value(t, doc.fields.schema_version, yaml.Integer{"1", 10, false})
	testing.expect_value(t, doc.fields.priority, "")
	testing.expect_value(t, doc.fields.parent, "")
	testing.expect_value(t, doc.fields.due, "")
	testing.expect_value(t, len(doc.fields.tags) + len(doc.fields.depends_on), 0)
	testing.expect_value(t, yaml.lookup(&doc.root, "tags").kind, .Sequence)
	testing.expect_value(t, yaml.lookup(&doc.root, "depends_on").kind, .Null)
	testing.expect_value(t, doc.fields.custom.kind, .Mapping)

	future := string(#load("../../tests/fixtures/v1/cases/recognition/future-schema/input/project/tasks/future.md"))
	unsupported := decode_task(future)
	defer destroy(&unsupported)
	testing.expect_value(t, unsupported.status, .Unsupported_Schema)
	testing.expect_value(t, unsupported.fields.id, "FUTURE")
	testing.expect_value(t, unsupported.fields.schema_version, yaml.Integer{"2", 10, false})
	testing.expect_value(t, unsupported.fields.status, "")
	testing.expect_value(t, len(unsupported.field_errors), 0)

	ordinary_inputs := []string{"# note", "---\n---", "---\ncustom: {kadai: task}\n---", "---\nkadai: note\n---"}
	for input in ordinary_inputs {
		ordinary := decode_task(input)
		defer destroy(&ordinary)
		testing.expect_value(t, ordinary.status, .Non_Task)
	}
}

@(test)
decode_custom_core_scalars :: proc(t: ^testing.T) {
	source := string(#load("../../tests/fixtures/v1/cases/yaml/numeric-core/input/project/tasks/numbers.md"))
	doc := decode_task(source)
	defer destroy(&doc)
	if !testing.expect_value(t, doc.status, .Decoded) do return
	cases := []struct {key: string, kind: yaml.Node_Kind, text: string}{
		{"no_word", .String, "no"}, {"true_value", .Boolean, "true"}, {"false_value", .Boolean, "false"},
		{"large", .Integer, "1234567890123456789012345678901234567890"},
		{"leading", .Integer, "0007"}, {"hex", .Integer, "0x2A"}, {"octal", .Integer, "0o52"},
		{"exp", .Float, "1.2e+9"}, {"nan", .Float, ".nan"}, {"inf", .Float, ".inf"},
		{"neg_inf", .Float, "-.inf"}, {"quoted", .String, "123"}, {"date", .String, "2026-11-08"},
	}
	for c in cases {
		value := yaml.lookup(doc.fields.custom, c.key)
		if !testing.expect(t, value != nil, c.key) do continue
		testing.expect_value(t, value.kind, c.kind)
		testing.expect_value(t, value.text, c.text)
	}
	integers := []struct {key: string, n: yaml.Integer}{
		{"leading", {"7", 10, false}}, {"signed", {"42", 10, true}},
		{"hex", {"2A", 16, false}}, {"octal", {"52", 8, false}},
	}
	for c in integers {
		n, ok := yaml.integer_value(yaml.lookup(doc.fields.custom, c.key))
		testing.expect(t, ok)
		testing.expect_value(t, n, c.n)
	}

	flow := string(#load("../../tests/fixtures/v1/cases/yaml/flow-block/input/project/tasks/flow.md"))
	nested := decode_task(flow)
	defer destroy(&nested)
	if !testing.expect_value(t, nested.status, .Decoded) do return
	custom := nested.fields.custom
	testing.expect_value(t, yaml.lookup(custom, "multiline").text, "line 1\nline 2")
	testing.expect_value(t, yaml.lookup(custom, "folded").text, "part one part two")
	owners := yaml.lookup(yaml.lookup(custom, "nested"), "owners")
	testing.expect_value(t, owners.items[0].text, "Alice")
	testing.expect_value(t, owners.items[1].text, "Bob")
}

@(test)
field_validation :: proc(t: ^testing.T) {
	// Each row has one schema error. Keep its valid ID for diagnostic reads.
	cases := []struct {field, invalid: string, reason: Field_Error_Reason}{
		{"title", "title: null", .Required_Null}, {"title", "", .Missing},
		{"title", "title: \"a\\nb\"", .Invalid_Value}, {"title", "title: '　'", .Invalid_Value},
		{"status", "status: pending", .Invalid_Value}, {"priority", "priority: urgent", .Invalid_Value},
		{"parent", "parent: -invalid", .Invalid_Value}, {"parent", "parent: []", .Wrong_Type},
		{"tags", "tags: [one, one]", .Duplicate_Item}, {"tags", "tags: [two, BAD]", .Invalid_Value},
		{"tags", "tags: tag", .Wrong_Type}, {"depends_on", "depends_on: [Ab, aB]", .Duplicate_Item},
		{"depends_on", "depends_on: [~]", .Wrong_Type}, {"due", "due: 2026-02-29", .Invalid_Value},
		{"due", "due: 2000-01-01T00:00:60Z", .Invalid_Value}, {"due", "due: 2000-01-01T00:00:00+00:60", .Invalid_Value},
		{"custom", "custom: [x]", .Wrong_Type}, {"custom", "custom: {nested: [{10: true}]}", .Invalid_Key},
		{"custom", "custom: {\"bad\\nkey\": hi}", .Invalid_Key},
		{"schema_version", "schema_version: '1'", .Invalid_Value}, {"schema_version", "schema_version: 0", .Invalid_Value},
	}
	for c in cases {
		title := "title: ok" if c.field != "title" else ""
		status := "status: todo" if c.field != "status" else ""
		source := fmt.tprintf("---\nkadai: task\nid: T\n%s\n%s\n%s\n---", title, status, c.invalid)
		doc := decode_task(source)
		defer destroy(&doc)
		testing.expect_value(t, doc.status, .Invalid_Fields)
		testing.expect(t, slice.equal(doc.field_errors[:], []Field_Error{{c.field, c.reason}}))
		testing.expect_value(t, doc.fields.id, "T")
		testing.expect_value(t, len(doc.fields.tags) + len(doc.fields.depends_on), 0)
	}
}
