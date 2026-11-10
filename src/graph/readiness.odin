// Read-only prerequisite semantics over the unique, supported tasks in one collection.
package graph

import "core:strings"

Readiness :: enum {Ready, Blocked, Unresolved}
Node :: struct {
	category: string,
	depends_on: []string,
}

// Keys are ASCII-folded IDs. Missing nodes include quarantined and unsupported
// targets. Only a cycle returning to this task affects its own readiness.
readiness :: proc(nodes: map[string]Node, id: string) -> Readiness {
	context.allocator = context.temp_allocator
	start := strings.to_lower(id)
	source, known := nodes[start]
	if !known do return .Unresolved
	result := Readiness.Ready
	queue: [dynamic]string
	seen: map[string]bool
	for dependency in source.depends_on {
		key := strings.to_lower(dependency)
		target, ok := nodes[key]
		if !ok || key == start do return .Unresolved
		if target.category != "done" do result = .Blocked
		if key not_in seen {
			if _, e := map_insert(&seen, key, true); e != nil do return .Unresolved
			if _, e := append(&queue, key); e != nil do return .Unresolved
		}
	}
	for len(queue) != 0 {
		node := nodes[pop(&queue)]
		for dependency in node.depends_on {
			key := strings.to_lower(dependency)
			if key == start do return .Unresolved
			if len(key) != len(dependency) do return .Unresolved
			if key in seen || key not_in nodes do continue
			if _, e := map_insert(&seen, key, true); e != nil do return .Unresolved
			if _, e := append(&queue, key); e != nil do return .Unresolved
		}
	}
	return result
}
