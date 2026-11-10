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
Marker_Scan :: struct {
	h: ^History,
	entries: int,
	bytes: i64,
	audit: storage.State_Audit,
}

@(private)
read_level :: proc(scan: ^Marker_Scan, path: string, depth: int) {
	d, e := storage.open_dir(path)
	if e == os.General_Error.Not_Exist && depth == 0 do return
	if e != nil {
		storage.state_problem(&scan.audit, path, "history_incomplete", os.error_string(e), true)
		return
	}
	defer storage.close_dir(&d)
	items, err := storage.state_entries(&d, &scan.entries)
	if err != nil {
		message := "history filesystem_entries limit exceeded" if err == .Short_Buffer else os.error_string(err)
		storage.state_problem(&scan.audit, path, "history_incomplete", message, true)
		return
	}
	for fi in items {
		file := storage.child(path, fi.name)
		if depth < 2 {
			expected := fi.name == "v1" if depth == 0 else hex_pair(fi.name)
			if !expected || fi.type != .Directory {
				storage.state_problem(&scan.audit, file, "invalid_used_id_directory", "Unexpected history version, shard or file type.")
			} else { read_level(scan, file, depth+1) }
			continue
		}
		if fi.type != .Regular || len(fi.name) != 67 || !strings.has_suffix(fi.name, ".id") {
			storage.state_problem(&scan.audit, file, "corrupt_used_id_marker", "Invalid marker name or file type.")
			continue
		}
		f, open_err := storage.regular(&d, fi.name, mutation = true)
		if open_err != nil {
			storage.state_problem(&scan.audit, file, "history_incomplete", os.error_string(open_err), true)
			continue
		}
		data, read_err := storage.read_bounded(f, int(min(i64(scan.h.record_limit), scan.bytes)))
		os.close(f)
		if read_err != nil {
			reason := os.error_string(read_err)
			if read_err == .Short_Buffer { reason = "used-ID marker exceeds document or aggregate byte limit" }
			storage.state_problem(&scan.audit, file, "history_incomplete", reason, true)
			continue
		}
		scan.bytes -= i64(len(data))
		src := string(data)
		key := strings.trim_suffix(strings.trim_prefix(src, HEADER), "\n")
		if !strings.has_prefix(src, HEADER) || !strings.has_suffix(src, "\n") || !task.valid_id(key) ||
		   strings.to_lower(key) != key || storage.digest(transmute([]byte)key) != fi.name[:64] || os.base(path) != fi.name[:2] {
			storage.state_problem(&scan.audit, file, "corrupt_used_id_marker", "Marker contents or digest do not match its path.")
			continue
		}
		if _, insert_err := map_insert(&scan.h.recorded, key, true); insert_err != nil {
			storage.state_problem(&scan.audit, file, "history_incomplete", "history allocation failed", true)
			return
		}
	}
}

inspect :: proc(root: string, record_limit, entry_limit: int, byte_limit: i64) -> (h: History, audit: storage.State_Audit) {
	context.allocator = context.temp_allocator
	h = {root = storage.child(root, ".kadai/used-ids"), record_limit = record_limit}
	scan := Marker_Scan{h = &h, entries = entry_limit, bytes = byte_limit}
	read_level(&scan, h.root, 0)
	return h, scan.audit
}

load :: proc(root: string, record_limit, entry_limit: int, byte_limit: i64) -> (History, string) {
	h, audit := inspect(root, record_limit, entry_limit, byte_limit)
	if len(audit.problems) != 0 {
		p := audit.problems[0]
		return {}, fmt.tprintf("%s: %s: %s", p.path, p.code, p.message)
	}
	if audit.incomplete do return {}, "used-ID history inspection incomplete"
	return h, ""
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
