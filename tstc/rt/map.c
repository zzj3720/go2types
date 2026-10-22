// Maps (lib/pure map.ts): persistent hash array mapped tries with structural
// keys. A map variable holds a pointer to a cell with the map value (or null).
//
// Updates through a cell are transient (as Clojure's): the cell gets a map
// value of its own (owner), with an edit id; nodes made by that edit change
// in place, and others are copied first. Reading the value out of the cell
// (hget, loads, copies of cells) freezes it: what may be shared is never
// changed.
//
// A map a cell builds from (nearly) empty is a hash table instead (tab: open
// addressing, linear probing), changed in place while the cell owns it: a
// lookup or an update is a probe or two, not a walk down the trie with its
// copies and shifts (a checker merges thousands of lib globals into a new
// map). A table another cell takes over is copied; an update not through
// its cell (pmap_put, pmap_del: a new map value) makes it a trie first.
#include "lib.h"

#include <stdio.h>
#include <stdlib.h>

typedef struct MNode MNode;
typedef struct { V k, v; uint32_t h, pad; } MEnt;  // k == 0: v is a child node
struct MNode {
  uint32_t bitmap;  // collision nodes: 0
  uint32_t n, cap;
  uint64_t edit;  // the edit that may change it in place (0: none)
  MEnt e[];
};
typedef struct {
  uint32_t tag, aux;
  int64_t n;
  MNode *root;
  int64_t owner;  // the cell (+ 1) whose value it is, 0 when none
  uint64_t edit;
  V keys;  // its keys in range order once computed (pmap_keys), 0 when not
  // the table (or NULL: the trie at root): an MNode whose n (= cap) slots
  // are entries (k 0: empty), bitmap the log2 of their number
  MNode *tab;
} MapT;

static uint64_t edits;

// The collector scans maps by their layout: the hashes, counts and owner
// cells in them are not values (nor cell indices of the cell store).
static void scan_map(char *p, size_t n, bool cand) {
  (void)n;
  MapT *m = (MapT *)p;
  if (m->root) gc_mark((V)m->root, cand);
  if (m->tab) gc_mark((V)m->tab, cand);
  if (m->keys) gc_mark(m->keys, cand);
}

// (a word that looks like a pointer to a free object gets here too: its
// count is not trusted beyond the object's size)
static void scan_mnode(char *p, size_t n, bool cand) {
  MNode *x = (MNode *)p;
  size_t max = n > sizeof(MNode) ? (n - sizeof(MNode)) / sizeof(MEnt) : 0;
  uint32_t cnt = x->n < max ? x->n : (uint32_t)max;
  for (uint32_t i = 0; i < cnt; i++) {
    if (x->e[i].k) gc_mark(x->e[i].k, cand);
    gc_mark(x->e[i].v, cand);
  }
}

// a map value read out of its cell as a value (it may be copied elsewhere):
// no longer changed in place
static void map_freeze(V v) { ((MapT *)v)->owner = 0; }

void map_gc_init(void) {
  gc_set_scanner(GC_MAP, scan_map);
  gc_set_scanner(GC_MNODE, scan_mnode);
  store_owned_kind(K_MAP, map_freeze);
}

static MNode *node_new_e(uint32_t n, uint32_t cap, uint64_t edit) {
  MNode *x = gc_alloc_flavor(sizeof(MNode) + (size_t)cap * sizeof(MEnt), GC_MNODE);
  x->n = n;
  x->cap = cap;
  x->edit = edit;
  return x;
}

static MNode *node_new(uint32_t n) { return node_new_e(n, n, 0); }

// x changeable by the edit, with room for need entries
static MNode *node_own(MNode *x, uint32_t need, uint64_t edit, bool collision) {
  if (x->edit == edit && need <= x->cap) return x;
  uint32_t cap = need;
  if (x->edit == edit || need > x->n) {
    // growing: room for more
    cap = x->n * 2 > need ? x->n * 2 : need;
    if (!collision && cap > 32) cap = 32 > need ? 32 : need;
  }
  MNode *r = node_new_e(x->n, cap, edit);
  r->bitmap = x->bitmap;
  memcpy(r->e, x->e, (size_t)x->n * sizeof(MEnt));
  return r;
}

