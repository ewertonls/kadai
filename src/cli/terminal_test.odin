#+test
package cli

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// A tab in a title must stay inside one field. An unresolved edge must still
// identify its two endpoints and leave a source location in validation output.
@(test)
terminal_queries_show_task_and_reference_context :: proc(t: ^testing.T) {
	root, err := os.mkdir_temp("", "kadai-terminal-", context.temp_allocator)
	if !testing.expect(t, err == nil) do return
	defer os.remove_all(root)
	for task in ([]struct {id, status, title, links: string}{
		{"A", "done", "Plan", ""},
		{"B", "todo", `"Revisar café\tdraft"`, "parent: a\ndepends_on: [a, Lost]\n"},
		{"C", "done", "Ship", "depends_on: [B]\n"},
	}) {
		path := fmt.tprintf("%s/%s.md", root, task.id)
		source := fmt.tprintf("---\nkadai: task\nid: %s\ntitle: %s\nstatus: %s\n%s---\n",
		                      task.id, task.title, task.status, task.links)
		if !testing.expect(t, os.write_entire_file(path, source) == nil) do return
	}
	list := invoke_cli(t, {"list", "--project", root, "--tasks-root", ".", "--status", "todo"}).stdout
	testing.expect_value(t, strings.count(list, "\n"), 1)
	testing.expect(t, strings.contains(list, `café\tdraft`) && strings.contains(list, "B.md") && !strings.contains(list, "\t"), list)
	// Directional overrides in a file name can otherwise reorder the visible suffix.
	testing.expect(t, strings.contains(terminal_field("notes\u202etxt.md"), `\u202e`))

	tree := invoke_cli(t, {"tree", "--project", root, "--tasks-root", "."}).stdout
	testing.expect(t, strings.has_prefix(tree, "A ") && strings.contains(tree, "\n  - B ") && strings.contains(tree, "\nC "), tree)
	deps := invoke_cli(t, {"dep", "show", "b", "--project", root, "--tasks-root", "."}).stdout
	for edge in ([]string{"A -> B", "Lost -> B  [missing prerequisite]", "B -> C"}) do testing.expect(t, strings.contains(deps, edge), deps)

	report := invoke_cli(t, {"validate", "--project", root, "--tasks-root", "."}, 1).stdout
	for detail in ([]string{"B.md:7:17: error [missing_prerequisite]", "target=Lost", "warning [completed_with_unmet_prerequisites]", "1 error, 1 warning"}) {
		testing.expect(t, strings.contains(report, detail), report)
	}
	// A nonzero validation exit still delivers the structured finding on stdout.
	machine := invoke_cli(t, {"validate", "--json", "--project", root, "--tasks-root", "."}, 1)
	findings := parse_result(t, machine.stdout).(json.Object)["findings"].(json.Array)
	if !testing.expect_value(t, len(findings), 2) do return
	missing := findings[0].(json.Object)
	testing.expect_value(t, missing["code"].(string), "missing_prerequisite")
	testing.expect_value(t, missing["target_id"].(string), "Lost")
	testing.expect_value(t, missing["location"].(json.Object)["column"].(i64), 17)
}

// A filename must not reorder or split the diagnostic printed by the CLI.
@(test)
terminal_errors_escape_file_names :: proc(t: ^testing.T) {
	root, err := os.mkdir_temp("", "kadai-terminal-error-", context.temp_allocator)
	if !testing.expect(t, err == nil) do return
	defer os.remove_all(root)
	if !testing.expect(t, os.mkdir(fmt.tprintf("%s/tasks", root)) == nil) do return
	// The direction override is legal in filenames on all supported hosts.
	name := "task\u202efake.md"
	err = os.write_entire_file(fmt.tprintf("%s/tasks/%s", root, name), "---\nkadai: task\n---\n")
	if !testing.expect(t, err == nil, os.error_string(err)) do return
	out := invoke_cli(t, {"list", "--project", root, "--limit=task_source_bytes=10"}, 1)
	testing.expect_value(t, out.stdout, "")
	start := strings.last_index(out.stderr, "kadai: error:")
	if !testing.expect(t, start >= 0) do return
	line := out.stderr[start:]
	testing.expect(t, strings.count(line, "\n") == 1 && !strings.contains_rune(line, '\u202e'), line)
	testing.expect(t, strings.contains(line, `task\u202efake.md`), line)

	// Pass bytes that Windows cannot store in filenames directly to the diagnostic.
	for sample in ([]struct {name, escaped: string}{
		{"task\x1b[2J\nFAKE SUCCESS.md", `task\e[2J\nFAKE SUCCESS.md`},
		{"bad\xff.md", `bad\xff.md`},
	}) {
		err_line: strings.Builder
		defer strings.builder_destroy(&err_line)
		code := diagnose(strings.to_writer(&err_line), .Failure, sample.name)
		testing.expect_value(t, code, Exit_Code.Failure)
		testing.expect_value(t, strings.to_string(err_line), fmt.tprintf("kadai: error: \"%s\"\n", sample.escaped))
	}
}
