#+test
package storage

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
discard_preparation_preserves_entries_with_different_identities :: proc(t: ^testing.T) {
	tmp, tmp_err := os.mkdir_temp("", "kadai-discard-", context.temp_allocator)
	if !testing.expect(t, tmp_err == nil) do return
	defer os.remove_all(tmp)
	root, root_err := physical(tmp, .Directory)
	if !testing.expect(t, root_err == nil) do return
	vault, vault_err := open_dir(root)
	if !testing.expect(t, vault_err == nil) do return
	defer close_dir(&vault)
	id := random_name("")
	created := false
	dir, dir_err := create_private_dir(&vault, id, &created)
	if !testing.expect(t, dir_err == nil) do return
	defer close_dir(&dir)

	prep := Preparation {
		images = make([dynamic]Prepared_File, context.temp_allocator),
	}
	defer {when ODIN_OS != .Windows {release_preparation_pins(&prep)}}
	dir.preparation = &prep
	if !testing.expect(t, create_file(&dir, "plan", {1}, prepared_plan = &prep) == nil) do return
	_, image_err := save_image(&dir, "0-next", {2}, nil, 1)
	if !testing.expect(t, image_err == nil && len(prep.images) == 1) do return

	plan := prep.plan
	image := prep.images[0].identity
	plan_path, image_path := child(dir.path, "plan"), child(dir.path, "0-next")
	if !testing.expect(t, plan.inode != 0 && image.inode != 0) do return
	when ODIN_OS != .Windows {testing.expect_value(t, len(prep.pins), 2)}
	prep.plan = image
	if !testing.expect(t, discard_preparation(&vault, &dir, id) == .Invalid_File) do return
	data, e := os.read_entire_file(plan_path, context.temp_allocator)
	testing.expect(t, e == nil && len(data) == 1 && data[0] == 1)

	prep.plan = plan
	when ODIN_OS == .Windows {
		if !testing.expect(t, os.rename(image_path, child(dir.path, "old-image")) == nil) do return
	} else {
		// The creator has closed its file descriptor. Its pin keeps the inode alive.
		if !testing.expect(t, os.remove(image_path) == nil) do return
	}
	if !testing.expect(t, create_file(&dir, "0-next", {3}) == nil) do return
	replacement, open_err := regular(&dir, "0-next")
	if !testing.expect(t, open_err == nil) do return
	replaced_id, id_err := file_identity(replacement)
	os.close(replacement)
	testing.expect(t, id_err == nil && replaced_id != image)
	if !testing.expect(t, discard_preparation(&vault, &dir, id) == .Invalid_File) do return
	testing.expect(t, !os.exists(plan_path))
	data, e = os.read_entire_file(image_path, context.temp_allocator)
	testing.expect(t, e == nil && len(data) == 1 && data[0] == 3)

	when ODIN_OS != .Windows {
		fallback := Preparation {
			images = make([dynamic]Prepared_File, context.temp_allocator),
		}
		defer release_preparation_pins(&fallback)
		dir.preparation = &fallback
		_, first_err := save_image(&dir, "1-next", {4}, nil, 1)
		if !testing.expect(t, first_err == nil && len(fallback.pins) == 1) do return
		// A directory cannot provide a file-backed mapping.
		if !testing.expect(t, !pin_prepared_inode(dir.file, &fallback)) do return
		testing.expect(t, len(fallback.pins) == 0 && fallback.images[0].identity == {})
		_, second_err := save_image(&dir, "2-next", {5}, nil, 1)
		if !testing.expect(t, second_err == nil && len(fallback.images) == 2) do return
		testing.expect(t, len(fallback.pins) == 0 && fallback.images[1].identity == {})
		if !testing.expect(t, create_file(&dir, "plan", {6}, prepared_plan = &fallback) == nil) do return
		if !testing.expect(t, fallback.plan.inode != 0 && len(fallback.pins) == 1) do return
		testing.expect(t, discard_preparation(&vault, &dir, id) == .Invalid_File)
		testing.expect(
			t,
			!os.exists(plan_path) &&
			os.exists(child(dir.path, "1-next")) &&
			os.exists(child(dir.path, "2-next")),
		)
	}
}

