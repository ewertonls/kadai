package storage

import "core:fmt"
import "core:os"
import w "core:sys/windows"

foreign import advapi "system:advapi32.lib"
foreign import kernel "system:kernel32.lib"
foreign import ntdll "system:ntdll.lib"
foreign advapi {
	ConvertStringSecurityDescriptorToSecurityDescriptorW :: proc "system"(text: w.LPCWSTR, revision: u32, sd: ^rawptr, size: ^u32) -> w.BOOL ---
	ConvertSecurityDescriptorToStringSecurityDescriptorW :: proc "system"(sd: rawptr, revision, flags: u32, out: ^w.wstring, size: ^u32) -> w.BOOL ---
	GetKernelObjectSecurity :: proc "system"(h: w.HANDLE, flags: u32, sd: rawptr, length: u32, needed: ^u32) -> w.BOOL ---
	GetSecurityDescriptorOwner :: proc "system"(sd: rawptr, owner: ^rawptr, defaulted: ^w.BOOL) -> w.BOOL ---
	GetSecurityDescriptorDacl :: proc "system"(sd: rawptr, present: ^w.BOOL, acl: ^w.PACL, defaulted: ^w.BOOL) -> w.BOOL ---
	GetAce :: proc "system"(acl: w.PACL, index: u32, ace: ^rawptr) -> w.BOOL ---
	IsValidSid :: proc "system"(sid: rawptr) -> w.BOOL ---
	EqualSid :: proc "system"(a, b: rawptr) -> w.BOOL ---
	ConvertStringSidToSidW :: proc "system"(text: w.LPCWSTR, sid: ^rawptr) -> w.BOOL ---
}
foreign ntdll {
	RtlValidRelativeSecurityDescriptor :: proc "system"(sd: rawptr, length, required: u32) -> w.BOOLEAN ---
}
foreign kernel {
	BackupRead :: proc "system"(h: w.HANDLE, buf: rawptr, count: u32, read: ^u32, abort, security: w.BOOL, ctx: ^rawptr) -> w.BOOL ---
	BackupWrite :: proc "system"(h: w.HANDLE, buf: rawptr, count: u32, written: ^u32, abort, security: w.BOOL, ctx: ^rawptr) -> w.BOOL ---
	BackupSeek :: proc "system"(h: w.HANDLE, lo, hi: u32, out_lo, out_hi: ^u32, ctx: ^rawptr) -> w.BOOL ---
}

@(private)
owner_acl :: proc(dir: bool) -> (sd: rawptr, err: os.Error) {
	text := "D:P(A;OICI;FA;;;OW)" if dir else "D:P(A;;FA;;;OW)"
	if !ConvertStringSecurityDescriptorToSecurityDescriptorW(wide(text), 1, &sd, nil) do return nil, native_error()
	return
}

@(private)
security_buffer :: proc(size: int) -> (bytes: []byte, err: os.Error) {
	if size < 20 || size > 1<<20 do return nil, .Unsupported
	// Both native descriptors and BackupWrite streams need DWORD alignment.
	words := make([]u32, (size+3)/4, context.temp_allocator) or_return
	return ([^]byte)(raw_data(words))[:size], nil
}

@(private)
security_descriptor :: proc(h: w.HANDLE, flags: u32) -> (bytes: []byte, err: os.Error) {
	n: u32
	_ = GetKernelObjectSecurity(h, flags, nil, 0, &n)
	bytes = security_buffer(int(n)) or_return
	if !GetKernelObjectSecurity(h, flags, raw_data(bytes), n, &n) do return nil, native_error()
	return bytes[:n], nil
}

// Snapshots retain the source security descriptor. A private parent directory
// cannot hide a readable child from users with traverse-check bypass. Check
// owners as well as every grant, even OWNER RIGHTS and inherit-only ACEs.
@(private)
private_security :: proc(bytes: []byte) -> (err: os.Error) {
	if len(bytes) < 20 || len(bytes) > 1<<20 || uintptr(raw_data(bytes)) % 4 != 0 do return .Unsupported
	if !RtlValidRelativeSecurityDescriptor(raw_data(bytes), u32(len(bytes)), w.OWNER_SECURITY_INFORMATION | w.DACL_SECURITY_INFORMATION) do return .Unsupported
	owner: rawptr
	present, defaulted: w.BOOL
	acl: w.PACL
	if !GetSecurityDescriptorOwner(raw_data(bytes), &owner, &defaulted) || owner == nil ||
	   !GetSecurityDescriptorDacl(raw_data(bytes), &present, &acl, &defaulted) || !present || acl == nil { return .Unsupported }
	token: w.HANDLE
	if !w.OpenProcessToken(w.GetCurrentProcess(), w.TOKEN_QUERY, &token) do return native_error()
	defer w.CloseHandle(token)
	n: u32
	_ = w.GetTokenInformation(token, .TokenUser, nil, 0, &n)
	if n < size_of(w.TOKEN_USER) || n > 1<<20 do return .Unsupported
	user_info := make([]u64, (n+7)/8, context.temp_allocator) or_return
	if !w.GetTokenInformation(token, .TokenUser, raw_data(user_info), n, &n) do return native_error()
	user := (^w.TOKEN_USER)(raw_data(user_info)).User.Sid
	trusted: [3]rawptr // LocalSystem, Administrators, OWNER RIGHTS
	defer for sid in trusted { if sid != nil do w.LocalFree(sid) }
	for text, i in ([3]string{"S-1-5-18", "S-1-5-32-544", "S-1-3-4"}) {
		if !ConvertStringSidToSidW(wide(text), &trusted[i]) do return native_error()
	}
	if !EqualSid(owner, user) && !EqualSid(owner, trusted[0]) && !EqualSid(owner, trusted[1]) do return .Unsupported
	for i in 0..<u32(acl.AceCount) {
		ace: rawptr
		if !GetAce(acl, i, &ace) do return .Unsupported
		header := ([^]byte)(ace)
		size := int((^u16le)(&header[2])^)
		// Only conventional allow/deny ACEs have the supported SID layout.
		if header[0] > 1 || size < 16 || uintptr(ace)+uintptr(size) > uintptr(acl)+uintptr(acl.AclSize) do return .Unsupported
		if 16 + 4*int(header[9]) > size do return .Unsupported
		sid := rawptr(&header[8])
		if !IsValidSid(sid) do return .Unsupported
		if header[0] == 1 do continue // A deny cannot disclose the snapshot.
		if !EqualSid(sid, user) && !EqualSid(sid, trusted[0]) &&
		   !EqualSid(sid, trusted[1]) && !EqualSid(sid, trusted[2]) { return .Unsupported }
	}
	return
}

