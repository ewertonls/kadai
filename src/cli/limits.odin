#+private
package cli

import "core:fmt"
import "core:strconv"
import "core:strings"
import "kadai:app"

Limit :: enum {
	Task_Source_Bytes, YAML_Document_Bytes, YAML_Nodes_Document, YAML_Depth,
	Filesystem_Entries, Markdown_Candidates, Scan_YAML_Bytes, Scan_YAML_Nodes,
}

@(rodata)
LIMIT_NAMES := [Limit]string{
	.Task_Source_Bytes = "task_source_bytes",
	.YAML_Document_Bytes = "yaml_document_bytes",
	.YAML_Nodes_Document = "yaml_nodes_document",
	.YAML_Depth = "yaml_depth",
	.Filesystem_Entries = "filesystem_entries",
	.Markdown_Candidates = "markdown_candidates",
	.Scan_YAML_Bytes = "scan_yaml_bytes",
	.Scan_YAML_Nodes = "scan_yaml_nodes",
}

limit_values :: proc(l: app.Scan_Limits) -> [Limit]i64 {
	return {
		.Task_Source_Bytes = i64(l.source_bytes),
		.YAML_Document_Bytes = i64(l.yaml.bytes),
		.YAML_Nodes_Document = i64(l.yaml.nodes),
		.YAML_Depth = i64(l.yaml.depth),
		.Filesystem_Entries = i64(l.entries),
		.Markdown_Candidates = i64(l.candidates),
		.Scan_YAML_Bytes = l.total_bytes,
		.Scan_YAML_Nodes = l.total_nodes,
	}
}

// Parse every override before resolving the project or opening any input file.
// Use i64 for scan totals, including the 2 GiB ceiling on 32-bit targets.
parse_limits :: proc(options: []string) -> (app.Scan_Limits, string) {
	values := limit_values(app.DEFAULT_SCAN_LIMITS)
	ceilings := limit_values(app.MAX_SCAN_LIMITS)
	seen: bit_set[Limit]
	for option in options {
		name, _, number := strings.partition(option, "=")
		if name == "" || number == "" || strings.trim_left(number, "0123456789") != "" {
			return {}, fmt.tprintf("invalid --limit %q: expected NAME=positive decimal integer", option)
		}
		matched := false
		for key in Limit {
			if name != LIMIT_NAMES[key] do continue
			if key in seen do return {}, fmt.tprintf("duplicate --limit %s", name)
			value, ok := strconv.parse_i64(number, 10)
			if !ok || value <= 0 || value > ceilings[key] {
				return {}, fmt.tprintf("--limit %s must be between 1 and %d", name, ceilings[key])
			}
			values[key] = value
			seen += {key}
			matched = true
			break
		}
		if !matched do return {}, fmt.tprintf("unknown --limit budget %q", name)
	}
	return {
		yaml = {int(values[.YAML_Document_Bytes]), int(values[.YAML_Nodes_Document]), int(values[.YAML_Depth])},
		source_bytes = int(values[.Task_Source_Bytes]),
		entries = int(values[.Filesystem_Entries]),
		candidates = int(values[.Markdown_Candidates]),
		total_bytes = values[.Scan_YAML_Bytes],
		total_nodes = values[.Scan_YAML_Nodes],
	}, ""
}
