#+build darwin, linux
package storage

import "core:os"
import p "core:sys/posix"

when ODIN_OS == .Darwin { foreign import libc "system:System" }
else { foreign import libc "system:c" }
foreign libc {
	@(link_name = "flock")
	file_lock :: proc(fd: p.FD, flags: i32) -> i32 ---
}

Domain_Lock :: struct { file: ^os.File }
domain_held :: proc(d: Domain_Lock) -> bool { return d.file != nil }

@(private)
lock_file :: proc(f: ^os.File) -> os.Error {
	if file_lock(p.FD(os.fd(f)), 2 | 4) == 0 do return nil // LOCK_EX | LOCK_NB
	if p.errno() == .EWOULDBLOCK do return .Timeout
	return native_error()
}

@(private)
try_domain :: proc() -> (d: Domain_Lock, err: os.Error) {
	f := os.open("/") or_return
	defer if err != nil { os.close(f) }
	lock_file(f) or_return
	return {f}, nil
}

@(private)
release_domain :: proc(d: ^Domain_Lock) {
	if d.file != nil do os.close(d.file)
	d^ = {}
}
