#+private
package cli

import "core:fmt"
import "core:io"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"
import "kadai:app"

// Titles, paths and diagnostic text can contain control characters. Quote
// those fields so one input value cannot split, overwrite or reorder a row.
needs_terminal_quotes :: proc(value: string) -> bool {
	for r, i in value {
		switch r {
		case '\u061c', '\u200e', '\u200f', '\u2028'..='\u202e', '\u2066'..='\u2069':
			return true // Line separators and bidirectional controls.
		case utf8.RUNE_ERROR:
			_, width := utf8.decode_rune_in_string(value[i:])
			if width == 1 do return true
		}
		if unicode.is_control(r) do return true
	}
	return false
}

terminal_field :: proc(value: string) -> string {
	return fmt.tprintf("%q", value) if needs_terminal_quotes(value) else value
}

write_terminal_field :: proc(w: io.Writer, value: string) -> io.Error {
	if needs_terminal_quotes(value) {
		io.write_quoted_string(w, value) or_return
	} else {
		io.write_string(w, value) or_return
	}
	return nil
}

write_task_label :: proc(b: ^strings.Builder, id, status, title: string) -> io.Error {
	w := strings.to_writer(b)
	for part in ([]string{id, "  [", status, "]  "}) do io.write_string(w, part) or_return
	return write_terminal_field(w, title)
}

list_text :: proc(items: []^app.Task_Candidate, long: bool) -> (text: string, err: io.Error) {
	b, alloc_err := strings.builder_make(context.temp_allocator)
	if alloc_err != nil do return "", .Buffer_Full
	w := strings.to_writer(&b)
	for item in items {
		fields := &item.fields
		write_task_label(&b, fields.id, fields.status, fields.title) or_return
		io.write_string(w, "  (") or_return
		write_terminal_field(w, item.path) or_return
		io.write_string(w, ")\n") or_return
		if long {
			priority := fields.priority if fields.priority != "" else "-"
			due := fields.due if fields.due != "" else "-"
			for part in ([]string{"    priority ", priority, "  due ", due, "\n"}) do io.write_string(w, part) or_return
		}
	}
	return strings.to_string(b), nil
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

@(rodata)
PREREQUISITE_NOTES := [app.Target_Status]string{
	.Resolved = "", .Missing = "missing prerequisite", .Ambiguous = "ambiguous prerequisite ID",
	.Invalid = "invalid prerequisite", .Unsupported = "unsupported prerequisite schema",
}

write_dependency_graph_text :: proc(w: io.Writer, view: app.Dependency_Graph) -> io.Error {
	label := "Prerequisite" if view.direction == .Prerequisites else "Dependent"
	for part in ([]string{label, " graph for ", view.task.fields.id, " (prerequisite -> dependent)\n"}) do io.write_string(w, part) or_return
	if len(view.edges) == 0 do io.write_string(w, "  (none)\n") or_return
	for edge in view.edges {
		for part in ([]string{"  ", edge.prerequisite, " -> ", edge.dependent}) do io.write_string(w, part) or_return
		if edge.resolution != .Resolved {
			for part in ([]string{"  [", PREREQUISITE_NOTES[edge.resolution], "]"}) do io.write_string(w, part) or_return
		}
		io.write_byte(w, '\n') or_return
	}
	return nil
}

dependency_graph_output :: proc(view: app.Dependency_Graph, as_json: bool) -> (string, string, Exit_Code) {
	b, alloc_err := strings.builder_make(context.temp_allocator)
	if alloc_err != nil do return "", "cannot allocate dependency graph output", .Output_Failed
	w := strings.to_writer(&b)
	err := write_dependency_graph_json(w, view) if as_json else write_dependency_graph_text(w, view)
	if err == .Unsupported do return "", "unsupported_output: JSON requires valid UTF-8", .Output_Failed
	if err != nil do return "", "cannot encode dependency graph output", .Output_Failed
	return strings.to_string(b), "", .Success
}

dependency_text :: proc(view: app.Dependency_View) -> string {
	b := strings.builder_make(context.temp_allocator)
	fields := &view.task.fields
	write_task_label(&b, fields.id, fields.status, fields.title)
	strings.write_string(&b, "\nPrerequisites (prerequisite -> dependent)\n")
	if len(view.prerequisites) == 0 do strings.write_string(&b, "  (none)\n")
	for ref in view.prerequisites {
		if ref.status == .Resolved {
			fmt.sbprintf(&b, "  %s -> %s\n", app.target_display_id(ref), fields.id)
			continue
		}
		fmt.sbprintf(&b, "  %s -> %s  [%s]\n", ref.written_id, fields.id, PREREQUISITE_NOTES[ref.status])
		for item in ref.candidates do fmt.sbprintf(&b, "    %s\n", terminal_field(item.path))
	}
	strings.write_string(&b, "Dependents\n")
	if len(view.dependents) == 0 do strings.write_string(&b, "  (none)\n")
	for item in view.dependents do fmt.sbprintf(&b, "  %s -> %s\n", fields.id, item.fields.id)
	return strings.to_string(b)
}
