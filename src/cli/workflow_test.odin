#+test
package cli

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "kadai:document"

@(private)
expect_workflow_body :: proc(t: ^testing.T, task: json.Object, expected: string) {
	source := task["source"].(string)
	parts, status := document.extract_frontmatter(source)
	if !testing.expect_value(t, status, .Present) do return
	testing.expect_value(t, source[parts.body.start:parts.body.end], expected)
}

@(test)
task_command_workflow :: proc(t: ^testing.T) {
	for initialized in ([2]bool{false, true}) {
		root, err := os.mkdir_temp("", "kadai-workflow-", context.temp_allocator)
		if !testing.expect(t, err == nil) do return
		defer os.remove_all(root)
		project := fmt.tprintf("--project=%s", root)
		if initialized {
			_ = invoke_cli(t, {"init", project})
			testing.expect(t, os.exists(fmt.tprintf("%s/.kadai.yaml", root)))
		}

		file_body :: "# Plan\r\nKeep these notes."
		stdin_body :: "- [ ] Review\n"
		body_file := fmt.tprintf("%s/input.md", root)
		if !testing.expect(t, os.write_entire_file(body_file, file_body) == nil) do return
		reader: strings.Reader
		parent_id := strings.trim_space(invoke_cli(t, {"add", "Milestone", project}).stdout)
		work_id := strings.trim_space(invoke_cli(t, {"add", "Work", "--body-file", body_file, project}).stdout)
		input := strings.to_reader(&reader, stdin_body)
		prerequisite_id := strings.trim_space(invoke_cli(t, {"add", "Review", "--stdin", project}, stdin = input).stdout)

		created := []struct {id, body: string}{
			{parent_id, ""}, {work_id, file_body}, {prerequisite_id, stdin_body},
		}
		for task in created {
			shown := invoke_cli(t, {"show", task.id, "--json", project})
			expect_workflow_body(t, parse_result(t, shown.stdout).(json.Object), task.body)
		}

		original_path := fmt.tprintf("%s/tasks/%s.md", root, work_id)
		source, read_err := os.read_entire_file(original_path, context.temp_allocator)
		if !testing.expect(t, read_err == nil) do return
		manual_note :: "\r\n- Added by hand"
		edited := fmt.tprintf("%s%s", string(source), manual_note)
		if !testing.expect(t, os.write_entire_file(original_path, edited) == nil) do return

		moved_path :: "work/implementation.md"
		_ = invoke_cli(t, {"status", work_id, "in_progress", project})
		_ = invoke_cli(t, {"move", work_id, moved_path, project})
		_ = invoke_cli(t, {"parent", "add", work_id, parent_id, project})
		_ = invoke_cli(t, {"dep", "add", work_id, prerequisite_id, project})
		shown := invoke_cli(t, {"show", work_id, "--json", project})
		moved := parse_result(t, shown.stdout).(json.Object)
		testing.expect_value(t, moved["id"].(string), work_id)
		testing.expect_value(t, moved["path"].(string), moved_path)
		testing.expect_value(t, moved["status"].(string), "in_progress")
		expect_workflow_body(t, moved, file_body + manual_note)

		tree := invoke_cli(t, {"tree", project, "--json"})
		found_child := false
		for row in parse_result(t, tree.stdout).(json.Array) {
			node := row.(json.Object)
			if node["id"].(string) != work_id do continue
			found_child = true
			testing.expect_value(t, node["position"].(string), "child")
			testing.expect_value(t, node["parent"].(string), parent_id)
		}
		testing.expect(t, found_child, "Moved task missing from tree")

		deps := invoke_cli(t, {"dep", "show", work_id, project, "--json"})
		refs := parse_result(t, deps.stdout).(json.Object)["prerequisites"].(json.Array)
		if !testing.expect_value(t, len(refs), 1) do return
		testing.expect_value(t, refs[0].(json.Object)["id"].(string), prerequisite_id)
		testing.expect_value(t, refs[0].(json.Object)["resolution"].(string), "resolved")

		list := invoke_cli(t, {"list", project, "--json"})
		rows := parse_result(t, list.stdout).(json.Array)
		// list orders by path: the two generated filenames precede work/.
		final_tasks := []struct {id, path: string}{
			{parent_id, fmt.tprintf("%s.md", parent_id)},
			{prerequisite_id, fmt.tprintf("%s.md", prerequisite_id)},
			{work_id, moved_path},
		}
		if !testing.expect_value(t, len(rows), len(final_tasks)) do return
		for expected, i in final_tasks {
			row := rows[i].(json.Object)
			testing.expect_value(t, row["id"].(string), expected.id)
			testing.expect_value(t, row["path"].(string), expected.path)
		}

		validation := invoke_cli(t, {"validate", project, "--json"})
		report := parse_result(t, validation.stdout).(json.Object)
		testing.expect_value(t, report["errors"].(i64), 0)
		for field in ([]string{"scan_complete", "history_complete", "recovery_complete"}) {
			testing.expect(t, report[field].(bool), field)
		}
		if !initialized {
			_, config_err := os.lstat(fmt.tprintf("%s/.kadai.yaml", root), context.temp_allocator)
			testing.expect(t, config_err == os.General_Error.Not_Exist, os.error_string(config_err))
		}
	}
}
