package cli

import "core:fmt"
import "core:strings"
import "kadai:app"

@(private)
validation_complete :: proc(r: app.Validation) -> bool {
	return r.scan_complete && r.history_complete && r.recovery_complete
}

@(private)
validation_text :: proc(r: app.Validation) -> string {
	if len(r.findings) == 0 && validation_complete(r) do return "Valid. No issues found.\n"
	b := strings.builder_make(context.temp_allocator)
	for f in r.findings {
		if f.path != "" {
			strings.write_string(&b, terminal_field(f.path))
			if f.location.line > 0 do fmt.sbprintf(&b, ":%d:%d", f.location.line, f.location.column)
			strings.write_string(&b, ": ")
		}
		severity := "warning" if f.severity == .Warning else "error"
		fmt.sbprintf(&b, "%s [%s] %s", severity, f.code, terminal_field(f.message))
		if f.id != "" do fmt.sbprintf(&b, "  task=%s", terminal_field(f.id))
		if f.field != "" do fmt.sbprintf(&b, "  field=%s", terminal_field(f.field))
		if f.target_id != "" do fmt.sbprintf(&b, "  target=%s", terminal_field(f.target_id))
		strings.write_byte(&b, '\n')
		if len(f.related) > 1 &&
		   (f.target_id != "" || f.code == "completed_with_unmet_prerequisites") {
			// The duplicate_id finding already lists each conflicting path.
			fmt.sbprintf(&b, "  %d matching files (see duplicate_id)\n", len(f.related))
		} else {
			for other in f.related do fmt.sbprintf(&b, "  related: %s  (%s)\n", other.fields.id, terminal_field(other.path))
		}
		for edge in f.edges do fmt.sbprintf(&b, "  %s references %s\n", edge.from, edge.to)
	}
	if !r.scan_complete do strings.write_string(&b, "Task scan incomplete.\n")
	if !r.history_complete do strings.write_string(&b, "Used-ID history check incomplete.\n")
	if !r.recovery_complete do strings.write_string(&b, "Recovery check incomplete.\n")
	fmt.sbprintf(
		&b,
		"%d error%s, %d warning%s\n",
		r.errors,
		"" if r.errors == 1 else "s",
		r.warnings,
		"" if r.warnings == 1 else "s",
	)
	return strings.to_string(b)
}
