package project

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "kadai:storage"
import "kadai:yaml"

@(private)
GITIGNORE_RULE :: "/.kadai/"

@(private)
plan_gitignore :: proc(path: string, limit: int) -> (contents, expected: string, err: os.Error) {
	f, open_err := storage.read_file(path)
	if open_err == os.General_Error.Not_Exist {
		contents = GITIGNORE_RULE + "\n"
		if len(contents) > limit do return "", "", .Short_Buffer
		return
	}
	if open_err != nil do return "", "", open_err
	defer os.close(f)
	data := storage.read_bounded(f, limit) or_return
	source := strings.trim_prefix(string(data), "\xef\xbb\xbf")
	lines := source
	for line in strings.split_iterator(&lines, "\n") {
		if strings.trim_right(strings.trim_suffix(line, "\r"), " ") == GITIGNORE_RULE do return
	}
	// Follow the last line ending, including when the final rule has no newline.
	eol := "\n"
	if lf := strings.last_index_byte(source, '\n'); lf > 0 && source[lf - 1] == '\r' do eol = "\r\n"
	separator := eol if source != "" && !strings.has_suffix(source, "\n") else ""
	if len(separator) + len(GITIGNORE_RULE) + len(eol) > limit - len(data) do return "", "", .Short_Buffer
	// Check single-link eligibility before init publishes any project files.
	target := storage.read_file(path, mutation = true) or_return
	os.close(target) or_return
	info := storage.file_info(f) or_return
	contents = strings.concatenate(
		{string(data), separator, GITIGNORE_RULE, eol},
		context.temp_allocator,
	) or_return
	return contents, storage.file_version(info, data), nil
}

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
	git := false,
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
	gitignore, expected: string
	if git {
		path := storage.child(cfg.tasks, ".gitignore")
		e: os.Error
		gitignore, expected, e = plan_gitignore(path, limits.source_bytes)
		if e == .Short_Buffer do return cfg, fmt.tprintf("%s: task_source_bytes limit exceeded (%d)", path, limits.source_bytes)
		if e != nil do return cfg, fmt.tprintf("%s: %s", path, os.error_string(e))
	}
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
	defer storage.close_dir(&dir)
	if gitignore != "" {
		err = storage.write_project_file(
			&dir,
			".gitignore",
			expected,
			transmute([]byte)gitignore,
			limits.source_bytes,
			started,
		)
		if err != nil do return cfg, fmt.tprintf("%s: %s", storage.child(cfg.tasks, ".gitignore"), os.error_string(err))
	}
	return
}
