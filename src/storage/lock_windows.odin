package storage

import "core:os"
import "core:sync"
import w "core:sys/windows"

foreign import lib "system:kernel32.lib"
foreign lib {
	CreateMutexW :: proc "system"(sa: ^w.SECURITY_ATTRIBUTES, own: w.BOOL, name: w.LPCWSTR) -> w.HANDLE ---
	ReleaseMutex :: proc "system"(mutex: w.HANDLE) -> w.BOOL ---
}

Domain_Lock :: struct { handle: w.HANDLE }
domain_held :: proc(d: Domain_Lock) -> bool { return d.handle != nil }
@(private) local_domain: sync.Mutex

@(private)
try_domain :: proc() -> (d: Domain_Lock, err: os.Error) {
	if !sync.mutex_try_lock(&local_domain) do return {}, .Timeout
	defer if err != nil { sync.mutex_unlock(&local_domain) }
	h := CreateMutexW(nil, false, wide("Global\\Kadai.CollectionWriter.v1"))
	if h == nil do return {}, native_error()
	defer if err != nil { w.CloseHandle(h) }
	result := w.WaitForSingleObject(h, 0)
	if result == w.WAIT_TIMEOUT do return {}, .Timeout
	if result != w.WAIT_OBJECT_0 && result != 0x80 do return {}, native_error() // WAIT_ABANDONED
	return {h}, nil
}

@(private)
lock_file :: proc(f: ^os.File) -> os.Error {
	ov: w.OVERLAPPED
	if !w.LockFileEx(w.HANDLE(os.fd(f)), w.LOCKFILE_EXCLUSIVE_LOCK | w.LOCKFILE_FAIL_IMMEDIATELY, 0, 1, 0, &ov) do return native_error()
	return nil
}

@(private)
release_domain :: proc(d: ^Domain_Lock) {
	if d.handle != nil {
		ReleaseMutex(d.handle)
		w.CloseHandle(d.handle)
		sync.mutex_unlock(&local_domain)
	}
	d^ = {}
}
