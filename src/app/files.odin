package app

import "core:fmt"
import "core:os"
import "kadai:project"
import "kadai:identity"
import "kadai:storage"

// The planner runs under writer coordination and sees a freshly built index.
// The planner queues generated IDs before returning collection-relative changes.
Plan_Changes :: proc(view: ^Collection, data: rawptr) -> ([]storage.Change, string)

@(private)
journal_limits :: proc(l: project.Scan_Limits) -> storage.Journal_Limits {
	return {l.source_bytes, l.yaml.bytes, l.yaml.nodes, l.yaml.depth, l.entries, l.total_bytes, l.total_nodes}
}

mutate_collection :: proc(cwd: string, options: Project_Options, plan: Plan_Changes, data: rawptr = nil, limits := project.DEFAULT_SCAN_LIMITS) -> (operation, issue: string) {
	if plan == nil || !project.valid_scan_limits(limits) do return "", "invalid writer options"
	w, e := storage.begin_writer()
	if e != nil do return "", fmt.tprintf("writer lock: %s", os.error_string(e))
	defer storage.end_writer(&w)
	view: Collection
	view.limits = limits
	view.config, issue = project.resolve(cwd, options, limits.yaml)
	if issue != "" do return
	root := view.config.tasks
	if issue = storage.check_pending(&w, root, limits.entries); issue != "" do return
	if e = storage.lock_collection(&w, root); e != nil do return "", os.error_string(e)
	view.index = project.build_index(project.scan(view.config, limits))
	if !view.index.complete do return "", view.index.problem
	view.history, issue = identity.load(root, limits.yaml.bytes, limits.entries, limits.total_bytes)
	if issue != "" do return
	for key in view.index.by_id {
		if issue = identity.observe(&view.history, key); issue != "" do return
	}
	changes: []storage.Change
	changes, issue = plan(&view, data)
	if issue != "" || len(changes) == 0 do return
	for c in changes {
		_, issue = project.task_path(view.config, c.path, c.kind == .Create)
		if issue != "" do return
		if c.kind == .Move {
			_, issue = project.task_path(view.config, c.destination, true)
			if issue != "" do return
		}
	}
	// A newly created directory can make a previously absent board root
	// resolve to this spelling on a case- or normalization-insensitive volume.
	created_parent := false
	for c in changes {
		if c.kind != .Move && c.kind != .Create do continue
		path := c.destination if c.kind == .Move else c.path
		parent := storage.slash(os.dir(storage.child(root, path)))
		_, stat_err := os.lstat(parent, context.temp_allocator)
		if stat_err == os.General_Error.Not_Exist {
			dir, open_err := storage.open_dir(parent, create = true)
			if open_err != nil do return "", os.error_string(open_err)
			storage.close_dir(&dir)
			created_parent = true
		} else if stat_err != nil { return "", os.error_string(stat_err) }
	}
	if created_parent {
		cfg, problem := project.resolve(cwd, options, limits.yaml)
		if problem != "" do return "", problem
		if cfg.tasks != root do return "", "collection changed during destination preparation"
		for c in changes {
			if c.kind != .Move && c.kind != .Create do continue
			dst := c.destination if c.kind == .Move else c.path
			_, issue = project.task_path(cfg, dst, true)
			if issue != "" do return
		}
	}
	record_ids :: proc(data: rawptr) -> string { return identity.persist((^identity.History)(data)) }
	return storage.commit(&w, changes, journal_limits(limits), record_ids, &view.history)
}

recover_collection :: proc(cwd: string, options: Project_Options, mode: storage.Recovery_Mode, operation := "", limits := project.DEFAULT_SCAN_LIMITS) -> (id, issue: string) {
	if !project.valid_scan_limits(limits) do return "", "invalid recovery limits"
	w, e := storage.begin_writer()
	if e != nil do return "", os.error_string(e)
	defer storage.end_writer(&w)
	cfg, problem := project.resolve(cwd, options, limits.yaml)
	if problem != "" do return "", problem
	if e = storage.lock_collection(&w, cfg.tasks); e != nil do return "", os.error_string(e)
	return storage.recover(&w, mode, operation, journal_limits(limits))
}
