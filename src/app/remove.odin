package app

import "core:fmt"
import "core:strings"
import "kadai:document"
import "kadai:project"
import "kadai:storage"
import "kadai:yaml"

Removal :: struct { id: string, detach: bool, expected_plan: string }
Removal_Edit :: struct {
	id, path, field: string,
	span: document.Byte_Range, // Half-open byte range in the original Markdown.
}
Removal_Preview :: struct {
	edits: [dynamic]Removal_Edit,
	token: string,
}

@(private)
Remove_Request :: struct { using options: Removal, preview: Removal_Preview }

@(private)
references_known :: proc(c: ^project.Candidate) -> bool {
	if c.status == .Decoded do return true
	if c.status != .Invalid_Fields || c.fields.schema_version.digits != "1" do return false
	for d in c.diagnostics {
		if d.field == "depends_on" || d.field == "parent" do return false
	}
	return true
}

@(private)
plan_removal :: proc(view: ^Collection, data: rawptr) -> ([]storage.Change, string) {
	context.allocator = context.temp_allocator
	request := (^Remove_Request)(data)
	target, issue := unique_task(view, request.id)
	if issue != "" do return nil, issue
	id := target.fields.id
	problems := strings.builder_make()
	blocked := false
	remaining := view.limits.total_bytes
	changes: [dynamic]storage.Change
	vocab, l := view.config.vocabulary, view.limits
	for &c in view.index.candidates {
		parent := strings.equal_fold(c.fields.parent, id)
		dep := -1
		for ref, i in c.fields.depends_on {
			if strings.equal_fold(ref, id) { dep = i; break }
		}
		if !references_known(&c) {
			blocked = true
			fmt.sbprintf(&problems, "%s: cannot establish inbound references (%v)\n", c.path, c.status)
		}
		if !parent && dep < 0 do continue
		if !request.detach {
			blocked = true
			if parent do fmt.sbprintf(&problems, "%s (%s): parent references %s\n", c.path, c.fields.id, id)
			if dep >= 0 do fmt.sbprintf(&problems, "%s (%s): depends_on references %s\n", c.path, c.fields.id, id)
			continue
		}
		if _, lookup_err := unique_task(view, c.fields.id); lookup_err != "" do return nil, lookup_err
		if c.info.size > remaining do return nil, "detach plan exceeds recovery byte limit"
		remaining -= c.info.size
		source, read_err := read_versioned(view, &c, mutation = true)
		if read_err != "" do return nil, read_err
		doc := document.decode_task(source, vocab, l.source_bytes, l.yaml, c.path)
		if doc.status != .Decoded do return nil, fmt.tprintf("%s: cannot verify reference spans", c.path)
		edited := source
		e: document.Header_Edit_Error
		if parent {
			span := yaml.lookup(&doc.root, "parent").span
			if _, err := append(&request.preview.edits, Removal_Edit{c.fields.id, c.path, "parent", {doc.parts.header.start+span.start, doc.parts.header.start+span.end}}); err != nil do return nil, "cannot allocate removal preview"
			if &c != target {
				// Clearing the token preserves inline comments and makes the child a root.
				edited, e = document.plan_scalar_patch(edited, .Parent, nil, vocab, l.source_bytes, l.yaml, c.path)
				if err := patch_issue(e); err != "" do return nil, err
			}
		}
		if dep >= 0 {
			span := yaml.lookup(&doc.root, "depends_on").items[dep].span
			if _, err := append(&request.preview.edits, Removal_Edit{c.fields.id, c.path, "depends_on", {doc.parts.header.start+span.start, doc.parts.header.start+span.end}}); err != nil do return nil, "cannot allocate removal preview"
			if &c != target {
				edited, e = document.plan_sequence_patch(edited, .Depends_On, .Remove, id, vocab, l.source_bytes, l.yaml, c.path)
				if err := patch_issue(e); err != "" do return nil, err
			}
		}
		if &c != target {
			if _, err := append(&changes, storage.Change{kind = .Replace, path = c.path, expected = c.version, data = transmute([]byte)edited}); err != nil {
				return nil, "cannot allocate detach plan"
			}
		}
	}
	if blocked {
		if strings.builder_len(problems) == 0 do return nil, "cannot establish safe deletion"
		return nil, strings.trim_suffix(strings.to_string(problems), "\n")
	}
	source, read_err := read_versioned(view, target, mutation = true)
	if read_err != "" do return nil, read_err
	if _, err := append(&request.preview.edits, Removal_Edit{id, target.path, "delete", {0, len(source)}}); err != nil do return nil, "cannot allocate removal preview"
	if _, err := append(&changes, storage.Change{kind = .Delete, path = target.path, expected = target.version}); err != nil {
		return nil, "cannot allocate delete plan"
	}
	// Include physical source versions and the resulting patches. Recomputing
	// this under the writer lock detects newly added, removed and edited references.
	key := strings.builder_make()
	fmt.sbprintf(&key, "%q %q %t\n", view.config.tasks, id, request.detach)
	for change in changes {
		fmt.sbprintf(&key, "%d:%s %s %s\n", len(change.path), change.path, change.expected, storage.digest(change.data))
	}
	request.preview.token = storage.digest(transmute([]byte)strings.to_string(key))
	if request.expected_plan != "" && request.expected_plan != request.preview.token do return nil, "stale removal plan"
	return changes[:], ""
}

preview_removal :: proc(cwd: string, options: Project_Options, remove: Removal, limits := project.DEFAULT_SCAN_LIMITS) -> (Removal_Preview, string) {
	view, issue := read_collection(cwd, options, limits)
	if issue != "" do return {}, issue
	req := Remove_Request{options = remove}
	_, issue = plan_removal(&view, &req)
	if issue != "" do return {}, issue
	return req.preview, ""
}

remove_task :: proc(cwd: string, options: Project_Options, remove: Removal, limits := project.DEFAULT_SCAN_LIMITS) -> (operation, issue: string) {
	req := Remove_Request{options = remove}
	return mutate_collection(cwd, options, plan_removal, &req, limits)
}
