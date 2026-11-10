#+private
#+feature dynamic-literals
package cli

import "core:encoding/json"
import "core:io"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"
import "kadai:app"

// Use strict JSON string escaping for user-supplied object keys as well as
// values. Reject non-UTF-8 filesystem paths before publishing any bytes.
write_json_value :: proc(w: io.Writer, value: json.Value) -> (err: io.Error) {
	switch v in value {
	case json.Object:
		keys, e := slice.map_keys(v, context.temp_allocator)
		if e != nil do return .Buffer_Full
		slice.sort(keys)
		io.write_byte(w, '{') or_return
		for key, i in keys {
			if i > 0 do io.write_byte(w, ',') or_return
			write_json_value(w, key) or_return
			io.write_byte(w, ':') or_return
			write_json_value(w, v[key]) or_return
		}
		io.write_byte(w, '}') or_return
	case json.Array:
		io.write_byte(w, '[') or_return
		for item, i in v {
			if i > 0 do io.write_byte(w, ',') or_return
			write_json_value(w, item) or_return
		}
		io.write_byte(w, ']') or_return
	case string:
		if !utf8.valid_string(v) do return .Unsupported
		json.write_quoted_json_string(w, v) or_return
	case i64:  io.write_i64(w, v) or_return
	case bool: io.write_string(w, "true" if v else "false") or_return
	case nil, json.Null: io.write_string(w, "null") or_return
	case f64: unreachable() // YAML numbers always carry their exact lexeme.
	}
	return
}

json_projection :: proc{
	json_tasks, json_detail, json_tree, json_ready, json_dependencies,
	json_validation, json_preview, json_summary, json_receipt,
}

json_result :: proc(value: $T, code := Exit_Code.Success) -> (string, string, Exit_Code) {
	context.allocator = context.temp_allocator
	b := strings.builder_make(context.temp_allocator)
	w := strings.to_writer(&b)
	err := write_json_value(w, json.Object{"version" = i64(1), "result" = json_projection(value)})
	if err == .Unsupported do return "", "unsupported_output: JSON requires valid UTF-8", .Output_Failed
	if err != .None || io.write_byte(w, '\n') != .None do return "", "cannot encode JSON response", .Output_Failed
	return strings.to_string(b), "", code
}

optional_string :: proc(s: string) -> json.Value {
	if s == "" do return nil
	return s
}

json_task :: proc(item: ^app.Task_Candidate) -> json.Object {
	return json_summary({id = item.fields.id, path = item.path, status = item.fields.status, title = item.fields.title})
}

json_summary :: proc(task: app.Task_Summary) -> json.Object {
	return {"id" = task.id, "path" = task.path, "status" = task.status, "title" = task.title}
}

json_receipt :: proc(operation: string) -> json.Object {
	return {"ok" = true, "operation" = optional_string(operation)}
}

json_tasks :: proc(items: []^app.Task_Candidate) -> json.Array {
	rows := make(json.Array, len(items))
	for item, i in items do rows[i] = json_task(item)
	return rows
}

json_strings :: proc(values: []string) -> json.Array {
	rows := make(json.Array, len(values))
	for value, i in values do rows[i] = value
	return rows
}

json_custom :: proc(node: ^app.Custom_Node) -> json.Value {
	if node == nil do return nil
	switch node.kind {
	case .Absent, .Null: return nil
	case .String: return node.text
	case .Boolean: return strings.equal_fold(node.text, "true")
	case .Integer: return json.Object{"$integer" = node.text}
	case .Float:   return json.Object{"$float" = node.text}
	case .Sequence:
		items := make(json.Array, len(node.items))
		for &item, i in node.items do items[i] = json_custom(&item)
		return items
	case .Mapping:
		obj := make(json.Object, len(node.entries))
		for &entry in node.entries {
			key := entry.key.text
			if strings.has_prefix(key, "$") do key = strings.concatenate({"$", key}, context.temp_allocator)
			obj[key] = json_custom(&entry.value)
		}
		return obj
	}
	unreachable()
}