@(test)
preparation_cleanup_stops_at_first_published_intent :: proc(t: ^testing.T) {
	tmp, err := os.mkdir_temp("", "kadai-preparation-", context.temp_allocator)
	if !testing.expect(t, err == nil) do return
	defer os.remove_all(tmp)
	root, _ := physical(tmp, .Directory)
	w, lock_err := begin_writer()
	if !testing.expect(t, lock_err == nil) do return
	defer end_writer(&w)
	if !testing.expect(t, lock_collection(&w, root) == nil) do return
	state, open_err := open_dir(child(root, ".kadai"))
	if !testing.expect(t, open_err == nil) do return
	defer close_dir(&state)
	changes := []Change{{kind = .Create, path = "A.md", data = {42}}}

	// The pre-intent callback can already have persisted an ID reservation.
	fail_after_recording :: proc(data: rawptr) -> string {
		if e := create_file((^Directory)(data), "reservation", {1}); e != nil do return os.error_string(e)
		return "recording stopped"
	}
	id, issue := commit(&w, changes, before_intent = fail_after_recording, data = &state)
	archive := child(state.path, "recovery")
	testing.expect(t, strings.contains(issue, "recording stopped"), issue)
	testing.expect(
		t,
		os.exists(child(state.path, "reservation")) && !os.exists(child(archive, id)),
	)
	testing.expect(t, !os.exists(child(root, "A.md")))

	// An unexpected entry must survive cleanup, and both failures must reach the caller.
	leave_unknown_file :: proc(data: rawptr) -> string {
		vault := (^string)(data)^
		dirs, e := os.read_directory_by_path(vault, 1, context.temp_allocator)
		if e != nil || len(dirs) != 1 do return "missing preparation"
		if err := os.write_entire_file(child(child(vault, dirs[0].name), "keep"), "user data"); err != nil do return os.error_string(err)
		return "recording stopped"
	}
	id, issue = commit(&w, changes, before_intent = leave_unknown_file, data = &archive)
	testing.expect(
		t,
		strings.contains(issue, "recording stopped") &&
		strings.contains(issue, "Preparation cleanup failed"),
		issue,
	)
	retained, read_err := os.read_entire_file(
		child(child(archive, id), "keep"),
		context.temp_allocator,
	)
	testing.expect(t, read_err == nil && string(retained) == "user data")

	// Make only the second no-replace publication fail. The first pointer
	// must still lead to a complete journal after commit returns.
	block_second_pointer :: proc(data: rawptr) -> string {
		return os.error_string(create_file((^Directory)(data), "pending", {1}))
	}
	id, issue = commit(&w, changes, before_intent = block_second_pointer, data = &state)
	if !testing.expect(t, strings.contains(issue, "recording operation intent"), issue) do return
	testing.expect(t, os.exists(child(state.path, "intent")) && !os.exists(child(root, "A.md")))
	if !testing.expect(t, remove_entry(&state, "pending") == nil) do return
	recovered, recovery_issue := recover(&w, .Resume)
	testing.expect(
		t,
		recovery_issue == "" && recovered == id && os.exists(child(root, "A.md")),
		recovery_issue,
	)
}

