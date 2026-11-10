#+test
package project

import "core:testing"

@(test)
quarantine_complete_collision_group :: proc(t: ^testing.T) {
	inv := Inventory{complete = true}
	inv.candidates = make([dynamic]Candidate, context.temp_allocator)
	append(&inv.candidates,
		Candidate{path = "a.md", status = .Decoded, fields = {id = "A"}},
		Candidate{path = "b.md", status = .Invalid_Fields, fields = {id = "a"}},
		Candidate{path = "c.md", status = .Unsupported_Schema, fields = {id = "A"}},
		Candidate{path = "d.md", status = .Invalid_Fields, fields = {id = "D"}},
		Candidate{path = "e.md", status = .Decoded, fields = {id = "E"}})
	idx := build_index(inv)
	testing.expect_value(t, len(idx.collisions), 1)
	testing.expect_value(t, len(idx.valid), 1)
	group, status := lookup(&idx, "a")
	testing.expect_value(t, status, Lookup_Status.Ambiguous)
	testing.expect_value(t, len(group), 3)
	_, status = lookup(&idx, "d")
	testing.expect_value(t, status, Lookup_Status.Diagnostic_Only)
	inv.complete = false
	idx = build_index(inv)
	_, status = lookup(&idx, "E")
	testing.expect_value(t, status, Lookup_Status.Incomplete)
	testing.expect_value(t, len(idx.valid), 0)
}
