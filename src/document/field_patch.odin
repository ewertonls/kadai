package document

import "kadai:task"
import "kadai:yaml"

@(private)
take_diagnostic :: proc(doc: ^Task_Document, index: int) -> yaml.Diagnostic {
	d := doc.diagnostics[index]
	doc.diagnostics[index] = {}
	return d
}

@(private)
same_yaml_value :: proc(a, b: ^yaml.Node) -> bool {
	if a.kind != b.kind || a.text != b.text || len(a.items) != len(b.items) || len(a.entries) != len(b.entries) {
		return false
	}
	for &item, i in a.items {
		if !same_yaml_value(&item, &b.items[i]) {
			return false
		}
	}
	for &entry, i in a.entries {
		other := &b.entries[i]
		if !same_yaml_value(&entry.key, &other.key) || !same_yaml_value(&entry.value, &other.value) {
			return false
		}
	}
	return true
}

@(private)
unrelated_fields_match :: proc(before, after: ^Task_Document, name: string) -> bool {
	// Skip the target on either side. All other key/value pairs must match in order.
	a, b := before.root.entries[:], after.root.entries[:]
	for len(a) != 0 || len(b) != 0 {
		if len(a) != 0 && a[0].key.text == name {
			a = a[1:]
			continue
		}
		if len(b) != 0 && b[0].key.text == name {
			b = b[1:]
			continue
		}
		if len(a) == 0 || len(b) == 0 || !same_yaml_value(&a[0].key, &b[0].key) ||
		   !same_yaml_value(&a[0].value, &b[0].value) {
			return false
		}
		a, b = a[1:], b[1:]
	}
	i := 0
	for issue in before.field_errors {
		if issue.field == name {
			continue
		}
		if i >= len(after.field_errors) || after.field_errors[i] != issue {
			return false
		}
		i += 1
	}
	return i == len(after.field_errors)
}

@(private)
check_patch_target :: proc(before: ^Task_Document, name: string, loc: yaml.Location) -> Header_Edit_Error {
	path := before.path
	if before.status == .Non_Task {
		return yaml.diagnostic(path, "not_task", "", "Select a Markdown document with a task discriminator.") or_return
	}
	if (before.status != .Decoded && before.status != .Invalid_Fields) ||
	   before.fields.schema_version.digits != "1" || before.fields.id == "" {
		return take_diagnostic(before, 0)
	}
	if before.status == .Invalid_Fields {
		for issue in before.field_errors {
			if issue.field == name {
				return nil
			}
		}
		return yaml.diagnostic(path, "unrelated_invalid_field", name, "Repair an invalid field before changing unrelated metadata.", loc) or_return
	}
	return nil
}

// A nil expectation requires the key to be absent after reparsing.
@(private)
Expected_Field :: struct {
	span: Byte_Range,
	value: Field_Value,
}

@(private)
verify_field_patch :: proc(
	before: ^Task_Document, edited, name: string, expected: ^Expected_Field,
	loc: yaml.Location, vocabulary: task.Vocabulary, limits: yaml.Limits,
) -> Header_Edit_Error {
	path := before.path
	after := decode_task(edited, vocabulary, before.frontmatter_limits.task_source_bytes, limits, path) or_return
	defer destroy(&after)
	if after.status != .Decoded && after.status != .Invalid_Fields {
		if len(after.diagnostics) > 0 {
			d := take_diagnostic(&after, 0)
			d.location = loc
			return d
		}
		return yaml.diagnostic(path, "invalid_proposed_document", name, "The proposed edit must preserve task identity and schema.", loc) or_return
	}
	for d, i in after.diagnostics {
		if d.field == name {
			problem := take_diagnostic(&after, i)
			problem.location = loc
			return problem
		}
	}
	node := yaml.lookup(&after.root, name)
	matches := node == nil
	if expected != nil {
		matches = node != nil && node.span == expected.span && matches_value(node, expected.value)
	}
	if !matches || !unrelated_fields_match(before, &after, name) {
		return yaml.diagnostic(path, "unsafe_source_patch", name, "Use an isolated field edit that preserves unrelated metadata.", loc) or_return
	}
	return nil
}
