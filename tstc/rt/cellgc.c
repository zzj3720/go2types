// Garbage collection of the cell store (the cells of heap.c).
//
// The definitions of the store (tstst's lib/pure heap.ts) never free a cell:
// the heap only grows. The library declares (tags on hinit, see store.mbt in
// the compiler; the program's tstc_store) what lets the runtime do better:
//   @store-reuse    the address an allocation gets is not observable, so the
//                   cells nothing refers to may be freed and reused;
//   @store-ref      references to cells are their indices (integers);
//   @store-scalar   a cell allocated with a value of the listed types never
//                   holds a reference.
// Without @store-reuse, cells are never freed (they are roots of the
// runtime's own collection). With it, cells nobody can reach are freed at safe
// points (the allocating natives, before they look at their arguments),
// together with the runtime's own collection (gc.c).
//
// What a cell may hold comes from the value it is allocated with: one of the
// declared scalar types (a scalar cell: its immediates are no cell indices),
// or anything else (scanned conservatively). The cells hinit makes may
// hold anything.
// Roots are found conservatively: every integer on a stack, in a register,
// or in a value reachable from them may be a cell index. An integer inside
// an object keeps the whole object (all cells from its first to the next
// object's first). The cells [0, base) (made by hinit) are always live.
//
// Free cells: a run of free cells starts with a FREE header (an immediate
// with the run's length); the others keep what they held, or read as 0 where
// their pages went back to the system. A load or store of a run's first cell
// dies. With TSTC_CELLGC_DEBUG=1 freed cells are never reused and hold POISON
// (every stale access dies; the poison names the collection that freed it), TSTC_CELLGC_STRESS=<n>
// collects every n allocations, and TSTC_CELLGC_VERIFY=1 (with DEBUG) reports
// integers in live cells and objects that name objects about to be freed.
#include <stddef.h>
#include "lib.h"

#include <execinfo.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

// what a cell may hold: no cell index (a scalar cell), or anything
enum { GK_NOSCAN, GK_CONS = 3 };

// The store's declaration (emitted by the compiler from the tags of hinit):
// the scalar types (STORE_S_*) and flags (STORE_F_*).
typedef struct { int64_t scalar, flags; } StoreDecl;
extern const StoreDecl tstc_store;
enum { STORE_S_BIGINT = 1, STORE_S_NUMBER = 2, STORE_S_STRING = 4, STORE_S_BOOLEAN = 8, STORE_S_NULL = 16,
       STORE_S_UNDEFINED = 32 };
enum { STORE_F_DECLARED = 1, STORE_F_LINEAR = 2, STORE_F_REUSE = 4 };

#define SMALL_MAX 64
#define SMALL_CELLS 1024  // objects of fewer cells are allocated in address order
#define TOP_RUN 4096      // cells a small object from the top takes for those after it
static bool top_runs;     // (cells_after_fork)

typedef struct { int64_t *d; int64_t n, cap; } IVec;

struct CellGc {
  // (first: the inline allocations of generated code read them, and start,
  // l1 and kinds, at these offsets: codegen.mbt's tstc_halloc)
  int64_t cur, cur_end;       // a free run allocated from in order (not in the lists)
  uint64_t *start;  // a bit per cell: an object (or free run) begins there
  uint64_t *l1;     // a bit per word of start: the word is not 0
  uint64_t *mark;   // a bit per cell (at an object's first)
  uint64_t *freeb;  // a bit per cell: a free run begins there
  uint64_t *kinds;  // two bits per cell (GK_*)
  int64_t base;     // [0, base) is always live
  int64_t sweep_lo; // cells below were allocated by the parent process
  IVec small[SMALL_MAX + 1];  // free runs by length
  IVec big[64];               // longer ones by floor(log2(length))
  uint64_t small_nz[2];       // a bit per list of small: not empty
  uint64_t big_nz;            // a bit per list of big: not empty
  int64_t free_cells;         // in the free lists
  bool has_free;              // a collection freed cells (there are free runs)
  int64_t tail_lo, tail_hi;   // freed by the last sweep above the allocation pointer
  int64_t scan;               // free runs before it were taken in address order (or skipped)
};

_Static_assert(offsetof(CellGc, cur) == 0 && offsetof(CellGc, cur_end) == 8 && offsetof(CellGc, start) == 16 &&
                   offsetof(CellGc, l1) == 24 && offsetof(CellGc, kinds) == 48,
               "the layout codegen.mbt's tstc_halloc reads");

static bool debug_mode, inited, verify;
extern bool gc_debug_cand;
extern int64_t gc_cur_cell;
static int verify_shown;
int64_t cells_stress;
static int64_t stress_count;
static int64_t min_cells = (int64_t)32 << 20;  // 256 MB
int64_t cells_since;      // cells allocated since the last collection
int64_t cells_threshold;  // of cells_since
static double growth = 1.0;
static bool trace;
size_t gc_extra_live;
static size_t cell_collections;
static double cell_ms;

static HeapT **gheaps;
static uint32_t *gnheaps;

// values the safe point's native still needs
static V sp_roots[8];

static int kind_gk(int k);

static void init_env(void) {
  if (inited) return;
  inited = true;
  const char *e = getenv("TSTC_CELLGC_DEBUG");
  debug_mode = e && e[0] && e[0] != '0';
  e = getenv("TSTC_CELLGC_STRESS");
  cells_stress = e ? atoll(e) : 0;
  e = getenv("TSTC_CELLGC_MIN");
  if (e) min_cells = atoll(e);
  e = getenv("TSTC_GC_GROWTH");
  if (e && atof(e) > 0) growth = atof(e);
  trace = getenv("TSTC_GC_TRACE") != NULL;
  verify = debug_mode && getenv("TSTC_CELLGC_VERIFY") != NULL;
  gc_debug_cand = verify;
  cells_threshold = min_cells;
  for (int k = 0; k < 64; k++) cells_kind_of[k] = (uint8_t)kind_gk(k);
  // (cells are never freed: no safe point is ever due)
  if (!(tstc_store.flags & STORE_F_REUSE)) cells_threshold = INT64_MAX;
  gc_add_root(sp_roots, sizeof sp_roots);
}

