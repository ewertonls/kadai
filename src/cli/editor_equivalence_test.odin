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
	testing.expect_value(t, invoke_cli(t, {"add", "Initial", "--project", tmp}).stdout, "0001\n")
	path := fmt.tprintf("%s/tasks/0001.md", tmp)
	save := fmt.tprintf("%s/tasks/editor-save.tmp", tmp)
	manual := "\uFEFF---\r\nkadai: task\r\nid: HAND\r\ntitle: 'Editor title' # keep\r\nstatus: todo\r\ncustom: {x: 007}\r\n---\r\n## Body\r\nplain text"
	testing.expect(t, os.write_entire_file(save, manual) == nil)
	testing.expect(t, os.rename(save, path) == nil)
	testing.expect(t, strings.contains(invoke_cli(t, {"show", "0001", "--project", tmp}, 3).stderr, "unknown task ID"))
	row := invoke_cli(t, {"list", "--project", tmp}).stdout
	for value in ([]string{"HAND", "[todo]", "Editor title", "0001.md"}) do testing.expect(t, strings.contains(row, value), row)
	testing.expect_value(t, invoke_cli(t, {"show", "hand", "--project", tmp}).stdout, fmt.tprintf("0001.md\n%s", manual))
	_ = invoke_cli(t, {"status", "HAND", "in_progress", "--project", tmp})
	testing.expect_value(t, invoke_cli(t, {"list", "--project", tmp, "--status", "todo"}).stdout, "")
	current, e := os.read_entire_file(path, context.temp_allocator)
	expected, _ := strings.replace_all(manual, "status: todo", "status: in_progress", context.temp_allocator)
	testing.expect(t, e == nil && string(current) == expected)
}
