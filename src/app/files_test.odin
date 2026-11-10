#+test
package app

import "core:os"
import "core:testing"
import "kadai:project"
import "kadai:storage"

@(test)
move_preserves_identity_and_discoverability :: proc(t: ^testing.T) {
	tmp, err := os.mkdir_temp("", "kadai-move-", context.temp_allocator)
	if !testing.expect(t, err == nil) do return
	defer os.remove_all(tmp)
	opts := Project_Options{override_exclude = true, exclude = {"ignored/"}}
	view, issue := read_collection(tmp, opts)
	if !testing.expect_value(t, issue, "") do return
	bytes: string = "---\nkadai: task\nid: T\ntitle: Title\nstatus: todo\n---\nbody"
	testing.expect_value(t, create_task_file(view.config, "old.md", transmute([]byte)bytes), "")
	view, issue = read_collection(tmp, opts)
	if !testing.expect_value(t, issue, "") do return
	for dst in ([]string{"old.md", "boards/x.md", "ignored/x.md", "../escape.md", ".kadai/x.md"}) {
		testing.expect(t, move_task_file(&view, "T", dst) != "", dst)
	}
	testing.expect_value(t, move_task_file(&view, "T", "nested/renamed.md"), "")
	view, issue = read_collection(tmp, opts)
	group, status := project.lookup(&view.index, "t")
	if !testing.expect(t, issue == "" && status == .Valid) do return
	testing.expect_value(t, group[0].path, "nested/renamed.md")
	data, _ := os.read_entire_file(storage.child(view.config.tasks, group[0].path), context.temp_allocator)
	testing.expect_value(t, string(data), bytes)
}
