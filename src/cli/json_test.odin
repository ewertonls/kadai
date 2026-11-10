#+test
package cli

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(private)
parse_result :: proc(t: ^testing.T, output: string) -> json.Value {
	value, err := json.parse(output, .JSON, parse_integers = true, allocator = context.temp_allocator)
	if err != .None do testing.fail_now(t, output)
	envelope := value.(json.Object)
	testing.expect_value(t, envelope["version"].(i64), 1)
	return envelope["result"]
}

@(test)
json_task_preserves_numeric_lexemes_and_user_keys :: proc(t: ^testing.T) {
	root, e := os.mkdir_temp("", "kadai-json-", context.temp_allocator)
	if !testing.expect(t, e == nil) do return
	defer os.remove_all(root)
	source :: "---\nkadai: task\nid: Mixed\ntitle: 'Café'\nstatus: todo\ncustom:\n" +
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
	for v, i in ([]struct{key, lexeme: string}{{"$integer", "12345678901234567890001"}, {"$float", ".NaN"}, {"$float", "-.Inf"}, {"$integer", "0xAF"}}) {
		testing.expect_value(t, values[i].(json.Object)[v.key].(string), v.lexeme)
	}
	testing.expect_value(t, values[4].(string), ".NaN")
	testing.expect(t, custom["$$float"].(json.Object)["a\u00a0b"].(bool))
	empty := invoke_cli(t, {"list", "--json", "--status", "done", "--project", root, "--tasks-root", "."})
	testing.expect_value(t, len(parse_result(t, empty.stdout).(json.Array)), 0)
}

// A predictable encoding refusal must precede ID reservation. A delivery
// failure after commit must identify the created ID and keep its file.
@(test)
json_creation_distinguishes_rejection_from_delivery_failure :: proc(t: ^testing.T) {
	root, e := os.mkdir_temp("", "kadai-json-write-", context.temp_allocator)
	if !testing.expect(t, e == nil) do return
	defer os.remove_all(root)
	refused := invoke_cli(t, {"add", "First", "--path", "bad\xff.md", "--json", "--project", root}, 1)
	testing.expect_value(t, refused.stdout, "")
	testing.expect(t, strings.contains(refused.stderr, "unsupported_output"))
	testing.expect(t, !os.exists(fmt.tprintf("%s/tasks", root)))

	err: strings.Builder
	defer strings.builder_destroy(&err)
	code := run({"add", "First", "--json", "--project", root}, {}, strings.to_writer(&err))
	testing.expect_value(t, code, 1)
	testing.expect(t, strings.contains(strings.to_string(err), "created task 0001"))
	testing.expect(t, os.exists(fmt.tprintf("%s/tasks/0001.md", root)))
}
