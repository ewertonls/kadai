package storage

import "core:fmt"
import "core:os"
import "core:strings"

@(private)
safe_collection :: proc(root: string) -> bool {
	if !os.is_absolute_path(root) do return false
	parts := slash(root)
	for part in strings.split_iterator(&parts, "/") {
		if part == ".kadai" || part == ".git" do return false
	}
	return true
}

@(private)
pending_at :: proc(root: string) -> (found: bool, err: os.Error) {
	// Probe the marker through real directory handles. A link or corrupt
	// state cannot serve as evidence of absence.
	state, e := open_dir(child(root, ".kadai"))
	if e == os.General_Error.Not_Exist do return false, nil
	if e != nil do return false, e
	defer close_dir(&state)
	for name in ([]string{"pending", "intent"}) {
		f, open_err := regular(&state, name, mutation = true)
		if open_err == os.General_Error.Not_Exist do continue
		if open_err != nil do return false, open_err
		os.close(f)
		return true, nil
	}
	return
}

// An enclosing journal or one in any descendant collection can protect the
// same namespace. Discovery exclusions cannot hide pending writer state.
check_pending :: proc(w: ^Writer, root: string, entry_limit: int, allow_own := false) -> string {
	if !domain_held(w.domain) || !safe_collection(root) do return "invalid writer domain"
	check :: proc(path: string) -> string {
		pending, err := pending_at(path)
		if err != nil do return fmt.tprintf("%s: %s", path, os.error_string(err))
		if pending do return fmt.tprintf("pending operation in %s", path)
		return ""
	}
	ancestor := root
	for {
		if !allow_own || ancestor != root {
			if issue := check(ancestor); issue != "" do return issue
		}
		parent := slash(os.dir(ancestor))
		if parent == ancestor || parent == "" || parent == "." do break
		ancestor = parent
	}
	stack := make([dynamic]string, context.temp_allocator)
	append(&stack, root)
	entries := 0
	for len(stack) > 0 {
		path := pop(&stack)
		d, e := open_dir(path)
		if e == os.General_Error.Not_Exist && path == root do continue
		if e != nil do return fmt.tprintf("%s: %s", path, os.error_string(e))
		// Scoped iteration releases the directory before opening the next.
		{
			defer close_dir(&d)
			it := os.read_directory_iterator_create(d.file)
			defer os.read_directory_iterator_destroy(&it)
			for fi in os.read_directory_iterator(&it) {
				if _, scan_err := os.read_directory_iterator_error(&it); scan_err != nil do break
				entries += 1
				if entries > entry_limit do return fmt.tprintf("%s: incomplete pending-operation check (filesystem_entries)", path)
				if fi.type != .Directory || fi.name == ".git" || fi.name == ".kadai" do continue
				sub := child(path, fi.name)
				if issue := check(sub); issue != "" do return issue
				if _, err := append(&stack, sub); err != nil do return "pending-operation check allocation failed"
			}
			if bad, err := os.read_directory_iterator_error(&it); err != nil do return fmt.tprintf("%s: %s", bad, os.error_string(err))
		}
	}
	return ""
}
