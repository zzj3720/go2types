package harnessutil

import (
	"strings"
	"testing"
)

// TststTestLib holds the files of testdata/tests/lib (path below it ->
// content) when they cannot be read from disk.
var TststTestLib map[string]string

func init() {
	testing.TststKeyHooks = append(testing.TststKeyHooks, func(k, v string) bool {
		if path, ok := strings.CutPrefix(k, "testlib:"); ok {
			if TststTestLib == nil {
				TststTestLib = map[string]string{}
			}
			TststTestLib[path] = v
			return true
		}
		return false
	})
}
