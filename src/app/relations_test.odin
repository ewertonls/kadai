#+test
package app

import "core:fmt"
import "core:os"
import "core:testing"
import "kadai:storage"

@(private)
write_graph_task :: proc(root, path, id, status: string, extra := "") -> bool {
	text := fmt.tprintf("---\nkadai: task\nid: %s\ntitle: Example\nstatus: %s\n%s---\nbody", id, status, extra)
	return os.write_entire_file(storage.child(root, path), text) == nil
}

@(test)
parent_changes_only_child_metadata :: proc(t: ^testing.T) {
	tmp, e := os.mkdir_temp("", "kadai-parent-", context.temp_allocator)
	if !testing.expect(t, e == nil) do return
	defer os.remove_all(tmp)
	opts := Project_Options{tasks_root = "."}
	testing.expect(t, write_graph_task(tmp, "p.md", "Parent", "done", "depends_on: [Child]\n"))
	testing.expect(t, write_graph_task(tmp, "c.md", "Child", "todo", "parent: missing # keep\n"))
	_, issue := set_parent(tmp, opts, "child", "PARENT")
	if !testing.expect_value(t, issue, "") do return
	_, issue = set_parent(tmp, opts, "Parent", "Child")
	testing.expect(t, issue != "")
	_, issue = set_parent(tmp, opts, "Child", "absent")
	testing.expect(t, issue != "")
	_, issue = set_parent(tmp, opts, "child", nil)
	testing.expect_value(t, issue, "")
	data, _ := os.read_entire_file(storage.child(tmp, "c.md"), context.temp_allocator)
	testing.expect_value(t, string(data), "---\nkadai: task\nid: Child\ntitle: Example\nstatus: todo\nparent: null # keep\n---\nbody")
}
