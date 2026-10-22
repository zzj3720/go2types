//go:build !tstst

package main

// Loading with go/packages (which runs `go list`), and output to files.

import (
	"flag"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"

	"golang.org/x/tools/go/packages"
	"golang.org/x/tools/go/ssa"
	"golang.org/x/tools/go/ssa/ssautil"
)

var (
	packPath = flag.String("pack", "", "write the loaded packages and the command line to this file (the input of a go2types running on tstst) instead of compiling")
	fromPack = flag.String("from-pack", "", "load the program from a pack (as the go2types on tstst does); the command line after the pack's overrides its flags")
)

var stderr = os.Stderr

func parseFlags() {
	flag.Parse()
	if *fromPack == "" {
		return
	}
	data, err := os.ReadFile(*fromPack)
	if err != nil {
		fatal("%v", err)
	}
	thePack = &packReader{s: string(data)}
	if err := flag.CommandLine.Parse(readPackArgs(thePack)); err != nil {
		fatal("%v", err)
	}
	// this command line's flags override the pack's; the package is the pack's
	pkg := flag.Args()
	if err := flag.CommandLine.Parse(append(os.Args[1:], pkg...)); err != nil {
		fatal("%v", err)
	}
}

var thePack *packReader

func load() (*ssa.Program, []*ssa.Package, string) {
	mode := ssa.InstantiateGenerics | ssa.SanityCheckFunctions | ssa.BuildSerially
	if thePack != nil {
		return loadPack(thePack, mode)
	}
	cfg := &packages.Config{
		Mode:       packages.LoadAllSyntax,
		Env:        append(os.Environ(), "CGO_ENABLED=0", "GOOS=linux", "GOARCH=amd64", "GOWORK=off"),
		BuildFlags: []string{"-tags=tstst,purego,math_big_pure_go"},
		Dir:        *dir,
		Overlay:    buildOverlay(),
		Tests:      *testBin,
	}
	var mu sync.Mutex
	srcs := map[string][]byte{}
	if *packPath != "" {
		// the module's go version (the type checker's language version)
		cfg.Mode |= packages.NeedModule
		// remember exactly what was parsed
		cfg.ParseFile = func(fset *token.FileSet, filename string, src []byte) (*ast.File, error) {
			mu.Lock()
			srcs[filename] = src
			mu.Unlock()
			return parser.ParseFile(fset, filename, src, parser.AllErrors|parser.ParseComments)
		}
	}
	// runtime too, which a program using only builtins does not import: its
	// runtime errors are Go values of package runtime (G_rterr)
	patterns := flag.Args()
	if !*testBin {
		patterns = append(patterns, "runtime")
	}
	pkgs, err := packages.Load(cfg, patterns...)
	if err != nil {
		fatal("load: %v", err)
	}
	// the program's packages first (the first is the one go2types compiles)
	if len(patterns) > 1 {
		var mine, rt []*packages.Package
		for _, p := range pkgs {
			if p.PkgPath == "runtime" && len(pkgs) > 1 {
				rt = append(rt, p)
			} else {
				mine = append(mine, p)
			}
		}
		pkgs = append(mine, rt...)
	}
	if packages.PrintErrors(pkgs) > 0 {
		os.Exit(1)
	}
	// the //go:embed directives (their files go into a pack)
	embeds := map[string][]string{}
	packages.Visit(pkgs, nil, func(p *packages.Package) {
		embeds[p.ID] = scanEmbeds(p.Fset, p.Syntax)
	})
	if *packPath != "" {
		writePack(pkgs, srcs, embeds)
		os.Exit(0)
	}
	if *testBin && len(patterns) > 1 {
		packages.Visit(pkgs, nil, func(p *packages.Package) {
			if p.Types != nil && strings.HasSuffix(p.ID, ".test]") {
				variantIDs[p.Types] = p.ID
			}
		})
	}
	prog, spkgs := ssautil.AllPackages(pkgs, mode)
	return prog, spkgs, pkgs[0].PkgPath
}

