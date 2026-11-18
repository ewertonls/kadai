#+test
package cli

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import "kadai:app"

// A tab in a title must stay inside one field. An unresolved edge must still
// identify its two endpoints and leave a source location in validation output.
@(test)
terminal_queries_show_task_and_reference_context :: proc(t: ^testing.T) {
	root, err := os.mkdir_temp("", "kadai-terminal-", context.temp_allocator)
	if !testing.expect(t, err == nil) do return
	defer os.remove_all(root)
	for task in ([]struct {id, status, title, links: string}{
		{"A", "done", "Plan", ""},
		{"B", "todo", `"Revisar café\tdraft"`, "parent: a\ndepends_on: [a, Lost]\npriority: high\ndue: '2026-11-15'\n"},
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
	long := invoke_cli(t, {"list", "--long", "--project", root, "--tasks-root", "."}).stdout
	testing.expect(t, strings.contains(long, fmt.tprintf("%s    priority high  due 2026-11-15\n", list)), long)
	testing.expect(t, strings.contains(long, "(A.md)\n    priority -  due -\n"), long)
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

// A shared prerequisite and a handwritten cycle retain all their edges.
// Ambiguous references stay visible without choosing a file to traverse.
@(test)
dependency_graph_follows_only_the_selected_direction :: proc(t: ^testing.T) {
	root, err := os.mkdir_temp("", "kadai-dep-graph-", context.temp_allocator)
	if !testing.expect(t, err == nil) do return
	defer os.remove_all(root)
	for row, i in ([]struct {id, refs: string}{
		{"A", "[b, C]"}, {"B", "[D, Lost, DuP]"}, {"C", "[D]"}, {"D", "[b]"},
		{"E", "[A]"}, {"F", "[E]"}, {"Dup", "[F]"}, {"dup", "[]"},
	}) {
		source := fmt.tprintf("---\nkadai: task\nid: %s\ntitle: Example\nstatus: todo\ndepends_on: %s\n---\n", row.id, row.refs)
		if !testing.expect(t, os.write_entire_file(fmt.tprintf("%s/%d.md", root, i), source) == nil) do return
	}
	up := invoke_cli(t, {"dep", "graph", "a", "--project", root, "--tasks-root", ".", "--json"})
	graph := parse_result(t, up.stdout).(json.Object)
	testing.expect_value(t, graph["direction"].(string), "prerequisites")
	testing.expect_value(t, graph["task"].(json.Object)["id"].(string), "A")
	edges := graph["edges"].(json.Array)
	expected := []struct {prerequisite, dependent, resolution: string}{
		{"B", "A", "resolved"}, {"C", "A", "resolved"}, {"D", "B", "resolved"},
		{"Lost", "B", "missing"}, {"DuP", "B", "ambiguous"}, {"D", "C", "resolved"}, {"B", "D", "resolved"},
	}
	if !testing.expect_value(t, len(edges), len(expected)) do return
	for row, i in expected {
		edge := edges[i].(json.Object)
		testing.expect_value(t, edge["prerequisite"].(string), row.prerequisite)
		testing.expect_value(t, edge["dependent"].(string), row.dependent)
		testing.expect_value(t, edge["resolution"].(string), row.resolution)
	}
	down := invoke_cli(t, {"dep", "graph", "A", "dependents", "--project", root, "--tasks-root", "."})
	testing.expect_value(t, down.stdout, "Dependent graph for A (prerequisite -> dependent)\n  A -> E\n  E -> F\n")
	testing.expect(t, !os.exists(fmt.tprintf("%s/.kadai", root)))
}

@(test)
dependency_graph_encoding_discards_incomplete_output :: proc(t: ^testing.T) {
	item := app.Task_Candidate{fields = {id = "A"}}
	edges: [8]app.Dependency_Edge
	for &edge in edges do edge = {"Prerequisite", "Dependent", .Resolved}
	view := app.Dependency_Graph{task = &item, edges = edges[:]}
	for as_json in ([2]bool{false, true}) {
		space: [128]byte
		arena: mem.Arena
		mem.arena_init(&arena, space[:])
		out: string
		code: Exit_Code
		{
			context.temp_allocator = mem.arena_allocator(&arena)
			out, _, code = dependency_graph_output(view, as_json)
		}
		testing.expect_value(t, code, Exit_Code.Output_Failed)
		testing.expect_value(t, out, "")
	}
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
