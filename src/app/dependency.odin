package app

import "core:fmt"
import "core:strings"
import "kadai:document"
import "kadai:project"
import "kadai:storage"

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

Target_Status :: enum {Resolved, Missing, Ambiguous, Invalid, Unsupported}
Target :: struct {
	written_id: string,
	status: Target_Status,
	candidates: []^project.Candidate,
}

@(private)
resolve_reference :: proc(index: ^project.Index, id: string) -> (target: Target, ok: bool) {
	group, state := project.lookup(index, id)
	target.written_id, target.candidates = id, group
	switch state {
	case .Valid: target.status = .Resolved
	case .Missing: target.status = .Missing
	case .Ambiguous: target.status = .Ambiguous
	case .Diagnostic_Only: target.status = .Unsupported if group[0].status == .Unsupported_Schema else .Invalid
	case .Incomplete: return {}, false
	}
	return target, true
}

Dependency_View :: struct {
	task: ^project.Candidate,
	prerequisites: []Target, // Retains frontmatter order, including unresolved references.
	dependents: []^project.Candidate, // Unique valid tasks, in collection-relative path order.
}

dependencies :: proc(cwd: string, options: Project_Options, id: string, limits := project.DEFAULT_SCAN_LIMITS) -> (result: Dependency_View, issue: string) {
	context.allocator = context.temp_allocator
	view: Collection
	view, issue = read_collection(cwd, options, limits)
	if issue != "" do return
	result.task, issue = unique_task(&view, id)
	if issue != "" do return
	g, e := relationship_graph(&view.index, .Prerequisite)
	if e != nil do return {}, "cannot build dependency view"
	refs := result.task.fields.depends_on[:]
	result.prerequisites, e = make([]Target, len(refs))
	if e != nil do return {}, "cannot allocate prerequisite list"
	for ref, j in refs {
		target, ok := resolve_reference(&view.index, ref)
		if !ok do return {}, "cannot resolve prerequisite"
		result.prerequisites[j] = target
	}
	for item, v in view.index.valid {
		if item != result.task do continue
		result.dependents, e = make([]^project.Candidate, len(g.referrers[v]))
		if e != nil do return {}, "cannot allocate dependent list"
		for from, j in g.referrers[v] do result.dependents[j] = view.index.valid[from]
		break
	}
	return
}
