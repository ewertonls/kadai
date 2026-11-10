package app

import "base:runtime"
import "core:strings"
import "kadai:graph"
import "kadai:project"
import "kadai:yaml"

Severity :: enum {Error, Warning}
Cycle_Edge :: struct {from, to: string}
Finding :: struct {
	severity: Severity,
	code, path, id, field, target_id, message: string,
	location: yaml.Location,
	related: []^project.Candidate,
	edges: []Cycle_Edge, // Declaring task -> stored reference within a cyclic component.
}

@(private)
reference_findings :: proc(index: ^project.Index, out: ^[dynamic]Finding) -> (err: runtime.Allocator_Error) {
	for group in index.collisions {
		first := group[0]
		_ = append(out, Finding{code = "duplicate_id", path = first.path, id = first.fields.id,
			field = "id", location = first.id_location, related = group, message = "Multiple files declare this task ID."}) or_return
	}
	for &item in index.candidates {
		for ref in item.references {
			parent := ref.field == "parent"
			group, status := project.lookup(index, ref.id)
			f := Finding{path = item.path, id = item.fields.id, field = ref.field, target_id = ref.id, location = ref.location, related = group}
			if strings.equal_fold(item.fields.id, ref.id) {
				f.code = "parent_self_link" if parent else "dependency_self_link"
				f.message = "A task references itself."
				_ = append(out, f) or_return
			}
			switch status {
			case .Valid: continue
			case .Missing:
				f.code = "missing_parent" if parent else "missing_prerequisite"
				f.message = "Target is missing from this collection."
			case .Ambiguous:
				f.code = "ambiguous_parent" if parent else "ambiguous_prerequisite"
				f.message = "Target ID is ambiguous."
			case .Diagnostic_Only:
				if group[0].status == .Unsupported_Schema {
					f.code = "unsupported_parent" if parent else "unsupported_prerequisite"
					f.message = "Target uses an unsupported schema."
				} else {
					f.code = "invalid_parent_target" if parent else "invalid_prerequisite"
					f.message = "Target is schema-invalid."
				}
			case .Incomplete: return .Out_Of_Memory
			}
			_ = append(out, f) or_return
		}
	}
	return
}

@(private)
cycle_findings :: proc(index: ^project.Index, g: graph.Network, cycles: graph.Cycles, kind: Relation, out: ^[dynamic]Finding) -> (err: runtime.Allocator_Error) {
	for members, leader in cycles.members {
		if len(members) == 0 do continue
		group := make([]^project.Candidate, len(members)) or_return
		edges: [dynamic]Cycle_Edge
		for v, i in members {
			group[i] = index.valid[v]
			for next in g.targets[v] {
				if cycles.leader[next] == leader {
					_ = append(&edges, Cycle_Edge{group[i].fields.id, index.valid[next].fields.id}) or_return
				}
			}
		}
		parent := kind == .Parent
		_ = append(out, Finding{code = "parent_cycle" if parent else "dependency_cycle", field = "parent" if parent else "depends_on",
			id = group[0].fields.id, path = group[0].path, related = group, edges = edges[:], message = "References form a cycle."}) or_return
	}
	return
}

graph_findings :: proc(view: ^Collection) -> (out: [dynamic]Finding, issue: string) {
	context.allocator = context.temp_allocator
	if !view.index.complete do return nil, "incomplete task index"
	if reference_findings(&view.index, &out) != nil do return nil, "cannot inspect references"
	for kind in Relation {
		g, err := relationship_graph(&view.index, kind)
		if err != nil do return nil, "cannot build relationship graph"
		components, e := graph.cycles(g)
		if e != nil || cycle_findings(&view.index, g, components, kind, &out) != nil do return nil, "cannot inspect graph cycles"
	}
	return
}
