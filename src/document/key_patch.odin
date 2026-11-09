package document

import "core:strings"
import "kadai:task"
import "kadai:yaml"

// Generic metadata edits exclude the discriminator, identity and version.
Metadata_Field :: enum {Title, Status, Priority, Parent, Due, Tags, Depends_On, Custom}
Insert_Field :: struct {
	value: Field_Value,
	after: string, // Decoded top-level key. Empty appends to the mapping.
}
Unset_Field :: struct {}
Key_Edit :: union #no_nil {Insert_Field, Unset_Field}

@(private)
line_start :: proc(header: string, offset: int) -> int {
	return 1 + strings.last_index_byte(header[:offset], '\n')
}

@(private)
line_ending :: proc(source: string, lf: int) -> string {
	if lf > 0 && source[lf-1] == '\r' {
		return "\r\n"
	}
	return "\n"
}

// pos is a header-relative line start immediately after an LF. A closing
// delimiter at EOF has no line ending to compare.
@(private)
insertion_line_ending :: proc(doc: ^Task_Document, pos: int, name: string, loc: yaml.Location) -> (eol: string, err: Header_Edit_Error) {
	absolute := doc.parts.header.start + pos
	eol = line_ending(doc.source, absolute-1)
	next := doc.source[absolute:doc.parts.closing.end]
	if lf := strings.index_byte(next, '\n'); lf >= 0 && line_ending(next, lf) != eol {
		return "", yaml.diagnostic(doc.path, "unsafe_line_ending", name, "Choose an insertion point with consistent adjacent line endings.", loc) or_return
	}
	return
}

// A key next to a standalone comment can change the comment's attachment.
// Look past blank lines without consuming them in the splice.
@(private)
adjacent_comment :: proc(header: string, span: Byte_Range) -> bool {
	before := strings.trim_right(header[:span.start], " \t\r\n")
	last := strings.trim_left(before[line_start(before, len(before)):], " \t")
	next := strings.trim_left(header[span.end:], " \t\r\n")
	return strings.has_prefix(last, "#") || strings.has_prefix(next, "#")
}

@(private)
Field_Insertion :: struct {
	span: Byte_Range,
	indent, eol: string,
	location: yaml.Location,
}

@(private)
field_insertion_point :: proc(doc: ^Task_Document, name, after: string) -> (point: Field_Insertion, err: Header_Edit_Error) {
	header := doc.source[doc.parts.header.start:doc.parts.header.end]
	entries := doc.root.entries[:]
	offset := doc.root.span.end
	if after != "" {
		found := false
		for &entry, i in entries {
			if entry.key.text == after {
				found = true
				if i+1 < len(entries) {
					offset = entries[i+1].key.span.start
				}
				break
			}
		}
		if !found {
			return {}, yaml.diagnostic(doc.path, "missing_field", after, "Choose an existing top-level key as the insertion point.") or_return
		}
	}
	pos := line_start(header, offset)
	span := Byte_Range{pos, pos}
	absolute := doc.parts.header.start + pos
	loc := yaml.locate(doc.source, {absolute, absolute})
	indent := header[line_start(header, doc.root.span.start):doc.root.span.start]
	if pos == 0 || strings.trim_left(indent, " ") != "" || strings.trim_left(header[pos:offset], " ") != "" {
		return {}, yaml.diagnostic(doc.path, "unsafe_source_patch", name, "Insert at the start of an ordinary block mapping line.", loc) or_return
	}
	if adjacent_comment(header, span) {
		return {}, yaml.diagnostic(doc.path, "comment_ownership_ambiguous", name, "Choose an insertion point separate from standalone comments.", loc) or_return
	}

	eol := insertion_line_ending(doc, pos, name, loc) or_return
	return {span, indent, eol, loc}, nil
}

// A block collection's parser end mark can include following trivia. Its last
// child's content ends at the last byte we can attribute to the entry.
@(private)
last_value_token :: proc(node: ^yaml.Node) -> ^yaml.Node {
	last := node
	for last.style == .Block {
		if last.kind == .Sequence {
			last = &last.items[len(last.items)-1]
		} else {
			last = &last.entries[len(last.entries)-1].value
		}
	}
	return last
}

