package storage

import "core:fmt"
import "core:os"
import w "core:sys/windows"

foreign import advapi "system:advapi32.lib"
foreign import kernel "system:kernel32.lib"
foreign advapi {
	ConvertStringSecurityDescriptorToSecurityDescriptorW :: proc "system"(text: w.LPCWSTR, revision: u32, sd: ^rawptr, size: ^u32) -> w.BOOL ---
	ConvertSecurityDescriptorToStringSecurityDescriptorW :: proc "system"(sd: rawptr, revision, flags: u32, out: ^w.wstring, size: ^u32) -> w.BOOL ---
	GetKernelObjectSecurity :: proc "system"(h: w.HANDLE, flags: u32, sd: rawptr, length: u32, needed: ^u32) -> w.BOOL ---
}
foreign kernel {
	BackupRead :: proc "system"(h: w.HANDLE, buf: rawptr, count: u32, read: ^u32, abort, security: w.BOOL, ctx: ^rawptr) -> w.BOOL ---
	BackupSeek :: proc "system"(h: w.HANDLE, lo, hi: u32, out_lo, out_hi: ^u32, ctx: ^rawptr) -> w.BOOL ---
}

@(private)
owner_acl :: proc(dir: bool) -> (sd: rawptr, err: os.Error) {
	text := "D:P(A;OICI;FA;;;OW)" if dir else "D:P(A;;FA;;;OW)"
	if !ConvertStringSecurityDescriptorToSecurityDescriptorW(wide(text), 1, &sd, nil) do return nil, native_error()
	return
}

@(private)
security_text :: proc(h: w.HANDLE, flags: u32) -> (result: string, err: os.Error) {
	n: u32
	_ = GetKernelObjectSecurity(h, flags, nil, 0, &n)
	if n == 0 || n > 1<<20 do return "", .Unsupported
	bytes := make([]byte, n, context.temp_allocator) or_return
	if !GetKernelObjectSecurity(h, flags, raw_data(bytes), n, &n) do return "", native_error()
	out: w.wstring
	if !ConvertSecurityDescriptorToStringSecurityDescriptorW(raw_data(bytes), 1, flags, &out, nil) do return "", native_error()
	defer w.LocalFree(rawptr(out))
	return w.wstring_to_utf8(out, allocator = context.temp_allocator) or_return, nil
}

// Supported NTFS images contain a default data stream and a reproducible
// security stream. Refuse named streams, EAs, object IDs, sparse and reparse
// data instead of silently dropping them on replacement.
@(private)
metadata :: proc(f: ^os.File) -> (signature: string, err: os.Error) {
	h := w.HANDLE(os.fd(f))
	info: w.BY_HANDLE_FILE_INFORMATION
	if !w.GetFileInformationByHandle(h, &info) do return "", native_error()
	if info.dwFileAttributes & ~(w.FILE_ATTRIBUTE_NORMAL | w.FILE_ATTRIBUTE_ARCHIVE) != 0 do return "", .Unsupported
	sd := security_text(h, w.OWNER_SECURITY_INFORMATION | w.GROUP_SECURITY_INFORMATION | w.DACL_SECURITY_INFORMATION | w.LABEL_SECURITY_INFORMATION) or_return
	// BackupRead advances the file pointer. Restore it before returning.
	pos := os.seek(f, 0, .Current) or_return
	defer os.seek(f, pos, .Start)
	_ = os.seek(f, 0, .Start) or_return
	ctx: rawptr
	n: u32
	defer BackupRead(h, nil, 0, &n, true, true, &ctx)
	security := ""
	for {
		header: [20]byte
		if !BackupRead(h, &header, 20, &n, false, true, &ctx) do return "", native_error()
		if n == 0 do break
		if n != 20 do return "", .Invalid_File
		id := u32((^u32le)(&header[0])^)
		size := (^u64le)(&header[8])^
		if (^u32le)(&header[16])^ != 0 do return "", .Unsupported
		switch id {
		case 1:
			if size != 0 {
				lo, hi: u32
				if !BackupSeek(h, u32(size), u32(u64(size)>>32), &lo, &hi, &ctx) ||
				   u64(hi)<<32 | u64(lo) != u64(size) { return "", .Invalid_File }
			}
		case 3:
			if size == 0 || size > 1<<20 do return "", .Unsupported
			bytes := make([]byte, int(size), context.temp_allocator) or_return
			if !BackupRead(h, raw_data(bytes), u32(size), &n, false, true, &ctx) || n != u32(size) do return "", .Invalid_File
			security = digest(bytes)
		case: return "", .Unsupported
		}
	}
	if security == "" do return "", .Unsupported
	return digest(transmute([]byte)fmt.tprintf("%s/%s/%d", sd, security, info.dwFileAttributes)), nil
}

@(private)
copy_metadata :: proc(src, dst: ^os.File) -> (err: os.Error) {
	a := metadata(src) or_return
	b := metadata(dst) or_return
	if a != b do return .Unsupported
	return
}
