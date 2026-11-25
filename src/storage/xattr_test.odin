#+test
#+build darwin, linux
package storage

import "core:os"
import p "core:sys/posix"
import "core:testing"

when ODIN_OS == .Darwin {
	foreign import lib "system:System"
	foreign lib {fsetxattr :: proc(fd: p.FD, name: cstring, value: rawptr, size: uint, pos: u32, options: i32) -> i32 ---}
}

@(test)
project_files_inherit_permissions_and_replace_atomically :: proc(t: ^testing.T) {
	tmp, e := os.mkdir_temp("", "kadai-project-file-", context.temp_allocator)
	if !testing.expect(t, e == nil) do return
	defer os.remove_all(tmp)
	root, path_err := physical(tmp, .Directory)
	if !testing.expect(t, path_err == nil) do return
	dir, open_err := open_dir(root)
	if !testing.expect(t, open_err == nil) do return
	defer close_dir(&dir)
	reference := child(root, "ordinary")
	if !testing.expect(t, os.write_entire_file(reference, "", os.Permissions_Default_File) == nil) do return
	ordinary, stat_err := os.stat(reference, context.temp_allocator)
	if !testing.expect(t, stat_err == nil) do return
	if !testing.expect(t, write_project_file(&dir, ".gitignore", "", {1}, 32) == nil) do return
	old, read_err := regular(&dir, ".gitignore")
	if !testing.expect(t, read_err == nil) do return
	defer os.close(old)
	info, info_err := file_info(old)
	if !testing.expect(t, info_err == nil && info.mode == ordinary.mode) do return
	set_test_security_metadata(t, old)
	before, before_err := project_metadata(old)
	if !testing.expect(t, before_err == nil) do return
	version := file_version(info, {1})
	err := write_project_file(&dir, ".gitignore", version, {1, 2}, 32)
	if !testing.expect(t, err == nil, os.error_string(err)) do return
	// Readers that already opened the file still see the complete old version.
	original, old_err := read_bounded(old, 32)
	testing.expect(t, old_err == nil && len(original) == 1 && original[0] == 1)
	next, next_err := regular(&dir, ".gitignore")
	if !testing.expect(t, next_err == nil) do return
	defer os.close(next)
	updated, update_err := read_bounded(next, 32)
	testing.expect(t, update_err == nil && len(updated) == 2 && updated[1] == 2)
	after, after_err := project_metadata(next)
	testing.expect(t, after_err == nil && after == before)
}

@(private)
set_test_security_metadata :: proc(t: ^testing.T, f: ^os.File) {
	value: byte = 42
	fd := p.FD(os.fd(f))
	when ODIN_OS == .Darwin {result := fsetxattr(fd, "user.kadai.test", &value, 1, 0, 0)} else {result := fsetxattr(fd, "user.kadai.test", &value, 1, 0)}
	testing.expect_value(t, result, 0)
	when ODIN_OS == .Darwin {
		// An actual extended ACL exercises fcopyfile independently of xattrs.
		state, _, stderr, e := os.process_exec(
			{command = {"/bin/chmod", "+a", "everyone allow readattr", os.name(f)}},
			context.temp_allocator,
		)
		testing.expect(t, e == nil && state.exit_code == 0, string(stderr))
	} else {
		// Linux UAPI posix_acl_xattr_header followed by five little-endian entries.
		Entry :: struct #packed {
			tag, perm: u16le,
			id       : u32le,
		}
		acl := struct #packed {
			version: u32le,
			entries: [5]Entry,
		} {
			2,
			{
				{1, 7, 0xffffffff},
				{2, 4, 12345},
				{4, 4, 0xffffffff},
				{16, 4, 0xffffffff},
				{32, 0, 0xffffffff},
			},
		}
		testing.expect_value(t, fsetxattr(fd, "system.posix_acl_access", &acl, size_of(acl), 0), 0)
	}
}
