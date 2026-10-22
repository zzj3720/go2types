package main

func main() {
	s := "héllo, wörld"
	n := 0
	for _, ch := range s {
		if ch > 127 {
			n++
		}
	}
	println("str", len(s), n, s[1:5], string(rune(0x4e16)))
	b := []byte(s)
	b[0] = 'H'
	println(string(b))
}
