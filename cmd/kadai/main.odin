package main

import "core:os"
import "kadai:cli"

main :: proc() {
	when ODIN_OS == .Darwin || ODIN_OS == .Linux {
		handle_broken_pipe()
	}
	code := cli.run(os.args[1:], os.to_writer(os.stdout), os.to_writer(os.stderr), os.to_reader(os.stdin))
	if code != 0 {
		os.exit(code)
	}
}
