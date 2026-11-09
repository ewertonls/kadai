#+test
package fixture_runner

import "core:os"
import "core:testing"

@(test)
reject_unsafe_fixture_paths :: proc(t: ^testing.T) {
	paths := []string{"/project", "../project", "tests/../src", "C:/project", "tests\\fixtures", "tests\x00"}
	for path in paths {
		testing.expect_value(t, check_path(path, .Directory), os.Error(os.General_Error.Invalid_Path))
	}
}
