package sonder

import "base:runtime"
import "core:mem"
import "core:mem/virtual"

Module :: struct {
	arena: virtual.Arena,
	alloc: mem.Allocator,
}

Node_Kind :: enum {
	Start,
	Return,
	Constant,
}

NODE_INLINED_EDGES_COUNT :: 4

Node_Edges :: struct {
	len:     int,
	inlined: [NODE_INLINED_EDGES_COUNT]^Node,
	rest:    [dynamic]^Node,
}

node_edges_push :: proc(edges: ^Node_Edges, node: ^Node) {
	if edges.len < NODE_INLINED_EDGES_COUNT {
		edges.inlined[edges.len] = node
		edges.len += 1
	} else {
		edges.len += append(&edges.rest, node)
	}
}

node_edges_unordered_remove :: proc(edges: ^Node_Edges, i: int, loc := #caller_location) {
	runtime.bounds_check_error_loc(loc, i, edges.len)

	if i < NODE_INLINED_EDGES_COUNT {
		if edges.len < NODE_INLINED_EDGES_COUNT {
			edges.inlined[i] = edges.inlined[edges.len - 1]
		} else {
			edges.inlined[i] = pop(&edges.rest)
		}
	} else {
		unordered_remove(&edges.rest, i)
	}
	edges.len -= 1
}

Node :: struct {
	kind:    Node_Kind,
	inputs:  Node_Edges,
	outputs: Node_Edges,
}

node_new :: proc(m: ^Module, kind: Node_Kind) -> (result: ^Node) {
	result, _ = virtual.new(&m.arena, Node)

	result.inputs.rest  = make([dynamic]^Node, allocator = m.alloc)
	result.outputs.rest = make([dynamic]^Node, allocator = m.alloc)

	return
}
