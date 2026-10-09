package sonder_example

import "core:os"
import ".."

main :: proc() {
	input := "return -(4 + 4) / 0;"
	m := sonder.module_new()

	p: Parser
	p_init(&p, m, input)

	p_parse(&p)
	sonder.dot_print(os.to_stream(os.stdout), p.start)
}
