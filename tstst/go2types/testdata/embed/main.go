// Package main: string variables initialized by //go:embed, one of them gzip
// bytes (as tsgo's localized diagnostics): the translator puts the files'
// contents into the initial heap, from the file system or from a pack.
package main

import (
	"compress/gzip"
	_ "embed"
	"fmt"
	"io"
	"strings"
)

//go:embed greeting.txt
var greeting string

// data.json.gz: a JSON object, gzip-compressed
//
//go:embed data.json.gz
var dataGz string

var (
	//go:embed greeting.txt
	again string
	plain = "not embedded"
)

func main() {
	fmt.Printf("%q\n", greeting)
	fmt.Println(again == greeting, plain)
	fmt.Println(len(dataGz), strings.HasPrefix(dataGz, "\x1f\x8b"))
	r, err := gzip.NewReader(strings.NewReader(dataGz))
	if err != nil {
		fmt.Println("gzip:", err)
		return
	}
	b, err := io.ReadAll(r)
	fmt.Println(string(b), err)
}
