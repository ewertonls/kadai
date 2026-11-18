#+test
package app

import "core:os"
import "core:strings"
import "core:testing"
import "kadai:project"
import "kadai:storage"

@(test)
import_reads_only_ordinary_markdown_within_limits :: proc(t: ^testing.T) {
	root, err := os.mkdir_temp("", "kadai-import-source-", context.temp_allocator)
	if !testing.expect(t, err == nil) do return
	defer os.remove_all(root)
	path := storage.child(root, "draft.md")
	for c in ([]struct {source, issue: string}{
		{"---\nkadai: task\nid: A\ntitle: A\nstatus: todo\n---\n", "Kadai task marker"},
		{"---\nkadai: task\n---\n", "Kadai task marker"},
		{"---\nkadai: task\nschema_version: 2\n---\n", "Kadai task marker"},
		{"---\n'kadai': \"task\"\ntags: [x, }\n---\n", "Kadai task marker"},
		{"---\n'kadai': \"task\"\n", "Kadai task marker"},
		{"---\nkadai: note\n'kadai': \"task\"\n---\n", "Kadai task marker"},
		{"---\nkadai: note\nkadai: other\nkadai: task\n---\n", "Kadai task marker"},
		{"---\nkadai: note\nkadai: other\n---\n", ""},
		{"---\ntitle: &n Draft\nkadai: task\n---\n", "Kadai task marker"},
		{"---\nkadai: &n !!str task\n---\n", "Kadai task marker"},
		{"---\n! kadai: ! task\n---\n", "Kadai task marker"},
		{"---\nkadai: !foreign task\n---\n", ""},
		{"---\n\uFEFFkadai: task\nid: A\ntitle: Draft\nstatus: todo\n---\n", "Kadai task marker"},
		{"---\ntitle: First\ntitle: Second\nkadai: task\n---\n", "Kadai task marker"},
		{"---\nforeign: &n Draft\nnested: [{kadai: task}]\n---\n", ""},
		{"invalid byte \xff", "UTF-8"},
		{"---\nA thematic break above an ordinary paragraph.\n", ""},
	}) {
		if !testing.expect(t, os.write_entire_file(path, c.source) == nil) do return
		title, body, issue := read_import(root, "draft.md", "")
		if c.issue == "" {
			testing.expect_value(t, issue, "")
			testing.expect_value(t, title, "draft")
			testing.expect_value(t, body, c.source)
		} else {
			testing.expect(t, body == "" && strings.contains(issue, c.issue), issue)
		}
	}

	source :: "---\nforeign: metadata\n---\n"
	if !testing.expect(t, os.write_entire_file(path, source) == nil) do return
	limits := project.DEFAULT_SCAN_LIMITS
	limits.source_bytes = len(source)-1
	_, _, issue := read_import(root, "draft.md", "", limits)
	testing.expect(t, strings.contains(issue, "task_source_bytes"), issue)
	limits = project.DEFAULT_SCAN_LIMITS
	limits.yaml.bytes = len("foreign: metadata\n")-1
	_, _, issue = read_import(root, "draft.md", "", limits)
	testing.expect(t, strings.contains(issue, "18 yaml_document_bytes with a limit of 17"), issue)
	if !testing.expect(t, os.write_entire_file(path, "---\nforeign: &n Draft\nkadai: task\n---\n") == nil) do return
	limits = project.DEFAULT_SCAN_LIMITS
	limits.yaml.nodes = 4
	_, _, issue = read_import(root, "draft.md", "", limits)
	testing.expect(t, strings.contains(issue, "5 yaml_nodes_document with a limit of 4"), issue)
	_, _, issue = read_import(root, "draft.txt", "")
	testing.expect(t, strings.contains(issue, ".md source file"), issue)
	if !testing.expect(t, os.mkdir(storage.child(root, "folder.md")) == nil) do return
	_, _, issue = read_import(root, "folder.md", "")
	testing.expect(t, issue != "")
}

@(test)
import_resolves_the_invocation_directory_before_relative_paths :: proc(t: ^testing.T) {
	root, err := os.mkdir_temp("", "kadai-import-cwd-", context.temp_allocator)
	if !testing.expect(t, err == nil) do return
	defer os.remove_all(root)
	parent := storage.child(root, "real")
	child := storage.child(parent, "child")
	alias := storage.child(root, "alias")
	if !testing.expect(t, os.mkdir_all(child) == nil) do return
	for dir in ([2]string{parent, child}) {
		if !testing.expect(t, os.write_entire_file(storage.child(dir, "notes.md"), dir) == nil) do return
	}
	when ODIN_OS == .Windows {
		if !project.create_windows_test_symlink(t, alias, child, true) do return
	} else {
		if !testing.expect(t, os.symlink(child, alias) == nil) do return
	}
	for c in ([]struct {path, expected: string}{{"notes.md", child}, {"../notes.md", parent}}) {
		_, body, issue := read_import(alias, c.path, "")
		testing.expect_value(t, issue, "")
		testing.expect_value(t, body, c.expected)
	}
}
