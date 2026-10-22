package json

import (
	"errors"
	"strconv"
	"unicode/utf16"
	"unicode/utf8"
)

// TststAppendString appends s as a JSON string the way encoding/json/v2
// does with AllowInvalidUTF8: only quotes, backslashes and control
// characters are escaped; invalid UTF-8 becomes U+FFFD.
func TststAppendString(b []byte, s string) []byte {
	const hex = "0123456789abcdef"
	b = append(b, '"')
	for i := 0; i < len(s); {
		c := s[i]
		if c < utf8.RuneSelf {
			switch {
			case c == '"' || c == '\\':
				b = append(b, '\\', c)
			case c == '\b':
				b = append(b, '\\', 'b')
			case c == '\f':
				b = append(b, '\\', 'f')
			case c == '\n':
				b = append(b, '\\', 'n')
			case c == '\r':
				b = append(b, '\\', 'r')
			case c == '\t':
				b = append(b, '\\', 't')
			case c < 0x20:
				b = append(b, '\\', 'u', '0', '0', hex[c>>4], hex[c&0xF])
			default:
				b = append(b, c)
			}
			i++
			continue
		}
		r, n := utf8.DecodeRuneInString(s[i:])
		if r == utf8.RuneError && n == 1 {
			b = append(b, "�"...)
		} else {
			b = append(b, s[i:i+n]...)
		}
		i += n
	}
	return append(b, '"')
}

func tststStrings(ss []string) []byte {
	b := []byte{'['}
	for i, s := range ss {
		if i > 0 {
			b = append(b, ',')
		}
		b = TststAppendString(b, s)
	}
	return append(b, ']')
}

// TststValue is a parsed JSON value; Kind is 'n', 't' (true or false), 's', 'd' (number),
// 'a' or 'o'
type TststValue struct {
	Kind byte
	B    bool
	S    string
	D    float64
	Arr  []*TststValue
	Keys []string
	Vals []*TststValue
}

func (v *TststValue) TypeName() string {
	switch v.Kind {
	case 'n':
		return "null"
	case 't':
		return "boolean"
	case 's':
		return "string"
	case 'a':
		return "array"
	case 'o':
		return "object"
	}
	return "number"
}

// TststParse parses a JSON document without reflection.
func TststParse(data []byte) (*TststValue, error) {
	p := &tststParser{s: data}
	return p.document()
}

type tststParser struct {
	s []byte
	i int
}

var errTststSyntax = errors.New("invalid JSON")

func (p *tststParser) ws() {
	for p.i < len(p.s) {
		switch p.s[p.i] {
		case ' ', '\t', '\n', '\r':
			p.i++
		default:
			return
		}
	}
}

func (p *tststParser) document() (*TststValue, error) {
	v, err := p.value()
	if err != nil {
		return nil, err
	}
	p.ws()
	if p.i != len(p.s) {
		return nil, errTststSyntax
	}
	return v, nil
}

func (p *tststParser) lit(word string) bool {
	if len(p.s)-p.i >= len(word) && string(p.s[p.i:p.i+len(word)]) == word {
		p.i += len(word)
		return true
	}
	return false
}

