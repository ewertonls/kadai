package project

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "kadai:storage"

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

initialize :: proc(cwd: string, options := Options{}) -> (cfg: Config, problem: string) {
	context.allocator = context.temp_allocator
	cfg, problem = resolve(cwd, options)
	if problem != "" do return
	if cfg.existing {
		persisted, issue := resolve(cwd, Options{project = options.project})
		if issue != "" do return cfg, issue
		if cfg.tasks != persisted.tasks || cfg.boards != persisted.boards ||
		   cfg.id_prefix != persisted.id_prefix || cfg.timezone != persisted.timezone ||
		   !slice.equal(cfg.exclude, persisted.exclude) { return cfg, "init options conflict with existing .kadai.yaml" }
	} else {
		source := initial_config(cfg)
		path := storage.child(cfg.project, ".kadai.yaml")
		stage, e := os.create_temp_file(cfg.project, ".kadai-init-*")
		if e != nil do return cfg, os.error_string(e)
		staged := strings.clone(os.name(stage), context.temp_allocator)
		defer os.remove(staged)
		n, write_err := os.write(stage, transmute([]byte)source)
		if write_err == nil && n != len(source) do write_err = .Short_Write
		if write_err == nil do write_err = os.sync(stage)
		close_err := os.close(stage)
		if write_err != nil do return cfg, os.error_string(write_err)
		if close_err != nil do return cfg, os.error_string(close_err)
		if publish_err := os.link(staged, path); publish_err != nil do return cfg, os.error_string(publish_err)
	}
	if err := os.mkdir_all(cfg.tasks); err != nil do return cfg, os.error_string(err)
	return
}
