package main

func main() {
	m := map[string]int{}
	m["x"] = 1
	m["y"] = 2
	m["x"] += 10
	v, ok := m["z"]
	println("map", m["x"], m["y"], len(m), v, ok)
}
