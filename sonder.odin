package sonder

import "core:mem"
import "core:slice"
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
	Ctrl,
	XCtrl, // ~Ctrl

	Simple_End = XCtrl,

	Integer_Constant,
	Integer,          // constant == 0 = top, constant == 1 = bottom
	Tuple,
}

Type :: struct {
	kind:     Type_Kind,
	constant: int,
	tuple:    []Type,
}

@(rodata)
type_bottom := Type { kind = .Bottom }

@(rodata)
type_top := Type { kind = .Top }

@(rodata)
type_ctrl := Type { kind = .Ctrl }

@(rodata)
type_xctrl := Type { kind = .XCtrl }

@(rodata)
type_integer_bottom := Type { kind = .Integer, constant = 1 }

@(rodata)
type_integer_top := Type { kind = .Integer, constant = 0 }

@(rodata)
type_tuple_if_both := Type { kind = .Tuple, tuple = { { kind = .Ctrl }, { kind = .Ctrl } } }

@(rodata)
type_tuple_if_neither := Type { kind = .Tuple, tuple = { { kind = .XCtrl }, { kind = .XCtrl } } }

@(rodata)
type_tuple_if_true := Type { kind = .Tuple, tuple = { { kind = .Ctrl }, { kind = .XCtrl } } }

@(rodata)
type_tuple_if_false := Type { kind = .Tuple, tuple = { { kind = .XCtrl }, { kind = .Ctrl } } }


TYPE_INTEGERS :: bit_set[Type_Kind]{.Integer_Constant, .Integer}

type_integer_constant :: proc(constant: int) -> (t: Type) {
	t.kind     = .Integer_Constant
	t.constant = constant
	return
}

type_tuple_from_slice :: proc(types: []Type) -> (t: Type) {
	t.kind  = .Tuple
	t.tuple = types
	return
}

type_tuple_from_module :: proc(m: ^Module, types: ..Type) -> (t: Type) {
	t = type_tuple_from_slice(slice.clone(types, allocator = m.alloc))
	return
}

type_is_simple :: proc(t: Type) -> (is_simple: bool) {
	is_simple = t.kind <= .Simple_End
	return
}

type_is_constant :: proc(t: Type) -> (is_constant: bool) {
	switch t.kind {
	case .Top, .XCtrl, .Integer_Constant: is_constant = true

	case .Integer, .Bottom,
			   .Ctrl,    .Tuple:  is_constant = false
	}
	return
}

type_is_integer :: proc(t: Type) -> bool {
	return t.kind in TYPE_INTEGERS
}

type_is_integer_bottom :: proc(t: Type) -> bool {
	return t.kind == .Integer && t.constant == type_integer_bottom.constant
}

type_is_integer_top :: proc(t: Type) -> bool {
	return t.kind == .Integer && t.constant == type_integer_top.constant
}

