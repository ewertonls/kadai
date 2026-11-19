package document

import "base:runtime"
import "kadai:task"
import "kadai:yaml"

Task_Reference :: struct {
	field, id: string,
	location : yaml.Location,
}

// Retain the position of each independently readable reference. If one item
// is malformed, validation can still diagnose the other scalars in the list.
reference_locations :: proc(
	doc: ^Task_Document,
) -> (
	id: yaml.Location,
	refs: [dynamic]Task_Reference,
	err: runtime.Allocator_Error,
) {
	context.allocator = context.temp_allocator
	if doc.fields.id != "" {
		node := yaml.lookup(&doc.root, "id")
		id = markdown_location(doc.parts.header, node.location)
	}
	if doc.fields.schema_version.digits != "1" do return
	if doc.fields.parent != "" {
		node := yaml.lookup(&doc.root, "parent")
		_ = append(
			&refs,
			Task_Reference {
				"parent",
				doc.fields.parent,
				markdown_location(doc.parts.header, node.location),
			},
		) or_return
	}
	if seq := yaml.lookup(&doc.root, "depends_on"); seq != nil && seq.kind == .Sequence {
		for &node in seq.items {
			if node.kind == .Null || node.kind == .Mapping || node.kind == .Sequence || !task.valid_id(node.text) do continue
			_ = append(
				&refs,
				Task_Reference {
					"depends_on",
					node.text,
					markdown_location(doc.parts.header, node.location),
				},
			) or_return
		}
	}
	return
}
