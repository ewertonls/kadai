package identity

import "core:fmt"
import "core:os"
import "core:strings"
import "kadai:storage"

// Compare and increment decimal strings without a machine-sized ID limit.
@(private)
increment :: proc(digits: string) -> string {
	buf := make([]byte, max(4, len(digits)+1), context.temp_allocator)
	for &b in buf do b = '0'
	copy(buf[len(buf)-len(digits):], digits)
	for i := len(buf)-1; i >= 0; i -= 1 {
		if buf[i] < '9' { buf[i] += 1; break }
		buf[i] = '0'
	}
	return string(buf[1:]) if len(buf) > 4 && buf[0] == '0' else string(buf)
}

allocate :: proc(h: ^History, prefix, root, explicit_path: string) -> (id, path, issue: string) {
	stem := "" if prefix == "" else fmt.tprintf("%s-", prefix)
	folded := strings.to_lower(stem, context.temp_allocator)
	largest := ""
	for key in h.recorded {
		if !strings.has_prefix(key, folded) do continue
		digits := key[len(folded):]
		if digits == "" || strings.trim_left(digits, "0123456789") != "" do continue
		digits = strings.trim_left(digits, "0")
		if len(digits) > len(largest) || len(digits) == len(largest) && digits > largest do largest = digits
	}
	for {
		largest = increment(largest)
		id = fmt.tprintf("%s%s", stem, largest)
		if explicit_path != "" do return id, explicit_path, ""
		path = fmt.tprintf("%s.md", id)
		_, err := os.lstat(storage.child(root, path), context.temp_allocator)
		if err == os.General_Error.Not_Exist do return id, path, ""
		if err != nil do return "", "", fmt.tprintf("%s: %s", path, os.error_string(err))
	}
}
