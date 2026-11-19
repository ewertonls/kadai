package fixture_runner

import json "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

CORPUS :: "tests/fixtures/v1"

// Inspect every component before reading through it. Fixture paths use '/' on all hosts.
@(private)
check_path :: proc(path: string, leaf_type: os.File_Type) -> os.Error {
	start := 0
	for end in 0 ..= len(path) {
		if end != len(path) && path[end] != '/' {
			continue
		}
		name := path[start:end]
		if name == "" || name == "." || name == ".." || strings.contains_any(name, ":\\\x00") {
			return .Invalid_Path
		}
		info := os.lstat(path[:end], context.temp_allocator) or_return
		expected := leaf_type if end == len(path) else os.File_Type.Directory
		if info.type != expected {
			return .Invalid_Path
		}
		start = end + 1
	}
	return nil
}

read_bytes :: proc(path: string) -> (data: []byte, err: os.Error) {
	check_path(path, .Regular) or_return
	return os.read_entire_file(path, context.temp_allocator)
}

Catalog :: struct {
	fixture_version: int,
	cases          : []struct {
		id, manifest: string,
	},
}

// Only the selected case is opened. Its location must agree with its catalog ID.
case_directory :: proc(id: string) -> (directory: string, problem: string) {
	data, err := read_bytes(CORPUS + "/index.json")
	if err != nil {
		return "", os.error_string(err)
	}
	index: Catalog
	if e := json.unmarshal(data, &index, .JSON, context.temp_allocator); e != nil {
		return "", fmt.tprintf("invalid fixture catalog: %v", e)
	}
	if index.fixture_version != 1 {
		return "", "unsupported catalog version"
	}
	seen := make(map[string]bool, context.temp_allocator)
	for entry in index.cases {
		if entry.id in seen {
			return "", fmt.tprintf("duplicate fixture ID: %s", entry.id)
		}
		seen[entry.id] = true
		if entry.id == id {
			if entry.manifest != fmt.tprintf("cases/%s/manifest.json", id) {
				return "", "manifest path does not match fixture ID"
			}
			directory = fmt.tprintf("%s/cases/%s", CORPUS, id)
		}
	}
	if directory == "" {
		return "", fmt.tprintf("fixture not in catalog: %s", id)
	}
	return directory, ""
}

// Return the temporary directory even on copy failure so the caller can clean it up.
stage_inputs :: proc(source: string) -> (sandbox: string, err: os.Error) {
	sandbox = os.make_directory_temp("", "kadai-fixture-*", context.temp_allocator) or_return
	return sandbox, copy_inputs(source, sandbox)
}

// Link fixtures are constructed by explicit setup actions.
@(private)
copy_inputs :: proc(source, destination: string) -> os.Error {
	check_path(source, .Directory) or_return
	entries := os.read_directory_by_path(source, -1, context.temp_allocator) or_return
	for entry in entries {
		target := fmt.tprintf("%s/%s", destination, entry.name)
		#partial switch entry.type {
		case .Regular:
			os.copy_file(target, entry.fullpath) or_return
		case .Directory:
			os.make_directory(target) or_return
			copy_inputs(fmt.tprintf("%s/%s", source, entry.name), target) or_return
		case:
			return .Invalid_File
		}
	}
	return nil
}