func writePack(initial []*packages.Package, srcs map[string][]byte, embeds map[string][]string) {
	var w packWriter
	w.str(packMagic)
	// the command line without -pack
	var args []string
	for i := 1; i < len(os.Args); i++ {
		a := os.Args[i]
		switch {
		case a == "-pack" || a == "--pack":
			i++
			continue
		case strings.HasPrefix(a, "-pack=") || strings.HasPrefix(a, "--pack="):
			continue
		}
		args = append(args, a)
	}
	w.int(len(args))
	for _, a := range args {
		w.str(a)
	}
	var order []*packages.Package
	packages.Visit(initial, nil, func(p *packages.Package) {
		if p.Types != nil && !p.IllTyped {
			order = append(order, p)
		}
	})
	w.int(len(order))
	for _, p := range order {
		goVersion := ""
		if p.Module != nil && p.Module.GoVersion != "" {
			goVersion = "go" + p.Module.GoVersion
		}
		w.str(p.ID)
		w.str(p.PkgPath)
		w.str(p.Name)
		w.str(goVersion)
		var imps []string
		for path := range p.Imports {
			imps = append(imps, path)
		}
		sort.Strings(imps)
		w.int(len(imps))
		for _, path := range imps {
			w.str(path)
			w.str(p.Imports[path].ID)
		}
		files := p.CompiledGoFiles
		if p.PkgPath == "unsafe" {
			files = nil // go/packages gives it no syntax
		}
		if len(files) != len(p.Syntax) {
			fatal("pack: %s: %d files but %d parsed", p.ID, len(files), len(p.Syntax))
		}
		w.int(len(files))
		for _, f := range files {
			src, ok := srcs[f]
			if !ok {
				fatal("pack: %s was not parsed", f)
			}
			w.str(f)
			w.str(string(src))
		}
		// the embedded files that exist (the bundled libs come in the
		// program's input)
		var names, contents []string
		if !strings.HasSuffix(p.PkgPath, "/internal/bundled") {
			for _, path := range embeds[p.ID] {
				if data, err := os.ReadFile(path); err == nil {
					names = append(names, path)
					contents = append(contents, string(data))
				}
			}
		}
		w.int(len(names))
		for i, path := range names {
			w.str(path)
			w.str(contents[i])
		}
	}
	w.int(len(initial))
	for _, p := range initial {
		w.str(p.ID)
	}
	if err := os.WriteFile(*packPath, []byte(w.b.String()), 0o644); err != nil {
		fatal("%v", err)
	}
}

func writeOutput(s string) {
	if err := os.MkdirAll(filepath.Dir(*outPath), 0o755); err != nil {
		fatal("%v", err)
	}
	if err := os.WriteFile(*outPath, []byte(s), 0o644); err != nil {
		fatal("%v", err)
	}
}

func writeSideFile(path, s string) { os.WriteFile(path, []byte(s), 0o644) }

// ---------------------------------------------------------------------------
// Overlays: replacement packages (natives/<import path>) and small patches to
// standard library files.

type patch struct {
	pkg, file, old, new string
}

