package app

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:time"
import "kadai:document"
import "kadai:project"
import "kadai:storage"
import "kadai:yaml"

Log_Entry :: document.Log_Entry

@(private)
log_issue :: proc(err: document.Header_Edit_Error) -> string {
	switch problem in err {
	case yaml.Diagnostic:
		line_buffer: [32]byte
		location := ""
		if problem.location.line != 0 {
			location = fmt.bprintf(line_buffer[:], ":%d", problem.location.line)
		}
		message, alloc_err := strings.concatenate(
			{problem.path, location, ": ", problem.code, ": ", problem.message},
			context.temp_allocator,
		)
		if alloc_err != nil || message == "" do return "cannot allocate task log diagnostic"
		return message
	case runtime.Allocator_Error:
		return "cannot allocate task log"
	}
	unreachable()
}

// The entry slice and its backing Markdown source live in invocation scratch memory.
list_log :: proc(
	cwd: string,
	options: Project_Options,
	id: string,
	limits := project.DEFAULT_SCAN_LIMITS,
) -> (
	[]Log_Entry,
	string,
) {
	view, issue := read_collection(cwd, options, limits)
	if issue != "" do return nil, issue
	item, lookup_issue := unique_task(&view, id)
	if lookup_issue != "" do return nil, lookup_issue
	source, read_issue := read_versioned(&view, item)
	if read_issue != "" do return nil, read_issue
	context.allocator = context.temp_allocator
	entries, err := document.parse_log(source, {item.body_start, len(source)}, item.path)
	if err != nil do return nil, log_issue(err)
	return entries[:], ""
}

@(private)
Log_Add :: struct {
	id, content: string,
}

@(private)
plan_log_add :: proc(view: ^Collection, data: rawptr) -> ([]storage.Change, string) {
	context.allocator = context.temp_allocator
	request := (^Log_Add)(data)
	item, issue := unique_task(view, request.id)
	if issue != "" do return nil, issue
	source, read_issue := read_versioned(view, item, mutation = true)
	if read_issue != "" do return nil, read_issue
	timestamp, time_issue := log_timestamp(time.now(), view.config.timezone)
	if time_issue != "" do return nil, time_issue
	edited, err := document.append_log(
		source,
		{item.body_start, len(source)},
		timestamp,
		request.content,
		item.path,
		{view.limits.source_bytes, view.limits.yaml.bytes},
	)
	if err != nil do return nil, log_issue(err)
	change, alloc_err := make([]storage.Change, 1)
	if alloc_err != nil do return nil, "cannot allocate task log change"
	change[0] = {
		kind     = .Replace,
		path     = item.path,
		expected = item.version,
		data     = transmute([]byte)edited,
	}
	return change, ""
}

add_log :: proc(
	cwd: string,
	options: Project_Options,
	id, content: string,
	limits := project.DEFAULT_SCAN_LIMITS,
) -> (
	operation, issue: string,
) {
	request := Log_Add{id, content}
	return mutate_collection(cwd, options, plan_log_add, &request, limits)
}
