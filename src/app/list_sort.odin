package app

import "core:slice"
import "kadai:project"
import "kadai:task"

// Enum names are also the command-line spellings.
List_Sort_Key :: enum {
	path,
	id,
	title,
	status,
	priority,
}
List_Order    :: enum {
	asc,
	desc,
}
List_Sort     :: struct {
	key  : List_Sort_Key,
	order: List_Order,
}

@(private)
sort_list_items :: proc(
	items: []^project.Candidate,
	sort: List_Sort,
	vocab: task.Vocabulary,
) -> string {
	if len(items) < 2 do return ""
	// The filtered index already follows ascending path order.
	if sort.key == .path {
		if sort.order == .desc do slice.reverse(items)
		return ""
	}
	Sort_Context :: struct {
		sort : List_Sort,
		ranks: map[string]int,
	}
	state := Sort_Context {
		sort = sort,
	}
	if sort.key == .priority {
		names := task.priority_order(vocab)
		ranks, err := make(map[string]int, len(names), context.temp_allocator)
		if err != nil do return "cannot allocate priority ranks"
		for name, rank in names {
			if _, insert_err := map_insert(&ranks, name, rank); insert_err != nil do return "cannot allocate priority ranks"
		}
		state.ranks = ranks
	}
	slice.sort_by_cmp_with_data(items, proc(a, b: ^project.Candidate, data: rawptr) -> slice.Ordering {
			state := (^Sort_Context)(data)
			primary: slice.Ordering
			switch state.sort.key {
			case .path:
				unreachable()
			case .id:
				primary = slice.cmp(a.fields.id, b.fields.id)
			case .title:
				primary = slice.cmp(a.fields.title, b.fields.title)
			case .status:
				primary = slice.cmp(a.fields.status, b.fields.status)
			case .priority:
				missing_a, missing_b := a.fields.priority == "", b.fields.priority == ""
				if missing_a != missing_b do return .Greater if missing_a else .Less
				primary = slice.cmp(state.ranks[a.fields.priority], state.ranks[b.fields.priority])
			}
			if primary == .Equal do return slice.cmp(a.path, b.path)
			if state.sort.order == .desc do return slice.Ordering(-int(primary))
			return primary
		}, &state)
	return ""
}
