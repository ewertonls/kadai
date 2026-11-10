#+private
package cli

import "core:flags"
import "kadai:app"

// core:flags reads top-level fields only, including for help. Each schema lists
// the project flags alongside the options accepted by that group of commands.
Project_Flags :: struct {
	project:        string           `usage:"Select the project directory."`,
	tasks_root:     string           `usage:"Select the task collection root."`,
	boards_root:    string           `usage:"Select the boards directory under the task root."`,
	id_prefix:      string           `usage:"Set the prefix for generated task IDs."`,
	timezone:       string           `usage:"Set the project time zone."`,
	exclude:        [dynamic]string  `usage:"Replace configured exclusions. Repeat for each glob."`,
	clear_excludes: bool             `usage:"Clear configured exclusions."`,
	limit:          [dynamic]string  `usage:"Override a resource budget: NAME=INTEGER. Repeat for different budgets."`,
	json:           bool             `usage:"Write the command result as JSON."`,
	overflow:       [dynamic]string  `args:"hidden"`,
}

List_Flags :: struct {
	project:        string           `usage:"Select the project directory."`,
	tasks_root:     string           `usage:"Select the task collection root."`,
	boards_root:    string           `usage:"Select the boards directory under the task root."`,
	id_prefix:      string           `usage:"Set the prefix for generated task IDs."`,
	timezone:       string           `usage:"Set the project time zone."`,
	exclude:        [dynamic]string  `usage:"Replace configured exclusions. Repeat for each glob."`,
	clear_excludes: bool             `usage:"Clear configured exclusions."`,
	limit:          [dynamic]string  `usage:"Override a resource budget: NAME=INTEGER. Repeat for different budgets."`,
	json:           bool             `usage:"Write the command result as JSON."`,
	overflow:       [dynamic]string  `args:"hidden"`,

	status:    string `usage:"Match the exact stored status, including configured statuses."`,
	directory: string `usage:"Include tasks in this collection-relative directory and its subdirectories."`,
	tag:       string `usage:"Match one exact tag."`,
	parent:    string `usage:"List direct children of this task ID (case-insensitive)."`,
}

Add_Flags :: struct {
	project:        string           `usage:"Select the project directory."`,
	tasks_root:     string           `usage:"Select the task collection root."`,
	boards_root:    string           `usage:"Select the boards directory under the task root."`,
	id_prefix:      string           `usage:"Set the prefix for generated task IDs."`,
	timezone:       string           `usage:"Set the project time zone."`,
	exclude:        [dynamic]string  `usage:"Replace configured exclusions. Repeat for each glob."`,
	clear_excludes: bool             `usage:"Clear configured exclusions."`,
	limit:          [dynamic]string  `usage:"Override a resource budget: NAME=INTEGER. Repeat for different budgets."`,
	json:           bool             `usage:"Write the command result as JSON."`,
	overflow:       [dynamic]string  `args:"hidden"`,

	status:    string `usage:"Set the initial task status."`,
	body_file: string `usage:"Read the Markdown body from this file."`,
	stdin:     bool   `usage:"Read the Markdown body from stdin."`,
	path:      string `usage:"Write the task at this collection-relative path."`,
}

Status_Flags :: struct {
	project:        string           `usage:"Select the project directory."`,
	tasks_root:     string           `usage:"Select the task collection root."`,
	boards_root:    string           `usage:"Select the boards directory under the task root."`,
	id_prefix:      string           `usage:"Set the prefix for generated task IDs."`,
	timezone:       string           `usage:"Set the project time zone."`,
	exclude:        [dynamic]string  `usage:"Replace configured exclusions. Repeat for each glob."`,
	clear_excludes: bool             `usage:"Clear configured exclusions."`,
	limit:          [dynamic]string  `usage:"Override a resource budget: NAME=INTEGER. Repeat for different budgets."`,
	json:           bool             `usage:"Write the command result as JSON."`,
	overflow:       [dynamic]string  `args:"hidden"`,

	force: bool `usage:"Allow a blocked or unresolved task to transition to done."`,
}

