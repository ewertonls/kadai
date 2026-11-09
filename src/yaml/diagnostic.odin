package yaml

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"

Location :: struct {
	span: Byte_Range,
	line, column: int, // One-based Unicode columns. Zero means no source location.
}

Diagnostic :: struct {
	path, code, field, message: string,
	location: Location,
	observed, limit: int,
}

// Path is borrowed, code is a static category. Field and message are owned.
diagnostic :: proc(path, code, field, message: string, location := Location{}) -> Diagnostic {
	return {path = path, code = code, field = strings.clone(field), message = strings.clone(message), location = location}
}

destroy_diagnostic :: proc(d: ^Diagnostic) {
	delete(d.field)
	delete(d.message)
	d^ = {}
}

limit_diagnostic :: proc(path, field: string, observed, limit: int, location := Location{}, invalid := false) -> Diagnostic {
	d := Diagnostic{path = path, field = strings.clone(field), observed = observed, limit = limit, location = location}
	if invalid {
		d.code = "invalid_limit"
		d.message = fmt.aprintf("Set %s to an integer from 1 to %d (received %d).", field, limit, observed)
	} else {
		d.code = "limit_exceeded"
		d.message = fmt.aprintf("Observed %d %s with a limit of %d. Reduce the input or raise the limit within its allowed range.", observed, field, limit)
	}
	return d
}

// Used for a single failure, including errors in a bounded prefix of a large file.
// Ignore the initial BOM for display columns while preserving absolute byte offsets.
locate :: proc(source: string, span: Byte_Range) -> Location {
	if span.start < 0 || span.end < span.start || span.end > len(source) do return {}
	loc := Location{span = span, line = 1, column = 1}
	i := 0
	for i < span.start {
		c, n := utf8.decode_rune_in_string(source[i:])
		if i + n > span.start do break // A byte budget may end inside a rune.
		i += n
		if i == len("\uFEFF") && c == '\uFEFF' do continue
		if c == '\n' {
			loc.line += 1
			loc.column = 1
		} else {
			loc.column += 1
		}
	}
	return loc
}

rune_span :: proc(source: string, offset: int) -> Byte_Range {
	_, n := utf8.decode_rune_in_string(source[offset:])
	return {offset, offset + n}
}

first_invalid_utf8 :: proc(source: string) -> (offset: int, found: bool) {
	if utf8.valid_string(source) do return 0, false
	for offset < len(source) {
		c, n := utf8.decode_rune_in_string(source[offset:])
		if c == utf8.RUNE_ERROR && n == 1 do return offset, true
		offset += n
	}
	return
}
