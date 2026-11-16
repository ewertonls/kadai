package app

import "core:fmt"
import "core:os"
import "core:strings"
import "kadai:project"
import "kadai:storage"

Move :: struct {
	source, destination: string, // Task ID or, with directory set, a collection-relative directory.
	directory: bool,
}

@(private)
plan_move :: proc(view: ^Collection, data: rawptr) -> ([]storage.Change, string) {
	op := (^Move)(data)
	ch := make([]storage.Change, 1, context.temp_allocator)
	if !op.directory {
		task, issue := unique_task(view, op.source)
		if issue != "" do return nil, issue
		ch[0] = {kind = .Move, path = task.path, expected = task.version, destination = storage.slash(op.destination)}
		return ch, ""
	}
	src, dst := storage.slash(op.source), storage.slash(op.destination)
	if storage.within(src, dst) || storage.within(dst, src) do return nil, "overlapping directory move"
	path, issue := project.task_path(view.config, src, false, true, &view.glob_budget)
	if issue != "" do return nil, issue
	if _, problem := project.task_path(view.config, dst, true, true, &view.glob_budget); problem != "" do return nil, problem
	actual, path_err := storage.physical(path, .Directory)
	if path_err != nil || actual != path do return nil, "use the physical source directory spelling"
	tree, err := storage.inspect_tree(path, journal_limits(view.limits))
	if err != nil do return nil, fmt.tprintf("%s: cannot verify directory (%s)", src, os.error_string(err))
	versions := make(map[string]string, len(tree.entries), context.temp_allocator)
	for entry in tree.entries {
		if !entry.directory { versions[entry.path] = entry.version }
	}
	prefix := storage.child(src, "")
	for &candidate in view.index.candidates {
		if !strings.has_prefix(candidate.path, prefix) do continue
		if _, problem := unique_task(view, candidate.fields.id); problem != "" do return nil, problem
		state := versions[candidate.path[len(prefix):]]
		if !strings.has_prefix(state, fmt.tprintf("%s:", candidate.version)) do return nil, "directory changed during scan"
	}
	ch[0] = {kind = .Move_Directory, path = src, destination = dst, expected = tree.version, members = tree.entries[:]}
	return ch, ""
}

move_task :: proc(cwd: string, options: Project_Options, move: Move, limits := project.DEFAULT_SCAN_LIMITS) -> (operation, issue: string) {
	op := move
	return mutate_collection(cwd, options, plan_move, &op, limits)
}