Move_Flags :: struct {
	project:        string           `usage:"Select the project directory."`,
	tasks_root:     string           `usage:"Select the task collection root."`,
	boards_root:    string           `usage:"Select the boards directory under the task root."`,
	id_prefix:      string           `usage:"Set the prefix for generated task IDs."`,
	timezone:       string           `usage:"Set the project time zone."`,
	exclude:        [dynamic]string  `usage:"Replace configured exclusions. Repeat for each glob."`,
	clear_excludes: bool             `usage:"Clear configured exclusions."`,
	limit:          [dynamic]string  `usage:"Override a resource budget: NAME=INTEGER. Repeat for different budgets."`,
	json:           bool             `usage:"Write the command result as JSON."`,
	overflow:       [dynamic]string  `args:"hidden"`,

	directory: bool `usage:"Move a directory within the collection."`,
}

Remove_Flags :: struct {
	project:        string           `usage:"Select the project directory."`,
	tasks_root:     string           `usage:"Select the task collection root."`,
	boards_root:    string           `usage:"Select the boards directory under the task root."`,
	id_prefix:      string           `usage:"Set the prefix for generated task IDs."`,
	timezone:       string           `usage:"Set the project time zone."`,
	exclude:        [dynamic]string  `usage:"Replace configured exclusions. Repeat for each glob."`,
	clear_excludes: bool             `usage:"Clear configured exclusions."`,
	limit:          [dynamic]string  `usage:"Override a resource budget: NAME=INTEGER. Repeat for different budgets."`,
	json:           bool             `usage:"Write the command result as JSON."`,
	overflow:       [dynamic]string  `args:"hidden"`,

	detach:  bool   `usage:"Remove references to this task."`,
	dry_run: bool   `usage:"Preview removal and print its plan token."`,
	plan:    string `usage:"Require the removal plan to match this token."`,
}

Arguments :: struct {
	project: app.Project_Options,
	limits: app.Scan_Limits,
	list_filter: app.List_Filter,
	words: []string,
	body_file, destination, plan: string,
	status: Maybe(string),
	stdin, force, directory, detach, dry_run, json: bool,
}

parse_options :: proc($T: typeid, args: []string) -> (a: Arguments, err: flags.Error) {
	options: T
	err = flags.parse(&options, args, .Unix, allocator = context.temp_allocator)
	if err != nil do return
	problem: string
	a.limits, problem = parse_limits(options.limit[:])
	if problem != "" do return a, flags.Validation_Error{problem}

	if options.clear_excludes && len(options.exclude) > 0 {
		return a, flags.Validation_Error{"choose either --exclude or --clear-excludes"}
	}
	a.project = {
		project          = options.project,
		tasks_root       = options.tasks_root,
		boards_root      = options.boards_root,
		id_prefix        = options.id_prefix,
		timezone         = options.timezone,
		exclude          = options.exclude[:],
		override_exclude = options.clear_excludes || len(options.exclude) > 0,
	}
	a.words = options.overflow[:]
	a.json = options.json

	when T == List_Flags {
		a.list_filter = {status = options.status, directory = options.directory, tag = options.tag, parent = options.parent}
	} else when T == Add_Flags {
		if options.stdin && options.body_file != "" {
			return a, flags.Validation_Error{"choose one body source: --body-file or --stdin"}
		}
		if options.status != "" do a.status = options.status
		a.body_file = options.body_file
		a.stdin = options.stdin
		a.destination = options.path
	} else when T == Status_Flags {
		a.force = options.force
	} else when T == Move_Flags {
		a.directory = options.directory
	} else when T == Remove_Flags {
		a.detach = options.detach
		a.dry_run = options.dry_run
		a.plan = options.plan
	}
	return
}
