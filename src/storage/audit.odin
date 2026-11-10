package storage

import "core:os"
import "core:slice"

State_Problem :: struct {path, code, message: string, warning: bool}
State_Audit :: struct {
	problems: [dynamic]State_Problem,
	incomplete: bool, // A read, resource or allocation failure prevented a complete examination.
	dropped_problem: bool,
}

state_problem :: proc(a: ^State_Audit, path, code, message: string, incomplete := false, warning := false) {
	context.allocator = context.temp_allocator
	a.incomplete = a.incomplete || incomplete
	if _, e := append(&a.problems, State_Problem{path, code, message, warning}); e != nil {
		a.incomplete, a.dropped_problem = true, true
	}
}

// Enumerate without following links. Bound the collection before sorting it.
state_entries :: proc(dir: ^Directory, remaining: ^int) -> (items: [dynamic]os.File_Info, err: os.Error) {
	context.allocator = context.temp_allocator
	it := os.read_directory_iterator_create(dir.file)
	defer os.read_directory_iterator_destroy(&it)
	for fi in os.read_directory_iterator(&it) {
		_ = os.read_directory_iterator_error(&it) or_return
		if remaining^ <= 0 do return nil, .Short_Buffer
		remaining^ -= 1
		copy := os.file_info_clone(fi, context.temp_allocator) or_return
		_ = append(&items, copy) or_return
	}
	_ = os.read_directory_iterator_error(&it) or_return
	slice.sort_by(items[:], proc(a,b: os.File_Info) -> bool { return a.name < b.name })
	return
}
