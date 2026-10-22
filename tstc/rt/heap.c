// The store of cells lib/pure declares (heap.ts: @store, see store.mbt): an
// array of cells, updated in place.
//
// Programs thread the heap linearly: each write makes a new version, and
// only the newest is used again. A heap value is an immediate naming the
// heap and its version (no allocation per write); using an older version is
// an error (die), which keeps a program that is not linear from silently
// seeing later writes. Cell 0 holds the allocation pointer. Pointers are
// cell indices or null; slices are [ptr | null, len, cap]; multi-cell values
// (structs, arrays) are laid out flat, strides are in cells.
//
// Cells nobody can reach any more are freed and reused (cellgc.c, when the
// store declares @store-reuse); the
// allocating natives are the collector's safe points.
#include "lib.h"

#include <stdio.h>
#include <stdlib.h>

HeapT *heap_latest;
#define MAX_HEAPS 128
static HeapT *heaps[MAX_HEAPS];
// the first store, at an address the inline cell accesses of generated
// code have as a constant (codegen.mbt's prelude: tstc_hget, ...); the
// layout they read
HeapT tstc_store0;
#define heap0 tstc_store0
_Static_assert(offsetof(HeapT, cells) == 8 && offsetof(HeapT, len) == 16 && offsetof(HeapT, version) == 32 &&
                   offsetof(HeapT, gc) == 40,
               "the layout codegen.mbt's prelude reads");
static uint32_t nheaps;

// the value naming the heap's current version
V heap_v(HeapT *h) { return ((V)h->version << 16) | ((V)h->id << 9) | ((V)K_STORE << 3) | 2; }

HeapT *heap_of(V t) {
  if ((t & 3) != 2 || kind(t) != K_STORE) die("expected a heap, got %s", ty_to_cstr_short(t));
  uint32_t id = (uint32_t)((t >> 9) & (MAX_HEAPS - 1));
  HeapT *h = id < nheaps ? heaps[id] : NULL;
  if (!h) die("expected a heap, got %s", ty_to_cstr_short(t));
  if ((t >> 16) != h->version)
    die("an older version of the heap is used (version %llu, the heap is at %llu): the program does not "
        "use its heap linearly",
        (unsigned long long)(t >> 16), (unsigned long long)h->version);
  return h;
}

V *heap_cells(HeapT *self, int64_t *len) {
  *len = self->len;
  return self->cells;
}

V heap_get(HeapT *h, int64_t i) {
  if (i < 0 || i >= h->len) die("invalid memory address %lld", (long long)i);
  V v = h->cells[i];
  if (cell_dead(v)) cells_dead_cell(h, i, "load");
  return v;
}

// the cells are reserved address space: nothing moves
static void heap_reserve(HeapT *h, int64_t n) {
  if (n > h->cap) die("out of memory: the cell store has %lld cells", (long long)h->cap);
}

// cells up to n exist (writes past the allocation pointer)
static void heap_extend(HeapT *h, int64_t n) {
  heap_reserve(h, n);
  while (h->len < n) h->cells[h->len++] = V_UNKNOWN;
}

void heap_fork_reserve(V hv) { (void)hv; }

// a write: the next version
HeapT *heap_set(HeapT *h, int64_t i, V x) {
  if (i < 0) die("invalid memory address %lld", (long long)i);
  if (i >= h->len) heap_extend(h, i + 1);
  else if (cell_dead(h->cells[i])) cells_dead_cell(h, i, "store");
  h->cells[i] = x;
  h->version++;
  return h;
}

// whether the n cells at a all hold integers (no freed cell, nothing a cell
// owns): one pass the compiler vectorizes, for the bulk operations on bytes
// and runes
static inline bool all_ints(const V *a, int64_t n) {
  V acc = 1;
  for (int64_t i = 0; i < n; i++) acc &= a[i];
  return acc & 1;
}

static void check_live(HeapT *h, int64_t base, int64_t n, const char *what) {
  int64_t e = base + n < h->len ? base + n : h->len;
  if (e > base && all_ints(h->cells + base, e - base)) return;
  for (int64_t i = base; i < e; i++)
    if (cell_dead(h->cells[i])) cells_dead_cell(h, i, what);
}

int64_t cell_index(V p) {
  if (kind(p) == K_INT) return int_val(p);
  if (p == V_NULL) rt_error("invalid memory address or nil pointer dereference");
  die("expected a pointer, got %s", ty_to_cstr_short(p));
}

// the allocation pointer: where an empty (zero-capacity) slice points. Empty
// slices are not nil (make([]T, 0), []byte(""), []rune("")): like Go's
// zerobase, they get a non-null base without allocating cells.
static int64_t heap_top(HeapT *h) {
  int64_t n0;
  V *a = heap_cells(h, &n0);
  return n0 > 0 && kind(a[0]) == K_INT ? int_val(a[0]) : 1;
}

// count * len(zero) cells initialized with the zero pattern: the new heap,
// *base the first cell
// The kinds of the cells of zero patterns of several cells (structs), kept
// for the next allocation with the pattern: patterns are the program's
// constants. The memo keeps its patterns alive (a root of the collector), and
// a tuple's elements do not change: the same elements are the same pattern.
#define KMEMO 256
static V kmemo_pat[KMEMO];
typedef struct {
  const V *z;
  int64_t nz;
  int uni;  // the kind of every cell, -1 when they differ
  uint8_t *kinds;
} PatKinds;
static PatKinds kmemo[KMEMO];

