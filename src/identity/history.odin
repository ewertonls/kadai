// Collection-local, durable ID reservations. All returned data uses invocation scratch storage.
package identity

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "kadai:storage"
import "kadai:task"

HEADER :: "kadai-used-id-v1\n"
History :: struct {
	root: string,
	recorded: map[string]bool,
	pending: [dynamic]string,
	record_limit: int,
}

@(private)
hex_pair :: proc(name: string) -> bool {
	if len(name) != 2 do return false
	for c in name {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') do return false
	}
	return true
}

@(private)
read_level :: proc(h: ^History, path: string, depth: int, entries: ^int, bytes: ^i64) -> string {
	d, e := storage.open_dir(path)
	if e == os.General_Error.Not_Exist && depth == 0 do return ""
	if e != nil do return fmt.tprintf("%s: %s", path, os.error_string(e))
	defer storage.close_dir(&d)
	it := os.read_directory_iterator_create(d.file)
	defer os.read_directory_iterator_destroy(&it)
	for fi in os.read_directory_iterator(&it) {
		if _, err := os.read_directory_iterator_error(&it); err != nil do break
		file := storage.child(path, fi.name)
		if entries^ == 0 do return fmt.tprintf("%s: history filesystem_entries limit exceeded", path)
		entries^ -= 1
		if depth < 2 {
			expected := fi.name == "v1" if depth == 0 else hex_pair(fi.name)
			if !expected || fi.type != .Directory do return fmt.tprintf("%s: invalid used-ID directory", file)
			if problem := read_level(h, file, depth+1, entries, bytes); problem != "" do return problem
			continue
		}
		if fi.type != .Regular || len(fi.name) != 67 || !strings.has_suffix(fi.name, ".id") {
			return fmt.tprintf("%s: invalid used-ID marker", file)
		}
		f, open_err := storage.regular(&d, fi.name, mutation = true)
		if open_err != nil do return fmt.tprintf("%s: %s", file, os.error_string(open_err))
		data, read_err := storage.read_bounded(f, int(min(i64(h.record_limit), bytes^)))
		os.close(f)
		if read_err != nil do return fmt.tprintf("%s: incomplete used-ID history (%s)", file, os.error_string(read_err))
		bytes^ -= i64(len(data))
		src := string(data)
		key := strings.trim_suffix(strings.trim_prefix(src, HEADER), "\n")
		if !strings.has_prefix(src, HEADER) || !strings.has_suffix(src, "\n") || !task.valid_id(key) ||
		   strings.to_lower(key) != key || storage.digest(transmute([]byte)key) != fi.name[:64] ||
		   os.base(path) != fi.name[:2] { return fmt.tprintf("%s: corrupt used-ID marker", file) }
		if _, err := map_insert(&h.recorded, key, true); err != nil do return "history allocation failed"
	}
	if bad, err := os.read_directory_iterator_error(&it); err != nil do return fmt.tprintf("%s: %s", bad, os.error_string(err))
	return ""
}

load :: proc(root: string, record_limit, entry_limit: int, byte_limit: i64) -> (h: History, issue: string) {
	context.allocator = context.temp_allocator
	h = {root = storage.child(root, ".kadai/used-ids"), record_limit = record_limit}
	entries, bytes := entry_limit, byte_limit
	issue = read_level(&h, h.root, 0, &entries, &bytes)
	return
}

// Queue observation in memory. Persistence starts only after full preflight.
observe :: proc(h: ^History, id: string) -> string {
	context.allocator = context.temp_allocator
	key := strings.to_lower(id)
	if !task.valid_id(key) || len(key) != len(id) do return "invalid ID for observation"
	if key in h.recorded do return ""
	if len(key) > h.record_limit-len(HEADER)-1 do return "used-ID marker exceeds record limit"
	if _, err := map_insert(&h.recorded, key, true); err != nil do return "ID observation allocation failed"
	if _, err := append(&h.pending, key); err != nil do return "ID observation allocation failed"
	return ""
}

persist :: proc(h: ^History) -> string {
	slice.sort(h.pending[:])
	for key, i in h.pending {
		hash := storage.digest(transmute([]byte)key)
		if len(hash) != 64 do return "cannot compute used-ID digest"
		dir, err := storage.open_dir(storage.child(storage.child(h.root, "v1"), hash[:2]), create = true)
		if err == nil {
			defer storage.close_dir(&dir)
			text := fmt.tprintf("%s%s\n", HEADER, key)
			err = storage.create_file(&dir, fmt.tprintf("%s.id", hash), transmute([]byte)text)
		}
		if err != nil do return fmt.tprintf("recording ID %s after %d markers: %s", key, i, os.error_string(err))
	}
	return ""
}
