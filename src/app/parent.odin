package app

import "core:fmt"
import "core:strings"
import "kadai:document"
import "kadai:project"
import "kadai:storage"
import "kadai:yaml"

@(private)
Parent_Edit :: struct { child: string, parent: Maybe(string) }

@(private)
plan_parent :: proc(view: ^Collection, data: rawptr) -> ([]storage.Change, string) {
	context.allocator = context.temp_allocator
	edit := (^Parent_Edit)(data)
	child, issue := unique_task(view, edit.child, diagnostic = true)
	if issue != "" do return nil, issue
	if child.status != .Decoded && child.status != .Invalid_Fields do return nil, "unsupported task schema"
	source, read_err := read_versioned(view, child, mutation = true)
	if read_err != "" do return nil, read_err
	value: Maybe(string)
	if id, set := edit.parent.?; set {
		if strings.equal_fold(child.fields.id, id) do return nil, fmt.tprintf("%s: parent_self_link", child.path)
		target, target_err := unique_task(view, id)
		if target_err != "" do return nil, target_err
		if issue = check_new_link(view, child, target, .Parent); issue != "" do return nil, issue
		if strings.equal_fold(child.fields.parent, id) do return nil, ""
		value = target.fields.id
	}
	vocab, l := view.config.vocabulary, view.limits
	doc := document.decode_task(source, vocab, l.source_bytes, l.yaml, child.path)
	node := yaml.lookup(&doc.root, "parent")
	if doc.status == .Allocation_Error do return nil, "cannot decode parent"
	edited: string
	e: document.Header_Edit_Error
	if id, set := value.?; set && node == nil {
		edited, e = document.plan_key_patch(source, .Parent, document.Insert_Field{value = id}, vocab, l.source_bytes, l.yaml, child.path)
	} else if !set && (node == nil || node.kind == .Null) {
		return nil, ""
	} else if !set && (node.kind == .Mapping || node.kind == .Sequence) {
		edited, e = document.plan_key_patch(source, .Parent, document.Unset_Field{}, vocab, l.source_bytes, l.yaml, child.path)
	} else {
		edited, e = document.plan_scalar_patch(source, .Parent, value, vocab, l.source_bytes, l.yaml, child.path)
	}
	if problem := patch_issue(e); problem != "" do return nil, problem
	change := make([]storage.Change, 1)
	change[0] = {kind = .Replace, path = child.path, expected = child.version, data = transmute([]byte)edited}
	return change, ""
}

set_parent :: proc(cwd: string, options: Project_Options, child: string, parent: Maybe(string), limits := project.DEFAULT_SCAN_LIMITS) -> (operation, issue: string) {
	edit := Parent_Edit{child, parent}
	return mutate_collection(cwd, options, plan_parent, &edit, limits)
}
