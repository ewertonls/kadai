package document

import "base:runtime"
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
	Allocation_Error,
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
	alloc_err: runtime.Allocator_Error,
) #optional_allocator_error {
	doc.source, doc.path = source, path
	doc.frontmatter_limits = {task_source_bytes, yaml_limits.bytes}
	alloc_err = decode_fields(&doc, vocabulary, yaml_limits)
	if alloc_err != nil {
		destroy(&doc)
		doc = Task_Document{source = source, path = path, status = .Allocation_Error}
	}
	return
}

@(private)
decode_fields :: proc(doc: ^Task_Document, vocabulary: task.Vocabulary, yaml_limits: yaml.Limits) -> (err: runtime.Allocator_Error) {
	source, path := doc.source, doc.path
	failure: yaml.Diagnostic
	if !yaml.valid_limits(yaml_limits) {
		doc.status, doc.boundary_status = .Boundary_Error, .Invalid_Limits
		add_diagnostic(doc, yaml.invalid_limits_diagnostic(path, yaml_limits)) or_return
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
		add_diagnostic(doc, failure) or_return
		return
	}
	header := doc.parts.header
	parse_err: yaml.Parse_Failure
	doc.root, parse_err = yaml.parse_mapping_checked(
		source[header.start:header.end],
		yaml_limits,
		&failure,
		path,
	)
	switch e in parse_err {
	case runtime.Allocator_Error:
		return e
	case yaml.Error:
		doc.yaml_error = e
		doc.status = .YAML_Error
		failure.location = markdown_location(header, failure.location)
		add_diagnostic(doc, failure) or_return
		return
	}
	marker := yaml.lookup(&doc.root, "kadai")
	if marker == nil || marker.kind != .String || marker.text != "task" do return

	read_text(doc, "id", &doc.fields.id, vocabulary) or_return
	version := yaml.lookup(&doc.root, "schema_version")
	if version == nil || version.kind == .Null {
		doc.fields.schema_version = {
			digits = "1",
			base   = 10,
		}
	} else {
		n, ok := yaml.integer_value(version)
		if !ok || n.negative || n.digits == "0" {
			field_error(doc, "schema_version", .Invalid_Value, version) or_return
			doc.status = .Invalid_Fields
			return
		}
		doc.fields.schema_version = n
		if n.digits != "1" {
			doc.status = .Unsupported_Schema
			add_diagnostic(
				doc,
				yaml.diagnostic(
					path,
					"unsupported_task_schema",
					"schema_version",
					"Use a Kadai version that supports this task schema.",
					markdown_location(header, version.location),
				),
			) or_return
			return
		}
	}

	read_text(doc, "title", &doc.fields.title, vocabulary) or_return
	read_text(doc, "status", &doc.fields.status, vocabulary) or_return
	read_text(doc, "priority", &doc.fields.priority, vocabulary) or_return
	read_text(doc, "parent", &doc.fields.parent, vocabulary) or_return
	read_text(doc, "due", &doc.fields.due, vocabulary) or_return
	read_list(doc, "tags", &doc.fields.tags) or_return
	read_list(doc, "depends_on", &doc.fields.depends_on) or_return
	if custom := yaml.lookup(&doc.root, "custom"); custom != nil && custom.kind != .Null {
		if custom.kind != .Mapping {
			field_error(doc, "custom", .Wrong_Type, custom) or_return
		} else if key := invalid_custom_key(custom); key != nil {
			field_error(doc, "custom", .Invalid_Key, key) or_return
		} else {
			doc.fields.custom = custom
		}
	}
	for &entry in doc.root.entries {
		if entry.key.kind != .String {
			field_error(doc, entry.key.text, .Invalid_Key, &entry.key) or_return
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
			field_error(doc, entry.key.text, .Unknown_Field, &entry.key) or_return
		}
	}
	doc.status = .Decoded if len(doc.field_errors) == 0 else .Invalid_Fields
	return
}

@(private)
read_text :: proc(doc: ^Task_Document, name: string, dst: ^string, vocab: task.Vocabulary) -> (err: runtime.Allocator_Error) {
	node := yaml.lookup(&doc.root, name)
	required := name == "id" || name == "title" || name == "status"
	if node == nil || node.kind == .Null {
		if required {
			reason: Field_Error_Reason = .Missing if node == nil else .Required_Null
			field_error(doc, name, reason, node) or_return
		}
		return
	}
	if node.kind == .Sequence || node.kind == .Mapping {
		field_error(doc, name, .Wrong_Type, node) or_return
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
		field_error(doc, name, .Invalid_Value, node) or_return
	}
	return
}

@(private)
read_list :: proc(doc: ^Task_Document, name: string, dst: ^[dynamic]string) -> (err: runtime.Allocator_Error) {
	node := yaml.lookup(&doc.root, name)
	if node == nil || node.kind == .Null do return
	if node.kind != .Sequence {
		field_error(doc, name, .Wrong_Type, node) or_return
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
			field_error(doc, name, .Wrong_Type, &item) or_return
			return
		}
		if !valid_item(item.text) {
			field_error(doc, name, .Invalid_Value, &item) or_return
			return
		}
		key := item.text
		if dependencies {
			key = strings.to_lower(key) or_return // valid IDs are ASCII
			if len(key) != len(item.text) {
				delete(key)
				return .Out_Of_Memory
			}
		}
		if key in seen {
			if dependencies do delete(key)
			field_error(doc, name, .Duplicate_Item, &item) or_return
			return
		}
		if _, insert_err := map_insert(&seen, key, true); insert_err != nil {
			if dependencies { delete(key) }
			return insert_err
		}
	}
	for item in node.items {
		_ = append(dst, item.text) or_return
	}
	return
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
