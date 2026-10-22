package softfloat

import (
	"math"
	"math/rand/v2"
	"testing"
)

func vals() []float64 {
	v := []float64{0, math.Copysign(0, -1), 1, -1, 0.5, 1.5, 2.5, -2.5, 3, 1e300, -1e300, 1e-300, 5e-324, -5e-324,
		math.MaxFloat64, math.SmallestNonzeroFloat64, math.Inf(1), math.Inf(-1), math.NaN(), 0.1, 0.2, 0.3, 1e21, 1e-7,
		123456789.125, 9007199254740993, -9223372036854775808, 9223372036854775807, 18446744073709551615, 4.5e15, 0.999999}
	r := rand.New(rand.NewPCG(1, 2))
	for i := 0; i < 300; i++ {
		v = append(v, math.Float64frombits(r.Uint64()), r.NormFloat64()*1e6, float64(r.Int64N(1000)-500)/8)
	}
	return v
}

func same(a, b uint64) bool {
	if isNaN(a) && isNaN(b) {
		return true
	}
	return a == b
}

func TestArith(t *testing.T) {
	vs := vals()
	for _, x := range vs {
		bx := math.Float64bits(x)
		for _, y := range vs[:60] {
			by := math.Float64bits(y)
			check := func(name string, got uint64, want float64) {
				if !same(got, math.Float64bits(want)) {
					t.Errorf("%s(%v, %v) = %v, want %v", name, x, y, math.Float64frombits(got), want)
				}
			}
			check("add", Fadd(bx, by), x+y)
			check("sub", Fsub(bx, by), x-y)
			check("mul", Fmul(bx, by), x*y)
			check("div", Fdiv(bx, by), x/y)
			if Flt(bx, by) != (x < y) || Fle(bx, by) != (x <= y) || Feq(bx, by) != (x == y) {
				t.Errorf("compare(%v, %v)", x, y)
			}
		}
		if !same(Fsqrt(bx), math.Float64bits(math.Sqrt(x))) {
			t.Errorf("sqrt(%v)", x)
		}
		if !same(Ffloor(bx), math.Float64bits(math.Floor(x))) {
			t.Errorf("floor(%v) = %v", x, math.Float64frombits(Ffloor(bx)))
		}
		if !same(Fround32(bx), math.Float64bits(float64(float32(x)))) {
			t.Errorf("round32(%v)", x)
		}
		if !math.IsNaN(x) && math.Abs(x) < 9e18 && F2i(bx) != int64(x) {
			t.Errorf("f2i(%v) = %v", x, F2i(bx))
		}
	}
	for _, i := range []int64{0, 1, -1, 1 << 53, 1<<53 + 1, -1 << 63, 1<<63 - 1, 123456789} {
		if I2f(i) != math.Float64bits(float64(i)) {
			t.Errorf("i2f(%v)", i)
		}
	}
	for _, u := range []uint64{0, 1, 1 << 63, 1<<64 - 1, 1<<64 - 1025} {
		if U2f(u) != math.Float64bits(float64(u)) {
			t.Errorf("u2f(%v)", u)
		}
	}
}

func TestFtoa(t *testing.T) {
	cases := map[float64]string{0: "0", 1: "1", -1.5: "-1.5", 0.1: "0.1", 1e21: "1e+21", 1e20: "100000000000000000000",
		1e-7: "1e-7", 1e-6: "0.000001", 123.456: "123.456", 5e-324: "5e-324", 1.7976931348623157e308: "1.7976931348623157e+308",
		math.Inf(1): "Infinity", math.NaN(): "NaN", 2.5e-7: "2.5e-7", 12345678901234567890: "12345678901234567000"}
	for f, want := range cases {
		if got := Ftoa(math.Float64bits(f)); got != want {
			t.Errorf("Ftoa(%v) = %q, want %q", f, got, want)
		}
	}
}