static V map_new(MNode *root, int64_t n) {
  MapT *m = gc_alloc_flavor(sizeof(MapT), GC_MAP);
  m->tag = K_MAP;
  m->n = n;
  m->root = root;
  return (V)m;
}

static MapT *as_map(V m) {
  if (kind(m) != K_MAP) die("expected a map, got %s", ty_to_cstr_short(m));
  return (MapT *)m;
}

V map_empty(void) { return map_new(NULL, 0); }

// ---------------------------------------------------------------------------
// Tables

static inline uint32_t tab_slot(MNode *t, uint32_t h) { return (h * 2654435769u) >> (32 - t->bitmap); }

static MNode *tab_new(uint32_t lg) {
  uint32_t n = 1u << lg;
  MNode *t = node_new_e(n, n, 0);
  t->bitmap = lg;
  memset(t->e, 0, (size_t)n * sizeof(MEnt));
  return t;
}

static MEnt *tab_find(MNode *t, uint32_t h, V k) {
  uint32_t mask = t->n - 1;
  for (uint32_t i = tab_slot(t, h);; i = (i + 1) & mask) {
    MEnt *e = &t->e[i];
    if (!e->k) return NULL;
    if (e->h == h && key_eq(e->k, k)) return e;
  }
}

// (a key not in the table, room for it)
static void tab_insert(MNode *t, uint32_t h, V k, V v) {
  uint32_t mask = t->n - 1, i = tab_slot(t, h);
  while (t->e[i].k) i = (i + 1) & mask;
  t->e[i].k = k;
  t->e[i].v = v;
  t->e[i].h = h;
}

static MNode *tab_resize(MNode *t, uint32_t lg) {
  MNode *r = tab_new(lg);
  if (t)
    for (uint32_t i = 0; i < t->n; i++)
      if (t->e[i].k) tab_insert(r, t->e[i].h, t->e[i].k, t->e[i].v);
  return r;
}

// the table of n entries: one of 2^lg slots with lg the least that keeps it
// at most 3/4 full
static uint32_t tab_lg(int64_t n) {
  uint32_t lg = 3;
  while ((int64_t)3 << (lg - 2) < n) lg++;
  return lg;
}

static void node_into_tab(MNode *x, MNode *t) {
  if (!x) return;
  for (uint32_t i = 0; i < x->n; i++) {
    if (x->e[i].k) tab_insert(t, x->e[i].h, x->e[i].k, x->e[i].v);
    else node_into_tab((MNode *)x->e[i].v, t);
  }
}

// mm (owned by an edit) changes in place: k is v
static void tab_put(MapT *mm, uint32_t h, V k, V v, bool *added) {
  MEnt *e = mm->tab ? tab_find(mm->tab, h, k) : NULL;
  if (e) {
    e->v = v;
    return;
  }
  if (!mm->tab || (mm->n + 1) * 4 > (int64_t)mm->tab->n * 3) mm->tab = tab_resize(mm->tab, tab_lg(mm->n + 1));
  tab_insert(mm->tab, h, k, v);
  *added = true;
}

// (backward-shift deletion: no tombstones)
static bool tab_del(MapT *mm, uint32_t h, V k) {
  MNode *t = mm->tab;
  MEnt *e = tab_find(t, h, k);
  if (!e) return false;
  uint32_t mask = t->n - 1, i = (uint32_t)(e - t->e);
  for (uint32_t j = (i + 1) & mask; t->e[j].k; j = (j + 1) & mask) {
    uint32_t home = tab_slot(t, t->e[j].h);
    // the entry at j may move to the hole at i when its home is not in (i, j]
    if (((j - home) & mask) >= ((j - i) & mask)) {
      t->e[i] = t->e[j];
      i = j;
    }
  }
  t->e[i].k = 0;
  t->e[i].v = 0;
  t->e[i].h = 0;
  return true;
}

