package project

import "core:fmt"
import "core:os"
import "core:strings"
import "kadai:storage"

// Validate the entire path against the same discovery policy as scan. A
// directory rename has different membership predicates and is not a file move.
task_path :: proc(cfg: Config, relative: string, destination: bool) -> (path, issue: string) {
	if relative == "" || os.is_absolute_path(relative) || strings.has_suffix(relative, "/") ||
	   !strings.has_suffix(relative, ".md") { return "", "expected a collection-relative .md path" }
	parts := storage.slash(relative)
	dir := cfg.tasks
	rel := ""
	for name in strings.split_iterator(&parts, "/") {
		if !storage.component(name) do return "", "unsafe path component"
		if skip, err := boundary(cfg, dir); skip || err != nil do return "", fmt.tprintf("discovery boundary: %s", dir)
		path = storage.child(dir, name)
		rel = name if rel == "" else storage.child(rel, name)
		directory := parts != ""
		if excluded(cfg, rel, directory) do return "", fmt.tprintf("excluded task path: %s", rel)
		info, err := os.lstat(path, context.temp_allocator)
		if err != nil && err != os.General_Error.Not_Exist do return "", os.error_string(err)
		if directory {
			if err == nil {
				if info.type != .Directory do return "", fmt.tprintf("unsafe directory: %s", rel)
				actual, e := storage.physical(path, .Directory)
				if e != nil || actual != path do return "", fmt.tprintf("use physical directory spelling: %s", rel)
			}
			dir = path
		} else if destination {
			if err == nil do return "", fmt.tprintf("occupied destination: %s", rel)
		} else if err != nil || info.type != .Regular {
			return "", fmt.tprintf("missing or unsafe source: %s", rel)
		}
	}
	return
}
