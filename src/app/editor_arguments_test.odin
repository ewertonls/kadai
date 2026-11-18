#+test
package app

import "core:fmt"
import "core:testing"

@(test)
editor_arguments_preserve_or_reject_empty_and_tab_operands :: proc(t: ^testing.T) {
	for sample in ([]struct {value: string, windows_supported: bool}{
		{"", false}, {"a\tb", false}, {"a b\tc", true},
	}) {
		testing.expect_value(t, windows_editor_argument_supported(sample.value), sample.windows_supported)
		args, issue, alloc_err := editor_arguments(fmt.tprintf("nvim -c '%s'", sample.value))
		if !testing.expect(t, alloc_err == nil) do continue
		when ODIN_OS == .Windows {
			if !sample.windows_supported {
				testing.expect(t, issue != "" && len(args) == 0)
				continue
			}
		}
		if !testing.expect(t, issue == "" && len(args) == 3, issue) do continue
		testing.expect_value(t, args[2], sample.value)
	}
}
