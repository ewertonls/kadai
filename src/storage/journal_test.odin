#+test
package storage

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

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
			steps[i], err = prepare_step(root, &dir, i, {kind = .Create, path = path, data = {42}}, 64)
			if err != nil do os.exit(3)
		}
		plan, _ := manifest(steps[:], 4096)
		state, _ := open_dir(child(root, ".kadai"))
		if create_file(&dir, "plan", transmute([]byte)plan) != nil ||
		   arm(&state, pointer(id, plan)) != nil ||
		   apply_step(root, &dir, 0, steps[0], false, 64) != nil { os.exit(4) }
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
		result, _, _, err := os.process_exec({working_dir = root, env = vars[:],
			command = {exe, "-tests:storage.overlapping_writers_and_interrupted_transaction"}}, context.temp_allocator)
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
}
