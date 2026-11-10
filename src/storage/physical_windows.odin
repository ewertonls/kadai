package storage

import "core:os"

physical :: proc(path: string, kind: os.File_Type) -> (result: string, err: os.Error) {
	f := os.open(path) or_return
	defer os.close(f)
	info := file_info(f) or_return
	if info.type != kind do return "", .Invalid_File
	return slash(info.fullpath), nil
}
