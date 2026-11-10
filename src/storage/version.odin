package storage

import "core:crypto/sha2"
import "core:encoding/hex"
import "core:fmt"
import "core:os"

digest :: proc(data: []byte) -> string {
	h: sha2.Context_256
	sha2.init_256(&h)
	sha2.update(&h, data)
	sum: [32]byte
	sha2.final(&h, sum[:])
	return string(hex.encode(sum[:], context.temp_allocator))
}

file_version :: proc(info: os.File_Info, data: []byte) -> string {
	return fmt.tprintf("%d.%d.%s", info.device, info.inode, digest(data))
}

// Hash directly from the descriptor. Offset reads leave callers' file cursors
// untouched and bound memory independently of the source size.
@(private)
stream_version :: proc(f: ^os.File, info: os.File_Info, limit: int) -> (version: string, err: os.Error) {
	if info.size < 0 || info.size > i64(limit) do return "", .Short_Buffer
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	buf: [32<<10]byte
	for pos := i64(0); pos < info.size; {
		chunk := buf[:int(min(i64(len(buf)), info.size-pos))]
		n, read_err := os.read_at(f, chunk, pos)
		if n != len(chunk) || read_err != nil && read_err != .EOF do return "", .Invalid_File
		sha2.update(&ctx, chunk)
		pos += i64(n)
	}
	after := os.fstat(f, context.temp_allocator) or_return
	if after.size != info.size || after.modification_time != info.modification_time do return "", .Invalid_File
	sum: [32]byte
	sha2.final(&ctx, sum[:])
	return fmt.tprintf("%d.%d.%s", info.device, info.inode, string(hex.encode(sum[:], context.temp_allocator))), nil
}