static const PatKinds *pat_kinds(V pat, const V *z, int64_t nz) {
  static bool rooted;
  uint32_t i = (uint32_t)(((uintptr_t)z >> 3) % KMEMO);
  PatKinds *m = &kmemo[i];
  if (m->z == z && m->nz == nz) return m;
  if (!rooted) {
    gc_add_root(kmemo_pat, sizeof kmemo_pat);
    rooted = true;
  }
  free(m->kinds);
  m->kinds = malloc((size_t)nz);
  cells_zero_kinds(z, nz, m->kinds);
  m->uni = m->kinds[0];
  for (int64_t k = 1; k < nz; k++)
    if (m->kinds[k] != m->uni) m->uni = -1;
  m->z = z;
  m->nz = nz;
  kmemo_pat[i] = pat;
  return m;
}

static inline __attribute__((always_inline)) HeapT *alloc_cells(HeapT *h, V pat, const V *zero, int64_t nz,
                                                                int64_t count, int64_t *base) {
  int64_t n = nz * count, k;
  V *c = h->cells;
  if (nz <= 1) {
    k = cells_alloc_kind(h, n, nz ? cells_kind_of[kind(zero[0])] : 0);
    *base = k;
    if (n == 1) {
      c[k] = zero[0];
      return h;
    }
    V z = nz ? zero[0] : 0;
    for (int64_t i = 0; i < n; i++) c[k + i] = z;
    return h;
  }
  const PatKinds *pk = pat_kinds(pat, zero, nz);
  if (pk->uni >= 0) {
    k = cells_alloc_kind(h, n, pk->uni);
  } else {
    k = cells_alloc(h, n, pk->kinds, nz);
  }
  *base = k;
  for (int64_t i = 0; i < count; i++)
    for (int64_t z = 0; z < nz; z++) c[k++] = zero[z];
  return h;
}

// n cells of one kind (0: no pointers, 3: anything), initialized: *base
HeapT *heap_alloc_items(HeapT *h, const V *items, int64_t n, int kind, int64_t *base) {
  int64_t k = cells_alloc_kind(h, n, kind);
  memcpy(h->cells + k, items, (size_t)n * 8);
  *base = k;
  return h;
}

// the cells of a zero pattern: a tuple's elements, or the value (one cell,
// in *one)
static void zero_cells(V t, V *one, const V **z, int64_t *n) {
  if (kind(t) == K_TUPLE) {
    *z = as_tup(t)->e;
    *n = as_tup(t)->len;
  } else {
    *one = t;
    *z = one;
    *n = 1;
  }
}

static V *cells_load(HeapT *h, int64_t base, int64_t n) {
  int64_t len;
  V *a = heap_cells(h, &len);
  if (base < 0 || base + n > len)
    die("load of unallocated cells %lld..%lld (heap has %lld cells)", (long long)base,
        (long long)(base + n), (long long)len);
  V *out = gc_alloc((size_t)(n > 0 ? n : 1) * 8);
  memcpy(out, a + base, (size_t)n * 8);
  for (int64_t i = 0; i < n; i++) {
    if (cell_dead(out[i])) cells_dead_cell(h, base + i, "load");
    cell_out(out[i]);
  }
  return out;
}

// the cells [base, base + n) to read in place (what cells_load copies out):
// allocated and live, the maps in them frozen (the cells are reserved
// address space: they stay where they are)
static const V *cells_at(HeapT *h, int64_t base, int64_t n) {
  int64_t len;
  V *a = heap_cells(h, &len);
  if (base < 0 || base + n > len)
    die("load of unallocated cells %lld..%lld (heap has %lld cells)", (long long)base,
        (long long)(base + n), (long long)len);
  if (all_ints(a + base, n)) return a + base;
  for (int64_t i = 0; i < n; i++) {
    V v = a[base + i];
    if (cell_dead(v)) cells_dead_cell(h, base + i, "load");
    cell_out(v);
  }
  return a + base;
}

static HeapT *cells_store(HeapT *h, int64_t base, const V *items, int64_t n) {
  if (n <= 0) return h;
  if (base < 0) die("invalid memory address %lld", (long long)base);
  check_live(h, base, n, "store");
  heap_extend(h, base + n);
  memmove(h->cells + base, items, (size_t)n * 8);
  h->version++;
  return h;
}

// cells without pointers (bytes, runes, string iterators)
static HeapT *alloc_with(HeapT *h, const V *items, int64_t n, int64_t *base) {
  return heap_alloc_items(h, items, n, 0, base);
}

static V heap_new(VA *cells) {
  if (nheaps == 0) cells_set_heaps(heaps, &nheaps);
  if (nheaps == MAX_HEAPS) die("too many heaps");
  // not collected: the cells are kept by the cell store's collector. The
  // first heap is static: the fast paths find it at a constant address
  HeapT *h = nheaps == 0 ? &heap0 : calloc(1, sizeof(HeapT));
  h->tag = K_STORE;
  h->id = nheaps;
  cells_heap_init(h, cells);
  heaps[nheaps++] = h;
  heap_latest = h;
  return heap_v(h);
}

