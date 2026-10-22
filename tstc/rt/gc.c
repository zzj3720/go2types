// Conservative mark-sweep garbage collector.
//
// Memory comes in 1 MiB aligned chunks. A small-object chunk holds objects of
// one size class; a large object gets a span of chunks of its own. Any word
// that points into an object (interior pointers included) keeps it alive.
// Roots: the stacks and registers of every thread, and registered ranges.
// Program code runs on one thread (a program's own concurrency, as tstst's
// goroutines, is scheduled in the program), so the collector runs on that
// thread; threads registered otherwise are scanned with the registers they
// saved.
#include "tstc.h"

#include <pthread.h>
#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <time.h>
#include <unistd.h>

#ifndef CHUNK_SHIFT
#define CHUNK_SHIFT 20
#endif
#define CHUNK_SIZE ((size_t)1 << CHUNK_SHIFT)
// small chunks are cut from regions of this size (fewer system calls)
#define REGION_SIZE ((size_t)4 << 20)
#define LARGE_CLS 0xFFFF

typedef struct Chunk {
  uint32_t cls;     // size class index, LARGE_CLS for a large object span
  uint32_t size;    // object size
  uint32_t nobj;
  uint8_t flavor;   // GC_PLAIN, GC_ATOMIC, or a typed layout (GC_MAP, GC_MNODE)
  uint8_t marked;   // large objects
  uint8_t free;     // in the free chunk pool (2: since before the last sweep)
  uint8_t unswept;  // its marks say which objects are free (swept when allocated from)
  uint64_t recip;   // (offset * recip) >> 40 == offset / size
  size_t span;      // large: bytes of the span (a multiple of CHUNK_SIZE)
  size_t large;     // large: bytes of the object
  char *data;
  struct Chunk *next;
  struct Chunk *unext;  // in unswept[cls][flavor]
  uint64_t mark[];
} Chunk;

static const uint32_t class_sizes[] = {
    16,   24,   32,   40,   48,   64,   80,   96,   112,  128,  160,  192,  224,  256,
    320,  384,  448,  512,  640,  768,  896,  1024, 1280, 1536, 2048, 2560,
    3072, 4096, 5120, 6144, 8192, 10240, 12288, 16384, 20480, 24576, 32768};
// objects up to a quarter of a chunk are small
#define MAX_SMALL (CHUNK_SIZE / 4 < 32768 ? CHUNK_SIZE / 4 : 32768)
#define NCLS_ALL (sizeof(class_sizes) / sizeof(class_sizes[0]))
#define NCLS (CHUNK_SHIFT >= 17 ? NCLS_ALL : CHUNK_SHIFT == 16 ? NCLS_ALL - 3 : 0)
static uint8_t cls_of_8[MAX_SMALL / 8 + 1];  // (size + 7) / 8 -> class

// chunks with free objects (their marks say which), allocated from only when
// their class needs objects: a collection does not write to free objects
static Chunk *unswept[NCLS][GC_NFLAVORS];

// Objects of a class and flavor are handed out from a run of free objects
// (adjacent slots) by bumping a pointer. The runs come from the mark bits of
// a chunk (the objects the last collection did not mark are free), a mark
// word at a time, cleared as it is read; a fresh chunk is one run. Nothing
// reads or writes a free object before it is handed out.
typedef struct {
  char *cur, *end;  // the run
  Chunk *c;         // the chunk the next runs come from (NULL: none)
  uint64_t free;    // the free objects of mark word w not handed out as runs yet
  uint32_t w, nw;   // that word; the next one to read is w + 1 (of nw)
} Alloc;
static Alloc alloc_st[NCLS][GC_NFLAVORS];

// the next run of the chunk being allocated from (false: it has no more)
static bool next_run(Alloc *a, uint32_t size) {
  Chunk *c = a->c;
  if (!c) return false;
  while (!a->free) {
    if (a->w + 1 >= a->nw) {
      c->unswept = 0;
      a->c = NULL;
      return false;
    }
    a->w++;
    uint64_t m = c->mark[a->w];
    c->mark[a->w] = 0;
    a->free = ~m;
    uint32_t rest = c->nobj - a->w * 64;  // slots in this word
    if (rest < 64) a->free &= ((uint64_t)1 << rest) - 1;
  }
  int b = __builtin_ctzll(a->free);
  uint64_t taken = ~(a->free >> b);  // the first taken slot at or after b
  int len = taken ? __builtin_ctzll(taken) : 64 - b;
  a->free = b + len >= 64 ? 0 : a->free & (~(uint64_t)0 << (b + len));
  a->cur = c->data + ((size_t)a->w * 64 + (size_t)b) * size;
  a->end = a->cur + (size_t)len * size;
  // the whole run zeroed at once (memset clears whole cache lines without
  // reading them first)
  memset(a->cur, 0, (size_t)(a->end - a->cur));
  return true;
}

// a chunk with free objects to allocate from (its marks say which)
static void alloc_from(Alloc *a, Chunk *c) {
  a->c = c;
  a->nw = (c->nobj + 63) / 64;
  a->w = (uint32_t)-1;
  a->free = 0;
}

