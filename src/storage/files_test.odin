#+test
package storage

import "core:os"
import "core:testing"

@(test)
occupied_destinations_and_unsafe_links :: proc(t: ^testing.T) {
	tmp, err := os.mkdir_temp("", "kadai-path-", context.temp_allocator)
	if !testing.expect(t, err == nil) do return
	defer os.remove_all(tmp)
	path, _ := physical(tmp, .Directory)
	d, e := open_dir(path)
	if !testing.expect(t, e == nil) do return
	defer close_dir(&d)
	testing.expect(t, create_file(&d, "source.md", {1, 2}) == nil)
	testing.expect(t, create_file(&d, "source.md", {3}) != nil)
	testing.expect(t, os.link(child(path, "source.md"), child(path, "other.md")) == nil)
	f, bad := regular(&d, "source.md", mutation = true)
	if f != nil do os.close(f)
	testing.expect(t, bad != nil)
	when ODIN_OS != .Windows {
		testing.expect(t, os.symlink("..", child(path, "redirect")) == nil)
		sub, refused := open_dir(child(path, "redirect/missing"), create = true)
		if refused == nil do close_dir(&sub)
		testing.expect(t, refused != nil)
	}
	data, _ := os.read_entire_file(child(path, "source.md"), context.temp_allocator)
	testing.expect(t, len(data) == 2 && data[0] == 1)
}
