// Shared helpers of the natives of lib/pure (prim.c, heap.c, map.c, proc.c).
#ifndef TSTC_LIB_H
#define TSTC_LIB_H

#include "tstc.h"

// a value as an integer, string, boolean (the common cases inline; the
// others, and dying on a value of another type, out of line)
int64_t gi_slow(V t);
Str *gs_slow(V t);
bool gb_slow(V t);
static inline int64_t gi(V t) { return (t & 1) ? ((int64_t)t) >> 1 : gi_slow(t); }
static inline Str *gs(V t) { return !(t & 3) && t && ((Hdr *)t)->tag == K_STRLIT ? (Str *)t : gs_slow(t); }
static inline bool gb(V t) { return t == V_TRUE ? true : t == V_FALSE ? false : gb_slow(t); }
double gf(V t);
V fl(double d);
uint32_t key_hash(V t);
bool key_eq(V a, V b);
void utf8_put(SB *b, int64_t r);
int64_t utf8_decode_at(Str *s, int32_t i, int32_t *size);

// the heap: a persistent array of cells (heap.c)
typedef struct HeapT HeapT;
typedef struct CellGc CellGc;
struct HeapT {
  uint32_t tag, id;
  V *cells;          // reserved address space (cap cells), touched as used
  int64_t len, cap;
  uint64_t version;  // writes so far: a heap value names one (heap_v)
  CellGc *gc;          // the collector's state (cellgc.c)
};
V heap_v(HeapT *h);
HeapT *heap_of(V t);
V *heap_cells(HeapT *h, int64_t *len);  // re-roots
V heap_get(HeapT *h, int64_t i);
HeapT *heap_set(HeapT *h, int64_t i, V x);
int64_t cell_index(V p);
extern HeapT *heap_latest;  // the newest version (what a goroutine continues with)

// The collector of the heap (cellgc.c). Free cells hold FREE headers (a run's
// first) and POISON, or 0 where pages went back to the system.
#define V_POISON (((V)61 << 3) | 2)
static inline V free_hdr(int64_t n) { return ((V)n << 16) | ((V)62 << 3) | 2; }
static inline bool cell_is_free_hdr(V v) { return (v & 0x1FF) == (((V)62 << 3) | 2); }
static inline bool cell_is_poison(V v) { return (v & 0x1FF) == V_POISON; }  // (debug: | collection << 16)
static inline bool cell_dead(V v) { return v == 0 || cell_is_poison(v) || cell_is_free_hdr(v); }
_Noreturn void cells_dead_cell(HeapT *h, int64_t i, const char *what);
void cells_heap_init(HeapT *h, VA *init);
void cells_set_heaps(HeapT **hs, uint32_t *n);
int64_t cells_alloc(HeapT *h, int64_t n, const uint8_t *pat, int64_t np);
int64_t cells_alloc_kind(HeapT *h, int64_t n, int kind);  // GK_*: 0 no pointers, 3 conservative
void cells_zero_kinds(const V *z, int64_t nz, uint8_t *out);
extern uint8_t cells_kind_of[64];  // the kind of a cell allocated with a value, by kind(value)
// a safe point of the cell store's collector (an allocating native, before it
// looks at its arguments; a, b, c, d: what it still needs). The common case
// (no collection due) inline.
extern int64_t cells_since, cells_threshold, cells_stress;
void cells_safepoint_slow(V a, V b, V c, V d);
static inline void cells_safepoint4(V a, V b, V c, V d) {
  if (__builtin_expect(cells_since >= cells_threshold || gc_grown_since > gc_due_at || cells_stress > 0, 0))
    cells_safepoint_slow(a, b, c, d);
}
void cells_after_fork(void);
void cells_gc_init(void);
// Values a cell owns: natives may change a value of such a kind in place
// while only its cell has it (map.c); reading it out of the cell as a value
// (cell_out) freezes it.
void store_owned_kind(int kind, void (*freeze)(V));
extern void (*store_freeze[K_COUNT])(V);
static inline V cell_out(V v) {
  if ((v & 3) == 0 && v) {
    unsigned k = (unsigned)kind(v);
    if (k < K_COUNT && store_freeze[k]) store_freeze[k](v);
  }
  return v;
}

// maps (map.c)
V map_empty(void);
V map_get(V m, V k);     // 0 when absent
V map_add(V m, V k, V v);
V map_remove(V m, V k);
int64_t map_len(V m);
void map_keys(V m, VA *out);

// output (main.c)
void emit_bytes(const uint8_t *b, size_t n);
extern const char *emit_path;
extern uint8_t *crash_note;  // written before a fatal error (crash_note)
extern size_t crash_note_len;

#endif
