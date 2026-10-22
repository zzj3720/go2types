// tstst-scan: prints the token stream of a TypeScript file using tsgo's scanner.
// Used to check go2types on real compiler code against the native build.
package main

import (
	"strconv"
	"strings"

	"github.com/microsoft/TypeScript/tsc/internal/ast"
	"github.com/microsoft/TypeScript/tsc/internal/core"
	"github.com/microsoft/TypeScript/tsc/internal/scanner"
)

func main() {
	text := input()
	s := scanner.NewScanner()
	s.SetText(text)
	s.SetLanguageVariant(core.LanguageVariantStandard)
	var b strings.Builder
	for {
		tok := s.Scan()
		b.WriteString(strconv.Itoa(s.TokenStart()))
		b.WriteByte(' ')
		b.WriteString(tok.String())
		if tok == ast.KindIdentifier || tok == ast.KindStringLiteral || tok == ast.KindNumericLiteral {
			b.WriteByte(' ')
			b.WriteString(s.TokenValue())
		}
		b.WriteByte('\n')
		if tok == ast.KindEndOfFile {
			break
		}
	}
	output(b.String())
}
