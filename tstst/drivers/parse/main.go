// tstst-parse: parses a TypeScript file with tsgo's parser and prints the AST
// (kinds, ranges, flags) and the parse diagnostics.
package main

import (
	"strconv"
	"strings"

	"github.com/microsoft/TypeScript/tsc/internal/ast"
	"github.com/microsoft/TypeScript/tsc/internal/core"
	"github.com/microsoft/TypeScript/tsc/internal/parser"
)

func main() {
	text := input()
	sf := parser.ParseSourceFile(ast.SourceFileParseOptions{
		FileName: "/test.ts",
		PathKey:  "/test.ts",
	}, text, core.ScriptKindTS)
	var b strings.Builder
	var visit func(n *ast.Node, depth int)
	visit = func(n *ast.Node, depth int) {
		for i := 0; i < depth; i++ {
			b.WriteString("  ")
		}
		b.WriteString(n.Kind.String())
		b.WriteString(" ")
		b.WriteString(strconv.Itoa(n.Pos()))
		b.WriteString("-")
		b.WriteString(strconv.Itoa(n.End()))
		if n.Flags != 0 {
			b.WriteString(" flags=")
			b.WriteString(strconv.Itoa(int(n.Flags)))
		}
		switch n.Kind {
		case ast.KindIdentifier, ast.KindStringLiteral, ast.KindNumericLiteral, ast.KindPrivateIdentifier:
			b.WriteString(" ")
			b.WriteString(strconv.Quote(n.Text()))
		}
		b.WriteString("\n")
		n.ForEachChild(func(c *ast.Node) bool {
			visit(c, depth+1)
			return false
		})
	}
	visit(sf.AsNode(), 0)
	for _, d := range sf.Diagnostics() {
		b.WriteString("diag ")
		b.WriteString(strconv.Itoa(d.Pos()))
		b.WriteString(" TS")
		b.WriteString(strconv.Itoa(int(d.Code())))
		b.WriteString(" ")
		b.WriteString(d.MessageText())
		b.WriteString("\n")
	}
	output(b.String())
}
