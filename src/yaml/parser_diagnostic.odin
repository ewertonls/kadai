package yaml

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"

invalid_limits_diagnostic :: proc(path: string, limits: Limits) -> Diagnostic {
	if limits.bytes <= 0 || limits.bytes > MAX_LIMITS.bytes {
		return limit_diagnostic(path, "yaml_document_bytes", limits.bytes, MAX_LIMITS.bytes, invalid = true)
	}
	if limits.nodes <= 0 || limits.nodes > MAX_LIMITS.nodes {
		return limit_diagnostic(path, "yaml_nodes_document", limits.nodes, MAX_LIMITS.nodes, invalid = true)
	}
	return limit_diagnostic(path, "yaml_depth", limits.depth, MAX_LIMITS.depth, invalid = true)
}

@(private)
field_path :: proc(r: ^Reader, count: int) -> strings.Builder {
	b: strings.Builder
	for segment in r.field[:count] {
		switch v in segment {
		case int: fmt.sbprintf(&b, "[%d]", v)
		case ^Entry:
			key := v.key.text
			if key == "" || strings.contains_any(key, ".[]\"\\\r\n\t") {
				fmt.sbprintf(&b, "[%q]", key)
			} else {
				if strings.builder_len(b) > 0 do strings.write_byte(&b, '.')
				strings.write_string(&b, key)
			}
		}
	}
	return b
}

// LibYAML can look ahead into a sibling before emitting an empty value. Only
// name a field when the native error context is anchored in that field.
@(private)
syntax_field_count :: proc(r: ^Reader) -> int {
	if r.parser.error != .SCANNER_ERROR && r.parser.error != .PARSER_ERROR do return 0
	mark := r.parser.context_mark if r.parser.context_m != nil else r.parser.problem_mark
	line, column := int(mark.line) + 1, int(mark.column) + 1
	for i := len(r.field) - 1; i >= 0; i -= 1 {
		entry, ok := r.field[i].(^Entry)
		if !ok do continue
		key, value := &entry.key, &entry.value
		if line == key.line && column > key.column ||
		   line == value.line && column == value.column ||
		   line == key.line + 1 && column > key.column {
			return i + 1
		}
	}
	return 0
}

// Failure marks can point backwards (scanner lookahead), or at the end of the
// stream. Resolve them independently of the forward-only node cursor.
@(private)
mark_location :: proc(source: string, index: uint, end_index: Maybe(uint) = nil) -> Location {
	pos := 0
	for _ in 0..<index {
		if pos >= len(source) do return {}
		_, n := utf8.decode_rune_in_string(source[pos:])
		pos += n
	}
	span := rune_span(source, pos)
	if end, ok := end_index.?; ok {
		if end < index do return {}
		span.end = pos
		for _ in index..<end {
			if span.end >= len(source) do return {}
			_, n := utf8.decode_rune_in_string(source[span.end:])
			span.end += n
		}
	}
	return locate(source, span)
}

// A directive may cause a parser error before LibYAML emits DOCUMENT_START.
@(private)
leading_directive :: proc(source: string) -> (int, bool) {
	start := 0
	rest := source
	for line in strings.split_by_byte_iterator(&rest, '\n') {
		if strings.has_prefix(line, "%") do return start, true
		trimmed := strings.trim(line, " \r\t")
		if trimmed != "" && !strings.has_prefix(trimmed, "#") do break
		start += len(line) + 1
	}
	return 0, false
}

