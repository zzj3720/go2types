package core

import (
	"math/bits"

	"github.com/zeebo/xxh3"
)

// XXH3 (seed 0) in safe Go, for programs on tstst: xxh3's own code reads
// strings and slices through their headers, which the tstst runtime does not
// have. go2types makes xxh3's Hash, HashString and Hasher (seed 0) call these
// (redirects in main.go); Hash128 and HashString128 are intrinsics.

const tststXXHKey = "\xb8\xfe\x6c\x39\x23\xa4\x4b\xbe\x7c\x01\x81\x2c\xf7\x21\xad\x1c" +
	"\xde\xd4\x6d\xe9\x83\x90\x97\xdb\x72\x40\xa4\xa4\xb7\xb3\x67\x1f" +
	"\xcb\x79\xe6\x4e\xcc\xc0\xe5\x78\x82\x5a\xd0\x7d\xcc\xff\x72\x21" +
	"\xb8\x08\x46\x74\xf7\x43\x24\x8e\xe0\x35\x90\xe6\x81\x3a\x26\x4c" +
	"\x3c\x28\x52\xbb\x91\xc3\x00\xcb\x88\xd0\x65\x8b\x1b\x53\x2e\xa3" +
	"\x71\x64\x48\x97\xa2\x0d\xf9\x4e\x38\x19\xef\x46\xa9\xde\xac\xd8" +
	"\xa8\xfa\x76\x3f\xe3\x9c\x34\x3f\xf9\xdc\xbb\xc7\xc7\x0b\x4f\x1d" +
	"\x8a\x51\xe0\x4b\xcd\xb4\x59\x31\xc8\x9f\x7e\xc9\xd9\x78\x73\x64" +
	"\xea\xc5\xac\x83\x34\xd3\xeb\xc3\xc5\x81\xa0\xff\xfa\x13\x63\xeb" +
	"\x17\x0d\xdd\x51\xb7\xf0\xda\x49\xd3\x16\x55\x26\x29\xd4\x68\x9e" +
	"\x2b\x16\xbe\x58\x7d\x47\xa1\xfc\x8f\xf8\xb8\xd1\x7a\xd0\x31\xce" +
	"\x45\xcb\x3a\x8f\x95\x16\x04\x28\xaf\xd7\xfb\xca\xbb\x4b\x40\x7e"

const (
	tststP32_1 = 2654435761
	tststP32_2 = 2246822519
	tststP32_3 = 3266489917
	tststP64_1 = 11400714785074694791
	tststP64_2 = 14029467366897019727
	tststP64_3 = 1609587929392839161
	tststP64_4 = 9650029242287828579
	tststP64_5 = 2870177450012600261
)

func tststU64(s string, o int) uint64 {
	return uint64(s[o]) | uint64(s[o+1])<<8 | uint64(s[o+2])<<16 | uint64(s[o+3])<<24 |
		uint64(s[o+4])<<32 | uint64(s[o+5])<<40 | uint64(s[o+6])<<48 | uint64(s[o+7])<<56
}

func tststU32(s string, o int) uint32 {
	return uint32(s[o]) | uint32(s[o+1])<<8 | uint32(s[o+2])<<16 | uint32(s[o+3])<<24
}

func tststK64(o int) uint64 { return tststU64(tststXXHKey, o) }

func tststAvalanche(x uint64) uint64 {
	x ^= x >> 37
	x *= 0x165667919e3779f9
	x ^= x >> 32
	return x
}

func tststAvalancheSmall(x uint64) uint64 {
	x *= tststP64_2
	x ^= x >> 29
	x *= tststP64_3
	x ^= x >> 32
	return x
}

func tststMulFold(x, y uint64) uint64 {
	hi, lo := bits.Mul64(x, y)
	return hi ^ lo
}

// one 64-byte stripe of s at d, with the key at k
func tststStripe(accs *[8]uint64, s string, d, k int) {
	for j := 0; j < 8; j++ {
		dv := tststU64(s, d+8*j)
		dk := dv ^ tststK64(k+8*j)
		accs[j^1] += dv
		accs[j] += uint64(uint32(dk)) * (dk >> 32)
	}
}

func tststHash128(s string) xxh3.Uint128 {
	hi, lo := tststXXH3Parts(s)
	return xxh3.Uint128{Hi: hi, Lo: lo}
}