// the free objects not handed out are left for the next collection to find
// (as garbage): the marks of the chunks they are in go
static void drop_alloc(void) {
  for (uint32_t k = 0; k < NCLS; k++)
    for (int f = 0; f < GC_NFLAVORS; f++) {
      Alloc *a = &alloc_st[k][f];
      Chunk *c = a->c;
      if (c) {
        uint32_t w0 = a->w + 1;
        if (w0 < a->nw) memset(c->mark + w0, 0, (size_t)(a->nw - w0) * 8);
        c->unswept = 0;
      }
      memset(a, 0, sizeof *a);
      for (c = unswept[k][f]; c; c = c->unext) {
        memset(c->mark, 0, (size_t)((c->nobj + 63) / 64) * 8);
        c->unswept = 0;
      }
      unswept[k][f] = NULL;
    }
}
static Chunk *chunks;          // all chunks in use (small and large heads)
static Chunk *free_chunks;     // empty chunks to reuse
static Chunk **ctab;           // chunk index -> chunk (large: the head)
static uintptr_t ctab_lo, ctab_hi;  // chunk indices covered
static size_t heap_bytes;      // bytes in chunks in use
static size_t pool_bytes, large_bytes;  // bytes of free chunks; of large objects' spans
size_t gc_grown_since;  // bytes of chunks added since the last collection
static size_t threshold = (size_t)64 << 20;
size_t gc_due_at = ((size_t)64 << 20) / 4 * 3;  // gc_due() past it (threshold / 4 * 3)
static void set_threshold(size_t t) {
  threshold = t;
  gc_due_at = t / 4 * 3;
}
size_t gc_bytes_live, gc_collections;
// TSTC_GC_STATS=<file>: each process appends what it allocated at exit
static size_t st_small, st_nsmall, st_large, st_nlarge, st_chunks, st_reused;
static bool gc_disabled;

typedef struct Root { void *p; size_t n; struct Root *next; } Root;
static Root *roots;

struct GcThread {
  void *base;   // highest stack address
  void *sp;     // lowest live stack address while not running
  V *ebase;     // the environment stack
  V *etop;      // its top while not running
  jmp_buf regs;
  bool running;
  GcThread *next;
};
static GcThread *threads;
static __thread GcThread *self;

V *tstc_top;

static void fatal(const char *m) {
  fprintf(stderr, "gc: %s\n", m);
  abort();
}

