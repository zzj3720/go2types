package main

import (
	"bytes"
	"errors"
	"fmt"
	"reflect"
	"strings"
	"text/template"
)

type point struct{ X, Y int }

func add(a, b int) int { return a + b }

func join(sep string, parts ...string) string { return strings.Join(parts, sep) }

func div(a, b int) (int, error) {
	if b == 0 {
		return 0, errors.New("division by zero")
	}
	return a / b, nil
}

func main() {
	r := reflect.ValueOf(add).Call([]reflect.Value{reflect.ValueOf(2), reflect.ValueOf(3)})
	fmt.Println(len(r), r[0].Int())
	r = reflect.ValueOf(join).Call([]reflect.Value{reflect.ValueOf("-"), reflect.ValueOf("a"), reflect.ValueOf("b"), reflect.ValueOf("c")})
	fmt.Println(r[0].String())
	r = reflect.ValueOf(div).Call([]reflect.Value{reflect.ValueOf(7), reflect.ValueOf(0)})
	fmt.Println(r[0].Int(), r[1].Interface())
	r = reflect.ValueOf(div).Call([]reflect.Value{reflect.ValueOf(7), reflect.ValueOf(2)})
	fmt.Println(r[0].Int(), r[1].IsNil())
	sum := 0
	reflect.ValueOf(func(p point) { sum = p.X + p.Y }).Call([]reflect.Value{reflect.ValueOf(point{4, 5})})
	fmt.Println(sum)

	tmpl := template.Must(template.New("t").Funcs(template.FuncMap{
		"add":   add,
		"upper": strings.ToUpper,
		"pt":    func(x int) point { return point{x, x * 2} },
	}).Parse(`{{ .Data.name | upper }} {{ add 1 .Data.n }} {{ (pt 3).Y }}{{ range .Data.list }} [{{ . }}]{{ end }}{{ if .Data.flag }} yes{{ end }}`))
	var buf bytes.Buffer
	err := tmpl.Execute(&buf, map[string]any{"Data": map[string]any{"name": "go", "n": 41, "list": []string{"x", "y"}, "flag": true}})
	fmt.Println(buf.String(), err)
}
