#+test
package storage

import "core:os"
import "core:testing"

@(test)
atomic_replace_preserves_metadata_and_verified_rollback :: proc(t: ^testing.T) {
	tmp, err := os.mkdir_temp("", "kadai-atomic-", context.temp_allocator)
	if !testing.expect(t, err == nil) do return
	defer os.remove_all(tmp)
	root, _ := physical(tmp, .Directory)
	d, e := open_dir(root)
	if !testing.expect(t, e == nil) do return
	defer close_dir(&d)
	testing.expect(t, create_file(&d, "T.md", {1, 2}) == nil)
	path := child(root, "T.md")
	when ODIN_OS != .Windows {
		testing.expect(t, os.chmod(path, {.Read_User, .Write_User, .Read_Group, .Execute_User}) == nil)
	} else {
		// An editor's atomic save gives the task its ordinary inherited DACL.
		manual := child(root, "editor-save.md")
		testing.expect(t, os.write_entire_file(manual, []byte{1, 2}) == nil)
		testing.expect(t, os.rename(manual, path) == nil)
	}
	images, private_err := open_dir(child(root, "recovery"), create = true, private_leaf = true)
	if !testing.expect(t, private_err == nil, os.error_string(private_err)) do return
	defer close_dir(&images)
	f, ferr := regular(&d, "T.md")
	if !testing.expect(t, ferr == nil) do return
	info, _ := file_info(f)
	when ODIN_OS != .Windows { set_test_security_metadata(t, f) }
	before_metadata, metadata_err := metadata(f)
	if !testing.expect(t, metadata_err == nil) { os.close(f); return }
	os.close(f)
	version := file_version(info, {1, 2})
	step, prep := prepare_step(root, &images, 0, {kind = .Replace, path = "T.md", expected = version, data = {3}}, 100)
	if !testing.expect(t, prep == nil, os.error_string(prep)) do return
	when ODIN_OS == .Windows {
		// All three images must retain the supported inherited descriptor and
		// pass the privacy gate before publication or rollback.
		for name in ([]string{"0-original", "0-restore", "0-next"}) {
			image, image_err := regular(&images, name)
			if !testing.expect(t, image_err == nil) do return
			image_metadata, image_metadata_err := metadata(image)
			os.close(image)
			testing.expect(t, image_metadata_err == nil && image_metadata == before_metadata)
		}
	}
	testing.expect(t, apply_step(root, &images, 0, step, false, 100) == nil)
	current, _ := entry_state(&d, "T.md", 100)
	testing.expect_value(t, current, step.after)
	updated, updated_err := regular(&d, "T.md")
	if !testing.expect(t, updated_err == nil) do return
	after_metadata, after_err := metadata(updated)
	os.close(updated)
	testing.expect(t, after_err == nil && after_metadata == before_metadata)
	backup_path := child(images.path, "0-original")
	backup, _ := os.read_entire_file(backup_path, context.temp_allocator)
	testing.expect(t, len(backup) == 2 && backup[0] == 1)
	testing.expect(t, os.write_entire_file(path, "later") == nil)
	testing.expect(t, apply_step(root, &images, 0, step, true, 100) != nil)
	data, _ := os.read_entire_file(path, context.temp_allocator)
	testing.expect_value(t, string(data), "later")
	// Restore the expected post-image in the same inode and exercise rollback.
	testing.expect(t, os.write_entire_file(path, []byte{3}) == nil)
	testing.expect(t, apply_step(root, &images, 0, step, true, 100) == nil)
	testing.expect(t, apply_step(root, &images, 0, step, true, 100) == nil)
	data, _ = os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, len(data) == 2 && data[0] == 1 && data[1] == 2)
	restored, restored_err := entry_state(&d, "T.md", 100)
	testing.expect(t, restored_err == nil && payload_signature(restored) == payload_signature(step.before))
}
