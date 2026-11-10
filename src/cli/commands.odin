package cli

import "core:flags"
import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"
import "kadai:app"

@(private)
execute :: proc(command, cwd: string, a: Arguments, stdin: io.Reader) -> (output, issue: string, code: int) {
	switch command {
	case "init":
		if len(a.words) != 0 do return "", "init takes no positional arguments", 2
		_, issue = app.initialize(cwd, a.project)
	case "validate":
		if len(a.words) != 0 do return "", "validate takes no positional arguments", 2
		report, problem := app.validate_project(cwd, a.project)
		if problem != "" do return "", problem, 1
		return validation_text(report), "", 1 if report.errors != 0 else 0
	case "ready":
		if len(a.words) > 1 do return "", "ready accepts an optional task ID", 2
		id: Maybe(string)
		if len(a.words) == 1 do id = a.words[0]
		rows, problem := app.ready_tasks(cwd, a.project, id)
		if problem != "" do return "", problem, 1
		b := strings.builder_make(context.temp_allocator)
		for row in rows {
			label := "ready"
			switch row.readiness {
			case .Ready:
			case .Blocked: label = "blocked"
			case .Unresolved: label = "unresolved"
			}
			fmt.sbprintf(&b, "%s\t%s\t%s\t%s\n", row.item.fields.id, label, row.item.fields.status, row.item.fields.title)
		}
		output = strings.to_string(b)
	case "tree":
		if len(a.words) != 0 do return "", "tree takes no positional arguments", 2
		rows, problem := app.task_tree(cwd, a.project)
		if problem != "" do return "", problem, 1
		b := strings.builder_make(context.temp_allocator)
		for row in rows {
			// Keep text output linear in the number of tasks, even for a long chain.
			for _ in 0..<min(row.depth, 16) do strings.write_string(&b, "  ")
			if row.depth > 16 do fmt.sbprintf(&b, "[depth %d] ", row.depth)
			fmt.sbprintf(&b, "%s %s", row.item.fields.id, row.item.fields.title)
			switch row.position {
			case .Unresolved_Parent: fmt.sbprintf(&b, " [unresolved parent: %s]", row.item.fields.parent)
			case .Parent_Cycle: fmt.sbprintf(&b, " [parent cycle: %s]", row.item.fields.parent)
			case .Root, .Child:
			}
			strings.write_byte(&b, '\n')
		}
		output = strings.to_string(b)
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
	case "dep":
		if len(a.words) == 2 && a.words[0] == "show" {
			view, problem := app.dependencies(cwd, a.project, a.words[1])
			if problem != "" do return "", problem, 1
			b := strings.builder_make(context.temp_allocator)
			id := view.task.fields.id
			fmt.sbprintf(&b, "Prerequisites of %s (prerequisite -> dependent)\n", id)
			if len(view.prerequisites) == 0 do strings.write_string(&b, "  (none)\n")
			for ref in view.prerequisites {
				if ref.status == .Resolved {
					fmt.sbprintf(&b, "  %s -> %s\n", ref.candidates[0].fields.id, id)
				} else {
					fmt.sbprintf(&b, "  %s -> %s [%v]\n", ref.written_id, id, ref.status)
				}
			}
			fmt.sbprintf(&b, "Dependents of %s\n", id)
			if len(view.dependents) == 0 do strings.write_string(&b, "  (none)\n")
			for other in view.dependents do fmt.sbprintf(&b, "  %s -> %s\n", id, other.fields.id)
			return strings.to_string(b), "", 0
		}
		if len(a.words) != 3 || (a.words[0] != "add" && a.words[0] != "remove") do return "", "expected dep show ID or dep add|remove TASK PREREQUISITE", 2
		_, issue = app.change_dependency(cwd, a.project, a.words[1], a.words[2], a.words[0] == "remove")
	case "parent":
		if len(a.words) == 3 && a.words[0] == "add" {
			_, issue = app.set_parent(cwd, a.project, a.words[1], a.words[2])
		} else if len(a.words) == 2 && a.words[0] == "remove" {
			_, issue = app.set_parent(cwd, a.project, a.words[1], nil)
		} else { return "", "expected parent add CHILD PARENT or parent remove CHILD", 2 }
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
		if len(a.words) < 2 || command == "unset" && len(a.words) != 2 do return "", "expected an ID and field", 2
		_, issue = app.update_task(cwd, a.project, {id = a.words[0], field = a.words[1], values = a.words[2:], unset = command == "unset", force = a.force})
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
run_command :: proc(command: Command, args: []string, stdout, stderr: io.Writer, stdin: io.Reader) -> int {
	a: Arguments
	parse_err: flags.Error
	switch command.flag_type {
	case Project_Flags: a, parse_err = parse_options(Project_Flags, args)
	case Add_Flags:     a, parse_err = parse_options(Add_Flags, args)
	case Status_Flags:  a, parse_err = parse_options(Status_Flags, args)
	case Move_Flags:    a, parse_err = parse_options(Move_Flags, args)
	case Remove_Flags:  a, parse_err = parse_options(Remove_Flags, args)
	case Help_Flags:
		topic: Help_Flags
		parse_err = flags.parse(&topic, args, .Unix, allocator = context.temp_allocator)
		if parse_err == nil {
			if topic.command == "" do return write_stdout(help_text(), stdout, stderr)
			if target, ok := find_command(topic.command); ok {
				return write_stdout(command_help(target), stdout, stderr)
			}
			fmt.wprintf(stderr, "kadai help: unknown command %q. Run 'kadai help' to list commands.\n", topic.command)
			return 2
		}
	case: unreachable()
	}

	switch err in parse_err {
	case flags.Help_Request:
		return write_stdout(command_help(command), stdout, stderr)
	case flags.Parse_Error:
		fmt.wprintf(stderr, "kadai %s: %s\n", command.name, err.message)
		return 2
	case flags.Validation_Error:
		fmt.wprintf(stderr, "kadai %s: %s\n", command.name, err.message)
		return 2
	case flags.Open_File_Error:
		fmt.wprintf(stderr, "kadai %s: could not open %q\n", command.name, err.filename)
		return 2
	}
	cwd, e := os.getwd(context.temp_allocator)
	if e != nil { fmt.wprintf(stderr, "kadai: %s\n", os.error_string(e)); return 1 }
	warnings: []string
	a.project.resolved_warnings = &warnings
	output, issue, code := execute(command.name, cwd, a, stdin)
	for w in warnings do fmt.wprintf(stderr, "kadai: %s\n", w)
	if issue != "" { fmt.wprintf(stderr, "kadai: %s\n", issue); return code }
	if output != "" {
		if write_stdout(output, stdout, stderr) != 0 do return 1
	}
	return code
}