@(private)
security_text :: proc(h: w.HANDLE, flags: u32, require_private := false) -> (result: string, err: os.Error) {
	read_flags := flags
	if require_private do read_flags |= w.OWNER_SECURITY_INFORMATION | w.DACL_SECURITY_INFORMATION
	bytes := security_descriptor(h, read_flags) or_return
	if require_private do private_security(bytes) or_return
	out: w.wstring
	if !ConvertSecurityDescriptorToStringSecurityDescriptorW(raw_data(bytes), 1, flags, &out, nil) do return "", native_error()
	defer w.LocalFree(rawptr(out))
	return w.wstring_to_utf8(out, allocator = context.temp_allocator) or_return, nil
}

// Supported NTFS images contain a default data stream and a reproducible
// security stream. Refuse named streams, EAs, object IDs, sparse and reparse
// data instead of silently dropping them on replacement.
@(private)
metadata :: proc(f: ^os.File, security_image: ^[]byte = nil) -> (signature: string, err: os.Error) {
	h := w.HANDLE(os.fd(f))
	info: w.BY_HANDLE_FILE_INFORMATION
	if !w.GetFileInformationByHandle(h, &info) do return "", native_error()
	if info.dwFileAttributes & ~(w.FILE_ATTRIBUTE_NORMAL | w.FILE_ATTRIBUTE_ARCHIVE) != 0 do return "", .Unsupported
	sd := security_text(h, w.OWNER_SECURITY_INFORMATION | w.GROUP_SECURITY_INFORMATION | w.DACL_SECURITY_INFORMATION | w.LABEL_SECURITY_INFORMATION, require_private = true) or_return
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
			if security != "" do return "", .Unsupported
			bytes := security_buffer(int(size)) or_return
			if !BackupRead(h, raw_data(bytes), u32(size), &n, false, true, &ctx) || n != u32(size) do return "", .Invalid_File
			// Validate the captured bytes too: the ACL may change after the
			// GetKernelObjectSecurity call and before BackupRead captures it.
			private_security(bytes) or_return
			security = digest(bytes)
			if security_image != nil {
				security_image^ = security_buffer(20+len(bytes)) or_return
				copy(security_image^[:20], header[:])
				copy(security_image^[20:], bytes)
			}
		case: return "", .Unsupported
		}
	}
	if security == "" do return "", .Unsupported
	return digest(transmute([]byte)fmt.tprintf("%s/%s/%d", sd, security, info.dwFileAttributes)), nil
}

@(private)
copy_metadata :: proc(src, dst: ^os.File) -> (err: os.Error) {
	security: []byte
	a := metadata(src, &security) or_return
	write_private_security(dst, security) or_return
	b := metadata(dst) or_return
	if a != b do return .Unsupported
	return
}

@(private)
write_private_security :: proc(dst: ^os.File, security: []byte) -> (err: os.Error) {
	if len(security) < 40 || (^u32le)(&security[0])^ != 3 ||
	   u64((^u64le)(&security[8])^) != u64(len(security)-20) || (^u32le)(&security[16])^ != 0 { return .Unsupported }
	// Never apply a captured descriptor until it has passed the privacy gate.
	private_security(security[20:]) or_return
	h := w.HANDLE(os.fd(dst))
	ctx: rawptr
	n: u32
	defer BackupWrite(h, nil, 0, &n, true, true, &ctx)
	if !BackupWrite(h, raw_data(security), u32(len(security)), &n, false, true, &ctx) do return native_error()
	if n != u32(len(security)) do return .Short_Write
	return
}

@(private)
directory_metadata :: proc(f: ^os.File) -> (signature: string, err: os.Error) {
	sd := security_text(w.HANDLE(os.fd(f)), w.OWNER_SECURITY_INFORMATION | w.GROUP_SECURITY_INFORMATION | w.DACL_SECURITY_INFORMATION | w.LABEL_SECURITY_INFORMATION) or_return
	return digest(transmute([]byte)sd), nil
}
