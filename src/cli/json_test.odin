#+test
package cli

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"

@(private)
parse_result :: proc(t: ^testing.T, output: string) -> json.Value {
	value, err := json.parse(
		output,
		.JSON,
		parse_integers = true,
		allocator = context.temp_allocator,
	)
	if err != .None do testing.fail_now(t, output)
	envelope := value.(json.Object)
	testing.expect_value(t, envelope["version"].(i64), 1)
	return envelope["result"]
}

@(test)
list_expression_combines_with_flags_in_both_outputs :: proc(t: ^testing.T) {
	root, e := os.mkdir_temp("", "kadai-where-", context.temp_allocator)
	if !testing.expect(t, e == nil) do return
	defer os.remove_all(root)
	config := "statuses: {review: in_progress}\npriorities: [routine, urgent]\n"
	if !testing.expect(t, os.write_entire_file(fmt.tprintf("%s/.kadai.yaml", root), config) == nil) do return
	for row in ([]struct {
			id, status, fields: string,
		}{{"A", "todo", "priority: urgent\ntags: [release, wip]\n"}, {"B", "review", "tags: [release]\ndue: '2026-11-15'\n"}, {"C", "review", "tags: [release, wip]\n"}, {"D", "todo", "priority: urgent\n"}}) {
		source := fmt.tprintf(
			"---\nkadai: task\nid: %s\ntitle: Example\nstatus: %s\n%s---\n",
			row.id,
			row.status,
			row.fields,
		)
		if !testing.expect(t, os.write_entire_file(fmt.tprintf("%s/%s.md", root, row.id), source) == nil) do return
	}
	expr := "priority=urgent OR status=review AND tag!=wip"
	args := []string {
		"list",
		"--project",
		root,
		"--tasks-root",
		".",
		"--tag",
		"release",
		"--where",
		expr,
		"--json",
	}
	text := invoke_cli(t, args[:len(args) - 1]).stdout
	testing.expect_value(t, text, "A  [todo]  Example  (A.md)\nB  [review]  Example  (B.md)\n")
	rows := parse_result(t, invoke_cli(t, args).stdout).(json.Array)
	if !testing.expect_value(t, len(rows), 2) do return
	testing.expect_value(t, rows[0].(json.Object)["id"].(string), "A")
	testing.expect_value(t, rows[1].(json.Object)["id"].(string), "B")

	args[8] = "id=b AND due=2026-11-15 AND priority!=urgent"
	rows = parse_result(t, invoke_cli(t, args).stdout).(json.Array)
	if !testing.expect_value(t, len(rows), 1) do return
	testing.expect_value(t, rows[0].(json.Object)["id"].(string), "B")
	// C has no due date and B has the requested date. Both predicates matter.
	args[8] = "id=c AND due=2026-11-15"
	rows = parse_result(t, invoke_cli(t, args).stdout).(json.Array)
	testing.expect_value(t, len(rows), 0)
	// Even an alternative with no candidate rows must reject an unknown configured value.
	args[8] = "id=absent AND priority=high"
	bad := invoke_cli(t, args, 1)
	testing.expect(t, bad.stdout == "" && strings.contains(bad.stderr, "high"), bad.stderr)
}

