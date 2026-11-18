#+test
#+build darwin, linux
package app

import "core:fmt"
import "core:os"
import "core:testing"
import "kadai:storage"

@(test)
editor_receives_literal_path_and_propagates_exit :: proc(t: ^testing.T) {
	tmp, e := os.mkdir_temp("", "kadai-editor-", context.temp_allocator)
	if !testing.expect(t, e == nil) do return
	defer os.remove_all(tmp)
	source := "---\nkadai: task\nid: Editor\ntitle: Example\nstatus: todo\n---\n"
	path := storage.child(tmp, "a $(touch injected).md")
	exe := storage.child(tmp, "editor helper")
	testing.expect(t, os.write_entire_file(path, source) == nil)
	testing.expect(t, os.write_entire_file(exe, "#!/bin/sh\n[ \"$#\" -eq 2 ] && [ \"$1\" = 'literal arg' ] || exit 4\nprintf 'manual' >> \"$2\"\n") == nil)
	testing.expect(t, os.chmod(exe, {.Read_User, .Write_User, .Execute_User}) == nil)
	opts := Project_Options{tasks_root = "."}
	args, problem := editor_arguments(fmt.tprintf("%q 'literal arg'", exe))
	if !testing.expect_value(t, problem, "") do return
	issue := edit_task(tmp, opts, "editor", args)
	if !testing.expect_value(t, issue, "") do return
	data, _ := os.read_entire_file(path, context.temp_allocator)
	testing.expect_value(t, string(data), fmt.tprintf("%smanual", source))
	testing.expect(t, !os.exists(storage.child(tmp, "injected")))
	testing.expect(t, edit_task(tmp, opts, "editor", {exe, "wrong"}) != "")
}
