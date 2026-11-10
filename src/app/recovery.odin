package app

import "core:fmt"
import "core:strings"
import "kadai:document"
import "kadai:project"
import "kadai:storage"

@(private)
check_recovery_membership :: proc(effects: []storage.Recovery_Effect, data: rawptr) -> string {
	context.allocator = context.temp_allocator
	view := (^Collection)(data)
	inv := project.scan(view.config, view.limits)
	if !inv.complete do return inv.problem
	remaining := make(map[string]^project.Candidate, len(inv.candidates))
	for &item in inv.candidates do remaining[item.path] = &item
	removed, restored: map[string]bool
	for effect in effects {
		item := remaining[effect.path]
		if _, issue := project.task_path(view.config, effect.path, item == nil); issue != "" do return issue
		if effect.remove {
			if item == nil || item.fields.id == "" do return fmt.tprintf("%s: unknown recovery target", effect.path)
			removed[strings.to_lower(item.fields.id)] = true
			delete_key(&remaining, effect.path)
			continue
		}
		doc := document.decode_task(string(effect.source), view.config.vocabulary, view.limits.source_bytes, view.limits.yaml, effect.path)
		if doc.status != .Decoded && doc.status != .Invalid_Fields || doc.fields.id == "" do return fmt.tprintf("%s: unknown recovery ID", effect.path)
		if item == nil {
			restored[strings.to_lower(doc.fields.id)] = true
		} else if !strings.equal_fold(item.fields.id, doc.fields.id) { return "unexpected identity change in recovery" }
		replacement := new(project.Candidate)
		replacement^ = {path = effect.path, status = doc.status, fields = doc.fields, diagnostics = doc.diagnostics[:]}
		remaining[effect.path] = replacement
	}
	counts: map[string]int
	for _, item in remaining {
		if len(restored) > 0 && item.fields.id == "" do return fmt.tprintf("%s: cannot prove restored ID uniqueness", item.path)
		key := strings.to_lower(item.fields.id)
		if key in restored {
			counts[key] += 1
			if counts[key] > 1 do return fmt.tprintf("%s: restored ID %s already exists", item.path, item.fields.id)
		}
		if len(removed) == 0 do continue
		if !references_known(item) do return fmt.tprintf("%s: cannot verify inbound references during recovery", item.path)
		if strings.to_lower(item.fields.parent) in removed do return fmt.tprintf("%s: recovery would leave a missing parent", item.path)
		for dep in item.fields.depends_on {
			if strings.to_lower(dep) in removed do return fmt.tprintf("%s: recovery would leave a missing prerequisite", item.path)
		}
	}
	return ""
}
