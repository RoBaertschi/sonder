package sonder_example

import "core:strconv"
import "core:fmt"
import ".."

Precedence :: enum {
	Lowest,
	Compare,
	Sum,
	Product,
	Prefix,
}

@(rodata)
token_precedence := #partial [Token_Kind]Precedence{
	.Plus 		     		     = .Sum,
	.Minus 		    		     = .Sum,
	.Asterisk    		     = .Product,
	.Slash 		    		     = .Product,
	.Equal_Equal 		     = .Compare,
	.Not_Equal 				     = .Compare,
	.Less_Than 									= .Compare,
	.Less_Than_Equal    = .Compare,
	.Greater_Than       = .Compare,
	.Greater_Than_Equal = .Compare,
}

Parser :: struct {
	lexer: Lexer,
	curr_token, next_token: Token,

	module: ^sonder.Module,
	start:  ^sonder.Node,
	stop:   ^sonder.Node,
	scope:  ^sonder.Node,
}

p_init :: proc(p: ^Parser, m: ^sonder.Module, input: string) {
	p^ = { module = m }
	l_init(&p.lexer, input)
	p_next_token(p)
	p_next_token(p)
}

p_next_token :: proc(p: ^Parser) {
	p.curr_token = p.next_token
	p.next_token = l_next(&p.lexer)
}

p_error :: proc(p: ^Parser, t: Token, format: string, args: ..any) {
	fmt.printf("%d: Syntax Error: ", t.pos)
	fmt.printfln(format, ..args)
}

p_expect :: proc(p: ^Parser, t: Token_Kind) -> (ok: bool) {
	ok = p.curr_token.kind == t
	if !ok {
		p_error(p, p.curr_token, "expected %v, but got %v", t, p.curr_token.kind)
	}
	return
}

p_expect_next :: proc(p: ^Parser, t: Token_Kind) -> (ok: bool) {
	ok = p.next_token.kind == t

	if !ok {
		p_error(p, p.next_token, "expected %v, but got %v", t, p.next_token.kind)
	}
	p_next_token(p)

	return
}

p_parse :: proc(p: ^Parser) -> (node: ^sonder.Node) {
	p.start = sonder.node_start(p.module)
	p.stop  = sonder.node_stop(p.module)
	p.scope = sonder.node_scope(p.module)

	p.module.start = p.start
	defer p.module.start = nil

	{
		sonder.node_scope_push(p.module, p.scope)
		defer sonder.node_scope_pop(p.module, p.scope)

		sonder.node_scope_define(p.module, p.scope, sonder.NODE_SCOPE_CTRL, sonder.node_peephole(p.module, sonder.node_proj(p.module, p.start, 0)))
		sonder.node_scope_define(p.module, p.scope, sonder.NODE_SCOPE_ARG,  sonder.node_peephole(p.module, sonder.node_proj(p.module, p.start, 1)))

		p_parse_block(p)
		p_expect_next(p, .EOF)
	}

	node = sonder.node_peephole(p.module, p.stop)
	return
}

p_ctrl :: proc(p: ^Parser) -> (ctrl: ^sonder.Node) {
	ctrl = sonder.node_input(p.scope, 0)
	return
}

p_set_ctrl :: proc(p: ^Parser, ctrl: ^sonder.Node) {
	sonder.node_set_def(p.module, p.scope, 0, ctrl)
}

p_parse_block :: proc(p: ^Parser) -> (node: ^sonder.Node) {
	sonder.node_scope_push(p.module, p.scope)
	defer sonder.node_scope_pop(p.module, p.scope)

	for p.curr_token.kind != .Brace_Close && p.curr_token.kind != .EOF {
		stmt := p_parse_statement(p)
		p_next_token(p)
	}

	return
}

p_parse_statement :: proc(p: ^Parser) -> (stmt: ^sonder.Node) {
	#partial switch p.curr_token.kind {
	case .Return:     stmt = p_parse_return_statement(p)
	case .Int:        stmt = p_parse_declaration(p)
	case .Brace_Open: stmt = p_parse_block_statement(p)
	case .Identifier: stmt = p_parse_assignment_expression(p)
	case .If:         stmt = p_parse_if_statement(p)
	case .Semicolon:  stmt = nil
	case:
		p_error(p, p.curr_token, "invalid token %v, expected statement", p.curr_token.kind)
	}

	return
}

p_parse_return_statement :: proc(p: ^Parser) -> (node: ^sonder.Node) {
	p_expect(p, .Return)
	p_next_token(p)
	value := p_parse_expression(p)
	p_expect_next(p, .Semicolon)
	node = sonder.node_peephole(p.module, sonder.node_return(p.module, p_ctrl(p), value))
	sonder.node_stop_add_return(p.module, p.stop, node)
	p_set_ctrl(p, nil)
	return
}

p_parse_declaration :: proc(p: ^Parser) -> (node: ^sonder.Node) {
	p_expect(p, .Int)
	if p_expect_next(p, .Identifier) {
		variable_token := p.curr_token
		variable_name := variable_token.content

		if p_expect_next(p, .Equal) {
			p_next_token(p)
			node = p_parse_expression(p)
			if sonder.node_scope_define(p.module, p.scope, variable_name, node) == nil {
				p_error(p, variable_token, "variable %q already declared in this scope", variable_name)
			}
			p_expect_next(p, .Semicolon)
		}
	}

	return
}

