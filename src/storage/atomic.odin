package storage

import "core:fmt"
import "core:os"
import "core:strings"

Change_Kind :: enum {
	Create,
	Replace,
	Delete,
	Move,
	Move_Directory,
}
Change      :: struct {
	kind             : Change_Kind,
	path, destination: string, // Collection-relative. destination is used only by Move.
	expected         : string, // Physical file identity and SHA-256 from the decision read.
	data             : []byte,
	members          : []Tree_Entry, // Directory membership captured by the planner.
}

Step :: struct {
	kind                           : Change_Kind,
	path, destination              : string,
	before, after, backup, restored: string,
}

@(private)
relative_file :: proc(path: string, directory := false) -> bool {
	if path == "" || os.is_absolute_path(path) || strings.has_suffix(path, "/") do return false
	parts := path
	for part in strings.split_iterator(&parts, "/") {
		if !component(part) || part == ".kadai" || part == ".git" do return false
	}
	return directory || strings.has_suffix(path, ".md")
}

@(private)
state :: proc(
	f: ^os.File,
	limit: int,
	version := CURRENT_JOURNAL_VERSION,
) -> (
	value: string,
	err: os.Error,
) {
	info := file_info(f) or_return
	if info.size < 0 || info.size > i64(limit) do return "", .Short_Buffer
	identity := stream_version(f, info, limit) or_return
	attributes := metadata(f, version = version) or_return
	return fmt.tprintf("%s:%s", identity, attributes), nil
}

// "-" denotes verified absence. Every existing input must be a regular,
// single-link file, including recovery images.
@(private)
entry_state :: proc(
	dir: ^Directory,
	name: string,
	limit: int,
	budget: ^i64 = nil,
	version := CURRENT_JOURNAL_VERSION,
) -> (
	value: string,
	err: os.Error,
) {
	f, e := regular(dir, name, mutation = true)
	if e == os.General_Error.Not_Exist do return "-", nil
	if e != nil do return "", e
	defer os.close(f)
	if budget != nil {
		info := file_info(f) or_return
		if info.size < 0 || info.size > budget^ do return "", .Short_Buffer
		budget^ -= info.size
	}
	return state(f, limit, version)
}

@(private)
image_name :: proc(slot: int, suffix: string) -> string {return fmt.tprintf("%d-%s", slot, suffix)}

@(private)
payload_signature :: proc(stamp: string) -> string {
	i := strings.last_index_byte(stamp, '.')
	return stamp[i + 1:]
}

// Persist a new image exclusively. Never reopen a snapshot for writing.
@(private)
save_image :: proc(
	dir: ^Directory,
	name: string,
	data: []byte,
	original: ^os.File,
	limit: int,
	version := CURRENT_JOURNAL_VERSION,
) -> (
	stamp: string,
	err: os.Error,
) {
	if dir.prepared_images != nil {
		_ = append(dir.prepared_images, name) or_return
	}
	created := false
	f, create_err := create_regular(dir, name, &created)
	if create_err != nil {
		if !created && dir.prepared_images != nil do pop(dir.prepared_images)
		return "", create_err
	}
	defer os.close(f)
	n := os.write(f, data) or_return
	if n != len(data) do return "", .Short_Write
	if original != nil do copy_metadata(original, f, version) or_return
	os.sync(f) or_return
	return state(f, limit, version)
}