static void ivec_push(IVec *v, int64_t x) {
  if (v->n == v->cap) {
    v->cap = v->cap ? v->cap * 2 : 64;
    v->d = realloc(v->d, (size_t)v->cap * 8);
    if (!v->d) die("out of memory (free lists)");
  }
  v->d[v->n++] = x;
}

static void *reserve(size_t n) {
  void *p = mmap(NULL, n, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON | MAP_NORESERVE, -1, 0);
  return p == MAP_FAILED ? NULL : p;
}

// ---------------------------------------------------------------------------
// Bitmaps

static inline bool bit(const uint64_t *a, int64_t i) { return (a[i >> 6] >> (i & 63)) & 1; }

static inline void set_start(CellGc *g, int64_t i) {
  g->start[i >> 6] |= (uint64_t)1 << (i & 63);
  g->l1[i >> 12] |= (uint64_t)1 << ((i >> 6) & 63);
}

static inline void clear_start(CellGc *g, int64_t i) {
  uint64_t *w = &g->start[i >> 6];
  *w &= ~((uint64_t)1 << (i & 63));
  if (!*w) g->l1[i >> 12] &= ~((uint64_t)1 << ((i >> 6) & 63));
}

// the last object start at or before i (there is one at 0)
static int64_t start_before(CellGc *g, int64_t i) {
  int64_t w = i >> 6;
  uint64_t m = g->start[w] & (~(uint64_t)0 >> (63 - (i & 63)));
  if (m) return (w << 6) + 63 - __builtin_clzll(m);
  int64_t j = w - 1;  // a word of start
  while (j >= 0) {
    int64_t lw = j >> 6;
    uint64_t lm = g->l1[lw] & (~(uint64_t)0 >> (63 - (j & 63)));
    if (lm) {
      j = (lw << 6) + 63 - __builtin_clzll(lm);
      return (j << 6) + 63 - __builtin_clzll(g->start[j]);
    }
    j = (lw << 6) - 1;
  }
  return 0;
}

// the first object start after i, or top
static int64_t start_after(CellGc *g, int64_t i, int64_t top) {
  int64_t j = i + 1;
  if (j >= top) return top;
  int64_t w = j >> 6;
  uint64_t m = g->start[w] & (~(uint64_t)0 << (j & 63));
  if (m) {
    int64_t r = (w << 6) + __builtin_ctzll(m);
    return r < top ? r : top;
  }
  int64_t k = w + 1, kmax = (top + 63) >> 6;
  while (k < kmax) {
    int64_t lw = k >> 6;
    uint64_t lm = g->l1[lw] & (~(uint64_t)0 << (k & 63));
    if (lm) {
      k = (lw << 6) + __builtin_ctzll(lm);
      int64_t r = (k << 6) + __builtin_ctzll(g->start[k]);
      return r < top ? r : top;
    }
    k = (lw + 1) << 6;
  }
  return top;
}

static inline int kind_at(CellGc *g, int64_t i) { return (int)((g->kinds[i >> 5] >> ((i & 31) * 2)) & 3); }

static inline void set_kind(CellGc *g, int64_t i, int k) {
  uint64_t *w = &g->kinds[i >> 5];
  int sh = (int)(i & 31) * 2;
  *w = (*w & ~((uint64_t)3 << sh)) | ((uint64_t)k << sh);
}

// cells a..a+n of kind k (whole words of the bitmap at once)
static inline void fill_kinds(CellGc *g, int64_t a, int64_t n, int k) {
  if (n <= 0) return;
  int64_t b = a + n;
  if ((a >> 5) == ((b - 1) >> 5)) {
    // within a word: at once
    uint64_t mask = (n >= 32 ? ~(uint64_t)0 : ((uint64_t)1 << (2 * n)) - 1) << ((a & 31) * 2);
    uint64_t *w = &g->kinds[a >> 5];
    *w = (*w & ~mask) | ((uint64_t)k * UINT64_C(0x5555555555555555) & mask);
    return;
  }
  while (a < b && (a & 31)) set_kind(g, a++, k);
  while (b > a && (b & 31)) set_kind(g, --b, k);
  if (a < b) memset(&g->kinds[a >> 5], k * 0x55, (size_t)((b - a) >> 5) * 8);
}

static void clear_kinds(CellGc *g, int64_t a, int64_t n) { fill_kinds(g, a, n, GK_NOSCAN); }

// ---------------------------------------------------------------------------
// Heaps

// a cell allocated with z: scalar when z is a value of a declared scalar type
// (cells_kind_of: the same by kind(z))
uint8_t cells_kind_of[64];
static int kind_gk(int k) {
  int64_t m = tstc_store.scalar, bit;
  switch (k) {
  case K_INT:
  case K_BIGLIT: bit = STORE_S_BIGINT; break;
  case K_NUMLIT: bit = STORE_S_NUMBER; break;
  case K_STRLIT: bit = STORE_S_STRING; break;
  case K_TRUE:
  case K_FALSE: bit = STORE_S_BOOLEAN; break;
  case K_NULL: bit = STORE_S_NULL; break;
  case K_UNDEFINED: bit = STORE_S_UNDEFINED; break;
  default: bit = 0;
  }
  return m & bit ? GK_NOSCAN : GK_CONS;
}
static int zero_kind(V z) { return kind_gk(kind(z)); }

