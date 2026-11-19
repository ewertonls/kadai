#+test
package app

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import "kadai:project"
import "kadai:storage"

@(private)
count_finding :: proc(r: Validation, code: string) -> (n: int) {
	for f in r.findings { if f.code == code do n += 1 }
	return
}

@(test)
validate_reports_multiple_issues_and_respects_discovery_boundaries :: proc(t: ^testing.T) {
	tmp, e := os.mkdir_temp("", "kadai-validate-", context.temp_allocator)
	if !testing.expect(t, e == nil) do return
	defer os.remove_all(tmp)
	config := storage.child(tmp, ".kadai.yaml")
	testing.expect(t, os.write_entire_file(config, "tasks: {root: ., wrong: 1}\nids: {prefix: '!'}\n") == nil)
	testing.expect(t, write_graph_task(tmp, "a.md", "A", "todo", "parent: missing\n"))
	testing.expect(t, write_graph_task(tmp, "b.md", "B", "done", "depends_on: [A]\n"))
	testing.expect(t, write_graph_task(tmp, "c.md", "C", "done", "depends_on: [B]\n"))
	report, issue := validate_project(tmp)
	if !testing.expect_value(t, issue, "") do return
	testing.expect(t, report.errors == 2 && !report.scan_complete && count_finding(report, "missing_parent") == 0)
	testing.expect(t, os.write_entire_file(config, "tasks: {root: .}") == nil)
	report, issue = validate_project(tmp)
	testing.expect(t, issue == "" && report.scan_complete && report.history_complete && report.recovery_complete)
	testing.expect_value(t, count_finding(report, "missing_parent"), 1)
	testing.expect_value(t, count_finding(report, "completed_with_unmet_prerequisites"), 2)
	testing.expect(t, report.errors == 1 && report.warnings == 2)
	l := project.DEFAULT_SCAN_LIMITS
	l.candidates = 1
	report, issue = validate_project(tmp, {}, l)
	testing.expect(t, issue == "" && !report.scan_complete && count_finding(report, "scan_incomplete") == 1)
	testing.expect_value(t, count_finding(report, "missing_parent"), 0)
	testing.expect(t, !os.exists(storage.child(tmp, ".kadai")))
}

@(test)
validate_releases_task_bodies_during_the_scan :: proc(t: ^testing.T) {
	tmp, e := os.mkdir_temp("", "kadai-validate-bodies-", context.temp_allocator)
	if !testing.expect(t, e == nil) do return
	defer os.remove_all(tmp)
	tasks := storage.child(tmp, "tasks")
	if !testing.expect(t, os.mkdir(tasks) == nil) do return
	body := strings.repeat("a", 48 << 10, context.temp_allocator)
	for id in ([3]string{"A", "B", "C"}) {
		source := fmt.tprintf("---\nkadai: task\nid: %s\ntitle: Example\nstatus: todo\n---\n%s", id, body)
		if !testing.expect(t, os.write_entire_file(storage.child(tasks, fmt.tprintf("%s.md", id)), source) == nil) do return
	}

	// Each task fits on its own. Keeping all three bodies would exhaust the report arena.
	space := make([]byte, 128 << 10)
	defer delete(space)
	arena: mem.Arena
	mem.arena_init(&arena, space)
	{
		context.temp_allocator = mem.arena_allocator(&arena)
		report, issue := validate_project(tmp)
		testing.expect_value(t, issue, "")
		testing.expect(t, report.scan_complete && report.errors == 0)
	}
}

@(test)
validate_checks_history_journals_and_snapshots_read_only :: proc(t: ^testing.T) {
	tmp, e := os.mkdir_temp("", "kadai-validate-state-", context.temp_allocator)
	if !testing.expect(t, e == nil) do return
	defer os.remove_all(tmp)
	_, issue := create_task(tmp, {}, {title = "Before", destination = "a.md"})
	if !testing.expect_value(t, issue, "") do return
	op, problem := update_task(tmp, {}, {id = "0001", field = "title", values = {"After"}})
	if !testing.expect_value(t, problem, "") do return
	report: Validation
	report, issue = validate_project(tmp)
	if !testing.expect(t, issue == "" && report.errors == 0 && report.warnings == 0) do return
	state := storage.child(tmp, "tasks/.kadai")
	journal := storage.child(storage.child(state, "recovery"), op)
	receipt, read_err := os.read_entire_file(storage.child(journal, "committed"), context.temp_allocator)
	if !testing.expect(t, read_err == nil) do return
	intent := storage.child(state, "intent")
	if !testing.expect(t, os.write_entire_file(intent, receipt) == nil) do return
	testing.expect(t, os.write_entire_file(storage.child(tmp, "tasks/a.md"), "later external edit") == nil)
	report, issue = validate_project(tmp)
	testing.expect(t, issue == "" && count_finding(report, "pending_operation") == 1 && count_finding(report, "recovery_conflict") == 1)
	pending, _ := os.read_entire_file(intent, context.temp_allocator)
	testing.expect_value(t, string(pending), string(receipt))
	for name in ([]string{"bad1","bad2"}) {
		testing.expect(t, os.write_entire_file(storage.child(state, storage.child("used-ids/v1", name)), "wrong") == nil)
	}
	image := storage.child(journal, "0-original")
	testing.expect(t, os.write_entire_file(image, "corrupt") == nil)
	testing.expect(t, os.write_entire_file(intent, "broken") == nil)
	report, issue = validate_project(tmp)
	testing.expect_value(t, issue, "")
	testing.expect_value(t, count_finding(report, "invalid_used_id_directory"), 2)
	testing.expect_value(t, count_finding(report, "corrupt_intent"), 1)
	testing.expect_value(t, count_finding(report, "corrupt_snapshot"), 1)
	bytes, _ := os.read_entire_file(image, context.temp_allocator)
	testing.expect_value(t, string(bytes), "corrupt")
	l := project.DEFAULT_SCAN_LIMITS
	l.yaml.bytes = 128
	report, issue = validate_project(tmp, {}, l)
	testing.expect(t, issue == "" && report.scan_complete && !report.recovery_complete && count_finding(report, "recovery_incomplete") > 0)
}
