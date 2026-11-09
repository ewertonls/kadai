// Interprets task Markdown and applies source-preserving frontmatter edits.
package document

import "core:strings"
import "core:unicode/utf8"
import "kadai:yaml"

// Half-open byte offsets into the original Markdown source.
Byte_Range :: yaml.Byte_Range

Frontmatter :: struct {
	bom, opening, header, closing, body: Byte_Range,
}

Frontmatter_Status :: enum {
	Absent,
	Present,
	Missing_Close,
	Unsupported_Line_Break,
	Invalid_UTF8,
	Task_Source_Too_Large,
	YAML_Document_Too_Large,
	Invalid_Limits,
}

Frontmatter_Limits :: struct {
	task_source_bytes, yaml_document_bytes: int,
}

DEFAULT_FRONTMATTER_LIMITS :: Frontmatter_Limits{16 * 1024 * 1024, yaml.DEFAULT_LIMITS.bytes}
MAX_FRONTMATTER_LIMITS :: Frontmatter_Limits{256 * 1024 * 1024, yaml.MAX_LIMITS.bytes}

// Called only at the start of a line. A delimiter owns its line ending, if any.
@(private)
delimiter :: proc(line: string) -> (size: int, status: Frontmatter_Status) {
	if !strings.has_prefix(line, "---") do return 0, .Absent
	suffix := line[3:]
	if suffix == ""                       do return 3, .Present
	if suffix[0] == '\n'                  do return 4, .Present
	if strings.has_prefix(suffix, "\r\n") do return 5, .Present
	r, _ := utf8.decode_rune_in_string(suffix)
	if yaml.unsupported_line_break(r, suffix) do return 0, .Unsupported_Line_Break
	return 0, .Absent
}

@(private)
find_closing_delimiter :: proc(source: string, header_start, limit: int) -> (Byte_Range, Frontmatter_Status) {
	scan_end := header_start + min(len(source) - header_start, limit)
	pos := header_start
	failure: Frontmatter_Status = .Missing_Close
	bad_break: Byte_Range
	for {
		// Check the real suffix even at the limit: a closing line costs no header bytes.
		size, status := delimiter(source[pos:])
		if status == .Present do return {pos, pos + size}, .Present
		if status == .Unsupported_Line_Break && failure == .Missing_Close {
			failure = status
			bad_break = yaml.rune_span(source, pos + 3)
		}
		lf := strings.index_byte(source[pos:scan_end], '\n')
		if lf < 0 do break
		pos += lf + 1
	}
	if scan_end < len(source) do return {scan_end, scan_end}, .YAML_Document_Too_Large
	return bad_break, failure
}

// Only Present returns ranges. An empty header is a valid boundary result.
// Source is borrowed. No part is copied, normalized or interpreted as YAML.
extract_frontmatter :: proc(
	source: string,
	limits := DEFAULT_FRONTMATTER_LIMITS,
	report: ^yaml.Diagnostic = nil,
	path := "",
) -> (parts: Frontmatter, status: Frontmatter_Status) {
	bad_offset := -1
	defer if report != nil && status != .Present && status != .Absent {
		report^ = boundary_diagnostic(source, path, status, limits, bad_offset)
	}
	if limits.task_source_bytes <= 0 || limits.task_source_bytes > MAX_FRONTMATTER_LIMITS.task_source_bytes ||
	   limits.yaml_document_bytes <= 0 || limits.yaml_document_bytes > MAX_FRONTMATTER_LIMITS.yaml_document_bytes {
		return {}, .Invalid_Limits
	}

	bom_size := 0
	if strings.has_prefix(source, "\uFEFF") do bom_size = len("\uFEFF")
	open_size, open_status := delimiter(source[bom_size:])
	if open_status != .Present {
		if open_status == .Unsupported_Line_Break do bad_offset = bom_size + 3
		return {}, open_status
	}
	if len(source) > limits.task_source_bytes do return {}, .Task_Source_Too_Large

	header_start := bom_size + open_size
	closing, close_status := find_closing_delimiter(source, header_start, limits.yaml_document_bytes)
	if close_status != .Present {
		bad_offset = len(source) if close_status == .Missing_Close else closing.start
		return {}, close_status
	}
	if offset, invalid := yaml.first_invalid_utf8(source); invalid {
		bad_offset = offset
		return {}, .Invalid_UTF8
	}
	header := source[header_start:closing.start]
	for r, i in header {
		if yaml.unsupported_line_break(r, header[i:]) {
			bad_offset = header_start + i
			return {}, .Unsupported_Line_Break
		}
	}
	return {
		bom     = {0, bom_size},
		opening = {bom_size, header_start},
		header  = {header_start, closing.start},
		closing = closing,
		body    = {closing.end, len(source)},
	}, .Present
}

@(private)
boundary_diagnostic :: proc(source, path: string, status: Frontmatter_Status, limits: Frontmatter_Limits, offset: int) -> yaml.Diagnostic {
	loc: yaml.Location
	if offset >= 0 do loc = yaml.locate(source, yaml.rune_span(source, offset))
	switch status {
	case .Invalid_Limits:
		if limits.task_source_bytes <= 0 || limits.task_source_bytes > MAX_FRONTMATTER_LIMITS.task_source_bytes {
			return yaml.limit_diagnostic(path, "task_source_bytes", limits.task_source_bytes, MAX_FRONTMATTER_LIMITS.task_source_bytes, invalid = true)
		}
		return yaml.limit_diagnostic(path, "yaml_document_bytes", limits.yaml_document_bytes, yaml.MAX_LIMITS.bytes, invalid = true)
	case .Task_Source_Too_Large:
		return yaml.limit_diagnostic(path, "task_source_bytes", len(source), limits.task_source_bytes)
	case .YAML_Document_Too_Large:
		// Extraction stops at the first byte beyond the budget.
		return yaml.limit_diagnostic(path, "yaml_document_bytes", limits.yaml_document_bytes + 1, limits.yaml_document_bytes, loc)
	case .Missing_Close: return yaml.diagnostic(path, "frontmatter_missing_close", "", "Add a closing --- line before the Markdown body.", loc)
	case .Unsupported_Line_Break: return yaml.diagnostic(path, "unsupported_line_break", "", "Use LF or CRLF line endings in frontmatter.", loc)
	case .Invalid_UTF8: return yaml.diagnostic(path, "invalid_utf8", "", "Save the file as valid UTF-8.", loc)
	case .Absent, .Present: return {}
	}
	return {}
}