// Run the same test executable so the contender has independent native locks.
// The interrupted writer exits without running cleanup after the first rename.
@(test)
overlapping_writers_and_interrupted_transaction :: proc(t: ^testing.T) {
	mode, child_mode := os.lookup_env("KADAI_TEST_WRITER_CHILD", context.temp_allocator)
	if child_mode {
		if mode == "contend" {
			_, err := begin_writer(0)
			if err == os.General_Error.Timeout do os.exit(72)
			os.exit(1)
		}
		root, _ := os.getwd(context.temp_allocator)
		root, _ = physical(root, .Directory)
		w, err := begin_writer()
		if err != nil || lock_collection(&w, root) != nil do os.exit(1)
		id := random_name("")
		dir, open_err := op_directory(root, id, true)
		if open_err != nil do os.exit(2)
		steps: [2]Step
		for path, i in ([2]string{"nested/A.md", "B.md"}) {
			steps[i], err = prepare_step(
				root,
				&dir,
				i,
				{kind = .Create, path = path, data = {42}},
				64,
			)
			if err != nil do os.exit(3)
		}
		plan, _ := manifest(steps[:], 4096)
		state, _ := open_dir(child(root, ".kadai"))
		if create_file(&dir, "plan", transmute([]byte)plan) != nil ||
		   arm(&state, pointer(id, plan)) != nil ||
		   apply_step(root, &dir, 0, steps[0], false, 64) != nil {os.exit(4)}
		os.exit(73)
	}

	root_tmp, tmp_err := os.mkdir_temp("", "kadai-restart-", context.temp_allocator)
	if !testing.expect(t, tmp_err == nil) do return
	defer os.remove_all(root_tmp)
	root, _ := physical(root_tmp, .Directory)
	run_child :: proc(root, mode: string) -> int {
		exe, e := os.get_executable_path(context.temp_allocator)
		if e != nil do return -1
		env, _ := os.environ(context.temp_allocator)
		vars := make([dynamic]string, context.temp_allocator)
		append(&vars, ..env)
		append(&vars, fmt.tprintf("KADAI_TEST_WRITER_CHILD=%s", mode))
		result, _, _, err := os.process_exec(
			{
				working_dir = root,
				env = vars[:],
				command = {exe, "-tests:storage.overlapping_writers_and_interrupted_transaction"},
			},
			context.temp_allocator,
		)
		return int(result.exit_code) if err == nil else -1
	}
	{
		w, e := begin_writer()
		if !testing.expect(t, e == nil) do return
		defer end_writer(&w)
		if !testing.expect(t, lock_collection(&w, root) == nil) do return
		testing.expect_value(t, run_child(root, "contend"), 72)
	}

	if !testing.expect_value(t, run_child(root, "interrupt"), 73) do return
	w, e := begin_writer()
	if !testing.expect(t, e == nil) do return
	defer end_writer(&w)
	sub := child(root, "nested")
	testing.expect(t, strings.contains(check_pending(&w, sub, 200), "pending operation"))
	testing.expect(t, !os.exists(child(root, "B.md")))
	if !testing.expect(t, lock_collection(&w, root) == nil) do return
	id, issue := recover(&w, .Resume)
	if !testing.expect_value(t, issue, "") do return
	testing.expect(t, os.exists(child(root, "B.md")))
	testing.expect_value(t, check_pending(&w, sub, 200), "")
	second := child(root, "B.md")
	testing.expect(t, os.write_entire_file(second, "later") == nil)
	_, issue = recover(&w, .Rollback, id)
	testing.expect(t, issue != "")
	testing.expect_value(t, check_pending(&w, root, 200), "")
	testing.expect(t, os.exists(child(root, "nested/A.md")))
	end_writer(&w)

	// A separate interrupted operation exercises rollback directly after exit,
	// including refusal to erase an external edit made after the interruption.
	rollback_root := child(root, "rollback")
	if !testing.expect(t, os.mkdir(rollback_root) == nil) do return
	if !testing.expect_value(t, run_child(rollback_root, "interrupt"), 73) do return
	w, e = begin_writer()
	if !testing.expect(t, e == nil) do return
	if !testing.expect(t, lock_collection(&w, rollback_root) == nil) do return
	first := child(rollback_root, "nested/A.md")
	testing.expect(t, os.write_entire_file(first, "later") == nil)
	_, issue = recover(&w, .Rollback)
	testing.expect(t, issue != "")
	later, read_err := os.read_entire_file(first, context.temp_allocator)
	testing.expect(t, read_err == nil && string(later) == "later")
	testing.expect(t, os.write_entire_file(first, []byte{42}) == nil)
	_, issue = recover(&w, .Rollback)
	testing.expect_value(t, issue, "")
	testing.expect(t, !os.exists(first) && !os.exists(child(rollback_root, "B.md")))
	testing.expect_value(t, check_pending(&w, rollback_root, 200), "")
}
