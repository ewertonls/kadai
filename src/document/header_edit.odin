package document

import "base:intrinsics"
import "base:runtime"
import "core:strings"
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
	if (doc.status != .Decoded && doc.status != .Invalid_Fields) ||
	   doc.fields.schema_version.digits != "1" || doc.fields.id == "" {
		return "", yaml.diagnostic(doc.path, "unsafe_source_patch", "", "Select a parsed v1 task with a valid ID before editing its header.")
	}
	header := doc.parts.header
	size := header.end - header.start
	if span.start < 0 || span.end < span.start || span.end > size {
		return "", yaml.diagnostic(doc.path, "unsafe_source_patch", "", "Keep the edit inside the YAML header.")
	}
	start, end := header.start + span.start, header.start + span.end
	if !utf8.rune_start(doc.source[start]) || !utf8.rune_start(doc.source[end]) {
		return "", yaml.diagnostic(doc.path, "unsafe_source_patch", "", "Place both edit boundaries between UTF-8 characters.")
	}

	removed := span.end - span.start
	limits := doc.frontmatter_limits
	new_header_size := intrinsics.saturating_add(size - removed, len(replacement))
	new_source_size := intrinsics.saturating_add(len(doc.source) - removed, len(replacement))
	if new_header_size > limits.yaml_document_bytes {
		return "", yaml.limit_diagnostic(doc.path, "yaml_document_bytes", new_header_size, limits.yaml_document_bytes)
	}
	if new_source_size > limits.task_source_bytes {
		return "", yaml.limit_diagnostic(doc.path, "task_source_bytes", new_source_size, limits.task_source_bytes)
	}

	edited := strings.concatenate({doc.source[:start], replacement, doc.source[end:]}) or_return
	defer if err != nil {
		delete(edited)
	}
	// A nil allocator can decline a nonempty allocation without returning an error.
	if len(edited) != new_source_size {
		return "", runtime.Allocator_Error.Out_Of_Memory
	}
	closing_start := header.start + new_header_size
	if edited[closing_start - 1] != '\n' {
		loc := yaml.locate(doc.source, {start, end})
		return "", yaml.diagnostic(doc.path, "unsafe_source_patch", "", "Keep the closing delimiter at the start of its own line.", loc)
	}

	failure: yaml.Diagnostic
	parts, status := extract_frontmatter(edited, limits, &failure, doc.path)
	if status != .Present {
		// The candidate is discarded. Point to the planned edit in the original.
		failure.location = yaml.locate(doc.source, {start, end})
		return "", failure
	}
	// The suffix was copied verbatim. Its original closing delimiter must
	// still be the one that separates the YAML from the Markdown body.
	if parts.closing.start != closing_start {
		loc := yaml.locate(doc.source, {start, end})
		return "", yaml.diagnostic(doc.path, "unsafe_source_patch", "", "Keep the original closing delimiter at the end of the edited header.", loc)
	}
	return edited, nil
}
