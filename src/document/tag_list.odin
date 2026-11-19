package document

import "core:slice"
import "core:strings"
import "kadai:task"
import "kadai:yaml"

// Set an ordered list. Reuse the existing item planner for single-item edits.
// Bulk edits require simple separators and retain the spelling of surviving tags.
plan_tags :: proc(
	doc: ^Task_Document,
	tags: []string,
	vocab: task.Vocabulary,
	limits: yaml.Limits,
) -> (
	edited: string,
	err: Header_Edit_Error,
) {
	node := yaml.lookup(&doc.root, "tags")
	loc: yaml.Location
	if node != nil do loc = markdown_location(doc.parts.header, node.location)
	check_patch_target(doc, "tags", loc) or_return
	if len(tags) > limits.nodes do return "", yaml.limit_diagnostic(doc.path, "yaml_nodes_document", len(tags), limits.nodes) or_return
	seen: map[string]bool
	defer delete(seen)
	for tag in tags {
		if len(tag) > limits.bytes do return "", yaml.limit_diagnostic(doc.path, "yaml_document_bytes", len(tag), limits.bytes) or_return
		if !task.valid_tag(tag) || tag in seen do return "", yaml.diagnostic(doc.path, "invalid_tag", "tags", "Supply unique, valid tags.", loc) or_return
		_ = map_insert(&seen, tag, true) or_return
	}
	old := doc.fields.tags[:]
	if node != nil && node.kind == .Sequence && len(node.items) == len(old) {
		if slice.equal(old, tags) do return strings.clone(doc.source) or_return, nil
		if len(tags) == len(old) + 1 && slice.equal(tags[:len(old)], old) {
			return plan_sequence_patch(
				doc.source,
				.Tags,
				.Append,
				tags[len(old)],
				vocab,
				doc.frontmatter_limits.task_source_bytes,
				limits,
				doc.path,
			)
		}
		if len(old) == len(tags) + 1 {
			i := 0
			for i < len(tags) && tags[i] == old[i] do i += 1
			if slice.equal(old[i + 1:], tags[i:]) {
				return plan_sequence_patch(
					doc.source,
					.Tags,
					.Remove,
					old[i],
					vocab,
					doc.frontmatter_limits.task_source_bytes,
					limits,
					doc.path,
				)
			}
		}
	}
	unsafe :: proc(path: string, loc: yaml.Location) -> (e: Header_Edit_Error) {
		return(
			yaml.diagnostic(
				path,
				"unsafe_source_patch",
				"tags",
				"Select a simple sequence with unambiguous separators and comments.",
				loc,
			) or_return \
		)
	}
	if doc.root.style != .Block do return "", unsafe(doc.path, loc)
	header := doc.source[doc.parts.header.start:doc.parts.header.end]
	span: Byte_Range
	prefix, suffix, separator := "[", "]", ", "
	old_tokens: map[string]string
	defer delete(old_tokens)
	block := false
	if node == nil {
		point := field_insertion_point(doc, "tags", "") or_return
		span, loc = point.span, point.location
		prefix, suffix =
			strings.concatenate({point.indent, "tags: ["}, context.temp_allocator) or_return,
			strings.concatenate({"]", point.eol}, context.temp_allocator) or_return
	} else if node.kind == .Null {
		s, ok := null_item_splice(header, node)
		if !ok do return "", unsafe(doc.path, loc)
		span, prefix, suffix = s.span, s.prefix, s.suffix
	} else if node.kind == .Sequence {
		block = node.style == .Block
		span = node.span
		if !block && strings.contains_any(header[span.start:span.end], "\r\n") do return "", unsafe(doc.path, loc)
		for &item, i in node.items {
			raw := header[item.span.start:item.span.end]
			if !single_line_token(&item, raw) do return "", unsafe(doc.path, loc)
			if item.kind != .Null {_ = map_insert(&old_tokens, item.text, raw) or_return}
			if block {
				if _, ok := block_item_splice(header, node, i, doc.root.column - 1); !ok do return "", unsafe(doc.path, loc)
			}
		}
		if len(node.items) > 0 && (len(tags) > 0 || block) {
			first, last := node.items[0].span, node.items[len(node.items) - 1].span
			span = {first.start, last.end}
			prefix, suffix = "", ""
			if block {
				start := line_start(header, first.start)
				dash := header[start:first.start]
				if len(tags) == 0 {
					span.start = start
					indent := len(dash) - len(strings.trim_left(dash, " "))
					prefix = header[start:start + indent]
					suffix = "  []" if indent == doc.root.column - 1 else "[]"
				} else if len(tags) > len(node.items) {
					point := last.end + strings.index_byte(header[last.end:], '\n') + 1
					eol := insertion_line_ending(doc, point, "tags", loc) or_return
					separator = strings.concatenate({eol, dash}, context.temp_allocator) or_return
				}
			} else if len(node.items) > 1 {
				separator = header[node.items[0].span.end:node.items[1].span.start]
			}
		}
	} else {return "", unsafe(doc.path, loc)}
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_string(&b, prefix)
	for tag, i in tags {
		if i > 0 {
			gap := separator
			if node != nil && i < len(node.items) {
				gap = header[node.items[i - 1].span.end:node.items[i].span.start]
			}
			strings.write_string(&b, gap)
		}
		if raw, ok := old_tokens[tag]; ok {
			strings.write_string(&b, raw)
		} else if yaml.is_plain_null(tag) {
			strings.write_byte(&b, '\'')
			strings.write_string(&b, tag)
			strings.write_byte(&b, '\'')
		} else {
			strings.write_string(&b, tag)
		}
		if strings.builder_len(b) > limits.bytes do return "", yaml.limit_diagnostic(doc.path, "yaml_document_bytes", strings.builder_len(b), limits.bytes) or_return
	}
	strings.write_string(&b, suffix)
	edited = compose_header_edit(doc, span, strings.to_string(b)) or_return
	defer if err != nil {delete(edited)}
	verify_field_patch(doc, edited, "tags", tags, loc, vocab, limits) or_return
	return
}
