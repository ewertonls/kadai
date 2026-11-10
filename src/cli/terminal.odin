#+private
package cli

import "core:fmt"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"
import "kadai:app"

// Titles, paths and diagnostic text can contain control characters. Quote
// those fields so one input value cannot split, overwrite or reorder a row.
terminal_field :: proc(value: string) -> string {
	for r, i in value {
		switch r {
		case '\u061c', '\u200e', '\u200f', '\u2028'..='\u202e', '\u2066'..='\u2069':
			return fmt.tprintf("%q", value) // Line separators and bidirectional controls.
		case utf8.RUNE_ERROR:
			_, width := utf8.decode_rune_in_string(value[i:])
			if width == 1 do return fmt.tprintf("%q", value)
		}
		if unicode.is_control(r) do return fmt.tprintf("%q", value)
	}
	return value
}

write_task_label :: proc(b: ^strings.Builder, id, status, title: string) {
	fmt.sbprintf(b, "%s  [%s]  %s", id, status, terminal_field(title))
}

tree_text :: proc(rows: []app.Tree_Row) -> string {
	b := strings.builder_make(context.temp_allocator)
	for row in rows {
		// Cap indentation so a long chain still uses linear output space.
		for _ in 0..<min(row.depth, 16) do strings.write_string(&b, "  ")
		if row.depth > 16 do fmt.sbprintf(&b, "[depth %d] ", row.depth)
		if row.position == .Child do strings.write_string(&b, "- ")
		fields := &row.item.fields
		write_task_label(&b, fields.id, fields.status, fields.title)
		switch row.position {
		case .Unresolved_Parent: fmt.sbprintf(&b, "  [unresolved parent: %s]", fields.parent)
		case .Parent_Cycle: fmt.sbprintf(&b, "  [parent cycle: %s]", fields.parent)
		case .Root, .Child:
		}
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

dependency_text :: proc(view: app.Dependency_View) -> string {
	b := strings.builder_make(context.temp_allocator)
	fields := &view.task.fields
	write_task_label(&b, fields.id, fields.status, fields.title)
	strings.write_string(&b, "\nPrerequisites (prerequisite -> dependent)\n")
	if len(view.prerequisites) == 0 do strings.write_string(&b, "  (none)\n")
	for ref in view.prerequisites {
		note: string
		switch ref.status {
		case .Resolved:
			fmt.sbprintf(&b, "  %s -> %s\n", ref.candidates[0].fields.id, fields.id)
			continue
		case .Missing:     note = "missing prerequisite"
		case .Ambiguous:   note = "ambiguous prerequisite ID"
		case .Invalid:     note = "invalid prerequisite"
		case .Unsupported: note = "unsupported prerequisite schema"
		}
		fmt.sbprintf(&b, "  %s -> %s  [%s]\n", ref.written_id, fields.id, note)
		for item in ref.candidates do fmt.sbprintf(&b, "    %s\n", terminal_field(item.path))
	}
	strings.write_string(&b, "Dependents\n")
	if len(view.dependents) == 0 do strings.write_string(&b, "  (none)\n")
	for item in view.dependents do fmt.sbprintf(&b, "  %s -> %s\n", fields.id, item.fields.id)
	return strings.to_string(b)
}
