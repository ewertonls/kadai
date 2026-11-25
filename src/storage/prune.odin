package storage

import "core:fmt"
import "core:os"
import "core:slice"

// A named batch probes only its own directories, even when the whole vault
// exceeds the entry budget. A retry can include IDs already pruned.
@(private)
prune_entries :: proc(
	dir: ^Directory,
	requested: []string,
	remaining: ^int,
) -> (
	items: [dynamic]os.File_Info,
	err: os.Error,
) {
	if len(requested) == 0 do return state_entries(dir, remaining)
	context.allocator = context.temp_allocator
	for id in requested {
		info, stat_err := os.lstat(child(dir.path, id), context.temp_allocator)
		if stat_err == os.General_Error.Not_Exist do continue
		if stat_err != nil do return nil, stat_err
		if remaining^ <= 0 do return nil, .Short_Buffer
		remaining^ -= 1
		info.name = id
		_ = append(&items, info) or_return
	}
	return
}

prune :: proc(
	w: ^Writer,
	root: string,
	cutoff: i128,
	dry_run: bool,
	l: Journal_Limits,
	started: ^bool = nil,
	requested: []string = nil,
) -> (
	ids: []string,
	issue: string,
) {
	if len(requested) > l.entries do return nil, "operation batch exceeds filesystem_entries limit"
	batch, alloc_err := slice.clone(requested, context.temp_allocator)
	if alloc_err != nil do return nil, "cannot allocate recovery prune batch"
	slice.sort(batch)
	for id, i in batch {
		if !valid_token(id) do return nil, fmt.tprintf("invalid recovery operation ID: %q", id)
		if i > 0 && id == batch[i - 1] do return nil, fmt.tprintf("duplicate recovery operation ID: %s", id)
	}
	if issue = check_pending(w, root, l.entries); issue != "" do return
	audit := recovery_audit(root, l)
	detached, detached_issue := detached_prunes(&audit, batch)
	if detached_issue != "" do return nil, detached_issue
	candidates, plan_issue := plan_prune(&audit, cutoff, batch)
	if plan_issue != "" do return nil, plan_issue
	ids = candidates
	if len(detached) > 0 {
		all, err := make([]string, len(candidates) + len(detached), context.temp_allocator)
		if err != nil do return nil, "cannot allocate recovery prune plan"
		ids = all
		copy(ids, candidates)
		copy(ids[len(candidates):], detached)
		slice.sort(ids)
	}
	// The domain lock protects selection through removal. Only an actual removal
	// needs the collection lock, which could create writer.lock in an empty checkout.
	if dry_run || len(ids) == 0 do return
	if err := lock_collection(w, root); err != nil do return nil, os.error_string(err)
	if issue = apply_prune(w, candidates, detached, l, started); issue != "" do return nil, issue
	return
}