p_parse_block_statement :: proc(p: ^Parser) -> (stmt: ^sonder.Node) {
	p_expect(p, .Brace_Open)
	p_next_token(p)
	stmt = p_parse_block(p)
	p_expect(p, .Brace_Close)
	return
}

p_parse_assignment_expression :: proc(p: ^Parser) -> (expr: ^sonder.Node) {
	p_expect(p, .Identifier)
	variable_token := p.curr_token
	if p_expect_next(p, .Equal) {
		p_next_token(p)
		expr = p_parse_expression(p)
		if !sonder.node_scope_set(p.module, p.scope, variable_token.content, expr) {
			p_error(p, variable_token, "could not find variable %q", variable_token.content)
		}
		p_expect_next(p, .Semicolon)
	}
	return
}

p_parse_if_statement :: proc(p: ^Parser) -> (stmt: ^sonder.Node) {
	p_expect(p, .If)
	p_expect_next(p, .Paren_Open)
	p_next_token(p)
	expr := p_parse_expression(p)

	stmt = sonder.node_peephole(p.module, sonder.node_keep(sonder.node_if(p.module, p_ctrl(p), expr)))
	if_t := sonder.node_peephole(p.module, sonder.node_proj(p.module, stmt, 0))
	sonder.node_unkeep(stmt)
	if_f := sonder.node_peephole(p.module, sonder.node_proj(p.module, stmt, 1))

	node_defs := sonder.node_len_inputs(p.scope)
	t_scope   := p.scope
	f_scope   := sonder.node_scope_dup(p.module, p.scope)

	p_expect_next(p, .Paren_Close)
	p_next_token(p)

	p_set_ctrl(p, if_t)
	p_parse_statement(p)

	p.scope = f_scope
	p_set_ctrl(p, if_f)
	if p.next_token.kind == .Else {
		p_next_token(p)
		p_next_token(p)
		p_parse_statement(p)
	}

	if sonder.node_len_inputs(t_scope) != node_defs || sonder.node_len_inputs(f_scope) != node_defs {
		p_error(p, p.curr_token, "cannot define a new name on one arm of an if")
	}

	p.scope = t_scope

	stmt = sonder.node_scope_merge(p.module, t_scope, f_scope)
	p_set_ctrl(p, stmt)

	return
}

p_parse_expression :: proc(p: ^Parser, prec := Precedence.Lowest) -> (node: ^sonder.Node) {
	#partial switch p.curr_token.kind {
	case .Constant:
		constant, _ := strconv.parse_int(p.curr_token.content)
		node = sonder.node_peephole(p.module, sonder.node_constant(p.module, p.start, constant))
	case .Minus:
		p_next_token(p)
		data := p_parse_expression(p, .Prefix)
		node = sonder.node_peephole(p.module, sonder.node_minus(p.module, data))
	case .Paren_Open:
		p_next_token(p)
		node = p_parse_expression(p)
		p_expect_next(p, .Paren_Close)
	case .Identifier:
		node = sonder.node_scope_get(p.module, p.scope, p.curr_token.content)
		if node == nil {
			p_error(p, p.curr_token, "could not find variable associated with identifier %q", p.curr_token.content)
		}
	case .True:
		node = sonder.node_peephole(p.module, sonder.node_constant(p.module, p.start, 1))
		case .False:
			node = sonder.node_peephole(p.module, sonder.node_constant(p.module, p.start, 0))
	case:
		p_error(p, p.curr_token, "invalid expression token %v", p.curr_token.kind)
	}

	for p.next_token.kind != .Semicolon && prec < token_precedence[p.next_token.kind] {
		#partial switch p.next_token.kind {
		case .Plus,               .Minus,
							.Asterisk,           .Slash,
		     .Equal_Equal,        .Not_Equal,
							.Less_Than_Equal,    .Less_Than,
							.Greater_Than_Equal, .Greater_Than:
			p_next_token(p) // skip previous expression
			op := p.curr_token.kind
			p_next_token(p) // skip operator

			rhs := p_parse_expression(p, token_precedence[op])

			@(rodata, static)
			LUT := #partial [Token_Kind](#type proc(m: ^sonder.Module, lhs, rhs: ^sonder.Node) -> ^sonder.Node) {
				.Plus     = sonder.node_add,
				.Minus    = sonder.node_sub,
				.Asterisk = sonder.node_mul,
				.Slash    = sonder.node_div,

				.Equal_Equal = sonder.node_bool_eq,
				.Not_Equal   = proc(m: ^sonder.Module, lhs, rhs: ^sonder.Node) -> ^sonder.Node { return sonder.node_not(m, sonder.node_peephole(m, sonder.node_bool_eq(m, lhs, rhs))) },

				.Less_Than_Equal = sonder.node_bool_le,
				.Less_Than       = sonder.node_bool_lt,

				.Greater_Than_Equal = proc(m: ^sonder.Module, lhs, rhs: ^sonder.Node) -> ^sonder.Node { return sonder.node_bool_le(m, rhs, lhs) },
			 .Greater_Than       = proc(m: ^sonder.Module, lhs, rhs: ^sonder.Node) -> ^sonder.Node { return sonder.node_bool_lt(m, rhs, lhs) },
			}
			node = LUT[op](p.module, node, rhs)
			node = sonder.node_peephole(p.module, node)
		case:
			break
		}
	}

	return
}