static MNode *node_put(MNode *x, uint32_t h, V k, V v, int shift, bool *added, uint64_t edit);

// a table map as a trie from now on (its value stays what it was)
static void tab_to_trie(MapT *mm) {
  if (!mm->tab) return;
  MNode *t = mm->tab, *root = NULL;
  uint64_t edit = ++edits;
  bool added;
  for (uint32_t i = 0; i < t->n; i++)
    if (t->e[i].k) root = node_put(root, t->e[i].h, t->e[i].k, t->e[i].v, 0, &added, edit);
  mm->root = root;
  mm->tab = NULL;
}

static V node_get(MNode *x, uint32_t h, V k, int shift) {
  while (x) {
    if (shift >= 32) {
      for (uint32_t i = 0; i < x->n; i++)
        if (x->e[i].h == h && key_eq(x->e[i].k, k)) return x->e[i].v;
      return 0;
    }
    uint32_t bit = 1u << ((h >> shift) & 31);
    if (!(x->bitmap & bit)) return 0;
    MEnt *e = &x->e[__builtin_popcount(x->bitmap & (bit - 1))];
    if (e->k) return e->h == h && key_eq(e->k, k) ? e->v : 0;
    x = (MNode *)e->v;
    shift += 5;
  }
  return 0;
}

static MNode *pair_node_e(MEnt a, MEnt b, int shift, uint64_t edit) {
  if (shift >= 32) {
    MNode *x = node_new_e(2, 2, edit);
    x->e[0] = a;
    x->e[1] = b;
    return x;
  }
  uint32_t ia = (a.h >> shift) & 31, ib = (b.h >> shift) & 31;
  if (ia == ib) {
    MNode *x = node_new_e(1, 1, edit);
    x->bitmap = 1u << ia;
    x->e[0].k = 0;
    x->e[0].v = (V)pair_node_e(a, b, shift + 5, edit);
    return x;
  }
  MNode *x = node_new_e(2, 2, edit);
  x->bitmap = (1u << ia) | (1u << ib);
  x->e[ia < ib ? 0 : 1] = a;
  x->e[ia < ib ? 1 : 0] = b;
  return x;
}

static MNode *pair_node(MEnt a, MEnt b, int shift) { return pair_node_e(a, b, shift, 0); }

// node_add by an edit: nodes of the edit change in place
static MNode *node_put(MNode *x, uint32_t h, V k, V v, int shift, bool *added, uint64_t edit) {
  if (!x) {
    MNode *r = node_new_e(1, 2, edit);
    r->bitmap = shift >= 32 ? 0 : 1u << ((h >> shift) & 31);
    r->e[0].k = k;
    r->e[0].v = v;
    r->e[0].h = h;
    *added = true;
    return r;
  }
  if (shift >= 32) {
    for (uint32_t i = 0; i < x->n; i++) {
      if (x->e[i].h == h && key_eq(x->e[i].k, k)) {
        MNode *r = node_own(x, x->n, edit, true);
        r->e[i].v = v;
        return r;
      }
    }
    MNode *r = node_own(x, x->n + 1, edit, true);
    r->e[r->n].k = k;
    r->e[r->n].v = v;
    r->e[r->n].h = h;
    r->e[r->n].pad = 0;
    r->n++;
    *added = true;
    return r;
  }
  uint32_t bit = 1u << ((h >> shift) & 31);
  uint32_t idx = __builtin_popcount(x->bitmap & (bit - 1));
  if (!(x->bitmap & bit)) {
    MNode *r = node_own(x, x->n + 1, edit, false);
    memmove(r->e + idx + 1, r->e + idx, (size_t)(r->n - idx) * sizeof(MEnt));
    r->e[idx].k = k;
    r->e[idx].v = v;
    r->e[idx].h = h;
    r->e[idx].pad = 0;
    r->bitmap |= bit;
    r->n++;
    *added = true;
    return r;
  }
  MEnt *e0 = &x->e[idx];
  if (!e0->k) {
    MNode *c = node_put((MNode *)e0->v, h, k, v, shift + 5, added, edit);
    if (c == (MNode *)e0->v) return x;
    MNode *r = node_own(x, x->n, edit, false);
    r->e[idx].v = (V)c;
    return r;
  }
  MNode *r = node_own(x, x->n, edit, false);
  MEnt *e = &r->e[idx];
  if (e->h == h && key_eq(e->k, k)) {
    e->v = v;
  } else {
    MEnt nw = {k, v, h, 0};
    MEnt old = *e;
    e->k = 0;
    e->v = (V)pair_node_e(old, nw, shift + 5, edit);
    e->h = 0;
    *added = true;
  }
  return r;
}

