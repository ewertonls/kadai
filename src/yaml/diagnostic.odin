package yaml

import "base:runtime"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

Location :: struct {
	span        : Byte_Range,
	line, column: int, // One-based Unicode columns. Zero means no source location.
}

Diagnostic :: struct {
	path, code, field, message: string,
	location                  : Location,
	observed, limit           : int,
}

// Path is borrowed, code is a static category. Field and message are owned.
diagnostic :: proc(
	path, code, field, message: string,
	location := Location{},
) -> (
	d: Diagnostic,
	err: runtime.Allocator_Error,
) #optional_allocator_error {
	return diagnostic_parts(path, code, field, {message}, location)
}

@(private)
diagnostic_parts :: proc(
	path, code, field: string,
	parts: []string,
	location: Location,
) -> (
	d: Diagnostic,
	err: runtime.Allocator_Error,
) {
	d.path, d.code, d.location = path, code, location
	owned_field := strings.clone(field) or_return
	defer if err != nil {delete(owned_field)}
	if len(owned_field) != len(field) {
		return d, .Out_Of_Memory
	}
	text := strings.concatenate(parts) or_return
	if text == "" {
		for part in parts {
			if part != "" {
				delete(text)
				return d, .Out_Of_Memory
			}
		}
	}
	d.field, d.message = owned_field, text
	return
}

destroy_diagnostic :: proc(d: ^Diagnostic) {
	delete(d.field)
	delete(d.message)
	d^ = {}
}

limit_diagnostic :: proc(
	path, field: string,
	observed, limit: int,
	location := Location{},
	invalid := false,
) -> (
	d: Diagnostic,
	err: runtime.Allocator_Error,
) #optional_allocator_error {
	actual_buf, limit_buf: [32]byte
	actual_text := strconv.write_int(actual_buf[:], i64(observed), 10)
	limit_text := strconv.write_int(limit_buf[:], i64(limit), 10)
	if invalid {
		d, err = diagnostic_parts(
			path,
			"invalid_limit",
			field,
			{
				"Set ",
				field,
				" to an integer from 1 to ",
				limit_text,
				" (received ",
				actual_text,
				").",
			},
			location,
		)
	} else {
		d, err = diagnostic_parts(
			path,
			"limit_exceeded",
			field,
			{
				"Observed ",
				actual_text,
				" ",
				field,
				" with a limit of ",
				limit_text,
				". Reduce the input or raise the limit within its allowed range.",
			},
			location,
		)
	}
	d.observed, d.limit = observed, limit
	return
}

// Used for a single failure, including errors in a bounded prefix of a large file.
// Ignore the initial BOM for display columns while preserving absolute byte offsets.
locate :: proc(source: string, span: Byte_Range) -> Location {
	if span.start < 0 || span.end < span.start || span.end > len(source) do return {}
	loc := Location {
		span   = span,
		line   = 1,
		column = 1,
	}
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
