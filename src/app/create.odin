package app

import "core:fmt"
import "core:io"
import "kadai:document"
import "kadai:identity"
import "kadai:project"
import "kadai:storage"
import "kadai:task"

Create_Task :: struct {
	title, body, destination: string,
	status: Maybe(string),
}

@(private)
Creation :: struct {
	using request: Create_Task,
	result: Task_Summary,
}

Task_Summary :: struct {id, path, title, status: string}

@(private)
plan_create :: proc(view: ^Collection, data: rawptr) -> ([]storage.Change, string) {
	context.allocator = context.temp_allocator
	c := (^Creation)(data)
	for candidate in view.index.candidates {
		if candidate.fields.id == "" do return nil, fmt.tprintf("%s: cannot allocate with an unknown task ID", candidate.path)
	}
	status := c.status.? or_else "todo"
	if !task.valid_title(c.title) do return nil, "invalid title"
	if !task.valid_status(status, view.config.vocabulary) do return nil, "invalid status"
	if len(c.body) > view.limits.source_bytes || len(c.title) > view.limits.yaml.bytes do return nil, "task exceeds size limit"
	id, path, issue := identity.allocate(&view.history, view.config.id_prefix, view.config.tasks, storage.slash(c.destination))
	if issue != "" do return nil, issue
	c.result = {id, path, c.title, status}
	source := fmt.tprintf("---\nkadai: task\nid: %q\ntitle: %q\nstatus: %q\n---\n%s", id, c.title, status, c.body)
	doc := document.decode_task(source, view.config.vocabulary, view.limits.source_bytes, view.limits.yaml, path)
	if doc.status != .Decoded || doc.fields.title != c.title || doc.fields.id != id || doc.fields.status != status {
		return nil, "unable to encode task within source and YAML limits"
	}
	if issue = identity.observe(&view.history, id); issue != "" do return nil, issue
	change := make([]storage.Change, 1)
	change[0] = {kind = .Create, path = path, data = transmute([]byte)source}
	return change, ""
}

create_task_result :: proc(cwd: string, options: Project_Options, request: Create_Task, limits := project.DEFAULT_SCAN_LIMITS) -> (Task_Summary, string) {
	c := Creation{request = request}
	operation, issue := mutate_collection(cwd, options, plan_create, &c, limits)
	if issue != "" {
		if operation != "" { issue = fmt.tprintf("operation %s for %s: %s", operation, c.result.id, issue) }
		return {}, issue
	}
	return c.result, ""
}

create_task :: proc(cwd: string, options: Project_Options, request: Create_Task, limits := project.DEFAULT_SCAN_LIMITS) -> (id, issue: string) {
	created, problem := create_task_result(cwd, options, request, limits)
	return created.id, problem
}

// Read pipes and ordinary files incrementally before taking the writer lock.
read_body :: proc(reader: io.Reader, limit := project.DEFAULT_SCAN_LIMITS.source_bytes) -> (string, string) {
	body := make([dynamic]byte, context.temp_allocator)
	buf: [32<<10]byte
	for {
		n, e := io.read(reader, buf[:min(len(buf), limit-len(body)+1)])
		if n < 0 || n > limit-len(body) do return "", "body exceeds task_source_bytes"
		if _, err := append(&body, ..buf[:n]); err != nil do return "", "cannot allocate task body"
		if e == .EOF do break
		if e != .None || n == 0 do return "", fmt.tprintf("reading task body: %v", e)
	}
	return string(body[:]), ""
}
