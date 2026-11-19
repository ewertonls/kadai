package storage

import "core:os"

// Use the same volume/file ID representation for enumeration and open handles.
file_info :: proc(f: ^os.File) -> (info: os.File_Info, err: os.Error) {
	info = os.fstat(f, context.temp_allocator) or_return
	when ODIN_OS == .Windows {windows_file_id(f, &info) or_return}
	return
}
