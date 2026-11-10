package app

import "base:runtime"
import "kadai:graph"
import "kadai:project"

Ready_Task :: struct {item: ^project.Candidate, readiness: graph.Readiness}

@(private)
done_categories :: proc(view: ^Collection) -> (done: []bool, err: runtime.Allocator_Error) {
	done = make([]bool, len(view.index.valid), context.temp_allocator) or_return
	for item, i in view.index.valid do done[i] = category(&view.config, item.fields.status) == "done"
	return
}

ready_tasks :: proc(cwd: string, options: Project_Options, id: Maybe(string) = nil, limits := project.DEFAULT_SCAN_LIMITS) -> ([]Ready_Task, string) {
	context.allocator = context.temp_allocator
	view, issue := read_collection(cwd, options, limits)
	if issue != "" do return nil, issue
	selected: ^project.Candidate
	if requested, ok := id.?; ok {
		selected, issue = unique_task(&view, requested)
		if issue != "" do return nil, issue
	}
	g, e := relationship_graph(&view.index, .Prerequisite)
	if e != nil do return nil, "cannot build prerequisite graph"
	cycles, cycle_err := graph.cycles(g)
	if cycle_err != nil do return nil, "cannot determine dependency cycles"
	done, alloc_err := done_categories(&view)
	if alloc_err != nil do return nil, "cannot resolve task categories"
	rows: [dynamic]Ready_Task
	for item, i in view.index.valid {
		if selected != nil && item != selected do continue
		state := graph.readiness_at(g, cycles, done, i)
		if selected == nil {
			status := category(&view.config, item.fields.status)
			if state != .Ready || status != "todo" && status != "in_progress" do continue
		}
		if _, err := append(&rows, Ready_Task{item, state}); err != nil do return nil, "cannot allocate readiness result"
	}
	return rows[:], ""
}
