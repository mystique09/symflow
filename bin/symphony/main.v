module main

import os
import symphony.app

fn main() {
	exit_code := app.execute(os.args[1..]) or {
		eprintln(err.msg())
		eprintln(app.usage())
		exit(1)
	}
	if exit_code != 0 {
		exit(exit_code)
	}
}
