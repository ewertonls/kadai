package project

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time/timezone"
import "kadai:storage"
import "kadai:task"
import "kadai:yaml"

Options :: struct {
	project, tasks_root, boards_root, id_prefix, timezone: string,
	exclude: []string,
	override_exclude: bool,
}

Config :: struct {
	project, tasks, boards, id_prefix, timezone: string,
	exclude: []string,
	statuses: map[string]string,
	vocabulary: task.Vocabulary,
	existing: bool,
	warnings: [dynamic]string,
}

@(private)
keys :: proc(node: ^yaml.Node, allowed: []string) -> bool {
	if node == nil || node.kind == .Null do return true
	if node.kind != .Mapping do return false
	for entry in node.entries {
		if entry.key.kind != .String || !slice.contains(allowed, entry.key.text) do return false
	}
	return true
}

@(private)
scalar :: proc(node: ^yaml.Node, fallback, override: string) -> (string, bool) {
	if override != "" do return override, true
	if node == nil || node.kind == .Null do return fallback, true
	if node.kind == .Mapping || node.kind == .Sequence do return "", false
	return node.text, true
}

@(private)
list :: proc(node: ^yaml.Node) -> (result: []string, ok: bool) {
	if node == nil || node.kind == .Null do return nil, true
	if node.kind != .Sequence do return nil, false
	items := make([]string, len(node.items), context.temp_allocator)
	for &item, i in node.items {
		if item.kind == .Null do return nil, false
		items[i] = scalar(&item, "", "") or_return
	}
	return items, true
}

valid_pattern :: proc(s: string) -> bool {
	if s == "" || s[0] == '/' || s[0] == '!' || strings.contains_any(s, "\\[]{}\x00") ||
	   len(s) >= 2 && s[1] == ':' { return false }
	parts := s
	for part in strings.split_iterator(&parts, "/") {
		if part == ".." do return false
	}
	return true
}

@(private)
valid_timezone :: proc(name: string) -> bool {
	if name == "" || name == "local" do return false
	parts := name
	for part in strings.split_iterator(&parts, "/") {
		if part == "" || part == "." || part == ".." do return false
		for c in part {
			if !(c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || c >= '0' && c <= '9' ||
			     c == '_' || c == '+' || c == '-') { return false }
		}
	}
	reg, ok := timezone.region_load(name, context.temp_allocator)
	if ok do timezone.region_destroy(reg, context.temp_allocator)
	return ok
}

@(private)
root_path :: proc(cfg: ^Config, node: ^yaml.Node, base, fallback, override: string, strict: bool) -> (string, string) {
	value, ok := scalar(node, fallback, override)
	if !ok || value == "" do return "", "invalid root path"
	if override == "" && (os.is_absolute_path(value) || strings.contains(value, "\\") ||
	                      len(value) >= 2 && value[1] == ':') { return "", "config root must be relative" }
	root, link, err := storage.directory(base, value, true)
	if err != nil do return "", fmt.tprintf("%s: %s", value, os.error_string(err))
	if !storage.within(base, root) || strict && root == base do return "", fmt.tprintf("root outside permitted directory: %s", value)
	if link do append(&cfg.warnings, fmt.tprintf("%s resolves to %s", value, root))
	return root, ""
}

