package document

import "base:intrinsics"
import "base:runtime"
import "core:strings"
import "core:unicode/utf8"
import "kadai:task"
import "kadai:yaml"

Log_Entry :: struct {
	timestamp, content: string,
}

@(private)
LOG_START :: "<!-- kadai:log:start -->"
@(private)
LOG_END   :: "<!-- kadai:log:end -->"

@(private)
Log_Layout :: struct {
	end_marker: int, // -1 when the body has no log.
	count     : int,
	last      : Log_Entry,
	open_fence: bool,
}

@(private)
log_problem :: proc(source, path: string, at: int, message: string) -> (err: Header_Edit_Error) {
	return(
		yaml.diagnostic(
			path,
			"invalid_log",
			"",
			message,
			yaml.locate(source, {at, at}),
		) or_return \
	)
}

// A closing fence must match its opening character and be at least as long.
@(private)
log_fenced_line :: proc(line: string, fence: ^string) -> bool {
	inside := fence^ != ""
	text := strings.trim_left(line, " ")
	if len(line) - len(text) > 3 || len(text) < 3 || (text[0] != '`' && text[0] != '~') do return inside
	n := 1
	for n < len(text) && text[n] == text[0] do n += 1
	if inside {
		if text[0] == fence^[0] && n >= len(fence^) && strings.trim(text[n:], " \t") == "" do fence^ = ""
	} else if n >= 3 && (text[0] != '`' || !strings.contains(text[n:], "`")) {
		fence^ = text[:n]
	}
	return inside || fence^ != ""
}

@(private)
log_entry_content :: proc(raw: string) -> string {
	// The writer adds one blank line after the heading and one before the next
	// heading/marker. Remove only this framing. Keep indentation, hard breaks
	// and additional newlines belonging to the entry itself.
	text := raw
	if strings.has_prefix(
		text,
		"\r\n",
	) {text = text[2:]} else if strings.has_prefix(text, "\n") {text = text[1:]}
	for _ in 0 ..< 2 {
		if !strings.has_suffix(text, "\n") do break
		text = text[:len(text) - len(line_ending(text, len(text) - 1))]
	}
	return text
}

@(private)
scan_log :: proc(
	source: string,
	body: Byte_Range,
	path: string,
	entries: ^[dynamic]Log_Entry = nil,
) -> (
	layout: Log_Layout,
	err: Header_Edit_Error,
) {
	layout.end_marker = -1
	if body.start < 0 || body.end != len(source) || body.start > body.end {
		return {}, log_problem(source, path, 0, "Read the log from the task's Markdown body.")
	}
	stage: enum {
		Before,
		Title,
		Entries,
		After,
	}
	fence, timestamp: string
	content_start, heading_start: int
	for pos := body.start; pos < body.end; {
		start := pos
		lf := strings.index_byte(source[start:], '\n')
		pos = start + lf + 1 if lf >= 0 else body.end
		line := source[start:start + lf] if lf >= 0 else source[start:]
		if lf >= 0 do line = strings.trim_suffix(line, "\r")
		blank := strings.trim(line, " \t") == ""
		if stage == .After {
			if !blank do return {}, log_problem(source, path, start, "Move the log end marker and its section to the end of the task.")
			continue
		}
		if log_fenced_line(line, &fence) {
			if stage == .Title || stage == .Entries && timestamp == "" {
				return {}, log_problem(source, path, start, "Put fenced content under a timestamp heading in the log.")
			}
			continue
		}
		if line == LOG_START {
			if stage != .Before do return {}, log_problem(source, path, start, "Keep only one log start marker in the task.")
			stage = .Title
			continue
		}
		end := line == LOG_END
		if end && stage != .Entries {
			return {}, log_problem(source, path, start, "Place the log start marker and ## Log before its end marker.")
		}
		// A misspelled reserved marker must not be mistaken for a task without a log.
		trimmed := strings.trim_left(line, " ")
		if !end && len(line) - len(trimmed) <= 3 && strings.has_prefix(trimmed, "<!--") {
			comment := strings.trim_left(trimmed[4:], " \t")
			if strings.has_prefix(comment, "kadai:log:") ||
			   strings.trim_right(comment, " \t->") == "kadai:log" {
				return {}, log_problem(source, path, start, "Put <!-- kadai:log:start --> or <!-- kadai:log:end --> alone on an unindented line.")
			}
		}
		switch stage {
		case .Before, .After:
		case .Title:
			if blank do continue
			if line != "## Log" do return {}, log_problem(source, path, start, "Add the ## Log heading after the log start marker.")
			stage = .Entries
		case .Entries:
			stamp := strings.trim_prefix(line, "### ")
			heading := len(stamp) != len(line) && task.valid_timestamp(stamp)
			if !end && !heading {
				if timestamp == "" && !blank do return {}, log_problem(source, path, start, "Start each entry with ### and an RFC 3339 timestamp including its time zone.")
				continue
			}
			if timestamp != "" {
				content := log_entry_content(source[content_start:start])
				if strings.trim_space(content) == "" do return {}, log_problem(source, path, heading_start, "Add Markdown content under this log timestamp.")
				layout.last = {timestamp, content}
				layout.count += 1
				if entries != nil {_ = append(entries, layout.last) or_return}
			}
			if end {
				layout.end_marker = start
				stage = .After
			} else {
				timestamp, content_start, heading_start = stamp, pos, start
			}
		}
	}
	if stage == .Title || stage == .Entries {
		return {}, log_problem(source, path, body.end, "Close any open code fence, then finish the log with <!-- kadai:log:end -->.")
	}
	layout.open_fence = fence != ""
	return
}

