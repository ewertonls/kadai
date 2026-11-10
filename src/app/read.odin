package app

import "core:fmt"
import "core:os"
import "core:strings"
import "kadai:project"
import "kadai:storage"

@(private)
unique_task :: proc(view: ^Collection, id: string, diagnostic := false) -> (^project.Candidate, string) {
	group, status := project.lookup(&view.index, id)
	switch status {
	case .Valid: return group[0], ""
	case .Diagnostic_Only:
		if diagnostic do return group[0], ""
		return nil, fmt.tprintf("%s: task %s requires repair (%v)", group[0].path, id, group[0].status)
	case .Missing: return nil, fmt.tprintf("unknown task ID: %s", id)
	case .Incomplete: return nil, "incomplete task index"
	case .Ambiguous:
		paths := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&paths, "ambiguous task ID %s:", id)
		for c in group do fmt.sbprintf(&paths, " %s", c.path)
		return nil, strings.to_string(paths)
	}
	unreachable()
}

// The returned bytes and the indexed fields must describe the same revision.
@(private)
read_versioned :: proc(view: ^Collection, item: ^project.Candidate, mutation := false) -> (string, string) {
	path := storage.child(view.config.tasks, item.path)
	f, e := storage.read_file(path, mutation)
	if e != nil do return "", fmt.tprintf("%s: %s", item.path, os.error_string(e))
	defer os.close(f)
	bytes, read_err := storage.read_bounded(f, view.limits.source_bytes)
	if read_err != nil do return "", fmt.tprintf("%s: %s", item.path, os.error_string(read_err))
	info, info_err := storage.file_info(f)
	if info_err != nil || storage.file_version(info, bytes) != item.version do return "", fmt.tprintf("%s: task changed during read", item.path)
	return string(bytes), ""
}

Task_Read :: struct {
	item: ^project.Candidate,
	source: string, // Only for ordinary readable tasks. Diagnostic-only results carry their field diagnostics.
}

get_task :: proc(cwd: string, options: Project_Options, id: string, limits := project.DEFAULT_SCAN_LIMITS) -> (result: Task_Read, issue: string) {
	view: Collection
	view, issue = read_collection(cwd, options, limits)
	if issue != "" do return
	result.item, issue = unique_task(&view, id, diagnostic = true)
	if issue != "" || result.item.status != .Decoded do return
	result.source, issue = read_versioned(&view, result.item)
	return
}

// The index already orders unique valid tasks by collection-relative path.
list_tasks :: proc(cwd: string, options: Project_Options, limits := project.DEFAULT_SCAN_LIMITS) -> ([]^project.Candidate, string) {
	view, issue := read_collection(cwd, options, limits)
	if issue != "" do return nil, issue
	return view.index.valid[:], ""
}
