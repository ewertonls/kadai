#+test
package app

import "core:fmt"
import "core:os"
import "core:testing"
import "kadai:storage"

@(test)
creation_observes_manual_ids_and_retains_reservations :: proc(t: ^testing.T) {
	tmp, e := os.mkdir_temp("", "kadai-create-", context.temp_allocator)
	if !testing.expect(t, e == nil) do return
	defer os.remove_all(tmp)
	root := storage.child(tmp, "tasks")
	testing.expect(t, os.mkdir(root) == nil)
	path := storage.child(root, "manual.md")
	testing.expect(
		t,
		os.write_entire_file(
			path,
			"---\nkadai: task\nid: kad-99999999999999999999\nstatus: todo\n---\n",
		) ==
		nil,
	)
	opts := Project_Options {
		id_prefix = "KAD",
	}
	occupied := storage.child(root, "KAD-100000000000000000000.md")
	testing.expect(t, os.write_entire_file(occupied, "ordinary Markdown") == nil)
	id, issue := create_task(tmp, opts, {title = "# title: \"quoted\"", body = "---\r\nbody"})
	if !testing.expect_value(t, issue, "") do return
	testing.expect_value(t, id, "KAD-100000000000000000001")
	testing.expect(t, os.remove(path) == nil)
	testing.expect(t, os.remove(storage.child(root, fmt.tprintf("%s.md", id))) == nil)
	id, issue = create_task(tmp, opts, {title = "Next"})
	testing.expect_value(t, issue, "")
	testing.expect_value(t, id, "KAD-100000000000000000002")
	key := "kad-99999999999999999999"
	hash := storage.digest(transmute([]byte)key)
	marker := fmt.tprintf("%s/.kadai/used-ids/v1/%s/%s.id", root, hash[:2], hash)
	content, _ := os.read_entire_file(marker, context.temp_allocator)
	testing.expect_value(t, string(content), fmt.tprintf("kadai-used-id-v1\n%s\n", key))
	testing.expect(t, os.write_entire_file(marker, "broken") == nil)
	_, issue = create_task(tmp, opts, {title = "Refused"})
	testing.expect(t, issue != "")
	testing.expect(t, !os.exists(storage.child(root, "KAD-100000000000000000003.md")))
	testing.expect(t, !os.exists(storage.child(tmp, ".kadai.yaml")))
}

@(test)
reject_unknown_identity_before_reservation :: proc(t: ^testing.T) {
	tmp, e := os.mkdir_temp("", "kadai-unknown-id-", context.temp_allocator)
	if !testing.expect(t, e == nil) do return
	defer os.remove_all(tmp)
	root := storage.child(tmp, "tasks")
	testing.expect(t, os.mkdir(root) == nil)
	testing.expect(
		t,
		os.write_entire_file(
			storage.child(root, "bad.md"),
			"---\nkadai: task\nid: bad/id\n---\n",
		) ==
		nil,
	)
	_, issue := create_task(tmp, {}, {title = "Denied"})
	testing.expect(t, issue != "")
	testing.expect(t, !os.exists(storage.child(root, ".kadai/used-ids")))
}
