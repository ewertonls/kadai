package document

import "kadai:task"
import "kadai:yaml"

// Identity, schema version and the discriminator have separate mutation rules.
Scalar_Field :: enum {Title, Status, Priority, Parent, Due}

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
	if len(before.root.entries) != len(after.root.entries) {
		return false
	}
	for &entry, i in before.root.entries {
		other := &after.root.entries[i]
		if !same_yaml_value(&entry.key, &other.key) {
			return false
		}
		if entry.key.text != name && !same_yaml_value(&entry.value, &other.value) {
			return false
		}
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

// Produce owned Markdown for a single existing task field. nil denotes YAML null.
// This is the document-local preflight; collection and persistence checks belong
// to the operation that applies the proposal. Ownership matches compose_header_edit.
@(require_results)
plan_scalar_patch :: proc(
	source: string,
	field: Scalar_Field,
	value: Maybe(string),
	vocabulary := task.Vocabulary{},
	task_source_bytes := DEFAULT_FRONTMATTER_LIMITS.task_source_bytes,
	yaml_limits := yaml.DEFAULT_LIMITS,
	path := "",
) -> (candidate: string, err: Header_Edit_Error) {
	names := [Scalar_Field]string{.Title = "title", .Status = "status", .Priority = "priority", .Parent = "parent", .Due = "due"}
	name := names[field]
	before := decode_task(source, vocabulary, task_source_bytes, yaml_limits, path) or_return
	defer destroy(&before)
	if before.status == .Non_Task {
		return "", yaml.diagnostic(path, "not_task", "", "Select a Markdown document with a task discriminator.") or_return
	}
	if (before.status != .Decoded && before.status != .Invalid_Fields) ||
	   before.fields.schema_version.digits != "1" || before.fields.id == "" {
		return "", take_diagnostic(&before, 0)
	}
	node := yaml.lookup(&before.root, name)
	loc: yaml.Location
	if node != nil {
		loc = markdown_location(before.parts.header, node.location)
	}
	if before.status == .Invalid_Fields {
		target_invalid := false
		for issue in before.field_errors {
			if issue.field == name {
				target_invalid = true
				break
			}
		}
		if !target_invalid {
			return "", yaml.diagnostic(path, "unrelated_invalid_field", name, "Repair an invalid field before changing unrelated metadata.", loc) or_return
		}
	}

	if node == nil {
		return "", yaml.diagnostic(path, "missing_field", name, "Select an existing top-level scalar to replace.") or_return
	}
	raw := source[loc.span.start:loc.span.end]
	if before.root.style != .Block || !single_line_token(node, raw) {
		return "", yaml.diagnostic(path, "unsafe_source_patch", name, "Use a single-line scalar token in a block mapping.", loc) or_return
	}

	edited := compose_scalar(&before, name, node, raw, value) or_return
	defer if err != nil {
		delete(edited)
	}
	after := decode_task(edited, vocabulary, task_source_bytes, yaml_limits, path) or_return
	defer destroy(&after)
	if after.status != .Decoded && after.status != .Invalid_Fields {
		if len(after.diagnostics) > 0 {
			d := take_diagnostic(&after, 0)
			d.location = loc // edited source will be discarded
			return "", d
		}
		return "", yaml.diagnostic(path, "invalid_proposed_document", name, "The proposed edit must preserve task identity and schema.", loc) or_return
	}
	// The splice copied the prefix and suffix verbatim. Verify that exactly
	// the inserted bytes still form the target token in the reparsed document.
	updated := yaml.lookup(&after.root, name)
	expected_span := Byte_Range{node.span.start, node.span.end + (len(edited) - len(source))}
	if updated != nil && updated.span == expected_span && matches_scalar(updated, value) {
		for d, i in after.diagnostics {
			if d.field == name {
				problem := take_diagnostic(&after, i)
				problem.location = loc
				return "", problem
			}
		}
		if unrelated_fields_match(&before, &after, name) {
			return edited, nil
		}
	}
	return "", yaml.diagnostic(path, "unsafe_source_patch", name, "The proposed scalar must preserve unrelated metadata and its source boundaries.", loc) or_return
}
