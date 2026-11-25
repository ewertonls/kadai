#+build darwin, linux
package storage

import "core:c"
import "core:os"
import "core:strings"
import p "core:sys/posix"

when ODIN_OS == .Darwin {
	foreign import libc "system:System"
	foreign libc {renameatx_np :: proc(a: p.FD, src: cstring, b: p.FD, dst: cstring, flags: u32) -> c.int ---}
} else {
	foreign import libc "system:c"
	foreign libc {renameat2 :: proc(a: p.FD, src: cstring, b: p.FD, dst: cstring, flags: u32) -> c.int ---}
}

@(private)
native_error :: proc() -> os.Error {
	e := p.errno()
	#partial switch e {
	case .ENOENT:
		return .Not_Exist
	case .EEXIST:
		return .Exist
	case .EACCES, .EPERM:
		return .Permission_Denied
	}
	return os.Platform_Error(e)
}

@(private)
cs :: proc(s: string) -> cstring {return strings.clone_to_cstring(s, context.temp_allocator)}

open_dir :: proc(
	path: string,
	create := false,
	private_leaf := false,
	created: ^bool = nil,
) -> (
	d: Directory,
	err: os.Error,
) {
	if !strings.has_prefix(path, "/") do return {}, .Invalid_Path
	fd := p.open("/", {.DIRECTORY, .CLOEXEC})
	if fd < 0 do return {}, native_error()
	defer if err != nil {p.close(fd)}
	parts := path[1:]
	for name in strings.split_iterator(&parts, "/") {
		if !component(name) do return {}, .Invalid_Path
		part := cs(name)
		flags := p.O_Flags{.DIRECTORY, .NOFOLLOW, .CLOEXEC}
		next := p.openat(fd, part, flags)
		if next < 0 && p.errno() == .ENOENT && create {
			mode := transmute(p.mode_t)p._mode_t(0o700 if private_leaf && parts == "" else 0o755)
			if p.mkdirat(fd, part, mode) == .OK {
				if created != nil do created^ = true
			} else if p.errno() != .EEXIST {return {}, native_error()}
			if p.fsync(fd) != .OK do return {}, native_error()
			next = p.openat(fd, part, flags)
		}
		if next < 0 do return {}, native_error()
		p.close(fd)
		fd = next
	}
	if private_leaf do check_private_dir(fd) or_return
	return Directory{path = path, file = os.new_file(uintptr(fd), path)}, nil
}

@(private)
dir_fd :: proc(d: ^Directory) -> p.FD {return p.FD(os.fd(d.file))}

@(private)
check_private_dir :: proc(fd: p.FD) -> os.Error {
	st: p.stat_t
	if p.fstat(fd, &st) != .OK do return native_error()
	if st.st_uid != p.geteuid() || u32(transmute(p._mode_t)st.st_mode) & 0o077 != 0 do return .Permission_Denied
	return private_directory_acl(fd)
}

regular :: proc(
	d: ^Directory,
	name: string,
	mutation := false,
	writable := false,
) -> (
	f: ^os.File,
	err: os.Error,
) {
	if !component(name) do return nil, .Invalid_Path
	flags := p.O_Flags{.NOFOLLOW, .CLOEXEC, .NONBLOCK}
	if writable do flags += {.RDWR}
	fd := p.openat(dir_fd(d), cs(name), flags)
	if fd < 0 do return nil, native_error()
	defer if err != nil {p.close(fd)}
	st: p.stat_t
	if p.fstat(fd, &st) != .OK do return nil, native_error()
	if !p.S_ISREG(st.st_mode) || (mutation || writable) && st.st_nlink != 1 do return nil, .Invalid_File
	return os.new_file(uintptr(fd), child(d.path, name)), nil
}

@(private)
create_regular :: proc(
	d: ^Directory,
	name: string,
	created: ^bool = nil,
	project_file := false,
) -> (
	^os.File,
	os.Error,
) {
	if !component(name) do return nil, .Invalid_Path
	fd := p.openat(
		dir_fd(d),
		cs(name),
		{.RDWR, .CREAT, .EXCL, .NOFOLLOW, .CLOEXEC},
		transmute(p.mode_t)p._mode_t(0o666 if project_file else 0o600),
	)
	if fd < 0 do return nil, native_error()
	if created != nil do created^ = true
	return os.new_file(uintptr(fd), child(d.path, name)), nil
}

