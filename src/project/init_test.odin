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
}