@(private)
prepare_step :: proc(
	root: string,
	images: ^Directory,
	slot: int,
	c: Change,
	limit: int,
	version := CURRENT_JOURNAL_VERSION,
) -> (
	step: Step,
	err: os.Error,
) {
	if !relative_file(c.path) || c.kind == .Move && !relative_file(c.destination) do return {}, .Invalid_Path
	if len(c.data) > limit do return {}, .Short_Buffer
	step = {
		kind        = c.kind,
		path        = c.path,
		destination = c.destination,
		before      = "-",
		after       = "-",
		backup      = "-",
		restored    = "-",
	}
	path := child(root, c.path)
	dir := open_dir(slash(os.dir(path)), create = c.kind == .Create) or_return
	defer close_dir(&dir)
	name := os.base(path)
	step.before = entry_state(&dir, name, limit, version = version) or_return
	original: ^os.File
	defer if original != nil {os.close(original)}
	if c.kind == .Create {
		if step.before != "-" do return {}, .Exist
	} else {
		if c.expected == "" || !strings.has_prefix(step.before, fmt.tprintf("%s:", c.expected)) do return {}, .Invalid_File
		original = regular(&dir, name, mutation = true) or_return
		// Validate this particular open handle before accepting its bytes or metadata.
		opened := state(original, limit, version) or_return
		if opened != step.before do return {}, .Invalid_File
		bytes := read_bounded(original, limit, context.allocator) or_return
		defer delete(bytes)
		info := file_info(original) or_return
		if file_version(info, bytes) != c.expected do return {}, .Invalid_File
		step.backup = save_image(
			images,
			image_name(slot, "original"),
			bytes,
			original,
			limit,
			version,
		) or_return
		if payload_signature(step.backup) != payload_signature(step.before) do return {}, .Invalid_File
		if c.kind == .Delete || c.kind == .Replace {
			// Rollback consumes its own staged inode. Its pre-recorded identity
			// distinguishes a completed rollback from a later independent edit.
			step.restored = save_image(
				images,
				image_name(slot, "restore"),
				bytes,
				original,
				limit,
				version,
			) or_return
			if payload_signature(step.restored) != payload_signature(step.before) do return {}, .Invalid_File
		}
	}
	if c.kind == .Create || c.kind == .Replace {
		step.after = save_image(
			images,
			image_name(slot, "next"),
			c.data,
			original,
			limit,
			version,
		) or_return
	} else if c.kind == .Move {
		dst_dir := open_dir(slash(os.dir(child(root, c.destination))), create = true) or_return
		close_dir(&dst_dir)
		step.after = step.before
	}
	sync_dir(images) or_return
	return
}

@(private)
apply_step :: proc(
	root: string,
	images: ^Directory,
	slot: int,
	step: Step,
	rollback: bool,
	limit: int,
	verify_only := false,
	budget: ^i64 = nil,
	replay := true,
	live_budget: ^i64 = nil,
	version := CURRENT_JOURNAL_VERSION,
) -> (
	err: os.Error,
) {
	path := child(root, step.path)
	d := open_dir(slash(os.dir(path))) or_return
	defer close_dir(&d)
	name := os.base(path)
	target_dir := file_info(d.file) or_return
	staging_dir := file_info(images.file) or_return
	if target_dir.device != staging_dir.device do return .Unsupported
	if step.before != "-" {
		backup := entry_state(
			images,
			image_name(slot, "original"),
			limit,
			budget,
			version,
		) or_return
		if backup != step.backup do return .Invalid_File
	}
	if step.kind == .Move {
		dst := child(root, step.destination)
		to := open_dir(slash(os.dir(dst))) or_return
		defer close_dir(&to)
		dest_info := file_info(to.file) or_return
		if dest_info.device != target_dir.device do return .Unsupported
		from_dir, to_dir := &d, &to
		old, new_name := name, os.base(dst)
		if rollback {from_dir, to_dir = to_dir, from_dir; old, new_name = new_name, old}
		target := entry_state(to_dir, new_name, limit, live_budget, version) or_return
		source := entry_state(from_dir, old, limit, live_budget, version) or_return
		if replay && source == "-" && target == step.before {
			if verify_only do return
			sync_dir(to_dir) or_return
			return sync_dir(from_dir)
		}
		if source != step.before || target != "-" do return .Invalid_File
		if verify_only do return
		publish(from_dir, old, to_dir, new_name, false) or_return
		sync_dir(to_dir) or_return
		return sync_dir(from_dir)
	}
	from, to, image := step.before, step.after, image_name(slot, "next")
	if rollback {from, to, image = step.after, step.restored, image_name(slot, "restore")}
	current := entry_state(&d, name, limit, live_budget, version) or_return
	if replay && (current == to || rollback && current == step.before) {
		if verify_only do return
		sync_dir(&d) or_return
		return sync_dir(images)
	}
	if current != from do return .Invalid_File
	if to == "-" {
		if verify_only do return
		remove_entry(&d, name) or_return
	} else {
		staged := entry_state(images, image, limit, budget, version) or_return
		if staged != to do return .Invalid_File
		if verify_only do return
		// Re-open the target after reading the staged image, immediately before rename.
		current = entry_state(&d, name, limit, version = version) or_return
		if current != from do return .Invalid_File
		publish(images, image, &d, name, from != "-") or_return
	}
	sync_dir(&d) or_return
	return sync_dir(images)
}
