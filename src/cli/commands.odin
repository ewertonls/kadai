package cli

import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"
import "kadai:app"

@(private)
Arguments :: struct {
	command: string,
	project: app.Project_Options,
	words: [dynamic]string,
	body_file, destination, plan: string,
	status: Maybe(string),
	stdin, force, directory, detach, dry_run: bool,
}

@(private)
parse_command :: proc(args: []string) -> (a: Arguments, problem: string) {
	context.allocator = context.temp_allocator
	a.command = args[0]
	excludes: [dynamic]string
	positional := false
	for i := 1; i < len(args); i += 1 {
		name := args[i]
		if positional || !strings.has_prefix(name, "--") { append(&a.words, name); continue }
		if name == "--" { positional = true; continue }
		if a.command == "remove" && name == "--detach" { a.detach = true; continue }
		if a.command == "remove" && name == "--dry-run" { a.dry_run = true; continue }
		if name == "--directory" && a.command == "move" { a.directory = true; continue }
		if name == "--force" && (a.command == "status" || a.command == "set") { a.force = true; continue }
		if name == "--stdin" && a.command == "add" { a.stdin = true; continue }
		if i+1 >= len(args) { return a, fmt.tprintf("missing value for %s", name) }
		i += 1
		value := args[i]
		if value == "" && name != "--exclude" do return a, fmt.tprintf("empty value for %s", name)
		switch name {
		case "--plan":
			if a.command != "remove" do return a, "unexpected --plan"
			a.plan = value
		case "--project": a.project.project = value
		case "--tasks-root": a.project.tasks_root = value
		case "--boards-root": a.project.boards_root = value
		case "--id-prefix": a.project.id_prefix = value
		case "--timezone": a.project.timezone = value
		case "--exclude":
			a.project.override_exclude = true
			if value != "" do append(&excludes, value)
		case "--status", "--body-file", "--path":
			if a.command != "add" do return a, fmt.tprintf("unexpected %s option %s", a.command, name)
			switch name {
			case "--status": a.status = value
			case "--body-file": a.body_file = value
			case "--path": a.destination = value
			}
		case: return a, fmt.tprintf("unknown %s option %s", a.command, name)
		}
	}
	a.project.exclude = excludes[:]
	if a.stdin && a.body_file != "" do return a, "choose one body source"
	return
}

@(private)
execute :: proc(cwd: string, a: Arguments, stdin: io.Reader) -> (output, issue: string, code: int) {
	switch a.command {
	case "init":
		if len(a.words) != 0 do return "", "init takes no positional arguments", 2
		_, issue = app.initialize(cwd, a.project)
	case "list":
		if len(a.words) != 0 do return "", "list takes no positional arguments", 2
		items, problem := app.list_tasks(cwd, a.project)
		if problem != "" do return "", problem, 1
		b := strings.builder_make(context.temp_allocator)
		for item in items do fmt.sbprintf(&b, "%s\t%s\t%s\t%s\n", item.fields.id, item.fields.status, item.fields.title, item.path)
		output = strings.to_string(b)
	case "remove":
		if len(a.words) != 1 do return "", "remove requires an ID", 2
		remove := app.Removal{id = a.words[0], detach = a.detach, expected_plan = a.plan}
		if a.dry_run {
			preview, problem := app.preview_removal(cwd, a.project, remove)
			if problem != "" do return "", problem, 1
			b := strings.builder_make(context.temp_allocator)
			for edit in preview.edits do fmt.sbprintf(&b, "%s\t%q\t%s\t%d..%d\n", edit.id, edit.path, edit.field, edit.span.start, edit.span.end)
			fmt.sbprintf(&b, "plan %s\n", preview.token)
			output = strings.to_string(b)
		} else {
			operation, problem := app.remove_task(cwd, a.project, remove)
			if problem != "" do return "", problem, 1
			output = fmt.tprintf("%s\n", operation)
		}
	case "recover":
		if len(a.words) < 1 || len(a.words) > 2 do return "", "recover requires resume or rollback and an optional operation ID", 2
		id := a.words[1] if len(a.words) == 2 else ""
		switch a.words[0] {
		case "resume": _, issue = app.recover_collection(cwd, a.project, .Resume, id)
		case "rollback": _, issue = app.recover_collection(cwd, a.project, .Rollback, id)
		case: return "", "unknown recovery mode", 2
		}
	case "move":
		if len(a.words) != 2 do return "", "move requires a source and destination", 2
		_, issue = app.move_task(cwd, a.project, {a.words[0], a.words[1], a.directory})
	case "edit":
		if len(a.words) != 1 do return "", "edit requires an ID", 2
		issue = app.edit_task(cwd, a.project, a.words[0], os.get_env("EDITOR", context.temp_allocator))
	case "status":
		if len(a.words) != 2 do return "", "status requires an ID and status", 2
		_, issue = app.set_status(cwd, a.project, a.words[0], a.words[1], a.force)
	case "set", "unset":
		if len(a.words) < 2 || a.command == "unset" && len(a.words) != 2 do return "", "expected an ID and field", 2
		_, issue = app.update_task(cwd, a.project, {id = a.words[0], field = a.words[1], values = a.words[2:], unset = a.command == "unset", force = a.force})
	case "show":
		if len(a.words) != 1 do return "", "show requires an ID", 2
		result, problem := app.get_task(cwd, a.project, a.words[0])
		if problem != "" do return "", problem, 1
		if result.item.status != .Decoded {
			b := strings.builder_make(context.temp_allocator)
			fmt.sbprintf(&b, "%s (%s)", result.item.fields.id, result.item.path)
			for d in result.item.diagnostics do fmt.sbprintf(&b, "\n%s: %s", d.code, d.message)
			return "", strings.to_string(b), 1
		}
		output = fmt.tprintf("%s\n%s", result.item.path, result.source)
	case "add":
		if len(a.words) != 1 do return "", "add requires a title", 2
		body := ""
		if a.stdin {
			if stdin.procedure == nil do return "", "stdin unavailable", 1
			body, issue = app.read_body(stdin)
		} else if a.body_file != "" {
			f, err := os.open(a.body_file)
			if err != nil do return "", fmt.tprintf("%s: %s", a.body_file, os.error_string(err)), 1
			defer os.close(f)
			body, issue = app.read_body(os.to_reader(f))
		}
		if issue == "" {
			output, issue = app.create_task(cwd, a.project, {title = a.words[0], body = body, destination = a.destination, status = a.status})
			output = fmt.tprintf("%s\n", output)
		}
	}
	return output, issue, 1 if issue != "" else 0
}

@(private)
run_command :: proc(args: []string, stdout, stderr: io.Writer, stdin: io.Reader) -> int {
	a, problem := parse_command(args)
	if problem != "" { fmt.wprintf(stderr, "kadai: %s\n", problem); return 2 }
	cwd, e := os.getwd(context.temp_allocator)
	if e != nil { fmt.wprintf(stderr, "kadai: %s\n", os.error_string(e)); return 1 }
	warnings: []string
	a.project.resolved_warnings = &warnings
	output, issue, code := execute(cwd, a, stdin)
	for w in warnings do fmt.wprintf(stderr, "kadai: %s\n", w)
	if issue != "" { fmt.wprintf(stderr, "kadai: %s\n", issue); return code }
	if output != "" {
		n, err := io.write_string(stdout, output)
		if err != .None || n != len(output) { fmt.wprintf(stderr, "kadai: could not write to stdout.\n"); return 1 }
	}
	return 0
}
