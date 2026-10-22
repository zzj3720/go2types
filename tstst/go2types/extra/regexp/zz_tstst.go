package regexp

import "unicode/utf8"

// Hand-written matchers for the expressions the tsgo test harness runs over
// whole baselines; the backtracking engine is slow inside the type system.
// Each returns the leftmost match at or after pos as capture positions
// (2 per group, the whole match first), or nil.
func tststFinder(expr string) func(s string, pos int) []int {
	switch expr {
	case "\r?\n":
		return tststFindNewline
	case "[\r  ]|\r?\n":
		return tststFindCodeLine
	case `\S`:
		return tststFindNonSpace
	case `^\s*[{|}]\s*$`:
		return tststFindBracketLine
	case `(?m)^\/{2}\s*@(\w+)\s*:\s*([^\r\n]*)`:
		return tststFindOption
	}
	return nil
}

func tststSpace(c byte) bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\f' || c == '\r'
}

func tststWord(c byte) bool {
	return c >= '0' && c <= '9' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c == '_'
}

func tststFindNewline(s string, pos int) []int {
	for i := pos; i < len(s); i++ {
		if s[i] == '\n' {
			if i > pos && s[i-1] == '\r' {
				return []int{i - 1, i + 1}
			}
			return []int{i, i + 1}
		}
	}
	return nil
}

func tststFindCodeLine(s string, pos int) []int {
	for i := pos; i < len(s); i++ {
		switch s[i] {
		case '\r', '\n':
			return []int{i, i + 1}
		case 0xE2:
			if i+2 < len(s) && s[i+1] == 0x80 && (s[i+2] == 0xA8 || s[i+2] == 0xA9) {
				return []int{i, i + 3}
			}
		}
	}
	return nil
}

func tststFindNonSpace(s string, pos int) []int {
	for i := pos; i < len(s); i++ {
		if !tststSpace(s[i]) {
			_, n := utf8.DecodeRuneInString(s[i:])
			return []int{i, i + n}
		}
	}
	return nil
}

func tststFindBracketLine(s string, pos int) []int {
	if pos != 0 {
		return nil
	}
	i, j := 0, len(s)
	for i < j && tststSpace(s[i]) {
		i++
	}
	for j > i && tststSpace(s[j-1]) {
		j--
	}
	if j-i == 1 && (s[i] == '{' || s[i] == '|' || s[i] == '}') {
		return []int{0, len(s)}
	}
	return nil
}

func tststFindOption(s string, pos int) []int {
	for i := pos; i < len(s); i++ {
		if i > 0 && s[i-1] != '\n' {
			continue
		}
		if m := tststMatchOption(s, i); m != nil {
			return m
		}
	}
	return nil
}

func tststMatchOption(s string, i int) []int {
	if i+2 > len(s) || s[i] != '/' || s[i+1] != '/' {
		return nil
	}
	j := i + 2
	for j < len(s) && tststSpace(s[j]) {
		j++
	}
	if j >= len(s) || s[j] != '@' {
		return nil
	}
	j++
	k := j
	for k < len(s) && tststWord(s[k]) {
		k++
	}
	if k == j {
		return nil
	}
	l := k
	for l < len(s) && tststSpace(s[l]) {
		l++
	}
	if l >= len(s) || s[l] != ':' {
		return nil
	}
	l++
	for l < len(s) && tststSpace(s[l]) {
		l++
	}
	e := l
	for e < len(s) && s[e] != '\r' && s[e] != '\n' {
		e++
	}
	return []int{i, e, j, k, l, e}
}
