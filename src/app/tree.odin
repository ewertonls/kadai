package app

import "base:runtime"
import "kadai:graph"
import "kadai:project"

Tree_Position :: enum {Root, Child, Unresolved_Parent, Parent_Cycle}
Tree_Row :: struct {item: ^project.Candidate, depth: int, position: Tree_Position}

@(private)
tree_rows :: proc(index: ^project.Index) -> (rows: []Tree_Row, err: runtime.Allocator_Error) {
	context.allocator = context.temp_allocator
	g := relationship_graph(index, .Parent) or_return
	cycles := graph.cycles(g) or_return
	Visit :: struct {node, depth: int, position: Tree_Position}
	stack := make([dynamic]Visit, 0, len(index.valid)) or_return
	// Push in reverse presentation order. Each cycle member starts its own
	// marked branch. Ordinary descendants retain their actual parent.
	#reverse for group in cycles.members {
		#reverse for v in group { _ = append(&stack, Visit{v, 0, .Parent_Cycle}) or_return }
	}
	#reverse for broken, v in g.unresolved {
		if broken { _ = append(&stack, Visit{v, 0, .Unresolved_Parent}) or_return }
	}
	#reverse for item, v in index.valid {
		if item.fields.parent == "" { _ = append(&stack, Visit{v, 0, .Root}) or_return }
	}

	out := make([dynamic]Tree_Row, 0, len(index.valid)) or_return
	for len(stack) > 0 {
		current := pop(&stack)
		_ = append(&out, Tree_Row{index.valid[current.node], current.depth, current.position}) or_return
		#reverse for child in g.referrers[current.node] {
			if cycles.leader[child] >= 0 do continue
			_ = append(&stack, Visit{child, current.depth+1, .Child}) or_return
		}
	}
	return out[:], nil
}

task_tree :: proc(cwd: string, options: Project_Options, limits := project.DEFAULT_SCAN_LIMITS) -> ([]Tree_Row, string) {
	view, issue := read_collection(cwd, options, limits)
	if issue != "" do return nil, issue
	rows, err := tree_rows(&view.index)
	if err != nil do return nil, "cannot build task tree"
	return rows, ""
}