void (*store_freeze[K_COUNT])(V);
// (the inline cell reads of codegen.mbt index it as [36 x ptr])
_Static_assert(K_COUNT == 36, "store_freeze in codegen.mbt");
void store_owned_kind(int k, void (*freeze)(V)) { store_freeze[k] = freeze; }

// ---------------------------------------------------------------------------
// Cells and pointers

// the common case of hget/hset without calls: the store's current version,
// an index in range, a live cell (hget: holding an integer or a keyword, no
// map to freeze)
static inline HeapT *heap_quick(V t) {
  // the first heap (id 0): no lookup
  if ((t & 0xFFFF) == (((V)K_STORE << 3) | 2)) return (t >> 16) == heap0.version ? &heap0 : NULL;
  if ((t & 0x1FF) != (((V)K_STORE << 3) | 2)) return NULL;
  HeapT *h = heaps[(t >> 9) & (MAX_HEAPS - 1)];
  return h && (t >> 16) == h->version ? h : NULL;
}

// (the general cases out of line: the fast paths need no frame of their own)
static __attribute__((noinline)) V hget_slow(V h, V p) { return cell_out(heap_get(heap_of(h), cell_index(p))); }
static __attribute__((noinline)) V hset_slow(V h, V p, V x) { return heap_v(heap_set(heap_of(h), cell_index(p), x)); }

// a cell's value as hget returns it: live, and not a map to freeze (an
// integer first: integers are never dead cells)
static inline bool cell_plain(V v) {
  if (v & 1) return true;
  if (v & 2) return !cell_is_poison(v) && !cell_is_free_hdr(v);
  if (!v) return false;
  unsigned k = (unsigned)((Hdr *)v)->tag;
  return k < K_COUNT && !store_freeze[k];
}

static inline bool cell_live(V v) { return (v & 1) || !cell_dead(v); }

// (p, off: immediates)
#define IMM_VAL(x) ((int64_t)(x) >> 1)

V n_hget(V h, V p) {
  HeapT *hh = heap_quick(h);
  if (hh && (p & 1)) {
    uint64_t i = (uint64_t)IMM_VAL(p);
    if (i < (uint64_t)hh->len) {
      V v = hh->cells[i];
      if (cell_plain(v)) return v;
    }
  }
  return hget_slow(h, p);
}

V n_hset(V h, V p, V x) {
  HeapT *hh = heap_quick(h);
  if (hh && (p & 1)) {
    uint64_t i = (uint64_t)IMM_VAL(p);
    if (i < (uint64_t)hh->len && cell_live(hh->cells[i])) {
      hh->cells[i] = x;
      hh->version++;
      return heap_v(hh);
    }
  }
  return hset_slow(h, p, x);
}

VPair n_halloc(V h, V zero, V count) {
  cells_safepoint4(h, zero, 0, 0);
  const V *z;
  V one;
  int64_t nz, base;
  zero_cells(zero, &one, &z, &nz);
  HeapT *hh = heap_quick(h);
  if (!hh) hh = heap_of(h);
  HeapT *h2 = alloc_cells(hh, zero, z, nz, (count & 1) ? IMM_VAL(count) : gi(count), &base);
  return PAIR(heap_v(h2), mk_int(base));
}

// hinit([[count, pattern], ...])
V n_hinit(V runs) {
  VA cells;
  va_init(&cells);
  if (kind(runs) != K_TUPLE) die("hinit: expected runs");
  TupT *rs = as_tup(runs);
  for (uint32_t i = 0; i < rs->len; i++) {
    if (kind(rs->e[i]) != K_TUPLE) die("hinit: bad run");
    TupT *r = as_tup(rs->e[i]);
    int64_t n = gi(r->e[0]);
    const V *z;
    V one;
    int64_t nz;
    zero_cells(r->e[1], &one, &z, &nz);
    for (int64_t k = 0; k < n; k++)
      for (int64_t j = 0; j < nz; j++) va_push(&cells, z[j]);
  }
  return heap_new(&cells);
}

static V ptr_add(V p, int64_t off) {
  if (kind(p) == K_INT) return mk_int(int_val(p) + off);
  if (p == V_NULL) rt_error("invalid memory address or nil pointer dereference");
  die("expected a pointer, got %s", ty_to_cstr_short(p));
}

V n_padd(V p, V off) { return ptr_add(p, gi(off)); }

// the cell at p + off, and a store into it (hget/hset of padd), with the
// fast paths of n_hget/n_hset
static __attribute__((noinline)) V hgetf_slow(V h, V p, V off) {
  return cell_out(heap_get(heap_of(h), cell_index(p) + gi(off)));
}

V n_hgetf(V h, V p, V off) {
  HeapT *hh = heap_quick(h);
  if (hh && (p & off & 1)) {
    uint64_t i = (uint64_t)(IMM_VAL(p) + IMM_VAL(off));
    if (i < (uint64_t)hh->len) {
      V v = hh->cells[i];
      if (cell_plain(v)) return v;
    }
  }
  return hgetf_slow(h, p, off);
}
static __attribute__((noinline)) V hsetf_slow(V h, V p, V off, V x) {
  return heap_v(heap_set(heap_of(h), cell_index(p) + gi(off), x));
}

