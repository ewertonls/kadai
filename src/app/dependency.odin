package app

import "core:fmt"
import "core:strings"
import "kadai:document"
import "kadai:project"
import "kadai:storage"

@(private)
Relation :: enum {Parent, Prerequisite}

// A new subject -> target reference closes a cycle exactly when the target
// already reaches the subject by references of the same kind.
@(private)
check_new_link :: proc(view: ^Collection, subject, target: ^project.Candidate, kind: Relation) -> string {
	context.allocator = context.temp_allocator
	seen: map[^project.Candidate]bool
	pending: [dynamic]^project.Candidate
	if _, e := append(&pending, target); e != nil do return "cannot verify relationship"
	for len(pending) > 0 {
		item := pop(&pending)
		if item == subject {
			code := "parent_cycle" if kind == .Parent else "dependency_cycle"
			return fmt.tprintf("%s: %s through %s", subject.path, code, target.fields.id)
		}
		if item in seen do continue
		if _, e := map_insert(&seen, item, true); e != nil do return "cannot verify relationship"
		parent := [1]string{item.fields.parent}
		refs := item.fields.depends_on[:]
		if kind == .Parent {
			if item.fields.parent == "" do continue
			refs = parent[:]
		}
		for ref in refs {
			next, issue := unique_task(view, ref)
			if issue != "" do return issue
			if _, e := append(&pending, next); e != nil do return "cannot verify relationship"
		}
	}
	return ""
}

@(private)
Dependency_Edit :: struct { task, prerequisite: string, remove: bool }

@(private)
plan_dependency :: proc(view: ^Collection, data: rawptr) -> ([]storage.Change, string) {
	context.allocator = context.temp_allocator
	edit := (^Dependency_Edit)(data)
	item, issue := unique_task(view, edit.task, diagnostic = edit.remove)
	if issue != "" do return nil, issue
	value := edit.prerequisite
	if !edit.remove {
		if strings.equal_fold(item.fields.id, value) do return nil, fmt.tprintf("%s: dependency_self_link", item.path)
		target, target_err := unique_task(view, value)
		if target_err != "" do return nil, target_err
		for ref in item.fields.depends_on {
			if strings.equal_fold(ref, value) do return nil, fmt.tprintf("%s: duplicate_dependency %s", item.path, value)
		}
		if issue = check_new_link(view, item, target, .Prerequisite); issue != "" do return nil, issue
		value = target.fields.id
	}
	source, read_err := read_versioned(view, item, mutation = true)
	if read_err != "" do return nil, read_err
	op := document.Sequence_Edit.Remove if edit.remove else document.Sequence_Edit.Append
	edited, e := document.plan_sequence_patch(source, .Depends_On, op, value, view.config.vocabulary, view.limits.source_bytes, view.limits.yaml, item.path)
	if problem := patch_issue(e); problem != "" do return nil, problem
	change := make([]storage.Change, 1)
	change[0] = {kind = .Replace, path = item.path, expected = item.version, data = transmute([]byte)edited}
	return change, ""
}

change_dependency :: proc(cwd: string, options: Project_Options, task, prerequisite: string, remove := false, limits := project.DEFAULT_SCAN_LIMITS) -> (operation, issue: string) {
	edit := Dependency_Edit{task, prerequisite, remove}
	return mutate_collection(cwd, options, plan_dependency, &edit, limits)
}
