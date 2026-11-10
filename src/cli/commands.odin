package cli

import "core:flags"
import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"
import "core:unicode/utf8"
import "kadai:app"

@(private, rodata)
READINESS_LABELS := [app.Readiness]string{.Ready = "ready", .Blocked = "blocked", .Unresolved = "unresolved"}

@(private)
execute :: proc(command, cwd: string, a: Arguments, stdin: io.Reader, completed: ^string) -> (output, issue: string, code: Exit_Code) {
	operation: string
	switch command {
	case "init":
		if len(a.words) != 0 do return "", "init takes no positional arguments", .Usage
		_, issue = app.initialize(cwd, a.project, a.limits)
	case "validate":
		if len(a.words) != 0 do return "", "validate takes no positional arguments", .Usage
		report, problem := app.validate_project(cwd, a.project, a.limits)
		if problem != "" do return "", problem, .Failure
		code = .Failure if report.errors != 0 || !validation_complete(report) else .Success
		if a.json do return json_result(report, code)
		return validation_text(report), "", code
	case "ready":
		if len(a.words) > 1 do return "", "ready accepts an optional task ID", .Usage
		id: Maybe(string)
		if len(a.words) == 1 do id = a.words[0]
		rows, problem := app.ready_tasks(cwd, a.project, id, a.limits)
		if problem != "" do return "", problem, .Failure
		if a.json do return json_result(rows)
		b := strings.builder_make(context.temp_allocator)
		for row in rows {
			write_task_label(&b, row.item.fields.id, row.item.fields.status, row.item.fields.title)
			fmt.sbprintf(&b, "  (readiness: %s)\n", READINESS_LABELS[row.readiness])
		}
		return strings.to_string(b), "", .Success
	case "tree":
		if len(a.words) != 0 do return "", "tree takes no positional arguments", .Usage
		rows, problem := app.task_tree(cwd, a.project, a.limits)
		if problem != "" do return "", problem, .Failure
		if a.json do return json_result(rows)
		return tree_text(rows), "", .Success
	case "list":
		if len(a.words) != 0 do return "", "list takes no positional arguments", .Usage
		items, problem := app.list_tasks(cwd, a.project, a.limits, a.list_filter)
		if problem != "" do return "", problem, .Failure
		if a.json do return json_result(items)
		b := strings.builder_make(context.temp_allocator)
		for item in items {
			write_task_label(&b, item.fields.id, item.fields.status, item.fields.title)
			fmt.sbprintf(&b, "  (%s)\n", terminal_field(item.path))
		}
		return strings.to_string(b), "", .Success
	case "remove":
		if len(a.words) != 1 do return "", "remove requires an ID", .Usage
		remove := app.Removal{id = a.words[0], detach = a.detach, expected_plan = a.plan}
		if a.dry_run {
			preview, problem := app.preview_removal(cwd, a.project, remove, a.limits)
			if problem != "" do return "", problem, .Failure
			if a.json do return json_result(preview)
			b := strings.builder_make(context.temp_allocator)
			for edit in preview.edits do fmt.sbprintf(&b, "%s\t%q\t%s\t%d..%d\n", edit.id, edit.path, edit.field, edit.span.start, edit.span.end)
			fmt.sbprintf(&b, "plan %s\n", preview.token)
			return strings.to_string(b), "", .Success
		}
		if !a.yes && a.plan == "" {
			return "", "remove requires --yes or --plan TOKEN to delete a task. Use --dry-run to preview", .Usage
		}
		operation, issue = app.remove_task(cwd, a.project, remove, a.limits)
		output = fmt.tprintf("%s\n", operation)
	case "recover":
		if len(a.words) < 1 || len(a.words) > 2 do return "", "recover requires resume or rollback and an optional operation ID", .Usage
		id := ""
		if len(a.words) == 2 {
			id = a.words[1]
			if id == "" do return "", "recovery operation ID cannot be empty", .Usage
		}
		mode: app.Recovery_Mode
		switch a.words[0] {
		case "resume": mode = .Resume
		case "rollback": mode = .Rollback
		case: return "", "unknown recovery mode", .Usage
		}
		if !a.yes do return "", "recover requires --yes to apply the operation", .Usage
		operation, issue = app.recover_collection(cwd, a.project, mode, id, a.limits)
	case "dep":
		if len(a.words) == 2 && a.words[0] == "show" {
			view, problem := app.dependencies(cwd, a.project, a.words[1], a.limits)
			if problem != "" do return "", problem, .Failure
			if a.json do return json_result(view)
			return dependency_text(view), "", .Success
		}
		if len(a.words) != 3 || (a.words[0] != "add" && a.words[0] != "remove") do return "", "expected dep show ID or dep add|remove TASK PREREQUISITE", .Usage
		operation, issue = app.change_dependency(cwd, a.project, a.words[1], a.words[2], a.words[0] == "remove", a.limits)
	case "parent":
		if len(a.words) == 3 && a.words[0] == "add" {
			operation, issue = app.set_parent(cwd, a.project, a.words[1], a.words[2], a.limits)
		} else if len(a.words) == 2 && a.words[0] == "remove" {
			operation, issue = app.set_parent(cwd, a.project, a.words[1], nil, a.limits)
		} else { return "", "expected parent add CHILD PARENT or parent remove CHILD", .Usage }
	case "move":
		if len(a.words) != 2 do return "", "move requires a source and destination", .Usage
		operation, issue = app.move_task(cwd, a.project, {a.words[0], a.words[1], a.directory}, a.limits)
	case "edit":
		if len(a.words) != 1 do return "", "edit requires an ID", .Usage
		editor_out := os.stderr if a.json else os.stdout
		issue = app.edit_task(cwd, a.project, a.words[0], os.get_env("EDITOR", context.temp_allocator), a.limits, editor_out)
	case "status":
		if len(a.words) != 2 do return "", "status requires an ID and status", .Usage
		operation, issue = app.set_status(cwd, a.project, a.words[0], a.words[1], a.force, a.limits)
	case "set", "unset":
		if len(a.words) < 2 || command == "unset" && len(a.words) != 2 do return "", "expected an ID and field", .Usage
		field := a.words[1]
		switch field {
		case "title", "status":
			if command == "unset" do return "", "unset supports only priority, due and tags", .Usage
		case "priority", "due", "tags":
		case: return "", fmt.tprintf("not an editable core field: %s", field), .Usage
		}
		if command == "set" && field != "tags" && len(a.words) != 3 do return "", "set requires one scalar value", .Usage
		if a.force && field != "status" do return "", "force applies only to a status transition", .Usage
		operation, issue = app.update_task(cwd, a.project, {id = a.words[0], field = field, values = a.words[2:], unset = command == "unset", force = a.force}, a.limits)
	case "show":
		if len(a.words) != 1 do return "", "show requires an ID", .Usage
		result, problem := app.get_task(cwd, a.project, a.words[0], a.limits)
		if problem != "" do return "", problem, .Failure
		if result.item.status != .Decoded {
			b := strings.builder_make(context.temp_allocator)
			fmt.sbprintf(&b, "%s (%s)", result.item.fields.id, result.item.path)
			for d in result.item.diagnostics do fmt.sbprintf(&b, "\n%s: %s", d.code, d.message)
			return "", strings.to_string(b), .Failure
		}
		if a.json do return json_result(result)
		return fmt.tprintf("%s\n%s", result.item.path, result.source), "", .Success
	case "add":
		if len(a.words) != 1 do return "", "add requires a title", .Usage
		if a.json && !utf8.valid_string(a.destination) do return "", "unsupported_output: JSON requires a UTF-8 task path", .Output_Failed
		body := ""
		if a.stdin {
			if stdin.procedure == nil do return "", "stdin unavailable", .Failure
			body, issue = app.read_body(stdin, a.limits.source_bytes)
		} else if a.body_file != "" {
			f, err := os.open(a.body_file)
			if err != nil do return "", fmt.tprintf("%s: %s", a.body_file, os.error_string(err)), .Failure
			defer os.close(f)
			body, issue = app.read_body(os.to_reader(f), a.limits.source_bytes)
		}
		if issue != "" do return "", issue, .Failure
		created, problem := app.create_task_result(cwd, a.project, {title = a.words[0], body = body, destination = a.destination, status = a.status}, a.limits)
		if problem != "" do return "", problem, .Failure
		completed^ = fmt.tprintf("created task %s", created.id)
		if a.json do return json_result(created)
		return fmt.tprintf("%s\n", created.id), "", .Success
	}
	if issue != "" {
		if operation != "" do issue = fmt.tprintf("operation %s: %s", operation, issue)
		return "", issue, .Failure
	}
	completed^ = fmt.tprintf("%s completed", command)
	if operation != "" do completed^ = fmt.tprintf("%s completed (operation %s)", command, operation)
	if a.json do return json_result(operation)
	return output, "", .Success
}

