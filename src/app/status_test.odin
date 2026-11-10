#+test
package app

import "core:fmt"
import "core:os"
import "core:testing"
import "kadai:storage"

@(test)
completion_checks_direct_prerequisites_and_own_cycles :: proc(t: ^testing.T) {
	tmp, e := os.mkdir_temp("", "kadai-status-", context.temp_allocator)
	if !testing.expect(t, e == nil) do return
	defer os.remove_all(tmp)
	testing.expect(t, os.write_entire_file(storage.child(tmp, ".kadai.yaml"), "tasks: {root: .}\nstatuses: {shipped: done}") == nil)
	write :: proc(tmp, id, status, deps: string) -> bool {
		doc := fmt.tprintf("---\nkadai: task\nid: %s\ntitle: Example\nstatus: %s\ndepends_on: [%s]\n---\n", id, status, deps)
		return os.write_entire_file(storage.child(tmp, fmt.tprintf("%s.md", id)), doc) == nil
	}
	testing.expect(t, write(tmp, "A", "todo", "b"))
	testing.expect(t, write(tmp, "B", "shipped", "C"))
	testing.expect(t, write(tmp, "C", "canceled", ""))
	_, issue := set_status(tmp, {}, "A", "shipped")
	if !testing.expect_value(t, issue, "") do return
	_, issue = set_status(tmp, {}, "A", "in_progress")
	testing.expect_value(t, issue, "")
	testing.expect(t, write(tmp, "C", "canceled", "a"))
	_, issue = update_task(tmp, {}, {id = "A", field = "status", values = {"done"}})
	testing.expect(t, issue != "", "cycle must block generic status update")
	testing.expect(t, write(tmp, "A", "todo", "C"))
	testing.expect(t, write(tmp, "C", "canceled", ""))
	_, issue = set_status(tmp, {}, "A", "done")
	testing.expect(t, issue != "", "a canceled prerequisite does not satisfy completion")
	testing.expect(t, write(tmp, "A", "todo", "C, Missing"))
	_, issue = set_status(tmp, {}, "A", "done")
	testing.expect(t, issue != "")
	_, issue = set_status(tmp, {}, "A", "shipped", true)
	testing.expect_value(t, issue, "")
	result, read_err := get_task(tmp, {}, "A")
	if !testing.expect_value(t, read_err, "") do return
	testing.expect_value(t, result.item.fields.status, "shipped")
	testing.expect_value(t, len(result.item.fields.depends_on), 2)
}
