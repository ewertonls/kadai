package yaml

import "core:strings"
import "core:unicode/utf8"
import oyaml "third_party:odin-yaml"

Limits :: struct {bytes, nodes, depth: int}
DEFAULT_LIMITS :: Limits{256 << 10, 10_000, 32}
MAX_LIMITS :: Limits{4 << 20, 100_000, 128}

valid_limits :: proc(limits: Limits) -> bool {
	return 0 < limits.bytes && limits.bytes <= MAX_LIMITS.bytes &&
	       0 < limits.nodes && limits.nodes <= MAX_LIMITS.nodes &&
	       0 < limits.depth && limits.depth <= MAX_LIMITS.depth
}

Error :: enum {
	None, Invalid_Limits, Too_Large, Too_Many_Nodes, Too_Deep,
	Invalid_UTF8, Unsupported_Line_Break, Unexpected_BOM, Syntax, Invalid_Mark,
	Not_Mapping, Invalid_Key, Duplicate_Key, Anchor, Alias, Tag, Directive, Multiple_Documents,
}

unsupported_line_break :: proc(r: rune, suffix: string) -> bool {
	return r == '\u0085' || r == '\u2028' || r == '\u2029' ||
	       (r == '\r' && !strings.has_prefix(suffix, "\r\n"))
}

@(private)
Reader :: struct {
	parser:     oyaml.parser,
	event:      oyaml.event,
	source:     string,
	limits:     Limits,
	node_count: int,
	char_index: uint,
	byte_index: int,
}

@(private)
advance :: proc(r: ^Reader) -> Error {
	oyaml.event_delete(&r.event)
	if oyaml.parser_parse(&r.parser, &r.event) == 0 do return .Syntax
	return .None
}

// Walk UTF-8 only once, in event order. LibYAML indexes count code points,
// including both characters of a CRLF. All returned spans index source bytes.
@(private)
byte_offset :: proc(r: ^Reader, mark: oyaml.mark, scalar_content := false) -> (int, Error) {
	if mark.index < r.char_index do return 0, .Invalid_Mark
	for r.char_index < mark.index {
		if r.byte_index >= len(r.source) do return 0, .Invalid_Mark
		c, size := utf8.decode_rune_in_string(r.source[r.byte_index:])
		// LibYAML skips a BOM before a document even after leading comments.
		// A U+FEFF inside a scalar is content and keeps its original span.
		if !scalar_content && c == '\uFEFF' && (r.byte_index == 0 || r.source[r.byte_index-1] == '\n') {
			return 0, .Unexpected_BOM
		}
		r.byte_index += size
		r.char_index += 1
	}
	return r.byte_index, .None
}

@(private)
check_properties :: proc(anchor, tag: cstring) -> Error {
	if anchor != nil do return .Anchor
	if tag != nil do return .Tag
	return .None
}

@(private)
read_node :: proc(r: ^Reader, node: ^Node, depth: int) -> Error {
	r.node_count += 1
	if r.node_count > r.limits.nodes do return .Too_Many_Nodes
	if depth > r.limits.depth do return .Too_Deep
	node.span.start = byte_offset(r, r.event.start_mark) or_return
	#partial switch r.event.type {
	case .SCALAR_EVENT:
		scalar := r.event.data.scalar
		check_properties(scalar.anchor, scalar.tag) or_return
		node.text = strings.clone(strings.string_from_ptr((^u8)(scalar.value), int(scalar.length)))
		node.kind = plain_kind(node.text) if scalar.style == .PLAIN_SCALAR_STYLE else .String
	case .SEQUENCE_START_EVENT:
		props := r.event.data.sequence_start
		check_properties(props.anchor, props.tag) or_return
		node.kind = .Sequence
		advance(r) or_return
		for r.event.type != .SEQUENCE_END_EVENT {
			append(&node.items, Node{})
			read_node(r, &node.items[len(node.items)-1], depth + 1) or_return
			advance(r) or_return
		}
	case .MAPPING_START_EVENT:
		props := r.event.data.mapping_start
		check_properties(props.anchor, props.tag) or_return
		node.kind = .Mapping
		seen: map[string]bool
		defer delete(seen)
		advance(r) or_return
		for r.event.type != .MAPPING_END_EVENT {
			append(&node.entries, Entry{})
			pair := &node.entries[len(node.entries)-1]
			read_node(r, &pair.key, depth + 1) or_return
			if pair.key.kind == .Mapping || pair.key.kind == .Sequence do return .Invalid_Key
			if pair.key.text in seen do return .Duplicate_Key
			seen[pair.key.text] = true
			advance(r) or_return
			read_node(r, &pair.value, depth + 1) or_return
			advance(r) or_return
		}
	case .ALIAS_EVENT: return .Alias
	case: return .Syntax
	}
	node.span.end = byte_offset(r, r.event.end_mark, r.event.type == .SCALAR_EVENT) or_return
	return .None
}

@(private)
read_document :: proc(r: ^Reader, root: ^Node) -> Error {
	advance(r) or_return // stream start
	advance(r) or_return
	if r.event.type == .STREAM_END_EVENT {
		_ = byte_offset(r, r.event.end_mark) or_return // empty or comments only
		return .None
	}
	if r.event.type != .DOCUMENT_START_EVENT do return .Syntax
	doc := r.event.data.document_start
	if doc.version_directive_m != nil || doc.tag_directives.start != doc.tag_directives.end do return .Directive
	advance(r) or_return
	read_node(r, root, 1) or_return
	if root.kind != .Mapping do return .Not_Mapping
	advance(r) or_return // document end
	advance(r) or_return
	if r.event.type != .STREAM_END_EVENT do return .Multiple_Documents
	_ = byte_offset(r, r.event.end_mark) or_return
	return .None
}

// Parses one bounded mapping. An empty stream returns an Absent node. The
// caller owns a successful tree and releases it with destroy.
parse_mapping :: proc(source: string, limits := DEFAULT_LIMITS) -> (Node, Error) {
	if !valid_limits(limits) do return {}, .Invalid_Limits
	if len(source) > limits.bytes do return {}, .Too_Large
	if len(source) == 0 do return {}, .None
	if !utf8.valid_string(source) do return {}, .Invalid_UTF8
	if strings.has_prefix(source, "\uFEFF") do return {}, .Unexpected_BOM
	for c, i in source {
		if unsupported_line_break(c, source[i:]) do return {}, .Unsupported_Line_Break
	}
	reader := Reader{source = source, limits = limits}
	if oyaml.parser_initialize(&reader.parser) == 0 do return {}, .Syntax
	defer oyaml.parser_delete(&reader.parser)
	defer oyaml.event_delete(&reader.event)
	oyaml.parser_set_input_string(&reader.parser, raw_data(source), uint(len(source)))
	root: Node
	if err := read_document(&reader, &root); err != .None {
		destroy(&root)
		return {}, err
	}
	return root, .None
}