@(private)
run_command :: proc(command: Command, args: []string, stdout, stderr: io.Writer, stdin: io.Reader) -> Exit_Code {
	a: Arguments
	parse_err: flags.Error
	switch command.flag_type {
	case Project_Flags: a, parse_err = parse_options(Project_Flags, args)
	case List_Flags:    a, parse_err = parse_options(List_Flags, args)
	case Add_Flags:     a, parse_err = parse_options(Add_Flags, args)
	case Status_Flags:  a, parse_err = parse_options(Status_Flags, args)
	case Move_Flags:    a, parse_err = parse_options(Move_Flags, args)
	case Remove_Flags:  a, parse_err = parse_options(Remove_Flags, args)
	case Recover_Flags: a, parse_err = parse_options(Recover_Flags, args)
	case Help_Flags:
		topic: Help_Flags
		parse_err = flags.parse(&topic, args, .Unix, allocator = context.temp_allocator)
		if parse_err == nil {
			if topic.command == "" do return write_stdout(help_text(), stdout, stderr)
			if target, ok := find_command(topic.command); ok {
				return write_stdout(command_help(target), stdout, stderr)
			}
			return diagnose(stderr, .Usage, fmt.tprintf("help: unknown command %q. Run 'kadai help' to list commands.", topic.command))
		}
	case: unreachable()
	}

	switch err in parse_err {
	case flags.Help_Request:
		return write_stdout(command_help(command), stdout, stderr)
	case flags.Parse_Error:
		return diagnose(stderr, .Usage, fmt.tprintf("%s: %s", command.name, err.message))
	case flags.Validation_Error:
		return diagnose(stderr, .Usage, fmt.tprintf("%s: %s", command.name, err.message))
	case flags.Open_File_Error:
		return diagnose(stderr, .Usage, fmt.tprintf("%s: could not open %q", command.name, err.filename))
	}
	cwd, e := os.getwd(context.temp_allocator)
	if e != nil do return diagnose(stderr, .Failure, os.error_string(e))
	warnings: []string
	a.project.resolved_warnings = &warnings
	report: app.Invocation_Report
	a.project.report = &report
	completed: string
	output, issue, code := execute(command.name, cwd, a, stdin, &completed)
	for w in warnings do fmt.wprintf(stderr, "kadai: warning: %s\n", terminal_field(w))
	if issue != "" {
		if completed != "" {
			return diagnose(stderr, .Completed_Response_Failed, fmt.tprintf("%s, but response failed: %s", completed, issue))
		}
		if report.write_started {
			return diagnose(stderr, .Write_Incomplete, fmt.tprintf("%s did not complete. Changes may remain. %s", command.name, issue))
		}
		if lookup, failed := report.lookup_failure.?; failed {
			if lookup == .Missing do code = .Task_Not_Found
			if lookup == .Ambiguous do code = .Ambiguous_Task
		}
		return diagnose(stderr, code, issue)
	}
	if output != "" {
		if delivery := write_stdout(output, stdout, stderr, completed); delivery != .Success do return delivery
	}
	return code
}
