package sonder_example

import "core:fmt"
import "core:unicode/utf8"
Token_Kind :: enum {
	Invalid,
	EOF,

	Semicolon,

	Return,

	Constant,
}

Token :: struct {
	kind:    Token_Kind,
	pos:     int,
	content: string,
}

Lexer :: struct {
	input: string,
	pos:   int,
	ch:    rune,
}

l_init :: proc(l: ^Lexer, input: string) {
	l^ = {
		input = input,
		pos   = -1,
	}

	l_next_ch(l)
}

l_error :: proc(l: ^Lexer, pos: int, format: string, args: ..any) {
	fmt.printf("%d: Syntax Error: ")
	fmt.printfln(format, ..args)
}

l_next_ch :: proc(l: ^Lexer) {
	if l.pos+1 < len(l.input) {
		l.pos += 1
		l.ch = rune(l.input[l.pos])
	} else {
		l.ch = utf8.RUNE_EOF
	}
}

l_lex_number :: proc(l: ^Lexer) -> (t: Token) {
	t.pos = l.pos

	loop: for {
		switch l.ch {
		case '0'..='9': l_next_ch(l)
		case: break loop
		}
	}

	t.content = l.input[t.pos:l.pos]
	t.kind = .Constant

	return
}

l_lex_identifier :: proc(l: ^Lexer) -> (t: Token) {
	t.pos = l.pos

	loop: for {
		switch l.ch {
		case 'a'..='z': l_next_ch(l)
		case: break loop
		}
	}

	t.content = l.input[t.pos:l.pos]

	if t.content == "return" {
		t.kind = .Return
	} else {
		l_error(l, t.pos, "invalid identifier %q", t.content)
	}

	return
}

l_skip_whitespace :: proc(l: ^Lexer) {
	loop: for {
		switch l.ch {
		case ' ', '\n', '\r', '\t': l_next_ch(l)
		case: break loop
		}
	}
}

l_next :: proc(l: ^Lexer) -> (t: Token) {
	l_skip_whitespace(l)

	t.pos = l.pos
	t.content = l.input[l.pos:l.pos+1]

	switch l.ch {
	case utf8.RUNE_EOF: t.kind = .EOF
	case ';': t.kind = .Semicolon
	case '0'..='9':
		return l_lex_number(l)
	case:
		return l_lex_identifier(l)
	}

	l_next_ch(l)
	return
}
