package sonder

import "core:mem"
import "core:sync"
import "core:strings"
import "core:mem/virtual"
import "core:container/xar"

import "base:runtime"

Module :: struct {
	arena: virtual.Arena,
	alloc: mem.Allocator,

	nodes: xar.Array(Node, 5),
}

module_new :: proc() -> (m: ^Module) {
	m, _    = virtual.arena_growing_bootstrap_new(Module, "arena")
	m.alloc = virtual.arena_allocator(&m.arena)
	xar.init(&m.nodes, m.alloc)

	return
}

Type_Kind :: enum {
	Bottom,
	Top,
	Integer,
}

Type :: struct {
	kind:     Type_Kind,
	constant: int,
}

@(rodata)
type_bottom := Type { kind = .Bottom }

@(rodata)
type_top := Type { kind = .Top }

type_integer_constant :: proc(constant: int) -> (t: Type) {
	t.kind     = .Integer
	t.constant = constant
	return
}

type_is_constant :: proc(t: Type) -> (is_constant: bool) {
	switch t.kind {
	case .Integer: is_constant = true
	case .Top:     is_constant = true
	case .Bottom:  is_constant = false
	}
	return
}

Node_Id :: distinct u32

Node_Kind :: enum {
	Start,
	Return,
	Constant,
}

Node_Metadata_Flag :: enum {
	Cfg,
}

Node_Metadata :: struct {
	flags: bit_set[Node_Metadata_Flag],
}

@(rodata)
node_metadata := [Node_Kind]Node_Metadata{
	.Start    = { flags = { .Cfg } },
	.Return   = { flags = { .Cfg } },
	.Constant = {},
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
	id:       Node_Id,
	kind:     Node_Kind,
	inputs:   Node_Edges,
	outputs:  Node_Edges,
	type:     Type,
}

node_new :: proc(m: ^Module, kind: Node_Kind, nodes: ..^Node) -> (result: ^Node) {
	result, _ = xar.push_back_elem_and_get_ptr(&m.nodes, {})

	result.kind = kind
	result.id   = Node_Id(xar.len(m.nodes)-1)
	result.inputs.rest  = make([dynamic]^Node, max(0, len(nodes)-NODE_INLINED_EDGES_COUNT), allocator = m.alloc)
	result.outputs.rest = make([dynamic]^Node, allocator = m.alloc)

	for node in nodes {
		node_edges_push(&result.inputs, node)
		if node != nil {
			node_edges_push(&node.outputs, result)
		}
	}

	return
}

node_start :: proc(m: ^Module) -> (result: ^Node) {
	result = node_new(m, .Start)
	return
}

node_return :: proc(m: ^Module, ctrl: ^Node, data: ^Node) -> (result: ^Node) {
	result = node_new(m, .Return, ctrl, data)
	return
}

node_constant :: proc(m: ^Module, start: ^Node, constant: int) -> (result: ^Node) {
	result = node_new(m, .Constant, start)
	result.type = type_integer_constant(constant)
	return
}

node_is_cfg :: proc(node: ^Node) -> bool {
	return .Cfg in node_metadata[node.kind].flags
}

node_string :: proc(node: ^Node, allocator: mem.Allocator) -> string {
	b: strings.Builder
	strings.builder_init(&b, allocator)

	switch node.kind {
	case .Start:    strings.write_string(&b, "Start")
	case .Return:   strings.write_string(&b, "Return")
	case .Constant:
		strings.write_string(&b, "Constant ")
		strings.write_int(&b, node.type.constant)
	}

	shrink(&b.buf)
	return strings.to_string(b)
}
