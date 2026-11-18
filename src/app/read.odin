package app

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "kadai:project"
import "kadai:storage"
import "kadai:task"

@(private)
unique_task :: proc(view: ^Collection, id: string, diagnostic := false) -> (^project.Candidate, string) {
	group, status := project.lookup(&view.index, id)
	switch status {
	case .Valid: return group[0], ""
	case .Diagnostic_Only:
		if diagnostic do return group[0], ""
		return nil, fmt.tprintf("%s: task %s requires repair (%v)", group[0].path, id, group[0].status)
	case .Missing:
		if !task.valid_id(id) do return nil, fmt.tprintf("invalid task ID: %q", id)
		if view.report != nil do view.report.lookup_failure = .Missing
		return nil, fmt.tprintf("unknown task ID: %s", id)
	case .Incomplete: return nil, "incomplete task index"
	case .Ambiguous:
		if view.report != nil do view.report.lookup_failure = .Ambiguous
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

List_Filter :: struct {
	status, directory, tag, parent: string,
	// Any group may match. Within a group every predicate must match.
	alternatives: [][]List_Predicate,
}

List_Predicate :: struct {
	field: enum {ID, Status, Priority, Tag, Due},
	value: string,
	negated: bool,
}

@(private)
valid_list_predicate :: proc(p: List_Predicate, vocabulary: task.Vocabulary) -> bool {
	switch p.field {
	case .ID:       return task.valid_id(p.value)
	case .Status:   return task.valid_status(p.value, vocabulary)
	case .Priority: return task.valid_priority(p.value, vocabulary)
	case .Tag:      return task.valid_tag(p.value)
	case .Due:      return task.valid_due(p.value)
	}
	unreachable()
}

@(private)
matches_expression :: proc(item: ^project.Candidate, alternatives: [][]List_Predicate) -> bool {
	for group in alternatives {
		matches := true
		for p in group {
			equal: bool
			switch p.field {
			case .ID:       equal = strings.equal_fold(item.fields.id, p.value)
			case .Status:   equal = item.fields.status == p.value
			case .Priority: equal = item.fields.priority == p.value
			case .Tag:      equal = slice.contains(item.fields.tags[:], p.value)
			case .Due:      equal = item.fields.due == p.value
			}
			if equal == p.negated {
				matches = false
				break
			}
		}
		if matches do return true
	}
	return len(alternatives) == 0
}

@(private)
list_directory_prefix :: proc(directory: string) -> (string, string) {
	if directory == "" do return "", ""
	if os.is_absolute_path(directory) || os.volume_name(directory) != "" {
		return "", "--directory requires a collection-relative path"
	}
	// Compare indexed paths lexically so the filter never follows a link or changes the scan root.
	path, clean_err := os.clean_path(directory, context.temp_allocator)
	if clean_err != nil do return "", "cannot normalize directory filter"
	when ODIN_OS == .Windows {
		converted, convert_err := os.replace_path_separators(path, '/', context.temp_allocator)
		if convert_err != nil do return "", "cannot normalize directory filter"
		path = converted
	}
	if path == ".." || strings.has_prefix(path, "../") do return "", "--directory escapes the task root"
	if path == "." do return "", ""
	prefix, err := strings.concatenate({path, "/"}, context.temp_allocator)
	if err != nil do return "", "cannot allocate directory filter"
	return prefix, ""
}

list_tasks :: proc(
	cwd: string,
	options: Project_Options,
	limits := project.DEFAULT_SCAN_LIMITS,
	filter := List_Filter{},
) -> ([]^project.Candidate, string) {
	prefix, directory_issue := list_directory_prefix(filter.directory)
	if directory_issue != "" do return nil, directory_issue
	if filter.tag != "" && !task.valid_tag(filter.tag) do return nil, fmt.tprintf("invalid tag: %s", filter.tag)
	view, issue := read_collection(cwd, options, limits)
	if issue != "" do return nil, issue
	items := view.index.valid[:]
	if filter.status != "" && !task.valid_status(filter.status, view.config.vocabulary) {
		return nil, fmt.tprintf("unknown status: %s", filter.status)
	}
	if filter.parent != "" {
		if _, problem := unique_task(&view, filter.parent); problem != "" do return nil, problem
	}
	for group in filter.alternatives {
		for p in group {
			if !valid_list_predicate(p, view.config.vocabulary) {
				return nil, fmt.tprintf("invalid --where value for %v: %q", p.field, p.value)
			}
		}
	}
	// Compact this invocation's pointers in their existing collection-relative path order.
	n := 0
	for item in items {
		if filter.status != "" && item.fields.status != filter.status do continue
		if !strings.has_prefix(item.path, prefix) do continue
		if filter.tag != "" && !slice.contains(item.fields.tags[:], filter.tag) do continue
		if filter.parent != "" && !strings.equal_fold(item.fields.parent, filter.parent) do continue
		if !matches_expression(item, filter.alternatives) do continue
		items[n] = item
		n += 1
	}
	return items[:n], ""
}
