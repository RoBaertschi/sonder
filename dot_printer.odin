package sonder

import "core:mem/virtual"
import "core:io"

Dot_Printer :: struct {
	output:  io.Writer,
	printed: map[Node_Id]struct{},
}

dot_print :: proc(w: io.Writer, start: ^Node) {
	p := Dot_Printer {
		output = w,
	}

	temp: virtual.Arena
	context.temp_allocator = virtual.arena_allocator(&temp)
	defer virtual.arena_destroy(&temp)

	p.printed = make(map[Node_Id]struct{}, context.temp_allocator)

	io.write_string(p.output, "digraph SoN {\n")
	dot_printer_print_node(&p, start)
	io.write_string(p.output, "}\n")
}

dot_printer_print_node :: proc(p: ^Dot_Printer, n: ^Node) {
	if _, ok := p.printed[n.id]; !ok && n != nil {
		p.printed[n.id] = {}

		name := node_string(n, context.temp_allocator)

		io.write_rune(p.output, '\t')
		io.write_u64(p.output, u64(n.id))
		io.write_string(p.output, " [label=")
		io.write_quoted_string(p.output, name)
		io.write_string(p.output, "];\n")

		for i in 0..<n.outputs.len {
			output: ^Node
			if i < NODE_INLINED_EDGES_COUNT {
				output = n.outputs.inlined[i]
			} else {
				output = n.outputs.rest[i - NODE_INLINED_EDGES_COUNT]
			}

			if output == nil {
				continue
			}

			io.write_rune(p.output, '\t')
			io.write_u64(p.output, u64(n.id))
			io.write_string(p.output, " -> ")
			io.write_u64(p.output, u64(output.id))
			#partial switch output.kind {
			case .Constant: io.write_string(p.output, " [style=dotted]")
			}
			io.write_string(p.output, ";\n")
		}

		for i in 0..<n.outputs.len {
			output: ^Node
			if i < NODE_INLINED_EDGES_COUNT {
				output = n.outputs.inlined[i]
			} else {
				output = n.outputs.rest[i - NODE_INLINED_EDGES_COUNT]
			}

			dot_printer_print_node(p, output)
		}
	}
}