// pkg is a GOROOT/src directory or "tsc:<dir>" relative to the -C directory.
var patches = []patch{
	// fast paths for the harness's expressions (extra/regexp)
	{"regexp", "exec.go", "\tif dstCap == nil {\n\t\t// Make sure 'return dstCap' is non-nil.\n\t\tdstCap = arrayNoInts[:0:0]\n\t}\n", "\tif dstCap == nil {\n\t\t// Make sure 'return dstCap' is non-nil.\n\t\tdstCap = arrayNoInts[:0:0]\n\t}\n\tif r == nil && b == nil {\n\t\tif f := tststFinder(re.expr); f != nil {\n\t\t\tcaps := f(s, pos)\n\t\t\tif caps == nil {\n\t\t\t\treturn nil\n\t\t\t}\n\t\t\treturn append(dstCap, caps[:ncap]...)\n\t\t}\n\t}\n"},
	// pure Go math where amd64 has assembly
	{"math", "dim_asm.go", "const haveArchMax = true", "const haveArchMax = false"},
	{"math", "dim_asm.go", "const haveArchMin = true", "const haveArchMin = false"},
	{"math", "exp_asm.go", "const haveArchExp = true", "const haveArchExp = false"},
	{"math", "log_asm.go", "const haveArchLog = true", "const haveArchLog = false"},
	// encoding/json needs reflection: package.json and source maps are
	// handled by hand (extra/tsc/internal/packagejson, extra/tsc/internal/sourcemap)
	{"tsc:internal/packagejson", "packagejson.go", "func Parse(data []byte) (Fields, error) {\n", "func Parse(data []byte) (Fields, error) {\n\tif true {\n\t\treturn tststParse(data)\n\t}\n"},
	{"tsc:internal/testutil/harnessutil", "harnessutil.go", "\ttestfs := make(map[string]any)\n", "\ttestfs := make(map[string]any)\n\tif TststTestLib != nil {\n\t\tfor p, c := range TststTestLib {\n\t\t\ttestfs[testLibFolder+\"/\"+p] = &fstest.MapFile{Data: []byte(c)}\n\t\t}\n\t\treturn testfs\n\t}\n"},
	{"tsc:internal/json", "json.go", "func Unmarshal(in []byte, out any, opts ...json.Options) (err error) {\n", "func Unmarshal(in []byte, out any, opts ...json.Options) (err error) {\n\tif u, ok := out.(interface{ TststUnmarshalJSON([]byte) error }); ok {\n\t\treturn u.TststUnmarshalJSON(in)\n\t}\n"},
	{"tsc:internal/json", "json.go", "func Marshal(in any, opts ...json.Options) (out []byte, err error) {\n", "func Marshal(in any, opts ...json.Options) (out []byte, err error) {\n\tif m, ok := in.(interface{ TststJSON() []byte }); ok {\n\t\treturn m.TststJSON(), nil\n\t}\n\tif ss, ok := in.([]string); ok {\n\t\treturn tststStrings(ss), nil\n\t}\n"},
	// no netpoller: descriptors are not pollable (as regular files on Linux),
	// the in-memory kernel (extra/syscall) blocks in reads instead
	{"internal/poll", "fd_poll_runtime.go", "func (pd *pollDesc) init(fd *FD) error {\n", "func (pd *pollDesc) init(fd *FD) error {\n\tif true {\n\t\treturn syscall.EPERM\n\t}\n"},
	// syscall's initialization is skipped, so its boxed errno globals are nil
	{"syscall", "syscall_unix.go", "func errnoErr(e Errno) error {\n\tswitch e {\n", "func errnoErr(e Errno) error {\n\tif e != 0 {\n\t\treturn e\n\t}\n\tswitch e {\n"},
	{"errors", "wrap.go", "isComparable := reflectlite.TypeOf(target).Comparable()", "isComparable := true"},
	{"tsc:internal/jsnum", "string.go", "\t\"github.com/microsoft/TypeScript/tsc/internal/json\"\n", ""},
	{"tsc:internal/jsnum", "string.go", "b, _ := json.Marshal(float64(n))\n\treturn string(b)", "return tststJSONFloat(float64(n))"},
	{"tsc:internal/testutil/baseline", "baseline.go", "\tsubfolder := opts.Subfolder\n", "\tif TststSink != nil {\n\t\tTststSink(filepath.Join(opts.Subfolder, fileName), actual)\n\t\treturn\n\t}\n\tsubfolder := opts.Subfolder\n"},
	{"tsc:internal/testrunner", "compiler_runner.go", "\tcompilerTest.verifyUnionOrdering(t)\n\tcompilerTest.verifyParentPointers(t)\n", ""},
	// transpile tests get their content from the driver
	{"tsc:internal/testrunner", "transpile_runner.go", "\tcontent, ok := osvfs.FS().ReadFile(tspath.RootedFilePathFromNormalized(fileName))\n", "\tcontent, ok := tststTranspileContent, true\n\tif content == \"\" {\n\t\tcontent, ok = osvfs.FS().ReadFile(tspath.RootedFilePathFromNormalized(fileName))\n\t}\n"},
	// content mappers without goroutines: test mappers run in-process (extra/tsc/internal/ipc),
	// and the host reads their replies inline; processes keep the reader goroutine (timeouts, exits)
	{"tsc:internal/testutil/contentmappertest", "spawner.go", "\t\"io\"\n\t\"net\"\n", "\t\"io\"\n"},
	{"tsc:internal/testutil/contentmappertest", "spawner.go", "\tclient, server := net.Pipe()\n\tgo func() { _ = ipc.NewAsyncConn(server, handler).Run(context.Background()) }()\n\treturn client, nil\n", "\treturn ipc.NewTststPeer(handler), nil\n"},
	{"tsc:internal/contentmapper", "hostimpl.go", "\t\trwc, err := spawner.Spawn(mapper.Exec, mapper.PackageDirectory.AsString(), stderr)\n", "\t\ttststPeers := ipc.TststPeerCount()\n\t\trwc, err := spawner.Spawn(mapper.Exec, mapper.PackageDirectory.AsString(), stderr)\n\t\ttststInProcess := ipc.TststPeerCount() != tststPeers\n"},
	{"tsc:internal/contentmapper", "hostimpl.go", "\t\tconn := ipc.NewAsyncConnWithProtocol(rwc, protocol, rejectHandler{})\n\t\tgo func() {\n\t\t\t_ = conn.Run(ctx)\n\t\t\t_ = rwc.Close()\n\t\t}()\n", "\t\tvar conn ipc.Conn\n\t\tif tststInProcess {\n\t\t\tconn = ipc.NewSyncConn(rwc, protocol, rejectHandler{})\n\t\t} else {\n\t\t\tasync := ipc.NewAsyncConnWithProtocol(rwc, protocol, rejectHandler{})\n\t\t\tgo func() {\n\t\t\t\t_ = async.Run(ctx)\n\t\t\t\t_ = rwc.Close()\n\t\t\t}()\n\t\t\tconn = async\n\t\t}\n"},
	{"tsc:internal/repo", "paths.go", "var rootPath = sync.OnceValue(func() string {\n", "var rootPath = sync.OnceValue(func() string {\n\tif true {\n\t\treturn \"/tsc\"\n\t}\n"},
}

