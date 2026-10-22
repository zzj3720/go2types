package main

import (
	"errors"
	"fmt"
	"os"
	"time"
)

var calls int

func fakeRead(buf []byte) (int, error) {
	calls++
	if calls > 5 {
		panic("read loops")
	}
	return -1, errors.New("no such file")
}

func closeIt() { fmt.Println("closed") }

// the shape of time.readFile: a loop over named locals in a function with a defer
func readAll() ([]byte, error) {
	defer closeIt()
	var (
		buf [16]byte
		ret []byte
		n   int
		err error
	)
	for {
		n, err = fakeRead(buf[:])
		if n > 0 {
			ret = append(ret, buf[:n]...)
		}
		if n == 0 || err != nil {
			break
		}
	}
	return ret, err
}

func main() {
	b, err := readAll()
	fmt.Println(len(b), err, calls)
	_, err = os.ReadFile("/nowhere/file.txt")
	fmt.Println("readfile error:", err != nil, errors.Is(err, os.ErrNotExist), os.IsNotExist(err))
	fmt.Println(err)
	_, err = time.LoadLocation("Nowhere/City")
	fmt.Println("loadlocation error:", err != nil)
	fmt.Println(time.Unix(0, 0).UTC().Format(time.RFC3339))
}
