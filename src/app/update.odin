package app

import "base:runtime"
import "core:fmt"
import "kadai:document"
import "kadai:project"
import "kadai:storage"
import "kadai:yaml"

Update :: struct {
	id, field   : string,
	values      : []string,
	unset, force: bool,
}

@(private)
patch_issue :: proc(e: document.Header_Edit_Error) -> string {
	switch problem in e {
	case yaml.Diagnostic:
		return fmt.tprintf(
			"%s: %s (%s): %s",
			problem.path,
			problem.code,
			problem.field,
			problem.message,
		)
	case runtime.Allocator_Error:
		return fmt.tprintf("patch allocation failed: %v", problem)
	}
	return ""
}

@(private)
plan_update :: proc(view: ^Collection, data: rawptr) -> ([]storage.Change, string) {
	context.allocator = context.temp_allocator
	op := (^Update)(data)
	item, issue := unique_task(view, op.id, diagnostic = true)
	if issue != "" do return nil, issue
	if item.status != .Decoded && item.status != .Invalid_Fields do return nil, "unsupported task schema"
	source, read_issue := read_versioned(view, item, mutation = true)
	if read_issue != "" do return nil, read_issue
	vocab, l := view.config.vocabulary, view.limits
	doc := document.decode_task(source, vocab, l.source_bytes, l.yaml, item.path)
	if doc.status == .Allocation_Error do return nil, "cannot decode task"
	scalar: document.Scalar_Field
	field: document.Metadata_Field
	switch op.field {
	case "title":
		field, scalar = .Title, .Title
	case "status":
		field, scalar = .Status, .Status
	case "priority":
		field, scalar = .Priority, .Priority
	case "due":
		field, scalar = .Due, .Due
	case "tags":
		field = .Tags
	case:
		return nil, fmt.tprintf("not an editable core field: %s", op.field)
	}
	edited: string
	e: document.Header_Edit_Error
	if op.unset {
		if len(op.values) != 0 do return nil, "unset does not take a value"
		edited, e = document.plan_key_patch(
			source,
			field,
			document.Unset_Field{},
			vocab,
			l.source_bytes,
			l.yaml,
			item.path,
		)
	} else if field == .Tags {
		edited, e = document.plan_tags(&doc, op.values, vocab, l.yaml)
	} else {
		if len(op.values) != 1 do return nil, "set requires one scalar value"
		if yaml.lookup(&doc.root, op.field) == nil {
			edited, e = document.plan_key_patch(
				source,
				field,
				document.Insert_Field{value = op.values[0]},
				vocab,
				l.source_bytes,
				l.yaml,
				item.path,
			)
		} else {
			edited, e = document.plan_scalar_patch(
				source,
				scalar,
				op.values[0],
				vocab,
				l.source_bytes,
				l.yaml,
				item.path,
			)
		}
	}
	if problem := patch_issue(e); problem != "" do return nil, problem
	if op.force && (field != .Status || op.unset) do return nil, "force applies only to a status transition"
	if field == .Status &&
	   !op.unset &&
	   !op.force &&
	   category(&view.config, item.fields.status) != "done" &&
	   category(&view.config, op.values[0]) == "done" {
		if ready := task_readiness(view, item); ready != .Ready {
			return nil, fmt.tprintf(
				"%s: prerequisites are %v; completing this task requires --force",
				item.path,
				ready,
			)
		}
	}
	if edited == source do return nil, ""
	change := make([]storage.Change, 1)
	change[0] = {
		kind     = .Replace,
		path     = item.path,
		expected = item.version,
		data     = transmute([]byte)edited,
	}
	return change, ""
}

update_task :: proc(
	cwd: string,
	options: Project_Options,
	update: Update,
	limits := project.DEFAULT_SCAN_LIMITS,
) -> (
	operation, issue: string,
) {
	op := update
	return mutate_collection(cwd, options, plan_update, &op, limits)
}