type_meet :: proc(lhs, rhs: Type) -> (result: Type) {
// 	Pattern_Result_Use :: enum {
// 		A,
// 		B,
// 		Result,
// 		Fail,
// 	}
//
// 	Pattern_Operator :: enum {
// 		And,
// 		Or,
// 	}
//
// 	Type_Kinds :: bit_set[Type_Kind]
//
// 	Pattern :: struct {
// 		a:      bit_set[Type_Kind],
// 		b:      bit_set[Type_Kind],
// 		result: Type,
// 		use:    Pattern_Result_Use,
// 		swap:   bool,
// 		op:     Pattern_Operator,
// 	}
//
// 	int_like := Type_Kinds{.Integer_Constant, .Integer}
// 	bot := Type_Kinds { .Bottom }
// 	top := Type_Kinds { .Top }
// 	ctrl := Type_Kinds { .Ctrl }
// 	xctrl := Type_Kinds { .XCtrl }
//
// 	patterns := []Pattern{
// 		// Tuple
// 		{ a = { .Tuple }, b = { .Tuple }, use = .Fail, op = .Or },
//
// 		// Integer
// 		{ a = int_like }
//
// 		// General
// 		{ a = bot, b = top, use = .A, swap = true },
// 		{ a = ctrl, b = ctrl, result = type_ctrl, use = .Result, op = .Or },
// 		{ a = xctrl, b = xctrl, result = type_xctrl, use = .Result, op = .Or },
// 	}

	lhs := lhs
	rhs := rhs

	match_or :: proc(lhs, rhs: Type, lhs_kind, rhs_kind: Type_Kind) -> (matched: bool) {
		matched = lhs.kind == lhs_kind || rhs.kind == rhs_kind
		return
	}

	if !type_is_simple(rhs) && type_is_simple(lhs) {
		// Swap the simple side to the right side
		lhs, rhs = rhs, lhs
	}

	if type_is_simple(lhs) {
		if match_or(lhs, rhs, .Top, .Bottom) {
				result = lhs
			} else if match_or(lhs, rhs, .Bottom, .Top) {
				result = rhs
			} else if type_is_simple(rhs) {
				result = match_or(lhs, rhs, .Ctrl, .Ctrl) ? type_ctrl : type_xctrl
			}
	} else {
		switch lhs.kind {
		case .Tuple: unimplemented()
		case .Integer, .Integer_Constant:
			if type_is_integer(rhs) {
				if type_is_integer_bottom(lhs) || type_is_integer_bottom(rhs) {
					result = type_integer_bottom
				} else if type_is_integer_top(lhs) {
					result = rhs
				} else if type_is_integer_top(rhs) {
					result = lhs
				} else {
					assert(lhs.kind == .Integer_Constant && rhs.kind == .Integer_Constant)
					result = lhs if lhs.constant == rhs.constant else type_bottom
				}
				break
			}
			fallthrough
		case .XCtrl, .Ctrl, .Bottom, .Top: result = type_bottom
		}
	}

	return
}

type_is_constant_integer :: proc(t: Type) -> (is_integer: bool) {
	is_integer   = t.kind == .Integer_Constant
	is_integer &&= type_is_constant(t)
	return
}

Node_Id :: distinct u32

Node_Kind :: enum {
	Start,
	Return,
	Constant,
	Scope,
	Proj,
	If,
	Phi,
	Region,
	Stop,

	// Operators
	Add,
	Sub,
	Mul,
	Div,
	Bool_EQ,
	Bool_LT,
	Bool_LE,
	Not,
	Minus,
}

NODE_BOOL :: bit_set[Node_Kind]{.Bool_EQ, .Bool_LT, .Bool_LE}

Node_Metadata_Flag :: enum {
	Cfg,
	MultiNode,
}

Node_Metadata :: struct {
	flags: bit_set[Node_Metadata_Flag],
}

@(rodata)
node_metadata := #partial [Node_Kind]Node_Metadata{
	.Start    = { flags = { .Cfg, .MultiNode } },
	.Return   = { flags = { .Cfg             } },
	.If       = { flags = { .Cfg, .MultiNode } },
	.Region   = { flags = { .Cfg             } },
	.Stop     = { flags = { .Cfg             } },
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

	proj:     int,
	scope:    ^Node_Scope_Node,
}

node_new_cap :: proc(m: ^Module, kind: Node_Kind, input_cap: int) -> (result: ^Node) {
	result, _ = xar.push_back_elem_and_get_ptr(&m.nodes, {})

	result.kind = kind
	result.id   = Node_Id(xar.len(m.nodes)-1)
	result.inputs.rest  = make([dynamic]^Node, max(0, input_cap-NODE_INLINED_EDGES_COUNT), allocator = m.alloc)
	result.outputs.rest = make([dynamic]^Node, allocator = m.alloc)

	return
}

node_new :: proc(m: ^Module, kind: Node_Kind, nodes: ..^Node) -> (result: ^Node) {
	result = node_new_cap(m, kind, len(nodes))

	for node in nodes {
		node_edges_push(&result.inputs, node)
		if node != nil {
			node_add_use(node, result)
		}
	}

	return
}

node_start :: proc(m: ^Module, arg := Type{}) -> (result: ^Node) {
	result = node_new(m, .Start)
	result.type = type_tuple_from_module(m, type_ctrl, arg)
	return
}

node_return :: proc(m: ^Module, ctrl: ^Node, data: ^Node) -> (result: ^Node) {
	result = node_new(m, .Return, ctrl, data)
	return
}

