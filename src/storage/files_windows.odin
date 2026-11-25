package storage

import "core:os"
import "core:strings"
import w "core:sys/windows"

@(private)
native_error :: proc() -> os.Error {return windows_error(w.GetLastError())}

@(private)
windows_error :: proc(e: u32) -> os.Error {
	switch e {
	case w.ERROR_FILE_NOT_FOUND, w.ERROR_PATH_NOT_FOUND:
		return .Not_Exist
	case w.ERROR_ALREADY_EXISTS, w.ERROR_FILE_EXISTS:
		return .Exist
	}
	return os.Platform_Error(e)
}

@(private)
wide :: proc(s: string) -> w.wstring {return w.utf8_to_wstring(s)}

foreign import ntdll "system:ntdll.lib"
foreign ntdll {
	NtSetInformationFile :: proc "system" (h: w.HANDLE, io: ^w.IO_STATUS_BLOCK, info: rawptr, length: u32, kind: w.FILE_INFORMATION_CLASS) -> w.NTSTATUS ---
}

@(private)
check_directory :: proc(f: ^os.File) -> os.Error {
	info: w.BY_HANDLE_FILE_INFORMATION
	if !w.GetFileInformationByHandle(w.HANDLE(os.fd(f)), &info) do return native_error()
	if info.dwFileAttributes & (w.FILE_ATTRIBUTE_DIRECTORY | w.FILE_ATTRIBUTE_REPARSE_POINT) != w.FILE_ATTRIBUTE_DIRECTORY do return .Invalid_File
	return nil
}

// A pinned directory cannot be renamed, but can acquire a reparse point.
// Resolve one component relative to its handle, never through its path again.
@(private)
relative_handle :: proc(
	parent: ^os.File,
	name: string,
	access, share, disposition, options: u32,
	sd: rawptr = nil,
) -> (
	h: w.HANDLE,
	err: os.Error,
) {
	if !component(name) do return nil, .Invalid_Path
	check_directory(parent) or_return
	text := w.utf8_to_utf16(name)
	if len(text) * 2 > 65534 do return nil, .Invalid_Path
	unicode := w.UNICODE_STRING{u16(len(text) * 2), u16(len(text) * 2), raw_data(text)}
	attrs := w.OBJECT_ATTRIBUTES {
		Length             = size_of(w.OBJECT_ATTRIBUTES),
		RootDirectory      = w.HANDLE(os.fd(parent)),
		ObjectName         = &unicode,
		Attributes         = 0x40 | 0x1000,
		SecurityDescriptor = sd,
	} // OBJ_CASE_INSENSITIVE | OBJ_DONT_REPARSE
	io: w.IO_STATUS_BLOCK
	status := w.NtCreateFile(
		&h,
		access | w.SYNCHRONIZE,
		&attrs,
		&io,
		nil,
		w.FILE_ATTRIBUTE_NORMAL,
		share,
		disposition,
		options | 0x20 | w.FILE_FLAG_OPEN_REPARSE_POINT,
		nil,
		0,
	) // FILE_SYNCHRONOUS_IO_NONALERT
	if status < 0 do return nil, windows_error(w.RtlNtStatusToDosError(status))
	return
}

@(private)
win_open :: proc(
	path: string,
	dir, create, mutation: bool,
	parent: ^os.File = nil,
	private_leaf := false,
	created: ^bool = nil,
	writable := false,
	project_file := false,
) -> (
	f: ^os.File,
	err: os.Error,
) {
	access := w.GENERIC_READ
	share := w.FILE_SHARE_READ
	how := w.OPEN_EXISTING
	flags := w.FILE_FLAG_OPEN_REPARSE_POINT
	if writable {
		access |= w.GENERIC_WRITE
	} else if dir {
		flags |= w.FILE_FLAG_BACKUP_SEMANTICS
		share |= w.FILE_SHARE_WRITE
	} else {
		share |= w.FILE_SHARE_WRITE | w.FILE_SHARE_DELETE
	}
	if create && !dir {
		access |= w.GENERIC_WRITE
		if !project_file do access |= w.WRITE_DAC | w.WRITE_OWNER
		how = w.CREATE_NEW
	}
	sa := w.SECURITY_ATTRIBUTES {
		nLength = size_of(w.SECURITY_ATTRIBUTES),
	}
	if create &&
	   (!dir && !project_file || private_leaf) {sa.lpSecurityDescriptor = owner_acl(dir) or_return}
	defer if sa.lpSecurityDescriptor != nil {w.LocalFree(sa.lpSecurityDescriptor)}
	h: w.HANDLE
	if parent == nil {
		h = w.CreateFileW(wide(path), access, share, &sa, how, flags, nil)
		if h == w.INVALID_HANDLE_VALUE do return nil, native_error()
	} else {
		disposition := u32(w.FILE_CREATE) if create else u32(w.FILE_OPEN)
		options := u32(1) if dir else u32(w.FILE_NON_DIRECTORY_FILE) // FILE_DIRECTORY_FILE
		h = relative_handle(
			parent,
			os.base(path),
			access,
			share,
			disposition,
			options,
			sa.lpSecurityDescriptor,
		) or_return
	}
	if create && created != nil do created^ = true
	defer if err != nil {w.CloseHandle(h)}
	info: w.BY_HANDLE_FILE_INFORMATION
	if !w.GetFileInformationByHandle(h, &info) do return nil, native_error()
	attr := info.dwFileAttributes
	if attr & w.FILE_ATTRIBUTE_REPARSE_POINT != 0 ||
	   (attr & w.FILE_ATTRIBUTE_DIRECTORY != 0) != dir ||
	   !dir && (w.GetFileType(h) != w.FILE_TYPE_DISK || mutation && info.nNumberOfLinks != 1) {
		return nil, .Invalid_File
	}
	return os.new_file(uintptr(h), path), nil
}

