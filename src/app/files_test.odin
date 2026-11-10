#+test
package app

import "core:fmt"
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
	testing.expect(t, os.mkdir(view.config.tasks) == nil)
	testing.expect(t, os.write_entire_file(storage.child(view.config.tasks, "old.md"), bytes) == nil)
	ref := "---\nkadai: task\nid: R\ntitle: Ref\nstatus: todo\nparent: t\ndepends_on: [T]\n---\n"
	ref_path := storage.child(view.config.tasks, "ref.md")
	testing.expect(t, os.write_entire_file(ref_path, ref) == nil)
	view, issue = read_collection(tmp, opts)
	if !testing.expect_value(t, issue, "") do return
	for target in ([]string{"old.md", "boards/x.md", "ignored/x.md", "../escape.md", ".kadai/x.md"}) {
		dst := target
		_, issue = move_task(tmp, opts, {"T", dst, false})
		testing.expect(t, issue != "", dst)
	}
	dst := "nested/renamed.md"
	_, issue = move_task(tmp, opts, {"T", dst, false})
	testing.expect_value(t, issue, "")
	view, issue = read_collection(tmp, opts)
	group, status := project.lookup(&view.index, "t")
	if !testing.expect(t, issue == "" && status == .Valid) do return
	testing.expect_value(t, group[0].path, "nested/renamed.md")
	data, _ := os.read_entire_file(storage.child(view.config.tasks, group[0].path), context.temp_allocator)
	testing.expect_value(t, string(data), bytes)
	references, _ := os.read_entire_file(ref_path, context.temp_allocator)
	testing.expect_value(t, string(references), ref)
}

@(test)
directory_move_preserves_members_and_guards_rollback :: proc(t: ^testing.T) {
	tmp, e := os.mkdir_temp("", "kadai-directory-", context.temp_allocator)
	if !testing.expect(t, e == nil) do return
	defer os.remove_all(tmp)
	opts := Project_Options{override_exclude = true, exclude = {"hidden/deep/*"}}
	id, issue := create_task(tmp, opts, {title = "Nested", destination = "old/deep/name.md"})
	if !testing.expect_value(t, issue, "") do return
	root := storage.child(tmp, "tasks")
	extra := storage.child(root, "old/note.txt")
	testing.expect(t, os.write_entire_file(extra, "text") == nil)
	testing.expect(t, os.mkdir(storage.child(root, "old/empty")) == nil)
	_, issue = move_task(tmp, opts, {"old", "other/.kadai.yaml", true})
	testing.expect(t, issue != "" && !os.exists(storage.child(root, "other")))
	_, issue = move_task(tmp, opts, {"old", "hidden", true})
	testing.expect(t, issue != "" && !os.exists(storage.child(root, "hidden")))
	op: string
	op, issue = move_task(tmp, opts, {"old", "new", true})
	if !testing.expect_value(t, issue, "") do return
	read, problem := get_task(tmp, opts, id)
	if !testing.expect_value(t, problem, "") do return
	testing.expect_value(t, read.item.path, "new/deep/name.md")
	testing.expect(t, !os.exists(storage.child(root, "old")) && os.is_dir(storage.child(root, "new/empty")))
	changed := storage.child(root, "new/note.txt")
	testing.expect(t, os.write_entire_file(changed, "later") == nil)
	_, issue = recover_collection(tmp, opts, .Rollback, op)
	testing.expect(t, issue != "" && !os.exists(extra))
	testing.expect(t, os.write_entire_file(changed, "text") == nil)
	_, issue = recover_collection(tmp, opts, .Rollback, op)
	testing.expect_value(t, issue, "")
	testing.expect(t, os.exists(extra) && !os.exists(storage.child(root, "new")))
	report: Validation
	report, problem = validate_project(tmp, opts)
	if !testing.expect(t, problem == "" && report.errors == 0) do return
	archive := storage.child(storage.child(root, ".kadai/recovery"), op)
	name := fmt.tprintf("original-%s", storage.digest(transmute([]byte)string("note.txt")))
	if !testing.expect(t, os.remove(storage.child(archive, name)) == nil) do return
	report, problem = validate_project(tmp, opts)
	testing.expect(t, problem == "" && count_finding(report, "corrupt_snapshot") == 1)
}
