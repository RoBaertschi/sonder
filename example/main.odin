package sonder_example

import "core:os"
import ".."

main :: proc() {
	input := "int test = 1;{ int a = test; int b = 3; test = 4; }return 5 + test;"
	m := sonder.module_new()

	p: Parser
	p_init(&p, m, input)

	p_parse(&p)
	sonder.dot_print(os.to_stream(os.stdout), p.start)
}
