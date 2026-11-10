#+test
package cli

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "kadai:app"

// Every budget has an inclusive ceiling; malformed numbers must not wrap,
// acquire units implicitly, or silently replace a previous override.
@(test)
resource_limit_grammar :: proc(t: ^testing.T) {
	defaults := limit_values(app.DEFAULT_SCAN_LIMITS)
	ceilings := limit_values(app.MAX_SCAN_LIMITS)
	for key in Limit {
		for n in ([2]i64{1, ceilings[key]}) {
			a, err := parse_options(Project_Flags, {"--limit", fmt.tprintf("%s=%d", LIMIT_NAMES[key], n)})
			if !testing.expect(t, err == nil) do continue
			want := defaults
			want[key] = n
			testing.expect_value(t, limit_values(a.limits), want)
		}
		for n in ([2]i64{0, ceilings[key]+1}) {
			_, err := parse_options(Project_Flags, {"--limit", fmt.tprintf("%s=%d", LIMIT_NAMES[key], n)})
			testing.expect(t, err != nil)
		}
	}
	for option in ([]string{
		"yaml_depth", "=1", "yaml_depth=", "yaml_depth=-1", "yaml_depth=+1",
		"yaml_depth=1.0", "yaml_depth=0x10", "yaml_depth=1_0", "yaml_depth= 1",
		"yaml_depth=1=2", "yaml_depth=9223372036854775808", "task_source_bytes=1MiB", "unknown=1",
	}) {
		_, err := parse_options(Project_Flags, {"--limit", option})
		testing.expect(t, err != nil, option)
	}
	_, duplicate := parse_options(Project_Flags, {"--limit=yaml_depth=2", "--limit=yaml_depth=3"})
	testing.expect(t, duplicate != nil)
	a, err := parse_options(Project_Flags, {"--limit=yaml_depth=4", "--limit", "scan_yaml_nodes=100"})
	testing.expect(t, err == nil && a.limits.yaml.depth == 4 && a.limits.total_nodes == 100)
}

// A missed forwarding argument would let one of these commands read or mutate
// the project with defaults. This includes both init config reads and recovery.
@(test)
commands_forward_config_limits :: proc(t: ^testing.T) {
	tmp, e := os.mkdir_temp("", "kadai-limit-config-", context.temp_allocator)
	if !testing.expect(t, e == nil) do return
	defer os.remove_all(tmp)
	config := "schema_version: 1\ntasks: {root: tasks}\n"
	path := fmt.tprintf("%s/.kadai.yaml", tmp)
	testing.expect(t, os.write_entire_file(path, config) == nil)
	// Config loading has separate entry points for init, queries, validation,
	// mutation planning and recovery. Test one command per path.
	commands := [][]string{{"init"}, {"list"}, {"validate"}, {"add", "Title"}, {"recover", "resume", "--yes"}}
	for command in commands {
		args := make([dynamic]string, context.temp_allocator)
		append(&args, ..command)
		append(&args, "--project", tmp, fmt.tprintf("--limit=yaml_document_bytes=%d", len(config)-1))
		out := invoke_cli(t, args[:], 1)
		testing.expect(t, strings.contains(out.stdout if command[0] == "validate" else out.stderr, ".kadai.yaml"), out.stderr)
		if command[0] == "validate" do testing.expect(t, strings.contains(out.stdout, "Task scan incomplete."), out.stdout)
	}
	testing.expect(t, !os.exists(fmt.tprintf("%s/tasks", tmp)))
	// Exactly N config bytes passes, N-1 above failed. init re-reads persisted
	// config with the same limits and never stores the invocation budgets.
	_ = invoke_cli(t, {"init", "--project", tmp, fmt.tprintf("--limit=yaml_document_bytes=%d", len(config))})
	after, read_err := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, read_err == nil && string(after) == config)
}

// Bound stdin/file body reads and the subsequent locked scan/patch. A refusal
// cannot rewrite a task, and the next invocation must get the default budgets.
@(test)
limits_bound_bodies_and_mutations :: proc(t: ^testing.T) {
	tmp, e := os.mkdir_temp("", "kadai-limit-task-", context.temp_allocator)
	if !testing.expect(t, e == nil) do return
	defer os.remove_all(tmp)
	body := "# body\r\nno final newline"
	body_file := fmt.tprintf("%s/body.md", tmp)
	testing.expect(t, os.write_entire_file(body_file, body) == nil)
	reader: strings.Reader
	limit := fmt.tprintf("--limit=task_source_bytes=%d", len(body)-1)
	out := invoke_cli(t, {"add", "Title", "--project", tmp, "--stdin", limit}, 1, strings.to_reader(&reader, body))
	testing.expect(t, strings.contains(out.stderr, "body exceeds task_source_bytes"), out.stderr)
	out = invoke_cli(t, {"add", "Title", "--project", tmp, "--body-file", body_file, limit}, 1)
	testing.expect(t, strings.contains(out.stderr, "body exceeds task_source_bytes"), out.stderr)
	testing.expect(t, !os.exists(fmt.tprintf("%s/tasks", tmp)))
	testing.expect_value(t, invoke_cli(t, {"add", "Title", "--project", tmp, "--body-file", body_file}).stdout, "0001\n")
	path := fmt.tprintf("%s/tasks/0001.md", tmp)
	source, read_err := os.read_entire_file(path, context.temp_allocator)
	if !testing.expect(t, read_err == nil) do return
	testing.expect(t, strings.has_suffix(string(source), body))
	limit = fmt.tprintf("--limit=task_source_bytes=%d", len(source))
	out = invoke_cli(t, {"show", "0001", "--project", tmp, limit})
	testing.expect(t, strings.contains(out.stdout, string(source)))
	limit = fmt.tprintf("--limit=task_source_bytes=%d", len(source)-1)
	out = invoke_cli(t, {"set", "0001", "title", "Changed", "--project", tmp, limit}, 1)
	testing.expect(t, strings.contains(out.stderr, "task_source_bytes limit exceeded"), out.stderr)
	after, after_err := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, after_err == nil && string(after) == string(source))
	_ = invoke_cli(t, {"set", "0001", "title", "Changed", "--project", tmp})
}