V n_hsetf(V h, V p, V off, V x) {
  HeapT *hh = heap_quick(h);
  if (hh && (p & off & 1)) {
    uint64_t i = (uint64_t)(IMM_VAL(p) + IMM_VAL(off));
    if (i < (uint64_t)hh->len && cell_live(hh->cells[i])) {
      hh->cells[i] = x;
      hh->version++;
      return heap_v(hh);
    }
  }
  return hsetf_slow(h, p, off, x);
}

// the cell of element i of slice s (stride cells each), and a store into it
// (hget/hset of sidx), with the fast paths of n_sidx and n_hget/n_hset
V n_sidx(V s, V iv, V stride);
static __attribute__((noinline)) V hgets_slow(V h, V s, V iv, V stride) { return n_hget(h, n_sidx(s, iv, stride)); }
static __attribute__((noinline)) V hsets_slow(V h, V s, V iv, V stride, V x) {
  return n_hset(h, n_sidx(s, iv, stride), x);
}

// the cell index of element i of a slice tuple s, or -1 (the general cases)
static inline int64_t slice_cell(V s, V iv, V stride) {
  if ((s & 3) == 0 && ((Hdr *)s)->tag == K_TUPLE && ((TupT *)s)->len >= 3 && (iv & stride & 1)) {
    V *e = ((TupT *)s)->e;
    if (e[0] & e[1] & 1) {
      uint64_t i = (uint64_t)IMM_VAL(iv);
      if (i < (uint64_t)IMM_VAL(e[1]) && i < ((uint64_t)1 << 32)) {
        int64_t r;
        if (!__builtin_add_overflow(IMM_VAL(e[0]), (int64_t)i * IMM_VAL(stride), &r) && r >= 0) return r;
      }
    }
  }
  return -1;
}

V n_hgets(V h, V s, V iv, V stride) {
  HeapT *hh = heap_quick(h);
  int64_t i = slice_cell(s, iv, stride);
  if (hh && i >= 0 && i < hh->len) {
    V v = hh->cells[i];
    if (cell_plain(v)) return v;
  }
  return hgets_slow(h, s, iv, stride);
}

V n_hsets(V h, V s, V iv, V stride, V x) {
  HeapT *hh = heap_quick(h);
  int64_t i = slice_cell(s, iv, stride);
  if (hh && i >= 0 && i < hh->len && cell_live(hh->cells[i])) {
    hh->cells[i] = x;
    hh->version++;
    return heap_v(hh);
  }
  return hsets_slow(h, s, iv, stride, x);
}

// memmove of n cells
V n_hcopy(V h, V dst, V src, V nv) {
  int64_t n = gi(nv);
  if (n == 0) return h;
  HeapT *hh = heap_of(h);
  const V *items = cells_at(hh, cell_index(src), n);
  return heap_v(cells_store(hh, cell_index(dst), items, n));
}

// ---------------------------------------------------------------------------
// Layouts: "s" one scalar cell, "(...)" a struct, "[N...]" an array (a tuple
// as a value)

typedef struct Layout Layout;
struct Layout {
  int kind;  // 0 scalar, 1 struct, 2 array
  int64_t n;
  Layout **fields;  // struct fields, or the array element
  int64_t size;     // cells
  bool flat;        // a struct or array of scalars: a tuple of size cells
};

static Layout scalar_layout = {0, 0, NULL, 1, false};

static Layout *parse_layout(const uint16_t *d, int32_t len, int32_t *pos) {
  if (*pos >= len) die("bad layout descriptor");
  uint16_t c = d[(*pos)++];
  if (c == 's') return &scalar_layout;
  if (c == '(') {
    Layout *l = calloc(1, sizeof(Layout));
    l->kind = 1;
    int64_t cap = 4;
    l->fields = malloc((size_t)cap * sizeof(Layout *));
    while (*pos < len && d[*pos] != ')') {
      if (l->n == cap) {
        cap *= 2;
        l->fields = realloc(l->fields, (size_t)cap * sizeof(Layout *));
      }
      l->fields[l->n++] = parse_layout(d, len, pos);
      l->size += l->fields[l->n - 1]->size;
    }
    (*pos)++;
    l->flat = true;
    for (int64_t i = 0; i < l->n; i++) l->flat = l->flat && l->fields[i]->kind == 0;
    return l;
  }
  if (c == '[') {
    Layout *l = calloc(1, sizeof(Layout));
    l->kind = 2;
    while (*pos < len && d[*pos] >= '0' && d[*pos] <= '9') l->n = l->n * 10 + (d[(*pos)++] - '0');
    l->fields = malloc(sizeof(Layout *));
    l->fields[0] = parse_layout(d, len, pos);
    l->size = l->n * l->fields[0]->size;
    (*pos)++;  // ']'
    l->flat = l->fields[0]->kind == 0;
    return l;
  }
  die("bad layout descriptor");
}

// layouts by descriptor text (they are few)
typedef struct LCache { Str *key; Layout *l; struct LCache *next; } LCache;
static LCache *lcache[256];

static Layout *layout_of(Str *s) {
  uint32_t h = str_hash(s) & 255;
  for (LCache *c = lcache[h]; c; c = c->next)
    if (c->key == s || str_eq(c->key, s)) return c->l;
  int32_t pos = 0;
  Layout *l = parse_layout(str_d(s), s->len, &pos);
  LCache *c = malloc(sizeof(LCache));
  // the key must stay alive: copy it out of the collected heap
  StrBuf *b = malloc(sizeof(StrBuf));
  b->used = b->cap = s->len;
  b->cap = -1;
  b->d = malloc((size_t)(s->len ? s->len : 1) * 2);
  memcpy(b->d, str_d(s), (size_t)s->len * 2);
  Str *k = malloc(sizeof(Str));
  k->tag = K_STRLIT;
  k->hash = 0;
  k->start = 0;
  k->len = s->len;
  k->buf = b;
  c->key = k;
  c->l = l;
  c->next = lcache[h];
  lcache[h] = c;
  return l;
}

