package document

import "core:strings"
import "kadai:task"
import "kadai:yaml"

Sequence_Field :: enum {
	Tags,
	Depends_On,
}
Sequence_Edit  :: enum {
	Append,
	Remove,
}

Sequence_Field_Name :: [Sequence_Field]string {
	.Tags       = "tags",
	.Depends_On = "depends_on",
}

@(private)
Expected_Sequence :: struct {
	original: []yaml.Node,
	edit    : Sequence_Edit,
	value   : string,
	index   : int, // Original item to remove, or len(original) for append.
}

@(private)
sequence_matches :: proc(node: ^yaml.Node, want: Expected_Sequence) -> bool {
	if node == nil || node.kind != .Sequence {
		return false
	}
	items := node.items[:]
	for &old, i in want.original {
		if want.edit == .Remove && i == want.index {
			continue
		}
		if len(items) == 0 || !same_yaml_value(&old, &items[0]) {
			return false
		}
		items = items[1:]
	}
	if want.edit == .Append {
		return len(items) == 1 && matches_value(&items[0], want.value)
	}
	return len(items) == 0
}

@(private)
find_sequence_item :: proc(
	doc: ^Task_Document,
	field: Sequence_Field,
	items: []yaml.Node,
	value: string,
	loc: yaml.Location,
) -> (
	index: int,
	err: Header_Edit_Error,
) {
	names := Sequence_Field_Name
	name := names[field]
	fold_ids :=
		field == .Depends_On &&
		len(value) <= doc.frontmatter_limits.yaml_document_bytes &&
		task.valid_id(value)
	index = -1
	for &item, i in items {
		if item.kind == .Null || item.kind == .Sequence || item.kind == .Mapping {
			continue
		}
		if item.text != value &&
		   !(fold_ids && task.valid_id(item.text) && strings.equal_fold(item.text, value)) {
			continue
		}
		if index >= 0 {
			return -1,
				yaml.diagnostic(
					doc.path,
					"ambiguous_sequence_item",
					name,
					"Select a unique sequence item to remove.",
					markdown_location(doc.parts.header, item.location),
				) or_return
		}
		index = i
	}
	if index < 0 {
		return -1,
			yaml.diagnostic(
				doc.path,
				"missing_sequence_item",
				name,
				"Select an existing sequence item to remove.",
				loc,
			) or_return
	}
	return
}

// Plan one document-local item edit. The caller owns the candidate or diagnostic.
// Dependency resolution and graph validation belong to the collection operation.
@(require_results)
plan_sequence_patch :: proc(
	source: string,
	field: Sequence_Field,
	edit: Sequence_Edit,
	value: string,
	vocabulary := task.Vocabulary{},
	task_source_bytes := DEFAULT_FRONTMATTER_LIMITS.task_source_bytes,
	yaml_limits := yaml.DEFAULT_LIMITS,
	path := "",
) -> (
	candidate: string,
	err: Header_Edit_Error,
) {
	names := Sequence_Field_Name
	name := names[field]
	doc := decode_task(source, vocabulary, task_source_bytes, yaml_limits, path) or_return
	defer destroy(&doc)
	node := yaml.lookup(&doc.root, name)
	loc: yaml.Location
	items: []yaml.Node
	if node != nil {
		loc = markdown_location(doc.parts.header, node.location)
		items = node.items[:]
	}
	check_patch_target(&doc, name, loc) or_return
	if doc.root.style != .Block || (node != nil && node.kind != .Null && node.kind != .Sequence) {
		return "",
			yaml.diagnostic(
				path,
				"unsafe_source_patch",
				name,
				"Select a list field in a block mapping.",
				loc,
			) or_return
	}

	want := Expected_Sequence{items, edit, value, len(items)}
	token, quote := "", ""
	switch edit {
	case .Append:
		if len(value) > yaml_limits.bytes {
			return "",
				yaml.limit_diagnostic(
					path,
					"yaml_document_bytes",
					len(value),
					yaml_limits.bytes,
					loc,
				) or_return
		}
		validate := task.valid_tag if field == .Tags else task.valid_id
		if !validate(value) {
			code, message := field_problem(name, .Invalid_Value, nil)
			return "", yaml.diagnostic(path, code, name, message, loc) or_return
		}
		// The tag and ID alphabets exclude quotes and flow delimiters.
		token = value
		if !plain_text_allowed(value) {
			quote = "'"
		}
	case .Remove:
		want.index = find_sequence_item(&doc, field, items, value, loc) or_return
		loc = markdown_location(doc.parts.header, items[want.index].location)
	}

	edited: string
	if node == nil {
		point := field_insertion_point(&doc, name, "") or_return
		loc = point.location
		edited = compose_header_parts(
			&doc,
			point.span,
			{point.indent, name, ": [", quote, token, quote, "]", point.eol},
		) or_return
	} else {
		header := source[doc.parts.header.start:doc.parts.header.end]
		splice: Item_Splice
		ok: bool
		#partial switch node.style {
		case .Plain:
			// An explicit or implicit null starts the first list at the existing value.
			splice, ok = null_item_splice(header, node)
		case .Flow:
			splice, ok = flow_item_splice(header, node, want.index)
		case .Block:
			splice, ok = block_item_splice(header, node, want.index, doc.root.column - 1)
		}
		if !ok {
			return "",
				yaml.diagnostic(
					path,
					"unsafe_source_patch",
					name,
					"Choose a sequence item with isolated separators and unambiguous comments.",
					loc,
				) or_return
		}
		if node.style == .Block && edit == .Append {
			splice.suffix = insertion_line_ending(&doc, splice.span.start, name, loc) or_return
		}
		edited = compose_header_parts(
			&doc,
			splice.span,
			{splice.prefix, quote, token, quote, splice.suffix},
		) or_return
	}
	defer if err != nil {
		delete(edited)
	}
	verify_field_patch(&doc, edited, name, want, loc, vocabulary, yaml_limits) or_return
	return edited, nil
}