open_dir :: proc(
	path: string,
	create := false,
	private_leaf := false,
	created: ^bool = nil,
) -> (
	d: Directory,
	err: os.Error,
) {
	if len(path) < 3 || path[1:3] != ":/" do return {}, .Invalid_Path

	d.path = path[:3]
	d.file = win_open(d.path, true, false, false) or_return
	defer if err != nil {close_dir(&d)}
	parts := path[3:]
	for part in strings.split_iterator(&parts, "/") {
		if !component(part) do return d, .Invalid_Path
		d.path = child(d.path, part)
		f, e := win_open(d.path, true, false, false, d.file)
		if e == os.General_Error.Not_Exist && create {
			f, e = win_open(
				d.path,
				true,
				true,
				false,
				d.file,
				private_leaf && parts == "",
				created,
			)
			if e == os.General_Error.Exist {f, e = win_open(d.path, true, false, false, d.file)}
		}
		if e != nil do return d, e
		append(&d.parents, d.file)
		d.file = f
	}
	if private_leaf do check_private_dir(d.file) or_return
	return
}

@(private)
check_private_dir :: proc(f: ^os.File) -> os.Error {
	acl := security_text(
		w.HANDLE(os.fd(f)),
		w.DACL_SECURITY_INFORMATION,
		require_private = true,
	) or_return
	if acl != "D:P(A;OICI;FA;;;OW)" do return .Permission_Denied
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
	path := child(parent.path, name)
	f := win_open(path, true, true, false, parent.file, true, created) or_return
	defer if err != nil {os.close(f)}
	check_private_dir(f) or_return
	return Directory{path = path, file = f}, nil
}

regular :: proc(
	d: ^Directory,
	name: string,
	mutation := false,
	writable := false,
) -> (
	^os.File,
	os.Error,
) {
	if !component(name) do return nil, .Invalid_Path
	return win_open(
		child(d.path, name),
		false,
		false,
		mutation || writable,
		d.file,
		writable = writable,
	)
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
	return win_open(
		child(d.path, name),
		false,
		true,
		false,
		d.file,
		created = created,
		project_file = project_file,
	)
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
	check_directory(to.file) or_return
	h := relative_handle(
		from.file,
		src,
		w.DELETE,
		w.FILE_SHARE_READ | w.FILE_SHARE_WRITE | w.FILE_SHARE_DELETE,
		w.FILE_OPEN,
		0,
	) or_return
	defer w.CloseHandle(h)
	Rename :: struct {
		replace: w.BOOLEAN,
		root   : w.HANDLE,
		length : u32,
		name   : [1]u16,
	}
	text := w.utf8_to_utf16(dst)
	buf := make([]u64, (size_of(Rename) + len(text) * 2 + 7) / 8, context.temp_allocator) or_return
	info := (^Rename)(raw_data(buf))
	info.replace, info.root, info.length =
		w.BOOLEAN(replace), w.HANDLE(os.fd(to.file)), u32(len(text) * 2)
	copy(([^]u16)(&info.name[0])[:len(text)], text)
	io: w.IO_STATUS_BLOCK
	status := NtSetInformationFile(h, &io, info, u32(len(buf) * 8), .FileRenameInformation)
	if status < 0 do return windows_error(w.RtlNtStatusToDosError(status))
	return nil
}

@(private)
remove_entry :: proc(d: ^Directory, name: string) -> os.Error {
	return remove_relative(d, name, false)
}

@(private)
remove_empty_dir :: proc(d: ^Directory, name: string) -> os.Error {
	return remove_relative(d, name, true)
}

@(private)
remove_relative :: proc(d: ^Directory, name: string, directory: bool) -> os.Error {
	kind := u32(1) if directory else u32(w.FILE_NON_DIRECTORY_FILE) // FILE_DIRECTORY_FILE
	access := w.DELETE | w.FILE_READ_ATTRIBUTES if directory else w.DELETE
	h := relative_handle(
		d.file,
		name,
		access,
		w.FILE_SHARE_READ | w.FILE_SHARE_WRITE | w.FILE_SHARE_DELETE,
		w.FILE_OPEN,
		kind,
	) or_return
	defer w.CloseHandle(h)
	if directory {
		info: w.BY_HANDLE_FILE_INFORMATION
		if !w.GetFileInformationByHandle(h, &info) do return native_error()
		if info.dwFileAttributes & w.FILE_ATTRIBUTE_REPARSE_POINT != 0 do return .Invalid_File
	}
	remove: w.BOOLEAN = true
	if !w.SetFileInformationByHandle(h, .FileDispositionInfo, &remove, size_of(remove)) do return native_error()
	return nil
}

// Windows has no unprivileged equivalent of fsync on a directory handle.
sync_dir :: proc(d: ^Directory) -> os.Error {return nil}

@(private)
windows_file_id :: proc(f: ^os.File, info: ^os.File_Info) -> os.Error {
	id: w.FILE_ID_INFO
	if !w.GetFileInformationByHandleEx(w.HANDLE(os.fd(f)), .FileIdInfo, &id, size_of(id)) do return native_error()
	info.device = id.VolumeSerialNumber
	info.inode = transmute(u128)id.FileId
	return nil
}
