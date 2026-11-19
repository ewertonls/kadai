#+test
package graph

import "core:slice"
import "core:testing"

@(test)
cycle_members_exclude_acyclic_branches :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	g, err := network(6)
	if !testing.expect(t, err == nil) do return
	for pair in ([][2]int{{0, 1}, {1, 2}, {2, 1}, {2, 3}, {3, 2}, {3, 4}, {5, 5}}) {
		testing.expect(t, link(&g, pair[0], pair[1]) == nil)
	}
	c, e := cycles(g)
	if !testing.expect(t, e == nil) do return
	testing.expect(t, slice.equal(c.leader, []int{-1, 1, 1, 1, -1, 5}))
	testing.expect(t, slice.equal(c.members[1][:], []int{1, 2, 3}))
}