static V load_layout(const V *a, int64_t alen, int64_t *pos, Layout *l) {
  if (l->flat && *pos >= 0 && *pos + l->size <= alen && all_ints(a + *pos, l->size)) {
    // (a struct of integers, the common case: its cells as they are)
    TupT *t = tup_alloc((uint32_t)l->size);
    memcpy(t->e, a + *pos, (size_t)l->size * 8);
    *pos += l->size;
    return (V)t;
  }
  if (l->kind == 0) {
    if (*pos < 0 || *pos >= alen)
      die("load of unallocated cell %lld (heap has %lld cells)", (long long)*pos, (long long)alen);
    V v = a[(*pos)++];
    if (cell_dead(v)) cells_dead_cell(heap_latest, *pos - 1, "load");
    return cell_out(v);
  }
  TupT *t = tup_alloc((uint32_t)l->n);
  for (int64_t i = 0; i < l->n; i++) t->e[i] = load_layout(a, alen, pos, l->kind == 1 ? l->fields[i] : l->fields[0]);
  return (V)t;
}

static void flatten_layout(V v, Layout *l, VA *out) {
  if (l->kind == 0) {
    va_push(out, v);
    return;
  }
  if (kind(v) != K_TUPLE) die("store: expected a struct or array value, got %s", ty_to_cstr_short(v));
  TupT *t = as_tup(v);
  for (int64_t i = 0; i < l->n; i++) {
    if (i >= t->len) die("store: value too short for its layout");
    flatten_layout(t->e[i], l->kind == 1 ? l->fields[i] : l->fields[0], out);
  }
}

static int trace_mem = -1;

static void trace(const char *what, V a, V b) {
  if (trace_mem < 0) trace_mem = getenv("TSTC_TRACE_MEM") != NULL;
  if (!trace_mem) return;
  char *x = ty_to_cstr_short(a), *y = ty_to_cstr_short(b);
  fprintf(stderr, "%s %s %s\n", what, x, y);
  free(x);
  free(y);
}

V n_hloadt(V h, V p, V lay) {
  Layout *l = layout_of(gs(lay));
  int64_t len;
  V *a = heap_cells(heap_of(h), &len);
  int64_t pos = cell_index(p);
  V r = load_layout(a, len, &pos, l);
  trace("hloadt", lay, r);
  return r;
}

// a value's cells written at a[*pos...]
static void store_layout(V v, Layout *l, V *a, int64_t *pos) {
  if (l->kind == 0) {
    a[(*pos)++] = v;
    return;
  }
  if (l->flat && kind(v) == K_TUPLE && as_tup(v)->len >= l->size) {
    memcpy(a + *pos, as_tup(v)->e, (size_t)l->size * 8);
    *pos += l->size;
    return;
  }
  if (kind(v) != K_TUPLE) die("store: expected a struct or array value, got %s", ty_to_cstr_short(v));
  TupT *t = as_tup(v);
  for (int64_t i = 0; i < l->n; i++) {
    if (i >= t->len) die("store: value too short for its layout");
    store_layout(t->e[i], l->kind == 1 ? l->fields[i] : l->fields[0], a, pos);
  }
}

V n_hstoret(V h, V p, V v, V lay) {
  trace("hstoret", lay, v);
  Layout *l = layout_of(gs(lay));
  HeapT *hh = heap_of(h);
  int64_t base = cell_index(p);
  if (base < 0) die("invalid memory address %lld", (long long)base);
  check_live(hh, base, l->size, "store");
  heap_extend(hh, base + l->size);
  int64_t pos = base;
  store_layout(v, l, hh->cells, &pos);
  hh->version++;
  return heap_v(hh);
}

void layout_flatten(V v, Str *lay, VA *out) { flatten_layout(v, layout_of(lay), out); }

// arrays as values
V n_vnew(V nv, V z) {
  int64_t n = gi(nv);
  TupT *t = tup_alloc((uint32_t)n);
  for (int64_t i = 0; i < n; i++) t->e[i] = z;
  return (V)t;
}

V n_vget(V v, V iv) {
  if (kind(v) != K_TUPLE) die("expected an array value, got %s", ty_to_cstr_short(v));
  TupT *t = as_tup(v);
  int64_t i = gi(iv);
  if (i < 0 || i >= t->len) rt_error("index out of range [%lld] with length %u", (long long)i, t->len);
  return t->e[i];
}

// ---------------------------------------------------------------------------
// Slices

static void slice3(V t, V *ptr, int64_t *len, int64_t *cap) {
  if (t == V_NULL) {
    *ptr = V_NULL;
    *len = *cap = 0;
    return;
  }
  if (kind(t) != K_TUPLE || as_tup(t)->len < 3) die("expected a slice, got %s", ty_to_cstr_short(t));
  TupT *tp = as_tup(t);
  *ptr = tp->e[0];
  *len = gi(tp->e[1]);
  *cap = gi(tp->e[2]);
}

