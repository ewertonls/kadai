// Vertices are in the caller's stable task order. A stored reference points
// from its declaring task to its parent or prerequisite.
package graph

import "base:runtime"

Network :: struct {
	targets, referrers: [][dynamic]int,
	unresolved: []bool,
}

network :: proc(n: int) -> (g: Network, err: runtime.Allocator_Error) {
	g.targets = make([][dynamic]int, n) or_return
	g.referrers = make([][dynamic]int, n) or_return
	g.unresolved = make([]bool, n) or_return
	return
}

link :: proc(g: ^Network, from, to: int) -> (err: runtime.Allocator_Error) {
	_ = append(&g.targets[from], to) or_return
	_ = append(&g.referrers[to], from) or_return
	return
}

Cycles :: struct {
	leader: []int, // -1 for vertices outside cycles, otherwise the first member in task order.
	members: [][dynamic]int, // Indexed by leader. Members also follow task order.
}

// Two iterative DFS passes identify strongly connected components without
// recursion or enumerating all paths in a branching prerequisite graph.
cycles :: proc(g: Network) -> (result: Cycles, err: runtime.Allocator_Error) {
	n := len(g.targets)
	visited := make([]bool, n) or_return
	Frame :: struct { v, next: int }
	frames, finish := make([dynamic]Frame, 0, n) or_return, make([dynamic]int, 0, n) or_return
	for start in 0..<n {
		if visited[start] do continue
		visited[start] = true
		_ = append(&frames, Frame{v = start}) or_return
		for len(frames) != 0 {
			top := &frames[len(frames)-1]
			edges := g.targets[top.v]
			if top.next == len(edges) {
				_ = append(&finish, top.v) or_return
				pop(&frames)
				continue
			}
			next := edges[top.next]
			top.next += 1
			if visited[next] do continue
			visited[next] = true
			_ = append(&frames, Frame{v = next}) or_return
		}
	}

	result.leader = make([]int, n) or_return
	result.members = make([][dynamic]int, n) or_return
	component := make([dynamic]int, 0, n) or_return
	for &leader in result.leader do leader = -1
	#reverse for start in finish {
		if !visited[start] do continue
		clear(&component)
		_ = append(&component, start) or_return
		visited[start] = false
		first := start
		self := false
		for j := 0; j < len(component); j += 1 {
			v := component[j]
			for other in g.referrers[v] {
				if other == v do self = true
				if !visited[other] do continue
				visited[other] = false
				first = min(first, other)
				_ = append(&component, other) or_return
			}
		}
		if self || len(component) > 1 {
			for v in component do result.leader[v] = first
		}
	}
	for leader, v in result.leader {
		if leader >= 0 { _ = append(&result.members[leader], v) or_return }
	}
	return
}
