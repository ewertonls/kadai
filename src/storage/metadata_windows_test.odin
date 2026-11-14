#+test
#+build windows
package storage

import "core:os"
import "core:fmt"
import "core:testing"
import w "core:sys/windows"

foreign import test_advapi "system:advapi32.lib"
foreign test_advapi {
	SetFileSecurityW :: proc "system"(path: w.LPCWSTR, flags: u32, sd: rawptr) -> w.BOOL ---
}

@(private)
test_file_dacl :: proc(t: ^testing.T, path, sddl: string) -> bool {
	sd: rawptr
	if !testing.expect(t, bool(ConvertStringSecurityDescriptorToSecurityDescriptorW(wide(sddl), 1, &sd, nil))) do return false
	defer w.LocalFree(sd)
	return testing.expect(t, bool(SetFileSecurityW(wide(path), w.DACL_SECURITY_INFORMATION | 0x80000000 /* PROTECTED_DACL_SECURITY_INFORMATION */, sd)))
}

@(test)
windows_unsupported_metadata_is_not_discarded :: proc(t: ^testing.T) {
	tmp, err := os.mkdir_temp("", "kadai-metadata-", context.temp_allocator)
	if !testing.expect(t, err == nil) do return
	defer os.remove_all(tmp)
	root, _ := physical(tmp, .Directory)
	d, e := open_dir(root)
	if !testing.expect(t, e == nil) do return
	defer close_dir(&d)
	images, private_err := open_dir(child(root, "recovery"), create = true, private_leaf = true)
	if !testing.expect(t, private_err == nil) do return
	defer close_dir(&images)
	for name, i in ([]string{"stream.md", "hidden.md", "everyone.md", "null-dacl.md"}) {
		if !testing.expect(t, create_file(&d, name, {1, 2}) == nil) do return
		path := child(root, name)
		stream_path := fmt.tprintf("%s:custom", path)
		if i == 0 {
			if !testing.expect(t, os.write_entire_file(stream_path, "keep") == nil) do return
		} else if i == 1 {
			if !testing.expect(t, bool(w.SetFileAttributesW(wide(path), w.FILE_ATTRIBUTE_ARCHIVE | w.FILE_ATTRIBUTE_HIDDEN))) do return
		} else {
			sddl := "D:P(A;;FA;;;OW)(A;;FR;;;WD)" if i == 2 else "D:NO_ACCESS_CONTROL"
			if !test_file_dacl(t, path, sddl) do return
		}
		f, open_err := regular(&d, name)
		if !testing.expect(t, open_err == nil) do return
		info, info_err := file_info(f)
		before_acl, acl_err := security_text(w.HANDLE(os.fd(f)), w.DACL_SECURITY_INFORMATION)
		os.close(f)
		if !testing.expect(t, info_err == nil && acl_err == nil) do return
		_, prep := prepare_step(root, &images, i, {kind = .Replace, path = name, expected = file_version(info, {1, 2}), data = {3}}, 100)
		testing.expect(t, prep == .Unsupported, os.error_string(prep))
		for suffix in ([]string{"original", "restore", "next"}) {
			_, image_err := os.lstat(child(images.path, fmt.tprintf("%d-%s", i, suffix)), context.temp_allocator)
			testing.expect(t, image_err == os.General_Error.Not_Exist)
		}
		bytes, read_err := os.read_entire_file(path, context.temp_allocator)
		testing.expect(t, read_err == nil && len(bytes) == 2 && bytes[0] == 1 && bytes[1] == 2)
		if i == 0 {
			stream, stream_err := os.read_entire_file(stream_path, context.temp_allocator)
			testing.expect(t, stream_err == nil && string(stream) == "keep")
		} else if i == 1 {
			testing.expect(t, w.GetFileAttributesW(wide(path)) & w.FILE_ATTRIBUTE_HIDDEN != 0)
		}
		after, after_open := regular(&d, name)
		if !testing.expect(t, after_open == nil) do return
		after_acl, after_err := security_text(w.HANDLE(os.fd(after)), w.DACL_SECURITY_INFORMATION)
		os.close(after)
		testing.expect(t, after_err == nil && after_acl == before_acl)
	}
}

