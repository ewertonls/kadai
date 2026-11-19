package app

import "core:fmt"
import "core:os"
import "core:strings"
import "core:unicode/utf8"
import "kadai:document"
import "kadai:project"
import "kadai:storage"
import "kadai:task"

// Read the selected file before taking the collection writer lock. The entire
// source, including any foreign frontmatter, becomes the new task's body.
read_import :: proc(
	cwd, path, title_override: string,
	limits := project.DEFAULT_SCAN_LIMITS,
) -> (
	title, body, issue: string,
) {
	if !project.valid_scan_limits(limits) do return "", "", "invalid import limits"
	if !storage.valid_path_text(path) || !strings.has_suffix(path, ".md") do return "", "", "import requires a .md source file"
	parent, name := os.split_path(path)
	title = title_override if title_override != "" else strings.trim_suffix(name, ".md")
	if !utf8.valid_string(title) || !task.valid_title(title) do return "", "", "supply a valid task title with --title"

	// Resolve the working directory's components too, including a junction
	// or symlink in its spelling, before interpreting a relative "..".
	if !os.is_absolute_path(parent) do parent = storage.child(storage.slash(cwd), parent)
	dir, _, err := storage.directory(cwd, parent, false)
	if err != nil do return "", "", fmt.tprintf("%s: %s", path, os.error_string(err))
	f, open_err := storage.read_file(storage.child(dir, name))
	if open_err != nil do return "", "", fmt.tprintf("%s: %s", path, os.error_string(open_err))
	defer os.close(f)
	before, stat_err := storage.file_info(f)
	if stat_err != nil do return "", "", fmt.tprintf("%s: %s", path, os.error_string(stat_err))
	if before.size > i64(limits.source_bytes) do return "", "", fmt.tprintf("%s: task_source_bytes limit exceeded: observed %d, limit %d", path, before.size, limits.source_bytes)
	bytes, read_err := storage.read_bounded(f, limits.source_bytes)
	if read_err != nil do return "", "", fmt.tprintf("%s: %s", path, os.error_string(read_err))
	after, after_err := storage.file_info(f)
	if after_err != nil do return "", "", fmt.tprintf("%s: %s", path, os.error_string(after_err))
	if after.size != before.size || after.modification_time != before.modification_time {
		return "", "", fmt.tprintf("%s: source changed during import", path)
	}
	body = string(bytes)
	if !utf8.valid_string(body) do return "", "", fmt.tprintf("%s: import requires UTF-8 Markdown", path)
	doc := document.decode_task(
		body,
		task_source_bytes = limits.source_bytes,
		yaml_limits = limits.yaml,
		path = path,
	)
	defer document.destroy(&doc)
	candidate, _, problem := document.recognize_candidate(&doc, limits.yaml)
	if problem != "" do return "", "", fmt.tprintf("%s: %s", path, problem)
	if candidate do return "", "", fmt.tprintf("%s: import requires ordinary Markdown, found a Kadai task marker", path)
	return
}