node_proj :: proc(m: ^Module, ctrl: ^Node, index: int) -> (result: ^Node) {
	assert(.MultiNode in node_metadata[ctrl.kind].flags)
	result = node_new(m, .Proj, ctrl)
	result.proj = index
	return
}

node_if :: proc(m: ^Module, ctrl, pred: ^Node) -> (result: ^Node) {
	result = node_new(m, .If, ctrl, pred)
	return
}

node_phi :: proc(m: ^Module, region: ^Node, inputs: ..^Node) -> (result: ^Node) {
	result = node_new_cap(m, .Phi, len(inputs) + 1)

	node_edges_push(&result.inputs, region)
	if region != nil {
		node_add_use(region, result)
	}

	for node in inputs {
		node_edges_push(&result.inputs, node)
		if node != nil {
			node_add_use(node, result)
		}
	}

	return
}

node_region :: proc(m: ^Module, nodes: ..^Node) -> (result: ^Node) {
	result = node_new(m, .Region, ..nodes)
	return
}

node_stop :: proc(m: ^Module, nodes: ..^Node) -> (result: ^Node) {
	result = node_new(m, .Stop, ..nodes)
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

node_not :: proc(m: ^Module, lhs: ^Node) -> (result: ^Node) {
	result = node_new(m, .Not, nil, lhs)
	return
}

node_minus :: proc(m: ^Module, lhs: ^Node) -> (result: ^Node) {
	result = node_new(m, .Minus, nil, lhs)
	return
}

node_bool_eq :: proc(m: ^Module, lhs, rhs: ^Node) -> (result: ^Node) {
	result = node_new(m, .Bool_EQ, nil, lhs, rhs)
	return
}

node_bool_lt :: proc(m: ^Module, lhs, rhs: ^Node) -> (result: ^Node) {
	result = node_new(m, .Bool_LT, nil, lhs, rhs)
	return
}

node_bool_le :: proc(m: ^Module, lhs, rhs: ^Node) -> (result: ^Node) {
	result = node_new(m, .Bool_LE, nil, lhs, rhs)
	return
}

// Scope

NODE_SCOPE_CTRL :: "$ctrl"
NODE_SCOPE_ARG  :: "arg"

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

// Remember to push a new scope after this
node_scope_dup :: proc(m: ^Module, scope: ^Node) -> (dup_scope: ^Node) {
	dup_scope = node_scope(m)
	dup_scope.scope = scope.scope
	for i in 0..<scope.inputs.len {
		node_add_def(m, dup_scope, node_input(scope, i))
	}
	return
}

node_scope_merge :: proc(m: ^Module, into, from: ^Node) -> (r: ^Node) {
	assert(node_len_inputs(into) == node_len_inputs(from))
	assert(into.scope == from.scope)
	r = node_keep(node_region(m, nil, node_input(into, 0), node_input(from, 0)))
	defer node_kill(m, from) // dies

	// Skip the ctrl node
	for i in 1..<node_len_inputs(into) {
		a_node, b_node := node_input(into, i), node_input(from, i)
		if a_node != b_node {
			node_set_def(m, into, i, node_peephole(m, node_phi(m, r, a_node, b_node)))
		}
	}

	node_unkeep(r)
	r = node_peephole(m, r)
	return
}

// Stop
node_stop_ret :: proc(node: ^Node) -> (ret: ^Node) {
	if node.inputs.len == 1 {
		ret = node_input(node, 0)
	}
	return
}

node_stop_add_return :: proc(m: ^Module, node: ^Node, ret: ^Node) {
	node_add_def(m, node, ret)
}

// Helpers

node_all_inputs_constant :: proc(node: ^Node, start := 1) -> (all_constants: bool) {
	all_constants = true

	for i in start..<node.inputs.len {
		input := node_input(node, i)
		if input == nil || !type_is_constant(input.type) {
			all_constants = false
			break
		}
	}
	return
}

node_input :: proc(node: ^Node, index: int) -> (input: ^Node) {
	input = node_edges_get(node.inputs, index)
	return
}

node_len_inputs :: proc(node: ^Node) -> (len: int) {
	len = node.inputs.len
	return
}

node_output :: proc(node: ^Node, index: int) -> (output: ^Node) {
	output = node_edges_get(node.outputs, index)
	return
}

node_len_outputs :: proc(node: ^Node) -> (len: int) {
	len = node.outputs.len
	return
}

node_remove_use :: proc(node: ^Node, use: ^Node) {
	node_edges_unordered_remove(&node.outputs, node_edges_find(node.outputs, use))
}

node_remove_def :: proc(m: ^Module, node: ^Node, index: int) {
	old_def := node_input(node, index)
	if old_def != nil {
		node_remove_use(old_def, node)
		if node_len_outputs(old_def) == 0 {
			node_kill(m, old_def)
		}
	}
	node_edges_unordered_remove(&node.inputs, index)
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
			node_remove_use(old_def, n)

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
			node_remove_use(node, n)
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

node_copy :: proc(m: ^Module, kind: Node_Kind, lhs, rhs: ^Node) -> (copy: ^Node) {
	LUT := #partial [Node_Kind](#type proc(m: ^Module, lhs, rhs: ^Node) -> ^Node){
		.Add     = node_add,
		.Sub     = node_sub,
		.Mul     = node_mul,
		.Div     = node_div,
		.Bool_EQ = node_bool_eq,
		.Bool_LT = node_bool_lt,
		.Bool_LE = node_bool_le,
	}

	copy = LUT[kind](m, lhs, rhs)

	return
}

node_keep :: proc(node: ^Node) -> ^Node {
	node_add_use(node, nil)
	return node
}
node_unkeep :: proc(node: ^Node) {
	node_remove_use(node, nil)
}

PEEPHOLE_DISABLE :: #config(SONDER_PEEPHOLE_DISABLE, false)

node_peephole :: proc(m: ^Module, n: ^Node) -> (out: ^Node) {
	out = n

	if PEEPHOLE_DISABLE {
		return
	}

	dead_code_elimination :: proc(m: ^Module, node, replace_with: ^Node) -> ^Node {
		if node != replace_with && node.outputs.len == 0 {
			node_keep(replace_with)
			defer node_unkeep(replace_with)

			node_kill(m, node)
		}
		return replace_with
	}

	// compute

	compute :: proc(m: ^Module, n: ^Node) -> (type: Type) {
		switch n.kind {
		case .Scope, .Phi, .Stop: // do nothing
		case .Return:
			type = type_tuple_from_module(m, node_edges_get(n.inputs, 0).type, node_edges_get(n.inputs, 1).type)
		case .Start:
			assert(n.type.kind == .Tuple)
			type = n.type
		case .Proj:
			t := node_edges_get(n.inputs, 0).type
			if t.kind == .Tuple {
				type = t.tuple[n.proj]
			}
		case .If: type = type_tuple_if
		case .Region: type = type_ctrl
		case .Constant: type = n.type
		case .Add, .Sub, .Mul, .Div, .Bool_EQ, .Bool_LT, .Bool_LE:
			i1 := node_edges_get(n.inputs, 1)
			i2 := node_edges_get(n.inputs, 2)

			if n.kind == .Sub && i1 == i2 {
				type = type_integer_constant(0)
				break
			}

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

				case .Bool_EQ: result = int(c1 == c2)
				case .Bool_LT: result = int(c1 <  c2)
				case .Bool_LE: result = int(c1 <= c2)
				}
				type = type_integer_constant(result)
			} else {
				type = type_meet(t1, t2)
			}
		case .Not:
			t1 := node_edges_get(n.inputs, 1).type
			if type_is_integer(t1) {
				if type_is_constant(t1) {
					type = type_integer_constant(t1.constant == 0 ? 1 : 0)
				} else {
					type = t1
				}
			}
		case .Minus:
			t1 := node_edges_get(n.inputs, 1).type
			if type_is_constant_integer(t1) {
				type = type_integer_constant(-t1.constant)
			}
		}
		return
	}

	type := compute(m, n)

	// Replace
	if n.kind != .Constant && type_is_constant(type) {
		node_kill(m, n)
		out = dead_code_elimination(m, n, node_peephole(m, node_constant(m, m.start, type)))
	} else {
			// Idealize
			idealize_node: ^Node

			swap12 :: proc(n: ^Node) -> ^Node {
				lhs, rhs := node_edges_get(n.inputs, 1), node_edges_get(n.inputs, 2)
				node_edges_set(&n.inputs, 2, lhs)
				node_edges_set(&n.inputs, 1, rhs)

				return n
			}

			#partial switch n.kind {
			case .Add:
				lhs := node_edges_get(n.inputs, 1)
				rhs := node_edges_get(n.inputs, 2)
				t1, t2 := lhs.type, rhs.type

				// should be handled by compute
				assert(!(type_is_constant(t1) && type_is_constant(t2)))

				spline_cmp :: proc(hi, lo: ^Node) -> (swap: bool) {
					if type_is_constant(lo.type) {
						swap = false
					} else if type_is_constant(hi.type) {
						swap = true
					} else if lo.kind == .Phi && node_all_inputs_constant(lo) {
						swap = false
					} else if hi.kind == .Phi && node_all_inputs_constant(hi) {
						swap = true
					} else if lo.kind == .Phi && hi.kind != .Phi {
						swap = true
					} else if hi.kind == .Phi && lo.kind != .Phi {
						swap = false
					} else {
						swap = lo.id > hi.id
					}
					return
				}

				if type_is_constant_integer(t2) && t2.constant == 0 { // Add with 0
					idealize_node = lhs
				} else if lhs == rhs { // Add by itself
					idealize_node = node_mul(m, lhs, node_peephole(m, node_constant(m, m.start, 2)))
				} else if lhs.kind != .Add && rhs.kind == .Add { // Move non-add to rhs
					idealize_node = swap12(n)
				} else if rhs.kind == .Add { // rotate x + (y + z) -> (x + y) + z
					idealize_node = node_add(m, node_peephole(m, node_add(m, lhs, node_input(rhs, 1))), node_input(rhs, 2))
				} else if lhs.kind != .Add {
					if spline_cmp(lhs, rhs) {
						idealize_node = swap12(n)
					}
				} else if type_is_constant(node_input(lhs, 2).type) && type_is_constant(t2) { // (x + constant1) + constant2 -> x + (constant1 + constant2)
					idealize_node = node_add(m, node_input(lhs, 1), node_peephole(m, node_add(m, node_input(lhs, 2), rhs)))
				} else if phi := node_input(lhs, 2); // Holy moly, ((x + (phi cons)) + con), ((x + (phi cons)) + (phi cons)) -> x + (phi con0+con0 ...)
				          phi.kind == .Phi &&
	 	           node_all_inputs_constant(phi) &&
														(type_is_constant(t2) ||
															(rhs.kind == .Phi &&
															 node_input(phi, 0) == node_input(rhs, 0) &&
															 node_all_inputs_constant(rhs)))
				{
					runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
					nodes   := make([]^Node, node_len_inputs(phi), allocator = context.temp_allocator)
					nodes[0] = node_input(phi, 0)

					if type_is_constant(t2) {
						for i in 1..<len(nodes) {
						 nodes[i] = node_peephole(m, node_add(m, node_input(phi, i), rhs))
						}
					} else {
						for i in 1..<len(nodes) {
						 nodes[i] = node_peephole(m, node_add(m, node_input(phi, i), node_input(rhs, i)))
						}
					}

					rhs_phi      := node_peephole(m, node_phi(m, nodes[0], ..nodes[1:]))
					idealize_node = node_add(m, node_input(lhs, 1), rhs_phi)
				} else if spline_cmp(node_input(lhs, 2), rhs) { // (x + y) + z -> (x + z) + y
					idealize_node = node_add(m, node_peephole(m, node_add(m, node_input(lhs, 1), rhs)), node_input(lhs, 2))
				}

			case .Div:
				lhs := node_edges_get(n.inputs, 1)
				rhs := node_edges_get(n.inputs, 2)
				t1, t2 := lhs.type, rhs.type

				if type_is_constant_integer(t2) && t2.constant == 1 {
					idealize_node = lhs
				}
			case .Mul:
				lhs := node_edges_get(n.inputs, 1)
				rhs := node_edges_get(n.inputs, 2)
				t1, t2 := lhs.type, rhs.type

				if type_is_constant_integer(t2) && t2.constant == 1 {
					idealize_node = lhs
				} else if type_is_constant(t1) && !type_is_constant(t2) {
					idealize_node = swap12(n)
				}

			case .Bool_EQ, .Bool_LT, .Bool_LE:
				lhs := node_edges_get(n.inputs, 1)
				rhs := node_edges_get(n.inputs, 2)
				if lhs == rhs {
					result: bool
					#partial switch n.kind {
					case .Bool_EQ: result = true
					case .Bool_LT: result = false
					case .Bool_LE: result = true
					}
					idealize_node = node_constant(m, m.start, int(result))
				}
			case .Phi:
				same_op :: proc(node: ^Node) -> (same: bool) {
					same = true
					first_kind := node_input(node, 1).kind
					for i in 2..<node_len_inputs(node) {
						if first_kind != node_input(node, i).kind {
							same = false
							break
						}
					}
					return
				}

				same_inputs :: proc(node: ^Node) -> (same: bool) {
					same = true
					first_node := node_input(node, 1)
					for i in 2..<node_len_inputs(node) {
						if first_node != node_input(node, i) {
							same = false
							break
						}
					}
					return
				}

				if same_inputs(n) {
					idealize_node = node_input(n, 1)
				} else {
					op := node_input(n, 1)
					if node_len_inputs(n) == 3 &&
					   node_input(n, 0) == nil &&
								!node_is_cfg(op) &&
								same_op(n)
					{
						runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
						lhss := make([]^Node, node_len_inputs(n), allocator = context.temp_allocator)
						rhss := make([]^Node, node_len_inputs(n), allocator = context.temp_allocator)
						lhss[0] = node_input(n, 0)
						rhss[0] = node_input(n, 0)
						for i in 1..<node_len_inputs(n) {
							lhss[i] = node_input(node_input(n, i), 1)
							rhss[i] = node_input(node_input(n, i), 2)
						}
						phi_lhs := node_phi(m, lhss[0], ..lhss[1:])
						phi_rhs := node_phi(m, lhss[0], ..lhss[1:])
						idealize_node = node_copy(m, op.kind, phi_lhs, phi_rhs)
					}
				}
			case .Return:
				if node_input(n, 0).type.kind == .XCtrl {
					idealize_node = node_input(n, 0)
				}
			case .Stop:
				current_len := node_len_inputs(n)
				for i := 0; i < node_len_inputs(n); i += 1 {
					if node_input(n, i).type.kind == .XCtrl {
						node_remove_def(n, i)
						i -= 1
					}
				}
				if node_len_inputs(n) != current_len {
					idealize_node = n
				}
			}

			if idealize_node != nil {
				out = dead_code_elimination(m, n, node_peephole(m, idealize_node))
			}
	}

	return
}

