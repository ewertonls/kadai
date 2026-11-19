#+test
#+build windows
package project

import w "core:sys/windows"
import "core:testing"

// core:os.symlink is unsupported on Windows in the reference toolchain.
create_windows_test_symlink :: proc(t: ^testing.T, path, target: string, directory: bool) -> bool {
	flags := w.SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE
	if directory do flags |= w.SYMBOLIC_LINK_FLAG_DIRECTORY
	if w.CreateSymbolicLinkW(w.utf8_to_wstring(path), w.utf8_to_wstring(target), flags) do return true
	return testing.expectf(
		t,
		false,
		"CreateSymbolicLinkW(%s) failed: Win32 error %d",
		path,
		w.GetLastError(),
	)
}
