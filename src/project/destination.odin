package project

import "core:fmt"
import "core:os"
import "core:strings"
import "kadai:storage"

// Validate the entire path against the same discovery policy as scan. A
// directory rename also checks membership for every descendant.
task_path :: proc(cfg: Config, relative: string, destination: bool, is_directory := false, shared_budget: ^Glob_Budget = nil) -> (path, issue: string) {
	local_budget := Glob_Budget{limit = DEFAULT_SCAN_LIMITS.exclude_match_steps}
	budget := shared_budget if shared_budget != nil else &local_budget
	if relative == "" || os.is_absolute_path(relative) || strings.has_suffix(relative, "/") ||
	   !is_directory && !strings.has_suffix(relative, ".md") { return "", "expected a collection-relative task path" }
	parts := storage.slash(relative)
	dir := cfg.tasks
	rel := ""
	for name in strings.split_iterator(&parts, "/") {
		if !storage.component(name) do return "", "unsafe path component"
		if skip, err := boundary(cfg, dir); skip || err != nil do return "", fmt.tprintf("discovery boundary: %s", dir)
		path = storage.child(dir, name)
		rel = name if rel == "" else storage.child(rel, name)
		directory := parts != ""
		// Creating this directory would make its parent a project boundary
		// before the final destination can be rechecked.
		if (directory || is_directory) && strings.equal_fold(name, ".kadai.yaml") {
			return "", fmt.tprintf("reserved project marker: %s", rel)
		}
		skip, exclusion_issue := excluded(cfg, rel, directory || is_directory, budget)
		if exclusion_issue != "" do return "", exclusion_issue
		if skip do return "", fmt.tprintf("excluded task path: %s", rel)
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
		} else if err != nil || info.type != (.Directory if is_directory else .Regular) {
			return "", fmt.tprintf("missing or unsafe source: %s", rel)
		}
	}
	return
}

// Compare membership on both sides of a directory rename, including empty
// directories. Refuse a tree crossing an exclusion or a nested project.
tree_destination :: proc(cfg: Config, src, dst: string, members: []storage.Tree_Entry, shared_budget: ^Glob_Budget = nil) -> string {
	local_budget := Glob_Budget{limit = DEFAULT_SCAN_LIMITS.exclude_match_steps}
	budget := shared_budget if shared_budget != nil else &local_budget
	for entry in members {
		for root in ([2]string{src, dst}) {
			path := root if entry.path == "" else storage.child(root, entry.path)
			skip, exclusion_issue := excluded(cfg, path, entry.directory, budget)
			if exclusion_issue != "" do return exclusion_issue
			if skip do return fmt.tprintf("excluded path in directory move: %s", path)
			if entry.directory {
				if root == src {
					at_boundary, e := boundary(cfg, storage.child(cfg.tasks, path))
					if at_boundary || e != nil do return fmt.tprintf("discovery boundary in directory move: %s", path)
				} else if strings.equal_fold(storage.child(cfg.tasks, path), cfg.boards) ||
				          strings.equal_fold(os.base(path), ".kadai") || strings.equal_fold(os.base(path), ".git") {
					return fmt.tprintf("reserved directory destination: %s", path)
				}
			}
		}
	}
	return ""
}