@(private)
publish :: proc(
	from: ^Directory,
	src: string,
	to: ^Directory,
	dst: string,
	replace: bool,
) -> os.Error {
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

@(private)
create_private_dir :: proc(
	parent: ^Directory,
	name: string,
	created: ^bool,
) -> (
	dir: Directory,
	err: os.Error,
) {
	if !component(name) do return {}, .Invalid_Path
	part := cs(name)
	if p.mkdirat(dir_fd(parent), part, transmute(p.mode_t)p._mode_t(0o700)) != .OK do return {}, native_error()
	created^ = true
	fd := p.openat(dir_fd(parent), part, {.DIRECTORY, .NOFOLLOW, .CLOEXEC})
	if fd < 0 do return {}, native_error()
	defer if err != nil {p.close(fd)}
	check_private_dir(fd) or_return
	path := child(parent.path, name)
	return Directory{path = path, file = os.new_file(uintptr(fd), path)}, nil
}

@(private)
remove_empty_dir :: proc(parent: ^Directory, name: string) -> os.Error {
	if !component(name) do return .Invalid_Path
	if p.unlinkat(dir_fd(parent), cs(name), {.REMOVEDIR}) != .OK do return native_error()
	return nil
}

// Bound the number of virtual memory regions per preparation. The plan gets
// one additional mapping so cleanup can retire it before inspecting images.
@(private)
MAX_PREPARATION_IMAGE_PINS :: 4096

// A file-backed mapping keeps the inode alive after close, even for an empty
// file. We never access its pages. If pinning fails, cleanup must leave the file.
@(private)
pin_prepared_inode :: proc(f: ^os.File, prep: ^Preparation, plan := false) -> bool {
	if !plan && prep.skip_image_pins do return false
	if plan || len(prep.pins) < MAX_PREPARATION_IMAGE_PINS {
		pin := p.mmap(nil, 1, p.PROT_NONE, {.PRIVATE}, p.FD(os.fd(f)))
		if pin != p.MAP_FAILED {
			if _, err := append(&prep.pins, pin); err == nil do return true
			p.munmap(pin, 1)
		}
	}
	// Give back the mappings if the filesystem or process cannot retain them.
	// A large operation can still commit. Its plan gets a separate pin attempt.
	release_preparation_pins(prep)
	for &image in prep.images do image.identity = {}
	prep.plan = {}
	prep.skip_image_pins = true
	return false
}

@(private)
release_preparation_pins :: proc(prep: ^Preparation) {
	for pin in prep.pins do p.munmap(pin, 1)
	delete(prep.pins)
	prep.pins = nil
}

@(private)
verify_owned_entry :: proc(
	parent: ^Directory,
	name: string,
	expected: File_Identity,
	directory: bool,
) -> os.Error {
	if !component(name) do return .Invalid_Path
	st: p.stat_t
	if p.fstatat(dir_fd(parent), cs(name), &st, {.SYMLINK_NOFOLLOW}) != .OK do return native_error()
	actual := File_Identity{u64(st.st_dev), u128(st.st_ino)}
	if expected.inode == 0 || actual != expected do return .Invalid_File
	if directory {
		if !p.S_ISDIR(st.st_mode) do return .Invalid_File
	} else if !p.S_ISREG(st.st_mode) || st.st_nlink != 1 {return .Invalid_File}
	return nil
}

@(private)
remove_owned_entry :: proc(
	parent: ^Directory,
	name: string,
	expected: File_Identity,
	directory: bool,
) -> os.Error {
	e := verify_owned_entry(parent, name, expected, directory)
	if e == .Not_Exist do return nil
	if e != nil do return e
	flags := p.AT_Flags{.REMOVEDIR} if directory else p.AT_Flags{}
	if p.unlinkat(dir_fd(parent), cs(name), flags) != .OK && p.errno() != .ENOENT do return native_error()
	return nil
}

sync_dir :: proc(d: ^Directory) -> os.Error {return os.sync(d.file)}
