#+build darwin, linux
package storage

import "core:c"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import p "core:sys/posix"

when ODIN_OS == .Darwin {
	foreign import libc "system:System"
	foreign libc {
		flistxattr :: proc(fd: p.FD, list: rawptr, size: uint, flags: c.int) -> int ---
		fgetxattr :: proc(fd: p.FD, key: cstring, data: rawptr, size: uint, position: u32, flags: c.int) -> int ---
		fcopyfile :: proc(from, to: p.FD, state: rawptr, flags: u32) -> c.int ---
		acl_get_fd_np :: proc(fd: p.FD, kind: c.int) -> rawptr ---
		acl_to_text :: proc(acl: rawptr, size: ^int) -> cstring ---
		acl_free :: proc(ptr: rawptr) -> c.int ---
	}
} else {
	foreign import libc "system:c"
	foreign libc {
		flistxattr :: proc(fd: p.FD, list: rawptr, size: uint) -> int ---
		fgetxattr :: proc(fd: p.FD, key: cstring, data: rawptr, size: uint) -> int ---
		fsetxattr :: proc(fd: p.FD, key: cstring, data: rawptr, size: uint, flags: c.int) -> c.int ---
	}
}

@(private)
xattr_names :: proc(fd: p.FD) -> (result: [dynamic]string, err: os.Error) {
	names :: proc(fd: p.FD, buf: []byte) -> int {
		when ODIN_OS == .Darwin { return flistxattr(fd, raw_data(buf), uint(len(buf)), 0) }
		else { return flistxattr(fd, raw_data(buf), uint(len(buf))) }
	}
	n := names(fd, nil)
	if n < 0 do return nil, native_error()
	if n > 1<<20 do return nil, .Short_Buffer
	if n == 0 do return
	buf := make([]byte, n, context.temp_allocator) or_return
	if names(fd, buf) != n do return nil, .Invalid_File
	result = make([dynamic]string, context.temp_allocator)
	keys := string(buf)
	for key in strings.split_iterator(&keys, "\x00") do append(&result, key)
	slice.sort(result[:])
	return
}

@(private)
attribute :: proc(fd: p.FD, name: string) -> (value: []byte, err: os.Error) {
	get :: proc(fd: p.FD, name: cstring, buf: []byte) -> int {
		when ODIN_OS == .Darwin { return fgetxattr(fd, name, raw_data(buf), uint(len(buf)), 0, 0) }
		else { return fgetxattr(fd, name, raw_data(buf), uint(len(buf))) }
	}
	key := cs(name)
	size := get(fd, key, nil)
	if size < 0 do return nil, native_error()
	if size > 4<<20 do return nil, .Short_Buffer
	value = make([]byte, size) or_return
	if get(fd, key, value) != size { delete(value); return nil, .Invalid_File }
	return
}

@(private)
acl_text :: proc(fd: p.FD) -> (value: string, err: os.Error) {
	when ODIN_OS == .Darwin {
		acl := acl_get_fd_np(fd, 0x100)
		if acl == nil {
			if p.errno() == .ENOENT do return "", nil
			return "", native_error()
		}
		defer acl_free(acl)
		size: int
		txt := acl_to_text(acl, &size)
		if txt == nil do return "", native_error()
		defer acl_free(rawptr(txt))
		return strings.clone(string(txt), context.temp_allocator), nil
	} else {
		// POSIX ACLs on Linux are included in the xattr set.
		return "", nil
	}
}

@(private)
private_directory_acl :: proc(fd: p.FD) -> (err: os.Error) {
	acl := acl_text(fd) or_return
	if acl != "" do return .Permission_Denied
	when ODIN_OS == .Linux {
		names := xattr_names(fd) or_return
		for key in names {
			if strings.has_prefix(key, "system.posix_acl_") do return .Permission_Denied
		}
	}
	return
}

@(private)
metadata :: proc(f: ^os.File) -> (signature: string, err: os.Error) {
	fd := p.FD(os.fd(f))
	st: p.stat_t
	if p.fstat(fd, &st) != .OK do return "", native_error()
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "%d/%d/%d/", st.st_uid, st.st_gid, transmute(p._mode_t)st.st_mode)
	when ODIN_OS == .Darwin { fmt.sbprintf(&b, "%d/", st.st_flags) }
	acl := acl_text(fd) or_return
	fmt.sbprintf(&b, "%d:%s", len(acl), acl)
	names := xattr_names(fd) or_return
	for key in names {
		value := attribute(fd, key) or_return
		fmt.sbprintf(&b, "%d:%s%s", len(key), key, digest(value))
		delete(value)
	}
	return digest(transmute([]byte)strings.to_string(b)), nil
}

@(private)
copy_metadata :: proc(src, dst: ^os.File) -> (err: os.Error) {
	a, b := p.FD(os.fd(src)), p.FD(os.fd(dst))
	when ODIN_OS == .Darwin {
		if fcopyfile(a, b, nil, 7) != 0 do return native_error()
	} else {
		s, d: p.stat_t
		if p.fstat(a, &s) != .OK || p.fstat(b, &d) != .OK do return native_error()
		if s.st_uid != d.st_uid || s.st_gid != d.st_gid {
			if p.fchown(b, s.st_uid, s.st_gid) != .OK do return native_error()
		}
		if p.fchmod(b, s.st_mode) != .OK do return native_error()
		names := xattr_names(a) or_return
		for key in names {
			value := attribute(a, key) or_return
			res := fsetxattr(b, cs(key), raw_data(value), uint(len(value)), 0)
			delete(value)
			if res != 0 do return native_error()
		}
	}
	original := metadata(src) or_return
	copied := metadata(dst) or_return
	if original != copied do return .Unsupported
	return
}
