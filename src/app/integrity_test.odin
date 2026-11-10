#+test
package app

import "core:fmt"
import "core:testing"

@(private)
graph_fixture :: proc(name: string, opt := Project_Options{}) -> (Collection, string) {
	return read_collection(fmt.tprintf("%s/../../tests/fixtures/v1/cases/graph/%s/input/project", #directory, name), opt)
}

@(test)
diagnose_reference_resolution_without_picking_a_winner :: proc(t: ^testing.T) {
	cases := []struct {fixture, code, source, target: string, related: int}{
		{"missing-parent", "missing_parent", "C", "GHOST", 0},
		{"duplicate-target-unresolved", "ambiguous_parent", "C", "SAME", 2},
		{"duplicate-target-unresolved", "ambiguous_prerequisite", "C", "same", 2},
		{"invalid-status-prerequisite", "invalid_prerequisite", "A", "BAD", 1},
		{"unsupported-prerequisite", "unsupported_prerequisite", "A", "FUTURE", 1},
		{"dependency-self", "dependency_self_link", "A", "a", 1},
	}
	for c in cases {
		view, e := graph_fixture(c.fixture)
		if !testing.expect_value(t, e, "") do continue
		issues, problem := graph_findings(&view)
		if !testing.expect_value(t, problem, "") do continue
		found := false
		for f in issues {
			if f.code != c.code do continue
			found = f.id == c.source && f.target_id == c.target && f.location.line > 0 && len(f.related) == c.related
		}
		testing.expect(t, found, c.code)
	}
}