@(test)
windows_captured_security_is_checked_before_write :: proc(t: ^testing.T) {
	tmp, err := os.mkdir_temp("", "kadai-captured-acl-", context.temp_allocator)
	if !testing.expect(t, err == nil) do return
	defer os.remove_all(tmp)
	root, _ := physical(tmp, .Directory)
	d, e := open_dir(root)
	if !testing.expect(t, e == nil) do return
	defer close_dir(&d)
	f, create_err := create_regular(&d, "image")
	if !testing.expect(t, create_err == nil) do return
	defer os.close(f)
	_, write_err := os.write(f, []byte{1, 2})
	if !testing.expect(t, write_err == nil) do return
	before, before_err := metadata(f)
	if !testing.expect(t, before_err == nil) do return
	// Inject the bytes captured after an earlier safe read, without racing a
	// thread. A post-BackupWrite check would expose the image in the meantime.
	for sddl in ([]string{
		"O:SYD:P(A;;FR;;;WD)(A;;FA;;;SY)",
		"O:SYD:NO_ACCESS_CONTROL",
		"O:SY",
		"O:WDD:P(A;;FA;;;OW)", // OWNER RIGHTS cannot make an untrusted owner safe.
		"O:SYD:P(OA;;FR;00000000-0000-0000-0000-000000000001;;SY)",
	}) {
		sd: rawptr
		n: u32
		if !testing.expect(t, bool(ConvertStringSecurityDescriptorToSecurityDescriptorW(wide(sddl), 1, &sd, &n)), sddl) do return
		defer w.LocalFree(sd)
		stream, alloc_err := security_buffer(20+int(n))
		if !testing.expect(t, alloc_err == nil) do return
		(^u32le)(&stream[0])^ = 3
		(^u64le)(&stream[8])^ = u64le(n)
		copy(stream[20:], ([^]byte)(sd)[:n])
		testing.expect(t, write_private_security(f, stream) == .Unsupported, sddl)
		after, after_err := metadata(f)
		testing.expect(t, after_err == nil && after == before, sddl)
	}
	// Conventional denies do not grant access; trusted owners and grants are
	// compatible, including inherited ACEs and OWNER RIGHTS.
	safe: rawptr
	n: u32
	if !testing.expect(t, bool(ConvertStringSecurityDescriptorToSecurityDescriptorW(wide("O:SYD:P(D;;FW;;;WD)(A;ID;FR;;;SY)(A;;FA;;;BA)(A;;FA;;;OW)"), 1, &safe, &n))) do return
	defer w.LocalFree(safe)
	testing.expect(t, private_security(([^]byte)(safe)[:n]) == nil)
	testing.expect(t, private_security(([^]byte)(safe)[:n-1]) == .Unsupported)
}

@(test)
windows_tree_snapshot_refuses_public_member :: proc(t: ^testing.T) {
	tmp, err := os.mkdir_temp("", "kadai-tree-acl-", context.temp_allocator)
	if !testing.expect(t, err == nil) do return
	defer os.remove_all(tmp)
	root, _ := physical(tmp, .Directory)
	tree_path := child(root, "tree")
	d, e := open_dir(tree_path, create = true)
	if !testing.expect(t, e == nil) do return
	defer close_dir(&d)
	if !testing.expect(t, create_file(&d, "T.md", {1, 2}) == nil) do return
	path := child(tree_path, "T.md")
	if !test_file_dacl(t, path, "D:P(A;;FA;;;OW)(A;;FR;;;WD)") do return
	images, image_err := open_dir(child(root, "recovery"), create = true, private_leaf = true)
	if !testing.expect(t, image_err == nil) do return
	defer close_dir(&images)
	_, capture_err := inspect_tree(tree_path, DEFAULT_JOURNAL_LIMITS, &images, capture = true)
	testing.expect(t, capture_err == .Unsupported, os.error_string(capture_err))
	_, missing_err := os.lstat(child(images.path, tree_image_name("T.md")), context.temp_allocator)
	testing.expect(t, missing_err == os.General_Error.Not_Exist)
	data, read_err := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, read_err == nil && len(data) == 2 && data[0] == 1 && data[1] == 2)
}
