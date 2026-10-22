package bundled

import (
	"strings"
	"testing"
)

// test binaries on tstst get the lib files in their input (lib:<name>)
func init() {
	testing.TststKeyHooks = append(testing.TststKeyHooks, func(k, v string) bool {
		if name, ok := strings.CutPrefix(k, "lib:"); ok {
			TststSetLib(name, v)
			return true
		}
		return false
	})
}