void cells_heap_init(HeapT *h, VA *init) {
  init_env();
  if (!gheaps) die("cells_heap_init: no heap table");
  CellGc *g = calloc(1, sizeof(CellGc));
  h->gc = g;
  // the cells and their bitmaps are reserved: pages come when touched
  size_t cap = (size_t)1 << 33;  // cells
  while (cap > ((size_t)1 << 24)) {
    h->cells = reserve(cap * 8);
    if (h->cells) break;
    cap /= 2;
  }
  if (!h->cells) die("cannot reserve the cell store");
  g->start = reserve(cap / 8);
  g->mark = reserve(cap / 8);
  g->freeb = reserve(cap / 8);
  g->kinds = reserve(cap / 4);
  g->l1 = reserve(cap / 512 + 8);
  if (!g->start || !g->mark || !g->freeb || !g->kinds || !g->l1) die("cannot reserve the cell store's bitmaps");
  h->cap = (int64_t)cap;
  int64_t n = init->n + 1;
  h->cells[0] = mk_int(n);
  memcpy(h->cells + 1, init->d, (size_t)init->n * 8);
  h->len = n;
  g->base = n;
  g->sweep_lo = n;
  set_start(g, 0);
  // (hinit's cells may start with what a program's initialization would
  // have stored, a reference among them: anything)
  for (int64_t i = 1; i < n; i++) set_kind(g, i, GK_CONS);
}

void cells_set_heaps(HeapT **hs, uint32_t *n) {
  gheaps = hs;
  gnheaps = n;
}

static inline int64_t top_of(HeapT *h) { return int_val(h->cells[0]); }

static void print_backtrace(void) {
  void *frames[64];
  int k = backtrace(frames, 64);
  backtrace_symbols_fd(frames, k, 2);
}

_Noreturn void cells_dead_cell(HeapT *h, int64_t i, const char *what) {
  if (debug_mode && h && h->gc && i >= 0 && i < h->len) {
    // what the object was, who still refers to it
    CellGc *g = h->gc;
    int64_t top = top_of(h);
    int64_t s = start_before(g, i), e = start_after(g, s, top);
    V v = h->cells[i];
    fprintf(stderr, "cell gc: %s of cell %lld: object [%lld, %lld) of kinds", what, (long long)i, (long long)s,
            (long long)e);
    for (int64_t k = s; k < e && k < s + 16; k++) fprintf(stderr, " %d", kind_at(g, k));
    fprintf(stderr, ", freed by collection %lld (now %zu)\n", cell_is_poison(v) ? (long long)(v >> 16) : -1LL,
            cell_collections);
    int shown = 0;
    for (int64_t c = 1; c < top && shown < 20; c++) {
      V x = h->cells[c];
      bool hit = (x & 1) && int_val(x) >= s && int_val(x) < e;
      if (!hit && !(x & 3) && x && kind(x) == K_TUPLE) {
        TupT *t = as_tup(x);
        for (uint32_t j = 0; j < t->len && j < 8; j++)
          if ((t->e[j] & 1) && int_val(t->e[j]) >= s && int_val(t->e[j]) < e) hit = true;
      }
      if (!hit) continue;
      int64_t cs = start_before(g, c);
      fprintf(stderr, "  cell %lld (kind %d, object at %lld%s) holds %s\n", (long long)c, kind_at(g, c), (long long)cs,
              cell_dead(h->cells[cs]) ? ", freed" : "", ty_to_cstr_short(x));
      shown++;
    }
    print_backtrace();
  }
  die("%s of a freed cell %lld: the cell store's collector freed a live object", what, (long long)i);
}

// ---------------------------------------------------------------------------
// Allocation

static void free_push(CellGc *g, int64_t s, int64_t n) {
  g->free_cells += n;
  if (n <= SMALL_MAX) {
    ivec_push(&g->small[n], s);
    g->small_nz[n >> 6] |= (uint64_t)1 << (n & 63);
  } else {
    int b = 63 - __builtin_clzll((uint64_t)n);
    ivec_push(&g->big[b], s);
    g->big_nz |= (uint64_t)1 << b;
  }
}

// the last run of a list taken out
static inline int64_t small_pop(CellGc *g, int64_t k) {
  int64_t s = g->small[k].d[--g->small[k].n];
  if (!g->small[k].n) g->small_nz[k >> 6] &= ~((uint64_t)1 << (k & 63));
  return s;
}
static inline void big_drop(CellGc *g, int b, int64_t k) {
  IVec *v = &g->big[b];
  v->d[k] = v->d[--v->n];
  if (!v->n) g->big_nz &= ~((uint64_t)1 << b);
}

// the first small list at or after k that is not empty, SMALL_MAX + 1 when none
static inline int64_t small_next(CellGc *g, int64_t k) {
  if (k < 64) {
    uint64_t m = g->small_nz[0] & (~(uint64_t)0 << k);
    if (m) return __builtin_ctzll(m);
    k = 64;
  }
  if (k <= SMALL_MAX && (g->small_nz[1] & ((uint64_t)1 << (k - 64)))) return k;
  return SMALL_MAX + 1;
}

static void lists_clear(CellGc *g) {
  for (int k = 0; k <= SMALL_MAX; k++) g->small[k].n = 0;
  for (int k = 0; k < 64; k++) g->big[k].n = 0;
  g->small_nz[0] = g->small_nz[1] = 0;
  g->big_nz = 0;
}

static inline bool is_free_start(CellGc *g, int64_t s) { return (g->freeb[s >> 6] >> (s & 63)) & 1; }

