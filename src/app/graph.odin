package app

import "base:runtime"
import "kadai:graph"
import "kadai:project"

Relation :: enum {Parent, Prerequisite}

@(private)
relationship_graph :: proc(index: ^project.Index, kind: Relation) -> (g: graph.Network, err: runtime.Allocator_Error) {
	context.allocator = context.temp_allocator
	g = graph.network(len(index.valid)) or_return
	positions := make(map[^project.Candidate]int, len(index.valid)) or_return
	for item, i in index.valid { _ = map_insert(&positions, item, i) or_return }
	for item, i in index.valid {
		parent := [1]string{item.fields.parent}
		refs := item.fields.depends_on[:]
		if kind == .Parent {
			if parent[0] == "" do continue
			refs = parent[:]
		}
		for ref in refs {
			group, status := project.lookup(index, ref)
			if status == .Incomplete do return {}, .Out_Of_Memory
			if status != .Valid { g.unresolved[i] = true; continue }
			graph.link(&g, i, positions[group[0]]) or_return
		}
	}
	return
}