// an environment stack: reserved, committed as used
V *env_stack_new(void) {
  size_t n = (size_t)4 << 30;
  void *p = mmap(NULL, n, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON | MAP_NORESERVE, -1, 0);
  if (p == MAP_FAILED) {
    n = (size_t)256 << 20;
    p = mmap(NULL, n, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (p == MAP_FAILED) fatal("cannot reserve an environment stack");
  }
  return p;
}

void gc_set_env_stack(V *base) {
  self->ebase = base;
  tstc_top = base;
}

// ---------------------------------------------------------------------------
// Chunks

static void *map_aligned(size_t n) {
  size_t len = n + CHUNK_SIZE;
  char *p = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
  if (p == MAP_FAILED) return NULL;
  uintptr_t a = ((uintptr_t)p + CHUNK_SIZE - 1) & ~(CHUNK_SIZE - 1);
  size_t head = a - (uintptr_t)p;
  if (head) munmap(p, head);
  size_t tail = len - head - n;
  if (tail) munmap((char *)a + n, tail);
  return (void *)a;
}

static char *region_cur, *region_end;

static void *map_chunk(void) {
  if (REGION_SIZE <= CHUNK_SIZE) return map_aligned(CHUNK_SIZE);
  if (region_cur == region_end) {
    char *p = map_aligned(REGION_SIZE);
    if (!p) return NULL;
    region_cur = p;
    region_end = p + REGION_SIZE;
  }
  void *c = region_cur;
  region_cur += CHUNK_SIZE;
  return c;
}

static void ctab_cover(uintptr_t lo, uintptr_t hi) {
  if (ctab && lo >= ctab_lo && hi <= ctab_hi) return;
  uintptr_t nlo = ctab ? (lo < ctab_lo ? lo : ctab_lo) : lo;
  uintptr_t nhi = ctab ? (hi > ctab_hi ? hi : ctab_hi) : hi;
  // leave room to grow on both sides
  uintptr_t pad = (nhi - nlo) / 2 + 64;
  nlo = nlo > pad ? nlo - pad : 0;
  nhi += pad;
  Chunk **nt = calloc(nhi - nlo, sizeof(Chunk *));
  if (!nt) fatal("out of memory (chunk table)");
  if (ctab) {
    memcpy(nt + (ctab_lo - nlo), ctab, (ctab_hi - ctab_lo) * sizeof(Chunk *));
    free(ctab);
  }
  ctab = nt;
  ctab_lo = nlo;
  ctab_hi = nhi;
}

static void ctab_set(void *p, size_t span, Chunk *c) {
  uintptr_t i0 = (uintptr_t)p >> CHUNK_SHIFT, i1 = i0 + span / CHUNK_SIZE;
  ctab_cover(i0, i1);
  for (uintptr_t i = i0; i < i1; i++) ctab[i - ctab_lo] = c;
}

static void maybe_collect(size_t n) {
  if (!gc_disabled && gc_grown_since + n > threshold && self) gc_collect();
}

static Chunk *new_small_chunk(uint32_t cls, int flavor) {
  Chunk *c = free_chunks;
  st_chunks++;
  if (c) {
    st_reused++;
    free_chunks = c->next;
    pool_bytes -= CHUNK_SIZE;
  } else {
    c = map_chunk();
    if (!c) {
      gc_collect();
      c = map_chunk();
      if (!c) fatal("out of memory");
    }
    ctab_set(c, CHUNK_SIZE, c);
    gc_grown_since += CHUNK_SIZE;
  }
  heap_bytes += CHUNK_SIZE;
  uint32_t size = class_sizes[cls];
  // header + mark bits, then objects
  size_t avail = CHUNK_SIZE - sizeof(Chunk);
  uint32_t nobj = (uint32_t)(avail / (size + 0.125));
  size_t hdr = sizeof(Chunk) + ((nobj + 63) / 64) * 8;
  hdr = (hdr + 15) & ~(size_t)15;
  nobj = (uint32_t)((CHUNK_SIZE - hdr) / size);
  memset(c, 0, hdr);
  c->cls = cls;
  c->size = size;
  c->nobj = nobj;
  c->flavor = (uint8_t)flavor;
  c->recip = (((uint64_t)1 << 40) + size - 1) / size;
  c->data = (char *)c + hdr;
  c->next = chunks;
  chunks = c;
  return c;
}

static void *alloc_large(size_t n, int flavor) {
  st_large += n;
  st_nlarge++;
  size_t hdr = (sizeof(Chunk) + 15) & ~(size_t)15;
  size_t span = (hdr + n + CHUNK_SIZE - 1) & ~(CHUNK_SIZE - 1);
  maybe_collect(span);
  gc_grown_since += span;
  Chunk *c = map_aligned(span);
  if (!c) {
    gc_collect();
    c = map_aligned(span);
    if (!c) fatal("out of memory (large object)");
  }
  memset(c, 0, hdr);
  c->cls = LARGE_CLS;
  c->size = 0;
  c->flavor = (uint8_t)flavor;
  c->span = span;
  c->large = n;
  c->data = (char *)c + hdr;
  c->next = chunks;
  chunks = c;
  ctab_set(c, span, c);
  heap_bytes += span;
  large_bytes += span;
  return c->data;  // fresh mmap memory is zero
}

static void init_classes(void) {
  uint32_t k = 0;
  for (uint32_t s = 0; s <= MAX_SMALL / 8; s++) {
    while (class_sizes[k] < s * 8) k++;
    cls_of_8[s] = (uint8_t)k;
  }
}

// the run is used up: the next one of the chunk allocated from, of an
// unswept chunk, after a collection, or a new chunk (its first object)
static __attribute__((noinline)) void *refill(uint32_t cls, int flavor) {
  Alloc *a = &alloc_st[cls][flavor];
  uint32_t size = class_sizes[cls];
  bool collected = false;
  for (;;) {
    if (next_run(a, size)) break;
    Chunk *c = unswept[cls][flavor];
    if (c) {
      unswept[cls][flavor] = c->unext;
      alloc_from(a, c);
      continue;
    }
    if (!free_chunks && !collected) {
      // (a collection drops the allocation state, and makes unswept chunks)
      collected = true;
      size_t n0 = gc_collections;
      maybe_collect(CHUNK_SIZE);
      if (gc_collections != n0) continue;
    }
    bool fresh = !free_chunks;
    c = new_small_chunk(cls, flavor);
    a->c = NULL;
    a->free = 0;
    a->cur = c->data;
    a->end = c->data + (size_t)c->nobj * size;
    // (a fresh chunk's memory is zero)
    if (!fresh) memset(a->cur, 0, (size_t)(a->end - a->cur));
    break;
  }
  void *p = a->cur;
  a->cur += size;
  return p;
}

static inline void *alloc_small(size_t n, int flavor) {
  uint32_t cls = cls_of_8[(n + 7) >> 3];
  uint32_t z = class_sizes[cls];
  st_small += z;
  st_nsmall++;
  Alloc *a = &alloc_st[cls][flavor];
  char *p = a->cur;
  if (__builtin_expect(p < a->end, 1)) a->cur = p + z;
  else p = refill(cls, flavor);
  // (runs are zero: cleared when they are made)
  return p;
}

void *gc_alloc_flavor(size_t n, int flavor) {
  if (n == 0) n = 8;
  if (n > MAX_SMALL) return alloc_large(n, flavor);
  return alloc_small(n, flavor);
}

void *gc_alloc(size_t n) {
  if (n == 0) n = 8;
  if (n > MAX_SMALL) return alloc_large(n, GC_PLAIN);
  return alloc_small(n, GC_PLAIN);
}

void *gc_alloc_atomic(size_t n) {
  if (n == 0) n = 8;
  if (n > MAX_SMALL) return alloc_large(n, GC_ATOMIC);
  return alloc_small(n, GC_ATOMIC);
}

void *gc_realloc_atomic(void *p, size_t old, size_t n) {
  void *q = gc_alloc_atomic(n);
  if (p && old) memcpy(q, p, old < n ? old : n);
  return q;
}

void gc_add_root(void *p, size_t n) {
  Root *r = malloc(sizeof(Root));
  r->p = p;
  r->n = n;
  r->next = roots;
  roots = r;
}

// ---------------------------------------------------------------------------
// Marking
//
// A collection of the cell store (gc_collect_cells, see cellgc.c) marks with
// candidates: an integer anywhere (a stack, an object, a cell that may hold
// pointers) may be a cell index, and the cell store is asked to keep it. Every
// range of a collection is scanned in the same mode (cand).
//
// Marking runs on several threads (TSTC_GC_THREADS, default 4; the program's
// threads are stopped): each has its own stack of ranges and gives part of it
// to a shared pool when it is long and the pool short; mark bits are set
// with atomic operations.

typedef struct { char *p; uint64_t nf; } Range;  // n bytes at p; flavor in the low byte
#define RANGE_N(r) ((size_t)((r).nf >> 8))
#define RANGE_FLAVOR(r) ((uint8_t)((r).nf & 0xFF))
bool gc_debug_cand;  // (kept for the debug reports; every range has candidates in a collection of the store)
int64_t gc_cur_cell = -1;  // the cell being scanned (cell store), for the reports
static GcScanner scanners[GC_NFLAVORS];
static const GcCellHooks *cell_hooks;
static bool cells_active;
static bool mark_cand;  // this collection's mode
int64_t gc_cand_lo, gc_cand_hi;
GcCellsFast gc_cells_fast;

void gc_set_scanner(int flavor, GcScanner f) { scanners[flavor] = f; }
void gc_set_cell_hooks(const GcCellHooks *h) { cell_hooks = h; }

// Marks wait in a small ring: the mark word of an object is fetched when
// the pointer is found and tested a few pointers later, when it has arrived.
typedef struct { uint64_t *mw; uint64_t bit; char *o; uint32_t size; uint8_t flavor; } Pend;
#define PR 16
#define PACKET 256

typedef struct {
  Range *st;
  size_t lo, sp, cap;  // the stack is st[lo, sp) (donate takes from the bottom)
  Pend pend[PR];
  unsigned ph, pn;
  size_t scanned, pushes, cands, candfast;
  int64_t cells_marked;
} MarkCtx;

static __thread MarkCtx *mc;
static MarkCtx main_ctx;

size_t gc_scanned, gc_root_bytes, gc_n_push, gc_n_cand, gc_n_candfast;
static struct timespec gc_t_marked, gc_t_swept;
int64_t gc_marked_cells;  // by the last collection (summed over the threads)

// the shared pool
typedef struct { Range r[PACKET]; int n; } Packet;
static Packet **pool;
static size_t npool, cappool;
static pthread_mutex_t pool_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t pool_cv = PTHREAD_COND_INITIALIZER, start_cv = PTHREAD_COND_INITIALIZER,
                      end_cv = PTHREAD_COND_INITIALIZER;
static int nmarkers = 1;  // the collecting thread and the workers
static int nworkers_live;  // workers started in this process
static pid_t workers_pid;
static int idle, finished;
static bool mark_done;
static uint64_t mark_epoch;
static volatile size_t pool_hint;  // npool, read without the lock

static __attribute__((noinline)) void grow_stack(MarkCtx *c) {
  if (c->lo > 0 && c->lo >= c->cap / 2) {
    // (room at the bottom, what donations took: moved down instead)
    memmove(c->st, c->st + c->lo, (c->sp - c->lo) * sizeof(Range));
    c->sp -= c->lo;
    c->lo = 0;
    return;
  }
  c->cap = c->cap ? c->cap * 2 : 4096;
  c->st = realloc(c->st, c->cap * sizeof(Range));
  if (!c->st) fatal("out of memory (mark stack)");
}

static inline void push_range(char *p, size_t n, uint8_t flavor) {
  MarkCtx *c = mc;
  c->pushes++;
  if (__builtin_expect(c->sp == c->cap, 0)) grow_stack(c);
  c->st[c->sp].p = p;
  c->st[c->sp].nf = ((uint64_t)n << 8) | flavor;
  c->sp++;
}

void gc_push_range(void *p, size_t n, int flavor) { push_range(p, n, (uint8_t)flavor); }

static inline void commit(const Pend *p) {
  uint64_t old = __atomic_fetch_or(p->mw, p->bit, __ATOMIC_RELAXED);
  if (old & p->bit) return;
  if (p->flavor != GC_ATOMIC) {
    // the object is scanned soon (after a few others): fetch it now
    __builtin_prefetch(p->o);
    push_range(p->o, p->size, p->flavor);
  }
}

static inline bool commit_one(MarkCtx *c) {
  if (!c->pn) return false;
  Pend e = c->pend[c->ph];
  c->ph = (c->ph + 1) % PR;
  c->pn--;
  commit(&e);
  return true;
}

static inline void mark_word(uintptr_t a) {
  uintptr_t ci = a >> CHUNK_SHIFT;
  if (ci - ctab_lo >= ctab_hi - ctab_lo) return;
  Chunk *c = ctab[ci - ctab_lo];
  if (!c || c->free) return;
  if ((char *)a < c->data) return;
  if (c->cls == LARGE_CLS) {
    if ((char *)a >= c->data + c->large || c->marked) return;
    if (__atomic_exchange_n(&c->marked, 1, __ATOMIC_RELAXED)) return;
    if (c->flavor != GC_ATOMIC) push_range(c->data, c->large, c->flavor);
    return;
  }
  uint64_t off = a - (uintptr_t)c->data;
  uint32_t i = (uint32_t)((off * c->recip) >> 40);
  if (i >= c->nobj) return;
  uint64_t *mw = &c->mark[i >> 6], bit = (uint64_t)1 << (i & 63);
  __builtin_prefetch(mw);
  MarkCtx *x = mc;
  if (x->pn == PR) commit_one(x);
  x->pend[(x->ph + x->pn) % PR] = (Pend){mw, bit, c->data + (size_t)i * c->size, c->size, c->flavor};
  x->pn++;
}

// an integer that may be a cell index: the cell store's quick answer first (an
// object's first cell, already marked), then its full one
static inline void cand_word(int64_t n) {
  if (n < gc_cand_lo || n >= gc_cand_hi) return;
  mc->cands++;
  if (gc_cells_fast.start) {
    uint64_t b = (uint64_t)1 << (n & 63);
    if ((gc_cells_fast.mark[n >> 6] & b) && (gc_cells_fast.start[n >> 6] & b)) {
      mc->candfast++;
      return;
    }
  }
  cell_hooks->cand(n);
}

static inline void scan_word(uintptr_t w) {
  if (w & 1) {
    if (mark_cand) cand_word((int64_t)w >> 1);
    return;
  }
  mark_word(w);
}

void gc_mark(V w, bool cand) {
  (void)cand;
  scan_word(w);
}

void gc_add_marked_cells(int64_t n) { mc->cells_marked += n; }

static void scan(char *p, size_t n) {
  mc->scanned += n;
  uintptr_t *w = (uintptr_t *)(((uintptr_t)p + 7) & ~(uintptr_t)7);
  uintptr_t *end = (uintptr_t *)(p + n);
  for (; w < end; w++) scan_word(*w);
}

void gc_scan_range(void *p, size_t n, bool cand) {
  (void)cand;
  push_range(p, n, GC_PLAIN);
}

static void scan_range(Range r) {
  uint8_t fl = RANGE_FLAVOR(r);
  size_t n = RANGE_N(r);
  if (fl != GC_PLAIN && scanners[fl]) {
    scanners[fl](r.p, n, mark_cand);
    return;
  }
  // big ranges a slice at a time, so the stacks stay small and others can
  // take the rest
  if (n > 32768) {
    push_range(r.p + 32768, n - 32768, fl);
    n = 32768;
  }
  scan(r.p, n);
}

// part of a long stack goes to the pool when it runs short
static void donate(MarkCtx *c) {
  if (c->sp - c->lo < 2 * PACKET || pool_hint >= (size_t)nmarkers) return;
  Packet *k = malloc(sizeof(Packet));
  if (!k) return;
  // the oldest ranges (the bottom of the stack): the larger subtrees
  memcpy(k->r, c->st + c->lo, PACKET * sizeof(Range));
  k->n = PACKET;
  c->lo += PACKET;
  pthread_mutex_lock(&pool_mu);
  if (npool == cappool) {
    cappool = cappool ? cappool * 2 : 64;
    pool = realloc(pool, cappool * sizeof(Packet *));
  }
  pool[npool++] = k;
  pool_hint = npool;
  pthread_cond_signal(&pool_cv);
  pthread_mutex_unlock(&pool_mu);
}

// Ranges go through a small queue before they are scanned: what was pushed
// last (and prefetched then) is scanned a few ranges later, when its memory
// has arrived.
#define PQ 32

static void drain_local(MarkCtx *c) {
  Range q[PQ];
  int qn = 0, qh = 0;
  unsigned steps = 0;
  while (c->sp > c->lo || qn > 0 || c->pn > 0) {
    if (c->sp == c->lo && qn == 0) {
      c->sp = c->lo = 0;
      commit_one(c);
      continue;
    }
    if (c->sp > c->lo && qn < PQ) {
      Range r = c->st[--c->sp];
      size_t n = RANGE_N(r);
      __builtin_prefetch(r.p);
      if (n > 64) __builtin_prefetch(r.p + 64);
      if (n > 128) __builtin_prefetch(r.p + 128);
      if (n > 192) __builtin_prefetch(r.p + 192);
      q[(qh + qn++) % PQ] = r;
      if (qn < PQ && c->sp > c->lo) continue;
    }
    Range r = q[qh];
    qh = (qh + 1) % PQ;
    qn--;
    scan_range(r);
    if (nmarkers > 1 && !(++steps & 63)) donate(c);
  }
}

// marks until there is nothing left anywhere
static void mark_loop(MarkCtx *c) {
  for (;;) {
    drain_local(c);
    pthread_mutex_lock(&pool_mu);
    while (npool == 0 && !mark_done) {
      idle++;
      if (idle == nmarkers) {
        mark_done = true;
        pthread_cond_broadcast(&pool_cv);
        break;
      }
      pthread_cond_wait(&pool_cv, &pool_mu);
      if (mark_done) break;
      idle--;
    }
    if (mark_done) {
      pthread_mutex_unlock(&pool_mu);
      return;
    }
    Packet *k = pool[--npool];
    pool_hint = npool;
    pthread_mutex_unlock(&pool_mu);
    c->sp = c->lo = 0;
    while (c->cap < c->sp + (size_t)k->n) grow_stack(c);
    memcpy(c->st + c->sp, k->r, (size_t)k->n * sizeof(Range));
    c->sp += (size_t)k->n;
    free(k);
  }
}

static void ctx_reset(MarkCtx *c) { c->scanned = c->pushes = c->cands = c->candfast = 0, c->cells_marked = 0; }

static void ctx_sum(MarkCtx *c) {
  gc_scanned += c->scanned;
  gc_n_push += c->pushes;
  gc_n_cand += c->cands;
  gc_n_candfast += c->candfast;
  gc_marked_cells += c->cells_marked;
}

static void *marker_main(void *arg) {
  (void)arg;
  MarkCtx *c = calloc(1, sizeof(MarkCtx));
  mc = c;
  uint64_t seen = 0;
  pthread_mutex_lock(&pool_mu);
  for (;;) {
    while (mark_epoch == seen) pthread_cond_wait(&start_cv, &pool_mu);
    seen = mark_epoch;
    pthread_mutex_unlock(&pool_mu);
    ctx_reset(c);
    mark_loop(c);
    pthread_mutex_lock(&pool_mu);
    ctx_sum(c);
    finished++;
    pthread_cond_signal(&end_cv);
  }
  return NULL;
}

// the workers of this process (a forked child has none at first)
static void start_markers(void) {
  if (workers_pid == getpid()) return;
  if (workers_pid) {
    // a forked child: the parent's workers are not here, their locks may be
    pthread_mutex_init(&pool_mu, NULL);
    pthread_cond_init(&pool_cv, NULL);
    pthread_cond_init(&start_cv, NULL);
    pthread_cond_init(&end_cv, NULL);
    npool = 0;
  }
  workers_pid = getpid();
  nworkers_live = 0;
  const char *e = getenv("TSTC_GC_THREADS");
  int want = e ? atoi(e) : 4;
  if (want < 1) want = 1;
  if (want > 64) want = 64;
  for (int k = 1; k < want; k++) {
    pthread_t t;
    pthread_attr_t at;
    pthread_attr_init(&at);
    pthread_attr_setdetachstate(&at, PTHREAD_CREATE_DETACHED);
    pthread_attr_setstacksize(&at, (size_t)1 << 20);
    if (pthread_create(&t, &at, marker_main, NULL) != 0) break;
    nworkers_live++;
  }
  nmarkers = 1 + nworkers_live;
}

// marks from what the collecting thread has pushed (the roots)
static void mark_all(void) {
  start_markers();
  if (gc_debug_cand || nmarkers == 1) {
    // one thread (the debug reports want one)
    int saved = nmarkers;
    nmarkers = 1;
    drain_local(mc);
    nmarkers = saved;
    return;
  }
  pthread_mutex_lock(&pool_mu);
  idle = 0;
  finished = 0;
  mark_done = false;
  mark_epoch++;
  pthread_cond_broadcast(&start_cv);
  pthread_mutex_unlock(&pool_mu);
  mark_loop(mc);
  pthread_mutex_lock(&pool_mu);
  while (finished < nmarkers - 1) pthread_cond_wait(&end_cv, &pool_mu);
  pthread_mutex_unlock(&pool_mu);
}


// ---------------------------------------------------------------------------
// Sweeping

// every marked object (between marking and sweeping)
void gc_each_marked(void (*f)(char *p, size_t n, int flavor)) {
  for (Chunk *c = chunks; c; c = c->next) {
    if (c->cls == LARGE_CLS) {
      if (c->marked) f(c->data, c->large, c->flavor);
      continue;
    }
    for (uint32_t i = 0; i < c->nobj; i++)
      if (c->mark[i >> 6] & ((uint64_t)1 << (i & 63))) f(c->data + (size_t)i * c->size, c->size, c->flavor);
  }
}

static void sweep(void) {
  // (the allocation state was dropped before marking: what it had not
  // handed out is unmarked, free with the rest)
  memset(alloc_st, 0, sizeof alloc_st);
  // free chunks no allocation needed since the last sweep go back to the
  // system, but a few (the ones this sweep frees are reused first: they are
  // at the head of the pool)
  size_t kept = 0;
  for (Chunk **fp = &free_chunks; *fp;) {
    Chunk *c = *fp;
    if (c->free == 2 && ++kept > ((size_t)32 << 20) / CHUNK_SIZE) {
      *fp = c->next;
      ctab[((uintptr_t)c >> CHUNK_SHIFT) - ctab_lo] = NULL;
      pool_bytes -= CHUNK_SIZE;
      munmap(c, CHUNK_SIZE);
      continue;
    }
    c->free = 2;
    fp = &c->next;
  }
  Chunk **pp = &chunks;
  size_t live = 0;
  heap_bytes = 0;
  while (*pp) {
    Chunk *c = *pp;
    if (c->cls == LARGE_CLS) {
      if (!c->marked) {
        *pp = c->next;
        uintptr_t i0 = (uintptr_t)c >> CHUNK_SHIFT;
        for (uintptr_t i = i0; i < i0 + c->span / CHUNK_SIZE; i++) ctab[i - ctab_lo] = NULL;
        large_bytes -= c->span;
        munmap(c, c->span);
        continue;
      }
      c->marked = 0;
      live += c->large;
      heap_bytes += c->span;
      pp = &c->next;
      continue;
    }
    uint32_t words = (c->nobj + 63) / 64;
    uint32_t nlive = 0;
    for (uint32_t w = 0; w < words; w++) nlive += (uint32_t)__builtin_popcountll(c->mark[w]);
    if (nlive == 0) {
      *pp = c->next;
      c->free = 1;
      c->next = free_chunks;
      free_chunks = c;
      pool_bytes += CHUNK_SIZE;
      continue;
    }
    live += (size_t)nlive * c->size;
    heap_bytes += CHUNK_SIZE;
    if (nlive == c->nobj) memset(c->mark, 0, words * 8);
    else {
      c->unswept = 1;
      c->unext = unswept[c->cls][c->flavor];
      unswept[c->cls][c->flavor] = c;
    }
    pp = &c->next;
  }
  gc_bytes_live = live;
}

// a collection of the cell store only: the marks go, the free lists stay (a
// sweep writes to every free object; in a forked child that copies pages)
static void clear_marks(void) {
  for (Chunk *c = chunks; c; c = c->next) {
    c->unswept = 0;
    if (c->cls == LARGE_CLS) c->marked = 0;
    else memset(c->mark, 0, (size_t)((c->nobj + 63) / 64) * 8);
  }
}

static __attribute__((noinline)) void collect_here(bool cells, bool csweep) {
  jmp_buf jb;
  setjmp(jb);
  drop_alloc();
  if (!mc) mc = &main_ctx;
  ctx_reset(mc);
  gc_scanned = gc_n_push = gc_n_cand = gc_n_candfast = 0;
  gc_marked_cells = 0;
  cells_active = cells && cell_hooks;
  mark_cand = cells_active;
  if (cells_active) cell_hooks->begin();
  else if (cell_hooks) cell_hooks->roots();
  char *sp = (char *)&jb;
  if (self) {
    scan(sp, (char *)self->base - sp);
    if (self->ebase && tstc_top > self->ebase) scan((char *)self->ebase, (size_t)((char *)tstc_top - (char *)self->ebase));
  }
  scan((char *)&jb, sizeof jb);
  for (GcThread *t = threads; t; t = t->next) {
    if (t == self) continue;
    if (t->sp) scan(t->sp, (char *)t->base - (char *)t->sp);
    scan((char *)&t->regs, sizeof t->regs);
    if (t->ebase && t->etop > t->ebase) scan((char *)t->ebase, (size_t)((char *)t->etop - (char *)t->ebase));
  }
  for (Root *r = roots; r; r = r->next) scan(r->p, r->n);
  gc_root_bytes = mc->scanned;
  mark_all();
  ctx_sum(mc);
  clock_gettime(CLOCK_MONOTONIC, &gc_t_marked);
  if (cells_active) cell_hooks->sweep();
  clock_gettime(CLOCK_MONOTONIC, &gc_t_swept);
  cells_active = false;
  mark_cand = false;
  gc_cand_lo = gc_cand_hi = 0;
  if (csweep) sweep();
  else clear_marks();
}

double gc_ms;      // in collections so far
double gc_cpu_ms;  // of the process (the marking threads too) in them

static void collect(bool cells) {
  if (gc_disabled) return;
  // the runtime's objects are swept too once half their budget is used
  bool csweep = !cells || gc_grown_since >= threshold / 2;
  struct timespec t0, t1, c0, c1;
  clock_gettime(CLOCK_MONOTONIC, &t0);
  clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &c0);
  collect_here(cells, csweep);
  clock_gettime(CLOCK_MONOTONIC, &t1);
  clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &c1);
  double ms = (t1.tv_sec - t0.tv_sec) * 1000.0 + (t1.tv_nsec - t0.tv_nsec) / 1e6;
  gc_ms += ms;
  gc_cpu_ms += (c1.tv_sec - c0.tv_sec) * 1000.0 + (c1.tv_nsec - c0.tv_nsec) / 1e6;
  if (!csweep) {
    if (getenv("TSTC_GC_TRACE"))
      fprintf(stderr, "gc (cells only, %d): %.1f ms (marked at %.1f, cell store swept at %.1f), scanned %zu MB (roots %zu MB)\n",
              (int)getpid(), ms, (gc_t_marked.tv_sec - t0.tv_sec) * 1000.0 + (gc_t_marked.tv_nsec - t0.tv_nsec) / 1e6,
              (gc_t_swept.tv_sec - t0.tv_sec) * 1000.0 + (gc_t_swept.tv_nsec - t0.tv_nsec) / 1e6, gc_scanned >> 20,
              gc_root_bytes >> 20);
    return;
  }
  gc_collections++;
  gc_grown_since = 0;
  // TSTC_GC_GROWTH=<k>: collect after allocating k times what is live
  static double growth;
  if (growth == 0) {
    const char *g = getenv("TSTC_GC_GROWTH");
    growth = g ? atof(g) : 1.0;
    if (growth <= 0) growth = 1.0;
  }
  size_t t = (size_t)((gc_bytes_live + gc_extra_live) * growth);
  // at least 64 MB; 256 MB with a cell store (its programs fork test processes,
  // where a collection also marks and sweeps what they inherited)
  size_t lo = gc_extra_live ? (size_t)256 << 20 : (size_t)64 << 20;
  set_threshold(t > lo ? t : lo);
  if (getenv("TSTC_GC_TRACE"))
    fprintf(stderr, "gc %zu%s (%d): live %zu MB, heap %zu MB (large %zu MB; free chunks %zu MB), %.1f ms (marked at %.1f, cell store swept at %.1f), scanned %zu MB; %zuk pushes, %zuk candidates (%zuk quick)\n",
            gc_collections, cells ? " (cells)" : "", (int)getpid(), gc_bytes_live >> 20, heap_bytes >> 20, large_bytes >> 20,
            pool_bytes >> 20, ms,
            (gc_t_marked.tv_sec - t0.tv_sec) * 1000.0 + (gc_t_marked.tv_nsec - t0.tv_nsec) / 1e6,
            (gc_t_swept.tv_sec - t0.tv_sec) * 1000.0 + (gc_t_swept.tv_nsec - t0.tv_nsec) / 1e6, gc_scanned >> 20,
            gc_n_push >> 10, gc_n_cand >> 10, gc_n_candfast >> 10);
}

