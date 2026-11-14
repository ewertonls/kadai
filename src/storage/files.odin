package storage

import "core:crypto"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:strings"

Directory :: struct {
	path: string,
	file: ^os.File,
	// Windows retains ancestor handles without sharing delete access.
	parents: [dynamic]^os.File,
}

close_dir :: proc(d: ^Directory) {
	if d.file != nil do os.close(d.file)
	#reverse for f in d.parents do os.close(f)
	delete(d.parents)
	d^ = {}
}

component :: proc(name: string) -> bool {
	if !valid_path_text(name) || name == "." || name == ".." || strings.contains(name, "/") do return false
	when ODIN_OS == .Windows {
		if strings.contains_any(name, "\\:*?\"<>|") || os.is_reserved_name(name) || os.is_reserved_name(strings.split_n(name, ".", 2, context.temp_allocator)[0]) ||
		   strings.has_suffix(name, ".") || strings.has_suffix(name, " ") { return false }
	}
	return true
}

read_file :: proc(path: string, mutation := false) -> (f: ^os.File, err: os.Error) {
	d := open_dir(slash(os.dir(path))) or_return
	defer close_dir(&d)
	return regular(&d, os.base(path), mutation)
}

random_name :: proc(prefix: string) -> string {
	raw: [16]byte
	crypto.rand_bytes(raw[:])
	encoded := hex.encode(raw[:], context.temp_allocator)
	return fmt.tprintf("%s%s", prefix, string(encoded[:]))
}

write_sync :: proc(f: ^os.File, data: []byte) -> (err: os.Error) {
	n := os.write(f, data) or_return
	if n != len(data) do return .Short_Write
	return os.sync(f)
}

// Publish a complete file without replacing any destination entry.
create_file :: proc(d: ^Directory, name: string, data: []byte, published: ^bool = nil) -> (err: os.Error) {
	if !component(name) do return .Invalid_Path
	tmp := random_name(".kadai-stage-")
	f := create_regular(d, tmp) or_return
	defer remove_entry(d, tmp)
	err = write_sync(f, data)
	close_err := os.close(f)
	if err != nil do return err
	if close_err != nil do return close_err
	publish(d, tmp, d, name, false) or_return
	if published != nil do published^ = true
	return sync_dir(d)
}
