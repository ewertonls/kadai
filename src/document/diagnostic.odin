package document

import "base:runtime"
import "kadai:yaml"

// Every extracted header starts on Markdown line two, including BOM and CRLF files.
@(private)
markdown_location :: proc(header: Byte_Range, loc: yaml.Location) -> yaml.Location {
	if loc.line == 0 do return {}
	return {{loc.span.start + header.start, loc.span.end + header.start}, loc.line + 1, loc.column}
}

// Transfer the diagnostic to the document, or release it on allocation failure.
@(private)
add_diagnostic :: proc(doc: ^Task_Document, diagnostic: yaml.Diagnostic) -> runtime.Allocator_Error {
	d := diagnostic
	if d.message == "" {
		yaml.destroy_diagnostic(&d)
		return .Out_Of_Memory
	}
	_, err := append(&doc.diagnostics, d)
	if err != nil {
		yaml.destroy_diagnostic(&d)
	}
	return err
}

@(private)
field_error :: proc(doc: ^Task_Document, field: string, reason: Field_Error_Reason, node: ^yaml.Node) -> runtime.Allocator_Error {
	_ = append(&doc.field_errors, Field_Error{field, reason}) or_return
	code, message := field_problem(field, reason, node)
	loc: yaml.Location
	if node != nil do loc = markdown_location(doc.parts.header, node.location)
	d := yaml.diagnostic(doc.path, code, field, message, loc) or_return
	return add_diagnostic(doc, d)
}

@(private)
field_problem :: proc(field: string, reason: Field_Error_Reason, node: ^yaml.Node) -> (code, message: string) {
	switch reason {
	case .Missing: return "missing_required_field", "Add this required field to the task header."
	case .Required_Null: return "required_null", "Replace null with a value for this required field."
	case .Unknown_Field: return "unknown_top_level_key", "Check the field name or move this metadata under custom."
	case .Invalid_Key:
		if node.kind != .String do return "non_string_mapping_key", "Use a string key. Quote numeric, boolean or null key names."
		return "invalid_custom_key", "Use a nonempty custom key without control characters."
	case .Duplicate_Item:
		if field == "tags" do return "duplicate_tag", "Keep each tag only once."
		return "duplicate_dependency", "Keep each dependency ID only once, including spelling variants that differ only in case."
	case .Invalid_Value, .Wrong_Type:
		switch field {
		case "schema_version":
			if node.kind != .Integer do return "invalid_schema_version_type", "Use an unquoted positive integer for schema_version."
			return "invalid_schema_version", "Use a schema_version greater than zero."
		case "id":       return "invalid_id", "Use an ASCII ID starting and ending with a letter or digit. Internal separators may be -, _ or ."
		case "parent":   return "invalid_parent", "Use one valid task ID for parent, or null."
		case "title":    return "invalid_title", "Use a nonblank single-line title."
		case "status":   return "invalid_status", "Use a configured status, such as todo or in_progress."
		case "priority": return "invalid_priority", "Use a priority from the project configuration, or null."
		case "due":      return "invalid_due", "Use a calendar date (YYYY-MM-DD) or a timestamp with seconds and an explicit UTC offset or Z."
		case "tags":     return "invalid_tags", "Use a list of nonempty tags containing only a-z, 0-9, -, _, . or /."
		case "depends_on": return "invalid_dependency", "Use a list of task IDs for depends_on."
		case "custom":   return "invalid_custom", "Use a mapping of custom keys to values, or null."
		}
	}
	return "invalid_field", "Use a value supported by the task schema."
}
