#+test
#+build darwin
package storage

import "core:fmt"
import "core:os"
import "core:strings"
import p "core:sys/posix"
import "core:testing"

@(test)
metadata_v2_excludes_only_macos_provenance :: proc(t: ^testing.T) {
	f, err := os.create_temp_file("", "kadai-provenance-")
	if !testing.expect(t, err == nil) do return
	defer os.close(f)
	defer os.remove(os.name(f))
	fd := p.FD(os.fd(f))
	key        :: "user.kadai.test"
	provenance :: "com.apple.provenance"
	value: byte = 42
	if !testing.expect_value(t, fsetxattr(fd, key, &value, 1, 0, 0), 0) do return

	base := strings.builder_make(context.temp_allocator)
	if !testing.expect(t, append_metadata_attributes(&base, fd, {key}, .V2) == nil) do return
	// Supply the key even when the test runner has no OS-assigned provenance.
	// A v2 signature must not depend on whether the key exists or can be read.
	with_provenance := strings.builder_make(context.temp_allocator)
	if !testing.expect(t, append_metadata_attributes(&with_provenance, fd, {provenance, key}, .V2) == nil) do return
	testing.expect_value(t, strings.to_string(with_provenance), strings.to_string(base))
	legacy := strings.builder_make(context.temp_allocator)
	legacy_err := append_metadata_attributes(&legacy, fd, {provenance, key}, .V1)
	raw, read_err := attribute(fd, provenance)
	defer delete(raw)
	testing.expect(t, legacy_err == read_err)
	if read_err == nil do testing.expect(t, strings.contains(strings.to_string(legacy), provenance))
	for protected_key in ([2]string{"com.apple.quarantine", "com.apple.macl"}) {
		protected := strings.builder_make(context.temp_allocator)
		e := append_metadata_attributes(&protected, fd, {protected_key}, .V2)
		testing.expect(
			t,
			e != nil || strings.contains(strings.to_string(protected), protected_key),
		)
	}

	value += 1
	if !testing.expect_value(t, fsetxattr(fd, key, &value, 1, 0, 0), 0) do return
	updated := strings.builder_make(context.temp_allocator)
	if !testing.expect(t, append_metadata_attributes(&updated, fd, {key}, .V2) == nil) do return
	testing.expect(t, strings.to_string(base) != strings.to_string(updated))
}

@(test)
legacy_directory_move_resumes_and_verifies_archived_images :: proc(t: ^testing.T) {
	tmp, tmp_err := os.mkdir_temp("", "kadai-legacy-tree-", context.temp_allocator)
	if !testing.expect(t, tmp_err == nil) do return
	defer os.remove_all(tmp)
	root, err := physical(tmp, .Directory)
	if !testing.expect(t, err == nil) do return
	w, lock_err := begin_writer()
	if !testing.expect(t, lock_err == nil) do return
	defer end_writer(&w)
	if !testing.expect(t, lock_collection(&w, root) == nil) do return
	src := child(root, "from")
	if !testing.expect(t, os.mkdir(src) == nil) do return
	if !testing.expect(t, os.write_entire_file(child(src, "note.md"), "note") == nil) do return

	id := random_name("")
	op, open_err := op_directory(root, id, true)
	if !testing.expect(t, open_err == nil) do return
	defer close_dir(&op)
	limits := DEFAULT_JOURNAL_LIMITS
	tree, tree_err := inspect_tree(src, limits, &op, capture = true, version = .V1)
	if !testing.expect(t, tree_err == nil, os.error_string(tree_err)) do return
	step := Step {
		.Move_Directory,
		"from",
		"to",
		tree.version,
		tree.version,
		fmt.tprintf("%s.%s", tree.backup, tree.image_digest),
		"-",
	}
	plan, ok := manifest({step}, limits.record, .V1)
	if !testing.expect(t, ok && strings.has_prefix(plan, "kadai-transaction-v1\n")) do return
	if !testing.expect(t, create_file(&op, "plan", transmute([]byte)plan) == nil) do return
	state_dir, state_err := open_dir(child(root, ".kadai"))
	if !testing.expect(t, state_err == nil) do return
	defer close_dir(&state_dir)
	if !testing.expect(t, arm(&state_dir, pointer(id, plan)) == nil) do return

	_, issue := recover(&w, .Resume)
	if !testing.expect_value(t, issue, "") do return
	testing.expect(t, os.exists(child(root, "to/note.md")) && !os.exists(src))
	audit := inspect_recovery(root, limits)
	testing.expect_value(t, len(audit.problems), 0)
}
