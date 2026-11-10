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
	create_plan :: proc(view: ^Collection, data: rawptr) -> ([]storage.Change, string) {
		changes := make([]storage.Change, 1, context.temp_allocator)
		changes[0] = {kind = .Create, path = "old.md", data = transmute([]byte)(^string)(data)^}
		return changes, ""
	}
	move_plan :: proc(view: ^Collection, data: rawptr) -> ([]storage.Change, string) {
		group, status := project.lookup(&view.index, "T")
		if status != .Valid do return nil, "missing task"
		change := make([]storage.Change, 1, context.temp_allocator)
		change[0] = {kind = .Move, path = group[0].path, expected = group[0].version, destination = (^string)(data)^}
		return change, ""
	}
	_, issue = mutate_collection(tmp, opts, create_plan, &bytes)
	testing.expect_value(t, issue, "")
	view, issue = read_collection(tmp, opts)
	if !testing.expect_value(t, issue, "") do return
	for target in ([]string{"old.md", "boards/x.md", "ignored/x.md", "../escape.md", ".kadai/x.md"}) {
		dst := target
		_, issue = mutate_collection(tmp, opts, move_plan, &dst)
		testing.expect(t, issue != "", dst)
	}
	dst := "nested/renamed.md"
	_, issue = mutate_collection(tmp, opts, move_plan, &dst)
	testing.expect_value(t, issue, "")
	view, issue = read_collection(tmp, opts)
	group, status := project.lookup(&view.index, "t")
	if !testing.expect(t, issue == "" && status == .Valid) do return
	testing.expect_value(t, group[0].path, "nested/renamed.md")
	data, _ := os.read_entire_file(storage.child(view.config.tasks, group[0].path), context.temp_allocator)
	testing.expect_value(t, string(data), bytes)
}
