package project

import "base:runtime"
import "core:strings"
import "kadai:task"

Lookup_Status :: enum {Missing, Valid, Diagnostic_Only, Ambiguous, Incomplete}

Index :: struct {
	using inventory: Inventory,
	by_id: map[string][dynamic]^Candidate,
	valid: [dynamic]^Candidate,
	collisions: [dynamic][]^Candidate, // Groups and their members are in path order.
}

// Build only from complete enumeration. Keep every recognized document in the
// inventory, including malformed documents that have no verified ID.
build_index :: proc(inv: Inventory) -> (idx: Index) {
	context.allocator = context.temp_allocator
	idx.inventory = inv
	if !inv.complete do return
	if fill_index(&idx) != nil {
		idx = Index{inventory = inv}
		idx.complete, idx.problem = false, "index allocation failed"
	}
	return
}

@(private)
fill_index :: proc(idx: ^Index) -> (err: runtime.Allocator_Error) {
	for &item in idx.candidates {
		if item.fields.id == "" do continue
		key := strings.to_lower(item.fields.id) or_return
		if len(key) != len(item.fields.id) do return .Out_Of_Memory
		group := idx.by_id[key]
		_ = append(&group, &item) or_return
		_ = map_insert(&idx.by_id, key, group) or_return
	}
	for &item in idx.candidates {
		if item.fields.id == "" do continue
		key := strings.to_lower(item.fields.id) or_return
		group := idx.by_id[key]
		if len(group) == 0 do return .Out_Of_Memory
		if len(group) > 1 {
			if group[0] == &item { _ = append(&idx.collisions, group[:]) or_return }
		} else if item.status == .Decoded {
			_ = append(&idx.valid, &item) or_return
		}
	}
	return
}

lookup :: proc(idx: ^Index, id: string) -> ([]^Candidate, Lookup_Status) {
	if !idx.complete do return nil, .Incomplete
	if !task.valid_id(id) do return nil, .Missing
	key, err := strings.to_lower(id, context.temp_allocator)
	if err != nil || len(key) != len(id) do return nil, .Incomplete
	group := idx.by_id[key]
	switch len(group) {
	case 0: return nil, .Missing
	case 1: return group[:], .Valid if group[0].status == .Decoded else .Diagnostic_Only
	}
	return group[:], .Ambiguous
}
