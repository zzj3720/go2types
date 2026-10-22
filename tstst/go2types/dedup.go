package main

import (
	"strconv"
	"strings"
)

// dedupFuncs makes the functions (and blocks) of the output that have the
// same code, up to the names of the functions they refer to, one: the first
// is emitted, the others are not and what referred to them refers to it.
// (Promoted methods of embedded types, for one, are the same code many
// times.) Equal code is found as in the minimization of an automaton: the
// texts with the names taken out first, then split by the classes of the
// names until no class splits, so blocks that call each other in a loop
// are equal when they are pairwise.
func dedupFuncs(out string) string {
	lines := strings.SplitAfter(out, "\n")
	type decl struct {
		name       string
		start, end int // lines
		doc        int // the doc comment's line, or -1
		tmpl       string
		refs       []string
	}
	var decls []*decl
	index := map[string]int{}
	for i := 0; i < len(lines); i++ {
		l := lines[i]
		head := strings.TrimPrefix(l, "export ")
		if !strings.HasPrefix(head, "type F") {
			continue
		}
		name := head[5:]
		k := 0
		for k < len(name) && identChar(name[k]) {
			k++
		}
		name = name[:k]
		if !isFuncName(name) {
			continue
		}
		j := i + 1
		for j < len(lines) && strings.HasPrefix(lines[j], " ") {
			j++
		}
		d := &decl{name: name, start: i, end: j, doc: -1}
		if i > 0 && strings.HasPrefix(lines[i-1], "/**") && strings.HasSuffix(lines[i-1], "*/\n") {
			d.doc = i - 1
		}
		index[name] = len(decls)
		decls = append(decls, d)
		i = j - 1
	}
	if len(decls) < 2 {
		return out
	}
	// the texts with the names of functions as #
	for _, d := range decls {
		var b strings.Builder
		if d.doc >= 0 && strings.Contains(lines[d.doc], "@") {
			// (tags: part of the code)
			b.WriteString(lines[d.doc])
		}
		text := strings.TrimPrefix(strings.Join(lines[d.start:d.end], ""), "export ")
		text = text[len("type ")+len(d.name):]
		b.WriteString(rewriteNames(text, func(n string) string {
			if _, ok := index[n]; ok {
				d.refs = append(d.refs, n)
				return "#"
			}
			return n
		}))
		d.tmpl = b.String()
	}
	class := make([]int, len(decls))
	ids := map[string]int{}
	for i, d := range decls {
		id, ok := ids[d.tmpl]
		if !ok {
			id = len(ids)
			ids[d.tmpl] = id
		}
		class[i] = id
	}
	n := len(ids)
	for {
		ids = map[string]int{}
		next := make([]int, len(decls))
		for i, d := range decls {
			var b strings.Builder
			b.WriteString(strconv.Itoa(class[i]))
			for _, r := range d.refs {
				b.WriteByte(',')
				b.WriteString(strconv.Itoa(class[index[r]]))
			}
			key := b.String()
			id, ok := ids[key]
			if !ok {
				id = len(ids)
				ids[key] = id
			}
			next[i] = id
		}
		class = next
		if len(ids) == n {
			break
		}
		n = len(ids)
	}
	first := map[int]int{}
	rename := map[string]string{}
	drop := make([]bool, len(lines))
	for i, d := range decls {
		f, ok := first[class[i]]
		if !ok {
			first[class[i]] = i
			continue
		}
		rename[d.name] = decls[f].name
		for k := d.start; k < d.end; k++ {
			drop[k] = true
		}
		if d.doc >= 0 {
			drop[d.doc] = true
		}
	}
	if len(rename) == 0 {
		return out
	}
	var b strings.Builder
	b.Grow(len(out))
	for k, l := range lines {
		if drop[k] {
			continue
		}
		b.WriteString(rewriteNames(l, func(n string) string {
			if r, ok := rename[n]; ok {
				return r
			}
			return n
		}))
	}
	return b.String()
}

// isFuncName: the name of a function or block (F, letters and digits, and _N)
func isFuncName(s string) bool {
	if len(s) < 2 || s[0] != 'F' {
		return false
	}
	i := 1
	for i < len(s) && (s[i] >= 'a' && s[i] <= 'z' || s[i] >= '0' && s[i] <= '9') {
		i++
	}
	if i == 1 {
		return false
	}
	if i == len(s) {
		return true
	}
	if s[i] != '_' || i+1 == len(s) {
		return false
	}
	for _, c := range []byte(s[i+1:]) {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}

func identChar(c byte) bool {
	return c == '_' || c == '$' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9'
}

// rewriteNames replaces the function names of the text (not in strings or
// comments) by f's
func rewriteNames(s string, f func(string) string) string {
	var b strings.Builder
	b.Grow(len(s))
	for i := 0; i < len(s); {
		c := s[i]
		switch {
		case c == '"' || c == '`':
			j := i + 1
			for j < len(s) && s[j] != c {
				if s[j] == '\\' {
					j++
				}
				j++
			}
			if j < len(s) {
				j++
			}
			b.WriteString(s[i:j])
			i = j
		case c == '/' && i+1 < len(s) && s[i+1] == '*':
			j := strings.Index(s[i+2:], "*/")
			if j < 0 {
				b.WriteString(s[i:])
				return b.String()
			}
			b.WriteString(s[i : i+2+j+2])
			i += 2 + j + 2
		case identChar(c):
			j := i
			for j < len(s) && identChar(s[j]) {
				j++
			}
			w := s[i:j]
			if c == 'F' && isFuncName(w) {
				w = f(w)
			}
			b.WriteString(w)
			i = j
		default:
			b.WriteByte(c)
			i++
		}
	}
	return b.String()
}
