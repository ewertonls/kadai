package cli

import "core:flags"
import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"
import "core:unicode/utf8"
import "kadai:app"

@(private, rodata)
READINESS_LABELS := [app.Readiness]string {
	.Ready      = "ready",
	.Blocked    = "blocked",
	.Unresolved = "unresolved",
}

@(private)
read_body_input :: proc(a: Arguments, stdin: io.Reader) -> (string, string) {
	if a.stdin {
		if stdin.procedure == nil do return "", "stdin unavailable"
		return app.read_body(stdin, a.limits.source_bytes)
	}
	if a.body_file == "" do return "", ""
	f, err := os.open(a.body_file)
	if err != nil do return "", fmt.tprintf("%s: %s", a.body_file, os.error_string(err))
	defer os.close(f)
	return app.read_body(os.to_reader(f), a.limits.source_bytes)
}

@(private)
execute :: proc(
	command, cwd: string,
	a: Arguments,
	stdin: io.Reader,
	completed: ^string,
) -> (
	output, issue: string,
	code: Exit_Code,
) {
	operation: string
	switch command {
	case "init":
		if len(a.words) != 0 do return "", "init takes no positional arguments", .Usage
		_, issue = app.initialize(cwd, a.project, a.limits, git = a.git)
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
		return task_text_result(rows)
	case "tree":
		if len(a.words) != 0 do return "", "tree takes no positional arguments", .Usage
		rows, problem := app.task_tree(cwd, a.project, a.limits)
		if problem != "" do return "", problem, .Failure
		if a.json do return json_result(rows)
		return task_text_result(rows)
	case "list":
		if len(a.words) != 0 do return "", "list takes no positional arguments", .Usage
		items, problem := app.list_tasks(cwd, a.project, a.limits, a.list_filter, a.list_sort)
		if problem != "" do return "", problem, .Failure
		if a.json do return json_result(items)
		text, err := list_text(items, a.long)
		if err != nil do return "", "cannot encode task list", .Output_Failed
		return text, "", .Success
	case "remove":
		if len(a.words) != 1 do return "", "remove requires an ID", .Usage
		remove := app.Removal {
			id            = a.words[0],
			detach        = a.detach,
			expected_plan = a.plan,
		}
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
			return "",
				"remove requires --yes or --plan TOKEN to delete a task. Use --dry-run to preview",
				.Usage
		}
		operation, issue = app.remove_task(cwd, a.project, remove, a.limits)
		output = fmt.tprintf("%s\n", operation)
	case "recover":
		if len(a.words) > 0 && a.words[0] == "prune" {
			if a.dry_run == a.yes do return "", "recover prune requires exactly one of --dry-run or --yes", .Usage
			ids, problem := app.prune_recovery(
				cwd,
				a.project,
				a.older_than,
				a.dry_run,
				a.limits,
				a.words[1:],
			)
			if problem != "" do return "", problem, .Failure
			if !a.dry_run && len(ids) > 0 do completed^ = "recover prune completed"
			result := Prune_Result{a.dry_run, ids}
			if a.json do return json_result(result)
			return task_text_result(result)
		}
		if len(a.words) < 1 || len(a.words) > 2 do return "", "recover requires resume, rollback or prune", .Usage
		id := ""
		if len(a.words) == 2 {
			id = a.words[1]
			if id == "" do return "", "recovery operation ID cannot be empty", .Usage
		}
		mode: app.Recovery_Mode
		switch a.words[0] {
		case "resume":
			mode = .Resume
		case "rollback":
			mode = .Rollback
		case:
			return "", "unknown recovery mode", .Usage
		}
		if !a.yes do return "", "recover requires --yes to apply the operation", .Usage
		operation, issue = app.recover_collection(cwd, a.project, mode, id, a.limits)
	case "log":
		if len(a.words) < 2 do return "", "expected log list ID or log add ID (MESSAGE | --stdin | --body-file FILE)", .Usage
		external_body := a.stdin || a.body_file != ""
		switch a.words[0] {
		case "list":
			if len(a.words) != 2 || external_body do return "", "log list takes only a task ID", .Usage
			entries, problem := app.list_log(cwd, a.project, a.words[1], a.limits)
			if problem != "" do return "", problem, .Failure
			if a.json do return json_result(entries)
			return task_text_result(entries)
		case "add":
			content: string
			if external_body && len(a.words) == 2 {
				content, issue = read_body_input(a, stdin)
				if issue != "" do return "", issue, .Failure
			} else if !external_body && len(a.words) == 3 {
				content = a.words[2]
			} else {
				return "",
					"log add requires exactly one entry source: MESSAGE, --stdin or --body-file FILE",
					.Usage
			}
			operation, issue = app.add_log(cwd, a.project, a.words[1], content, a.limits)
		case:
			return "", "expected log add or log list", .Usage
		}
	case "dep":
		if len(a.words) > 0 && a.words[0] == "graph" {
			if len(a.words) < 2 || len(a.words) > 3 do return "", "expected dep graph ID [prerequisites|dependents]", .Usage
			direction := app.Dependency_Direction.Prerequisites
			if len(a.words) == 3 {
				switch a.words[2] {
				case "prerequisites":
				case "dependents":
					direction = .Dependents
				case:
					return "", "dep graph direction must be prerequisites or dependents", .Usage
				}
			}
			view, problem := app.dependency_graph(cwd, a.project, a.words[1], direction, a.limits)
			if problem != "" do return "", problem, .Failure
			return dependency_graph_output(view, a.json)
		}
		if len(a.words) == 2 && a.words[0] == "show" {
			view, problem := app.dependencies(cwd, a.project, a.words[1], a.limits)
			if problem != "" do return "", problem, .Failure
			if a.json do return json_result(view)
			return task_text_result(view)
		}
		if len(a.words) != 3 || (a.words[0] != "add" && a.words[0] != "remove") do return "", "expected dep show ID, dep graph ID [prerequisites|dependents] or dep add|remove TASK PREREQUISITE", .Usage
		operation, issue = app.change_dependency(
			cwd,
			a.project,
			a.words[1],
			a.words[2],
			a.words[0] == "remove",
			a.limits,
		)
	case "parent":
		if len(a.words) == 3 && a.words[0] == "add" {
			operation, issue = app.set_parent(cwd, a.project, a.words[1], a.words[2], a.limits)
		} else if len(a.words) == 2 && a.words[0] == "remove" {
			operation, issue = app.set_parent(cwd, a.project, a.words[1], nil, a.limits)
		} else {return "", "expected parent add CHILD PARENT or parent remove CHILD", .Usage}
	case "move":
		if len(a.words) != 2 do return "", "move requires a source and destination", .Usage
		operation, issue = app.move_task(
			cwd,
			a.project,
			{a.words[0], a.words[1], a.directory},
			a.limits,
		)
	case "edit":
		if len(a.words) != 1 do return "", "edit requires an ID", .Usage
		editor := a.editor
		if editor == "" do editor = os.get_env("EDITOR", context.temp_allocator)
		args, problem, alloc_err := app.editor_arguments(editor)
		if alloc_err != nil do return "", "cannot allocate editor arguments", .Failure
		if problem != "" do return "", problem, .Usage if a.editor != "" else .Failure
		editor_out := os.stderr if a.json else os.stdout
		issue = app.edit_task(cwd, a.project, a.words[0], args, a.limits, editor_out)
	case "status":
		if len(a.words) != 2 do return "", "status requires an ID and status", .Usage
		operation, issue = app.set_status(
			cwd,
			a.project,
			a.words[0],
			a.words[1],
			a.force,
			a.limits,
		)
	case "set", "unset":
		if len(a.words) < 2 || command == "unset" && len(a.words) != 2 do return "", "expected an ID and field", .Usage
		field := a.words[1]
		switch field {
		case "title", "status":
			if command == "unset" do return "", "unset supports only priority, due and tags", .Usage
		case "priority", "due", "tags":
		case:
			return "", fmt.tprintf("not an editable core field: %s", field), .Usage
		}
		if command == "set" && field != "tags" && len(a.words) != 3 do return "", "set requires one scalar value", .Usage
		if a.force && field != "status" do return "", "force applies only to a status transition", .Usage
		operation, issue = app.update_task(
			cwd,
			a.project,
			{
				id = a.words[0],
				field = field,
				values = a.words[2:],
				unset = command == "unset",
				force = a.force,
			},
			a.limits,
		)
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
	case "add", "import":
		if command == "import" {
			if len(a.words) != 1 do return "", "import requires one Markdown source file", .Usage
			if !a.yes do return "", "import requires --yes to copy the source into a new task", .Usage
		} else if len(a.words) != 1 do return "", "add requires a title", .Usage
		if a.json && !utf8.valid_string(a.destination) do return "", "unsupported_output: JSON requires a UTF-8 task path", .Output_Failed
		request := app.Create_Task {
			title       = a.words[0],
			destination = a.destination,
			status      = a.status,
		}
		if command == "import" {
			request.title, request.body, issue = app.read_import(
				cwd,
				a.words[0],
				a.title,
				a.limits,
			)
		} else {
			request.body, issue = read_body_input(a, stdin)
		}
		if issue != "" do return "", issue, .Failure
		created, problem := app.create_task_result(cwd, a.project, request, a.limits)
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
run_command :: proc(
	command: Command,
	args: []string,
	stdout, stderr: io.Writer,
	stdin: io.Reader,
) -> Exit_Code {
	a: Arguments
	parse_err: flags.Error
	switch command.flag_type {
	case Project_Flags:
		a, parse_err = parse_options(Project_Flags, args)
	case Init_Flags:
		a, parse_err = parse_options(Init_Flags, args)
	case List_Flags:
		a, parse_err = parse_options(List_Flags, args)
	case Add_Flags:
		a, parse_err = parse_options(Add_Flags, args)
	case Log_Flags:
		a, parse_err = parse_options(Log_Flags, args)
	case Import_Flags:
		a, parse_err = parse_options(Import_Flags, args)
	case Edit_Flags:
		a, parse_err = parse_options(Edit_Flags, args)
	case Status_Flags:
		a, parse_err = parse_options(Status_Flags, args)
	case Move_Flags:
		a, parse_err = parse_options(Move_Flags, args)
	case Remove_Flags:
		a, parse_err = parse_options(Remove_Flags, args)
	case Recover_Flags:
		a, parse_err = parse_options(Recover_Flags, args)
	case Help_Flags:
		topic: Help_Flags
		parse_err = flags.parse(&topic, args, .Unix, allocator = context.temp_allocator)
		if parse_err == nil {
			if topic.command == "" do return write_stdout(help_text(), stdout, stderr)
			if target, ok := find_command(topic.command); ok {
				return write_stdout(command_help(target), stdout, stderr)
			}
			return diagnose(
				stderr,
				.Usage,
				fmt.tprintf(
					"help: unknown command %q. Run 'kadai help' to list commands.",
					topic.command,
				),
			)
		}
	case:
		unreachable()
	}

	switch err in parse_err {
	case flags.Help_Request:
		return write_stdout(command_help(command), stdout, stderr)
	case flags.Parse_Error:
		return diagnose(stderr, .Usage, fmt.tprintf("%s: %s", command.name, err.message))
	case flags.Validation_Error:
		return diagnose(stderr, .Usage, fmt.tprintf("%s: %s", command.name, err.message))
	case flags.Open_File_Error:
		return diagnose(
			stderr,
			.Usage,
			fmt.tprintf("%s: could not open %q", command.name, err.filename),
		)
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
			return diagnose(
				stderr,
				.Completed_Response_Failed,
				fmt.tprintf("%s, but response failed: %s", completed, issue),
			)
		}
		if report.write_started {
			return diagnose(
				stderr,
				.Write_Incomplete,
				fmt.tprintf("%s did not complete. Changes may remain. %s", command.name, issue),
			)
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