static inline int64_t free_len(HeapT *h, int64_t s) {
  V v = h->cells[s];
  if (!cell_is_free_hdr(v)) die("cell store: free run %lld is corrupted (a freed cell was written)", (long long)s);
  return (int64_t)(v >> 16);
}

// a free run of at least n cells, its first n taken: -1 when none
static int64_t take_free(HeapT *h, int64_t n) {
  CellGc *g = h->gc;
  int64_t s = -1, m = 0;
  int64_t k = n;
  // an exact fit, else the smallest longer short run (entries of runs taken
  // in address order since are dropped)
  if (n <= SMALL_MAX)
    for (k = small_next(g, k); k <= SMALL_MAX; k = small_next(g, k)) {
      IVec *v = &g->small[k];
      while (v->n && !is_free_start(g, v->d[v->n - 1])) v->n--;
      if (v->n) break;
      g->small_nz[k >> 6] &= ~((uint64_t)1 << (k & 63));
    }
  if (n <= SMALL_MAX && k <= SMALL_MAX) {
    s = small_pop(g, k);
    m = free_len(h, s);
    if (m != k) die("cell store: free run %lld has %lld cells, not %lld", (long long)s, (long long)m, (long long)k);
  } else {
    int b = n <= SMALL_MAX ? 63 - __builtin_clzll((uint64_t)SMALL_MAX + 1) : 63 - __builtin_clzll((uint64_t)n);
    IVec *v = &g->big[b];
    // a run of the same class that fits (a few tried)
    for (int64_t k = v->n - 1; k >= 0 && k >= v->n - 8; k--) {
      if (!is_free_start(g, v->d[k])) {
        big_drop(g, b, k);
        continue;
      }
      int64_t l = free_len(h, v->d[k]);
      if (l >= n) {
        s = v->d[k];
        m = l;
        big_drop(g, b, k);
        break;
      }
    }
    while (s < 0 && b < 63) {
      uint64_t above = g->big_nz & (~(uint64_t)0 << (b + 1));
      if (!above) break;
      int c = __builtin_ctzll(above);
      int64_t r = g->big[c].d[g->big[c].n - 1];
      big_drop(g, c, g->big[c].n - 1);
      if (!is_free_start(g, r)) continue;
      s = r;
      m = free_len(h, s);
    }
    if (s < 0) return -1;
  }
  g->free_cells -= m;
  g->freeb[s >> 6] &= ~((uint64_t)1 << (s & 63));
  if (m > n) {
    set_start(g, s + n);
    g->freeb[(s + n) >> 6] |= (uint64_t)1 << ((s + n) & 63);
    h->cells[s + n] = free_hdr(m - n);
    free_push(g, s + n, m - n);
  }
  return s;
}

// what is left of the run allocated from becomes a free run again (before
// a collection looks at the objects: until then it is part of the last one)
static void flush_cur(HeapT *h) {
  CellGc *g = h->gc;
  if (g->cur < g->cur_end) {
    int64_t s = g->cur, n = g->cur_end - s;
    set_start(g, s);
    h->cells[s] = free_hdr(n);
    g->freeb[s >> 6] |= (uint64_t)1 << (s & 63);
    free_push(g, s, n);
  }
  g->cur = g->cur_end = 0;
}

// the next free run of at least n cells in address order (at or after
// g->scan), out of the lists (its entry is dropped when found there): false
// when there is none before the top. Shorter runs are passed over (they
// stay in the lists).
static bool take_next(HeapT *h, int64_t n, int64_t *s, int64_t *m) {
  CellGc *g = h->gc;
  int64_t top = top_of(h), i = g->scan;
  while (i < top) {
    int64_t w = i >> 6;
    uint64_t f = g->freeb[w] & (~(uint64_t)0 << (i & 63));
    if (!f) {
      i = (w + 1) << 6;
      continue;
    }
    int64_t r = (w << 6) + __builtin_ctzll(f);
    if (r >= top) break;
    int64_t l = free_len(h, r);
    if (l < n) {
      i = r + 1;
      continue;
    }
    g->scan = r + l;
    *s = r;
    *m = l;
    g->free_cells -= l;
    g->freeb[r >> 6] &= ~((uint64_t)1 << (r & 63));
    return true;
  }
  g->scan = top;
  return false;
}

// n cells with kinds pat[0..np) repeated (np divides n): the first; the
// caller fills them. A write (the heap's next version). Small objects are
// allocated in address order, from the free runs a collection left (what is
// allocated together stays together), then from the top; others take the run
// that fits best.
int64_t cells_alloc(HeapT *h, int64_t n, const uint8_t *pat, int64_t np) {
  CellGc *g = h->gc;
  int64_t s = -1;
  if (n > 0 && !debug_mode) {
    if (g->cur + n <= g->cur_end) {
      s = g->cur;
      g->cur += n;
      set_start(g, s);
    } else if (g->free_cells >= n) {
      int64_t rs, rm;
      if (n < SMALL_CELLS) {
        // (past the last free run: from the top; the short runs passed
        // over wait for the next sweep)
        flush_cur(h);
        if (take_next(h, n, &rs, &rm)) {
          s = rs;
          g->cur = rs + n;
          g->cur_end = rs + rm;
        }
      } else {
        s = take_free(h, n);
      }
    }
  }
  if (s < 0) {
    s = top_of(h);
    if (s + n > h->cap) die("out of memory: the cell store has %lld cells", (long long)h->cap);
    // a small object from the top: a run of TOP_RUN cells taken with it, the
    // next ones allocated from there inline (flush_cur makes what is left a
    // free run before a collection; a forked child, cells_after_fork, and a
    // store without free runs allocate only so). Only in a forked child of a
    // program that declares that it does not observe where its objects are
    // (the reuse of cells): the top moves past the run (where lib/pure's
    // halloc, which the natives are checked against, puts the next object)
    int64_t e = s + n;
    if (n > 0 && n < SMALL_CELLS && !debug_mode && top_runs && s + TOP_RUN <= h->cap) {
      flush_cur(h);
      s = top_of(h);
      e = s + TOP_RUN;
      g->cur = s + n;
      g->cur_end = e;
    }
    h->cells[0] = mk_int(e);
    if (h->len < e) h->len = e;
    if (n > 0) set_start(g, s);
  }
  if (np == 1) fill_kinds(g, s, n, pat[0]);
  else {
    // (patterns are mostly scalars: those cleared at once, the others set)
    clear_kinds(g, s, n);
    for (int64_t k = 0; k < np; k++)
      if (pat[k] != GK_NOSCAN)
        for (int64_t i = 0; i < n; i += np) set_kind(g, s + i + k, pat[k]);
  }
  h->version++;
  cells_since += n;
  return s;
}

