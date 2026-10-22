// Reflection and encoding/json/v2 on the tstst runtime.
package main

import (
	"encoding/json/jsontext"
	"encoding/json/v2"
	"fmt"
	"reflect"
	"strings"
)

type Inner struct {
	A int    `json:"a"`
	B string `json:"b,omitempty"`
}

type Outer struct {
	Name    string         `json:"name"`
	Count   int64          `json:"count,omitzero"`
	Ratio   float64        `json:"ratio"`
	Ok      bool           `json:"ok"`
	Tags    []string       `json:"tags"`
	Inner   Inner          `json:"inner"`
	Ptr     *Inner         `json:"ptr,omitempty"`
	Map     map[string]int `json:"map"`
	Any     any            `json:"any"`
	Nested  [][]int        `json:"nested"`
	private int
}

type Color int

func (c Color) MarshalText() ([]byte, error) { return []byte(strings.Repeat("*", int(c))), nil }

type custom struct{ v string }

func (c *custom) UnmarshalJSONFrom(dec *jsontext.Decoder) error {
	tok, err := dec.ReadToken()
	if err != nil {
		return err
	}
	c.v = "<" + tok.String() + ">"
	return nil
}

func main() {
	o := Outer{Name: "x", Count: 3, Ratio: 0.5, Ok: true, Tags: []string{"a", "b"}, Inner: Inner{A: 1},
		Ptr: &Inner{A: 2, B: "two"}, Map: map[string]int{"k": 1, "j": 2}, Any: []any{1.5, "s", nil}, Nested: [][]int{{1}, {2, 3}}}
	b, err := json.Marshal(o, json.Deterministic(true))
	fmt.Println(string(b), err == nil)

	var back Outer
	err = json.Unmarshal(b, &back)
	fmt.Println(back.Name, back.Count, back.Ratio, back.Ok, len(back.Tags), back.Tags[1], back.Inner.A, back.Ptr.B, back.Map["j"], len(back.Any.([]any)), back.Nested[1][1], err == nil)
	fmt.Println(reflect.DeepEqual(o, back), reflect.DeepEqual(o.Tags, back.Tags))

	var m map[string]any
	err = json.Unmarshal([]byte(`{"z":[1,{"q":true}],"y":"é"}`), &m)
	fmt.Println(len(m), m["y"], err == nil)
	b, _ = json.Marshal(m, json.Deterministic(true))
	fmt.Println(string(b))

	b, _ = json.Marshal(map[Color]Color{1: 2, 3: 1}, json.Deterministic(true))
	fmt.Println(string(b))

	var c custom
	fmt.Println(json.Unmarshal([]byte(`"hello"`), &c) == nil, c.v)

	err = json.Unmarshal([]byte(`{"name": 5}`), &back)
	fmt.Println(err != nil)

	t := reflect.TypeFor[Outer]()
	fmt.Println(t.Kind(), t.NumField(), t.Field(1).Name, t.Field(1).Tag.Get("json"), t.Field(10).IsExported())
	v := reflect.ValueOf(&o).Elem()
	v.Field(0).SetString("changed")
	v.FieldByName("Tags").Index(1).SetString("B")
	fmt.Println(o.Name, o.Tags[1], v.Field(7).Len(), v.Field(7).MapIndex(reflect.ValueOf("k")).Int())
	keys := 0
	for it := v.Field(7).MapRange(); it.Next(); {
		keys += int(it.Value().Int())
	}
	fmt.Println(keys)
	s := reflect.MakeSlice(reflect.TypeFor[[]int](), 0, 1)
	s = reflect.Append(s, reflect.ValueOf(4), reflect.ValueOf(5))
	fmt.Println(s.Interface().([]int)[1], s.Len())
	p := reflect.New(reflect.TypeFor[Inner]())
	p.Elem().Field(0).SetInt(42)
	fmt.Println(p.Elem().Interface().(Inner).A, p.Interface().(*Inner).A)
	type Base struct{ ID int }
	type Outer struct {
		Base
		Name string
		hid  bool
	}
	for _, f := range reflect.VisibleFields(reflect.TypeFor[Outer]()) {
		fmt.Print(f.Name, f.Index, f.Anonymous, " ")
	}
	fmt.Println()
	for f, fv := range reflect.ValueOf(Outer{Base{7}, "n", true}).Fields() {
		fmt.Print(f.Name, "=", fv, " ")
	}
	fmt.Println()
	fmt.Printf("%v %+v\n", Outer{Base{1}, "x", false}, []Inner{{A: 3}})
}