void gc_collect(void) { collect(false); }

// at a safe point of the cell store (no cell index is held but as a value)
void gc_collect_cells(void) { collect(true); }

// a collection is near: better done at a safe point of the cell store
bool gc_due(void) { return !gc_disabled && gc_grown_since > gc_due_at; }
bool gc_is_disabled(void) { return gc_disabled; }


// what a forked child may allocate before it collects, at least: a 32nd of
// the machine's memory (2 GB of 64; 256 MB if unknown)
size_t gc_fork_budget(void) {
  static size_t b;
  if (!b) {
    long pages = sysconf(_SC_PHYS_PAGES), pg = sysconf(_SC_PAGESIZE);
    b = pages > 0 && pg > 0 ? (size_t)pages * (size_t)pg / 32 : (size_t)256 << 20;
    if (b < ((size_t)256 << 20)) b = (size_t)256 << 20;
  }
  return b;
}

// a forked child starts with a full allocation budget: what the parent
// allocated since its last collection is shared, and a collection in the
// child would scan everything it inherited
//
// Its allocations go to fresh chunks: the free space of the inherited ones is
// scattered over pages the parent wrote, and the first write to each would
// copy it (fresh memory is zero-filled, a page at a time, densely used).
void gc_after_fork(void) {
  gc_grown_since = 0;
  gc_ms = gc_cpu_ms = 0;
  st_small = st_nsmall = st_large = st_nlarge = st_chunks = st_reused = 0;
  drop_alloc();
  free_chunks = NULL;
  pool_bytes = 0;
  // a collection here is costly (its sweep writes to the inherited chunks,
  // which copies their pages) and mostly needless (the child is short-lived:
  // a test, or a group of tests, of tstst's drivers): the budget is at least
  // what the parent had in use (the cell store's cells included), and a
  // 32nd of the machine's memory
  size_t b = gc_bytes_live + gc_extra_live;
  if (b < gc_fork_budget()) b = gc_fork_budget();
  if (threshold < b) set_threshold(b);
  if (getenv("TSTC_GC_FORK_BUDGET")) set_threshold((size_t)atoll(getenv("TSTC_GC_FORK_BUDGET")) << 20);
}

