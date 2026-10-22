// Replacement for package hash/maphash: the real one hashes with the Go
// runtime's hasher. Bytes and strings are hashed with FNV-1a mixed with the
// seed; Comparable numbers values in the order they are first hashed (a map
// with interface keys), so hashes are deterministic.
package maphash

type Seed struct {
	s uint64
}

var seeds uint64

// MakeSeed returns a new seed (deterministic: the seeds are numbered).
func MakeSeed() Seed {
	seeds++
	return Seed{s: seeds*0x9E3779B97F4A7C15 | 1}
}

func mix(h, seed uint64) uint64 {
	h ^= seed
	h ^= h >> 33
	h *= 0xff51afd7ed558ccd
	h ^= h >> 33
	h *= 0xc4ceb9fe1a85ec53
	h ^= h >> 33
	return h
}

func fnv(h uint64, s string) uint64 {
	for i := 0; i < len(s); i++ {
		h = (h ^ uint64(s[i])) * 0x100000001B3
	}
	return h
}

const offset = 0xCBF29CE484222325

func Bytes(seed Seed, b []byte) uint64 { return mix(fnv(offset, string(b)), seed.s) }

func String(seed Seed, s string) uint64 { return mix(fnv(offset, s), seed.s) }

var numbered = map[any]uint64{}

func number(v any) uint64 {
	n, ok := numbered[v]
	if !ok {
		n = uint64(len(numbered)) + 1
		numbered[v] = n
	}
	return n
}

func Comparable[T comparable](seed Seed, v T) uint64 {
	return mix(number(v), seed.s)
}

func WriteComparable[T comparable](h *Hash, x T) {
	seed := h.seed()
	h.state = mix(h.state^number(x), seed.s)
}

type Hasher[T any] interface {
	Hash(*Hash, T)
	Equal(x, y T) bool
}

type ComparableHasher[T comparable] struct {
	_ [0]func(T)
}

func (ComparableHasher[T]) Hash(h *Hash, v T) { WriteComparable(h, v) }

func (ComparableHasher[T]) Equal(x, y T) bool { return x == y }

type Hash struct {
	_     [0]func()
	seed_ Seed
	state uint64
	n     int
}

func (h *Hash) seed() Seed {
	if h.seed_.s == 0 {
		h.seed_ = MakeSeed()
		h.state = offset
	}
	return h.seed_
}

func (h *Hash) Seed() Seed { return h.seed() }

func (h *Hash) SetSeed(seed Seed) {
	if seed.s == 0 {
		panic("maphash: use of uninitialized Seed")
	}
	h.seed_ = seed
	h.state = offset
	h.n = 0
}

func (h *Hash) Reset() {
	h.seed()
	h.state = offset
	h.n = 0
}

func (h *Hash) WriteString(s string) (int, error) {
	h.seed()
	h.state = fnv(h.state, s)
	h.n += len(s)
	return len(s), nil
}

func (h *Hash) Write(b []byte) (int, error) { return h.WriteString(string(b)) }

func (h *Hash) WriteByte(b byte) error {
	h.WriteString(string([]byte{b}))
	return nil
}

func (h *Hash) Sum64() uint64 { return mix(h.state, h.seed().s) }

func (h *Hash) Sum(b []byte) []byte {
	x := h.Sum64()
	return append(b, byte(x>>56), byte(x>>48), byte(x>>40), byte(x>>32), byte(x>>24), byte(x>>16), byte(x>>8), byte(x))
}

func (h *Hash) Size() int { return 8 }

func (h *Hash) BlockSize() int { return 128 }