// kinds of a zero pattern
void cells_zero_kinds(const V *z, int64_t nz, uint8_t *out) {
  for (int64_t i = 0; i < nz; i++) out[i] = (uint8_t)zero_kind(z[i]);
}

int64_t cells_alloc_kind(HeapT *h, int64_t n, int kind) {
  // (the common case first: from the run allocated from)
  CellGc *g = h->gc;
  if (n > 0 && g->cur + n <= g->cur_end) {
    int64_t s = g->cur;
    g->cur += n;
    set_start(g, s);
    fill_kinds(g, s, n, kind);
    h->version++;
    cells_since += n;
    return s;
  }
  uint8_t k = (uint8_t)kind;
  return cells_alloc(h, n, &k, 1);
}

// ---------------------------------------------------------------------------
// Marking

static int64_t marked_cells;  // by the last collection

static void hk_cand(int64_t n) {
  for (uint32_t k = 0; k < *gnheaps; k++) {
    HeapT *h = gheaps[k];
    if (!h || !h->gc) continue;
    CellGc *g = h->gc;
    if (n < g->base || n >= top_of(h)) continue;
    int64_t s = start_before(g, n);
    if (bit(g->mark, s)) continue;
    if (bit(g->freeb, s) || (debug_mode && cell_is_poison(h->cells[s]))) continue;
    uint64_t b = (uint64_t)1 << (s & 63);
    if (__atomic_fetch_or(&g->mark[s >> 6], b, __ATOMIC_RELAXED) & b) continue;
    int64_t e = start_after(g, s, top_of(h));
    gc_add_marked_cells(e - s);
    gc_push_range(h->cells + s, (size_t)(e - s) * 8, GC_CELLS);
  }
}

static void hk_begin(void) {
  int64_t hi = 0, lo = INT64_MAX;
  for (uint32_t k = 0; k < *gnheaps; k++) {
    HeapT *h = gheaps[k];
    if (!h || !h->gc) continue;
    flush_cur(h);
    CellGc *g = h->gc;
    if (top_of(h) > hi) hi = top_of(h);
    if (g->base < lo) lo = g->base;
    g->mark[0] |= 1;
    gc_add_marked_cells(g->base);
    gc_push_range(h->cells, (size_t)g->base * 8, GC_CELLS);
  }
  gc_cand_lo = lo;
  gc_cand_hi = hi;
  gc_cells_fast.start = gc_cells_fast.mark = NULL;
  if (*gnheaps == 1 && gheaps[0] && gheaps[0]->gc) {
    gc_cells_fast.start = gheaps[0]->gc->start;
    gc_cells_fast.mark = gheaps[0]->gc->mark;
  }
}

// An immediate in a cell of a scalar type is no cell index; anything else is
// scanned conservatively, with candidates. (Never without: an object is
// scanned in the mode it is first reached in, values share blocks, and a cell
// of a scalar type may hold more than a scalar.)
static inline void scan_cell(CellGc *g, V v, int64_t i) {
  if (kind_at(g, i) == GK_NOSCAN) {
    if (!(v & 3) && v) gc_mark(v, true);
    return;
  }
  gc_mark(v, true);
}

// cells of marked objects (GC_CELLS ranges), 4096 at a time
static void scan_gocells(char *p, size_t nb, bool cand) {
  (void)cand;
  HeapT *h = NULL;
  for (uint32_t k = 0; k < *gnheaps; k++) {
    HeapT *x = gheaps[k];
    if (x && x->gc && (V *)p >= x->cells && (V *)p < x->cells + x->cap) {
      h = x;
      break;
    }
  }
  if (!h) die("cell store: cells to scan in no heap");
  int64_t i = (V *)p - h->cells, end = i + (int64_t)(nb / 8);
  if (end - i > 4096) {
    gc_push_range(h->cells + i + 4096, (size_t)(end - i - 4096) * 8, GC_CELLS);
    end = i + 4096;
  }
  CellGc *g = h->gc;
  V *cells = h->cells;
  if (verify) {
    for (; i < end; i++) {
      gc_cur_cell = i;
      scan_cell(g, cells[i], i);
    }
    gc_cur_cell = -1;
    return;
  }
  while (i < end) {
    // 32 cells share a word of kinds: all scalar ones (the usual case) only
    // look at their pointers
    if (!(i & 31) && i + 32 <= end) {
      uint64_t kw = g->kinds[i >> 5];
      const V *c = cells + i;
      if (kw == 0) {
        for (int k = 0; k < 32; k++)
          if (!(c[k] & 3) && c[k]) gc_mark(c[k], true);
      } else
        for (int k = 0; k < 32; k++) {
          V v = c[k];
          if ((kw >> (2 * k)) & 3) gc_mark(v, true);
          else if (!(v & 3) && v) gc_mark(v, true);
        }
      i += 32;
      continue;
    }
    scan_cell(g, cells[i], i);
    i++;
  }
}

