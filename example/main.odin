package sonder_example

import "core:os"
import ".."

main :: proc() {
	input := """
	int a = 2;
	if (arg == 2) {
		a = 3 + arg;
	} else {
		a = 4 + arg;
	}
	return a + 3;
	"""
	m := sonder.module_new()

	p: Parser
	p_init(&p, m, input)

	p_parse(&p)
	sonder.dot_print(os.to_stream(os.stdout), p.start)
}
