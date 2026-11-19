#+test
package app

import "core:os"
import "core:testing"

@(test)
tree_keeps_broken_and_cyclic_branches_distinct :: proc(t: ^testing.T) {
	tmp, e := os.mkdir_temp("", "kadai-tree-", context.temp_allocator)
	if !testing.expect(t, e == nil) do return
	defer os.remove_all(tmp)
	cases := []struct {
		name, id, links: string,
	} {
		{"z.md", "Root", ""},
		{"a.md", "First", "parent: Root\n"},
		{"b.md", "Second", "parent: Root\n"},
		{"m.md", "Broken", "parent: Unknown\n"},
		{"n.md", "X", "parent: Y\n"},
		{"o.md", "Y", "parent: X\n"},
		{"c.md", "Leaf", "parent: x\n"},
	}
	for c in cases do testing.expect(t, write_graph_task(tmp, c.name, c.id, "todo", c.links))
	rows, issue := task_tree(tmp, {tasks_root = "."})
	if !testing.expect(t, issue == "" && len(rows) == len(cases)) do return
	want := []struct {
		id      : string,
		depth   : int,
		position: Tree_Position,
	} {
		{"Root", 0, .Root},
		{"First", 1, .Child},
		{"Second", 1, .Child},
		{"Broken", 0, .Unresolved_Parent},
		{"X", 0, .Parent_Cycle},
		{"Leaf", 1, .Child},
		{"Y", 0, .Parent_Cycle},
	}
	for row, i in rows {
		testing.expect_value(t, row.item.fields.id, want[i].id)
		testing.expect_value(t, row.depth, want[i].depth)
		testing.expect_value(t, row.position, want[i].position)
	}
}
