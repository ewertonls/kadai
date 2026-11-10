package storage

import "core:os"

// Same-filesystem no-replace rename. A successful move retains the original
// file object, including its Markdown bytes, filesystem identity and metadata.
move_file :: proc(source, destination: string, expected: os.File_Info) -> (err: os.Error) {
	src := open_dir(slash(os.dir(source))) or_return
	defer close_dir(&src)
	f := regular(&src, os.base(source), mutation = true) or_return
	defer os.close(f)
	info := os.fstat(f, context.temp_allocator) or_return
	if expected.inode == 0 || info.inode != expected.inode || info.device != expected.device do return .Invalid_File
	dst := open_dir(slash(os.dir(destination)), create = true) or_return
	defer close_dir(&dst)
	publish(&src, os.base(source), &dst, os.base(destination), false) or_return
	sync_dir(&dst) or_return
	if src.path != dst.path do sync_dir(&src) or_return
	return
}
