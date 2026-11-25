package storage

import "core:fmt"
import "core:os"

// A completed journal is first renamed out of recovery. Only this private
// directory can contain partially deleted operations after an interruption.
@(private)
detached_prunes :: proc(
	a: ^Recovery_Audit,
	requested: []string,
) -> (
	ids: []string,
	issue: string,
) {
	context.allocator = context.temp_allocator
	stage, err := open_dir(child(a.root, ".kadai/pruning"), private_leaf = true)
	if err == os.General_Error.Not_Exist do return
	if err != nil do return nil, os.error_string(err)
	defer close_dir(&stage)
	entries, list_err := prune_entries(&stage, requested, &a.entries)
	if list_err != nil do return nil, os.error_string(list_err)
	if len(entries) == 0 do return
	recovery, vault_err := open_dir(child(a.root, ".kadai/recovery"), private_leaf = true)
	if vault_err != nil && vault_err != .Not_Exist do return nil, os.error_string(vault_err)
	defer close_dir(&recovery)
	detached, alloc_err := make([]string, len(entries))
	if alloc_err != nil do return nil, "cannot allocate detached operation list"
	for fi, i in entries {
		if fi.type != .Directory || !valid_token(fi.name) do return nil, fmt.tprintf("unexpected entry in %s: %s", stage.path, fi.name)
		// A detached operation cannot also be live, even if its age or
		// completion state would exclude it from the current selection.
		if recovery.file != nil {
			live := child(recovery.path, fi.name)
			_, live_err := os.lstat(live, context.temp_allocator)
			if live_err == nil do return nil, fmt.tprintf("operation exists in both recovery and pruning: %s", fi.name)
			if live_err != os.General_Error.Not_Exist do return nil, fmt.tprintf("%s: %s", live, os.error_string(live_err))
		}
		if e := clean_detached(&stage, fi.name, a, false, nil); e != nil do return nil, fmt.tprintf("inspecting detached operation %s: %s", fi.name, os.error_string(e))
		detached[i] = fi.name
	}
	return detached, ""
}

@(private)
clean_detached :: proc(
	stage: ^Directory,
	id: string,
	a: ^Recovery_Audit,
	apply: bool,
	started: ^bool,
) -> (
	err: os.Error,
) {
	if !valid_token(id) do return .Invalid_Path
	{
		op := open_dir(child(stage.path, id), private_leaf = true) or_return
		defer close_dir(&op)
		files := state_entries(&op, &a.entries) or_return
		terminal := ""
		has_plan := false
		for fi in files {
			if fi.type != .Regular do return .Invalid_File
			if fi.name == "rolled-back" || fi.name == "committed" && terminal == "" do terminal = fi.name
			if fi.name == "plan" do has_plan = true
		}
		if len(files) > 0 {
			if terminal == "" || !has_plan && len(files) != 1 do return .Invalid_File
			receipt := control(&op, terminal, a.limits.record, &a.control_bytes) or_return
			if len(receipt) != 97 || receipt[:32] != id || receipt[32] != ' ' || !hex_digest(receipt[33:]) do return .Invalid_File
			if has_plan {
				plan := control(&op, "plan", a.limits.record, &a.control_bytes) or_return
				if pointer(id, plan) != receipt do return .Invalid_File
				steps := parse_audited_plan(plan, a.limits, &a.nodes) or_return
				for fi in files {
					expected := prune_entry_expected(
						&op,
						fi.name,
						steps,
						receipt,
						a.limits.record,
						&a.control_bytes,
					) or_return
					if !expected do return .Invalid_File
					if fi.name == terminal || fi.name == "plan" do continue
					if fi.name == "committed" || fi.name == "rollback" {
						other := control(&op, fi.name, a.limits.record, &a.control_bytes) or_return
						if other != receipt do return .Invalid_File
						continue
					}
					f := regular(&op, fi.name, mutation = true) or_return
					os.close(f)
				}
			}
		}
		if !apply do return nil
		if started != nil do started^ = true
		// Keep the manifest while removing images so retries can recognize
		// every remaining name. Keep the matching receipt until the end.
		for fi in files {
			if fi.name == "plan" || fi.name == terminal do continue
			remove_entry(&op, fi.name) or_return
		}
		if has_plan {
			sync_dir(&op) or_return
			remove_entry(&op, "plan") or_return
		}
		if terminal != "" {
			sync_dir(&op) or_return
			remove_entry(&op, terminal) or_return
			sync_dir(&op) or_return
		}
	}
	remove_empty_dir(stage, id) or_return
	return sync_dir(stage)
}

// The caller holds the writer locks from preflight through cleanup. A rename
// commits the prune decision before any unlink. Re-running prune also finishes
// decisions committed by an earlier process under the same locks.
@(private)
apply_prune :: proc(
	w: ^Writer,
	ids, detached: []string,
	l: Journal_Limits,
	started: ^bool,
) -> string {
	if !domain_held(w.domain) || w.collection == nil do return "prune requires the collection writer lock"
	if len(ids) == 0 && len(detached) == 0 do return ""
	recovery, err := open_dir(child(w.root, ".kadai/recovery"), private_leaf = true)
	if err != nil && (err != .Not_Exist || len(ids) > 0) do return os.error_string(err)
	defer close_dir(&recovery)
	stage, stage_err := open_dir(
		child(w.root, ".kadai/pruning"),
		create = len(ids) > 0,
		private_leaf = true,
		created = started,
	)
	if stage_err != nil do return os.error_string(stage_err)
	defer close_dir(&stage)

	audit := recovery_audit(w.root, l)
	if len(detached) > 0 {
		// A previous rename may have completed just before a failed sync.
		if e := sync_dir(&stage); e != nil do return os.error_string(e)
		if recovery.file != nil {
			if e := sync_dir(&recovery); e != nil do return os.error_string(e)
		}
	}
	for id in detached {
		if e := clean_detached(&stage, id, &audit, true, started); e != nil do return fmt.tprintf("cleaning detached operation %s: %s", id, os.error_string(e))
	}
	for id in ids {
		if !valid_token(id) do return "invalid prune operation ID"
		if e := publish(&recovery, id, &stage, id, false); e != nil do return fmt.tprintf("detaching operation %s: %s", id, os.error_string(e))
		if started != nil do started^ = true
		if e := sync_dir(&stage); e != nil do return os.error_string(e)
		if e := sync_dir(&recovery); e != nil do return os.error_string(e)
		if e := clean_detached(&stage, id, &audit, true, started); e != nil do return fmt.tprintf("cleaning detached operation %s: %s", id, os.error_string(e))
	}
	return ""
}
