package document

import "kadai:task"
import "kadai:yaml"

// Identity, schema version and the discriminator have separate mutation rules.
Scalar_Field :: enum {
	Title,
	Status,
	Priority,
	Parent,
	Due,
}

// Maps each Scalar_Field to its top-level YAML key, indexed by enum value.
Scalar_Field_Name :: [Scalar_Field]string {
	.Title    = "title",
	.Status   = "status",
	.Priority = "priority",
	.Parent   = "parent",
	.Due      = "due",
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
) -> (
	candidate: string,
	err: Header_Edit_Error,
) {
	names := Scalar_Field_Name
	name := names[field]
	before := decode_task(source, vocabulary, task_source_bytes, yaml_limits, path) or_return
	defer destroy(&before)
	node := yaml.lookup(&before.root, name)
	loc: yaml.Location
	if node != nil {
		loc = markdown_location(before.parts.header, node.location)
	}
	check_patch_target(&before, name, loc) or_return
	if node == nil {
		return "",
			yaml.diagnostic(
				path,
				"missing_field",
				name,
				"Select an existing top-level scalar to replace.",
			) or_return
	}
	raw := source[loc.span.start:loc.span.end]
	if before.root.style != .Block || !single_line_token(node, raw) {
		return "",
			yaml.diagnostic(
				path,
				"unsafe_source_patch",
				name,
				"Use a single-line scalar token in a block mapping.",
				loc,
			) or_return
	}

	requested: Field_Value
	if text, ok := value.?; ok {
		requested = text
	}
	edited: string
	if matches_value(node, requested) {
		edited = compose_header_edit(&before, node.span, raw) or_return
	} else {
		edited = compose_field_value(
			&before,
			name,
			node.span,
			requested,
			node.style,
			loc,
		) or_return
	}
	defer if err != nil {
		delete(edited)
	}
	expected := Expected_Field {
		{node.span.start, node.span.end + len(edited) - len(source)},
		requested,
	}
	verify_field_patch(&before, edited, name, expected, loc, vocabulary, yaml_limits) or_return
	return edited, nil
}