static MNode *node_add(MNode *x, uint32_t h, V k, V v, int shift, bool *added) {
  if (!x) {
    MNode *r = node_new(1);
    r->bitmap = shift >= 32 ? 0 : 1u << ((h >> shift) & 31);
    r->e[0].k = k;
    r->e[0].v = v;
    r->e[0].h = h;
    *added = true;
    return r;
  }
  if (shift >= 32) {
    for (uint32_t i = 0; i < x->n; i++) {
      if (x->e[i].h == h && key_eq(x->e[i].k, k)) {
        MNode *r = node_new(x->n);
        memcpy(r->e, x->e, (size_t)x->n * sizeof(MEnt));
        r->e[i].v = v;
        return r;
      }
    }
    MNode *r = node_new(x->n + 1);
    memcpy(r->e, x->e, (size_t)x->n * sizeof(MEnt));
    r->e[x->n].k = k;
    r->e[x->n].v = v;
    r->e[x->n].h = h;
    *added = true;
    return r;
  }
  uint32_t bit = 1u << ((h >> shift) & 31);
  uint32_t idx = __builtin_popcount(x->bitmap & (bit - 1));
  if (!(x->bitmap & bit)) {
    MNode *r = node_new(x->n + 1);
    r->bitmap = x->bitmap | bit;
    memcpy(r->e, x->e, (size_t)idx * sizeof(MEnt));
    r->e[idx].k = k;
    r->e[idx].v = v;
    r->e[idx].h = h;
    memcpy(r->e + idx + 1, x->e + idx, (size_t)(x->n - idx) * sizeof(MEnt));
    *added = true;
    return r;
  }
  MNode *r = node_new(x->n);
  r->bitmap = x->bitmap;
  memcpy(r->e, x->e, (size_t)x->n * sizeof(MEnt));
  MEnt *e = &r->e[idx];
  if (!e->k) {
    e->v = (V)node_add((MNode *)e->v, h, k, v, shift + 5, added);
  } else if (e->h == h && key_eq(e->k, k)) {
    e->v = v;
  } else {
    MEnt nw = {k, v, h, 0};
    MEnt old = *e;
    e->k = 0;
    e->v = (V)pair_node(old, nw, shift + 5);
    e->h = 0;
    *added = true;
  }
  return r;
}

static MNode *node_remove(MNode *x, uint32_t h, V k, int shift, bool *removed) {
  if (!x) return NULL;
  if (shift >= 32) {
    for (uint32_t i = 0; i < x->n; i++) {
      if (x->e[i].h == h && key_eq(x->e[i].k, k)) {
        *removed = true;
        if (x->n == 1) return NULL;
        MNode *r = node_new(x->n - 1);
        memcpy(r->e, x->e, (size_t)i * sizeof(MEnt));
        memcpy(r->e + i, x->e + i + 1, (size_t)(x->n - i - 1) * sizeof(MEnt));
        return r;
      }
    }
    return x;
  }
  uint32_t bit = 1u << ((h >> shift) & 31);
  if (!(x->bitmap & bit)) return x;
  uint32_t idx = __builtin_popcount(x->bitmap & (bit - 1));
  MEnt *e = &x->e[idx];
  MNode *child = NULL;
  if (e->k) {
    if (!(e->h == h && key_eq(e->k, k))) return x;
    *removed = true;
  } else {
    child = node_remove((MNode *)e->v, h, k, shift + 5, removed);
    if (!*removed) return x;
    if (child) {
      MNode *r = node_new(x->n);
      r->bitmap = x->bitmap;
      memcpy(r->e, x->e, (size_t)x->n * sizeof(MEnt));
      r->e[idx].v = (V)child;
      return r;
    }
  }
  if (x->n == 1) return NULL;
  MNode *r = node_new(x->n - 1);
  r->bitmap = x->bitmap & ~bit;
  memcpy(r->e, x->e, (size_t)idx * sizeof(MEnt));
  memcpy(r->e + idx, x->e + idx + 1, (size_t)(x->n - idx - 1) * sizeof(MEnt));
  return r;
}