json_detail :: proc(task: app.Task_Read) -> json.Object {
	obj := json_task(task.item)
	f := &task.item.fields
	obj["schema_version"] = i64(1)
	obj["parent"] = optional_string(f.parent)
	obj["priority"] = optional_string(f.priority)
	obj["due"] = optional_string(f.due)
	obj["tags"] = json_strings(f.tags[:])
	obj["depends_on"] = json_strings(f.depends_on[:])
	obj["custom"] = json_custom(f.custom)
	obj["source"] = task.source
	return obj
}

json_tree :: proc(rows: []app.Tree_Row) -> json.Array {
	result := make(json.Array, len(rows))
	positions := [app.Tree_Position]string{
		.Root = "root", .Child = "child", .Unresolved_Parent = "unresolved_parent", .Parent_Cycle = "parent_cycle",
	}
	for row, i in rows {
		obj := json_task(row.item)
		obj["parent"] = optional_string(row.item.fields.parent)
		obj["depth"] = i64(row.depth)
		obj["position"] = positions[row.position]
		result[i] = obj
	}
	return result
}

json_ready :: proc(rows: []app.Ready_Task) -> json.Array {
	result := make(json.Array, len(rows))
	for row, i in rows {
		task := json_task(row.item)
		task["readiness"] = READINESS_LABELS[row.readiness]
		result[i] = task
	}
	return result
}

json_refs :: proc(items: []^app.Task_Candidate) -> json.Array {
	refs := make(json.Array, len(items))
	for item, i in items do refs[i] = json.Object{"id" = item.fields.id, "path" = item.path}
	return refs
}

json_dependencies :: proc(view: app.Dependency_View) -> json.Object {
	states := [app.Target_Status]string{
		.Resolved = "resolved", .Missing = "missing", .Ambiguous = "ambiguous",
		.Invalid = "invalid", .Unsupported = "unsupported",
	}
	refs := make(json.Array, len(view.prerequisites))
	for ref, i in view.prerequisites {
		refs[i] = json.Object{"id" = ref.written_id, "resolution" = states[ref.status], "candidates" = json_refs(ref.candidates)}
	}
	return {"task" = json_task(view.task), "prerequisites" = refs, "dependents" = json_tasks(view.dependents)}
}

json_span :: proc(span: app.Source_Span) -> json.Object {
	return {"start" = i64(span.start), "end" = i64(span.end)}
}

json_preview :: proc(p: app.Removal_Preview) -> json.Object {
	edits := make(json.Array, len(p.edits))
	for edit, i in p.edits {
		edits[i] = json.Object{"id" = edit.id, "path" = edit.path, "field" = edit.field, "span" = json_span(edit.span)}
	}
	return {"plan" = p.token, "edits" = edits}
}

json_finding :: proc(f: app.Finding) -> json.Object {
	obj := json.Object{
		"severity" = "warning" if f.severity == .Warning else "error", "code" = f.code, "message" = f.message,
		"path" = optional_string(f.path), "id" = optional_string(f.id), "field" = optional_string(f.field),
		"target_id" = optional_string(f.target_id), "location" = nil,
	}
	if f.limit != 0 {
		obj["observed"] = i64(f.observed)
		obj["limit"] = i64(f.limit)
	}
	if f.location.line > 0 {
		obj["location"] = json.Object{"line" = i64(f.location.line), "column" = i64(f.location.column), "span" = json_span(f.location.span)}
	}
	// A duplicate_id finding owns the full group. Repeated ambiguous references
	// carry its size, keeping the report proportional to the graph and findings.
	obj["related_count"] = i64(len(f.related))
	if len(f.related) > 1 && f.target_id != "" {
		obj["related"] = json.Array{}
	} else {
		obj["related"] = json_refs(f.related)
	}
	edges := make(json.Array, len(f.edges))
	for edge, i in f.edges do edges[i] = json.Object{"from" = edge.from, "to" = edge.to}
	obj["edges"] = edges
	return obj
}

json_validation :: proc(r: app.Validation) -> json.Object {
	findings := make(json.Array, len(r.findings))
	for f, i in r.findings do findings[i] = json_finding(f)
	return {
		"findings" = findings, "errors" = i64(r.errors), "warnings" = i64(r.warnings),
		"scan_complete" = r.scan_complete, "history_complete" = r.history_complete, "recovery_complete" = r.recovery_complete,
	}
}
