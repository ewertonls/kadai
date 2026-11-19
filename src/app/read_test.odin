#+test
package app

import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "kadai:storage"

@(test)
queries_use_complete_current_files_only :: proc(t: ^testing.T) {
	tmp, err := os.mkdir_temp("", "kadai-read-", context.temp_allocator)
	if !testing.expect(t, err == nil) do return
	defer os.remove_all(tmp)
	opts := Project_Options {
		tasks_root = ".",
	}
	doc := "---\nkadai: task\nid: Mixed\ntitle: Example\nstatus: todo\n---\nbody"
	testing.expect(t, os.write_entire_file(storage.child(tmp, "z.md"), doc) == nil)
	a, _ := strings.replace_all(doc, "Mixed", "Two", context.temp_allocator)
	testing.expect(t, os.write_entire_file(storage.child(tmp, "a.md"), a) == nil)
	items, issue := list_tasks(tmp, opts)
	if !testing.expect(t, issue == "" && len(items) == 2) do return
	testing.expect_value(t, items[0].path, "a.md")
	result, problem := get_task(tmp, opts, "mixed")
	if !testing.expect_value(t, problem, "") do return
	testing.expect_value(t, result.source, doc)
	z, _ := strings.replace_all(doc, "todo", "unknown", context.temp_allocator)
	testing.expect(t, os.write_entire_file(storage.child(tmp, "z.md"), z) == nil)
	result, problem = get_task(tmp, opts, "mixed")
	testing.expect(t, problem == "" && result.source == "" && len(result.item.diagnostics) > 0)
	testing.expect(t, !os.exists(storage.child(tmp, ".kadai")))
}

@(test)
list_filters_preserve_collection_order_and_identity :: proc(t: ^testing.T) {
	tmp, err := os.mkdir_temp("", "kadai-list-", context.temp_allocator)
	if !testing.expect(t, err == nil) do return
	defer os.remove_all(tmp)
	opts := Project_Options {
		tasks_root = ".",
	}
	for dir in ([]string{"docs", "docs/a", "docs-old"}) {
		if !testing.expect(t, os.make_directory(storage.child(tmp, dir)) == nil) do return
	}
	// DFS visits docs/a/child.md first. Bytewise path order puts docs/a.md first.
	testing.expect(
		t,
		os.write_entire_file(
			storage.child(tmp, ".kadai.yaml"),
			"statuses: {review: in_progress}\n",
		) ==
		nil,
	)
	testing.expect(t, write_graph_task(tmp, "parent.md", "Root", "done"))
	testing.expect(
		t,
		write_graph_task(
			tmp,
			"docs/a/child.md",
			"A",
			"review",
			"tags: [cli, release]\nparent: Root\n",
		),
	)
	testing.expect(
		t,
		write_graph_task(
			tmp,
			"docs/other.md",
			"G",
			"in_progress",
			"tags: [release/candidate]\nparent: Z\n",
		),
	)
	testing.expect(
		t,
		write_graph_task(tmp, "docs/a.md", "Z", "review", "tags: [release]\nparent: ROOT\n"),
	)
	testing.expect(
		t,
		write_graph_task(tmp, "docs-old/x.md", "Y", "todo", "tags: [release]\nparent: Z\n"),
	)
	cases := []struct {
		filter: List_Filter,
		ids   : []string,
	} {
		{{directory = "./docs/"}, {"Z", "A", "G"}},
		{{status = "in_progress"}, {"G"}},
		{{tag = "release"}, {"Y", "Z", "A"}},
		{{parent = "z"}, {"Y", "G"}},
		{{directory = ".", status = "review", parent = "root", tag = "cli"}, {"A"}},
		{{directory = "docs", status = "todo"}, nil},
	}
	for c in cases {
		rows, issue := list_tasks(tmp, opts, filter = c.filter)
		if !testing.expect_value(t, issue, "") do continue
		ids := make([]string, len(rows), context.temp_allocator)
		for item, i in rows do ids[i] = item.fields.id
		testing.expect(t, slice.equal(ids, c.ids))
	}
	// A narrower directory cannot hide a colliding parent or mask an incomplete scan.
	testing.expect(t, write_graph_task(tmp, "docs-old/duplicate.md", "root", "todo"))
	_, issue := list_tasks(tmp, opts, filter = {directory = "docs", parent = "Root"})
	testing.expect(
		t,
		strings.contains(issue, "ambiguous task ID") &&
		strings.contains(issue, "docs-old/duplicate.md"),
		issue,
	)
	limits := DEFAULT_SCAN_LIMITS
	limits.candidates = 3
	rows, limited := list_tasks(tmp, opts, limits, {directory = "docs"})
	testing.expect(t, len(rows) == 0 && strings.contains(limited, "markdown_candidates"), limited)
}
