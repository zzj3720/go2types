package main

// A pack holds everything go2types needs from `go list`: its command line and
// the packages of the program (dependencies first) with the exact file
// contents that go/packages parsed. `go2types -pack F ...` writes one; a
// go2types that runs on tstst (which cannot start `go list`) reads one as its
// input and type-checks and builds the program itself, like go/packages and
// ssautil.AllPackages do.
//
// Encoding: a sequence of strings, each written as <decimal length>:<bytes>.
//
//	magic, nargs, args..., npkgs,
//	  per package: id, path, name, go version, nimports, (import path, id)...,
//	               nfiles, (file name, content)...,
//	               nembeds, (embedded file's path, content)...
//	ninitial, initial ids...

import (
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"go/types"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"golang.org/x/tools/go/ssa"
)

const packMagic = "go2types-pack-2"

type packWriter struct{ b strings.Builder }

func (w *packWriter) str(s string) {
	w.b.WriteString(strconv.Itoa(len(s)))
	w.b.WriteByte(':')
	w.b.WriteString(s)
}

func (w *packWriter) int(n int) { w.str(strconv.Itoa(n)) }

type packReader struct {
	s string
	i int
}

func (r *packReader) str() string {
	n, j := 0, r.i
	for j < len(r.s) && r.s[j] != ':' {
		d := r.s[j]
		if d < '0' || d > '9' {
			fatal("pack: bad length at offset %d", j)
		}
		n = n*10 + int(d-'0')
		j++
	}
	if j+1+n > len(r.s) {
		fatal("pack: truncated at offset %d", r.i)
	}
	v := r.s[j+1 : j+1+n]
	r.i = j + 1 + n
	return v
}

func (r *packReader) int() int {
	n, err := strconv.Atoi(r.str())
	if err != nil {
		fatal("pack: %v", err)
	}
	return n
}

// readPackArgs checks the pack's header and returns its command line; r is
// left at the packages.
func readPackArgs(r *packReader) []string {
	if r.str() != packMagic {
		fatal("input is not a go2types pack")
	}
	args := make([]string, r.int())
	for i := range args {
		args[i] = r.str()
	}
	return args
}

// The files of //go:embed directives by the position of the variable they
// initialize (found in the parsed files by scanEmbeds), and the files' contents
// when the program comes from a pack (nil: they are read from the file system).
var (
	embedPaths   = map[token.Pos]string{}
	embedContent map[string]string
)

// scanEmbeds records the //go:embed directives of the files' variables (the
// one nearest to the declaration, as one file's path) and returns the paths.
func scanEmbeds(fset *token.FileSet, files []*ast.File) []string {
	var paths []string
	for _, f := range files {
		dir := filepath.Dir(fset.Position(f.Package).Filename)
		for _, d := range f.Decls {
			gd, ok := d.(*ast.GenDecl)
			if !ok || gd.Tok != token.VAR {
				continue
			}
			for _, s := range gd.Specs {
				vs := s.(*ast.ValueSpec)
				doc := vs.Doc
				if !gd.Lparen.IsValid() {
					doc = gd.Doc
				}
				if doc == nil {
					continue
				}
				pattern := ""
				for _, cm := range doc.List {
					if p, ok := strings.CutPrefix(strings.TrimSpace(cm.Text), "//go:embed "); ok {
						pattern = strings.TrimSpace(p)
					}
				}
				if pattern == "" {
					continue
				}
				path := filepath.Join(dir, pattern)
				for _, n := range vs.Names {
					embedPaths[n.Pos()] = path
				}
				paths = append(paths, path)
			}
		}
	}
	return paths
}

// readEmbed returns an embedded file's content.
func readEmbed(path string) (string, bool) {
	if embedContent != nil {
		s, ok := embedContent[path]
		return s, ok
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return "", false
	}
	return string(data), true
}

type importerFunc func(path string) (*types.Package, error)

func (f importerFunc) Import(path string) (*types.Package, error) { return f(path) }

func newTypesInfo() *types.Info {
	return &types.Info{
		Types:        make(map[ast.Expr]types.TypeAndValue),
		Defs:         make(map[*ast.Ident]types.Object),
		Uses:         make(map[*ast.Ident]types.Object),
		Implicits:    make(map[ast.Node]types.Object),
		Instances:    make(map[*ast.Ident]types.Instance),
		Scopes:       make(map[ast.Node]*types.Scope),
		Selections:   make(map[*ast.SelectorExpr]*types.Selection),
		FileVersions: make(map[*ast.File]string),
	}
}

// loadPack parses and type-checks the pack's packages (as go/packages does
// with LoadAllSyntax) and creates their SSA packages (as ssautil.AllPackages
// does). It returns the program, the initial packages and the first initial
// package's path.
func loadPack(r *packReader, mode ssa.BuilderMode) (*ssa.Program, []*ssa.Package, string) {
	fset := token.NewFileSet()
	sizes := types.SizesFor("gc", "amd64")
	prog := ssa.NewProgram(fset, mode)
	tpkgs := map[string]*types.Package{}
	spkgs := map[string]*ssa.Package{}
	paths := map[string]string{}
	nerr := 0
	embedContent = map[string]string{}
	npkgs := r.int()
	for k := 0; k < npkgs; k++ {
		id, path, name, goVersion := r.str(), r.str(), r.str(), r.str()
		paths[id] = path
		imports := map[string]string{}
		for n := r.int(); n > 0; n-- {
			p := r.str()
			imports[p] = r.str()
		}
		files := []*ast.File{}
		for n := r.int(); n > 0; n-- {
			name := r.str()
			src := r.str()
			f, err := parser.ParseFile(fset, name, src, parser.AllErrors|parser.ParseComments)
			if err != nil {
				fmt.Fprintln(stderr, err)
				nerr++
			}
			if f != nil {
				files = append(files, f)
			}
		}
		scanEmbeds(fset, files)
		for n := r.int(); n > 0; n-- {
			p := r.str()
			embedContent[p] = r.str()
		}
		info := newTypesInfo()
		if path == "unsafe" {
			tpkgs[id] = types.Unsafe
			spkgs[id] = prog.CreatePackage(types.Unsafe, files, info, true)
			continue
		}
		pkg := types.NewPackage(path, name)
		tc := &types.Config{
			Importer: importerFunc(func(p string) (*types.Package, error) {
				if p == "unsafe" {
					return types.Unsafe, nil
				}
				if t := tpkgs[imports[p]]; t != nil {
					return t, nil
				}
				return nil, fmt.Errorf("no metadata for %s", p)
			}),
			Error: func(err error) {
				fmt.Fprintln(stderr, err)
				nerr++
			},
			Sizes:     sizes,
			GoVersion: goVersion,
		}
		types.NewChecker(tc, fset, pkg, info).Files(files)
		tpkgs[id] = pkg
		spkgs[id] = prog.CreatePackage(pkg, files, info, true)
	}
	if nerr > 0 {
		fatal("%d errors in the pack's packages", nerr)
	}
	var initial []*ssa.Package
	first := ""
	for n := r.int(); n > 0; n-- {
		id := r.str()
		if first == "" {
			first = paths[id]
		}
		initial = append(initial, spkgs[id])
	}
	return prog, initial, first
}
