#+test
package project

import "core:os"
import "core:strings"
import "core:testing"
import "kadai:storage"

@(test)
init_recovers_without_rewriting_config :: proc(t: ^testing.T) {
	dir, err := os.mkdir_temp("", "kadai-init-", context.temp_allocator)
	if !testing.expect(t, err == nil) do return
	defer os.remove_all(dir)
	dir, _ = storage.physical(dir, .Directory)
	opts := Options {
		tasks_root = storage.child(dir, "my tasks"),
		id_prefix  = "KAD",
	}
	limits := DEFAULT_SCAN_LIMITS
	limits.yaml.depth = 2
	_, limited := initialize(dir, opts, limits)
	testing.expect(t, strings.contains(limited, "initial config exceeds YAML limits"), limited)
	testing.expect(t, !os.exists(storage.child(dir, ".kadai.yaml")) && !os.exists(opts.tasks_root))
	cfg, issue := initialize(dir, opts)
	if !testing.expect_value(t, issue, "") do return
	testing.expect(t, os.is_dir(cfg.tasks))
	testing.expect(t, !os.exists(cfg.boards) && !os.exists(storage.child(cfg.tasks, ".kadai")))
	path := storage.child(dir, ".kadai.yaml")
	data, read_err := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, read_err == nil && !strings.contains(string(data), dir))
	testing.expect(t, os.remove(cfg.tasks) == nil)
	_, issue = initialize(dir, opts)
	testing.expect_value(t, issue, "")
	testing.expect(t, os.is_dir(cfg.tasks))
	_, issue = initialize(dir, Options{id_prefix = "ABC"})
	testing.expect(t, issue != "")
	after, _ := os.read_entire_file(path, context.temp_allocator)
	testing.expect_value(t, string(after), string(data))

	// Enable Git on an existing collection with CRLF rules and an unterminated negation.
	ignore := storage.child(cfg.tasks, ".gitignore")
	existing_rules :: "# /.kadai/\r\n*.tmp\r\n!/.kadai/"
	if !testing.expect(t, !os.exists(ignore) && os.write_entire_file(ignore, existing_rules) == nil) do return
	_, issue = initialize(dir, opts, git = true)
	if !testing.expect_value(t, issue, "") do return
	rules, rules_err := os.read_entire_file(ignore, context.temp_allocator)
	testing.expect(t, rules_err == nil && string(rules) == existing_rules + "\r\n/.kadai/\r\n")

	report: Invocation_Report
	opts.report = &report
	_, issue = initialize(dir, opts, git = true)
	testing.expect(t, issue == "" && !report.write_started)
}

@(test)
init_git_requires_single_link_only_for_changes :: proc(t: ^testing.T) {
	dir, err := os.mkdir_temp("", "kadai-init-link-", context.temp_allocator)
	if !testing.expect(t, err == nil) do return
	defer os.remove_all(dir)
	tasks := storage.child(dir, "tasks")
	ignore := storage.child(tasks, ".gitignore")
	shared := storage.child(dir, "shared.ignore")
	if !testing.expect(t, os.mkdir(tasks) == nil) do return
	if !testing.expect(t, os.write_entire_file(shared, "*.tmp\n") == nil) do return
	if !testing.expect(t, os.link(shared, ignore) == nil) do return

	report: Invocation_Report
	opts := Options {
		report = &report,
	}
	_, issue := initialize(dir, opts, git = true)
	testing.expect(
		t,
		issue != "" && !report.write_started && !os.exists(storage.child(dir, ".kadai.yaml")),
	)
	rules, read_err := os.read_entire_file(ignore, context.temp_allocator)
	testing.expect(t, read_err == nil && string(rules) == "*.tmp\n")

	_, issue = initialize(dir, opts)
	if !testing.expect_value(t, issue, "") do return
	if !testing.expect(t, os.write_entire_file(shared, "/.kadai/\n") == nil) do return
	report = {}
	_, issue = initialize(dir, opts, git = true)
	testing.expect(t, issue == "" && !report.write_started)
}
