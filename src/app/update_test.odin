#+test
package app

import "core:os"
import "core:strings"
import "core:testing"
import "kadai:storage"

@(test)
core_updates_repair_only_the_selected_field :: proc(t: ^testing.T) {
	tmp, e := os.mkdir_temp("", "kadai-update-", context.temp_allocator)
	if !testing.expect(t, e == nil) do return
	defer os.remove_all(tmp)
	opts := Project_Options {
		tasks_root = ".",
	}
	file := storage.child(tmp, "manual.md")
	orig := "---\nkadai: task\nid: MY-ID\nstatus: pending # keep\ntags: ['one', two] # labels\n---\nbody"
	testing.expect(t, os.write_entire_file(file, orig) == nil)
	_, issue := update_task(tmp, opts, {id = "my-id", field = "priority", values = {"low"}})
	testing.expect(t, issue != "")
	testing.expect(t, !os.exists(storage.child(tmp, ".kadai/used-ids")))
	for op in ([]Update{{id = "MY-ID", field = "title", values = {"Restored"}}, {id = "MY-ID", field = "status", values = {"todo"}}, {id = "MY-ID", field = "tags", values = {"two", "one", "null"}}, {id = "MY-ID", field = "due", values = {"2026-11-10"}}, {id = "MY-ID", field = "due", unset = true}}) {
		_, issue = update_task(tmp, opts, op)
		if !testing.expect_value(t, issue, "") do return
	}
	doc, _ := os.read_entire_file(file, context.temp_allocator)
	testing.expect(
		t,
		strings.contains(
			string(doc),
			"status: todo # keep\ntags: [two, 'one', 'null'] # labels\n",
		),
	)
	testing.expect(
		t,
		!strings.contains(string(doc), "due:") && strings.has_suffix(string(doc), "---\nbody"),
	)
	for field in ([]string{"title", "status", "id", "parent", "depends_on"}) {
		_, issue = update_task(tmp, opts, {id = "MY-ID", field = field, unset = true})
		testing.expect(t, issue != "", field)
	}
}