// a plain collection: the cells in use are roots, whatever they hold (free
// runs are skipped: their pages may have gone back to the system)
static void hk_roots(void) {
  // (a program without a cell store)
  if (!gnheaps) return;
  for (uint32_t k = 0; k < *gnheaps; k++) {
    HeapT *h = gheaps[k];
    if (!h || h->len <= 0) continue;
    CellGc *g = h->gc;
    flush_cur(h);
    int64_t top = top_of(h), s = 0, run = 0;
    if (g->has_free) {
      while (s < top) {
        int64_t e = start_after(g, s, top);
        if (bit(g->freeb, s) || (debug_mode && cell_is_poison(h->cells[s]))) {
          if (s > run) gc_scan_range(h->cells + run, (size_t)(s - run) * 8, false);
          run = e;
        }
        s = e;
      }
    }
    if (h->len > run) gc_scan_range(h->cells + run, (size_t)(h->len - run) * 8, false);
  }
}

// ---------------------------------------------------------------------------
// Sweeping

static int64_t freed_now;

// The pages inside [a, b), free cells, may go back to the system: they then
// read as 0 (or keep their values; free cells are not read).
static void release(HeapT *h, int64_t a, int64_t b) {
  static uintptr_t page;
  if (b - a < ((int64_t)1 << 17)) return;  // 1 MB
  if (!page) page = (uintptr_t)getpagesize();
  uintptr_t pa = ((uintptr_t)(h->cells + a) + page - 1) & ~(page - 1);
  uintptr_t pb = (uintptr_t)(h->cells + b) & ~(page - 1);
  if (pb <= pa) return;
#if defined(MADV_FREE_REUSABLE)
  madvise((void *)pa, pb - pa, MADV_FREE_REUSABLE);
#elif defined(MADV_FREE)
  madvise((void *)pa, pb - pa, MADV_FREE);
#else
  madvise((void *)pa, pb - pa, MADV_DONTNEED);
#endif
}

// debug: each object freed on its own (nothing is reused), its cells
// poisoned with the collection's number
static void sweep_heap_debug(HeapT *h) {
  CellGc *g = h->gc;
  int64_t top = top_of(h);
  int64_t lo = g->sweep_lo > g->base ? g->sweep_lo : g->base;
  int64_t s = lo < top ? start_before(g, lo) : top;
  if (s < lo) s = start_after(g, s, top);
  V poison = ((V)(cell_collections + 1) << 16) | V_POISON;
  while (s < top) {
    int64_t e = start_after(g, s, top);
    if (!bit(g->mark, s) && !cell_is_poison(h->cells[s])) {
      freed_now += e - s;
      for (int64_t k = s; k < e; k++) h->cells[k] = poison;
      g->has_free = true;
    }
    s = e;
  }
  memset(g->mark, 0, (size_t)((top + 63) >> 6) * 8);
}

// A sweep of [a, b): free objects and free runs between live objects merge
// into free runs (only the bitmaps are read, a word of 64 cells at a time).
// Several run at once on parts of the store that begin at a live object (a
// run never crosses them); the bitmaps' words they share are changed with
// atomic operations, their runs go to lists of their own.
typedef struct {
  HeapT *h;
  int64_t a, b;
  int64_t freed, free_cells;
  int64_t open, open_free;  // the run still open at b (-1: none), its cells free before
  IVec small[SMALL_MAX + 1], big[64];
} SweepPart;

static inline void and_word(uint64_t *w, uint64_t m) { __atomic_fetch_and(w, m, __ATOMIC_RELAXED); }
static inline void or_word(uint64_t *w, uint64_t m) { __atomic_fetch_or(w, m, __ATOMIC_RELAXED); }

static void part_close(SweepPart *p, int64_t s, int64_t e) {
  HeapT *h = p->h;
  CellGc *g = h->gc;
  int64_t n = e - s;
  h->cells[s] = free_hdr(n);
  or_word(&g->freeb[s >> 6], (uint64_t)1 << (s & 63));
  p->free_cells += n;
  if (n <= SMALL_MAX) ivec_push(&p->small[n], s);
  else ivec_push(&p->big[63 - __builtin_clzll((uint64_t)n)], s);
}

static void *sweep_part(void *arg) {
  SweepPart *p = arg;
  HeapT *h = p->h;
  CellGc *g = h->gc;
  int64_t a = p->a, b = p->b, run = -1, was_free = 0;
  if (b > a) {
    int64_t w0 = a >> 6, w1 = (b - 1) >> 6;
    for (int64_t w = w0; w <= w1; w++) {
      uint64_t S = g->start[w];
      if (!S) continue;
      if (w == w0) S &= ~(uint64_t)0 << (a & 63);
      if (w == w1 && (b & 63)) S &= ~(uint64_t)0 >> (64 - (b & 63));
      uint64_t M = g->mark[w] & S;
      if (run < 0 && M == S) continue;
      uint64_t F = g->freeb[w] & S;
      uint64_t clear_s = 0;
      while (S) {
        int bi = __builtin_ctzll(S);
        S &= S - 1;
        int64_t c = (w << 6) + bi;
        if ((M >> bi) & 1) {
          if (run >= 0) {
            p->freed += c - run - was_free;
            part_close(p, run, c);
            run = -1;
          }
          continue;
        }
        int64_t fl = 0;  // a free run already
        if ((F >> bi) & 1) {
          // (now: a run closed later in this word may begin here)
          fl = free_len(h, c);
          and_word(&g->freeb[w], ~((uint64_t)1 << bi));
        }
        if (run < 0) {
          run = c;
          was_free = fl;
        } else {
          was_free += fl;
          clear_s |= (uint64_t)1 << bi;
        }
      }
      if (clear_s) {
        uint64_t old = __atomic_fetch_and(&g->start[w], ~clear_s, __ATOMIC_RELAXED);
        if (!(old & ~clear_s)) and_word(&g->l1[w >> 6], ~((uint64_t)1 << (w & 63)));
      }
    }
  }
  p->open = run;
  p->open_free = was_free;
  return NULL;
}

