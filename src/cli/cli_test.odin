#+test
package cli

import "core:strings"
import "core:testing"
import "kadai:app"

@(test)
dispatch_arguments :: proc(t: ^testing.T) {
	cases := []struct {args: []string, code: int, contains: string}{
		{nil, 0, "--help"},
		{{"--help"}, 0, "--version"},
		{{"-h"}, 0, "--help"},
		{{"--version"}, 0, "kadai " + app.VERSION + "\n"},
		{{"unknown"}, 2, "unknown argument"},
		{{"--unknown"}, 2, "unknown argument"},
		{{"--version=invalid"}, 2, "invalid argument"},
		{{"--help", "extra"}, 2, "unexpected argument"},
		{{"--version", "--help"}, 2, "unexpected argument"},
	}
	for c in cases {
		out, err: strings.Builder
		defer strings.builder_destroy(&out)
		defer strings.builder_destroy(&err)
		code := run(c.args, strings.to_writer(&out), strings.to_writer(&err))
		testing.expect_value(t, code, c.code)
		result, other := strings.to_string(out), strings.to_string(err)
		if c.code != 0 {
			result, other = other, result
		}
		testing.expect(t, strings.contains(result, c.contains), result)
		testing.expect_value(t, other, "")
	}
}

@(test)
stdout_write_failure :: proc(t: ^testing.T) {
	err: strings.Builder
	defer strings.builder_destroy(&err)
	code := run({"--version"}, {}, strings.to_writer(&err))
	testing.expect_value(t, code, 1)
	testing.expect(t, strings.contains(strings.to_string(err), "stdout"))
}
