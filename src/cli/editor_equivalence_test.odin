#+test
package cli

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// An editor's atomic save replaces the inode. The next CLI read and patch
// must discover that revision, including its new ID and opaque Markdown body.
@(test)
manual_save_between_commands :: proc(t: ^testing.T) {
	tmp, file_err := os.mkdir_temp("", "kadai-equivalence-", context.temp_allocator)
	if !testing.expect(t, file_err == nil) do return
	defer os.remove_all(tmp)
	invoke :: proc(t: ^testing.T, args: []string, expect_code := 0) -> string {
		out, err: strings.Builder
		defer strings.builder_destroy(&out)
		defer strings.builder_destroy(&err)
		code := run(args, strings.to_writer(&out), strings.to_writer(&err))
		testing.expect(t, code == expect_code, strings.to_string(err))
		if code == 0 do return strings.clone(strings.to_string(out), context.temp_allocator)
		return strings.clone(strings.to_string(err), context.temp_allocator)
	}
	testing.expect_value(t, invoke(t, {"add", "Initial", "--project", tmp}), "0001\n")
	path := fmt.tprintf("%s/tasks/0001.md", tmp)
	save := fmt.tprintf("%s/tasks/editor-save.tmp", tmp)
	manual := "\uFEFF---\r\nkadai: task\r\nid: HAND\r\ntitle: 'Editor title' # keep\r\nstatus: todo\r\ncustom: {x: 007}\r\n---\r\n## Body\r\nplain text"
	testing.expect(t, os.write_entire_file(save, manual) == nil)
	testing.expect(t, os.rename(save, path) == nil)
	testing.expect(t, strings.contains(invoke(t, {"show", "0001", "--project", tmp}, 1), "unknown task ID"))
	testing.expect_value(t, invoke(t, {"list", "--project", tmp}), "HAND\ttodo\tEditor title\t0001.md\n")
	testing.expect_value(t, invoke(t, {"show", "hand", "--project", tmp}), fmt.tprintf("0001.md\n%s", manual))
	_ = invoke(t, {"status", "HAND", "in_progress", "--project", tmp})
	current, e := os.read_entire_file(path, context.temp_allocator)
	expected, _ := strings.replace_all(manual, "status: todo", "status: in_progress", context.temp_allocator)
	testing.expect(t, e == nil && string(current) == expected)
}
