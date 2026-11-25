package storage

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

@(private)
prune_entry_expected :: proc(
	op: ^Directory,
	name: string,
	steps: []Step,
	receipt: string,
	record_limit: int,
	budget: ^i64,
) -> (
	expected: bool,
	err: os.Error,
) {
	switch name {
	case "plan", "committed", "rollback", "rolled-back":
		return true, nil
	}
	// An interruption can leave any prefix of the receipt in its temporary file.
	if strings.has_prefix(name, STAGE_PREFIX) {
		if !valid_token(name[len(STAGE_PREFIX):]) do return false, nil
		staged := control(op, name, min(record_limit, len(receipt)), budget) or_return
		return strings.has_prefix(receipt, staged), nil
	}
	if len(steps) == 1 && steps[0].kind == .Move_Directory {
		return strings.has_prefix(name, "original-") && hex_digest(name[len("original-"):]), nil
	}
	dash := strings.index_byte(name, '-')
	if dash <= 0 do return false, nil
	slot, ok := strconv.parse_uint(name[:dash], 10)
	if !ok || slot >= uint(len(steps)) do return false, nil
	suffix := name[dash + 1:]
	if name != image_name(int(slot), suffix) do return false, nil
	kind := steps[slot].kind
	switch suffix {
	case "original":
		return kind != .Create, nil
	case "restore":
		return kind == .Delete || kind == .Replace, nil
	case "next":
		return kind == .Create || kind == .Replace, nil
	}
	return false, nil
}

@(private)
prune_receipt_old :: proc(op: ^Directory, cutoff: i128) -> (eligible: bool, err: os.Error) {
	// An explicit rollback after commit leaves both receipts. The rollback
	// receipt dates the most recent completion of that operation.
	for name in ([]string{"rolled-back", "committed"}) {
		f, open_err := regular(op, name, mutation = true)
		if open_err == os.General_Error.Not_Exist do continue
		if open_err != nil do return false, open_err
		defer os.close(f)
		info := file_info(f) or_return
		return i128(time.to_unix_nanoseconds(info.modification_time)) <= cutoff, nil
	}
	return
}

// Called under writer coordination after checking for pending operations.
// Validate every candidate before returning any IDs to the deletion phase.
@(private)
plan_prune :: proc(
	a: ^Recovery_Audit,
	cutoff: i128,
	requested: []string,
) -> (
	ids: []string,
	issue: string,
) {
	context.allocator = context.temp_allocator
	path := child(a.root, ".kadai/recovery")
	vault, err := open_dir(path, private_leaf = true)
	if err == os.General_Error.Not_Exist do return
	if err != nil do return nil, fmt.tprintf("%s: %s", path, os.error_string(err))
	defer close_dir(&vault)
	entries, scan_err := prune_entries(&vault, requested, &a.entries)
	if scan_err != nil do return nil, fmt.tprintf("%s: incomplete recovery scan: %s", path, os.error_string(scan_err))
	selected: [dynamic]string
	for entry in entries {
		dir_path := child(path, entry.name)
		if entry.type != .Directory || !valid_token(entry.name) do return nil, fmt.tprintf("%s: invalid recovery directory", dir_path)
		op, open_err := open_dir(dir_path, private_leaf = true)
		if open_err != nil do return nil, fmt.tprintf("%s: %s", dir_path, os.error_string(open_err))
		defer close_dir(&op)
		eligible, receipt_err := prune_receipt_old(&op, cutoff)
		if receipt_err != nil do return nil, fmt.tprintf("%s: checking completion receipt: %s", dir_path, os.error_string(receipt_err))
		if !eligible do continue
		audit_operation(a, &op, entry.name, nil, pruning = true)
		if len(a.problems) > 0 {
			p := a.problems[0]
			return nil, fmt.tprintf("%s: %s: %s", p.path, p.code, p.message)
		}
		if a.incomplete do return nil, fmt.tprintf("%s: incomplete recovery check", dir_path)
		if _, e := append(&selected, entry.name); e != nil do return nil, "cannot allocate recovery prune plan"
	}
	return selected[:], ""
}