static V mk_slice3(V ptr, int64_t len, int64_t cap) { return mk_tuple3(ptr, mk_int(len), mk_int(cap)); }

V n_sdata(V s) {
  V p;
  int64_t len, cap;
  slice3(s, &p, &len, &cap);
  return p;
}

static __attribute__((noinline)) V sidx_slow(V s, V iv, V stride) {
  V p;
  int64_t len, cap, i = gi(iv);
  slice3(s, &p, &len, &cap);
  if (i < 0 || i >= len) rt_error("index out of range [%lld] with length %lld", (long long)i, (long long)len);
  return ptr_add(p, i * gi(stride));
}

V n_sidx(V s, V iv, V stride) {
  // the common case first: a slice tuple, integers, an index in range
  if ((s & 3) == 0 && ((Hdr *)s)->tag == K_TUPLE && ((TupT *)s)->len >= 3 && (iv & stride & 1)) {
    V *e = ((TupT *)s)->e;
    if (e[0] & e[1] & 1) {
      uint64_t i = (uint64_t)IMM_VAL(iv);
      if (i < (uint64_t)IMM_VAL(e[1]) && i < ((uint64_t)1 << 32)) {
        int64_t off = (int64_t)i * IMM_VAL(stride), r;
        if (!__builtin_add_overflow(IMM_VAL(e[0]), off, &r) && r >= -(INT64_C(1) << 62) && r < (INT64_C(1) << 62))
          return ((V)r << 1) | 1;
      }
    }
  }
  return sidx_slow(s, iv, stride);
}

VPair n_salloc(V h, V nv, V cv, V zero) {
  cells_safepoint4(h, zero, 0, 0);
  int64_t n = gi(nv), c = gi(cv);
  if (c == 0) return PAIR(h, mk_slice3(mk_int(heap_top(heap_of(h))), 0, 0));
  const V *z;
  V one;
  int64_t nz, base;
  zero_cells(zero, &one, &z, &nz);
  HeapT *h2 = alloc_cells(heap_of(h), zero, z, nz, c, &base);
  return PAIR(heap_v(h2), mk_slice3(mk_int(base), n, c));
}

V n_reslice(V s, V lov, V hiv, V maxv, V stride) {
  V p;
  int64_t len, cap;
  slice3(s, &p, &len, &cap);
  int64_t lo = lov == V_NULL ? 0 : gi(lov);
  int64_t hi = hiv == V_NULL ? len : gi(hiv);
  int64_t mx = maxv == V_NULL ? cap : gi(maxv);
  if (lo < 0 || hi < lo || mx < hi || mx > cap)
    die("slice bounds out of range [%lld:%lld:%lld] with capacity %lld", (long long)lo, (long long)hi,
        (long long)mx, (long long)cap);
  V np = p == V_NULL ? V_NULL : ptr_add(p, lo * gi(stride));
  return mk_slice3(np, hi - lo, mx - lo);
}

V n_aslice(V p, V nv, V lov, V hiv, V maxv, V stride) {
  int64_t n = gi(nv);
  int64_t lo = lov == V_NULL ? 0 : gi(lov);
  int64_t hi = hiv == V_NULL ? n : gi(hiv);
  int64_t mx = maxv == V_NULL ? n : gi(maxv);
  if (lo < 0 || hi < lo || mx < hi || mx > n) die("slice bounds out of range");
  return mk_slice3(ptr_add(p, lo * gi(stride)), hi - lo, mx - lo);
}

static const int size_classes[] = {
    0,     8,     16,    24,    32,    48,    64,    80,    96,    112,   128,   144,
    160,   176,   192,   208,   224,   240,   256,   288,   320,   352,   384,   416,
    448,   480,   512,   576,   640,   704,   768,   896,   1024,  1152,  1280,  1408,
    1536,  1792,  2048,  2304,  2688,  3072,  3200,  3456,  4096,  4864,  5376,  6144,
    6528,  6784,  6912,  8192,  9472,  9728,  10240, 10880, 12288, 13568, 14336, 16384,
    18432, 19072, 20480, 21760, 24576, 27264, 28672, 32768};

// runtime.roundupsize
static int64_t roundupsize(int64_t size, bool noscan) {
  int64_t req = size;
  if (req <= 32768 - 8) {
    if (!noscan && req > 512) req += 8;
    for (size_t i = 0; i < sizeof size_classes / sizeof size_classes[0]; i++)
      if (size_classes[i] >= req) return size_classes[i] - (req - size);
  }
  req = size + 8191;
  return req - req % 8192;
}

// runtime.nextslicecap + roundupsize
static int64_t grow_cap(int64_t old_cap, int64_t new_len, int64_t elem_size, bool noscan) {
  int64_t newcap = old_cap, doublecap = newcap + newcap;
  if (new_len > doublecap) newcap = new_len;
  else if (old_cap < 256) newcap = doublecap;
  else
    while (newcap < new_len) newcap += (newcap + 768) >> 2;
  if (elem_size <= 0) return newcap;
  return roundupsize(newcap * elem_size, noscan) / elem_size;
}

static const V *slice_cells(HeapT *h, V s, int64_t stride, int64_t *n) {
  V p;
  int64_t len, cap;
  slice3(s, &p, &len, &cap);
  *n = len * stride;
  if (len == 0) return NULL;
  return cells_at(h, cell_index(p), len * stride);
}