static void node_keys(MNode *x, VA *out, VA *vals) {
  if (!x) return;
  for (uint32_t i = 0; i < x->n; i++) {
    if (x->e[i].k) {
      va_push(out, x->e[i].k);
      if (vals) va_push(vals, x->e[i].v);
    } else {
      node_keys((MNode *)x->e[i].v, out, vals);
    }
  }
}

V map_get(V m, V k) {
  MapT *mm = as_map(m);
  if (mm->tab) {
    MEnt *e = tab_find(mm->tab, key_hash(k), k);
    return e ? e->v : 0;
  }
  return node_get(mm->root, key_hash(k), k, 0);
}

// the entries of a map (vals: or only the keys)
static void map_entries(MapT *mm, VA *keys, VA *vals) {
  if (!mm->tab) {
    node_keys(mm->root, keys, vals);
    return;
  }
  for (uint32_t i = 0; i < mm->tab->n; i++)
    if (mm->tab->e[i].k) {
      va_push(keys, mm->tab->e[i].k);
      if (vals) va_push(vals, mm->tab->e[i].v);
    }
}

V map_add(V m, V k, V v) {
  MapT *mm = as_map(m);
  tab_to_trie(mm);
  bool added = false;
  MNode *r = node_add(mm->root, key_hash(k), k, v, 0, &added);
  return map_new(r, mm->n + added);
}

V map_remove(V m, V k) {
  MapT *mm = as_map(m);
  tab_to_trie(mm);
  bool removed = false;
  MNode *r = node_remove(mm->root, key_hash(k), k, 0, &removed);
  return removed ? map_new(r, mm->n - 1) : m;
}

int64_t map_len(V m) { return as_map(m)->n; }

// lib/pure's maps (map.ts) are tries over the serialization of their keys
// (Ser: i<decimal>; s<length>:<bytes> t f n (...)), so ranges visit keys in
// the order of those strings: map_keys sorts them so
// (the decimal digits of x, as printf's %lld)
static void sb_dec(SB *b, int64_t x) {
  char d[24];
  int n = 0;
  uint64_t u = x < 0 ? (uint64_t)0 - (uint64_t)x : (uint64_t)x;
  do {
    d[n++] = (char)('0' + u % 10);
    u /= 10;
  } while (u);
  if (x < 0) sb_put(b, '-');
  while (n) sb_put(b, (uint16_t)d[--n]);
}

static void ser_key(SB *b, V k) {
  switch (kind(k)) {
  case K_INT:
    sb_put(b, 'i');
    sb_dec(b, int_val(k));
    sb_put(b, ';');
    return;
  case K_STRLIT: {
    Str *s = as_str(k);
    sb_put(b, 's');
    sb_dec(b, s->len);
    sb_put(b, ':');
    sb_str(b, s);
    return;
  }
  case K_TRUE: sb_put(b, 't'); return;
  case K_FALSE: sb_put(b, 'f'); return;
  case K_NULL: sb_put(b, 'n'); return;
  case K_TUPLE: {
    TupT *t = as_tup(k);
    sb_put(b, '(');
    for (uint32_t i = 0; i < t->len; i++) ser_key(b, t->e[i]);
    sb_put(b, ')');
    return;
  }
  default: die("unsupported map key %s", ty_to_cstr_short(k));
  }
}

