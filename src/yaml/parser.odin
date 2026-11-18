package yaml

import "base:runtime"
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
	Not_Mapping, Invalid_Key, Duplicate_Key, Anchor, Alias, Tag, Directive, Multiple_Documents, Allocation_Failed,
	Invalid_Indentation,
}

Parse_Failure :: union {Error, runtime.Allocator_Error}

unsupported_line_break :: proc(r: rune, suffix: string) -> bool {
	return r == '\u0085' || r == '\u2028' || r == '\u2029' ||
	       (r == '\r' && !strings.has_prefix(suffix, "\r\n"))
}

// Record parser work even on rejection. A match comes only from a fully
// decoded scalar pair in the root mapping.
Mapping_Probe :: struct {
	key, value: string,
	matched: bool,
	nodes: int,
}

@(private)
Reader :: struct {
	probe: ^Mapping_Probe,
	parser:     oyaml.parser,
	event:      oyaml.event,
	source:     string,
	limits:     Limits,
	node_count: int,
	open_collections: int,
	probe_expects_value, probe_key_matched, probe_done: bool,
	char_index: uint,
	byte_index: int,
	field: [dynamic]union {^Entry, int},
	offender: ^Node,
	bad_offset: int,
	failed_depth: int,
	initialized: bool,
}

@(private)
matches_probe_scalar :: proc(event: ^oyaml.event, expected: string) -> bool {
	if event.type != .SCALAR_EVENT do return false
	scalar := event.data.scalar
	// An anchor on a literal does not change its text. Never dereference an
	// alias or infer a string from an unknown tag.
	if scalar.tag != nil && string(scalar.tag) != "tag:yaml.org,2002:str" do return false
	text := strings.string_from_ptr((^u8)(scalar.value), int(scalar.length))
	return text == expected && (scalar.tag != nil || scalar.style != .PLAIN_SCALAR_STYLE || plain_kind(text) == .String)
}

@(private)
advance :: proc(r: ^Reader) -> Error {
	oyaml.event_delete(&r.event)
	if oyaml.parser_parse(&r.parser, &r.event) == 0 do return .Syntax
	#partial switch r.event.type {
	case .MAPPING_START_EVENT, .SEQUENCE_START_EVENT, .SCALAR_EVENT, .ALIAS_EVENT:
		r.node_count += 1
		if r.node_count > r.limits.nodes do return .Too_Many_Nodes
		depth := r.open_collections + 1
		if depth > r.limits.depth {
			r.failed_depth = depth
			return .Too_Deep
		}
		if r.probe != nil && !r.probe_done && !r.probe.matched {
			if depth == 1 {
				r.probe_done = r.event.type != .MAPPING_START_EVENT
			} else if depth == 2 {
				if !r.probe_expects_value {
					r.probe_key_matched = matches_probe_scalar(&r.event, r.probe.key)
				} else if r.probe_key_matched {
					r.probe.matched = matches_probe_scalar(&r.event, r.probe.value)
				}
				r.probe_expects_value = !r.probe_expects_value
			}
		}
		if r.event.type == .MAPPING_START_EVENT || r.event.type == .SEQUENCE_START_EVENT do r.open_collections += 1
	case .MAPPING_END_EVENT, .SEQUENCE_END_EVENT:
		r.open_collections -= 1
		if r.open_collections == 0 do r.probe_done = true
	case .DOCUMENT_END_EVENT, .STREAM_END_EVENT:
		r.probe_done = true
	}
	return .None
}

// Tabs can separate flow tokens after the enclosing block's indentation.
@(private)
indentation_tab :: proc(line: string, required_spaces: int, scalar_content: bool) -> int {
	i := 0
	for i < min(len(line), required_spaces) && line[i] == ' ' {
		i += 1
	}
	if i == required_spaces || i == len(line) || line[i] != '\t' {
		return -1
	}
	content := strings.trim_left(line[i:], " \t")
	if content == "" || content[0] == '\r' || content[0] == '\n' || (!scalar_content && content[0] == '#') {
		return -1
	}
	return i
}

