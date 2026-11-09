package main

import "core:os"
import "kadai:cli"

main :: proc() {
	code := cli.run(os.args[1:], os.to_writer(os.stdout), os.to_writer(os.stderr))
	if code != 0 {
		os.exit(code)
	}
}