// a key and its serialization (at off in one buffer for all the keys); p0,
// p1: its first eight code units, big-endian (compared as integers, in the
// order of the units), so that most comparisons look at no more
typedef struct { uint64_t p0, p1; V k; int32_t off, n; } KeySer;

static inline int keyser_cmp(const KeySer *a, const KeySer *b, const uint16_t *base) {
  if (a->p0 != b->p0) return a->p0 < b->p0 ? -1 : 1;
  if (a->p1 != b->p1) return a->p1 < b->p1 ? -1 : 1;
  const uint16_t *x = base + a->off, *y = base + b->off;
  int32_t n = a->n < b->n ? a->n : b->n;
  for (int32_t i = 8; i < n; i++)
    if (x[i] != y[i]) return x[i] < y[i] ? -1 : 1;
  return (a->n > b->n) - (a->n < b->n);
}

static void keyser_sort(KeySer *a, int64_t n, KeySer *tmp, const uint16_t *base) {
  if (n <= 12) {
    for (int64_t i = 1; i < n; i++) {
      KeySer x = a[i];
      int64_t j = i;
      while (j > 0 && keyser_cmp(&a[j - 1], &x, base) > 0) {
        a[j] = a[j - 1];
        j--;
      }
      a[j] = x;
    }
    return;
  }
  int64_t h = n / 2;
  keyser_sort(a, h, tmp, base);
  keyser_sort(a + h, n - h, tmp, base);
  if (keyser_cmp(&a[h - 1], &a[h], base) <= 0) return;
  memcpy(tmp, a, (size_t)h * sizeof(KeySer));
  int64_t i = 0, j = h, k = 0;
  while (i < h && j < n) a[k++] = keyser_cmp(&tmp[i], &a[j], base) <= 0 ? tmp[i++] : a[j++];
  while (i < h) a[k++] = tmp[i++];
}

void map_keys(V m, VA *out) {
  va_init(out);
  map_entries(as_map(m), out, NULL);
  if (out->n < 2) return;
  KeySer *ks = malloc(out->n * sizeof(KeySer) * 2);
  SB b = {0};
  for (uint32_t i = 0; i < out->n; i++) {
    ks[i].k = out->d[i];
    ks[i].off = b.n;
    ser_key(&b, out->d[i]);
    ks[i].n = b.n - ks[i].off;
  }
  for (uint32_t i = 0; i < out->n; i++) {
    uint64_t p[2] = {0, 0};
    for (int32_t j = 0; j < 8 && j < ks[i].n; j++) p[j >> 2] |= (uint64_t)b.d[ks[i].off + j] << (48 - 16 * (j & 3));
    ks[i].p0 = p[0];
    ks[i].p1 = p[1];
  }
  keyser_sort(ks, out->n, ks + out->n, b.d);
  for (uint32_t i = 0; i < out->n; i++) out->d[i] = ks[i].k;
  free(b.d);
  free(ks);
}

void map_write(SB *b, V m, int depth) {
  VA ks, vs;
  va_init(&ks);
  va_init(&vs);
  map_entries(as_map(m), &ks, &vs);
  sb_puts(b, "Map{");
  for (uint32_t i = 0; i < ks.n && i < 50; i++) {
    if (i > 0) sb_puts(b, ", ");
    write_ty(b, ks.d[i], 0, depth + 1);
    sb_puts(b, " => ");
    write_ty(b, vs.d[i], 0, depth + 1);
  }
  sb_put(b, '}');
}

// ---------------------------------------------------------------------------
// Natives: map values (lib/pure map.ts: pm*), and the same on the map a cell
// of the store owns (cell_*: fused by the compiler from hget/hset around
// them, fuse.mbt)

V n_pmap_empty(void) { return map_empty(); }

