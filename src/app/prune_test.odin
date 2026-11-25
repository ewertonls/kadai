#+test
package app

import "core:os"
import "core:strings"
import "core:testing"
import "kadai:storage"

@(test)
prune_preserves_pending_recovery_and_finishes_interrupted_cleanup :: proc(t: ^testing.T) {
	tmp, e := os.mkdir_temp("", "kadai-prune-restart-", context.temp_allocator)
	if !testing.expect(t, e == nil) do return
	defer os.remove_all(tmp)
	_, issue := create_task(tmp, {}, {title = "Retired task"})
	if !testing.expect_value(t, issue, "") do return
	id, problem := remove_task(tmp, {}, {id = "0001"})
	if !testing.expect_value(t, problem, "") do return
	root, path_err := storage.physical(storage.child(tmp, "tasks"), .Directory)
	if !testing.expect(t, path_err == nil) do return
	state := storage.child(root, ".kadai")
	archive := storage.child(storage.child(state, "recovery"), id)
	receipt, read_err := os.read_entire_file(
		storage.child(archive, "committed"),
		context.temp_allocator,
	)
	if !testing.expect(t, read_err == nil) do return

	// A crash can leave one pointer even after recording completion.
	pending := storage.child(state, "pending")
	if !testing.expect(t, os.write_entire_file(pending, receipt) == nil) do return
	_, issue = prune_recovery(tmp, {}, 0, false)
	original := storage.child(archive, "0-original")
	testing.expect(t, issue != "" && os.exists(original) && os.exists(pending))

	// Recovery can finish even if the process exited before writing the receipt.
	stage_name :: ".kadai-stage-0123456789abcdef0123456789abcdef"
	receipt_stage := storage.child(archive, stage_name)
	if !testing.expect(t, os.rename(storage.child(archive, "committed"), receipt_stage) == nil) do return
	if !testing.expect(t, os.write_entire_file(receipt_stage, "") == nil) do return
	_, issue = recover_collection(tmp, {}, .Resume)
	if !testing.expect_value(t, issue, "") do return
	if !testing.expect(t, os.write_entire_file(receipt_stage, "unrelated") == nil) do return
	_, issue = prune_recovery(tmp, {}, 0, false)
	testing.expect(t, issue != "" && os.exists(receipt_stage) && os.exists(original))
	for written in ([3]int{0, len(receipt) / 2, len(receipt)}) {
		if !testing.expect(t, os.write_entire_file(receipt_stage, receipt[:written]) == nil) do return
		preview, selection_issue := prune_recovery(tmp, {}, 0, true)
		if !testing.expect(t, selection_issue == "" && len(preview) == 2, selection_issue) do return
	}

	// Interrupt a prune after detaching the archive and removing one image.
	stage, stage_err := storage.open_dir(
		storage.child(state, "pruning"),
		create = true,
		private_leaf = true,
	)
	if !testing.expect(t, stage_err == nil) do return
	detached := storage.child(stage.path, id)
	storage.close_dir(&stage)
	if !testing.expect(t, os.rename(archive, detached) == nil) do return
	if !testing.expect(t, os.remove(storage.child(detached, "0-original")) == nil) do return
	foreign_file := storage.child(detached, "notes.txt")
	if !testing.expect(t, os.write_entire_file(foreign_file, "keep") == nil) do return
	_, issue = prune_recovery(tmp, {}, 30, false)
	plan := storage.child(detached, "plan")
	testing.expect(t, issue != "" && os.exists(foreign_file) && os.exists(plan))
	if !testing.expect(t, os.remove(foreign_file) == nil) do return

	// Each one-step manifest costs nine nodes, including the detached one.
	limits := DEFAULT_SCAN_LIMITS
	limits.total_nodes = 9
	_, issue = prune_recovery(tmp, {}, 0, false, limits)
	testing.expect(t, strings.contains(issue, "node") && os.exists(plan), issue)
	ids, preview_issue := prune_recovery(tmp, {}, 30, true)
	if !testing.expect_value(t, preview_issue, "") do return
	testing.expect(t, len(ids) == 1 && ids[0] == id && os.exists(plan))

	// With only the terminal receipt left, its ID must still match the directory.
	if !testing.expect(t, os.remove(storage.child(detached, stage_name)) == nil) do return
	if !testing.expect(t, os.remove(storage.child(detached, "0-restore")) == nil && os.remove(plan) == nil) do return
	terminal := storage.child(detached, "committed")
	first := receipt[0]
	receipt[0] = '1' if first == '0' else '0'
	if !testing.expect(t, os.write_entire_file(terminal, receipt) == nil) do return
	_, issue = prune_recovery(tmp, {}, 30, false)
	testing.expect(t, issue != "" && os.exists(terminal))
	receipt[0] = first
	if !testing.expect(t, os.write_entire_file(terminal, receipt) == nil) do return
	_, issue = prune_recovery(tmp, {}, 30, false)
	if !testing.expect_value(t, issue, "") do return
	testing.expect(t, !os.exists(detached))
	next, create_err := create_task(tmp, {}, {title = "Next task"})
	testing.expect_value(t, create_err, "")
	testing.expect_value(t, next, "0002")
}