func tststXXH3Parts(s string) (hi, lo uint64) {
	l := len(s)
	switch {
	case l <= 16:
		switch {
		case l > 8:
			bitflipl := tststK64(32) ^ tststK64(40)
			bitfliph := tststK64(48) ^ tststK64(56)
			inLo := tststU64(s, 0)
			inHi := tststU64(s, l-8)
			mh, ml := bits.Mul64(inLo^inHi^bitflipl, tststP64_1)
			ml += uint64(l-1) << 54
			inHi ^= bitfliph
			mh += inHi + uint64(uint32(inHi))*(tststP32_2-1)
			ml ^= bits.ReverseBytes64(mh)
			hi, lo = bits.Mul64(ml, tststP64_2)
			hi += mh * tststP64_2
			return tststAvalanche(hi), tststAvalanche(lo)
		case l > 3:
			bitflip := tststK64(16) ^ tststK64(24)
			in64 := uint64(tststU32(s, 0)) + uint64(tststU32(s, l-4))<<32
			hi, lo = bits.Mul64(in64^bitflip, tststP64_1+uint64(l)<<2)
			hi += lo << 1
			lo ^= hi >> 3
			lo ^= lo >> 35
			lo *= 0x9fb21c651e98df25
			lo ^= lo >> 28
			return tststAvalanche(hi), lo
		case l == 3:
			c12 := uint64(s[0]) | uint64(s[1])<<8
			lo = c12<<16 + uint64(s[2]) + 3<<8
		case l == 2:
			c12 := uint64(s[0]) | uint64(s[1])<<8
			lo = c12*(1<<24+1)>>8 + 2<<8
		case l == 1:
			lo = uint64(s[0])*(1<<24+1<<16+1) + 1<<8
		default:
			return 0x99aa06d3014798d8, 0x6001c324468d497f
		}
		hi = uint64(bits.RotateLeft32(bits.ReverseBytes32(uint32(lo)), 13))
		lo ^= uint64(tststU32(tststXXHKey, 0) ^ tststU32(tststXXHKey, 4))
		hi ^= uint64(tststU32(tststXXHKey, 8) ^ tststU32(tststXXHKey, 12))
		return tststAvalancheSmall(hi), tststAvalancheSmall(lo)

	case l <= 128:
		lo = uint64(l) * tststP64_1
		for i := (l - 1) / 32; i >= 0; i-- {
			// pairs from both ends, the outermost first
			a0, a1 := tststU64(s, 16*i), tststU64(s, 16*i+8)
			b0, b1 := tststU64(s, l-16*i-16), tststU64(s, l-16*i-8)
			hi += tststMulFold(b0^tststK64(32*i+16), b1^tststK64(32*i+24))
			hi ^= a0 + a1
			lo += tststMulFold(a0^tststK64(32*i), a1^tststK64(32*i+8))
			lo ^= b0 + b1
		}
		hi, lo = lo*tststP64_1+hi*tststP64_4+uint64(l)*tststP64_2, hi+lo
		return -tststAvalanche(hi), tststAvalanche(lo)

	case l <= 240:
		lo = uint64(l) * tststP64_1
		for i := 0; i < 4; i++ {
			i0, i1, i2, i3 := tststU64(s, 32*i), tststU64(s, 32*i+8), tststU64(s, 32*i+16), tststU64(s, 32*i+24)
			hi += tststMulFold(i2^tststK64(32*i+16), i3^tststK64(32*i+24))
			hi ^= i0 + i1
			lo += tststMulFold(i0^tststK64(32*i), i1^tststK64(32*i+8))
			lo ^= i2 + i3
		}
		hi, lo = tststAvalanche(hi), tststAvalanche(lo)
		top := l &^ 31
		for i := 128; i < top; i += 32 {
			i0, i1, i2, i3 := tststU64(s, i), tststU64(s, i+8), tststU64(s, i+16), tststU64(s, i+24)
			hi += tststMulFold(i2^tststK64(i-125+16), i3^tststK64(i-125+24))
			hi ^= i0 + i1
			lo += tststMulFold(i0^tststK64(i-125), i1^tststK64(i-125+8))
			lo ^= i2 + i3
		}
		i0, i1, i2, i3 := tststU64(s, l-32), tststU64(s, l-24), tststU64(s, l-16), tststU64(s, l-8)
		hi += tststMulFold(i0^tststK64(119), i1^tststK64(127))
		hi ^= i2 + i3
		lo += tststMulFold(i2^tststK64(103), i3^tststK64(111))
		lo ^= i0 + i1
		hi, lo = lo*tststP64_1+hi*tststP64_4+uint64(l)*tststP64_2, hi+lo
		return -tststAvalanche(hi), tststAvalanche(lo)
	}

	lo = uint64(l) * tststP64_1
	hi = ^(uint64(l) * tststP64_2)
	accs := tststAccumulate(s)
	for j := 0; j < 4; j++ {
		lo += tststMulFold(accs[2*j]^tststK64(11+16*j), accs[2*j+1]^tststK64(19+16*j))
		hi += tststMulFold(accs[2*j]^tststK64(117+16*j), accs[2*j+1]^tststK64(125+16*j))
	}
	return tststAvalanche(hi), tststAvalanche(lo)
}

func tststRrmxmx(h, l uint64) uint64 {
	h ^= bits.RotateLeft64(h, 49) ^ bits.RotateLeft64(h, 24)
	h *= 0x9fb21c651e98df25
	h ^= (h >> 35) + l
	h *= 0x9fb21c651e98df25
	h ^= h >> 28
	return h
}

