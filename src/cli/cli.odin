// Command dispatch, terminal streams, text/JSON output, and exit codes.
package cli

import "core:flags"
import "core:fmt"
import "core:io"
import "kadai:app"

@(private)
Options :: struct {
	version: bool `usage:"Print the Kadai version."`,
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

@(private)
write_stdout :: proc(message: string, stdout, stderr: io.Writer) -> int {
	n, err := io.write_string(stdout, message)
	if err != .None || n != len(message) {
		_, _ = io.write_string(stderr, "kadai: could not write to stdout.\n")
		return 1
	}
	return 0
}

run :: proc(args: []string, stdout, stderr: io.Writer, stdin := io.Reader{}) -> int {
	if len(args) > 0 {
		if command, ok := find_command(args[0]); ok {
			return run_command(command, args[1:], stdout, stderr, stdin)
		}
	}
	message, ok := dispatch(args)
	if ok do return write_stdout(message, stdout, stderr)

	message = fmt.tprintf("kadai: %s. See 'kadai --help'.\n", message)
	n, err := io.write_string(stderr, message)
	return 2 if err == .None && n == len(message) else 1
}
