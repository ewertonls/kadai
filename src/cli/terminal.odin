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

@(require_results)
write_parts :: proc(w: io.Writer, parts: ..string) -> io.Error {
	for part in parts do io.write_string(w, part) or_return
	return nil
}

@(require_results)
write_task_label :: proc(w: io.Writer, item: ^app.Task_Candidate) -> io.Error {
	fields := &item.fields
	write_parts(w, fields.id, "  [", fields.status, "]  ") or_return
	return write_terminal_field(w, fields.title)
}

list_text :: proc(items: []^app.Task_Candidate, long: bool) -> (text: string, err: io.Error) {
	b, alloc_err := strings.builder_make(context.temp_allocator)
	if alloc_err != nil do return "", .Buffer_Full
	w := strings.to_writer(&b)
	for item in items {
		fields := &item.fields
		write_task_label(w, item) or_return
		io.write_string(w, "  (") or_return
		write_terminal_field(w, item.path) or_return
		io.write_string(w, ")\n") or_return
		if long {
			priority := fields.priority if fields.priority != "" else "-"
			due := fields.due if fields.due != "" else "-"
			write_parts(w, "    priority ", priority, "  due ", due, "\n") or_return
		}
	}
	return strings.to_string(b), nil
}

write_ready_text :: proc(w: io.Writer, rows: []app.Ready_Task) -> io.Error {
	for row in rows {
		write_task_label(w, row.item) or_return
		write_parts(w, "  (readiness: ", READINESS_LABELS[row.readiness], ")\n") or_return
	}
	return nil
}

write_tree_text :: proc(w: io.Writer, rows: []app.Tree_Row) -> io.Error {
	for row in rows {
		// Cap indentation so a long chain still uses linear output space.
		for _ in 0..<min(row.depth, 16) do io.write_string(w, "  ") or_return
		if row.depth > 16 {
			io.write_string(w, "[depth ") or_return
			io.write_int(w, row.depth) or_return
			io.write_string(w, "] ") or_return
		}
		if row.position == .Child do io.write_string(w, "- ") or_return
		write_task_label(w, row.item) or_return
		switch row.position {
		case .Unresolved_Parent: write_parts(w, "  [unresolved parent: ", row.item.fields.parent, "]") or_return
		case .Parent_Cycle: write_parts(w, "  [parent cycle: ", row.item.fields.parent, "]") or_return
		case .Root, .Child:
		}
		io.write_byte(w, '\n') or_return
	}
	return nil
}

@(rodata)
PREREQUISITE_NOTES := [app.Target_Status]string{
	.Resolved = "", .Missing = "missing prerequisite", .Ambiguous = "ambiguous prerequisite ID",
	.Invalid = "invalid prerequisite", .Unsupported = "unsupported prerequisite schema",
}

write_dependency_graph_text :: proc(w: io.Writer, view: app.Dependency_Graph) -> io.Error {
	label := "Prerequisite" if view.direction == .Prerequisites else "Dependent"
	write_parts(w, label, " graph for ", view.task.fields.id, " (prerequisite -> dependent)\n") or_return
	if len(view.edges) == 0 do io.write_string(w, "  (none)\n") or_return
	for edge in view.edges {
		write_parts(w, "  ", edge.prerequisite, " -> ", edge.dependent) or_return
		if edge.resolution != .Resolved {
			write_parts(w, "  [", PREREQUISITE_NOTES[edge.resolution], "]") or_return
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

write_dependency_text :: proc(w: io.Writer, view: app.Dependency_View) -> io.Error {
	id := view.task.fields.id
	write_task_label(w, view.task) or_return
	io.write_string(w, "\nPrerequisites (prerequisite -> dependent)\n") or_return
	if len(view.prerequisites) == 0 do io.write_string(w, "  (none)\n") or_return
	for ref in view.prerequisites {
		write_parts(w, "  ", app.target_display_id(ref), " -> ", id) or_return
		if ref.status == .Resolved {
			io.write_byte(w, '\n') or_return
			continue
		}
		write_parts(w, "  [", PREREQUISITE_NOTES[ref.status], "]\n") or_return
		for item in ref.candidates {
			io.write_string(w, "    ") or_return
			write_terminal_field(w, item.path) or_return
			io.write_byte(w, '\n') or_return
		}
	}
	io.write_string(w, "Dependents\n") or_return
	if len(view.dependents) == 0 do io.write_string(w, "  (none)\n") or_return
	for item in view.dependents do write_parts(w, "  ", id, " -> ", item.fields.id, "\n") or_return
	return nil
}

write_log_text :: proc(w: io.Writer, entries: []app.Log_Entry) -> io.Error {
	for entry, i in entries {
		if i > 0 do io.write_byte(w, '\n') or_return
		write_parts(w, "### ", entry.timestamp, "\n\n", entry.content) or_return
		if !strings.has_suffix(entry.content, "\n") do io.write_byte(w, '\n') or_return
	}
	return nil
}

write_task_text :: proc{write_ready_text, write_tree_text, write_dependency_text, write_log_text}

task_text_result :: proc(value: $T) -> (string, string, Exit_Code) {
	b, alloc_err := strings.builder_make(context.temp_allocator)
	if alloc_err != nil do return "", "cannot allocate task output", .Output_Failed
	if err := write_task_text(strings.to_writer(&b), value); err != nil do return "", "cannot encode task output", .Output_Failed
	return strings.to_string(b), "", .Success
}
