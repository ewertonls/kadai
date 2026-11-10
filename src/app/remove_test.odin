#+test
package app

import "core:os"
import "core:strings"
import "core:testing"
import "kadai:storage"

@(test)
detached_removal_previews_then_rechecks_every_reference :: proc(t: ^testing.T) {
	tmp, e := os.mkdir_temp("", "kadai-remove-", context.temp_allocator)
	if !testing.expect(t, e == nil) do return
	defer os.remove_all(tmp)
	root := storage.child(tmp, "tasks")
	testing.expect(t, os.mkdir(root) == nil)
	target := storage.child(root, "target.md")
	ref := storage.child(root, "ref.md")
	target_doc := "---\nkadai: task\nid: 0042\ntitle: Target\nstatus: todo\n---\n"
	ref_doc := "---\nkadai: task\nid: Ref\ntitle: Related\nstatus: done\nparent: 0042 # family\ndepends_on: [Z, 0042] # order\n---\n0042 in body"
	testing.expect(t, os.write_entire_file(target, target_doc) == nil)
	testing.expect(t, os.write_entire_file(ref, ref_doc) == nil)
	preview, issue := preview_removal(tmp, {}, {id = "0042", detach = true})
	if !testing.expect_value(t, issue, "") do return
	testing.expect_value(t, len(preview.edits), 3)
	for edit in preview.edits[:2] do testing.expect_value(t, ref_doc[edit.span.start:edit.span.end], "0042")
	testing.expect(t, !os.exists(storage.child(root, ".kadai")))
	_, issue = remove_task(tmp, {}, {id = "0042"})
	testing.expect(t, strings.contains(issue, "parent references") && strings.contains(issue, "depends_on references"))
	testing.expect(t, !os.exists(storage.child(root, ".kadai/used-ids")))
	testing.expect(t, os.write_entire_file(ref, strings.concatenate({ref_doc, "!"}, context.temp_allocator)) == nil)
	_, issue = remove_task(tmp, {}, {id = "0042", detach = true, expected_plan = preview.token})
	testing.expect_value(t, issue, "stale removal plan")
	testing.expect(t, os.exists(target))
	preview, issue = preview_removal(tmp, {}, {id = "0042", detach = true})
	if !testing.expect_value(t, issue, "") do return
	op, problem := remove_task(tmp, {}, {id = "0042", detach = true, expected_plan = preview.token})
	if !testing.expect_value(t, problem, "") do return
	testing.expect(t, !os.exists(target))
	bytes, _ := os.read_entire_file(ref, context.temp_allocator)
	testing.expect(t, strings.contains(string(bytes), "status: done\nparent: null # family\ndepends_on: [Z] # order\n---\n0042 in body!"))
	id, create_err := create_task(tmp, {}, {title = "Next"})
	testing.expect_value(t, create_err, "")
	testing.expect_value(t, id, "0043")
	manual := storage.child(root, "manual-restore.md")
	testing.expect(t, os.write_entire_file(manual, target_doc) == nil)
	_, issue = recover_collection(tmp, {}, .Rollback, op)
	testing.expect(t, issue != "" && !os.exists(target))
	testing.expect(t, os.remove(manual) == nil)
	_, issue = recover_collection(tmp, {}, .Rollback, op)
	testing.expect_value(t, issue, "")
	bytes, _ = os.read_entire_file(ref, context.temp_allocator)
	testing.expect_value(t, string(bytes), strings.concatenate({ref_doc, "!"}, context.temp_allocator))
	testing.expect(t, os.exists(target))
}

@(test)
unknown_inbound_references_block_deletion :: proc(t: ^testing.T) {
	tmp, e := os.mkdir_temp("", "kadai-remove-unknown-", context.temp_allocator)
	if !testing.expect(t, e == nil) do return
	defer os.remove_all(tmp)
	id, issue := create_task(tmp, {}, {title = "Safe"})
	if !testing.expect_value(t, issue, "") do return
	root := storage.child(tmp, "tasks")
	path := storage.child(root, "future.md")
	testing.expect(t, os.write_entire_file(path, "---\nkadai: task\nid: F\nschema_version: 2\n---\n") == nil)
	_, issue = remove_task(tmp, {}, {id = id, detach = true})
	testing.expect(t, strings.contains(issue, "future.md"))
	testing.expect(t, os.exists(storage.child(root, "0001.md")))
}
