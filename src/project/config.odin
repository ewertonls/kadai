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
	resolved_warnings: ^[]string,
}

Config :: struct {
	project, tasks, boards, id_prefix, timezone: string,
	exclude: []string,
	statuses: map[string]string,
	vocabulary: task.Vocabulary,
	existing: bool,
	warnings: [dynamic]string,
	diagnostics: [dynamic]yaml.Diagnostic,
	diagnostic_alloc_failed: bool,
}

@(private)
config_error :: proc(cfg: ^Config, code, field, message: string, node: ^yaml.Node = nil) {
	loc: yaml.Location
	if node != nil do loc = node.location
	if _, e := append(&cfg.diagnostics, yaml.Diagnostic{path = ".kadai.yaml", code = code, field = field, message = message, location = loc}); e != nil {
		cfg.diagnostic_alloc_failed = true
	}
}

@(private)
check_keys :: proc(cfg: ^Config, node: ^yaml.Node, section: string, allowed: []string) {
	if node == nil || node.kind == .Null do return
	if node.kind != .Mapping {
		config_error(cfg, "invalid_config_field", section, "Expected a mapping.", node)
		return
	}
	for &entry in node.entries {
		if entry.key.kind == .String && slice.contains(allowed, entry.key.text) do continue
		key := entry.key.text if section == "" else fmt.tprintf("%s.%s", section, entry.key.text)
		config_error(cfg, "unknown_config_key", key, "Unknown configuration key.", &entry.key)
	}
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
root_path :: proc(cfg: ^Config, node: ^yaml.Node, base, fallback, override: string, strict: bool) -> string {
	field := "boards.root" if strict else "tasks.root"
	value, ok := scalar(node, fallback, override)
	location := node if override == "" else nil
	if !ok || value == "" {
		config_error(cfg, "invalid_config_field", field, "Expected a root path.", location)
		return ""
	}
	if override == "" && (os.is_absolute_path(value) || strings.contains(value, "\\") ||
	                      len(value) >= 2 && value[1] == ':') {
		config_error(cfg, "absolute_config_path", field, "Config root must be a portable relative path.", node)
		return ""
	}
	root, link, err := storage.directory(base, value, true)
	if err != nil {
		config_error(cfg, "invalid_config_path", field, fmt.tprintf("%s: %s", value, os.error_string(err)), location)
		return ""
	}
	if !storage.within(base, root) || strict && root == base {
		code := "invalid_board_root" if strict && root == base else "root_escape"
		config_error(cfg, code, field, fmt.tprintf("Root outside permitted directory: %s", value), location)
		return ""
	}
	if link do append(&cfg.warnings, fmt.tprintf("%s resolves to %s", value, root))
	return root
}

// All strings and collections returned here live in the invocation's temporary allocator.
resolve :: proc(cwd: string, options := Options{}, limits := yaml.DEFAULT_LIMITS) -> (cfg: Config, problem: string) {
	defer if options.resolved_warnings != nil { options.resolved_warnings^ = cfg.warnings[:] }
	context.allocator = context.temp_allocator
	if !yaml.valid_limits(limits) do return {}, "invalid YAML limits"
	selection := options.project if options.project != "" else "."
	project, link, err := storage.directory(cwd, selection, false)
	if err != nil {
		msg := fmt.tprintf("%s: %s", selection, os.error_string(err))
		append(&cfg.diagnostics, yaml.Diagnostic{path = selection, code = "project_not_found" if err == .Not_Exist else "invalid_project", message = msg})
		return cfg, msg
	}
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
		if e != nil || !storage.within(cfg.project, target) {
			config_error(&cfg, "config_escape", "", "Unsafe .kadai.yaml target.")
			return cfg, "unsafe .kadai.yaml target"
		}
		if info.type == .Symlink do append(&cfg.warnings, fmt.tprintf("%s resolves to %s", path, target))
		f, open_err := storage.read_file(target)
		if open_err != nil do return cfg, os.error_string(open_err)
		defer os.close(f)
		data, read_err := storage.read_bounded(f, limits.bytes)
		if read_err != nil do return cfg, fmt.tprintf("%s: %s", path, os.error_string(read_err))
		var_err: yaml.Error
		d: yaml.Diagnostic
		root, var_err = yaml.parse_mapping(string(data), limits, &d, ".kadai.yaml")
		if var_err != .None { append(&cfg.diagnostics, d) }
		if var_err != .None || root.kind != .Mapping do return cfg, fmt.tprintf("invalid .kadai.yaml mapping (%v)", var_err)
	} else if exists_err != os.General_Error.Not_Exist {
		return cfg, fmt.tprintf("%s: %s", path, os.error_string(exists_err))
	}

	if ver := yaml.lookup(&root, "schema_version"); specified(ver) {
		n, ok := yaml.integer_value(ver)
		if !ok || n.negative || n.digits != "1" {
			config_error(&cfg, "unsupported_config_schema", "schema_version", "Unsupported configuration schema_version.", ver)
			return cfg, "unsupported configuration schema_version"
		}
	}
	check_keys(&cfg, &root, "", {"schema_version","tasks","boards","ids","statuses","priorities","timezone"})
	tasks, boards, ids := yaml.lookup(&root, "tasks"), yaml.lookup(&root, "boards"), yaml.lookup(&root, "ids")
	check_keys(&cfg, tasks, "tasks", {"root","exclude"})
	check_keys(&cfg, boards, "boards", {"root"})
	check_keys(&cfg, ids, "ids", {"prefix"})
	cfg.tasks = root_path(&cfg, yaml.lookup(tasks, "root"), cfg.project, "tasks", options.tasks_root, false)
	if cfg.tasks != "" {
		cfg.boards = root_path(&cfg, yaml.lookup(boards, "root"), cfg.tasks, "boards", options.boards_root, true)
	}
	ok: bool
	prefix := yaml.lookup(ids, "prefix")
	cfg.id_prefix, ok = scalar(prefix, "", options.id_prefix)
	if !ok || (cfg.id_prefix != "" || specified(prefix)) && !task.valid_id(cfg.id_prefix) {
		config_error(&cfg, "invalid_config_field", "ids.prefix", "Invalid ID prefix.", prefix if options.id_prefix == "" else nil)
	}
	zone := yaml.lookup(&root, "timezone")
	cfg.timezone, ok = scalar(zone, "", options.timezone)
	if !ok || (cfg.timezone != "" || specified(zone)) && !valid_timezone(cfg.timezone) {
		config_error(&cfg, "invalid_config_field", "timezone", "Unknown time zone.", zone if options.timezone == "" else nil)
	}
	exclude := yaml.lookup(tasks, "exclude")
	if options.override_exclude {
		cfg.exclude = options.exclude
	} else {
		cfg.exclude, ok = list(exclude)
		if !ok { config_error(&cfg, "invalid_config_field", "tasks.exclude", "Expected a list of exclusion patterns.", exclude) }
	}
	for pattern in cfg.exclude {
		if !valid_pattern(pattern) { config_error(&cfg, "invalid_exclusion_pattern", "tasks.exclude", fmt.tprintf("Invalid exclusion pattern %q.", pattern), exclude if !options.override_exclude else nil) }
	}
	if node := yaml.lookup(&root, "priorities"); specified(node) {
		cfg.vocabulary.priorities, ok = list(node)
		if !ok || len(cfg.vocabulary.priorities) == 0 { config_error(&cfg, "invalid_config_field", "priorities", "Expected at least one priority.", node) }
		seen: map[string]bool
		for p, i in cfg.vocabulary.priorities {
			if !task.valid_slug(p) || p in seen { config_error(&cfg, "invalid_config_field", "priorities", "Invalid or duplicate priority.", &node.items[i]) }
			seen[p] = true
		}
	}
	if node := yaml.lookup(&root, "statuses"); specified(node) {
		if node.kind != .Mapping { config_error(&cfg, "invalid_config_field", "statuses", "Expected a status mapping.", node) }
		names: [dynamic]string
		for &entry in node.entries {
			name := entry.key.text
			if entry.key.kind != .String || !task.valid_slug(name) || task.valid_status(name, {}) {
				config_error(&cfg, "invalid_config_field", "statuses", fmt.tprintf("Invalid status name %q.", name), &entry.key)
				continue
			}
			if entry.value.kind == .Null do continue
			category, valid := scalar(&entry.value, "", "")
			if !valid || !task.valid_status(category, {}) {
				config_error(&cfg, "invalid_config_field", fmt.tprintf("statuses.%s",name), "Expected a built-in status category.", &entry.value)
				continue
			}
			cfg.statuses[name] = category
			append(&names, name)
		}
		cfg.vocabulary.additional_statuses = names[:]
	}
	if cfg.diagnostic_alloc_failed do return cfg, "configuration validation incomplete: allocation failed"
	if len(cfg.diagnostics) > 0 {
		d := cfg.diagnostics[0]
		return cfg, fmt.tprintf("%s: %s", d.field, d.message)
	}
	return
}

@(private)
specified :: proc(node: ^yaml.Node) -> bool { return node != nil && node.kind != .Null }
