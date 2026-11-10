package project

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "kadai:document"
import "kadai:storage"
import "kadai:yaml"

Scan_Limits :: struct {
	yaml: yaml.Limits,
	source_bytes, entries, candidates: int,
	total_bytes, total_nodes: i64,
}
DEFAULT_SCAN_LIMITS :: Scan_Limits{yaml.DEFAULT_LIMITS, 16<<20, 250_000, 50_000, 256<<20, 1_000_000}
MAX_SCAN_LIMITS :: Scan_Limits{yaml.MAX_LIMITS, 256<<20, 2_000_000, 500_000, 2<<30, 10_000_000}

valid_scan_limits :: proc(l: Scan_Limits) -> bool {
	m := MAX_SCAN_LIMITS
	return yaml.valid_limits(l.yaml) && 0 < l.source_bytes && l.source_bytes <= m.source_bytes &&
	       0 < l.entries && l.entries <= m.entries && 0 < l.candidates && l.candidates <= m.candidates &&
	       0 < l.total_bytes && l.total_bytes <= m.total_bytes && 0 < l.total_nodes && l.total_nodes <= m.total_nodes
}

Candidate :: struct {
	path: string, // Relative to the physical collection.
	status: document.Decode_Status,
	fields: document.Task_Fields,
	diagnostics: []yaml.Diagnostic,
	info: os.File_Info,
	version: string,
}

Inventory :: struct {
	candidates: [dynamic]Candidate,
	complete: bool,
	problem: string,
	entries, markdown: int,
	bytes, nodes: i64,
}

@(private)
excluded :: proc(cfg: Config, relative: string, dir: bool) -> bool {
	if dir {
		path := storage.child(cfg.tasks, relative)
		name := os.base(relative)
		if name == ".git" || name == ".kadai" || storage.within(cfg.boards, path) do return true
		for reserved in ([]string{".git", ".kadai"}) {
			if strings.equal_fold(name, reserved) {
				other, err := storage.physical(storage.child(storage.slash(os.dir(path)), reserved), .Directory)
				if err == nil && other == path do return true
			}
		}
	}
	for p in cfg.exclude {
		if matches(p, relative, dir) do return true
	}
	return false
}

@(private)
boundary :: proc(cfg: Config, path: string) -> (found: bool, err: os.Error) {
	if path == cfg.project do return
	for marker in ([]string{".git", ".kadai.yaml"}) {
		_, e := os.lstat(storage.child(path, marker), context.temp_allocator)
		if e == nil do return true, nil
		if e != os.General_Error.Not_Exist do return false, e
	}
	return
}

@(private)
same_identity :: proc(a, b: os.File_Info) -> bool {
	return a.type == b.type && a.inode != 0 && a.inode == b.inode && a.device == b.device
}

@(private)
read_candidate :: proc(cfg: Config, inv: ^Inventory, info: os.File_Info, relative: string, limits: Scan_Limits) -> string {
	inv.markdown += 1
	if inv.markdown > limits.candidates do return "markdown_candidates limit exceeded"
	f, err := storage.read_file(storage.child(cfg.tasks, relative))
	if err != nil do return os.error_string(err)
	defer os.close(f)
	now, stat_err := storage.file_info(f)
	if stat_err != nil || !same_identity(info, now) do return "candidate identity changed"
	prefix: [10]byte
	n, read_err := os.read(f, prefix[:])
	if read_err != nil && read_err != .EOF do return os.error_string(read_err)
	if n != int(min(now.size, i64(len(prefix)))) do return "candidate size changed"
	if !document.potential_header(string(prefix[:n])) do return ""
	if now.size > i64(limits.source_bytes) do return "task_source_bytes limit exceeded"
	if _, seek_err := os.seek(f, 0, .Start); seek_err != nil do return os.error_string(seek_err)
	source, e := storage.read_bounded(f, limits.source_bytes, context.allocator)
	if e != nil do return os.error_string(e)
	defer delete(source)
	after, after_err := storage.file_info(f)
	if after_err != nil || after.size != now.size || after.modification_time != now.modification_time {
		return "candidate changed during read"
	}

	// The parser copies scalar values. The inventory retains fields and
	// diagnostics in command scratch storage, never complete Markdown bodies.
	parse_limits := limits.yaml
	bytes_left := limits.total_bytes - inv.bytes
	nodes_left := limits.total_nodes - inv.nodes
	parse_limits.bytes = max(1, int(min(bytes_left, i64(parse_limits.bytes))))
	parse_limits.nodes = max(1, int(min(nodes_left, i64(parse_limits.nodes))))
	doc: document.Task_Document
	{
		context.allocator = context.temp_allocator
		doc = document.decode_task(string(source), cfg.vocabulary, limits.source_bytes, parse_limits, relative)
	}
	header_bytes := doc.parts.header.end - doc.parts.header.start
	if doc.status == .Boundary_Error && doc.boundary_status != .YAML_Document_Too_Large {
		failure: yaml.Parse_Failure
		doc.probe, header_bytes, failure = document.probe_broken_header(string(source), parse_limits)
		switch e in failure {
		case yaml.Error:
			if e == .Too_Many_Nodes || e == .Too_Deep do return fmt.tprintf("YAML limit exceeded: %v", e)
		case runtime.Allocator_Error: return "recognition allocation failed"
		}
	}
	inv.bytes += i64(header_bytes)
	inv.nodes += i64(doc.probe.nodes)
	if inv.bytes > limits.total_bytes || doc.boundary_status == .YAML_Document_Too_Large && bytes_left < i64(limits.yaml.bytes) do return "scan_yaml_bytes limit exceeded"
	if inv.nodes > limits.total_nodes do return "scan_yaml_nodes limit exceeded"
	if doc.status == .Allocation_Error || doc.boundary_status == .YAML_Document_Too_Large ||
	   doc.yaml_error == .Too_Deep || doc.yaml_error == .Too_Many_Nodes {
		return fmt.tprintf("scan incomplete: %v / %v / %v", doc.status, doc.boundary_status, doc.yaml_error)
	}
	if doc.status == .Non_Task do return ""
	if (doc.status == .Boundary_Error || doc.status == .YAML_Error) && !doc.probe.matched do return ""
	if _, add_err := append(&inv.candidates, Candidate{relative, doc.status, doc.fields, doc.diagnostics[:], now, storage.file_version(now, source)}); add_err != nil {
		return "candidate allocation failed"
	}
	return ""
}

