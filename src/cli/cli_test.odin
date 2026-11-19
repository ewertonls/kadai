#+test
package cli

import "core:encoding/json"
import "core:fmt"
import "core:io"
import "core:mem"
import "core:os"
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
		{{"help", "log"}, 0, "kadai log add ID --body-file FILE"},
		{{"help", "missing"}, 2, "unknown command"},
		{{"help", "add", "extra"}, 2, "extra"},
		{{"help", "import"}, 0, "kadai import SOURCE.md --yes"},
		{{"import", "missing.md"}, 2, "requires --yes"},
		{{"import", "one.md", "two.md", "--yes"}, 2, "one Markdown source file"},
		{{"list", "--force"}, 2, "force"},
		{{"list", "--where", "status=todo OR"}, 2, "--where"},
		{{"list", "--where", "id=A XOR id=B"}, 2, "AND or OR"},
		{{"list", "--where", "title=notes"}, 2, "unknown --where field"},
		{{"list", "--sort", "unknown"}, 2, "sort"},
		{{"list", "--order", "sideways"}, 2, "order"},
		{{"list", "--long", "--json"}, 2, "choose either --long or --json"},
		{{"list", "--editor", "vim"}, 2, "editor"},
		{{"help", "list"}, 0, "--parent"},
		{{"show", "0001", "--tag", "release"}, 2, "tag"},
		{{"add", "Title", "--stdin", "--body-file", "body.md"}, 2, "choose one body source"},
		{{"log", "add", "0001"}, 2, "exactly one entry source"},
		{{"log", "add", "0001", "message", "--stdin"}, 2, "exactly one entry source"},
		{{"log", "add", "0001", "--stdin", "--body-file", "note.md"}, 2, "choose one body source"},
		{{"log", "list", "0001", "--body-file", "note.md"}, 2, "log list takes only a task ID"},
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
		{{"edit", "0001", "--editor", "'unterminated", "--json"}, 2, "unterminated quote in editor command"},
		{{"edit", "0001", "--editor", "   "}, 2, "specify an executable"},
		{{"move", "0001"}, 2, "source and destination"},
		{{"remove"}, 2, "requires an ID"},
		{{"parent", "add", "0001"}, 2, "parent add CHILD PARENT"},
		{{"dep", "add", "0001"}, 2, "dep add|remove TASK PREREQUISITE"},
		{{"dep", "graph", "A", "both"}, 2, "prerequisites or dependents"},
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
edit_reports_argument_allocation_failure :: proc(t: ^testing.T) {
	editor := fmt.tprintf("code --wait %s", strings.repeat("x", 256, context.temp_allocator))
	space: [144]byte
	arena: mem.Arena
	mem.arena_init(&arena, space[:])
	issue, completed: string
	code: Exit_Code
	{
		context.temp_allocator = mem.arena_allocator(&arena)
		_, issue, code = execute("edit", ".", {words = {"0001"}, editor = editor}, {}, &completed)
	}
	testing.expect_value(t, code, Exit_Code.Failure)
	testing.expect_value(t, issue, "cannot allocate editor arguments")
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
	testing.expect_value(t, code, 7)
	// A closed diagnostic stream still leaves a script the argument error.
	testing.expect_value(t, run({"--unknown"}, {}, {}), 2)
	testing.expect(t, strings.contains(strings.to_string(err), "stdout"))
}

