#+test
package document

import "core:strings"
import "core:testing"
import "kadai:yaml"

@(test)
log_append_preserves_handwritten_markdown_and_entry_order :: proc(t: ^testing.T) {
	header  :: "\uFEFF---\r\nkadai: task\r\nid: T\r\ntitle: Café # keep\r\nstatus: todo\r\n---\r\n"
	body    ::
		"\n## Log\n````markdown\n```\n<!-- kadai:log:start -->\n````\n" +
		"<!-- kadai:log:start -->\r\n\r\n## Log\r\n\r\n"
	first   :: "2026-11-18T13:42:07.1234-03:30"
	second  :: "2016-12-31t23:59:60z"
	message :: "- café\r\n### Implementation notes\n  ~~~md\n<!-- kadai:log:end -->\n### 2020-05-05T00:00:00Z\n  ~~~~"
	prefix  ::
		header +
		body +
		"### " +
		first +
		"\r\n\r\n" +
		message +
		"\r\n\n### " +
		second +
		"\r\nManual edit  \r\n"
	suffix  :: "<!-- kadai:log:end -->\r\n \t\r\n"
	source  :: prefix + suffix
	// The new entry has a duplicate timestamp and preserves significant whitespace.
	added :: "\r\n  build  \n\n- verify\n"
	edited, err := append_log(source, {len(header), len(source)}, second, added)
	defer delete(edited)
	if !testing.expect_value(t, err, nil) do return
	testing.expect_value(
		t,
		edited,
		prefix + "### " + second + "\r\n\r\n" + added + "\r\n\r\n" + suffix,
	)
	entries, read_err := parse_log(edited, {len(header), len(edited)})
	defer delete(entries)
	if !testing.expect_value(t, read_err, nil) || !testing.expect_value(t, len(entries), 3) do return
	testing.expect_value(t, entries[0], Log_Entry{first, message})
	testing.expect_value(t, entries[1], Log_Entry{second, "Manual edit  "})
	testing.expect_value(t, entries[2], Log_Entry{second, added})
}

@(test)
first_log_append_at_eof_respects_source_budget :: proc(t: ^testing.T) {
	source  :: "---\nkadai: task\nid: T\ntitle: T\nstatus: todo\n---"
	stamp   :: "2026-11-18T00:00:00Z"
	message :: "- first\n- second\r"
	result  ::
		source +
		"\n\n<!-- kadai:log:start -->\n\n## Log\n\n### " +
		stamp +
		"\n\n" +
		message +
		"\r\n\n<!-- kadai:log:end -->\n"
	parts, status := extract_frontmatter(source)
	if !testing.expect_value(t, status, .Present) do return
	empty, read_err := parse_log(source, parts.body)
	defer delete(empty)
	testing.expect_value(t, read_err, nil)
	testing.expect_value(t, len(empty), 0)
	limits := DEFAULT_FRONTMATTER_LIMITS
	limits.task_source_bytes = len(result)
	edited, err := append_log(source, parts.body, stamp, message, limits = limits)
	defer delete(edited)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, edited, result)
	limits.task_source_bytes -= 1
	over, limit_err := append_log(source, parts.body, stamp, message, limits = limits)
	testing.expect_value(t, over, "")
	d, ok := limit_err.(yaml.Diagnostic)
	if !testing.expect(t, ok) do return
	defer yaml.destroy_diagnostic(&d)
	testing.expect_value(t, d.code, "limit_exceeded")
	testing.expect_value(t, d.field, "task_source_bytes")
}

@(test)
invalid_log_structure_reports_source_line_and_refuses_append :: proc(t: ^testing.T) {
	header  :: "---\nkadai: task\nid: T\ntitle: T\nstatus: todo\n---\n"
	open    :: "<!-- kadai:log:start -->\n"
	close   :: "<!-- kadai:log:end -->"
	section :: open + "## Log\n"
	stamp   :: "2026-11-18T00:00:00Z"
	cases := [?]struct {
		body: string,
		line: int,
	} {
		{close, 7},
		{open + close, 8},
		{section, 9},
		{section + open + close, 9},
		{section + close + "\nafter", 10},
		{section + close + "\n" + open, 10},
		{"<!-- kadai:log:start ->\n", 7},
		{"<!-- kadai:log", 7},
		{section + "### 2026-02-31T00:00:00+00:00\nbody\n" + close, 9},
		{section + "### " + stamp + "\n\n" + close, 9},
	}
	for c in cases {
		source := strings.concatenate({header, c.body}, context.temp_allocator)
		span := Byte_Range{len(header), len(source)}
		list, read_err := parse_log(source, span, "T.md", collect = false)
		defer delete(list)
		edited, write_err := append_log(source, span, stamp, "note", "T.md")
		defer delete(edited)
		testing.expect_value(t, edited, "")
		for failure in ([?]Header_Edit_Error{read_err, write_err}) {
			d, ok := failure.(yaml.Diagnostic)
			if !testing.expect(t, ok) do continue
			defer yaml.destroy_diagnostic(&d)
			testing.expect_value(t, d.code, "invalid_log")
			testing.expect_value(t, d.path, "T.md")
			testing.expect_value(t, d.location.line, c.line)
		}
	}
}

@(test)
log_append_refuses_unreadable_or_structural_messages :: proc(t: ^testing.T) {
	stamp :: "2026-11-18T00:00:00Z"
	cases := [?]struct {
		body, message: string,
	} {
		{"", "\u2002\t"},
		{"", "bad \xff"},
		{"", "hello\n### " + stamp + "\nextra"},
		{"", "hello\n<!-- kadai:log:end -->"},
		{"", "```odin\ncode"},
		{"~~~\nunfinished code", "hello"},
	}
	for c in cases {
		edited, err := append_log(c.body, {0, len(c.body)}, stamp, c.message)
		defer delete(edited)
		testing.expect_value(t, edited, "")
		d, ok := err.(yaml.Diagnostic)
		if !testing.expect(t, ok) do continue
		defer yaml.destroy_diagnostic(&d)
		testing.expect_value(t, d.code, "invalid_log")
	}
}