// the first n code units of s stored as cells at base (cells_store of them)
static HeapT *cells_store_str(HeapT *h, int64_t base, Str *s, int64_t n) {
  if (n <= 0) return h;
  if (base < 0) die("invalid memory address %lld", (long long)base);
  check_live(h, base, n, "store");
  heap_extend(h, base + n);
  const uint16_t *d = str_d(s);
  for (int64_t i = 0; i < n; i++) h->cells[base + i] = mk_int(d[i]);
  h->version++;
  return h;
}

static VPair append_items(V hv, HeapT *h, V s, const V *items, Str *ts, int64_t ni, V zero, int64_t stride, V elemv,
                          V noscanv);

// sappend(h, s, t, zero, stride, elemBytes, noscan) -> [h, s']; t is a slice
// or (for []byte) a string
VPair n_sappend(V hv, V s, V t, V zero, V stridev, V elemv, V noscanv) {
  cells_safepoint4(hv, s, t, zero);
  HeapT *h = heap_of(hv);
  int64_t stride = gi(stridev), ni;
  const V *items = NULL;
  Str *ts = NULL;  // t, a string: its code units are the items
  if (kind(t) == K_STRLIT) {
    ts = as_str(t);
    ni = ts->len;
  } else {
    items = slice_cells(h, t, stride, &ni);
  }
  return append_items(hv, h, s, items, ts, ni, zero, stride, elemv, noscanv);
}

// sappendv(h, s, cells, zero, stride, elemBytes, noscan) -> [h, s']: the
// values' cells, a tuple
VPair n_sappendv(V hv, V s, V t, V zero, V stridev, V elemv, V noscanv) {
  cells_safepoint4(hv, s, t, zero);
  if (kind(t) != K_TUPLE) die("sappendv: expected a tuple, got %s", ty_to_cstr_short(t));
  TupT *tt = as_tup(t);
  return append_items(hv, heap_of(hv), s, tt->e, NULL, tt->len, zero, gi(stridev), elemv, noscanv);
}

static VPair append_items(V hv, HeapT *h, V s, const V *items, Str *ts, int64_t ni, V zero, int64_t stride, V elemv,
                          V noscanv) {
  V p;
  int64_t len, cap;
  slice3(s, &p, &len, &cap);
  int64_t n = ni / (stride == 0 ? 1 : stride);
  if (n == 0) return PAIR(hv, s);
  if (len + n <= cap) {
    int64_t at = cell_index(p) + len * stride;
    HeapT *h2 = ts ? cells_store_str(h, at, ts, ni) : cells_store(h, at, items, ni);
    return PAIR(heap_v(h2), mk_slice3(p, len + n, cap));
  }
  int64_t newcap = grow_cap(cap, len + n, gi(elemv), gb(noscanv));
  const V *z;
  V one;
  int64_t nz, base;
  zero_cells(zero, &one, &z, &nz);
  HeapT *h3 = alloc_cells(h, zero, z, nz, newcap, &base);
  if (len > 0) {
    const V *old = cells_at(h3, cell_index(p), len * stride);
    h3 = cells_store(h3, base, old, len * stride);
  }
  h3 = ts ? cells_store_str(h3, base + len * stride, ts, ni) : cells_store(h3, base + len * stride, items, ni);
  return PAIR(heap_v(h3), mk_slice3(mk_int(base), len + n, newcap));
}

// scopy(h, dst, src, stride) -> [h, n]; src may be a string
VPair n_scopy(V hv, V dst, V src, V stridev) {
  HeapT *h = heap_of(hv);
  int64_t stride = gi(stridev);
  V dp;
  int64_t dlen, dcap;
  slice3(dst, &dp, &dlen, &dcap);
  if (kind(src) == K_STRLIT) {
    Str *s = as_str(src);
    int64_t n = s->len < dlen ? s->len : dlen;
    if (n == 0) return PAIR(hv, mk_int(0));
    return PAIR(heap_v(cells_store_str(h, cell_index(dp), s, n)), mk_int(n));
  }
  V sp;
  int64_t slen, scap;
  slice3(src, &sp, &slen, &scap);
  int64_t n = slen < dlen ? slen : dlen;
  if (n == 0) return PAIR(hv, mk_int(0));
  const V *items = cells_at(h, cell_index(sp), n * stride);
  return PAIR(heap_v(cells_store(h, cell_index(dp), items, n * stride)), mk_int(n));
}

V n_sclear(V hv, V s, V zero) {
  V p;
  int64_t len, cap;
  slice3(s, &p, &len, &cap);
  if (len == 0) return hv;
  const V *z;
  V one;
  int64_t nz;
  zero_cells(zero, &one, &z, &nz);
  HeapT *h = heap_of(hv);
  int64_t base = cell_index(p), n = len * nz;
  if (base < 0) die("invalid memory address %lld", (long long)base);
  check_live(h, base, n, "store");
  heap_extend(h, base + n);
  V *c = h->cells + base;
  for (int64_t i = 0; i < len; i++)
    for (int64_t j = 0; j < nz; j++) c[i * nz + j] = z[j];
  h->version++;
  return heap_v(h);
}

