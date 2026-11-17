#+test
package project

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "kadai:document"

@(test)
discovery_boundaries_and_classification :: proc(t: ^testing.T) {
	cases := []struct{fixture: string, count: int, status: document.Decode_Status}{
		{"config/glob-excludes", 1, .Decoded},
		{"config/nested-project-boundary", 1, .Decoded},
		{"config/boards-excluded", 1, .Decoded},
		{"recognition/partial-id-invalid-status", 1, .Invalid_Fields},
		{"recognition/future-schema", 1, .Unsupported_Schema},
		{"recognition/missing-close", 1, .Boundary_Error},
		{"recognition/commented-marker", 0, .Non_Task},
		{"recognition/duplicate-marker", 1, .YAML_Error},
	}
	for c in cases {
		dir := fmt.tprintf("%s/../../tests/fixtures/v1/cases/%s/input/project", #directory, c.fixture)
		cfg, issue := resolve(dir)
		if !testing.expect_value(t, issue, "") do continue
		inv := scan(cfg)
		testing.expect(t, inv.complete, inv.problem)
		if testing.expect_value(t, len(inv.candidates), c.count) && c.count != 0 {
			testing.expect_value(t, inv.candidates[0].status, c.status)
		}
	}
	matched, ok := matches("**/?.md", "a/é.md", false)
	testing.expect(t, ok && matched)
	matched, ok = matches("?.md", "aa.md", false)
	testing.expect(t, ok && !matched)
}

@(test)
scan_ignores_file_and_directory_symlinks :: proc(t: ^testing.T) {
	root, err := os.mkdir_temp("", "kadai-scan-links-", context.temp_allocator)
	if !testing.expect(t, err == nil) do return
	defer os.remove_all(root)
	cfg, issue := resolve(root, {tasks_root = "."})
	if !testing.expect_value(t, issue, "") do return

	dir, _ := os.join_path({root, "work"}, context.temp_allocator)
	file, _ := os.join_path({dir, "real.md"}, context.temp_allocator)
	if !testing.expect(t, os.mkdir(dir) == nil) do return
	source :: "---\nkadai: task\nid: OK\ntitle: Visible\nstatus: todo\n---\n"
	if !testing.expect(t, os.write_entire_file(file, source) == nil) do return

	for link in ([]struct{name, target: string, directory: bool}{
		{"alias.md", file, false}, {"alias-dir", dir, true},
	}) {
		path, _ := os.join_path({root, link.name}, context.temp_allocator)
		when ODIN_OS == .Windows {
			if !create_windows_test_symlink(t, path, link.target, link.directory) do return
		} else {
			link_err := os.symlink(link.target, path)
			if !testing.expect(t, link_err == nil, os.error_string(link_err)) do return
		}
	}

	inv := scan(cfg)
	if !testing.expect(t, inv.complete, inv.problem) do return
	if !testing.expect_value(t, len(inv.candidates), 1) do return
	testing.expect_value(t, inv.candidates[0].path, "work/real.md")
}

@(test)
scan_budget_includes_rejected_nodes_and_ordinary_markdown :: proc(t: ^testing.T) {
	dir, err := os.mkdir_temp("", "kadai-scan-", context.temp_allocator)
	if !testing.expect(t, err == nil) do return
	defer os.remove_all(dir)
	cfg, issue := resolve(dir, {tasks_root = "."})
	if !testing.expect_value(t, issue, "") do return
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/a.md", dir), "ordinary body, ignored") == nil)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/b.md", dir), "---\nkadai: task\nbad: [\n---\n") == nil)
	limits := DEFAULT_SCAN_LIMITS
	limits.entries, limits.candidates = 2, 2
	inv := scan(cfg, limits)
	testing.expect(t, inv.complete && inv.nodes >= 3, inv.problem)
	limits.total_nodes = inv.nodes - 1
	testing.expect(t, !scan(cfg, limits).complete)
	limits.total_nodes = inv.nodes
	limits.candidates = 1
	testing.expect(t, !scan(cfg, limits).complete)
}

// A single failed match examines ten steps; the next lower budget cannot
// establish whether the ordinary Markdown file is excluded.
@(test)
exclude_work_budget_stops_incomplete_scans :: proc(t: ^testing.T) {
	dir, err := os.mkdir_temp("", "kadai-exclude-budget-", context.temp_allocator)
	if !testing.expect(t, err == nil) do return
	defer os.remove_all(dir)
	testing.expect(t, os.mkdir(fmt.tprintf("%s/tasks", dir)) == nil)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/.kadai.yaml", dir), "tasks:\n  exclude: [x]\n") == nil)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/tasks/a.md", dir), "ordinary Markdown") == nil)
	cfg, issue := resolve(dir)
	if !testing.expect_value(t, issue, "") do return
	limits := DEFAULT_SCAN_LIMITS
	limits.exclude_match_steps = 10
	inv := scan(cfg, limits)
	testing.expect(t, inv.complete, inv.problem)
	limits.exclude_match_steps = 9
	inv = scan(cfg, limits)
	testing.expect(t, !inv.complete && strings.contains(inv.problem, "observed 10, limit 9"), inv.problem)
}