@(test)
destructive_commands_require_explicit_flags :: proc(t: ^testing.T) {
	tmp, err := os.mkdir_temp("", "kadai-automation-", context.temp_allocator)
	if !testing.expect(t, err == nil) do return
	defer os.remove_all(tmp)
	reader: strings.Reader
	input := strings.to_reader(&reader, "yes\n")
	created := invoke_cli(t, {"add", "Keep", "--project", tmp}, stdin = input)
	if !testing.expect_value(t, created.stdout, "0001\n") do return
	path := fmt.tprintf("%s/tasks/0001.md", tmp)
	for args in ([][]string{
		{"remove", "0001", "--project", tmp},
		{"remove", "0001", "--detach", "--json", "--project", tmp},
		{"recover", "resume", "--project", tmp},
	}) {
		out := invoke_cli(t, args, 2, input)
		testing.expect_value(t, out.stdout, "")
		testing.expect(t, strings.contains(out.stderr, "--yes"))
	}
	testing.expect_value(t, strings.reader_length(&reader), len("yes\n"))
	if !testing.expect(t, os.exists(path)) do return

	preview := invoke_cli(t, {"remove", "0001", "--project", tmp, "--yes", "--dry-run", "--json"})
	token := parse_result(t, preview.stdout).(json.Object)["plan"].(string)
	if !testing.expect(t, token != "" && os.exists(path)) do return
	stale := invoke_cli(t, {"remove", "0001", "--project", tmp, "--yes", "--plan", "stale"}, 1)
	testing.expect(t, strings.contains(stale.stderr, "stale removal plan") && os.exists(path))
	deleted := invoke_cli(t, {"remove", "0001", "--project", tmp, "--plan", token})
	operation := strings.trim_space(deleted.stdout)
	if !testing.expect(t, operation != "" && !os.exists(path)) do return
	_ = invoke_cli(t, {"recover", "rollback", operation, "--project", tmp}, 2)
	empty := invoke_cli(t, {"recover", "rollback", "", "--yes", "--project", tmp}, 2)
	testing.expect(t, strings.contains(empty.stderr, "operation ID cannot be empty"))
	testing.expect(t, !os.exists(path))
	_ = invoke_cli(t, {"recover", "rollback", operation, "--project", tmp, "--yes"})
	testing.expect(t, os.exists(path))
	_ = invoke_cli(t, {"remove", "0001", "--project", tmp, "--yes"})
	testing.expect(t, !os.exists(path))
}

// The same lookup must report ambiguity in either format. In JSON mode even
// an explicit symlink warning on a successful scan belongs on stderr.
@(test)
lookup_exit_status_and_warning_stream :: proc(t: ^testing.T) {
	project := fmt.tprintf("%s/../../tests/fixtures/v1/cases/identity/duplicate-id-repair-needs-reference-choice/input/project", #directory)
	invalid := invoke_cli(t, {"show", "bad id", "--project", project}, 1)
	testing.expect(t, strings.contains(invalid.stderr, "invalid task ID"))
	when ODIN_OS != .Windows {
		tmp, err := os.mkdir_temp("", "kadai-streams-", context.temp_allocator)
		if !testing.expect(t, err == nil) do return
		defer os.remove_all(tmp)
		alias := fmt.tprintf("%s/alias", tmp)
		if !testing.expect(t, os.symlink(project, alias) == nil) do return
		list := invoke_cli(t, {"list", "--json", "--project", alias})
		_ = parse_result(t, list.stdout)
		testing.expect(t, strings.has_prefix(list.stderr, "kadai: warning: ") && strings.contains(list.stderr, "alias"))
	}
	for args in ([][]string{{"show", "dup", "--project", project}, {"list", "--parent", "dup", "--json", "--project", project}}) {
		out := invoke_cli(t, args, 4)
		testing.expect_value(t, out.stdout, "")
		testing.expect(t, strings.contains(out.stderr, "ambiguous task ID"))
	}
}

// A journal can survive a failure while preparing the task write.
// Conversely, a caller can supply an operation ID to a recovery that never wrote.
@(test)
incomplete_write_exit_tracks_filesystem_effects :: proc(t: ^testing.T) {
	tmp, err := os.mkdir_temp("", "kadai-write-exit-", context.temp_allocator)
	if !testing.expect(t, err == nil) do return
	defer os.remove_all(tmp)
	recovery := fmt.tprintf("%s/tasks/.kadai/recovery", tmp)
	_ = invoke_cli(t, {"add", "T", "--project", tmp, "--limit=yaml_document_bytes=96"}, 1)
	_ = invoke_cli(t, {"recover", "rollback", "ffffffffffffffffffffffffffffffff", "--project", tmp, "--yes"}, 1)
	testing.expect(t, !os.exists(recovery))
	out := invoke_cli(t, {"add", "T", "--json", "--project", tmp, "--limit=yaml_document_bytes=100"}, 5)
	testing.expect_value(t, out.stdout, "")
	testing.expect(t, strings.contains(out.stderr, "operation ") && strings.contains(out.stderr, "journal exceeds byte limit"), out.stderr)
	testing.expect(t, os.exists(recovery) && !os.exists(fmt.tprintf("%s/tasks/0001.md", tmp)))
}
