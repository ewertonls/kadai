package project

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "kadai:storage"
import "kadai:yaml"

@(private)
initial_config :: proc(cfg: Config) -> string {
	b := strings.builder_make(context.temp_allocator)
	root := "." if cfg.tasks == cfg.project else cfg.tasks[len(storage.child(cfg.project, "")):]
	strings.write_string(&b, "schema_version: 1\n\ntasks:\n")
	if root == "tasks" {
		strings.write_string(&b, "  root: tasks\n")
	} else {
		fmt.sbprintf(&b, "  root: %q\n", root)
	}
	if len(cfg.exclude) != 0 {
		strings.write_string(&b, "  exclude:\n")
		for p in cfg.exclude do fmt.sbprintf(&b, "    - %q\n", p)
	}
	boards := cfg.boards[len(storage.child(cfg.tasks, "")):]
	if boards != "boards" do fmt.sbprintf(&b, "boards:\n  root: %q\n", boards)
	if cfg.id_prefix != "" do fmt.sbprintf(&b, "ids:\n  prefix: %q\n", cfg.id_prefix)
	if cfg.timezone != "" do fmt.sbprintf(&b, "timezone: %q\n", cfg.timezone)
	return strings.to_string(b)
}

initialize :: proc(
	cwd: string,
	options := Options{},
	limits := DEFAULT_SCAN_LIMITS,
) -> (
	cfg: Config,
	problem: string,
) {
	context.allocator = context.temp_allocator
	if !valid_scan_limits(limits) do return {}, "invalid scan limits"
	writer, lock_err := storage.begin_writer()
	if lock_err != nil do return {}, fmt.tprintf("writer lock: %s", os.error_string(lock_err))
	defer storage.end_writer(&writer)
	cfg, problem = resolve(cwd, options, limits.yaml)
	if problem != "" do return
	if problem = storage.check_pending(&writer, cfg.project, limits.entries); problem != "" do return
	started := write_progress(options)
	if cfg.existing {
		persisted, issue := resolve(cwd, Options{project = options.project}, limits.yaml)
		if issue != "" do return cfg, issue
		if cfg.tasks != persisted.tasks ||
		   cfg.boards != persisted.boards ||
		   cfg.id_prefix != persisted.id_prefix ||
		   cfg.timezone != persisted.timezone ||
		   !slice.equal(
				   cfg.exclude,
				   persisted.exclude,
			   ) {return cfg, "init options conflict with existing .kadai.yaml"}
	} else {
		source := initial_config(cfg)
		// Refuse a config that this invocation cannot read back, before creating it.
		if _, e := yaml.parse_mapping(source, limits.yaml); e != .None {
			return cfg, fmt.tprintf("initial config exceeds YAML limits: %v", e)
		}
		dir, e := storage.open_dir(cfg.project)
		if e != nil do return cfg, os.error_string(e)
		defer storage.close_dir(&dir)
		if e = storage.create_file(&dir, ".kadai.yaml", transmute([]byte)source, published = started); e != nil do return cfg, os.error_string(e)
	}
	dir, err := storage.open_dir(cfg.tasks, create = true, created = started)
	if err != nil do return cfg, os.error_string(err)
	storage.close_dir(&dir)
	return
}
