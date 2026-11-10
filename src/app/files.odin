package app

import "core:os"
import "kadai:project"
import "kadai:storage"

// Filesystem step for an already validated and reserved creation. ID
// allocation and the public add operation belong to KAD-031.
@(private)
create_task_file :: proc(cfg: project.Config, relative: string, source: []byte) -> string {
	path, issue := project.task_path(cfg, relative, true)
	if issue != "" do return issue
	dir, err := storage.open_dir(storage.slash(os.dir(path)), create = true)
	if err != nil do return os.error_string(err)
	defer storage.close_dir(&dir)
	return os.error_string(storage.create_file(&dir, os.base(path), source))
}

@(private)
move_task_file :: proc(view: ^Collection, id, relative: string) -> string {
	group, status := project.lookup(&view.index, id)
	if status != .Valid do return "move requires a unique valid task"
	item := group[0]
	src, issue := project.task_path(view.config, item.path, false)
	if issue != "" do return issue
	dst, problem := project.task_path(view.config, relative, true)
	if problem != "" do return problem
	return os.error_string(storage.move_file(src, dst, item.info))
}
