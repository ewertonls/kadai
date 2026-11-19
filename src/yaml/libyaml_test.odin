#+test
package yaml

import "core:strings"
import "core:testing"
import "core:unicode/utf8"
import oyaml "third_party:odin-yaml"

@(test)
quoted_scalar_source_marks :: proc(t: ^testing.T) {
	prefix :: "# café\r\ntitle: "
	lexeme :: "\"ação\\nCLI\""
	source := prefix + lexeme + " # keep\r\n"

	parser: oyaml.parser
	if !testing.expect(t, oyaml.parser_initialize(&parser) != 0, "LibYAML initialization failed") {
		return
	}
	defer oyaml.parser_delete(&parser)
	oyaml.parser_set_input_string(&parser, raw_data(source), uint(len(source)))

	scalars := 0
	for {
		event: oyaml.event
		if oyaml.parser_parse(&parser, &event) == 0 {
			testing.expect(t, false, string(parser.problem))
			return
		}
		defer oyaml.event_delete(&event)
		if event.type == .STREAM_END_EVENT do break
		if event.type != .SCALAR_EVENT do continue
		scalars += 1
		if scalars == 2 {
			scalar := event.data.scalar
			decoded := strings.string_from_ptr((^u8)(scalar.value), int(scalar.length))
			testing.expect_value(t, scalar.style, .DOUBLE_QUOTED_SCALAR_STYLE)
			testing.expect_value(t, decoded, "ação\nCLI")
			// Both characters of CRLF count toward the index.
			testing.expect_value(
				t,
				event.start_mark.index,
				uint(utf8.rune_count_in_string(prefix)),
			)
			testing.expect_value(
				t,
				event.end_mark.index,
				uint(utf8.rune_count_in_string(prefix + lexeme)),
			)
			testing.expect_value(t, event.start_mark.line, uint(1))
			testing.expect_value(t, event.start_mark.column, uint(7))
		}
	}
	testing.expect_value(t, scalars, 2)
}