// the entry [k, v] (a pair, the query key standing for the stored one: they
// are the same type), or null
VPair n_pmap_get(V m, V k) {
  V v = map_get(m, k);
  return v ? PAIR(k, v) : PAIR(V_NULL, 0);
}
V n_pmap_put(V m, V k, V v) { return map_add(m, k, v); }
V n_pmap_del(V m, V k) { return map_remove(m, k); }
V n_pmap_len(V m) { return mk_int(map_len(m)); }
// (a map value does not change but in place through its cell, which drops
// the keys: n_cell_pmap_put, n_cell_pmap_del)
V n_pmap_keys(V m) {
  MapT *mm = as_map(m);
  if (mm->keys) return mm->keys;
  VA keys;
  map_keys(m, &keys);
  V t = mk_tuple(keys.d, keys.n);
  mm->keys = t;
  return t;
}

// the map in the cell (not frozen: it is only looked into)
static V cell_map(V h, V p) { return heap_get(heap_of(h), cell_index(p)); }

// a step of a range: from index i of the keys (n of them), the next key
// still in the map: [true, index after it, key, value], or [false, n, null, null]
V n_pmap_step(V m, V keysv, V iv, V nv) {
  if (kind(keysv) != K_TUPLE) die("pmap_step: expected the keys, got %s", ty_to_cstr_short(keysv));
  TupT *keys = as_tup(keysv);
  int64_t i = gi(iv), n = gi(nv);
  V r4[4];
  while (i < n && i < keys->len) {
    V k = keys->e[i++];
    V v = map_get(m, k);
    if (v) {
      r4[0] = V_TRUE;
      r4[1] = mk_int(i);
      r4[2] = k;
      r4[3] = v;
      return mk_tuple(r4, 4);
    }
  }
  r4[0] = V_FALSE;
  r4[1] = nv;
  r4[2] = V_NULL;
  r4[3] = V_NULL;
  return mk_tuple(r4, 4);
}

VPair n_cell_pmap_get(V h, V p, V k) { return n_pmap_get(cell_map(h, p), k); }
V n_cell_pmap_len(V h, V p) { return n_pmap_len(cell_map(h, p)); }
V n_cell_pmap_keys(V h, V p) { return n_pmap_keys(cell_map(h, p)); }
V n_cell_pmap_step(V h, V p, V keys, V i, V n) { return n_pmap_step(cell_map(h, p), keys, i, n); }

// the map the cell owns (a copy of its value the first time, which later
// updates through the cell change in place)
static MapT *owned_map(HeapT *hh, int64_t i) {
  MapT *mm = as_map(heap_get(hh, i));
  if (mm->owner != i + 1) {
    MapT *own = (MapT *)map_new(mm->root, mm->n);
    own->owner = i + 1;
    own->edit = ++edits;
    if (mm->tab) {
      // (a table: copied)
      own->tab = tab_new(mm->tab->bitmap);
      memcpy(own->tab->e, mm->tab->e, (size_t)mm->tab->n * sizeof(MEnt));
    } else if (mm->n <= 8) {
      // (a small trie: a table)
      own->root = NULL;
      own->tab = tab_new(tab_lg(mm->n));
      node_into_tab(mm->root, own->tab);
    }
    mm = own;
  }
  return mm;
}

V n_cell_pmap_put(V h, V p, V k, V v) {
  HeapT *hh = heap_of(h);
  int64_t i = cell_index(p);
  MapT *mm = owned_map(hh, i);
  bool added = false;
  if (mm->tab) tab_put(mm, key_hash(k), k, v, &added);
  else mm->root = node_put(mm->root, key_hash(k), k, v, 0, &added, mm->edit);
  mm->n += added;
  mm->keys = 0;
  return heap_v(heap_set(hh, i, (V)mm));
}

V n_cell_pmap_del(V h, V p, V k) {
  HeapT *hh = heap_of(h);
  int64_t i = cell_index(p);
  MapT *mm = as_map(heap_get(hh, i));
  if (mm->tab && mm->owner == i + 1) {
    // (its own table: in place)
    if (tab_del(mm, key_hash(k), k)) {
      mm->n--;
      mm->keys = 0;
    }
    return heap_v(heap_set(hh, i, (V)mm));
  }
  return heap_v(heap_set(hh, i, map_remove((V)mm, k)));
}