// files added to packages: (pkg, file name, content)
var extraFiles = [][3]string{
	{"tsc:internal/testutil/baseline", "zz_tstst.go", `package baseline

// TststSink receives baselines instead of comparing them with files on disk.
var TststSink func(path, content string)
`},
	{"tsc:internal/bundled", "zz_tstst.go", `package bundled

// TststSetLib provides the contents of a bundled lib file.
func TststSetLib(name, content string) { embeddedContents["libs/"+name] = content }
`},
	{"tsc:internal/testrunner", "zz_tstst.go", `package testrunner

import (
	"slices"
	"testing"
	"unicode/utf16"

	"github.com/microsoft/TypeScript/tsc/internal/testutil/harnessutil"
	"github.com/microsoft/TypeScript/tsc/internal/tspath"
)

// TststRunTest runs one compiler or conformance test whose content (the raw
// file bytes) is given. Each configuration is a subtest, as in the real runner.
func TststRunTest(t *testing.T, conformance bool, filename, content string) {
	testType := TestTypeRegression
	if conformance {
		testType = TestTypeConformance
	}
	if slices.Contains(skippedTests, tspath.GetBaseFileName(filename)) {
		return
	}
	content = tststDecode(content)
	r := NewCompilerBaselineRunner(testType)
	settings := extractCompilerSettings(content)
	configurations := harnessutil.GetFileBasedTestConfigurations(t, settings, compilerVaryBy)
	test := &compilerFileBasedTest{filename: filename, content: content, configurations: configurations}
	basename := tspath.GetBaseFileName(filename)
	if len(test.configurations) > 0 {
		for _, config := range test.configurations {
			testName := basename
			if config.Name != "" {
				testName += " " + config.Name
			}
			t.Run(testName, func(t *testing.T) { r.runSingleConfigTest(t, testName, test, config) })
		}
	} else {
		t.Run(basename, func(t *testing.T) { r.runSingleConfigTest(t, basename, test, nil) })
	}
}

var tststTranspileContent string

// TststRunTranspileTest runs one transpile test whose content (the raw file
// bytes) is given.
func TststRunTranspileTest(t *testing.T, filename, content string) {
	tststTranspileContent = tststDecode(content)
	NewTranspileBaselineRunner().runTest(t, filename)
}

// tststDecode does what the vfs does when reading a file: UTF-16 by its BOM,
// otherwise UTF-8 without a BOM.
func tststDecode(s string) string {
	if len(s) >= 2 && (s[0] == 0xFF && s[1] == 0xFE || s[0] == 0xFE && s[1] == 0xFF) {
		le := s[0] == 0xFF
		units := make([]uint16, 0, len(s)/2)
		for i := 2; i+1 < len(s); i += 2 {
			if le {
				units = append(units, uint16(s[i])|uint16(s[i+1])<<8)
			} else {
				units = append(units, uint16(s[i])<<8|uint16(s[i+1]))
			}
		}
		return string(utf16.Decode(units))
	}
	if len(s) >= 3 && s[0] == 0xEF && s[1] == 0xBB && s[2] == 0xBF {
		return s[3:]
	}
	return s
}
`},
	{"tsc:internal/jsnum", "zz_tstst.go", `package jsnum

import "strconv"

// Number formatting of encoding/json (ES6 Number::toString for non-integers).
func tststJSONFloat(f float64) string {
	abs := f
	if abs < 0 {
		abs = -abs
	}
	fmt := byte('f')
	if abs != 0 && (abs < 1e-6 || abs >= 1e21) {
		fmt = 'e'
	}
	b := strconv.AppendFloat(nil, f, fmt, -1, 64)
	if fmt == 'e' {
		n := len(b)
		if n >= 4 && b[n-4] == 'e' && b[n-3] == '-' && b[n-2] == '0' {
			b[n-2] = b[n-1]
			b = b[:n-1]
		}
	}
	return string(b)
}
`},
}

