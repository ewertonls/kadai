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

// These values are part of the shell contract in docs/development/cli.md.
@(private)
Exit_Code :: enum int {
	Success = 0,
	Failure = 1,
	Usage = 2,
	Task_Not_Found = 3,
	Ambiguous_Task = 4,
	Write_Incomplete = 5,
	Completed_Response_Failed = 6,
	Output_Failed = 7,
}

@(private)
diagnose :: proc(stderr: io.Writer, code: Exit_Code, message: string) -> Exit_Code {
	// stderr is best effort. Its availability cannot change the command outcome.
	fmt.wprintf(stderr, "kadai: error: %s\n", terminal_field(message))
	return code
}

@(private)
write_stdout :: proc(message: string, stdout, stderr: io.Writer, completed := "") -> Exit_Code {
	n, err := io.write_string(stdout, message)
	if err == .None && n == len(message) do return .Success
	if completed != "" {
		return diagnose(stderr, .Completed_Response_Failed, fmt.tprintf("%s, but could not write the response to stdout", completed))
	}
	return diagnose(stderr, .Output_Failed, "could not write to stdout")
}

run :: proc(args: []string, stdout, stderr: io.Writer, stdin := io.Reader{}) -> int {
	if len(args) > 0 {
		if command, ok := find_command(args[0]); ok {
			return int(run_command(command, args[1:], stdout, stderr, stdin))
		}
	}
	message, ok := dispatch(args)
	if ok do return int(write_stdout(message, stdout, stderr))

	return int(diagnose(stderr, .Usage, fmt.tprintf("%s. See 'kadai --help'.", message)))
}
