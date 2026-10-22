// Portions Copyright 2009 The Go Authors (derived from Go's reflect/type.go and value.go). Use of
// this source code is governed by a BSD-style license: see LICENSE-GO.

package reflect

import "iter"

// Iterators over struct fields (as in the real package's type.go and value.go).

func (t rtype) Fields() iter.Seq[StructField] {
	if t.Kind() != Struct {
		panic("reflect: Fields of non-struct type " + t.String())
	}
	return func(yield func(StructField) bool) {
		for i := range t.NumField() {
			if !yield(t.Field(i)) {
				return
			}
		}
	}
}

func (v Value) Fields() iter.Seq2[StructField, Value] {
	t := v.Type()
	if t.Kind() != Struct {
		panic("reflect: Fields of non-struct type " + t.String())
	}
	return func(yield func(StructField, Value) bool) {
		for i := range v.NumField() {
			if !yield(t.Field(i), v.Field(i)) {
				return
			}
		}
	}
}