func patchPath(root, pkg, file string) string {
	if rest, ok := strings.CutPrefix(pkg, "tsc:"); ok {
		base := *dir
		if base == "" {
			base = "."
		}
		// (the files' real paths, as go/packages has them: -C may be a link)
		if r, err := filepath.EvalSymlinks(base); err == nil {
			base = r
		}
		abs, _ := filepath.Abs(filepath.Join(base, rest, file))
		return abs
	}
	return filepath.Join(root, pkg, file)
}

func goroot() string {
	out, err := exec.Command("go", "env", "GOROOT").Output()
	if err != nil {
		fatal("go env GOROOT: %v", err)
	}
	return strings.TrimSpace(string(out))
}

func buildOverlay() map[string][]byte {
	root := filepath.Join(goroot(), "src")
	ov := map[string][]byte{}
	ndir := *natives
	if ndir == "" {
		ndir = "natives"
	}
	filepath.WalkDir(ndir, func(path string, d os.DirEntry, err error) error {
		if err != nil || !d.IsDir() {
			return nil
		}
		rel, _ := filepath.Rel(ndir, path)
		if rel == "." {
			return nil
		}
		files, _ := os.ReadDir(path)
		var mine []string
		pkgName := ""
		for _, fe := range files {
			if strings.HasSuffix(fe.Name(), ".go") {
				mine = append(mine, fe.Name())
				data, _ := os.ReadFile(filepath.Join(path, fe.Name()))
				for _, line := range strings.Split(string(data), "\n") {
					if strings.HasPrefix(line, "package ") {
						pkgName = strings.TrimSpace(strings.TrimPrefix(line, "package "))
						break
					}
				}
			}
		}
		if len(mine) == 0 {
			return nil
		}
		std := filepath.Join(root, rel)
		orig, _ := os.ReadDir(std)
		for _, fe := range orig {
			n := fe.Name()
			if strings.HasSuffix(n, ".go") && !strings.HasSuffix(n, "_test.go") {
				ov[filepath.Join(std, n)] = []byte("package " + pkgName + "\n")
			}
		}
		for _, n := range mine {
			data, _ := os.ReadFile(filepath.Join(path, n))
			ov[filepath.Join(std, "zz_tstst_"+n)] = data
		}
		return nil
	})
	for _, p := range patches {
		path := patchPath(root, p.pkg, p.file)
		data, ok := ov[path]
		if !ok {
			var err error
			data, err = os.ReadFile(path)
			if err != nil {
				if strings.HasPrefix(p.pkg, "tsc:") && *dir == "" {
					continue
				}
				fatal("patch %s/%s: %v", p.pkg, p.file, err)
			}
		}
		src := string(data)
		if !strings.Contains(src, p.old) {
			fatal("patch %s/%s: text not found: %q", p.pkg, p.file, p.old)
		}
		src = strings.Replace(src, p.old, p.new, 1)
		ov[path] = []byte(src)
	}
	for _, f := range extraFiles {
		if strings.HasPrefix(f[0], "tsc:") && *dir == "" {
			continue
		}
		ov[patchPath(root, f[0], f[1])] = []byte(f[2])
	}
	// extra/<package>/<file>: more files added to packages; tsc/... are tsc's
	// packages (relative to -C), the rest the standard library's
	filepath.WalkDir("extra", func(path string, d os.DirEntry, err error) error {
		if err != nil || d.IsDir() || !strings.HasSuffix(path, ".go") {
			return nil
		}
		rel, _ := filepath.Rel("extra", filepath.Dir(path))
		pkg := filepath.ToSlash(rel)
		if rest, ok := strings.CutPrefix(pkg, "tsc/"); ok {
			if *dir == "" {
				return nil
			}
			pkg = "tsc:" + rest
		}
		data, _ := os.ReadFile(path)
		ov[patchPath(root, pkg, d.Name())] = data
		return nil
	})
	return ov
}
