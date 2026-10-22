package baseline

import "testing"

// in test binaries on tstst, baselines become records of the test's output
func init() {
	if TststSink == nil {
		TststSink = testing.TststRecord
	}
}