// the first live object at or after i (its first cell), or b
static int64_t live_after(CellGc *g, int64_t i, int64_t b) {
  for (int64_t w = i >> 6; (w << 6) < b; w++) {
    uint64_t m = g->start[w] & g->mark[w];
    if (w == i >> 6) m &= ~(uint64_t)0 << (i & 63);
    if (m) {
      int64_t c = (w << 6) + __builtin_ctzll(m);
      return c < b ? c : b;
    }
  }
  return b;
}

static int sweep_threads(void) {
  static int n;
  if (!n) {
    const char *e = getenv("TSTC_GC_THREADS");
    n = e ? atoi(e) : 4;
    if (n < 1) n = 1;
    if (n > 16) n = 16;
  }
  return n;
}

static void sweep_heap(HeapT *h) {
  CellGc *g = h->gc;
  int64_t top = top_of(h);
  if (debug_mode) {
    sweep_heap_debug(h);
    return;
  }
  lists_clear(g);
  g->free_cells = 0;
  int64_t lo = g->sweep_lo > g->base ? g->sweep_lo : g->base;
  g->scan = lo;
  g->tail_lo = g->tail_hi = 0;
  // the parts (a few, for a large store), each but the first beginning at a
  // live object
  int np = top - lo > ((int64_t)1 << 22) ? sweep_threads() : 1;
  SweepPart *parts = calloc((size_t)np, sizeof(SweepPart));
  int64_t at = lo;
  int k = 0;
  for (int i = 0; i < np; i++) {
    int64_t want = lo + (top - lo) / np * i;
    int64_t a = i == 0 ? lo : live_after(g, want > at ? want : at, top);
    if (i > 0 && a <= parts[k - 1].a) continue;
    parts[k].h = h;
    parts[k].a = a;
    if (k > 0) parts[k - 1].b = a;
    at = a;
    k++;
  }
  parts[k - 1].b = top;
  pthread_t th[16];
  bool started[16] = {false};
  for (int i = 1; i < k; i++) started[i] = pthread_create(&th[i], NULL, sweep_part, &parts[i]) == 0;
  sweep_part(&parts[0]);
  for (int i = 1; i < k; i++) {
    if (started[i]) pthread_join(th[i], NULL);
    else sweep_part(&parts[i]);
  }
  // a run open at the end of a part ends at the next one's first (live)
  // object
  for (int i = 0; i < k; i++) {
    SweepPart *p = &parts[i];
    if (p->open >= 0 && i + 1 < k) {
      p->freed += p->b - p->open - p->open_free;
      part_close(p, p->open, p->b);
      p->open = -1;
    }
    freed_now += p->freed;
    g->free_cells += p->free_cells;
    if (p->free_cells) g->has_free = true;
    for (int n = 0; n <= SMALL_MAX; n++) {
      for (int64_t j = 0; j < p->small[n].n; j++) ivec_push(&g->small[n], p->small[n].d[j]);
      if (g->small[n].n) g->small_nz[n >> 6] |= (uint64_t)1 << (n & 63);
      free(p->small[n].d);
    }
    for (int c = 0; c < 64; c++) {
      for (int64_t j = 0; j < p->big[c].n; j++) ivec_push(&g->big[c], p->big[c].d[j]);
      if (g->big[c].n) g->big_nz |= (uint64_t)1 << c;
      free(p->big[c].d);
    }
  }
  SweepPart *last = &parts[k - 1];
  int64_t run = last->open;
  if (run >= 0) {
    // a free run at the end: the allocation pointer moves back over it
    freed_now += top - run - last->open_free;
    g->tail_lo = run;
    g->tail_hi = top;
    clear_start(g, run);
    h->cells[0] = mk_int(run);
    h->len = run;
  }
  free(parts);
  // clear the marks
  memset(g->mark, 0, (size_t)((top + 63) >> 6) * 8);
}

// TSTC_CELLGC_VERIFY=1 (with the debug mode): before sweeping, integers in
// live cells and objects that name unmarked objects (what a precise scan
// would have kept, if they are pointers)

static bool unmarked_target(HeapT *h, V x, int64_t *ts) {
  if (!(x & 1)) return false;
  CellGc *g = h->gc;
  int64_t n = int_val(x);
  if (n < g->base || n >= top_of(h)) return false;
  int64_t s = start_before(g, n);
  if (bit(g->mark, s) || cell_dead(h->cells[s])) return false;
  *ts = s;
  return true;
}

static void verify_object(char *p, size_t n, int flavor) {
  if (flavor == GC_ATOMIC || flavor == GC_MAP || verify_shown > 200) return;
  HeapT *h = gheaps[0];
  V *w = (V *)p;
  for (size_t i = 0; i < n / 8; i++) {
    if (flavor == GC_MNODE && (i < 3 || (i - 3) % 3 == 2)) continue;  // header, hashes
    int64_t ts;
    if (unmarked_target(h, w[i], &ts)) {
      fprintf(stderr, "cell gc verify: C object %p (tag %u, flavor %d, %zu bytes) word %zu = %lld -> unmarked object at %lld (kinds %d %d)\n",
              (void *)p, *(uint32_t *)p, flavor, n, i, (long long)int_val(w[i]), (long long)ts, kind_at(h->gc, ts),
              kind_at(h->gc, ts + 1));
      if (++verify_shown > 200) return;
    }
  }
}

