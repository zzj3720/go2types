// Replacement for package unique: values are interned in a map, so handles
// to equal values are equal.
package unique

type Handle[T comparable] struct {
	value *T
}

func (h Handle[T]) Value() T { return *h.value }

var interned = map[any]any{}

func Make[T comparable](value T) Handle[T] {
	if p, ok := interned[value]; ok {
		return Handle[T]{p.(*T)}
	}
	p := new(T)
	*p = value
	interned[value] = p
	return Handle[T]{p}
}