func tststHash64(s string) uint64 {
	l := len(s)
	var acc uint64
	switch {
	case l <= 16:
		switch {
		case l > 8:
			inLo := tststU64(s, 0) ^ (tststK64(24) ^ tststK64(32))
			inHi := tststU64(s, l-8) ^ (tststK64(40) ^ tststK64(48))
			folded := tststMulFold(inLo, inHi)
			return tststAvalanche(uint64(l) + bits.ReverseBytes64(inLo) + inHi + folded)
		case l > 3:
			in64 := uint64(tststU32(s, l-4)) + uint64(tststU32(s, 0))<<32
			return tststRrmxmx(in64^(tststK64(8)^tststK64(16)), uint64(l))
		case l == 3:
			c12 := uint64(s[0]) | uint64(s[1])<<8
			acc = c12<<16 + uint64(s[2]) + 3<<8
		case l == 2:
			c12 := uint64(s[0]) | uint64(s[1])<<8
			acc = c12*(1<<24+1)>>8 + 2<<8
		case l == 1:
			acc = uint64(s[0])*(1<<24+1<<16+1) + 1<<8
		default:
			return 0x2d06800538d394c2
		}
		acc ^= uint64(tststU32(tststXXHKey, 0) ^ tststU32(tststXXHKey, 4))
		acc ^= acc >> 33
		return tststAvalancheSmall(acc)
	case l <= 128:
		acc = uint64(l) * tststP64_1
		for i := (l - 1) / 32; i >= 0; i-- {
			acc += tststMulFold(tststU64(s, 16*i)^tststK64(32*i), tststU64(s, 16*i+8)^tststK64(32*i+8))
			acc += tststMulFold(tststU64(s, l-16*i-16)^tststK64(32*i+16), tststU64(s, l-16*i-8)^tststK64(32*i+24))
		}
		return tststAvalanche(acc)
	case l <= 240:
		acc = uint64(l) * tststP64_1
		for i := 0; i < 8; i++ {
			acc += tststMulFold(tststU64(s, 16*i)^tststK64(16*i), tststU64(s, 16*i+8)^tststK64(16*i+8))
		}
		acc = tststAvalanche(acc)
		top := l &^ 15
		for i := 128; i < top; i += 16 {
			acc += tststMulFold(tststU64(s, i)^tststK64(i-125), tststU64(s, i+8)^tststK64(i-117))
		}
		acc += tststMulFold(tststU64(s, l-16)^tststK64(119), tststU64(s, l-8)^tststK64(127))
		return tststAvalanche(acc)
	}
	acc = uint64(l) * tststP64_1
	accs := tststAccumulate(s)
	for j := 0; j < 4; j++ {
		acc += tststMulFold(accs[2*j]^tststK64(11+16*j), accs[2*j+1]^tststK64(19+16*j))
	}
	return tststAvalanche(acc)
}

// the long-input accumulators (more than 240 bytes)
func tststAccumulate(s string) [8]uint64 {
	accs := [8]uint64{tststP32_3, tststP64_1, tststP64_2, tststP64_3, tststP64_4, tststP32_2, tststP64_5, tststP32_1}
	d, rest := 0, len(s)
	for rest > 1024 {
		for i := 0; i < 16; i++ {
			tststStripe(&accs, s, d, 8*i)
			d += 64
			rest -= 64
		}
		for j := 0; j < 8; j++ {
			accs[j] ^= accs[j] >> 47
			accs[j] ^= tststK64(128 + 8*j)
			accs[j] *= tststP32_1
		}
	}
	if rest > 0 {
		t := (rest - 1) / 64
		for i := 0; i < t; i++ {
			tststStripe(&accs, s, d, 8*i)
			d += 64
			rest -= 64
		}
		tststStripe(&accs, s, len(s)-64, 121)
	}
	return accs
}

func tststXXH3Hash(b []byte) uint64       { return tststHash64(string(b)) }
func tststXXH3HashString(s string) uint64 { return tststHash64(s) }

// what each Hasher has been given (made on first use, not by the package's
// init: with several test binaries in one program the redirects reach the
// functions of one variant of this package, whose init only that package's
// test binary runs)
var tststHashers map[*xxh3.Hasher][]byte

func tststHasherWrite(h *xxh3.Hasher, b []byte) (int, error) {
	if tststHashers == nil {
		tststHashers = map[*xxh3.Hasher][]byte{}
	}
	tststHashers[h] = append(tststHashers[h], b...)
	return len(b), nil
}

func tststHasherWriteString(h *xxh3.Hasher, s string) (int, error) {
	if tststHashers == nil {
		tststHashers = map[*xxh3.Hasher][]byte{}
	}
	tststHashers[h] = append(tststHashers[h], s...)
	return len(s), nil
}

func tststHasherReset(h *xxh3.Hasher)               { delete(tststHashers, h) }
func tststHasherSum64(h *xxh3.Hasher) uint64        { return tststHash64(string(tststHashers[h])) }
func tststHasherSum128(h *xxh3.Hasher) xxh3.Uint128 { return tststHash128(string(tststHashers[h])) }