int64_t cells_new(void);

static void write_stats(void) {
  FILE *f = fopen(getenv("TSTC_GC_STATS"), "a");
  if (!f) return;
  struct rusage ru;
  getrusage(RUSAGE_SELF, &ru);
  fprintf(f, "%d small %zu MB %zu objects, large %zu MB %zu objects, chunks %zu (%zu reused), collections %zu, %.0f ms, %.0f ms cpu, cells %lld MB, faults %ld\n",
          (int)getpid(), st_small >> 20, st_nsmall, st_large >> 20, st_nlarge, st_chunks, st_reused, gc_collections, gc_ms, gc_cpu_ms,
          (long long)(cells_new() >> 17), ru.ru_minflt);
  fclose(f);
}

void gc_init(void *stack_base) {
  init_classes();
  if (getenv("TSTC_GC_STATS")) atexit(write_stats);
  const char *e = getenv("TSTC_GC");
  if (e && e[0] == '0') gc_disabled = true;
  self = gc_thread_register(stack_base);
}

GcThread *gc_current(void) { return self; }

GcThread *gc_thread_register(void *stack_base) {
  GcThread *t = calloc(1, sizeof(GcThread));
  t->base = stack_base;
  t->running = true;
  t->next = threads;
  threads = t;
  self = t;
  return t;
}

void gc_thread_unregister(GcThread *t) {
  for (GcThread **pp = &threads; *pp; pp = &(*pp)->next) {
    if (*pp == t) {
      *pp = t->next;
      break;
    }
  }
  if (self == t) self = NULL;
  free(t);
}

__attribute__((noinline)) void gc_thread_leave(GcThread *t) {
  setjmp(t->regs);
  t->sp = __builtin_frame_address(0);
  t->etop = tstc_top;
  t->running = false;
}

void gc_thread_enter(GcThread *t) {
  t->sp = NULL;
  t->running = true;
  self = t;
  tstc_top = t->etop;
}
