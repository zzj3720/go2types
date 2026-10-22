// Single-threaded replacement for package sync/atomic.
package atomic

import "unsafe"

func SwapInt32(addr *int32, new int32) (old int32)       { old = *addr; *addr = new; return }
func SwapInt64(addr *int64, new int64) (old int64)       { old = *addr; *addr = new; return }
func SwapUint32(addr *uint32, new uint32) (old uint32)   { old = *addr; *addr = new; return }
func SwapUint64(addr *uint64, new uint64) (old uint64)   { old = *addr; *addr = new; return }
func SwapUintptr(addr *uintptr, new uintptr) (old uintptr) { old = *addr; *addr = new; return }
func SwapPointer(addr *unsafe.Pointer, new unsafe.Pointer) (old unsafe.Pointer) {
	old = *addr
	*addr = new
	return
}

func CompareAndSwapInt32(addr *int32, old, new int32) bool {
	if *addr == old { *addr = new; return true }
	return false
}
func CompareAndSwapInt64(addr *int64, old, new int64) bool {
	if *addr == old { *addr = new; return true }
	return false
}
func CompareAndSwapUint32(addr *uint32, old, new uint32) bool {
	if *addr == old { *addr = new; return true }
	return false
}
func CompareAndSwapUint64(addr *uint64, old, new uint64) bool {
	if *addr == old { *addr = new; return true }
	return false
}
func CompareAndSwapUintptr(addr *uintptr, old, new uintptr) bool {
	if *addr == old { *addr = new; return true }
	return false
}
func CompareAndSwapPointer(addr *unsafe.Pointer, old, new unsafe.Pointer) bool {
	if *addr == old { *addr = new; return true }
	return false
}

func AddInt32(addr *int32, delta int32) (new int32)       { *addr += delta; return *addr }
func AddUint32(addr *uint32, delta uint32) (new uint32)   { *addr += delta; return *addr }
func AddInt64(addr *int64, delta int64) (new int64)       { *addr += delta; return *addr }
func AddUint64(addr *uint64, delta uint64) (new uint64)   { *addr += delta; return *addr }
func AddUintptr(addr *uintptr, delta uintptr) (new uintptr) { *addr += delta; return *addr }

func AndInt32(addr *int32, mask int32) (old int32)     { old = *addr; *addr &= mask; return }
func AndUint32(addr *uint32, mask uint32) (old uint32) { old = *addr; *addr &= mask; return }
func AndInt64(addr *int64, mask int64) (old int64)     { old = *addr; *addr &= mask; return }
func AndUint64(addr *uint64, mask uint64) (old uint64) { old = *addr; *addr &= mask; return }
func OrInt32(addr *int32, mask int32) (old int32)      { old = *addr; *addr |= mask; return }
func OrUint32(addr *uint32, mask uint32) (old uint32)  { old = *addr; *addr |= mask; return }
func OrInt64(addr *int64, mask int64) (old int64)      { old = *addr; *addr |= mask; return }
func OrUint64(addr *uint64, mask uint64) (old uint64)  { old = *addr; *addr |= mask; return }

func LoadInt32(addr *int32) int32                    { return *addr }
func LoadInt64(addr *int64) int64                    { return *addr }
func LoadUint32(addr *uint32) uint32                 { return *addr }
func LoadUint64(addr *uint64) uint64                 { return *addr }
func LoadUintptr(addr *uintptr) uintptr              { return *addr }
func LoadPointer(addr *unsafe.Pointer) unsafe.Pointer { return *addr }

func StoreInt32(addr *int32, val int32)                    { *addr = val }
func StoreInt64(addr *int64, val int64)                    { *addr = val }
func StoreUint32(addr *uint32, val uint32)                 { *addr = val }
func StoreUint64(addr *uint64, val uint64)                 { *addr = val }
func StoreUintptr(addr *uintptr, val uintptr)              { *addr = val }
func StorePointer(addr *unsafe.Pointer, val unsafe.Pointer) { *addr = val }

type noCopy struct{}
type align64 struct{}

type Bool struct{ v uint32 }

func (x *Bool) Load() bool { return x.v != 0 }
func (x *Bool) Store(val bool) { x.v = b32(val) }
func (x *Bool) Swap(new bool) (old bool) { old = x.v != 0; x.v = b32(new); return }
func (x *Bool) CompareAndSwap(old, new bool) (swapped bool) {
	if (x.v != 0) == old { x.v = b32(new); return true }
	return false
}