// Entries borrow their strings from source. The caller owns the entry array.
parse_log :: proc(
	source: string,
	body: Byte_Range,
	path := "",
	collect := true,
) -> (
	entries: [dynamic]Log_Entry,
	err: Header_Edit_Error,
) {
	list := &entries if collect else nil
	_, err = scan_log(source, body, path, list)
	if err != nil {delete(entries); entries = nil}
	return
}

// Compose one source-preserving insertion. The caller owns the candidate.
append_log :: proc(
	source: string,
	body: Byte_Range,
	timestamp, content: string,
	path := "",
	limits := DEFAULT_FRONTMATTER_LIMITS,
) -> (
	candidate: string,
	err: Header_Edit_Error,
) {
	layout := scan_log(source, body, path) or_return
	if strings.trim_space(content) == "" || !utf8.valid_string(content) {
		return "", log_problem(
			source,
			path,
			body.end,
			"Supply a nonblank UTF-8 Markdown message for the log entry.",
		)
	}
	if !task.valid_timestamp(timestamp) do return "", log_problem(source, path, body.end, "Use an RFC 3339 log timestamp with a time zone.")
	if layout.open_fence do return "", log_problem(source, path, body.end, "Close the Markdown code fence before appending a log section.")
	at := layout.end_marker if layout.end_marker >= 0 else body.end
	eol := line_ending(source, strings.last_index_byte(source[:at], '\n'))
	opening, closing: string
	if layout.end_marker < 0 {
		// Start the section after a blank line, reusing any existing breaks.
		if eol == "\r\n" {
			opening, closing = "\r\n\r\n" + LOG_START + "\r\n\r\n## Log\r\n\r\n", LOG_END + "\r\n"
		} else {
			opening, closing = "\n\n" + LOG_START + "\n\n## Log\n\n", LOG_END + "\n"
		}
		tail := source
		for _ in 0 ..< 2 {
			if !strings.has_suffix(tail, "\n") do break
			tail = tail[:len(tail) - len(line_ending(tail, len(tail) - 1))]
			opening = opening[len(eol):]
		}
	}
	// A message ending in a bare CR would fuse with an LF delimiter. Give the
	// separator its own CRLF so the message's last byte remains in the entry.
	content_eol := "\r\n" if strings.has_suffix(content, "\r") else eol
	parts := [?]string {
		source[:at],
		opening,
		"### ",
		timestamp,
		eol,
		eol,
		content,
		content_eol,
		eol,
		closing,
		source[at:],
	}
	size := 0
	for part in parts do size = intrinsics.saturating_add(size, len(part))
	if size > limits.task_source_bytes do return "", yaml.limit_diagnostic(path, "task_source_bytes", size, limits.task_source_bytes) or_return
	proposal := strings.concatenate(parts[:]) or_return
	defer if err != nil {delete(proposal)}
	if len(proposal) != size do return "", runtime.Allocator_Error.Out_Of_Memory
	// A message can contain structural lines or an unfinished fence. Only
	// publish the proposal if the one new entry round-trips literally.
	edited := scan_log(proposal, {body.start, len(proposal)}, path) or_return
	if edited.count != layout.count + 1 || edited.last != (Log_Entry{timestamp, content}) {
		return "", log_problem(
			source,
			path,
			at,
			"Fence literal log markers and timestamp headings inside the message.",
		)
	}
	return proposal, nil
}
