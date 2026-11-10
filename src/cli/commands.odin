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
	body_file, destination: string,
	status: Maybe(string),
	stdin: bool,
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
		if name == "--stdin" && a.command == "add" { a.stdin = true; continue }
		if i+1 >= len(args) { return a, fmt.tprintf("missing value for %s", name) }
		i += 1
		value := args[i]
		if value == "" && name != "--exclude" do return a, fmt.tprintf("empty value for %s", name)
		switch name {
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
