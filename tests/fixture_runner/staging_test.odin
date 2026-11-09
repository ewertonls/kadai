#+test
package fixture_runner

import json "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// Read the single document expected by this fixture. Refuse extra setup,
// operations, or assertions until their adapters exist.
scan_document_path :: proc(value: json.Value, id: string) -> (path: string, ok: bool) {
	manifest := value.(json.Object) or_return
	version := manifest["fixture_version"].(i64) or_return
	manifest_id := manifest["id"].(string) or_return
	cwd := manifest["cwd"].(string) or_return
	tier := manifest["tier"].(string) or_return
	description := manifest["description"].(string) or_return
	contracts := manifest["contracts"].(json.Array) or_return
	if len(manifest) != 8 || version != 1 || manifest_id != id || cwd != "project" ||
	   tier != "normal" || description == "" || len(contracts) == 0 {
		return "", false
	}
	seen := make(map[string]bool, context.temp_allocator)
	for contract in contracts {
		name := contract.(string) or_return
		if name in seen || len(name) != 7 || !strings.has_prefix(name, "KAD-") {
			return "", false
		}
		for digit in name[4:] {
			if digit < '0' || digit > '9' { return "", false }
		}
		seen[name] = true
	}

	action := manifest["action"].(json.Object) or_return
	expect := manifest["expect"].(json.Object) or_return
	op := action["op"].(string) or_return
	result := expect["result"].(string) or_return
	no_writes := expect["no_writes"].(bool) or_return
	complete := expect["scan_complete"].(bool) or_return
	documents := expect["documents"].(json.Array) or_return
	if len(action) != 1 || op != "scan" || len(expect) != 4 || result != "ok" ||
	   !no_writes || !complete || len(documents) != 1 {
		return "", false
	}
	doc := documents[0].(json.Object) or_return
	path = doc["path"].(string) or_return
	classification := doc["classification"].(string) or_return
	task_id := doc["id"].(string) or_return
	return path, len(doc) == 3 && path != "" && classification == "valid" && task_id != ""
}

@(test)
prepare_crlf_fixture :: proc(t: ^testing.T) {
	id :: "recognition/crlf-bom"
	directory, problem := case_directory(id)
	if !testing.expect(t, problem == "", problem) { return }
	manifest, read_err := read_bytes(fmt.tprintf("%s/manifest.json", directory))
	if !testing.expect(t, read_err == nil, os.error_string(read_err)) { return }
	parser := json.make_parser(manifest, .JSON, parse_integers=true, allocator=context.temp_allocator)
	value, json_err := json.parse_value(&parser)
	if !testing.expect_value(t, json_err, json.Error.None) { return }
	if !testing.expect(t, parser.curr_token.kind == .EOF && parser.curr_token_err == .EOF, "trailing data in manifest") { return }
	task_file, supported := scan_document_path(value, id)
	if !testing.expect(t, supported, "invalid or unsupported crlf-bom manifest") { return }

	input := fmt.tprintf("%s/input", directory)
	sandbox, copy_err := stage_inputs(input)
	defer if sandbox != "" {
		testing.expect(t, os.remove_all(sandbox) == nil, "failed to remove fixture sandbox")
	}
	if !testing.expect(t, copy_err == nil, os.error_string(copy_err)) { return }

	source := fmt.tprintf("%s/project/%s", input, task_file)
	copy := fmt.tprintf("%s/project/%s", sandbox, task_file)
	original, source_err := read_bytes(source)
	if !testing.expect(t, source_err == nil, os.error_string(source_err)) { return }
	staged, staged_err := os.read_entire_file(copy, context.temp_allocator)
	if !testing.expect(t, staged_err == nil, os.error_string(staged_err)) { return }
	testing.expect(t, strings.has_prefix(string(original), "\uFEFF---\r\n"), "fixture must exercise BOM and CRLF")
	testing.expect(t, string(staged) == string(original), "copy changed fixture bytes")

	source_info, err := os.lstat(source, context.temp_allocator)
	if !testing.expect(t, err == nil, os.error_string(err)) { return }
	copy_info, stat_err := os.lstat(copy, context.temp_allocator)
	if !testing.expect(t, stat_err == nil, os.error_string(stat_err)) { return }
	testing.expect(t, copy_info.type == .Regular && !(source_info.device == copy_info.device && source_info.inode == copy_info.inode), "copy must be an independent regular file")
}
