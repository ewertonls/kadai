package document

import "core:strings"
import "core:unicode"
import "kadai:task"
import "kadai:yaml"

Task_Fields :: struct {
	id, title, status, priority, parent, due: string,
	schema_version: yaml.Integer,
	tags, depends_on: [dynamic]string,
	custom: ^yaml.Node,
}

Field_Error_Reason :: enum {Missing, Required_Null, Wrong_Type, Invalid_Value, Invalid_Key, Duplicate_Item, Unknown_Field}
Field_Error :: struct {
	field: string,
	reason: Field_Error_Reason,
}

Decode_Status :: enum {Non_Task, Decoded, Invalid_Fields, Unsupported_Schema, Boundary_Error, YAML_Error}

Task_Document :: struct {
	source: string,
	parts: Frontmatter,
	root: yaml.Node,
	fields: Task_Fields,
	status: Decode_Status,
	boundary_status: Frontmatter_Status,
	yaml_error: yaml.Error,
	field_errors: [dynamic]Field_Error,
}

destroy :: proc(doc: ^Task_Document) {
	delete(doc.field_errors)
	delete(doc.fields.tags)
	delete(doc.fields.depends_on)
	yaml.destroy(&doc.root)
	doc^ = {}
}

// Source is borrowed and must outlive the result. Node spans are relative to
// parts.header.start. Always destroy the returned document, including on error.
decode_task :: proc(
	source: string,
	vocabulary := task.Vocabulary{},
	task_source_bytes := DEFAULT_FRONTMATTER_LIMITS.task_source_bytes,
	yaml_limits := yaml.DEFAULT_LIMITS,
) -> (doc: Task_Document) {
	doc.source = source
	if !yaml.valid_limits(yaml_limits) {
		doc.status, doc.boundary_status = .Boundary_Error, .Invalid_Limits
		return
	}
	doc.parts, doc.boundary_status = extract_frontmatter(source, {task_source_bytes, yaml_limits.bytes})
	if doc.boundary_status == .Absent do return
	if doc.boundary_status != .Present {
		doc.status = .Boundary_Error
		return
	}
	header := doc.parts.header
	doc.root, doc.yaml_error = yaml.parse_mapping(source[header.start:header.end], yaml_limits)
	if doc.yaml_error != .None {
		doc.status = .YAML_Error
		return
	}
	marker := yaml.lookup(&doc.root, "kadai")
	if marker == nil || marker.kind != .String || marker.text != "task" do return

	read_text(&doc, "id", &doc.fields.id, vocabulary)
	version := yaml.lookup(&doc.root, "schema_version")
	if version == nil || version.kind == .Null {
		doc.fields.schema_version = {digits = "1", base = 10}
	} else {
		n, ok := yaml.integer_value(version)
		if !ok || n.negative || n.digits == "0" {
			append(&doc.field_errors, Field_Error{"schema_version", .Invalid_Value})
			doc.status = .Invalid_Fields
			return
		}
		doc.fields.schema_version = n
		if n.digits != "1" {
			doc.status = .Unsupported_Schema
			return
		}
	}

	read_text(&doc, "title",    &doc.fields.title,    vocabulary)
	read_text(&doc, "status",   &doc.fields.status,   vocabulary)
	read_text(&doc, "priority", &doc.fields.priority, vocabulary)
	read_text(&doc, "parent",   &doc.fields.parent,   vocabulary)
	read_text(&doc, "due",      &doc.fields.due,      vocabulary)
	read_list(&doc, "tags", &doc.fields.tags)
	read_list(&doc, "depends_on", &doc.fields.depends_on)
	if custom := yaml.lookup(&doc.root, "custom"); custom != nil && custom.kind != .Null {
		if custom.kind != .Mapping {
			append(&doc.field_errors, Field_Error{"custom", .Wrong_Type})
		} else if !valid_custom_keys(custom) {
			append(&doc.field_errors, Field_Error{"custom", .Invalid_Key})
		} else {
			doc.fields.custom = custom
		}
	}
	for entry in doc.root.entries {
		if entry.key.kind != .String {
			append(&doc.field_errors, Field_Error{entry.key.text, .Invalid_Key})
			continue
		}
		switch entry.key.text {
		case "kadai", "id", "title", "status", "schema_version", "priority", "parent", "due", "tags", "depends_on", "custom":
		case: append(&doc.field_errors, Field_Error{entry.key.text, .Unknown_Field})
		}
	}
	doc.status = .Decoded if len(doc.field_errors) == 0 else .Invalid_Fields
	return
}

@(private)
read_text :: proc(doc: ^Task_Document, name: string, dst: ^string, vocab: task.Vocabulary) {
	node := yaml.lookup(&doc.root, name)
	required := name == "id" || name == "title" || name == "status"
	if node == nil || node.kind == .Null {
		if required {
			reason: Field_Error_Reason = .Missing if node == nil else .Required_Null
			append(&doc.field_errors, Field_Error{name, reason})
		}
		return
	}
	if node.kind == .Sequence || node.kind == .Mapping {
		append(&doc.field_errors, Field_Error{name, .Wrong_Type})
		return
	}
	s := node.text
	valid := false
	switch name {
	case "id", "parent": valid = task.valid_id(s)
	case "title":        valid = task.valid_title(s)
	case "status":       valid = task.valid_status(s, vocab)
	case "priority":     valid = task.valid_priority(s, vocab)
	case "due":          valid = task.valid_due(s)
	}
	if valid {
		dst^ = s
	} else {
		append(&doc.field_errors, Field_Error{name, .Invalid_Value})
	}
}

@(private)
read_list :: proc(doc: ^Task_Document, name: string, dst: ^[dynamic]string) {
	node := yaml.lookup(&doc.root, name)
	if node == nil || node.kind == .Null do return
	if node.kind != .Sequence {
		append(&doc.field_errors, Field_Error{name, .Wrong_Type})
		return
	}
	dependencies := name == "depends_on"
	valid_item := task.valid_id if dependencies else task.valid_tag
	seen: map[string]bool
	defer {
		if dependencies {
			for key in seen do delete(key)
		}
		delete(seen)
	}
	for item in node.items {
		if item.kind == .Mapping || item.kind == .Sequence || item.kind == .Null {
			append(&doc.field_errors, Field_Error{name, .Wrong_Type})
			return
		}
		if !valid_item(item.text) {
			append(&doc.field_errors, Field_Error{name, .Invalid_Value})
			return
		}
		key := item.text
		if dependencies do key = strings.to_lower(key) // valid IDs are ASCII
		if key in seen {
			if dependencies do delete(key)
			append(&doc.field_errors, Field_Error{name, .Duplicate_Item})
			return
		}
		seen[key] = true
	}
	for item in node.items do append(dst, item.text)
}

@(private)
valid_custom_keys :: proc(node: ^yaml.Node) -> bool {
	for &entry in node.entries {
		if entry.key.kind != .String || entry.key.text == "" do return false
		for c in entry.key.text {
			if unicode.is_control(c) do return false
		}
		if !valid_custom_keys(&entry.value) do return false
	}
	for &item in node.items {
		if !valid_custom_keys(&item) do return false
	}
	return true
}