@(test)
list_sort_uses_field_order_then_ascending_path :: proc(t: ^testing.T) {
	root, err := os.mkdir_temp("", "kadai-sort-", context.temp_allocator)
	if !testing.expect(t, err == nil) do return
	defer os.remove_all(root)
	if !testing.expect(t, os.write_entire_file(fmt.tprintf("%s/.kadai.yaml", root), "priorities: [later, now, asap]\n") == nil) do return
	for row in ([]struct {
			path, id, title, status, priority: string,
		}{{"a.md", "z", "Zebra", "in_progress", "now"}, {"b.md", "C", "Alpha", "done", "asap"}, {"c.md", "B", "Zebra", "todo", "now"}, {"d.md", "a", "Alpha", "done", "null"}}) {
		source := fmt.tprintf(
			"---\nkadai: task\nid: %s\ntitle: %s\nstatus: %s\npriority: %s\n---\n",
			row.id,
			row.title,
			row.status,
			row.priority,
		)
		if !testing.expect(t, os.write_entire_file(fmt.tprintf("%s/%s", root, row.path), source) == nil) do return
	}
	for c in ([]struct {
			key, order: string,
			ids       : []string,
		}{{"priority", "desc", {"C", "z", "B", "a"}}, {"priority", "asc", {"z", "B", "C", "a"}}, {"title", "asc", {"C", "a", "z", "B"}}, {"status", "desc", {"B", "z", "C", "a"}}, {"id", "asc", {"B", "C", "a", "z"}}, {"path", "desc", {"a", "B", "C", "z"}}}) {
		args := []string {
			"list",
			"--project",
			root,
			"--tasks-root",
			".",
			"--sort",
			c.key,
			"--order",
			c.order,
			"--json",
		}
		rows := parse_result(t, invoke_cli(t, args).stdout).(json.Array)
		ids := make([]string, len(rows), context.temp_allocator)
		for row, i in rows do ids[i] = row.(json.Object)["id"].(string)
		testing.expect(t, slice.equal(ids, c.ids), fmt.tprintf("%s %s: %v", c.key, c.order, ids))
	}
	text :=
		invoke_cli(t, {"list", "--project", root, "--tasks-root", ".", "--where", "status!=done", "--sort", "ignored", "--sort", "id", "--order", "ignored", "--order", "asc"}).stdout
	testing.expect_value(t, text, "B  [todo]  Zebra  (c.md)\nz  [in_progress]  Zebra  (a.md)\n")
}

@(test)
json_task_preserves_numeric_lexemes_and_user_keys :: proc(t: ^testing.T) {
	root, e := os.mkdir_temp("", "kadai-json-", context.temp_allocator)
	if !testing.expect(t, e == nil) do return
	defer os.remove_all(root)
	source ::
		"---\nkadai: task\nid: Mixed\ntitle: 'Café'\nstatus: todo\ncustom:\n" +
		"  values: [12345678901234567890001, .NaN, -.Inf, 0xAF, '.NaN']\n" +
		"  '$float': {'a\u00a0b': true}\n---\nBody\r\n"
	if !testing.expect(t, os.write_entire_file(fmt.tprintf("%s/other.md", root), source) == nil) do return
	output := invoke_cli(t, {"show", "mixed", "--json", "--project", root, "--tasks-root", "."})
	task := parse_result(t, output.stdout).(json.Object)
	testing.expect_value(t, task["id"].(string), "Mixed")
	testing.expect_value(t, task["path"].(string), "other.md")
	testing.expect_value(t, task["status"].(string), "todo")
	testing.expect_value(t, task["source"].(string), source)
	custom := task["custom"].(json.Object)
	values := custom["values"].(json.Array)
	for v, i in ([]struct {
			key, lexeme: string,
		}{{"$integer", "12345678901234567890001"}, {"$float", ".NaN"}, {"$float", "-.Inf"}, {"$integer", "0xAF"}}) {
		testing.expect_value(t, values[i].(json.Object)[v.key].(string), v.lexeme)
	}
	testing.expect_value(t, values[4].(string), ".NaN")
	testing.expect(t, custom["$$float"].(json.Object)["a\u00a0b"].(bool))
	empty := invoke_cli(
		t,
		{"list", "--json", "--status", "done", "--project", root, "--tasks-root", "."},
	)
	testing.expect_value(t, len(parse_result(t, empty.stdout).(json.Array)), 0)
}

// A predictable encoding refusal must precede ID reservation. A delivery
// failure after commit must identify the created ID and keep its file.
@(test)
json_creation_distinguishes_rejection_from_delivery_failure :: proc(t: ^testing.T) {
	root, e := os.mkdir_temp("", "kadai-json-write-", context.temp_allocator)
	if !testing.expect(t, e == nil) do return
	defer os.remove_all(root)
	refused := invoke_cli(
		t,
		{"add", "First", "--path", "bad\xff.md", "--json", "--project", root},
		7,
	)
	testing.expect_value(t, refused.stdout, "")
	testing.expect(t, strings.contains(refused.stderr, "unsupported_output"))
	testing.expect(t, !os.exists(fmt.tprintf("%s/tasks", root)))

	err: strings.Builder
	defer strings.builder_destroy(&err)
	code := run({"add", "First", "--json", "--project", root}, {}, strings.to_writer(&err))
	testing.expect_value(t, code, 6)
	testing.expect(t, strings.contains(strings.to_string(err), "created task 0001"))
	testing.expect(t, os.exists(fmt.tprintf("%s/tasks/0001.md", root)))
}
