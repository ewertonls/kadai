// Command dispatch, terminal streams, text/JSON output, and exit codes.
package cli

import "core:flags"
import "core:fmt"
import "core:io"
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
		"Kadai tracks tasks in project-local Markdown files.\n\nUsage: kadai [option]\n       kadai init [--project DIR] [--tasks-root DIR] [--boards-root DIR] [--id-prefix PREFIX] [--timezone ZONE] [--exclude GLOB]\n       kadai add TITLE [--status STATUS] [--body-file PATH | --stdin] [--path DEST]\n       kadai list | show ID\n       kadai set ID FIELD [VALUE ...] | unset ID FIELD\n       kadai status ID STATUS [--force]\n       kadai parent add CHILD PARENT | parent remove CHILD\n       kadai edit ID\n       kadai move [--directory] SOURCE DEST\n       kadai remove ID [--detach] [--dry-run] [--plan TOKEN]\n       kadai recover resume|rollback [OPERATION]\n",
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

run :: proc(args: []string, stdout, stderr: io.Writer, stdin := io.Reader{}) -> int {
	if len(args) > 0 {
		switch args[0] {
		case "init", "add", "list", "show", "set", "unset", "status", "edit", "move", "remove", "recover", "parent": return run_command(args, stdout, stderr, stdin)
		}
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
