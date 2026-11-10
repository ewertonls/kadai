// Physical selections and bounded reads. Returned paths use command scratch storage.
package storage

import "core:fmt"
import "core:os"
import "core:strings"

slash :: proc(s: string) -> string {
	when ODIN_OS == .Windows {
		return strings.replace_all(s, "\\", "/", context.temp_allocator)
	}
	return s
}

child :: proc(dir, name: string) -> string {
	return fmt.tprintf("%s/%s", strings.trim_suffix(dir, "/"), name)
}

within :: proc(root, path: string) -> bool {
	return path == root || strings.has_prefix(path, child(root, ""))
}

valid_path_text :: proc(s: string) -> bool {
	return s != "" && !strings.contains_rune(s, 0)
}

// Resolve existing components before interpreting "..". A broken symlink is
// an error even when a missing final directory would otherwise be permitted.
directory :: proc(base, selection: string, missing_ok: bool) -> (path: string, linked: bool, err: os.Error) {
	if !valid_path_text(selection) do return "", false, .Invalid_Path
	input := slash(selection)
	path = base
	if os.is_absolute_path(input) {
		when ODIN_OS == .Windows {
			if len(input) < 3 || input[1:3] != ":/" do return "", false, .Invalid_Path
			path, input = input[:3], input[3:]
		} else {
			path = "/"
		}
	}
	for part in strings.split_iterator(&input, "/") {
		if part == "" || part == "." do continue
		if part == ".." {
			if parent := slash(os.dir(path)); parent != "" { path = parent }
			continue
		}
		path = child(path, part)
		info, e := os.lstat(path, context.temp_allocator)
		if e == os.General_Error.Not_Exist && missing_ok do continue
		if e != nil do return "", linked, e
		if info.type == .Symlink {
			linked = true
		} else if info.type != .Directory {
			return "", linked, .Invalid_Dir
		}
		path = physical(path, .Directory) or_return
	}
	return
}

read_bounded :: proc(f: ^os.File, limit: int) -> (data: []byte, err: os.Error) {
	info := os.fstat(f, context.temp_allocator) or_return
	if info.type != .Regular || info.size < 0 do return nil, .Invalid_File
	if info.size > i64(limit) do return nil, .Short_Buffer
	data = make([]byte, int(info.size), context.temp_allocator) or_return
	if len(data) > 0 {
		_ = os.read_at_least(f, data, len(data)) or_return
	}
	probe: [1]byte
	n, end := os.read(f, probe[:])
	if n != 0 do return nil, .Invalid_File
	if end != nil && end != .EOF do return nil, end
	return
}
