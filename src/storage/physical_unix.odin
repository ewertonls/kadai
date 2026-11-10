#+build darwin, linux
package storage

import "core:os"
import "core:strings"
import "core:sys/posix"

// realpath does not open a FIFO or device encountered through an explicit symlink.
physical :: proc(path: string, kind: os.File_Type) -> (result: string, err: os.Error) {
	cpath := strings.clone_to_cstring(path, context.temp_allocator) or_return
	resolved := posix.realpath(cpath, nil)
	if resolved == nil do return "", .Invalid_Path
	defer posix.free(resolved)
	info := os.lstat(string(resolved), context.temp_allocator) or_return
	if info.type != kind do return "", .Invalid_File
	return info.fullpath, nil
}
