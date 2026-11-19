package app

import "base:runtime"
import "core:slice"
import "kadai:project"

Dependency_Direction :: enum {
	Prerequisites,
	Dependents,
}
Dependency_Edge      :: struct {
	prerequisite, dependent: string,
	resolution             : Target_Status,
}
Dependency_Graph     :: struct {
	task     : ^project.Candidate,
	direction: Dependency_Direction,
	edges    : []Dependency_Edge,
}

@(private)
prerequisite_edges :: proc(
	index: ^project.Index,
	start: ^project.Candidate,
) -> (
	result: []Dependency_Edge,
	err: runtime.Allocator_Error,
) {
	context.allocator = context.temp_allocator
	seen: map[^project.Candidate]struct{}
	queue: [dynamic]^project.Candidate
	edges: [dynamic]Dependency_Edge
	_ = map_insert(&seen, start, {}) or_return
	_ = append(&queue, start) or_return
	for i := 0; i < len(queue); i += 1 {
		item := queue[i]
		for ref in item.fields.depends_on {
			target, ok := resolve_reference(index, ref)
			if !ok do return nil, .Out_Of_Memory
			_ = append(
				&edges,
				Dependency_Edge{target_display_id(target), item.fields.id, target.status},
			) or_return
			if target.status != .Resolved do continue
			next := target.candidates[0]
			_, _, inserted := map_entry(&seen, next) or_return
			if inserted do _ = append(&queue, next) or_return
		}
	}
	return edges[:], nil
}

@(private)
dependent_edges :: proc(
	index: ^project.Index,
	start: int,
) -> (
	result: []Dependency_Edge,
	err: runtime.Allocator_Error,
) {
	context.allocator = context.temp_allocator
	g := relationship_graph(index, .Prerequisite) or_return
	seen := make([]bool, len(index.valid)) or_return
	queue := make([dynamic]int, 0, len(index.valid)) or_return
	_ = append(&queue, start) or_return
	seen[start] = true
	edges: [dynamic]Dependency_Edge
	for i := 0; i < len(queue); i += 1 {
		v := queue[i]
		for next in g.referrers[v] {
			_ = append(
				&edges,
				Dependency_Edge{index.valid[v].fields.id, index.valid[next].fields.id, .Resolved},
			) or_return
			if seen[next] do continue
			seen[next] = true
			_ = append(&queue, next) or_return
		}
	}
	return edges[:], nil
}

dependency_graph :: proc(
	cwd: string,
	options: Project_Options,
	id: string,
	direction: Dependency_Direction,
	limits := project.DEFAULT_SCAN_LIMITS,
) -> (
	Dependency_Graph,
	string,
) {
	view, issue := read_collection(cwd, options, limits)
	if issue != "" do return {}, issue
	item, problem := unique_task(&view, id)
	if problem != "" do return {}, problem
	edges: []Dependency_Edge
	err: runtime.Allocator_Error
	switch direction {
	case .Prerequisites:
		edges, err = prerequisite_edges(&view.index, item)
	case .Dependents:
		start, found := slice.linear_search(view.index.valid[:], item)
		if !found do return {}, "cannot locate dependency graph subject"
		edges, err = dependent_edges(&view.index, start)
	}
	if err != nil do return {}, "cannot build dependency graph"
	return {item, direction, edges}, ""
}
