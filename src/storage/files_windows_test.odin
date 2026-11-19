#+test
#+build windows
package storage

import "core:fmt"
import "core:os"
import "core:strings"
import w "core:sys/windows"
import "core:testing"

@(test)
windows_pinned_directory_blocks_redirection :: proc(t: ^testing.T) {
	tmp, err := os.mkdir_temp("", "kadai-pin-", context.temp_allocator)
	if !testing.expect(t, err == nil) do return
	defer os.remove_all(tmp)
	root, _ := physical(tmp, .Directory)
	d, e := open_dir(child(root, "pinned"), create = true)
	if !testing.expect(t, e == nil) do return
	defer close_dir(&d)
	testing.expect(t, !w.MoveFileExW(wide(d.path), wide(child(root, "moved")), 0))
	testing.expect_value(t, w.GetLastError(), w.ERROR_SHARING_VIOLATION)
	h := w.CreateFileW(
		wide(d.path),
		w.GENERIC_WRITE,
		w.FILE_SHARE_READ | w.FILE_SHARE_WRITE | w.FILE_SHARE_DELETE,
		nil,
		w.OPEN_EXISTING,
		w.FILE_FLAG_BACKUP_SEMANTICS | w.FILE_FLAG_OPEN_REPARSE_POINT,
		nil,
	)
	if !testing.expect(t, h != w.INVALID_HANDLE_VALUE) do return
	defer w.CloseHandle(h)
	data: struct {
		tag                                                                 : u32,
		length, reserved, sub_offset, sub_length, print_offset, print_length: u16,
		path                                                                : [1024]u16,
	}
	data.tag = w.IO_REPARSE_TAG_MOUNT_POINT
	target := wide(
		fmt.tprintf("\\??\\%s", strings.replace_all(root, "/", "\\", context.temp_allocator)),
	)
	units := len(target)
	copy(data.path[:], ([^]u16)(target)[:units])
	data.sub_length = u16(units * 2)
	data.print_offset = u16((units + 1) * 2)
	data.length = u16(8 + (units + 2) * 2)
	n: u32
	if !testing.expect(t, bool(w.DeviceIoControl(h, 0x900a4, &data, u32(data.length) + 8, nil, 0, &n, nil))) do return
	// Windows permits this conversion despite the live directory handle.
	// Kadai must refuse further use rather than write through the new junction.
	testing.expect(t, create_file(&d, "escaped.md", {1}) != nil)
	sub, refused := open_dir(child(d.path, "escaped"), create = true)
	if refused == nil do close_dir(&sub)
	testing.expect(t, refused != nil && !os.exists(child(root, "escaped")))
	source, source_err := open_dir(root)
	if !testing.expect(t, source_err == nil) do return
	defer close_dir(&source)
	if !testing.expect(t, create_file(&source, "source.md", {2}) == nil) do return
	testing.expect(t, publish(&source, "source.md", &d, "escaped.md", false) != nil)
	testing.expect(t, !os.exists(child(root, "escaped.md")) && os.exists(child(root, "source.md")))
}
