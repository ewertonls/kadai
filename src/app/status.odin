package app

import "core:strings"
import "kadai:graph"
import "kadai:project"

@(private)
category :: proc(cfg: ^project.Config, status: string) -> string {
	if mapped, ok := cfg.statuses[status]; ok do return mapped
	return status
}

@(private)
task_readiness :: proc(view: ^Collection, item: ^project.Candidate) -> graph.Readiness {
	// A directed status repair can have unrelated invalid fields. An
	// unparseable prerequisite list cannot be treated as an empty list.
	for d in item.diagnostics {
		if d.field == "depends_on" do return .Unresolved
	}
	context.allocator = context.temp_allocator
	nodes := make(map[string]graph.Node, len(view.index.valid) + 1)
	for valid in view.index.valid {
		key := strings.to_lower(valid.fields.id)
		if len(key) != len(valid.fields.id) do return .Unresolved
		if _, e := map_insert(&nodes, key, graph.Node{category(&view.config, valid.fields.status), valid.fields.depends_on[:]}); e != nil do return .Unresolved
	}
	id := strings.to_lower(item.fields.id)
	if len(id) != len(item.fields.id) do return .Unresolved
	if _, e := map_insert(&nodes, id, graph.Node{category(&view.config, item.fields.status), item.fields.depends_on[:]}); e != nil do return .Unresolved
	return graph.readiness(nodes, id)
}

set_status :: proc(
	cwd: string,
	options: Project_Options,
	id, status: string,
	force := false,
	limits := project.DEFAULT_SCAN_LIMITS,
) -> (
	operation, issue: string,
) {
	return update_task(
		cwd,
		options,
		{id = id, field = "status", values = {status}, force = force},
		limits,
	)
}
