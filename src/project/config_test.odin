#+test
package project

import "core:os"
import "core:testing"
import "kadai:storage"

@(test)
physical_collection_and_effective_config :: proc(t: ^testing.T) {
	dir, err := os.mkdir_temp("", "kadai-config-", context.temp_allocator)
	if !testing.expect(t, err == nil) do return
	defer os.remove_all(dir)
	dir, _ = storage.physical(dir, .Directory)
	sub := storage.child(dir, "sub")
	testing.expect(t, os.mkdir(sub) == nil)
	config := storage.child(dir, ".kadai.yaml")
	write :: proc(path, s: string) -> bool {return(
			os.write_entire_file(path, transmute([]byte)s) ==
			nil \
		)}
	testing.expect(t, write(config, "tasks: {root: [bad]}\nstatuses: {review: done}\n"))
	local, issue := resolve(sub)
	testing.expect_value(t, issue, "")
	testing.expect_value(t, local.tasks, storage.child(sub, "tasks"))
	testing.expect(t, !os.exists(local.tasks))
	_, issue = resolve(sub, {project = ".."})
	testing.expect(t, issue != "")
	options := Options {
		project    = "..",
		tasks_root = "sub/queue",
	}
	cfg: Config
	cfg, issue = resolve(sub, options)
	testing.expect_value(t, issue, "")
	testing.expect_value(t, cfg.tasks, storage.child(sub, "queue"))
	testing.expect_value(t, cfg.statuses["review"], "done")
	testing.expect(t, write(config, "tasks: {unknown: 1}\n"))
	_, issue = resolve(sub, options)
	testing.expect(t, issue != "")
	testing.expect(t, write(config, "tasks: {root: .}\n"))
	when ODIN_OS != .Windows {
		testing.expect(t, os.symlink("sub", storage.child(dir, "alias")) == nil)
		cfg, issue = resolve(dir, {tasks_root = "alias/new"})
		testing.expect_value(t, issue, "")
		testing.expect_value(t, cfg.tasks, storage.child(sub, "new"))
		testing.expect_value(t, len(cfg.warnings), 1)
		testing.expect(t, os.symlink("..", storage.child(dir, "outside")) == nil)
		_, issue = resolve(dir, {tasks_root = "outside/not-created"})
		testing.expect(t, issue != "")
	}
}
