package storage

import "core:os"
import "core:time"

// Acquire the shared writer domain before resolving config and scanning.
// Release the collection lock first. Kernel handles release on process exit.
Writer :: struct {
	domain    : Domain_Lock,
	collection: ^os.File,
	root      : string,
}

begin_writer :: proc(timeout := 2 * time.Second) -> (w: Writer, err: os.Error) {
	start := time.tick_now()
	for {
		w.domain, err = try_domain()
		if err != os.General_Error.Timeout || time.tick_since(start) >= timeout do return
		time.sleep(10 * time.Millisecond)
	}
}

end_writer :: proc(w: ^Writer) {
	if w.collection != nil do os.close(w.collection)
	release_domain(&w.domain)
	w^ = {}
}

lock_collection :: proc(w: ^Writer, root: string) -> (err: os.Error) {
	if !domain_held(w.domain) || w.collection != nil || !safe_collection(root) do return .Invalid_Path
	dir := open_dir(child(root, ".kadai"), create = true) or_return
	defer close_dir(&dir)
	f, e := regular(&dir, "writer.lock", mutation = true)
	if e == os.General_Error.Not_Exist {f, e = create_regular(&dir, "writer.lock")}
	if e != nil do return e
	defer if err != nil {os.close(f)}
	lock_file(f) or_return
	w.collection, w.root = f, root
	return
}
