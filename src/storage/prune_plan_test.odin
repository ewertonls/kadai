#+test
package storage

import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

@(test)
prune_selects_by_terminal_receipt_and_preserves_unverified_files :: proc(t: ^testing.T) {
	tmp, err := os.mkdir_temp("", "kadai-prune-plan-", context.temp_allocator)
	if !testing.expect(t, err == nil) do return
	defer os.remove_all(tmp)
	root, _ := physical(tmp, .Directory)
	w, lock_err := begin_writer()
	if !testing.expect(t, lock_err == nil) do return
	defer end_writer(&w)
	if !testing.expect(t, lock_collection(&w, root) == nil) do return
	id, issue := commit(&w, {{kind = .Create, path = "A.md", data = {42}}})
	if !testing.expect_value(t, issue, "") do return
	path := child(child(root, ".kadai/recovery"), id)

	// A failed preparation has neither a completion date nor permission to
	// discard its contents, even when the cutoff includes every receipt.
	orphan, orphan_err := op_directory(root, random_name(""), true)
	if !testing.expect(t, orphan_err == nil) do return
	close_dir(&orphan)
	committed := child(path, "committed")
	first := time.unix(1_700_000_000, 0)
	if !testing.expect(t, os.change_times(committed, first, first) == nil) do return
	cutoff := i128(time.to_unix_nanoseconds(first))
	ids: []string
	ids, issue = prune(&w, root, cutoff - 1, true, DEFAULT_JOURNAL_LIMITS)
	testing.expect(t, issue == "" && len(ids) == 0, issue)
	ids, issue = prune(&w, root, cutoff, true, DEFAULT_JOURNAL_LIMITS)
	testing.expect(t, issue == "" && len(ids) == 1 && ids[0] == id, issue)

	_, issue = recover(&w, .Rollback, id)
	if !testing.expect_value(t, issue, "") do return
	last := time.time_add(first, time.Hour)
	if !testing.expect(t, os.change_times(child(path, "rolled-back"), last, last) == nil) do return
	ids, issue = prune(&w, root, cutoff, true, DEFAULT_JOURNAL_LIMITS)
	testing.expect(t, issue == "" && len(ids) == 0, issue)
	cutoff = i128(time.to_unix_nanoseconds(last))
	ids, issue = prune(&w, root, cutoff, true, DEFAULT_JOURNAL_LIMITS)
	testing.expect(t, issue == "" && len(ids) == 1 && ids[0] == id, issue)

	foreign_path := child(path, "my-notes")
	if !testing.expect(t, os.write_entire_file(foreign_path, "keep") == nil) do return
	ids, issue = prune(&w, root, cutoff, true, DEFAULT_JOURNAL_LIMITS)
	testing.expect(t, len(ids) == 0 && strings.contains(issue, "unknown_recovery_entry"), issue)
	if !testing.expect(t, os.remove(foreign_path) == nil) do return
	if !testing.expect(t, os.write_entire_file(committed, "bad receipt") == nil) do return
	ids, issue = prune(&w, root, cutoff, true, DEFAULT_JOURNAL_LIMITS)
	testing.expect(t, len(ids) == 0 && strings.contains(issue, "corrupt_receipt"), issue)
}
