// Replacement for testing/internal/testdeps on the tstst runtime: go test's
// generated main only needs these names.
package testdeps

type TestDeps struct{}

var (
	ModulePath string
	ImportPath string
)
