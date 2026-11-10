#+build darwin, linux
package storage

import "core:c"
import "core:os"
import "core:strings"
import p "core:sys/posix"

when ODIN_OS == .Darwin {
	foreign import libc "system:System"
	foreign libc { renameatx_np :: proc(a: p.FD, src: cstring, b: p.FD, dst: cstring, flags: u32) -> c.int --- }
} else {
	foreign import libc "system:c"
	foreign libc { renameat2 :: proc(a: p.FD, src: cstring, b: p.FD, dst: cstring, flags: u32) -> c.int --- }
}

@(private)
native_error :: proc() -> os.Error {
	e := p.errno()
	#partial switch e {
	case .ENOENT: return .Not_Exist
	case .EEXIST: return .Exist
	case .EACCES, .EPERM: return .Permission_Denied
	}
	return os.Platform_Error(e)
}

@(private)
cs :: proc(s: string) -> cstring { return strings.clone_to_cstring(s, context.temp_allocator) }

open_dir :: proc(path: string, create := false, private_leaf := false) -> (d: Directory, err: os.Error) {
	if !strings.has_prefix(path, "/") do return {}, .Invalid_Path
	fd := p.open("/", {.DIRECTORY, .CLOEXEC})
	if fd < 0 do return {}, native_error()
	defer if err != nil { p.close(fd) }
	parts := path[1:]
	for name in strings.split_iterator(&parts, "/") {
		if !component(name) do return {}, .Invalid_Path
		part := cs(name)
		flags := p.O_Flags{.DIRECTORY, .NOFOLLOW, .CLOEXEC}
		next := p.openat(fd, part, flags)
		if next < 0 && p.errno() == .ENOENT && create {
			mode := transmute(p.mode_t)p._mode_t(0o700 if private_leaf && parts == "" else 0o755)
			if p.mkdirat(fd, part, mode) != .OK && p.errno() != .EEXIST do return {}, native_error()
			if p.fsync(fd) != .OK do return {}, native_error()
			next = p.openat(fd, part, flags)
		}
		if next < 0 do return {}, native_error()
		p.close(fd)
		fd = next
	}
	if private_leaf {
		st: p.stat_t
		if p.fstat(fd, &st) != .OK do return {}, native_error()
		if st.st_uid != p.geteuid() || u32(transmute(p._mode_t)st.st_mode) & 0o077 != 0 do return {}, .Permission_Denied
		private_directory_acl(fd) or_return
	}
	return Directory{path = path, file = os.new_file(uintptr(fd), path)}, nil
}

@(private)
dir_fd :: proc(d: ^Directory) -> p.FD { return p.FD(os.fd(d.file)) }

regular :: proc(d: ^Directory, name: string, mutation := false) -> (f: ^os.File, err: os.Error) {
	if !component(name) do return nil, .Invalid_Path
	fd := p.openat(dir_fd(d), cs(name), {.NOFOLLOW, .CLOEXEC, .NONBLOCK})
	if fd < 0 do return nil, native_error()
	defer if err != nil { p.close(fd) }
	st: p.stat_t
	if p.fstat(fd, &st) != .OK do return nil, native_error()
	if !p.S_ISREG(st.st_mode) || mutation && st.st_nlink != 1 do return nil, .Invalid_File
	return os.new_file(uintptr(fd), child(d.path, name)), nil
}

@(private)
create_regular :: proc(d: ^Directory, name: string) -> (^os.File, os.Error) {
	if !component(name) do return nil, .Invalid_Path
	fd := p.openat(dir_fd(d), cs(name), {.RDWR, .CREAT, .EXCL, .NOFOLLOW, .CLOEXEC}, transmute(p.mode_t)p._mode_t(0o600))
	if fd < 0 do return nil, native_error()
	return os.new_file(uintptr(fd), child(d.path, name)), nil
}

@(private)
publish :: proc(from: ^Directory, src: string, to: ^Directory, dst: string, replace: bool) -> os.Error {
	if !component(src) || !component(dst) do return .Invalid_Path
	a, b := dir_fd(from), dir_fd(to)
	if replace {
		if p.renameat(a, cs(src), b, cs(dst)) != .OK do return native_error()
	} else {
		when ODIN_OS == .Darwin {
			if renameatx_np(a, cs(src), b, cs(dst), 4) != 0 do return native_error() // RENAME_EXCL
		} else {
			if renameat2(a, cs(src), b, cs(dst), 1) != 0 do return native_error() // RENAME_NOREPLACE
		}
	}
	return nil
}

@(private)
remove_entry :: proc(d: ^Directory, name: string) -> os.Error {
	if !component(name) do return .Invalid_Path
	if p.unlinkat(dir_fd(d), cs(name), {}) != .OK do return native_error()
	return nil
}

sync_dir :: proc(d: ^Directory) -> os.Error { return os.sync(d.file) }