// Walk UTF-8 only once, in event order. LibYAML indexes count code points,
// including both characters of a CRLF. All returned spans index source bytes.
@(private)
byte_offset :: proc(r: ^Reader, mark: oyaml.mark, required_spaces := 1, scalar_content := false) -> (int, Error) {
	if mark.index < r.char_index do return 0, .Invalid_Mark
	for r.char_index < mark.index {
		if r.byte_index >= len(r.source) do return 0, .Invalid_Mark
		c, size := utf8.decode_rune_in_string(r.source[r.byte_index:])
		if r.byte_index == 0 || r.source[r.byte_index-1] == '\n' {
			// LibYAML can skip a BOM after leading comments. Inside a scalar it is content.
			if !scalar_content && c == '\uFEFF' {
				r.bad_offset = r.byte_index
				return 0, .Unexpected_BOM
			}
			// LibYAML can consume indentation tabs between flow tokens or inside quoted continuations.
			if offset := indentation_tab(r.source[r.byte_index:], required_spaces, scalar_content); offset >= 0 {
				r.bad_offset = r.byte_index + offset
				return 0, .Invalid_Indentation
			}
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

// Continuations need one more space than the enclosing block indentation. The
// one-based block column gives that count, including across nested flow nodes.
@(private)
read_node :: proc(r: ^Reader, node: ^Node, required_spaces := 1) -> Parse_Failure {
	node.span.start = byte_offset(r, r.event.start_mark, required_spaces) or_return
	node.line, node.column = int(r.event.start_mark.line) + 1, int(r.event.start_mark.column) + 1
	#partial switch r.event.type {
	case .SCALAR_EVENT:
		scalar := r.event.data.scalar
		check_properties(scalar.anchor, scalar.tag) or_return
		node.text = strings.clone(strings.string_from_ptr((^u8)(scalar.value), int(scalar.length))) or_return
		if len(node.text) != int(scalar.length) {
			return runtime.Allocator_Error.Out_Of_Memory
		}
		node.kind = plain_kind(node.text) if scalar.style == .PLAIN_SCALAR_STYLE else .String
		switch scalar.style {
		case .PLAIN_SCALAR_STYLE:         node.style = .Plain
		case .SINGLE_QUOTED_SCALAR_STYLE: node.style = .Single_Quoted
		case .DOUBLE_QUOTED_SCALAR_STYLE: node.style = .Double_Quoted
		case .LITERAL_SCALAR_STYLE:       node.style = .Literal
		case .FOLDED_SCALAR_STYLE:        node.style = .Folded
		case .ANY_SCALAR_STYLE:           node.style = .Unknown
		}
	case .SEQUENCE_START_EVENT:
		props := r.event.data.sequence_start
		check_properties(props.anchor, props.tag) or_return
		node.kind = .Sequence
		node.style = .Flow if props.style == .FLOW_SEQUENCE_STYLE else .Block
		child_indent := node.column if node.style == .Block else required_spaces
		advance(r) or_return
		for r.event.type != .SEQUENCE_END_EVENT {
			_ = append(&node.items, Node{}) or_return
			_ = append(&r.field, len(node.items) - 1) or_return
			read_node(r, &node.items[len(node.items)-1], child_indent) or_return
			pop(&r.field)
			advance(r) or_return
		}
	case .MAPPING_START_EVENT:
		props := r.event.data.mapping_start
		check_properties(props.anchor, props.tag) or_return
		node.kind = .Mapping
		node.style = .Flow if props.style == .FLOW_MAPPING_STYLE else .Block
		child_indent := node.column if node.style == .Block else required_spaces
		seen: map[string]bool
		defer delete(seen)
		advance(r) or_return
		for r.event.type != .MAPPING_END_EVENT {
			_ = append(&node.entries, Entry{}) or_return
			pair := &node.entries[len(node.entries)-1]
			read_node(r, &pair.key, child_indent) or_return
			if pair.key.kind == .Mapping || pair.key.kind == .Sequence {
				r.offender = &pair.key
				return Error.Invalid_Key
			}
			_ = append(&r.field, pair) or_return
			if pair.key.text in seen {
				r.offender = &pair.key
				return Error.Duplicate_Key
			}
			_ = map_insert(&seen, pair.key.text, true) or_return
			advance(r) or_return
			read_node(r, &pair.value, child_indent) or_return
			pop(&r.field)
			advance(r) or_return
		}
	case .ALIAS_EVENT: return Error.Alias
	case: return Error.Syntax
	}
	node.span.end = byte_offset(r, r.event.end_mark, required_spaces, r.event.type == .SCALAR_EVENT) or_return
	return nil
}

@(private)
read_document :: proc(r: ^Reader, root: ^Node) -> Parse_Failure {
	advance(r) or_return // stream start
	advance(r) or_return
	if r.event.type == .STREAM_END_EVENT {
		_ = byte_offset(r, r.event.end_mark) or_return // empty or comments only
		return nil
	}
	if r.event.type != .DOCUMENT_START_EVENT do return Error.Syntax
	doc := r.event.data.document_start
	if doc.version_directive_m != nil || doc.tag_directives.start != doc.tag_directives.end do return Error.Directive
	advance(r) or_return
	read_node(r, root) or_return
	if root.kind != .Mapping {
		r.offender = root
		return Error.Not_Mapping
	}
	advance(r) or_return // document end
	advance(r) or_return
	if r.event.type != .STREAM_END_EVENT do return Error.Multiple_Documents
	_ = byte_offset(r, r.event.end_mark) or_return
	return nil
}

@(private)
parse_input :: proc(r: ^Reader, root: ^Node) -> Parse_Failure {
	if !valid_limits(r.limits) do return Error.Invalid_Limits
	if len(r.source) > r.limits.bytes do return Error.Too_Large
	if len(r.source) == 0 do return nil
	if offset, invalid := first_invalid_utf8(r.source); invalid {
		r.bad_offset = offset
		return Error.Invalid_UTF8
	}
	for c, i in r.source {
		if unsupported_line_break(c, r.source[i:]) {
			r.bad_offset = i
			return Error.Unsupported_Line_Break
		}
	}
	if oyaml.parser_initialize(&r.parser) == 0 {
		return runtime.Allocator_Error.Out_Of_Memory
	}
	r.initialized = true
	oyaml.parser_set_input_string(&r.parser, raw_data(r.source), uint(len(r.source)))
	if strings.has_prefix(r.source, "\uFEFF") {
		r.bad_offset = 0
		return Error.Unexpected_BOM
	}
	return read_document(r, root)
}

// The caller owns a successful tree (Absent for an empty stream). Syntax and
// policy failures populate report. Allocation failures return the allocator error.
parse_mapping_checked :: proc(source: string, limits := DEFAULT_LIMITS, report: ^Diagnostic = nil, path := "", probe: ^Mapping_Probe = nil) -> (Node, Parse_Failure) {
	r := Reader{source = source, limits = limits, bad_offset = -1, probe = probe}
	defer if probe != nil { probe.nodes = r.node_count }
	defer {
		delete(r.field)
		if r.initialized {
			oyaml.event_delete(&r.event)
			oyaml.parser_delete(&r.parser)
		}
	}
	root: Node
	switch failure in parse_input(&r, &root) {
	case Error:
		defer destroy(&root)
		if r.parser.error == .MEMORY_ERROR {
			return {}, runtime.Allocator_Error.Out_Of_Memory
		}
		if report != nil do report^ = parser_diagnostic(&r, failure, path)
		// A policy error invalidates the tree, but LibYAML can still prove a
		// later root scalar pair. Consume only this document's bounded events.
		policy_errors :: bit_set[Error]{.Duplicate_Key, .Invalid_Key, .Anchor, .Alias, .Tag, .Directive, .Invalid_Indentation, .Unexpected_BOM}
		if probe != nil && r.initialized && failure in policy_errors {
			for !probe.matched && !r.probe_done {
				next := advance(&r)
				if next == .None do continue
				if r.parser.error == .MEMORY_ERROR {
					if report != nil do destroy_diagnostic(report)
					return {}, runtime.Allocator_Error.Out_Of_Memory
				}
				if next == .Too_Deep || next == .Too_Many_Nodes {
					if report != nil {
						destroy_diagnostic(report)
						r.offender, r.bad_offset = nil, -1
						report^ = parser_diagnostic(&r, next, path)
					}
					return {}, next
				}
				break // A syntax error ends the provable prefix.
			}
		}
		return {}, failure
	case runtime.Allocator_Error:
		destroy(&root)
		return {}, failure
	}
	return root, nil
}

// Readers that only need a category receive Allocation_Failed on allocator errors.
parse_mapping :: proc(source: string, limits := DEFAULT_LIMITS, report: ^Diagnostic = nil, path := "") -> (Node, Error) {
	root, failure := parse_mapping_checked(source, limits, report, path)
	switch err in failure {
	case Error: return {}, err
	case runtime.Allocator_Error:
		if report != nil {
			report^ = Diagnostic{path = path, code = "yaml_parser_error"}
		}
		return {}, .Allocation_Failed
	}
	return root, .None
}
