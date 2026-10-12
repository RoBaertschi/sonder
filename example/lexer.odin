package sonder_example

import "core:fmt"
import "core:unicode/utf8"
Token_Kind :: enum {
	Invalid,
	EOF,

	Semicolon,
	Plus,
	Minus,
	Slash,
	Asterisk,
	Paren_Open,
	Paren_Close,
	Brace_Open,
	Brace_Close,
	Equal,
	Equal_Equal,
	Not_Equal,
	Less_Than_Equal,
	Less_Than,
	Greater_Than_Equal,
	Greater_Than,

	Identifier,
	Else,
	False,
	If,
	Int,
	Return,
	True,

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

l_peek :: proc(l: ^Lexer) -> (peek_ch: rune) {
	old_l := l^
	defer l^ = old_l
	l_next_ch(l)
	peek_ch = l.ch
	return
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

	t.kind = .Identifier

	switch t.content {
	case "else":   t.kind = .Else
	case "false":  t.kind = .False
	case "if":     t.kind = .If
	case "int":    t.kind = .Int
	case "return": t.kind = .Return
	case "true":   t.kind = .True
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

	switch l.ch {
	case utf8.RUNE_EOF: t.kind = .EOF

	case ';': t.kind = .Semicolon
	case '+': t.kind = .Plus
	case '-': t.kind = .Minus
	case '/': t.kind = .Slash
	case '*': t.kind = .Asterisk
	case '(': t.kind = .Paren_Open
	case ')': t.kind = .Paren_Close
	case '{': t.kind = .Brace_Open
	case '}': t.kind = .Brace_Close

	case '=':
		t.kind = .Equal
	 if l_peek(l) == '=' {
			l_next_ch(l)
			t.kind = .Equal_Equal
		}
	case '<':
		t.kind = .Less_Than
	 if l_peek(l) == '=' {
			l_next_ch(l)
			t.kind = .Less_Than_Equal
		}
	case '>':
		t.kind = .Greater_Than
	 if l_peek(l) == '=' {
			l_next_ch(l)
			t.kind = .Greater_Than_Equal
		}
	case '!':
		if l_peek(l) == '=' {
			l_next_ch(l)
			t.kind = .Not_Equal
		}

	case '0'..='9':
		return l_lex_number(l)
	case:
		return l_lex_identifier(l)
	}

	t.content = l.input[t.pos:l.pos+1]
	l_next_ch(l)
	return
}