// All strings and collections returned here live in the invocation's temporary allocator.
resolve :: proc(cwd: string, options := Options{}, limits := yaml.DEFAULT_LIMITS) -> (cfg: Config, problem: string) {
	context.allocator = context.temp_allocator
	if !yaml.valid_limits(limits) do return {}, "invalid YAML limits"
	selection := options.project if options.project != "" else "."
	project, link, err := storage.directory(cwd, selection, false)
	if err != nil do return {}, fmt.tprintf("%s: %s", selection, os.error_string(err))
	cfg.project, err = storage.physical(project, .Directory)
	if err != nil do return {}, fmt.tprintf("%s: %s", project, os.error_string(err))
	if link do append(&cfg.warnings, fmt.tprintf("%s resolves to %s", selection, cfg.project))
	path := storage.child(cfg.project, ".kadai.yaml")
	info, exists_err := os.lstat(path, context.temp_allocator)
	root := yaml.Node{kind = .Mapping}
	if exists_err == nil {
		cfg.existing = true
		if info.type != .Regular && info.type != .Symlink do return cfg, "invalid .kadai.yaml file type"
		target, e := storage.physical(path, .Regular)
		if e != nil || !storage.within(cfg.project, target) do return cfg, "unsafe .kadai.yaml target"
		if info.type == .Symlink do append(&cfg.warnings, fmt.tprintf("%s resolves to %s", path, target))
		f, open_err := storage.read_file(target)
		if open_err != nil do return cfg, os.error_string(open_err)
		defer os.close(f)
		data, read_err := storage.read_bounded(f, limits.bytes)
		if read_err != nil do return cfg, fmt.tprintf("%s: %s", path, os.error_string(read_err))
		var_err: yaml.Error
		root, var_err = yaml.parse_mapping(string(data), limits)
		if var_err != .None || root.kind != .Mapping do return cfg, fmt.tprintf("invalid .kadai.yaml mapping (%v)", var_err)
	} else if exists_err != os.General_Error.Not_Exist {
		return cfg, fmt.tprintf("%s: %s", path, os.error_string(exists_err))
	}

	if !keys(&root, {"schema_version","tasks","boards","ids","statuses","priorities","timezone"}) do return cfg, "unknown configuration key"
	if ver := yaml.lookup(&root, "schema_version"); ver != nil && ver.kind != .Null {
		n, ok := yaml.integer_value(ver)
		if !ok || n.negative || n.digits != "1" do return cfg, "unsupported configuration schema_version"
	}
	tasks, boards, ids := yaml.lookup(&root, "tasks"), yaml.lookup(&root, "boards"), yaml.lookup(&root, "ids")
	if !keys(tasks, {"root","exclude"}) || !keys(boards, {"root"}) || !keys(ids, {"prefix"}) do return cfg, "invalid configuration section"
	cfg.tasks, problem = root_path(&cfg, yaml.lookup(tasks, "root"), cfg.project, "tasks", options.tasks_root, false)
	if problem != "" do return
	cfg.boards, problem = root_path(&cfg, yaml.lookup(boards, "root"), cfg.tasks, "boards", options.boards_root, true)
	if problem != "" do return
	ok: bool
	cfg.id_prefix, ok = scalar(yaml.lookup(ids, "prefix"), "", options.id_prefix)
	if !ok || (cfg.id_prefix != "" || specified(yaml.lookup(ids, "prefix"))) && !task.valid_id(cfg.id_prefix) do return cfg, "invalid ids.prefix"
	cfg.timezone, ok = scalar(yaml.lookup(&root, "timezone"), "", options.timezone)
	if !ok || (cfg.timezone != "" || specified(yaml.lookup(&root, "timezone"))) && !valid_timezone(cfg.timezone) do return cfg, "invalid timezone"
	if options.override_exclude {
		cfg.exclude = options.exclude
	} else {
		cfg.exclude, ok = list(yaml.lookup(tasks, "exclude"))
		if !ok do return cfg, "invalid tasks.exclude"
	}
	for pattern in cfg.exclude {
		if !valid_pattern(pattern) do return cfg, "invalid tasks.exclude pattern"
	}
	if node := yaml.lookup(&root, "priorities"); specified(node) {
		cfg.vocabulary.priorities, ok = list(node)
		if !ok || len(cfg.vocabulary.priorities) == 0 do return cfg, "invalid priorities"
		seen: map[string]bool
		for p in cfg.vocabulary.priorities {
			if !task.valid_slug(p) || p in seen do return cfg, "invalid or duplicate priority"
			seen[p] = true
		}
	}
	if node := yaml.lookup(&root, "statuses"); specified(node) {
		if node.kind != .Mapping do return cfg, "invalid statuses"
		names: [dynamic]string
		for &entry in node.entries {
			name := entry.key.text
			if entry.key.kind != .String || !task.valid_slug(name) || task.valid_status(name, {}) do return cfg, "invalid status name"
			if entry.value.kind == .Null do continue
			category, valid := scalar(&entry.value, "", "")
			if !valid || !task.valid_status(category, {}) do return cfg, "invalid status category"
			cfg.statuses[name] = category
			append(&names, name)
		}
		cfg.vocabulary.additional_statuses = names[:]
	}
	return
}

@(private)
specified :: proc(node: ^yaml.Node) -> bool { return node != nil && node.kind != .Null }
