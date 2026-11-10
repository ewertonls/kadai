#+test
#+build darwin, linux
package storage

import "core:os"
import "core:testing"
import p "core:sys/posix"

when ODIN_OS == .Darwin {
	foreign import lib "system:System"
	foreign lib { fsetxattr :: proc(fd: p.FD, name: cstring, value: rawptr, size: uint, pos: u32, options: i32) -> i32 --- }
}

@(private)
test_xattr :: proc(t: ^testing.T, f: ^os.File) {
	value: byte = 42
	fd := p.FD(os.fd(f))
	when ODIN_OS == .Darwin { result := fsetxattr(fd, "user.kadai.test", &value, 1, 0, 0) }
	else { result := fsetxattr(fd, "user.kadai.test", &value, 1, 0) }
	testing.expect_value(t, result, 0)
}