@(private)
remove_field :: proc(doc: ^Task_Document, name: string, entry: ^yaml.Entry, loc: yaml.Location) -> (edited: string, err: Header_Edit_Error) {
	header := doc.source[doc.parts.header.start:doc.parts.header.end]
	key := entry.key.span
	start := line_start(header, key.start)
	last := last_value_token(&entry.value)
	end := last.span.end
	// Require an ordinary key and colon on the same physical line. Multiline
	// tokens can own line endings and need a different removal rule.
	separator := strings.trim_left(header[key.end:entry.value.span.start], " \t")
	if strings.trim_left(header[start:key.start], " ") != "" ||
	   !single_line_token(&entry.key, header[key.start:key.end]) ||
	   !strings.has_prefix(separator, ":") || strings.contains_any(header[last.span.start:end], "\r\n") {
		return "", yaml.diagnostic(doc.path, "unsafe_source_patch", name, "Remove a complete block entry with an isolated key and value.", loc) or_return
	}
	lf := strings.index_byte(header[end:], '\n')
	if lf < 0 {
		return "", yaml.diagnostic(doc.path, "unsafe_source_patch", name, "Keep the following line separate from the removed entry.", loc) or_return
	}
	span := Byte_Range{start, end + lf + 1}
	trailing := strings.trim(header[end:end+lf], " \t\r")
	if strings.has_prefix(trailing, "#") || adjacent_comment(header, span) ||
	   (strings.contains(header[key.start:end], "\n") && strings.contains(header[key.end:end], "#")) {
		return "", yaml.diagnostic(doc.path, "comment_ownership_ambiguous", name, "Remove the field only when its comments can be preserved in place.", loc) or_return
	}
	if trailing != "" {
		return "", yaml.diagnostic(doc.path, "unsafe_source_patch", name, "Remove a field that occupies complete lines.", loc) or_return
	}
	return compose_header_edit(doc, span, "")
}

// Plan one whole-entry edit. Candidate and diagnostic ownership match compose_header_edit.
@(require_results)
plan_key_patch :: proc(
	source: string, field: Metadata_Field, edit: Key_Edit,
	vocabulary := task.Vocabulary{},
	task_source_bytes := DEFAULT_FRONTMATTER_LIMITS.task_source_bytes,
	yaml_limits := yaml.DEFAULT_LIMITS, path := "",
) -> (candidate: string, err: Header_Edit_Error) {
	names := [Metadata_Field]string{
		.Title = "title", .Status = "status", .Priority = "priority", .Parent = "parent",
		.Due = "due", .Tags = "tags", .Depends_On = "depends_on", .Custom = "custom",
	}
	name := names[field]
	doc := decode_task(source, vocabulary, task_source_bytes, yaml_limits, path) or_return
	defer destroy(&doc)
	entry: ^yaml.Entry
	loc: yaml.Location
	for &pair in doc.root.entries {
		if pair.key.text == name {
			entry = &pair
			loc = markdown_location(doc.parts.header, pair.key.location)
			break
		}
	}
	check_patch_target(&doc, name, loc) or_return
	if doc.root.style != .Block {
		return "", yaml.diagnostic(path, "unsafe_source_patch", name, "Use a block mapping for a top-level key edit.", loc) or_return
	}

	edited: string
	target: Field_Expectation
	switch op in edit {
	case Insert_Field:
		if entry != nil {
			return "", yaml.diagnostic(path, "field_already_present", name, "Select a missing field to insert.", loc) or_return
		}
		point := field_insertion_point(&doc, name, op.after) or_return
		loc = point.location
		edited = compose_field_value(&doc, name, point.span, op.value, .Plain, loc, point.indent, point.eol) or_return
		pos := point.span.start
		target = Expected_Field{
			span = {pos + len(point.indent) + len(name) + len(": "), pos + (len(edited) - len(source)) - len(point.eol)},
			value = op.value,
		}
	case Unset_Field:
		if field == .Title || field == .Status {
			return "", yaml.diagnostic(path, "required_field_unset", name, "Keep required fields and replace their values instead.", loc) or_return
		}
		if entry == nil {
			return "", yaml.diagnostic(path, "missing_field", name, "Select an existing optional field to remove.") or_return
		}
		edited = remove_field(&doc, name, entry, loc) or_return
	}
	defer if err != nil {
		delete(edited)
	}
	verify_field_patch(&doc, edited, name, target, loc, vocabulary, yaml_limits) or_return
	return edited, nil
}
