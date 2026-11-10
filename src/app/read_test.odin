#+test
package app

import "core:os"
import "core:strings"
import "core:testing"
import "kadai:storage"

@(test)
queries_use_complete_current_files_only :: proc(t: ^testing.T) {
	tmp, err := os.mkdir_temp("", "kadai-read-", context.temp_allocator)
	if !testing.expect(t, err == nil) do return
	defer os.remove_all(tmp)
	opts := Project_Options{tasks_root = "."}
	doc := "---\nkadai: task\nid: Mixed\ntitle: Example\nstatus: todo\n---\nbody"
	testing.expect(t, os.write_entire_file(storage.child(tmp, "z.md"), doc) == nil)
	a, _ := strings.replace_all(doc, "Mixed", "Two", context.temp_allocator)
	testing.expect(t, os.write_entire_file(storage.child(tmp, "a.md"), a) == nil)
	items, issue := list_tasks(tmp, opts)
	if !testing.expect(t, issue == "" && len(items) == 2) do return
	testing.expect_value(t, items[0].path, "a.md")
	result, problem := get_task(tmp, opts, "mixed")
	if !testing.expect_value(t, problem, "") do return
	testing.expect_value(t, result.source, doc)
	z, _ := strings.replace_all(doc, "todo", "unknown", context.temp_allocator)
	testing.expect(t, os.write_entire_file(storage.child(tmp, "z.md"), z) == nil)
	result, problem = get_task(tmp, opts, "mixed")
	testing.expect(t, problem == "" && result.source == "" && len(result.item.diagnostics) > 0)
	testing.expect(t, !os.exists(storage.child(tmp, ".kadai")))
}
