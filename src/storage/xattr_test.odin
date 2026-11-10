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
set_test_security_metadata :: proc(t: ^testing.T, f: ^os.File) {
	value: byte = 42
	fd := p.FD(os.fd(f))
	when ODIN_OS == .Darwin { result := fsetxattr(fd, "user.kadai.test", &value, 1, 0, 0) }
	else { result := fsetxattr(fd, "user.kadai.test", &value, 1, 0) }
	testing.expect_value(t, result, 0)
	when ODIN_OS == .Darwin {
		// An actual extended ACL exercises fcopyfile independently of xattrs.
		state, _, stderr, e := os.process_exec({command = {"/bin/chmod", "+a", "everyone allow readattr", os.name(f)}}, context.temp_allocator)
		testing.expect(t, e == nil && state.exit_code == 0, string(stderr))
	} else {
		// Linux UAPI posix_acl_xattr_header followed by five little-endian entries.
		Entry :: struct #packed {tag, perm: u16le, id: u32le}
		acl := struct #packed {version: u32le, entries: [5]Entry}{
			2, {{1,7,0xffffffff}, {2,4,12345}, {4,4,0xffffffff}, {16,4,0xffffffff}, {32,0,0xffffffff}},
		}
		testing.expect_value(t, fsetxattr(fd, "system.posix_acl_access", &acl, size_of(acl), 0), 0)
	}
}
