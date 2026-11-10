// Command dispatch, terminal streams, text/JSON output, and exit codes.
package cli

import "core:flags"
import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"
import "kadai:app"

@(private)
Options :: struct {
	version: bool `usage:"Print the Kadai version."`,
}

@(private)
help_text :: proc() -> string {
	text := strings.builder_make(context.temp_allocator)
	strings.write_string(
		&text,
		"Kadai tracks tasks in project-local Markdown files.\n\nUsage: kadai [option]\n       kadai init [--project DIR] [--tasks-root DIR] [--boards-root DIR] [--id-prefix PREFIX] [--timezone ZONE] [--exclude GLOB]\n",
	)
	flags.write_usage(strings.to_writer(&text), Options, style = .Unix)
	// Help is reserved by core:flags, so it has no field in Options.
	strings.write_string(&text, "\t-h, --help  | Show this help.\n")
	return strings.to_string(text)
}

@(private)
dispatch :: proc(args: []string) -> (message: string, ok: bool) {
	if len(args) > 1 {
		return fmt.tprintf("unexpected argument %q", args[1]), false
	}
	options: Options
	switch err in flags.parse(&options, args, .Unix) {
	case flags.Help_Request:
		return help_text(), true

	case flags.Parse_Error:
		if err.reason == .Missing_Flag || err.reason == .Extra_Positional {
			return fmt.tprintf("unknown argument %q", args[0]), false
		}
		return fmt.tprintf("invalid argument %q", args[0]), false

	case flags.Validation_Error:
		return err.message, false

	case flags.Open_File_Error:
		return fmt.tprintf("could not open %q", err.filename), false
	}

	if options.version {
		return "kadai " + app.VERSION + "\n", true
	}

	if len(args) == 0 {
		return help_text(), true
	}

	return "no operation selected", false
}

run :: proc(args: []string, stdout, stderr: io.Writer) -> int {
	if len(args) > 0 && args[0] == "init" {
		return run_init(args[1:], stderr)
	}
	message, ok := dispatch(args)
	if !ok {
		message = fmt.tprintf("kadai: %s. See 'kadai --help'.\n", message)
	}
	output := stdout if ok else stderr
	n, err := io.write_string(output, message)
	if err != .None || n != len(message) {
		if ok {
			_, _ = io.write_string(stderr, "kadai: could not write to stdout.\n")
		}
		return 1
	}
	return 0 if ok else 2
}

@(private)
run_init :: proc(args: []string, stderr: io.Writer) -> int {
	options: app.Project_Options
	excludes := make([dynamic]string, context.temp_allocator)
	for i := 0; i < len(args); i += 2 {
		if i+1 >= len(args) || args[i+1] == "" && args[i] != "--exclude" {
			fmt.wprintf(stderr, "kadai: missing value for %s\n", args[i])
			return 2
		}
		value := args[i+1]
		switch args[i] {
		case "--project":    options.project = value
		case "--tasks-root": options.tasks_root = value
		case "--boards-root": options.boards_root = value
		case "--id-prefix":  options.id_prefix = value
		case "--timezone":   options.timezone = value
		case "--exclude":
			options.override_exclude = true
			if value != "" do append(&excludes, value)
		case:
			fmt.wprintf(stderr, "kadai: unknown init option %s\n", args[i])
			return 2
		}
	}
	options.exclude = excludes[:]
	cwd, err := os.getwd(context.temp_allocator)
	if err != nil {
		fmt.wprintf(stderr, "kadai: %s\n", os.error_string(err))
		return 1
	}
	cfg, issue := app.initialize(cwd, options)
	for warning in cfg.warnings do fmt.wprintf(stderr, "kadai: %s\n", warning)
	if issue != "" {
		fmt.wprintf(stderr, "kadai: %s\n", issue)
		return 1
	}
	return 0
}
