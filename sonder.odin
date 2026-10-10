package sonder

import "core:fmt"
import "core:mem"
import "core:sync"
import "core:strings"
import "core:mem/virtual"
import "core:container/xar"

import "base:runtime"

Module :: struct {
	arena: virtual.Arena,
	alloc: mem.Allocator,

	string_interner: strings.Intern,

	nodes: xar.Array(Node, 5),
	start: ^Node,

	node_scope_free_list: ^Node_Scope_Node,
}

module_new :: proc() -> (m: ^Module) {
	m, _    = virtual.arena_growing_bootstrap_new(Module, "arena")
	m.alloc = virtual.arena_allocator(&m.arena)
	xar.init(&m.nodes, m.alloc)
	strings.intern_init(&m.string_interner, m.alloc, context.allocator)

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

type_is_constant_integer :: proc(t: Type) -> (is_integer: bool) {
	is_integer   = t.kind == .Integer
	is_integer &&= type_is_constant(t)
	return
}

Node_Id :: distinct u32

Node_Kind :: enum {
	Start,
	Return,
	Constant,
	Scope,

	// Operators
	Add,
	Sub,
	Mul,
	Div,
	Minus,
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
	.Scope    = {},
	.Add 		  = {},
	.Sub 		  = {},
	.Mul 		  = {},
	.Div 		  = {},
	.Minus    = {},
}

NODE_INLINED_EDGES_COUNT :: 4

Node_Edges :: struct {
	len:     int,
	inlined: [NODE_INLINED_EDGES_COUNT]^Node,
	rest:    [dynamic]^Node,
}

node_edges_clear :: proc(edges: ^Node_Edges) {
	edges.len = 0
	clear(&edges.rest)
}

node_edges_push :: proc(edges: ^Node_Edges, node: ^Node) -> (index: int) {
	index = edges.len
	if edges.len < NODE_INLINED_EDGES_COUNT {
		edges.inlined[edges.len] = node
		edges.len += 1
	} else {
		edges.len += append(&edges.rest, node)
	}
	return
}

node_edges_pop :: proc(edges: ^Node_Edges, loc := #caller_location) -> (node: ^Node) {
	assert(0 < edges.len, loc = loc)
	if edges.len <= NODE_INLINED_EDGES_COUNT {
		node = edges.inlined[edges.len - 1]
	} else {
		node = pop(&edges.rest, loc = loc)
	}
	edges.len -= 1
	return
}

node_edges_unordered_remove :: proc(edges: ^Node_Edges, i: int, loc := #caller_location) {
	runtime.bounds_check_error_loc(loc, i, edges.len)
	removed := node_edges_pop(edges)
	if 0 < edges.len && i != edges.len /* Popped last element */ {
		node_edges_set(edges, i, removed)
	}
}

node_edges_set :: proc(edges: ^Node_Edges, i: int, node: ^Node, loc := #caller_location) {
	runtime.bounds_check_error_loc(loc, i, edges.len)
	if i < NODE_INLINED_EDGES_COUNT {
		edges.inlined[i] = node
	} else {
		edges.rest[i - NODE_INLINED_EDGES_COUNT] = node
	}
}

node_edges_get :: proc(edges: Node_Edges, i: int, loc := #caller_location) -> (n: ^Node) {
	runtime.bounds_check_error_loc(loc, i, edges.len)
	if i < NODE_INLINED_EDGES_COUNT {
		n = edges.inlined[i]
	} else {
		n = edges.rest[i - NODE_INLINED_EDGES_COUNT]
	}
	return
}

node_edges_find :: proc(edges: Node_Edges, n: ^Node) -> (index: int) {
	edges := edges

	index = -1
	inlined_slice := edges.inlined[:min(NODE_INLINED_EDGES_COUNT, edges.len)]
	rest_slice    := edges.rest[:max(edges.len - NODE_INLINED_EDGES_COUNT, 0)]

	for inlined, i in inlined_slice {
		if inlined == n {
			index = i
			break
		}
	}

	if index == -1 {
		for rest, i in rest_slice {
			if rest == n {
				index = i + NODE_INLINED_EDGES_COUNT
				break
			}
		}
	}

	return
}

Node_Scope_Node :: struct {
	prev:  ^Node_Scope_Node,
	names: map[string]int,
}

Node :: struct {
	id:       Node_Id,
	kind:     Node_Kind,
	inputs:   Node_Edges,
	outputs:  Node_Edges,
	type:     Type,

	scope:    ^Node_Scope_Node,
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

node_constant_from_type :: proc(m: ^Module, start: ^Node, constant: Type) -> (result: ^Node) {
	result = node_new(m, .Constant, start)
	result.type = constant
	return
}

node_constant_from_int :: proc(m: ^Module, start: ^Node, constant: int) -> (result: ^Node) {
	result = node_constant_from_type(m, start, type_integer_constant(constant))
	return
}

node_constant :: proc{
	node_constant_from_type,
	node_constant_from_int,
}

node_scope :: proc(m: ^Module) -> (result: ^Node) {
	result = node_new(m, .Scope)
	return
}

node_scope_push :: proc(m: ^Module, s: ^Node) {
	scope_node := m.node_scope_free_list
	if scope_node != nil {
		m.node_scope_free_list = scope_node.prev
	} else {
		scope_node, _    = virtual.new(&m.arena, Node_Scope_Node)
		scope_node.names = make(map[string]int, 4, allocator = m.alloc)
	}
	scope_node.prev = s.scope
	s.scope 			  = scope_node
}

node_scope_pop :: proc(m: ^Module, s: ^Node) {
	// Remove old inputs
	node_pop_n(m, s, len(s.scope.names))

	// Reset scope without freeing data (for reuse)
	clear(&s.scope.names)

	// Pop from scope
	old_scope := s.scope
	s.scope = old_scope.prev

	// Push to module free list
	old_scope.prev = m.node_scope_free_list
	m.node_scope_free_list = old_scope
}

node_scope_define :: proc(m: ^Module, s: ^Node, variable: string, node: ^Node) -> (result: ^Node) {
	interned_variable, _ := strings.intern_get(&m.string_interner, variable)
	if interned_variable not_in s.scope.names {
		s.scope.names[interned_variable] = node_add_def(m, s, node)
		result = node
	}
	return
}

node_scope_set :: proc(m: ^Module, s: ^Node, variable: string, node: ^Node) -> (found: bool) {
	interned_variable, _ := strings.intern_get(&m.string_interner, variable)

	for current_scope := s.scope; current_scope != nil; current_scope = current_scope.prev {
		if old_node_index, ok := current_scope.names[interned_variable]; ok {
			node_set_def(m, s, old_node_index, node)
			found = true
			break
		}
	}

	return
}

node_scope_get :: proc(m: ^Module, s: ^Node, variable: string) -> (result: ^Node) {
	interned_variable, _ := strings.intern_get(&m.string_interner, variable)

	for current_scope := s.scope; current_scope != nil; current_scope = current_scope.prev {
		if result_index, ok := current_scope.names[interned_variable]; ok {
			result = node_edges_get(s.inputs, result_index)
			break
		}
	}
	return
}

node_add :: proc(m: ^Module, lhs, rhs: ^Node) -> (result: ^Node) {
	result = node_new(m, .Add, nil, lhs, rhs)
	return
}

node_sub :: proc(m: ^Module, lhs, rhs: ^Node) -> (result: ^Node) {
	result = node_new(m, .Sub, nil, lhs, rhs)
	return
}

node_mul :: proc(m: ^Module, lhs, rhs: ^Node) -> (result: ^Node) {
	result = node_new(m, .Mul, nil, lhs, rhs)
	return
}

node_div :: proc(m: ^Module, lhs, rhs: ^Node) -> (result: ^Node) {
	result = node_new(m, .Div, nil, lhs, rhs)
	return
}

node_minus :: proc(m: ^Module, lhs: ^Node) -> (result: ^Node) {
	result = node_new(m, .Minus, nil, lhs)
	return
}

node_remove_use :: proc(m: ^Module, node: ^Node, use: ^Node) {
	node_edges_unordered_remove(&node.outputs, node_edges_find(node.outputs, use))
}

node_add_def :: proc(m: ^Module, n: ^Node, new_def: ^Node) -> (n_index: int) {
	n_index = node_edges_push(&n.inputs, new_def)
	if new_def != nil {
		node_edges_push(&new_def.outputs, n)
	}
	return
}

node_add_use :: proc(n: ^Node, new_use: ^Node) {
	node_edges_push(&n.outputs, new_use)
}

node_set_def :: proc(m: ^Module, n: ^Node, index: int, new_def: ^Node) -> (flow_node: ^Node) {
	old_def := node_edges_get(n.inputs, index)
	if old_def != new_def {
		if new_def != nil {
			node_add_use(new_def, n)
		}

		if old_def != nil {
			node_remove_use(m, old_def, n)

			if old_def.outputs.len == 0 {
				// has no more uses, get rid of it
				node_kill(m, old_def)
			}
		}

		node_edges_set(&n.inputs, index, new_def)

		flow_node = new_def
	} else {
		flow_node = n
	}

	return
}

node_pop_n :: proc(m: ^Module, n: ^Node, count: int) {
	for i in 0..<count {
		node := node_edges_pop(&n.inputs)
		if node != nil {
			node_remove_use(m, node, n)
			if node.outputs.len == 0 {
				node_kill(m, node)
			}
		}
	}
}

node_kill :: proc(m: ^Module, n: ^Node) {
	assert(n.outputs.len == 0)
	node_pop_n(m, n, n.inputs.len)
	n^ = {}
	// TODO(robin): free list?
}

PEEPHOLE_DISABLE :: #config(SONDER_PEEPHOLE_DISABLE, false)

node_peephole :: proc(m: ^Module, n: ^Node) -> (out: ^Node) {
	out = n

	if PEEPHOLE_DISABLE {
		return
	}

	// compute

	type: Type

	switch n.kind {
	case .Start, .Return, .Scope: // do nothing

	case .Constant: type = n.type
	case .Add, .Sub, .Mul, .Div:
		i1 := node_edges_get(n.inputs, 1)
		i2 := node_edges_get(n.inputs, 2)

		t1 := i1.type if i1 != nil else type_bottom
		t2 := i2.type if i2 != nil else type_bottom

		if type_is_constant_integer(t1) &&
		   type_is_constant_integer(t2)
		{
			c1 := t1.constant
			c2 := t2.constant

			result := 0
			#partial switch n.kind {
			case .Add: result = c1 + c2
			case .Sub: result = c1 - c2
			case .Mul: result = c1 * c2
			case .Div: result = c1 / c2 if c2 != 0 else 0
			}
			type = type_integer_constant(result)
		}
	case .Minus:
		t1 := node_edges_get(n.inputs, 1).type
		if type_is_constant_integer(t1) {
			type = type_integer_constant(-t1.constant)
		}
	}

	// Replace
	if n.kind != .Constant && type_is_constant(type) {
		node_kill(m, n)
		out = node_peephole(m, node_constant(m, m.start, type))
	}

	// Idealize
	// Nothing for now

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
	case .Scope:  strings.write_string(&b, "Scope")
	case .Add:    strings.write_string(&b, "Add")
	case .Sub:    strings.write_string(&b, "Sub")
	case .Mul:    strings.write_string(&b, "Mul")
	case .Div:    strings.write_string(&b, "Div")
	case .Minus:  strings.write_string(&b, "Minus")
	}

	shrink(&b.buf)
	return strings.to_string(b)
}
