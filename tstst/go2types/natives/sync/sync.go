// Replacement for package sync on the tstst runtime. Goroutines run one at a
// time and switch only when one parks (waits until another wakes it), so the
// state here needs no atomics: waiting is a loop around tststPark, and every
// change others may wait for ends with tststWake.
package sync

// tstst intrinsics
func tststPark()
func tststWake()

type Locker interface {
	Lock()
	Unlock()
}

type noCopy struct{}

type Mutex struct{ locked bool }

func (m *Mutex) Lock() {
	for m.locked {
		tststPark()
	}
	m.locked = true
}

func (m *Mutex) Unlock() {
	if !m.locked {
		fatal("sync: unlock of unlocked mutex")
	}
	m.locked = false
	tststWake()
}

func (m *Mutex) TryLock() bool {
	if m.locked {
		return false
	}
	m.locked = true
	return true
}

func fatal(s string) { panic(s) }

type RWMutex struct {
	writer  bool
	readers int
	waiting int // writers waiting: new readers wait for them
}

func (rw *RWMutex) Lock() {
	rw.waiting++
	for rw.writer || rw.readers > 0 {
		tststPark()
	}
	rw.waiting--
	rw.writer = true
}

func (rw *RWMutex) Unlock() {
	if !rw.writer {
		fatal("sync: Unlock of unlocked RWMutex")
	}
	rw.writer = false
	tststWake()
}

func (rw *RWMutex) RLock() {
	for rw.writer || rw.waiting > 0 {
		tststPark()
	}
	rw.readers++
}

func (rw *RWMutex) RUnlock() {
	if rw.readers <= 0 {
		fatal("sync: RUnlock of unlocked RWMutex")
	}
	rw.readers--
	if rw.readers == 0 {
		tststWake()
	}
}

func (rw *RWMutex) TryLock() bool {
	if rw.writer || rw.readers > 0 {
		return false
	}
	rw.writer = true
	return true
}

func (rw *RWMutex) TryRLock() bool {
	if rw.writer || rw.waiting > 0 {
		return false
	}
	rw.readers++
	return true
}

func (rw *RWMutex) RLocker() Locker { return (*rlocker)(rw) }

type rlocker RWMutex

func (r *rlocker) Lock()   { (*RWMutex)(r).RLock() }
func (r *rlocker) Unlock() { (*RWMutex)(r).RUnlock() }

type Once struct {
	m    Mutex
	done bool
}

func (o *Once) Do(f func()) {
	if o.done {
		return
	}
	// (no defer: Once is on hot paths; a panicking f leaves the Once locked)
	o.m.Lock()
	if !o.done {
		f()
		o.done = true
	}
	o.m.Unlock()
}

func OnceFunc(f func()) func() {
	var once Once
	return func() { once.Do(f) }
}

func OnceValue[T any](f func() T) func() T {
	var once Once
	var result T
	return func() T {
		once.Do(func() { result = f() })
		return result
	}
}

func OnceValues[T1, T2 any](f func() (T1, T2)) func() (T1, T2) {
	var once Once
	var r1 T1
	var r2 T2
	return func() (T1, T2) {
		once.Do(func() { r1, r2 = f() })
		return r1, r2
	}
}

type WaitGroup struct{ n int }

func (wg *WaitGroup) Add(delta int) {
	wg.n += delta
	if wg.n < 0 {
		fatal("sync: negative WaitGroup counter")
	}
	if wg.n == 0 {
		tststWake()
	}
}

func (wg *WaitGroup) Done() { wg.Add(-1) }

func (wg *WaitGroup) Wait() {
	for wg.n > 0 {
		tststPark()
	}
}

func (wg *WaitGroup) Go(f func()) {
	wg.Add(1)
	go func() {
		defer wg.Done()
		f()
	}()
}

type Cond struct {
	L       Locker
	signals int // wakeups not yet taken
	waiters int
	gen     int
}

func NewCond(l Locker) *Cond { return &Cond{L: l} }

func (c *Cond) Wait() {
	c.waiters++
	gen := c.gen
	c.L.Unlock()
	for c.gen == gen && c.signals == 0 {
		tststPark()
	}
	if c.gen == gen {
		c.signals--
	}
	c.waiters--
	c.L.Lock()
}

func (c *Cond) Signal() {
	if c.waiters > c.signals {
		c.signals++
		tststWake()
	}
}

func (c *Cond) Broadcast() {
	c.gen++
	c.signals = 0
	tststWake()
}

type Pool struct {
	items []any
	New   func() any
}

func (p *Pool) Get() any {
	if n := len(p.items); n > 0 {
		x := p.items[n-1]
		p.items = p.items[:n-1]
		return x
	}
	if p.New != nil {
		return p.New()
	}
	return nil
}

func (p *Pool) Put(x any) {
	if x != nil {
		p.items = append(p.items, x)
	}
}

type Map struct {
	m    map[any]any
	keys []any
}

func (m *Map) Load(key any) (value any, ok bool) {
	value, ok = m.m[key]
	return
}

func (m *Map) Store(key, value any) {
	if m.m == nil {
		m.m = map[any]any{}
	}
	if _, ok := m.m[key]; !ok {
		m.keys = append(m.keys, key)
	}
	m.m[key] = value
}

func (m *Map) LoadOrStore(key, value any) (actual any, loaded bool) {
	if v, ok := m.m[key]; ok {
		return v, true
	}
	m.Store(key, value)
	return value, false
}

func (m *Map) LoadAndDelete(key any) (value any, loaded bool) {
	value, loaded = m.m[key]
	if loaded {
		m.Delete(key)
	}
	return
}

func (m *Map) Delete(key any) {
	if _, ok := m.m[key]; !ok {
		return
	}
	delete(m.m, key)
	for i, k := range m.keys {
		if k == key {
			m.keys = append(m.keys[:i:i], m.keys[i+1:]...)
			break
		}
	}
}

func (m *Map) Swap(key, value any) (previous any, loaded bool) {
	previous, loaded = m.m[key]
	m.Store(key, value)
	return
}

func (m *Map) CompareAndSwap(key, old, new any) bool {
	if v, ok := m.m[key]; ok && v == old {
		m.m[key] = new
		return true
	}
	return false
}

func (m *Map) CompareAndDelete(key, old any) bool {
	if v, ok := m.m[key]; ok && v == old {
		m.Delete(key)
		return true
	}
	return false
}

func (m *Map) Range(f func(key, value any) bool) {
	keys := append([]any(nil), m.keys...)
	for _, k := range keys {
		v, ok := m.m[k]
		if !ok {
			continue
		}
		if !f(k, v) {
			break
		}
	}
}

func (m *Map) Clear() {
	m.m = nil
	m.keys = nil
}