@(private)
parser_diagnostic :: proc(r: ^Reader, err: Error, path: string) -> Diagnostic {
	s := r.source
	field_count := syntax_field_count(r) if err == .Syntax else len(r.field)
	builder := field_path(r, field_count)
	defer strings.builder_destroy(&builder)
	field := strings.to_string(builder)
	loc: Location
	if r.offender != nil {
		loc = r.offender.location
	} else if r.bad_offset >= 0 {
		loc = locate(s, rune_span(s, r.bad_offset))
	} else if r.event.type != .NO_EVENT {
		loc = mark_location(s, r.event.start_mark.index, r.event.end_mark.index)
	}
	switch err {
	case .Invalid_Limits: return invalid_limits_diagnostic(path, r.limits)
	case .Too_Large: return limit_diagnostic(path, "yaml_document_bytes", len(s), r.limits.bytes)
	case .Too_Many_Nodes: return limit_diagnostic(path, "yaml_nodes_document", r.node_count, r.limits.nodes, loc)
	case .Too_Deep: return limit_diagnostic(path, "yaml_depth", r.failed_depth, r.limits.depth, loc)
	case .Syntax: return syntax_diagnostic(r, path, field)
	case .Invalid_UTF8: return diagnostic(path, "invalid_utf8", "", "Save the file as valid UTF-8.", loc)
	case .Unsupported_Line_Break: return diagnostic(path, "unsupported_line_break", "", "Use LF or CRLF line endings in YAML.", loc)
	case .Unexpected_BOM: return diagnostic(path, "unexpected_bom", "", "Remove the unexpected BOM from this YAML input.", loc)
	case .Not_Mapping: return diagnostic(path, "invalid_yaml_root", "", "Use a mapping of field names to values at the YAML root.", loc)
	case .Invalid_Key: return diagnostic(path, "non_string_mapping_key", field, "Use a scalar string as the mapping key.", loc)
	case .Duplicate_Key: return diagnostic(path, "duplicate_mapping_key", field, "Keep a single entry for this key in the mapping.", loc)
	case .Anchor: return diagnostic(path, "unsupported_anchor", field, "Remove the anchor and write the value directly.", loc)
	case .Alias: return diagnostic(path, "unsupported_alias", field, "Replace the alias with its explicit value.", loc)
	case .Tag: return diagnostic(path, "unsupported_tag", field, "Remove the explicit YAML tag and use a supported value.", loc)
	case .Directive: return diagnostic(path, "unsupported_directive", "", "Remove the YAML directive.", loc)
	case .Multiple_Documents: return diagnostic(path, "multiple_yaml_documents", "", "Keep a single YAML document in this input.", loc)
	case .Invalid_Mark: return diagnostic(path, "invalid_yaml_mark", field, "Check the source encoding and line endings before editing.", {})
	case .None, .Allocation_Failed: return {}
	}
	return {}
}

@(private)
syntax_diagnostic :: proc(r: ^Reader, path, active_field: string) -> Diagnostic {
	s := r.source
	field := active_field
	loc: Location
	switch r.parser.error {
	case .SCANNER_ERROR, .PARSER_ERROR:
		if offset, ok := leading_directive(s); ok {
			return diagnostic(path, "unsupported_directive", "", "Remove the YAML directive.", locate(s, rune_span(s, offset)))
		}
		loc = mark_location(s, r.parser.problem_mark.index)
	case .READER_ERROR:
		if r.parser.problem_offset <= uint(len(s)) {
			loc = locate(s, rune_span(s, int(r.parser.problem_offset)))
		}
		field = "" // The reader can fail before emitting any related event.
	case .MEMORY_ERROR, .NO_ERROR, .COMPOSER_ERROR, .WRITER_ERROR, .EMITTER_ERROR:
		return diagnostic(path, "yaml_parser_error", "", "The YAML parser could not read the input. Check available memory and retry.")
	}
	if loc.line != 0 && loc.span.start < len(s) && s[loc.span.start] == '\t' {
		start := strings.last_index_byte(s[:loc.span.start], '\n') + 1
		if strings.trim(s[start:loc.span.start], " \t") == "" {
			return diagnostic(path, "invalid_indentation", "", "Replace the indentation tab with spaces.", loc)
		}
	}
	d := Diagnostic{path = path, field = strings.clone(field), code = "yaml_syntax", location = loc}
	hint :: "Check the YAML syntax at the reported position."
	if r.parser.context_m != nil && r.parser.problem != nil {
		d.message = fmt.aprintf("%s: %s. %s", string(r.parser.context_m), string(r.parser.problem), hint)
	} else if r.parser.problem != nil {
		d.message = fmt.aprintf("%s. %s", string(r.parser.problem), hint)
	} else {
		d.message = strings.clone("Check the YAML syntax.")
	}
	return d
}
