package document

import "base:intrinsics"
import "base:runtime"
import "core:unicode/utf8"
import "kadai:yaml"

Header_Edit_Error :: union {
	yaml.Diagnostic,
	runtime.Allocator_Error,
}

// Compose candidate Markdown from one planned edit. The span uses the same
// header-relative byte offsets as YAML nodes. Field planners are responsible for
// choosing the span and validating the complete candidate before persistence.
// The caller owns the returned string on success or a diagnostic if one is returned.
@(require_results)
compose_header_edit :: proc(doc: ^Task_Document, span: Byte_Range, replacement: string) -> (candidate: string, err: Header_Edit_Error) {
	return compose_header_parts(doc, span, {replacement})
}

// Copy each piece directly to the candidate after checking their combined size.
@(private)
compose_header_parts :: proc(doc: ^Task_Document, span: Byte_Range, parts: []string) -> (candidate: string, err: Header_Edit_Error) {
	if (doc.status != .Decoded && doc.status != .Invalid_Fields) ||
	   doc.fields.schema_version.digits != "1" || doc.fields.id == "" {
		return "", yaml.diagnostic(doc.path, "unsafe_source_patch", "", "Select a parsed v1 task with a valid ID before editing its header.") or_return
	}
	header := doc.parts.header
	size := header.end - header.start
	if span.start < 0 || span.end < span.start || span.end > size {
		return "", yaml.diagnostic(doc.path, "unsafe_source_patch", "", "Keep the edit inside the YAML header.") or_return
	}
	start, end := header.start + span.start, header.start + span.end
	if !utf8.rune_start(doc.source[start]) || !utf8.rune_start(doc.source[end]) {
		return "", yaml.diagnostic(doc.path, "unsafe_source_patch", "", "Place both edit boundaries between UTF-8 characters.") or_return
	}

	limits := doc.frontmatter_limits
	replacement_size := 0
	for part in parts {
		replacement_size = intrinsics.saturating_add(replacement_size, len(part))
	}
	new_header_size, new_source_size := header_edit_sizes(doc, span, replacement_size) or_return
	buffer := non_zero_make([]byte, new_source_size) or_return
	defer if err != nil {
		delete(buffer)
	}
	if len(buffer) != new_source_size {
		return "", runtime.Allocator_Error.Out_Of_Memory
	}
	pos := copy(buffer, doc.source[:start])
	for part in parts {
		pos += copy(buffer[pos:], part)
	}
	copy(buffer[pos:], doc.source[end:])
	edited := string(buffer)
	closing_start := header.start + new_header_size
	if edited[closing_start - 1] != '\n' {
		loc := yaml.locate(doc.source, {start, end})
		return "", yaml.diagnostic(doc.path, "unsafe_source_patch", "", "Keep the closing delimiter at the start of its own line.", loc) or_return
	}

	envelope, status := extract_frontmatter(edited, limits)
	if status != .Present {
		// The candidate is discarded. Point to the planned edit in the original.
		loc := yaml.locate(doc.source, {start, end})
		return "", boundary_diagnostic(edited, doc.path, status, limits, loc) or_return
	}
	// The suffix was copied verbatim. Its original closing delimiter must
	// still be the one that separates the YAML from the Markdown body.
	if envelope.closing.start != closing_start {
		loc := yaml.locate(doc.source, {start, end})
		return "", yaml.diagnostic(doc.path, "unsafe_source_patch", "", "Keep the original closing delimiter at the end of the edited header.", loc) or_return
	}
	return edited, nil
}

// Check the byte budgets before allocating an encoded token or a complete candidate.
@(private)
header_edit_sizes :: proc(doc: ^Task_Document, span: Byte_Range, token_bytes: int) -> (header_bytes, source_bytes: int, err: Header_Edit_Error) {
	removed := span.end - span.start
	header := doc.parts.header
	limits := doc.frontmatter_limits
	header_bytes = intrinsics.saturating_add(header.end - header.start - removed, token_bytes)
	source_bytes = intrinsics.saturating_add(len(doc.source) - removed, token_bytes)
	if header_bytes > limits.yaml_document_bytes {
		return 0, 0, yaml.limit_diagnostic(doc.path, "yaml_document_bytes", header_bytes, limits.yaml_document_bytes) or_return
	}
	if source_bytes > limits.task_source_bytes {
		return 0, 0, yaml.limit_diagnostic(doc.path, "task_source_bytes", source_bytes, limits.task_source_bytes) or_return
	}
	return
}
