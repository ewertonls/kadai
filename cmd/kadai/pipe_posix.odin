#+build darwin, linux
package main

import "core:sys/posix"

handle_broken_pipe :: proc() {
	// Surface EPIPE to the writer, including after a committed mutation.
	// A caught signal resets to its default disposition on editor exec.
	posix.signal(.SIGPIPE, proc "c" (_: posix.Signal) {})
}
