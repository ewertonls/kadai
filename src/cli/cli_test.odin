#+test
package cli

import "core:slice"
import "core:strings"
import "core:testing"
import "kadai:app"

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
		{{"list", "--exclude", ""}, 2, "exclude"},
		{{"list", "--clear-excludes", "--exclude", "archive/"}, 2, "--clear-excludes"},
	}
	for c in cases {
		out, err: strings.Builder
		defer strings.builder_destroy(&out)
		defer strings.builder_destroy(&err)
		code := run(c.args, strings.to_writer(&out), strings.to_writer(&err))
		testing.expect_value(t, code, c.code)
		result, other := strings.to_string(out), strings.to_string(err)
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
