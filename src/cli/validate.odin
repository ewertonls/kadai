package cli

import "core:fmt"
import "core:strings"
import "kadai:app"

@(private)
validation_text :: proc(r: app.Validation) -> string {
	if len(r.findings) == 0 do return "valid\n"
	b := strings.builder_make(context.temp_allocator)
	for f in r.findings {
		fmt.sbprintf(&b, "%s %s", "warning" if f.severity == .Warning else "error", f.code)
		if f.path != "" do fmt.sbprintf(&b, " %q", f.path)
		if f.location.line > 0 do fmt.sbprintf(&b, ":%d:%d", f.location.line, f.location.column)
		if f.id != "" do fmt.sbprintf(&b, " id=%s", f.id)
		if f.field != "" do fmt.sbprintf(&b, " field=%s", f.field)
		if f.target_id != "" do fmt.sbprintf(&b, " target=%s", f.target_id)
		fmt.sbprintf(&b, "  %s", f.message)
		if len(f.related) > 1 && (f.target_id != "" || f.code == "completed_with_unmet_prerequisites") {
			fmt.sbprintf(&b, " [%d candidates]", len(f.related))
		} else {
			for other in f.related do fmt.sbprintf(&b, " [%s %q]", other.fields.id, other.path)
		}
		for edge in f.edges do fmt.sbprintf(&b, " [%s references %s]", edge.from, edge.to)
		strings.write_byte(&b, '\n')
	}
	fmt.sbprintf(&b, "%d errors, %d warnings\n", r.errors, r.warnings)
	return strings.to_string(b)
}
