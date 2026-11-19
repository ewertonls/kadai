package graph

import "core:strings"

Readiness :: enum {
	Ready,
	Blocked,
	Unresolved,
}
Node      :: struct {
	category  : string,
	depends_on: []string,
}

// An SCC affects only its own members. For a caller outside that SCC, a
// resolved direct prerequisite satisfies the dependency when its category is done.
readiness_at :: proc(g: Network, cycles: Cycles, done: []bool, vertex: int) -> Readiness {
	if cycles.leader[vertex] >= 0 || g.unresolved[vertex] do return .Unresolved
	for other in g.targets[vertex] {
		if !done[other] do return .Blocked
	}
	return .Ready
}

// Standalone in-memory query. Keys are ASCII-folded IDs of unique, supported tasks.
readiness :: proc(nodes: map[string]Node, id: string) -> Readiness {
	context.allocator = context.temp_allocator
	positions, alloc_err := make(map[string]int, len(nodes))
	if alloc_err != nil do return .Unresolved
	g, e := network(len(nodes))
	if e != nil do return .Unresolved
	done, e2 := make([]bool, len(nodes))
	if e2 != nil do return .Unresolved
	for key, node in nodes {
		i := len(positions)
		if _, err := map_insert(&positions, key, i); err != nil do return .Unresolved
		done[i] = node.category == "done"
	}
	folded, fold_err := strings.to_lower(id)
	if fold_err != nil || len(folded) != len(id) do return .Unresolved
	v, ok := positions[folded]
	if !ok do return .Unresolved
	for key, node in nodes {
		from := positions[key]
		for ref in node.depends_on {
			ref_key, err := strings.to_lower(ref)
			if err != nil || len(ref_key) != len(ref) do return .Unresolved
			to, resolved := positions[ref_key]
			if !resolved {g.unresolved[from] = true; continue}
			if link(&g, from, to) != nil do return .Unresolved
		}
	}
	c, err := cycles(g)
	if err != nil do return .Unresolved
	return readiness_at(g, c, done, v)
}
