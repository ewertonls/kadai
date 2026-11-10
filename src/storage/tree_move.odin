package storage

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

Tree_Entry :: struct {
	path: string, // Relative to the moved directory. Empty identifies the directory itself.
	directory: bool,
	version, backup: string,
}
Tree :: struct {
	entries: [dynamic]Tree_Entry,
	version, backup, image_digest: string,
}

@(private)
Image_Stamp :: struct {name, stamp: string}

@(private)
image_set_digest :: proc(images: []Image_Stamp) -> string {
	slice.sort_by(images, proc(a,b: Image_Stamp) -> bool { return a.name < b.name })
	b := strings.builder_make(context.temp_allocator)
	for image in images do fmt.sbprintf(&b, "%s %s\n", image.name, image.stamp)
	return digest(transmute([]byte)strings.to_string(b))
}

@(private)
tree_image_name :: proc(relative: string) -> string {
	return fmt.tprintf("original-%s", digest(transmute([]byte)relative))
}

@(private)
Tree_Read :: struct {
	root: string,
	limits: Journal_Limits,
	images: ^Directory,
	capture: bool,
	budget: ^i64,
	device: u64,
}

@(private)
sample_tree :: proc(r: ^Tree_Read, tree: ^Tree, relative: string) -> (err: os.Error) {
	path := r.root if relative == "" else child(r.root, relative)
	dir := open_dir(path) or_return
	defer close_dir(&dir)
	info := file_info(dir.file) or_return
	if relative == "" do r.device = info.device
	if info.device != r.device || info.inode == 0 do return .Unsupported
	sig := directory_metadata(dir.file) or_return
	if len(tree.entries) >= r.limits.entries do return .Short_Buffer
	_ = append(&tree.entries, Tree_Entry{relative, true, fmt.tprintf("%d.%d:%s", info.device, info.inode, sig), "-"}) or_return
	it := os.read_directory_iterator_create(dir.file)
	defer os.read_directory_iterator_destroy(&it)
	for fi in os.read_directory_iterator(&it) {
		if _, e := os.read_directory_iterator_error(&it); e != nil do return e
		name := fi.name
		if !component(name) || name == ".kadai" || name == ".git" || name == ".kadai.yaml" do return .Invalid_Path
		sub := strings.clone(name, context.temp_allocator) if relative == "" else child(relative, name)
		if fi.type == .Directory {
			sample_tree(r, tree, sub) or_return
			continue
		}
		if len(tree.entries) >= r.limits.entries do return .Short_Buffer
		if fi.type != .Regular do return .Invalid_File
		{
			f := regular(&dir, name, mutation = true) or_return
			defer os.close(f)
			actual := file_info(f) or_return
			if actual.device != r.device || actual.inode != fi.inode || actual.size < 0 do return .Invalid_File
			if actual.size > r.budget^ do return .Short_Buffer
			r.budget^ -= actual.size
			version := state(f, r.limits.source) or_return
			backup := "-"
			if r.images != nil {
				key := tree_image_name(sub)
				if r.capture {
					data := read_bounded(f, r.limits.source, context.allocator) or_return
					defer delete(data)
					backup = save_image(r.images, key, data, f, r.limits.source) or_return
				} else {
					backup = entry_state(r.images, key, r.limits.source, r.budget) or_return
				}
				if payload_signature(version) != payload_signature(backup) do return .Invalid_File
			}
			_ = append(&tree.entries, Tree_Entry{sub, false, version, backup}) or_return
		}
	}
	_ = os.read_directory_iterator_error(&it) or_return
	return
}

inspect_tree :: proc(root: string, limits: Journal_Limits, images: ^Directory = nil, capture := false, budget: ^i64 = nil) -> (tree: Tree, err: os.Error) {
	tree.entries = make([dynamic]Tree_Entry, context.temp_allocator)
	remaining := limits.total_bytes
	read := Tree_Read{root, limits, images, capture, budget if budget != nil else &remaining, 0}
	sample_tree(&read, &tree, "") or_return
	slice.sort_by(tree.entries[:], proc(a, b: Tree_Entry) -> bool { return a.path < b.path })
	content, backups := strings.builder_make(context.temp_allocator), strings.builder_make(context.temp_allocator)
	stamps := make([dynamic]Image_Stamp, context.temp_allocator) or_return
	for entry in tree.entries {
		if images != nil && !entry.directory { _ = append(&stamps, Image_Stamp{tree_image_name(entry.path),entry.backup}) or_return }
		fmt.sbprintf(&content, "%d:%s %s\n", len(entry.path), entry.path, entry.version)
		fmt.sbprintf(&backups, "%d:%s %s\n", len(entry.path), entry.path, entry.backup)
	}
	tree.version = digest(transmute([]byte)strings.to_string(content))
	tree.backup = digest(transmute([]byte)strings.to_string(backups))
	if images != nil do tree.image_digest = image_set_digest(stamps[:])
	return
}

@(private)
apply_tree_move :: proc(root: string, images: ^Directory, step: Step, rollback, verify_only, replay: bool, l: Journal_Limits, budget: ^i64, entries: ^int = nil) -> (err: os.Error) {
	src, dst := child(root, step.path), child(root, step.destination)
	if rollback { src, dst = dst, src }
	from := open_dir(slash(os.dir(src))) or_return
	defer close_dir(&from)
	to := open_dir(slash(os.dir(dst))) or_return
	defer close_dir(&to)
	src_volume := file_info(from.file) or_return
	dst_volume := file_info(to.file) or_return
	if src_volume.device != dst_volume.device do return .Unsupported
	_, src_err := os.lstat(src, context.temp_allocator)
	_, dst_err := os.lstat(dst, context.temp_allocator)
	already := replay && src_err == os.General_Error.Not_Exist && dst_err == nil
	if !already && (src_err != nil || dst_err != os.General_Error.Not_Exist) do return .Invalid_File
	live := dst if already else src
	limits := l
	if entries != nil do limits.entries = entries^
	tree, tree_err := inspect_tree(live, limits, images, budget = budget)
	if entries != nil do entries^ -= len(tree.entries)
	if tree_err != nil do return tree_err
	expected := tree.backup
	if len(step.backup) != 64 do expected = fmt.tprintf("%s.%s", tree.backup, tree.image_digest)
	if tree.version != step.before || expected != step.backup do return .Invalid_File
	if verify_only do return
	if !already { publish(&from, os.base(src), &to, os.base(dst), false) or_return }
	sync_dir(&to) or_return
	return sync_dir(&from)
}
