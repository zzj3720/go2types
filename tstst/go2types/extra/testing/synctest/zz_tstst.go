package synctest

import "testing"

func tstst_testingSynctestTest(t *testing.T, f func(*testing.T)) bool {
	f(t)
	return !t.Failed()
}
