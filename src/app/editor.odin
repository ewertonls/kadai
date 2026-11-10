package app

import "core:fmt"
import "core:os"
import "core:strings"
import "kadai:project"
import "kadai:storage"

// EDITOR accepts an executable and literal arguments, including quoted paths.
// Preserve Windows path separators. Never pass the task filename to a shell.
@(private)
editor_arguments :: proc(editor: string) -> (args: [dynamic]string, issue: string) {
	context.allocator = context.temp_allocator
	if strings.contains_any(editor, "\r\n\x00") do return nil, "invalid EDITOR"
	word := strings.builder_make()
	quote: byte
	started := false
	for i := 0; i < len(editor); i += 1 {
		c := editor[i]
		if quote == 0 && (c == ' ' || c == '\t') {
			if started {
				append(&args, strings.clone(strings.to_string(word)))
				strings.builder_reset(&word)
				started = false
			}
			continue
		}
		started = true
		if quote != 0 && c == quote { quote = 0; continue }
		if quote == 0 && (c == '\'' || c == '"') { quote = c; continue }
		if c == '\\' && i+1 < len(editor) && quote != '\'' {
			next := editor[i+1]
			if next == '"' || quote == 0 && (next == '\'' || next == ' ' || next == '\t') {
				c = next
				i += 1
			}
		}
		strings.write_byte(&word, c)
	}
	if quote != 0 do return nil, "unterminated quote in EDITOR"
	if started do append(&args, strings.clone(strings.to_string(word)))
	if len(args) == 0 || args[0] == "" do return nil, "set EDITOR to an executable"
	return
}

@(private)
editor_executable :: proc(cwd, name: string) -> string {
	if os.is_absolute_path(name) do return name
	if strings.contains(storage.slash(name), "/") do return storage.child(cwd, name)
	dirs, err := os.split_path_list(os.get_env("PATH", context.temp_allocator), context.temp_allocator)
	if err != nil do return ""
	for entry in dirs {
		dir := entry if os.is_absolute_path(entry) else storage.child(cwd, entry)
		path := storage.child(dir, name)
		when ODIN_OS == .Windows {
			if !strings.has_suffix(strings.to_lower(name, context.temp_allocator), ".exe") do path = fmt.tprintf("%s.exe", path)
		}
		info, e := os.lstat(path, context.temp_allocator)
		if e != nil || info.type != .Regular && info.type != .Symlink do continue
		if info.type == .Symlink { info, e = os.stat(path, context.temp_allocator) }
		if e != nil || info.type != .Regular do continue
		when ODIN_OS != .Windows {
			if info.mode & {.Execute_User, .Execute_Group, .Execute_Other} == {} do continue
		}
		return path
	}
	return ""
}

edit_task :: proc(cwd: string, options: Project_Options, id, editor: string, limits := project.DEFAULT_SCAN_LIMITS, stdout := os.stdout) -> string {
	command, issue := editor_arguments(editor)
	if issue != "" do return issue
	exe := editor_executable(cwd, command[0])
	if exe == "" do return fmt.tprintf("editor executable not found: %s", command[0])
	command[0] = exe
	process: os.Process
	{
		// Coordinate selection and launch. The editor subsequently owns its
		// manual saves and can stay open without blocking other CLI users.
		w, err := storage.begin_writer()
		if err != nil do return os.error_string(err)
		defer storage.end_writer(&w)
		view, problem := read_collection(cwd, options, limits)
		if problem != "" do return problem
		if pending := storage.check_pending(&w, view.config.tasks, limits.entries); pending != "" do return pending
		item, lookup_err := unique_task(&view, id, diagnostic = true)
		if lookup_err != "" do return lookup_err
		if item.status != .Decoded && item.status != .Invalid_Fields do return "unsupported task schema"
		if _, read_err := read_versioned(&view, item, mutation = true); read_err != "" do return read_err
		append(&command, storage.child(view.config.tasks, item.path))
		process, err = os.process_start({command = command[:], working_dir = cwd, stdin = os.stdin, stdout = stdout, stderr = os.stderr})
		if err != nil do return fmt.tprintf("launching %s: %s", exe, os.error_string(err))
		if options.report != nil do options.report.write_started = true // The editor now owns its saves.
	}
	state, e := os.process_wait(process)
	if e != nil do return fmt.tprintf("waiting for editor: %s", os.error_string(e))
	if !state.success || state.exit_code != 0 do return fmt.tprintf("editor exited with code %d", state.exit_code)
	return ""
}