func (p *tststParser) value() (*TststValue, error) {
	p.ws()
	if p.i >= len(p.s) {
		return nil, errTststSyntax
	}
	switch c := p.s[p.i]; {
	case c == '{':
		p.i++
		v := &TststValue{Kind: 'o'}
		p.ws()
		if p.i < len(p.s) && p.s[p.i] == '}' {
			p.i++
			return v, nil
		}
		for {
			p.ws()
			if p.i >= len(p.s) || p.s[p.i] != '"' {
				return nil, errTststSyntax
			}
			k, err := p.str()
			if err != nil {
				return nil, err
			}
			p.ws()
			if p.i >= len(p.s) || p.s[p.i] != ':' {
				return nil, errTststSyntax
			}
			p.i++
			x, err := p.value()
			if err != nil {
				return nil, err
			}
			replaced := false
			for j, old := range v.Keys {
				if old == k {
					v.Vals[j] = x
					replaced = true
				}
			}
			if !replaced {
				v.Keys = append(v.Keys, k)
				v.Vals = append(v.Vals, x)
			}
			p.ws()
			if p.i < len(p.s) && p.s[p.i] == ',' {
				p.i++
				continue
			}
			if p.i < len(p.s) && p.s[p.i] == '}' {
				p.i++
				return v, nil
			}
			return nil, errTststSyntax
		}
	case c == '[':
		p.i++
		v := &TststValue{Kind: 'a'}
		p.ws()
		if p.i < len(p.s) && p.s[p.i] == ']' {
			p.i++
			return v, nil
		}
		for {
			x, err := p.value()
			if err != nil {
				return nil, err
			}
			v.Arr = append(v.Arr, x)
			p.ws()
			if p.i < len(p.s) && p.s[p.i] == ',' {
				p.i++
				continue
			}
			if p.i < len(p.s) && p.s[p.i] == ']' {
				p.i++
				return v, nil
			}
			return nil, errTststSyntax
		}
	case c == '"':
		s, err := p.str()
		if err != nil {
			return nil, err
		}
		return &TststValue{Kind: 's', S: s}, nil
	case p.lit("true"):
		return &TststValue{Kind: 't', B: true}, nil
	case p.lit("false"):
		return &TststValue{Kind: 't'}, nil
	case p.lit("null"):
		return &TststValue{Kind: 'n'}, nil
	case c == '-' || c >= '0' && c <= '9':
		start := p.i
		p.i++
		for p.i < len(p.s) {
			d := p.s[p.i]
			if d >= '0' && d <= '9' || d == '.' || d == 'e' || d == 'E' || d == '+' || d == '-' {
				p.i++
				continue
			}
			break
		}
		f, err := strconv.ParseFloat(string(p.s[start:p.i]), 64)
		if err != nil {
			return nil, errTststSyntax
		}
		return &TststValue{Kind: 'd', D: f}, nil
	}
	return nil, errTststSyntax
}

func (p *tststParser) hex4() (rune, bool) {
	if p.i+4 > len(p.s) {
		return 0, false
	}
	n, err := strconv.ParseUint(string(p.s[p.i:p.i+4]), 16, 32)
	if err != nil {
		return 0, false
	}
	p.i += 4
	return rune(n), true
}

// reads a string starting at its opening quote
func (p *tststParser) str() (string, error) {
	p.i++
	var b []byte
	for p.i < len(p.s) {
		c := p.s[p.i]
		switch {
		case c == '"':
			p.i++
			return string(b), nil
		case c == '\\':
			p.i++
			if p.i >= len(p.s) {
				return "", errTststSyntax
			}
			e := p.s[p.i]
			p.i++
			switch e {
			case '"', '\\', '/':
				b = append(b, e)
			case 'b':
				b = append(b, '\b')
			case 'f':
				b = append(b, '\f')
			case 'n':
				b = append(b, '\n')
			case 'r':
				b = append(b, '\r')
			case 't':
				b = append(b, '\t')
			case 'u':
				r, ok := p.hex4()
				if !ok {
					return "", errTststSyntax
				}
				if utf16.IsSurrogate(r) {
					r2 := utf8.RuneError
					if p.i+1 < len(p.s) && p.s[p.i] == '\\' && p.s[p.i+1] == 'u' {
						p.i += 2
						if x, ok := p.hex4(); ok {
							r2 = x
						}
					}
					r = utf16.DecodeRune(r, r2)
				}
				b = utf8.AppendRune(b, r)
			default:
				return "", errTststSyntax
			}
		case c < 0x20:
			return "", errTststSyntax
		default:
			b = append(b, c)
			p.i++
		}
	}
	return "", errTststSyntax
}