func b32(b bool) uint32 {
	if b {
		return 1
	}
	return 0
}

type Pointer[T any] struct {
	v *T
}

func (x *Pointer[T]) Load() *T { return x.v }
func (x *Pointer[T]) Store(val *T) { x.v = val }
func (x *Pointer[T]) Swap(new *T) (old *T) { old = x.v; x.v = new; return }
func (x *Pointer[T]) CompareAndSwap(old, new *T) (swapped bool) {
	if x.v == old { x.v = new; return true }
	return false
}

type Int32 struct{ v int32 }

func (x *Int32) Load() int32 { return x.v }
func (x *Int32) Store(val int32) { x.v = val }
func (x *Int32) Swap(new int32) (old int32) { old = x.v; x.v = new; return }
func (x *Int32) CompareAndSwap(old, new int32) (swapped bool) {
	if x.v == old { x.v = new; return true }
	return false
}
func (x *Int32) Add(delta int32) (new int32) { x.v += delta; return x.v }
func (x *Int32) And(mask int32) (old int32) { old = x.v; x.v &= mask; return }
func (x *Int32) Or(mask int32) (old int32) { old = x.v; x.v |= mask; return }

type Int64 struct{ v int64 }

func (x *Int64) Load() int64 { return x.v }
func (x *Int64) Store(val int64) { x.v = val }
func (x *Int64) Swap(new int64) (old int64) { old = x.v; x.v = new; return }
func (x *Int64) CompareAndSwap(old, new int64) (swapped bool) {
	if x.v == old { x.v = new; return true }
	return false
}
func (x *Int64) Add(delta int64) (new int64) { x.v += delta; return x.v }
func (x *Int64) And(mask int64) (old int64) { old = x.v; x.v &= mask; return }
func (x *Int64) Or(mask int64) (old int64) { old = x.v; x.v |= mask; return }

type Uint32 struct{ v uint32 }

func (x *Uint32) Load() uint32 { return x.v }
func (x *Uint32) Store(val uint32) { x.v = val }
func (x *Uint32) Swap(new uint32) (old uint32) { old = x.v; x.v = new; return }
func (x *Uint32) CompareAndSwap(old, new uint32) (swapped bool) {
	if x.v == old { x.v = new; return true }
	return false
}
func (x *Uint32) Add(delta uint32) (new uint32) { x.v += delta; return x.v }
func (x *Uint32) And(mask uint32) (old uint32) { old = x.v; x.v &= mask; return }
func (x *Uint32) Or(mask uint32) (old uint32) { old = x.v; x.v |= mask; return }

type Uint64 struct{ v uint64 }

func (x *Uint64) Load() uint64 { return x.v }
func (x *Uint64) Store(val uint64) { x.v = val }
func (x *Uint64) Swap(new uint64) (old uint64) { old = x.v; x.v = new; return }
func (x *Uint64) CompareAndSwap(old, new uint64) (swapped bool) {
	if x.v == old { x.v = new; return true }
	return false
}
func (x *Uint64) Add(delta uint64) (new uint64) { x.v += delta; return x.v }
func (x *Uint64) And(mask uint64) (old uint64) { old = x.v; x.v &= mask; return }
func (x *Uint64) Or(mask uint64) (old uint64) { old = x.v; x.v |= mask; return }

type Uintptr struct{ v uintptr }

func (x *Uintptr) Load() uintptr { return x.v }
func (x *Uintptr) Store(val uintptr) { x.v = val }
func (x *Uintptr) Swap(new uintptr) (old uintptr) { old = x.v; x.v = new; return }
func (x *Uintptr) CompareAndSwap(old, new uintptr) (swapped bool) {
	if x.v == old { x.v = new; return true }
	return false
}
func (x *Uintptr) Add(delta uintptr) (new uintptr) { x.v += delta; return x.v }

type Value struct {
	v any
}

func (v *Value) Load() (val any) { return v.v }
func (v *Value) Store(val any) {
	if val == nil {
		panic("sync/atomic: store of nil value into Value")
	}
	v.v = val
}
func (v *Value) Swap(new any) (old any) { old = v.v; v.v = new; return }
func (v *Value) CompareAndSwap(old, new any) (swapped bool) {
	if v.v == old { v.v = new; return true }
	return false
}
