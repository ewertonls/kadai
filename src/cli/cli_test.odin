#+test
package cli

import "core:fmt"
import "core:io"
import "core:slice"
import "core:strings"
import "core:testing"
import "kadai:app"

@(private)
CLI_Output :: struct {stdout, stderr: string}

@(private)
invoke_cli :: proc(t: ^testing.T, args: []string, expected := 0, stdin := io.Reader{}) -> CLI_Output {
	out, err: strings.Builder
	defer strings.builder_destroy(&out)
	defer strings.builder_destroy(&err)
	code := run(args, strings.to_writer(&out), strings.to_writer(&err), stdin)
	testing.expect(t, code == expected, fmt.tprintf("%v: exit %d, expected %d: %s", args, code, expected, strings.to_string(err)))
	return {strings.clone(strings.to_string(out), context.temp_allocator), strings.clone(strings.to_string(err), context.temp_allocator)}
}

@(test)
dispatch_arguments :: proc(t: ^testing.T) {
	cases := []struct {args: []string, code: int, contains: string}{
		{nil, 0, "Create a Markdown task and print its ID."},
		{{"--help"}, 0, "--version"},
		{{"-h"}, 0, "--help"},
		{{"--version"}, 0, "kadai " + app.VERSION + "\n"},
		{{"unknown"}, 2, "unknown argument"},
		{{"--unknown"}, 2, "unknown argument"},
		{{"--version=invalid"}, 2, "invalid argument"},
		{{"--help", "extra"}, 2, "unexpected argument"},
		{{"--version", "--help"}, 2, "unexpected argument"},
		{{"add", "--help"}, 0, "--body-file"},
		{{"help"}, 0, "Commands:"},
		{{"help", "dep"}, 0, "kadai dep add 0002 0001"},
		{{"help", "missing"}, 2, "unknown command"},
		{{"help", "add", "extra"}, 2, "extra"},
		{{"list", "--force"}, 2, "force"},
		{{"add", "Title", "--stdin", "--body-file", "body.md"}, 2, "choose one body source"},
		{{"help", "init"}, 0, "scan_yaml_nodes"},
		{{"add", "Title", "--body-file", "missing-body.md", "--limit=yaml_depth=0"}, 2, "--limit yaml_depth"},
		{{"list", "--exclude", ""}, 2, "exclude"},
		{{"list", "--clear-excludes", "--exclude", "archive/"}, 2, "--clear-excludes"},
		{{"init", "extra"}, 2, "no positional arguments"},
		{{"add"}, 2, "requires a title"},
		{{"list", "extra"}, 2, "no positional arguments"},
		{{"show"}, 2, "requires an ID"},
		{{"set", "0001", "id", "NEW"}, 2, "not an editable core field"},
		{{"set", "0001", "title"}, 2, "one scalar value"},
		{{"set", "0001", "title", "too", "many"}, 2, "one scalar value"},
		{{"set", "0001", "tags", "cli", "--force"}, 2, "force applies only"},
		{{"unset", "0001", "status"}, 2, "unset supports only"},
		{{"unset", "0001", "tags", "cli"}, 2, "expected an ID and field"},
		{{"status", "0001"}, 2, "ID and status"},
		{{"edit"}, 2, "requires an ID"},
		{{"move", "0001"}, 2, "source and destination"},
		{{"remove"}, 2, "requires an ID"},
		{{"parent", "add", "0001"}, 2, "parent add CHILD PARENT"},
		{{"dep", "add", "0001"}, 2, "dep add|remove TASK PREREQUISITE"},
		{{"tree", "extra"}, 2, "no positional arguments"},
		{{"ready", "0001", "0002"}, 2, "optional task ID"},
		{{"validate", "extra"}, 2, "no positional arguments"},
		{{"recover", "invalid"}, 2, "unknown recovery mode"},
	}
	for c in cases {
		output := invoke_cli(t, c.args, c.code)
		result, other := output.stdout, output.stderr
		if c.code != 0 {
			result, other = other, result
		}
		testing.expect(t, strings.contains(result, c.contains), result)
		testing.expect_value(t, other, "")
	}
}

@(test)
set_operands_keep_order_around_flags :: proc(t: ^testing.T) {
	a, err := parse_options(Status_Flags, {"0001", "--project=repo", "tags", "cli", "--", "-draft", "--help"})
	if !testing.expect(t, err == nil) do return
	testing.expect_value(t, a.project.project, "repo")
	testing.expect(t, slice.equal(a.words, []string{"0001", "tags", "cli", "-draft", "--help"}))
}

@(test)
project_exclusion_options :: proc(t: ^testing.T) {
	cases := []struct{args: []string, override: bool, patterns: []string}{
		{nil, false, nil},
		{{"--exclude", "archive/", "--exclude=drafts/"}, true, {"archive/", "drafts/"}},
		{{"--clear-excludes"}, true, nil},
	}
	for c in cases {
		a, err := parse_options(Project_Flags, c.args)
		if !testing.expect(t, err == nil) do continue
		testing.expect_value(t, a.project.override_exclude, c.override)
		testing.expect(t, slice.equal(a.project.exclude, c.patterns))
	}
}

@(test)
stdout_write_failure :: proc(t: ^testing.T) {
	err: strings.Builder
	defer strings.builder_destroy(&err)
	code := run({"--version"}, {}, strings.to_writer(&err))
	testing.expect_value(t, code, 1)
	testing.expect(t, strings.contains(strings.to_string(err), "stdout"))
}
