package main

import (
	"encoding/hex"

	"github.com/zeebo/xxh3"
)

// XXH3-128 of strings of every length through the 240-byte paths and of a
// few long ones (one and more 1024-byte blocks), printed the way tsgo's
// incremental.ComputeHash prints file versions
func main() {
	data := make([]byte, 2200)
	x := uint32(2463534242)
	for i := range data {
		x ^= x << 13
		x ^= x >> 17
		x ^= x << 5
		data[i] = byte(x >> 7)
	}
	lengths := []int{}
	for n := 0; n <= 260; n++ {
		lengths = append(lengths, n)
	}
	lengths = append(lengths, 511, 1023, 1024, 1025, 1088, 2048, 2049, 2200)
	for _, n := range lengths {
		h := xxh3.HashString128(string(data[:n])).Bytes()
		b := xxh3.Hash128(data[2200-n:]).Bytes()
		println(n, hex.EncodeToString(h[:]), hex.EncodeToString(b[:]))
	}
	text := "export function foo() { return 1; }"
	h := xxh3.HashString128(text).Bytes()
	println(hex.EncodeToString(h[:]) + "-" + text)
}
