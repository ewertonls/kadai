package storage

import "core:os"
import "core:strings"
import w "core:sys/windows"

@(private)
native_error :: proc() -> os.Error {
	e := w.GetLastError()
	switch e {
	case w.ERROR_FILE_NOT_FOUND, w.ERROR_PATH_NOT_FOUND: return .Not_Exist
	case w.ERROR_ALREADY_EXISTS, w.ERROR_FILE_EXISTS: return .Exist
	}
	return os.Platform_Error(e)
}

@(private)
wide :: proc(s: string) -> w.wstring { return w.utf8_to_wstring(s) }

@(private)
win_open :: proc(path: string, dir, create, mutation: bool) -> (f: ^os.File, err: os.Error) {
	access := w.GENERIC_READ
	share := w.FILE_SHARE_READ
	how := w.OPEN_EXISTING
	flags := w.FILE_FLAG_OPEN_REPARSE_POINT
	if dir {
		flags |= w.FILE_FLAG_BACKUP_SEMANTICS
	} else {
		share |= w.FILE_SHARE_WRITE | w.FILE_SHARE_DELETE
	}
	if create { access |= w.GENERIC_WRITE; how = w.CREATE_NEW }
	sa := w.SECURITY_ATTRIBUTES{nLength = size_of(w.SECURITY_ATTRIBUTES)}
	if create { sa.lpSecurityDescriptor = owner_acl(false) or_return }
	defer if sa.lpSecurityDescriptor != nil { w.LocalFree(sa.lpSecurityDescriptor) }
	h := w.CreateFileW(wide(path), access, share, &sa, how, flags, nil)
	if h == w.INVALID_HANDLE_VALUE do return nil, native_error()
	defer if err != nil { w.CloseHandle(h) }
	info: w.BY_HANDLE_FILE_INFORMATION
	if !w.GetFileInformationByHandle(h, &info) do return nil, native_error()
	attr := info.dwFileAttributes
	if attr & w.FILE_ATTRIBUTE_REPARSE_POINT != 0 || (attr & w.FILE_ATTRIBUTE_DIRECTORY != 0) != dir ||
	   !dir && (w.GetFileType(h) != w.FILE_TYPE_DISK || mutation && info.nNumberOfLinks != 1) {
		return nil, .Invalid_File
	}
	return os.new_file(uintptr(h), path), nil
}

open_dir :: proc(path: string, create := false, private_leaf := false) -> (d: Directory, err: os.Error) {
	if len(path) < 3 || path[1:3] != ":/" do return {}, .Invalid_Path

	d.path = path[:3]
	d.file = win_open(d.path, true, false, false) or_return
	defer if err != nil { close_dir(&d) }
	parts := path[3:]
	for part in strings.split_iterator(&parts, "/") {
		if !component(part) do return d, .Invalid_Path
		d.path = child(d.path, part)
		f, e := win_open(d.path, true, false, false)
		if e == os.General_Error.Not_Exist && create {
			sa := w.SECURITY_ATTRIBUTES{nLength = size_of(w.SECURITY_ATTRIBUTES)}
			if private_leaf && parts == "" { sa.lpSecurityDescriptor = owner_acl(true) or_return }
			defer if sa.lpSecurityDescriptor != nil { w.LocalFree(sa.lpSecurityDescriptor) }
			if !w.CreateDirectoryW(wide(d.path), &sa) && w.GetLastError() != w.ERROR_ALREADY_EXISTS do return d, native_error()
			f, e = win_open(d.path, true, false, false)
		}
		if e != nil do return d, e
		append(&d.parents, d.file)
		d.file = f
	}
	if private_leaf {
		acl := security_text(w.HANDLE(os.fd(d.file)), w.DACL_SECURITY_INFORMATION) or_return
		if acl != "D:P(A;OICI;FA;;;OW)" do return d, .Permission_Denied
	}
	return
}

regular :: proc(d: ^Directory, name: string, mutation := false) -> (^os.File, os.Error) {
	if !component(name) do return nil, .Invalid_Path
	return win_open(child(d.path, name), false, false, mutation)
}

@(private)
create_regular :: proc(d: ^Directory, name: string) -> (^os.File, os.Error) {
	if !component(name) do return nil, .Invalid_Path
	return win_open(child(d.path, name), false, true, false)
}

@(private)
publish :: proc(from: ^Directory, src: string, to: ^Directory, dst: string, replace: bool) -> os.Error {
	if !component(src) || !component(dst) do return .Invalid_Path
	flags := w.MOVEFILE_WRITE_THROUGH
	if replace do flags |= w.MOVEFILE_REPLACE_EXISTING
	if !w.MoveFileExW(wide(child(from.path, src)), wide(child(to.path, dst)), flags) do return native_error()
	return nil
}

@(private)
remove_entry :: proc(d: ^Directory, name: string) -> os.Error {
	if !component(name) do return .Invalid_Path
	return os.remove(child(d.path, name))
}

// MoveFileExW requests write-through when publishing the name.
sync_dir :: proc(d: ^Directory) -> os.Error { return nil }

@(private)
windows_file_id :: proc(f: ^os.File, info: ^os.File_Info) -> os.Error {
	id: w.FILE_ID_INFO
	if !w.GetFileInformationByHandleEx(w.HANDLE(os.fd(f)), .FileIdInfo, &id, size_of(id)) do return native_error()
	info.device = id.VolumeSerialNumber
	info.inode = transmute(u128)id.FileId
	return nil
}