// Free cells beyond what is live (and 256 MB) go back to the system, the
// longest runs first; the rest stays for the next allocations (giving pages
// back and touching them again costs more than the collection)
static void release_excess(HeapT *h) {
  CellGc *g = h->gc;
  int64_t keep = marked_cells > ((int64_t)32 << 20) ? marked_cells : ((int64_t)32 << 20);
  int64_t excess = g->free_cells + (g->tail_hi - g->tail_lo) - keep;
  for (int c = 63; c >= 17 && excess > 0; c--)
    for (int64_t k = 0; k < g->big[c].n && excess > 0; k++) {
      int64_t r = g->big[c].d[k], n = free_len(h, r);
      release(h, r + 1, r + n);
      excess -= n;
    }
  if (excess > 0) release(h, g->tail_lo, g->tail_hi);
}

static void hk_sweep(void) {
  freed_now = 0;
  marked_cells = gc_marked_cells;
  gc_cells_fast.start = gc_cells_fast.mark = NULL;
  if (verify && gnheaps && *gnheaps > 0) {
    verify_shown = 0;
    fprintf(stderr, "cell gc verify: collection %zu\n", cell_collections + 1);
    gc_each_marked(verify_object);
  }
  int64_t used = 0, live = 0;
  for (uint32_t k = 0; k < *gnheaps; k++) {
    HeapT *h = gheaps[k];
    if (!h || !h->gc) continue;
    sweep_heap(h);
    if (!debug_mode) release_excess(h);
    used += top_of(h) - h->gc->free_cells;
  }
  live = marked_cells;
  gc_extra_live = (size_t)used * 8;
  cells_since = 0;
  if (trace)
    fprintf(stderr, "cell gc: %lld cells marked, %lld freed, %lld in use\n", (long long)live, (long long)freed_now,
            (long long)used);
}

static const GcCellHooks hooks = {hk_roots, hk_begin, hk_cand, hk_sweep};

void cells_gc_init(void) {
  gc_set_cell_hooks(&hooks);
  gc_set_scanner(GC_CELLS, scan_gocells);
}

// ---------------------------------------------------------------------------
// Safe points

void cells_safepoint_slow(V a, V b, V c, V d) {
  // cells are freed only when the store says reuse is unobservable
  if (gc_is_disabled() || !(tstc_store.flags & STORE_F_REUSE)) return;
  bool due = cells_since >= cells_threshold || gc_due();
  if (cells_stress > 0 && ++stress_count >= cells_stress) {
    stress_count = 0;
    due = true;
  }
  if (!due) return;
  sp_roots[0] = a;
  sp_roots[1] = b;
  sp_roots[2] = c;
  sp_roots[3] = d;
  struct timespec t0, t1;
  clock_gettime(CLOCK_MONOTONIC, &t0);
  gc_collect_cells();
  // the next one after allocating (growth times) as many cells as there are
  // bytes live, the runtime's included, over 8: a collection marks them all
  int64_t t = (int64_t)((marked_cells + (int64_t)(gc_bytes_live / 8)) * growth);
  cells_threshold = t > min_cells ? t : min_cells;
  clock_gettime(CLOCK_MONOTONIC, &t1);
  cell_collections++;
  cell_ms += (t1.tv_sec - t0.tv_sec) * 1000.0 + (t1.tv_nsec - t0.tv_nsec) / 1e6;
  memset(sp_roots, 0, sizeof sp_roots);
}

size_t gc_fork_budget(void);

// a forked child: what the parent allocated stays where it is (its pages
// are shared), new objects come from the top
void cells_after_fork(void) {
  cells_since = 0;
  top_runs = (tstc_store.flags & STORE_F_REUSE) != 0;
  cell_collections = 0;
  cell_ms = 0;
  if (!gnheaps) return;
  // as gc_after_fork: a budget of the cells the parent has in use, at least
  // gc_fork_budget
  int64_t b = (int64_t)(gc_extra_live / 8);
  if (b < (int64_t)(gc_fork_budget() / 8)) b = (int64_t)(gc_fork_budget() / 8);
  if (getenv("TSTC_GC_FORK_BUDGET")) b = (int64_t)atoll(getenv("TSTC_GC_FORK_BUDGET")) << 17;
  if (cells_threshold < b) cells_threshold = b;
  for (uint32_t k = 0; k < *gnheaps; k++) {
    HeapT *h = gheaps[k];
    if (!h || !h->gc) continue;
    CellGc *g = h->gc;
    lists_clear(g);
    g->free_cells = 0;
    g->cur = g->cur_end = 0;
    g->sweep_lo = g->scan = top_of(h);
  }
}

// cells allocated above where the process started (a forked child: the top
// at the fork)
int64_t cells_new(void) {
  int64_t n = 0;
  if (!gnheaps) return 0;
  for (uint32_t k = 0; k < *gnheaps; k++) {
    HeapT *h = gheaps[k];
    if (h && h->gc) n += top_of(h) - h->gc->sweep_lo;
  }
  return n;
}

void cells_gc_stats(FILE *f) {
  if (!cell_collections || !gnheaps) return;
  int64_t len = 0, used = 0;
  for (uint32_t k = 0; k < *gnheaps; k++) {
    HeapT *h = gheaps[k];
    if (!h || !h->gc) continue;
    len += h->len;
    used += top_of(h) - h->gc->free_cells;
  }
  fprintf(f, "cell store: %zu collections, %.0f ms, %lld MB in use, %lld MB spanned\n", cell_collections, cell_ms,
          (long long)(used >> 17), (long long)(len >> 17));
}
