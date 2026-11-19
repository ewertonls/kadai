#+test
package app

import "core:fmt"
import "core:testing"
import "kadai:graph"

@(test)
ready_selection_uses_direct_edges_and_status_categories :: proc(t: ^testing.T) {
	for c in ([]struct {
			fixture, id: string,
			state      : graph.Readiness,
		}{{"cycle-does-not-propagate", "A", .Unresolved}, {"cycle-does-not-propagate", "C", .Ready}, {"missing-dep-unresolved-precedence", "A", .Unresolved}, {"unsupported-prerequisite", "A", .Unresolved}, {"invalid-status-prerequisite", "A", .Unresolved}, {"canceled-is-blocking", "B", .Blocked}}) {
		root := fmt.tprintf(
			"%s/../../tests/fixtures/v1/cases/graph/%s/input/project",
			#directory,
			c.fixture,
		)
		rows, issue := ready_tasks(root, {}, c.id)
		if !testing.expect(t, issue == "" && len(rows) == 1, c.fixture) do continue
		testing.expect_value(t, rows[0].readiness, c.state)
	}
	for c in ([]struct {
			fixture : string,
			selected: []string,
		}{{"custom-status-mapping", {"B"}}, {"default-ready-filter", {"P", "T"}}}) {
		root := fmt.tprintf(
			"%s/../../tests/fixtures/v1/cases/graph/%s/input/project",
			#directory,
			c.fixture,
		)
		rows, issue := ready_tasks(root, {})
		if !testing.expect(t, issue == "" && len(rows) == len(c.selected), c.fixture) do continue
		for row, i in rows do testing.expect_value(t, row.item.fields.id, c.selected[i])
	}
}