node_is_cfg :: proc(node: ^Node) -> bool {
	if node.kind == .Proj {
		return node.proj == 0 || node_input(node, 0).kind == .If
	}
	return .Cfg in node_metadata[node.kind].flags
}

node_string :: proc(node: ^Node, allocator: mem.Allocator) -> string {
	b: strings.Builder
	strings.builder_init(&b, allocator)

	switch node.kind {
	case .Start:    strings.write_string(&b, "Start")
	case .Return:   strings.write_string(&b, "Return")
	case .Proj:
		strings.write_string(&b, "Proj ")
		strings.write_int(&b, node.proj)
	case .If:     strings.write_string(&b, "If")
	case .Phi:    strings.write_string(&b, "Phi")
	case .Region: strings.write_string(&b, "Region")
	case .Stop:   strings.write_string(&b, "Stop")
	case .Constant:
		strings.write_string(&b, "Constant ")
		strings.write_int(&b, node.type.constant)
	case .Scope:   strings.write_string(&b, "Scope")
	case .Add:     strings.write_string(&b, "Add")
	case .Sub:     strings.write_string(&b, "Sub")
	case .Mul:     strings.write_string(&b, "Mul")
	case .Div:     strings.write_string(&b, "Div")
	case .Not:     strings.write_string(&b, "Not")
	case .Minus:   strings.write_string(&b, "Minus")
	case .Bool_EQ: strings.write_string(&b, "Bool EQ")
	case .Bool_LT: strings.write_string(&b, "Bool LT")
	case .Bool_LE: strings.write_string(&b, "Bool LE")
	}

	shrink(&b.buf)
	return strings.to_string(b)
}
