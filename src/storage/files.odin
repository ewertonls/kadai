package storage

import "core:crypto"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:strings"

Directory :: struct {
	path           : string,
	file           : ^os.File,
	// Windows retains ancestor handles without sharing delete access.
	parents        : [dynamic]^os.File,
	// Only a new journal records image names, for cleanup before intent publication.
	prepared_images: ^[dynamic]string,
}

close_dir :: proc(d: ^Directory) {
	if d.file != nil do os.close(d.file)
	#reverse for f in d.parents do os.close(f)
	delete(d.parents)
	d^ = {}
}

component :: proc(name: string) -> bool {
	if !valid_path_text(name) || name == "." || name == ".." || strings.contains(name, "/") do return false
	when ODIN_OS == .Windows {
		if strings.contains_any(name, "\\:*?\"<>|") ||
		   os.is_reserved_name(name) ||
		   os.is_reserved_name(strings.split_n(name, ".", 2, context.temp_allocator)[0]) ||
		   strings.has_suffix(name, ".") ||
		   strings.has_suffix(name, " ") {return false}
	}
	return true
}

read_file :: proc(path: string, mutation := false) -> (f: ^os.File, err: os.Error) {
	d := open_dir(slash(os.dir(path))) or_return
	defer close_dir(&d)
	return regular(&d, os.base(path), mutation)
}

@(private)
STAGE_PREFIX :: ".kadai-stage-"

random_name :: proc(prefix: string) -> string {
	raw: [16]byte
	crypto.rand_bytes(raw[:])
	encoded := hex.encode(raw[:], context.temp_allocator)
	return fmt.tprintf("%s%s", prefix, string(encoded[:]))
}

write_sync :: proc(f: ^os.File, data: []byte) -> (err: os.Error) {
	n := os.write(f, data) or_return
	if n != len(data) do return .Short_Write
	return os.sync(f)
}

@(private)
checked_project_source :: proc(
	d: ^Directory,
	name, expected: string,
	limit: int,
) -> (
	f: ^os.File,
	err: os.Error,
) {
	source := regular(d, name, writable = true) or_return
	defer if err != nil {os.close(source)}
	info := file_info(source) or_return
	version := stream_version(source, info, limit) or_return
	if version != expected do return nil, .Invalid_File
	return source, nil
}

// A project directory can have an inheritable ACL. Apply the source's
// verified permissions to the empty stage before it holds any user data.
@(private)
stage_project_replacement :: proc(
	d: ^Directory,
	name, expected: string,
	staged: ^os.File,
	data: []byte,
	limit: int,
) -> (
	err: os.Error,
) {
	{
		src := checked_project_source(d, name, expected, limit) or_return
		defer os.close(src)
		copy_project_metadata(src, staged) or_return
	}
	write_sync(staged, data) or_return
	current := checked_project_source(d, name, expected, limit) or_return
	defer os.close(current)
	original := project_metadata(current) or_return
	copied := project_metadata(staged) or_return
	if original != copied do return .Invalid_File
	return
}

// The writer domain covers planning and publication. A short write or sync
// failure during staging leaves an existing project file untouched.
write_project_file :: proc(
	d: ^Directory,
	name, expected: string,
	data: []byte,
	limit: int,
	started: ^bool = nil,
) -> (
	err: os.Error,
) {
	if len(data) > limit do return .Short_Buffer
	return publish_file(d, name, data, expected, limit, expected == "", started)
}

// Publish a complete file without replacing any destination entry.
create_file :: proc(
	d: ^Directory,
	name: string,
	data: []byte,
	published: ^bool = nil,
) -> (
	err: os.Error,
) {
	return publish_file(d, name, data, "", len(data), false, published)
}

@(private)
publish_file :: proc(
	d: ^Directory,
	name: string,
	data: []byte,
	expected: string,
	limit: int,
	inherit_permissions: bool,
	published: ^bool,
) -> (
	err: os.Error,
) {
	if !component(name) do return .Invalid_Path
	tmp := random_name(STAGE_PREFIX)
	created := false
	f, open_err := create_regular(d, tmp, &created, project_file = inherit_permissions)
	defer if created {remove_entry(d, tmp)}
	if open_err != nil do return open_err
	if expected == "" {
		err = write_sync(f, data)
	} else {
		err = stage_project_replacement(d, name, expected, f, data, limit)
	}
	close_err := os.close(f)
	if err != nil do return err
	if close_err != nil do return close_err
	publish(d, tmp, d, name, expected != "") or_return
	created = false // The stage name is vacant after the rename.
	if published != nil do published^ = true
	return sync_dir(d)
}