V n_sswap(V hv, V s, V iv, V jv, V stridev) {
  V p;
  int64_t len, cap, i = gi(iv), j = gi(jv), stride = gi(stridev);
  slice3(s, &p, &len, &cap);
  if (i < 0 || i >= len || j < 0 || j >= len) die("index out of range in swap");
  int64_t base = cell_index(p);
  HeapT *h = heap_of(hv);
  V *a = cells_load(h, base + i * stride, stride);
  V *b = cells_load(h, base + j * stride, stride);
  return heap_v(cells_store(cells_store(h, base + i * stride, b, stride), base + j * stride, a, stride));
}

static V cells_str(const V *items, int64_t n) {
  if (n == 0) return (V)str_empty;
  Str *r = str_alloc((int32_t)n);
  uint16_t *w = str_wd(r);
  for (int64_t i = 0; i < n; i++) w[i] = (uint16_t)(gi(items[i]) & 0xFF);
  return (V)r;
}

V n_bytes2s(V hv, V s) {
  V p;
  int64_t len, cap;
  slice3(s, &p, &len, &cap);
  if (len == 0) return (V)str_empty;
  return cells_str(cells_at(heap_of(hv), cell_index(p), len), len);
}

V n_ptrstr(V hv, V p, V nv) {
  int64_t n = gi(nv);
  if (n == 0) return (V)str_empty;
  return cells_str(cells_at(heap_of(hv), cell_index(p), n), n);
}

VPair n_s2bytes(V hv, V sv) {
  cells_safepoint4(hv, sv, 0, 0);
  Str *s = gs(sv);
  if (s->len == 0) return PAIR(hv, mk_slice3(mk_int(heap_top(heap_of(hv))), 0, 0));
  int64_t c = roundupsize(s->len, true);
  HeapT *h2 = heap_of(hv);
  int64_t base = cells_alloc_kind(h2, c, 0);
  V *w = h2->cells + base;
  const uint16_t *d = str_d(s);
  for (int64_t i = 0; i < c; i++) w[i] = mk_int(i < s->len ? d[i] : 0);
  return PAIR(heap_v(h2), mk_slice3(mk_int(base), s->len, c));
}

V n_runes2sl(V hv, V s) {
  V p;
  int64_t len, cap;
  slice3(s, &p, &len, &cap);
  SB b = {0};
  if (len > 0) {
    const V *items = cells_at(heap_of(hv), cell_index(p), len);
    for (int64_t i = 0; i < len; i++) utf8_put(&b, gi(items[i]));
  }
  return (V)sb_finish(&b);
}

VPair n_s2runesl(V hv, V sv) {
  cells_safepoint4(hv, sv, 0, 0);
  Str *s = gs(sv);
  VA items;
  va_init(&items);
  for (int32_t i = 0; i < s->len;) {
    int32_t n;
    int64_t r = utf8_decode_at(s, i, &n);
    va_push(&items, mk_int(r));
    i += n;
  }
  int64_t len = items.n;
  if (len == 0) return PAIR(hv, mk_slice3(mk_int(heap_top(heap_of(hv))), 0, 0));
  int64_t c = roundupsize(len * 4, true) / 4;
  while ((int64_t)items.n < c) va_push(&items, mk_int(0));
  int64_t base;
  HeapT *h2 = alloc_with(heap_of(hv), items.d, c, &base);
  return PAIR(heap_v(h2), mk_slice3(mk_int(base), len, c));
}

// range over a string: the iterator cell holds [s, position]
VPair n_srange(V hv, V s) {
  cells_safepoint4(hv, s, 0, 0);
  V it = mk_tuple2(s, mk_int(0));
  int64_t base;
  HeapT *h2 = alloc_with(heap_of(hv), &it, 1, &base);
  return PAIR(heap_v(h2), mk_int(base));
}

// [heap, ok, index, rune]
V n_snext(V hv, V itv) {
  HeapT *h = heap_of(hv);
  int64_t it = cell_index(itv);
  V st = heap_get(h, it);
  if (kind(st) != K_TUPLE) die("snext: bad iterator");
  Str *s = gs(as_tup(st)->e[0]);
  int64_t pos = gi(as_tup(st)->e[1]);
  V r4[4];
  if (pos >= s->len) {
    r4[0] = hv;
    r4[1] = V_FALSE;
    r4[2] = mk_int(0);
    r4[3] = mk_int(0);
    return mk_tuple(r4, 4);
  }
  int32_t n;
  int64_t r = utf8_decode_at(s, (int32_t)pos, &n);
  HeapT *h2 = heap_set(h, it, mk_tuple2(as_tup(st)->e[0], mk_int(pos + n)));
  r4[0] = heap_v(h2);
  r4[1] = V_TRUE;
  r4[2] = mk_int(pos);
  r4[3] = mk_int(r);
  return mk_tuple(r4, 4);
}

// strings.Builder: the cell after addr holds the string written so far
V n_bstr(V hv, V p) {
  V s = heap_get(heap_of(hv), cell_index(p) + 1);
  return kind(s) == K_STRLIT ? s : (V)str_empty;
}

V n_bappend(V hv, V p, V sv) {
  HeapT *h = heap_of(hv);
  int64_t i = cell_index(p) + 1;
  V old = heap_get(h, i);
  Str *s = kind(old) == K_STRLIT ? str_concat(as_str(old), gs(sv)) : gs(sv);
  return heap_v(heap_set(h, i, (V)s));
}
