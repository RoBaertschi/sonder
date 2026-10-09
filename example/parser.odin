package sonder_example

import "core:strconv"
import "core:fmt"
import ".."

Parser :: struct {
	lexer: Lexer,
	curr_token, next_token: Token,

	module: ^sonder.Module,
	start: ^sonder.Node,
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
	stmt := p_parse_return_statement(p)
	p_expect_next(p, .EOF)
	return stmt
}

p_parse_return_statement :: proc(p: ^Parser) -> (node: ^sonder.Node) {
	p_expect(p, .Return)
	p_next_token(p)
	value := p_parse_expression(p)
	p_expect_next(p, .Semicolon)
	node = sonder.node_return(p.module, p.start, value)
	return
}

p_parse_expression :: proc(p: ^Parser) -> (node: ^sonder.Node) {
	#partial switch p.curr_token.kind {
	case .Constant:
		constant, _ := strconv.parse_int(p.curr_token.content)
		node = sonder.node_constant(p.module, p.start, constant)
		return
	case:
		p_error(p, p.curr_token, "invalid expression token %v", p.curr_token.kind)
	}

	return
}
