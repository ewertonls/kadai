package document

import "core:strings"
import "core:unicode"
import "kadai:task"
import "kadai:yaml"

Task_Fields :: struct {
	id, title, status, priority, parent, due: string,
	schema_version:                           yaml.Integer,
	tags, depends_on:                         [dynamic]string,
	custom:                                   ^yaml.Node,
}

Field_Error_Reason :: enum {
	Missing,
	Required_Null,
	Wrong_Type,
	Invalid_Value,
	Invalid_Key,
	Duplicate_Item,
	Unknown_Field,
}
Field_Error :: struct {
	field:  string,
	reason: Field_Error_Reason,
}

Decode_Status :: enum {
	Non_Task,
	Decoded,
	Invalid_Fields,
	Unsupported_Schema,
	Boundary_Error,
	YAML_Error,
}

Task_Document :: struct {
	source, path:       string,
	parts:              Frontmatter,
	frontmatter_limits: Frontmatter_Limits,
	root:               yaml.Node,
	fields:             Task_Fields,
	status:             Decode_Status,
	boundary_status:    Frontmatter_Status,
	yaml_error:         yaml.Error,
	field_errors:       [dynamic]Field_Error,
	diagnostics:        [dynamic]yaml.Diagnostic,
}

destroy :: proc(doc: ^Task_Document) {
	for &d in doc.diagnostics do yaml.destroy_diagnostic(&d)
	delete(doc.diagnostics)
	delete(doc.field_errors)
	delete(doc.fields.tags)
	delete(doc.fields.depends_on)
	yaml.destroy(&doc.root)
	doc^ = {}
}

// Source and path are borrowed and must outlive the result. Node spans are relative to
// parts.header.start. Always destroy the returned document, including on error.
decode_task :: proc(
	source: string,
	vocabulary := task.Vocabulary{},
	task_source_bytes := DEFAULT_FRONTMATTER_LIMITS.task_source_bytes,
	yaml_limits := yaml.DEFAULT_LIMITS,
	path := "",
) -> (
	doc: Task_Document,
) {
	doc.source, doc.path = source, path
	doc.frontmatter_limits = {task_source_bytes, yaml_limits.bytes}
	failure: yaml.Diagnostic
	if !yaml.valid_limits(yaml_limits) {
		doc.status, doc.boundary_status = .Boundary_Error, .Invalid_Limits
		append(&doc.diagnostics, yaml.invalid_limits_diagnostic(path, yaml_limits))
		return
	}
	doc.parts, doc.boundary_status = extract_frontmatter(
		source,
		doc.frontmatter_limits,
		&failure,
		path,
	)
	if doc.boundary_status == .Absent do return
	if doc.boundary_status != .Present {
		doc.status = .Boundary_Error
		append(&doc.diagnostics, failure)
		return
	}
	header := doc.parts.header
	doc.root, doc.yaml_error = yaml.parse_mapping(
		source[header.start:header.end],
		yaml_limits,
		&failure,
		path,
	)
	if doc.yaml_error != .None {
		doc.status = .YAML_Error
		failure.location = markdown_location(header, failure.location)
		append(&doc.diagnostics, failure)
		return
	}
	marker := yaml.lookup(&doc.root, "kadai")
	if marker == nil || marker.kind != .String || marker.text != "task" do return

	read_text(&doc, "id", &doc.fields.id, vocabulary)
	version := yaml.lookup(&doc.root, "schema_version")
	if version == nil || version.kind == .Null {
		doc.fields.schema_version = {
			digits = "1",
			base   = 10,
		}
	} else {
		n, ok := yaml.integer_value(version)
		if !ok || n.negative || n.digits == "0" {
			field_error(&doc, "schema_version", .Invalid_Value, version)
			doc.status = .Invalid_Fields
			return
		}
		doc.fields.schema_version = n
		if n.digits != "1" {
			doc.status = .Unsupported_Schema
			append(
				&doc.diagnostics,
				yaml.diagnostic(
					path,
					"unsupported_task_schema",
					"schema_version",
					"Use a Kadai version that supports this task schema.",
					markdown_location(header, version.location),
				),
			)
			return
		}
	}

	read_text(&doc, "title", &doc.fields.title, vocabulary)
	read_text(&doc, "status", &doc.fields.status, vocabulary)
	read_text(&doc, "priority", &doc.fields.priority, vocabulary)
	read_text(&doc, "parent", &doc.fields.parent, vocabulary)
	read_text(&doc, "due", &doc.fields.due, vocabulary)
	read_list(&doc, "tags", &doc.fields.tags)
	read_list(&doc, "depends_on", &doc.fields.depends_on)
	if custom := yaml.lookup(&doc.root, "custom"); custom != nil && custom.kind != .Null {
		if custom.kind != .Mapping {
			field_error(&doc, "custom", .Wrong_Type, custom)
		} else if key := invalid_custom_key(custom); key != nil {
			field_error(&doc, "custom", .Invalid_Key, key)
		} else {
			doc.fields.custom = custom
		}
	}
	for &entry in doc.root.entries {
		if entry.key.kind != .String {
			field_error(&doc, entry.key.text, .Invalid_Key, &entry.key)
			continue
		}
		switch entry.key.text {
		case "kadai",
		     "id",
		     "title",
		     "status",
		     "schema_version",
		     "priority",
		     "parent",
		     "due",
		     "tags",
		     "depends_on",
		     "custom":
		case:
			field_error(&doc, entry.key.text, .Unknown_Field, &entry.key)
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
			field_error(doc, name, reason, node)
		}
		return
	}
	if node.kind == .Sequence || node.kind == .Mapping {
		field_error(doc, name, .Wrong_Type, node)
		return
	}
	s := node.text
	valid := false
	switch name {
	case "id", "parent":
		valid = task.valid_id(s)
	case "title":
		valid = task.valid_title(s)
	case "status":
		valid = task.valid_status(s, vocab)
	case "priority":
		valid = task.valid_priority(s, vocab)
	case "due":
		valid = task.valid_due(s)
	}
	if valid {
		dst^ = s
	} else {
		field_error(doc, name, .Invalid_Value, node)
	}
}

@(private)
read_list :: proc(doc: ^Task_Document, name: string, dst: ^[dynamic]string) {
	node := yaml.lookup(&doc.root, name)
	if node == nil || node.kind == .Null do return
	if node.kind != .Sequence {
		field_error(doc, name, .Wrong_Type, node)
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
	for &item in node.items {
		if item.kind == .Mapping || item.kind == .Sequence || item.kind == .Null {
			field_error(doc, name, .Wrong_Type, &item)
			return
		}
		if !valid_item(item.text) {
			field_error(doc, name, .Invalid_Value, &item)
			return
		}
		key := item.text
		if dependencies do key = strings.to_lower(key) // valid IDs are ASCII
		if key in seen {
			if dependencies do delete(key)
			field_error(doc, name, .Duplicate_Item, &item)
			return
		}
		seen[key] = true
	}
	for item in node.items do append(dst, item.text)
}

@(private)
invalid_custom_key :: proc(node: ^yaml.Node) -> ^yaml.Node {
	for &entry in node.entries {
		if entry.key.kind != .String || entry.key.text == "" do return &entry.key
		for c in entry.key.text {
			if unicode.is_control(c) do return &entry.key
		}
		if bad := invalid_custom_key(&entry.value); bad != nil do return bad
	}
	for &item in node.items {
		if bad := invalid_custom_key(&item); bad != nil do return bad
	}
	return nil
}
