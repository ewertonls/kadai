#+test
package project

import "core:fmt"
import "core:os"
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
	testing.expect(t, matches("**/?.md", "a/é.md", false) && !matches("?.md", "aa.md", false))
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