@(private)
walk :: proc(cfg: Config, inv: ^Inventory, relative: string, expected: os.File_Info, limits: Scan_Limits) -> string {
	path := cfg.tasks if relative == "" else storage.child(cfg.tasks, relative)
	dir, err := storage.open_dir(path)
	if err != nil do return fmt.tprintf("%s: %s", path, os.error_string(err))
	defer storage.close_dir(&dir)
	f := dir.file
	actual, stat_err := storage.file_info(f)
	if stat_err != nil || actual.type != .Directory || actual.inode == 0 ||
	   (relative != "" || expected.inode != 0) && !same_identity(expected, actual) {
		return fmt.tprintf("%s: directory changed", path)
	}
	skip, boundary_err := boundary(cfg, path)
	if boundary_err != nil do return fmt.tprintf("%s: %s", path, os.error_string(boundary_err))
	if skip do return ""
	entries := make([dynamic]os.File_Info, context.temp_allocator)
	it := os.read_directory_iterator_create(f)
	defer os.read_directory_iterator_destroy(&it)
	for fi in os.read_directory_iterator(&it) {
		if _, e := os.read_directory_iterator_error(&it); e != nil do break
		inv.entries += 1
		if inv.entries > limits.entries do return fmt.tprintf("%s: filesystem_entries limit exceeded", path)
		entry, copy_err := os.file_info_clone(fi, context.temp_allocator)
		if copy_err != nil do return "directory allocation failed"
		if _, append_err := append(&entries, entry); append_err != nil do return "directory allocation failed"
	}
	if bad, e := os.read_directory_iterator_error(&it); e != nil do return fmt.tprintf("%s: %s", bad, os.error_string(e))
	slice.sort_by(entries[:], proc(a, b: os.File_Info) -> bool { return a.name < b.name })
	for fi in entries {
		rel := fi.name if relative == "" else storage.child(relative, fi.name)
		if fi.type == .Symlink || excluded(cfg, rel, fi.type == .Directory) do continue
		if fi.type == .Directory {
			if issue := walk(cfg, inv, rel, fi, limits); issue != "" do return issue
		} else if strings.has_suffix(rel, ".md") && fi.type == .Regular {
			if issue := read_candidate(cfg, inv, fi, rel, limits); issue != "" do return fmt.tprintf("%s: %s", rel, issue)
		}
	}
	return ""
}

scan :: proc(cfg: Config, limits := DEFAULT_SCAN_LIMITS) -> (inv: Inventory) {
	inv.candidates = make([dynamic]Candidate, context.temp_allocator)
	if !valid_scan_limits(limits) { inv.problem = "invalid scan limits"; return }
	info, err := os.lstat(cfg.tasks, context.temp_allocator)
	if err == os.General_Error.Not_Exist { inv.complete = true; return }
	if err != nil || info.type != .Directory {
		inv.problem = fmt.tprintf("cannot scan %s: %s", cfg.tasks, os.error_string(err))
		return
	}
	inv.problem = walk(cfg, &inv, "", info, limits)
	inv.complete = inv.problem == ""
	slice.sort_by(inv.candidates[:], proc(a, b: Candidate) -> bool { return a.path < b.path })
	return
}
