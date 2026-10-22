// Memoized aliases (src/main/opt.mbt): a table from an alias and its
// arguments to the value. Evaluation is pure, so equal arguments give the
// value again; arguments are compared strictly (structure, order of union
// members, names of tuple elements), objects and functions by identity.
// Arguments too large to hash cheaply are not memoized, nor are the
// natives' values updated in place (stores, maps, vectors). The table is
// cleared when it reaches its bound.
#include "tstc.h"

#include <stdlib.h>

bool alias_topped(V v);  // ty.c

typedef struct {
  uint64_t h;
  int64_t id, n;
  V v;
  V a[];
} MKey;

static MKey **tab;
static uint64_t cap, used;
static bool rooted;
#define MEMO_MAX (UINT64_C(1) << 20)
#define MEMO_BUDGET 4096

static inline uint64_t mix(uint64_t h, uint64_t x) {
  x *= UINT64_C(0x9E3779B97F4A7C15);
  x ^= x >> 29;
  return (h ^ x) * UINT64_C(0xBF58476D1CE4E5B9) + 0x94D049BB133111EBu;
}

// a hash of v; *budget below zero: too large, or not to be memoized
static uint64_t vhash(V v, int64_t *budget) {
  if (--*budget < 0) return 0;
  int k = kind(v);
  if (k == K_STORE || k == K_MAP || k == K_VEC) {
    *budget = -1;
    return 0;
  }
  if (v & 3) return mix(1, v);
  switch (k) {
  case K_INT: return mix(2, (uint64_t)int_val(v));
  case K_STRLIT: {
    Str *s = as_str(v);
    *budget -= s->len / 16;
    return mix(3, str_hash(s));
  }
  case K_NUMLIT: {
    double d = num_val(v);
    uint64_t u;
    memcpy(&u, &d, 8);
    return mix(4, u);
  }
  case K_BIGLIT: return mix(5, str_hash(((BigT *)v)->s));
  case K_USYM: return mix(6, (uint64_t)((USymT *)v)->id);
  case K_TUPLE: {
    // by runs of elements of equal hashes, so that a uniform tuple hashes
    // in O(1) as the same elements otherwise stored
    TupT *t = as_tup(v);
    uint64_t h = mix(7, t->len * 2 + tup_ro(t));
    V u = tup_uni(t);
    if (u) return t->len ? mix(mix(h, vhash(u, budget)), t->len) : h;
    uint64_t run = 0, rh = 0;
    for (uint32_t i = 0; i < t->len && *budget >= 0; i++) {
      uint64_t eh = vhash(t->e[i], budget);
      if (t->x && t->x->kinds) eh = mix(eh, t->x->kinds[i]);
      Str *nm = tup_name(t, i);
      if (nm) eh = mix(eh, str_hash(nm));
      if (run && eh == rh) {
        run++;
        continue;
      }
      if (run) h = mix(mix(h, rh), run);
      rh = eh;
      run = 1;
    }
    if (run) h = mix(mix(h, rh), run);
    return h;
  }
  case K_ARRAY: return mix(8 + ((ArrT *)v)->ro, vhash(((ArrT *)v)->el, budget));
  case K_UNION:
  case K_INTER: {
    SetT *s = (SetT *)v;
    uint64_t h = mix(10 + (uint64_t)k, s->n);
    for (uint32_t i = 0; i < s->n && *budget >= 0; i++) h = mix(h, vhash(s->m[i], budget));
    return h;
  }
  case K_TPL: {
    TplT *t = (TplT *)v;
    uint64_t h = mix(12, t->n);
    for (uint32_t i = 0; i <= t->n; i++) h = mix(h, str_hash(t->texts[i]));
    for (uint32_t i = 0; i < t->n && *budget >= 0; i++) h = mix(h, vhash(t->types[i], budget));
    return h;
  }
  default:
    // objects, functions, deferred types: identity
    return mix(13, v);
  }
}

static bool veq(V a, V b) {
  if (a == b) return true;
  int k = kind(a);
  if (k != kind(b) || (a & 3) || (b & 3)) return false;
  switch (k) {
  case K_INT: return int_val(a) == int_val(b);
  case K_STRLIT: return str_eq(as_str(a), as_str(b));
  case K_NUMLIT: return memcmp(&((NumT *)a)->d, &((NumT *)b)->d, 8) == 0;
  case K_BIGLIT: return str_eq(((BigT *)a)->s, ((BigT *)b)->s);
  case K_USYM: return ((USymT *)a)->id == ((USymT *)b)->id;
  case K_TUPLE: {
    TupT *x = as_tup(a), *y = as_tup(b);
    if (x->len != y->len || tup_ro(x) != tup_ro(y)) return false;
    for (uint32_t i = 0; i < x->len; i++) {
      if (tup_kind(x, i) != tup_kind(y, i)) return false;
      Str *n1 = tup_name(x, i), *n2 = tup_name(y, i);
      if ((n1 == NULL) != (n2 == NULL) || (n1 && !str_eq(n1, n2))) return false;
    }
    if (x->e == y->e) return true;
    V ux = tup_uni(x), uy = tup_uni(y);
    if (ux && uy) return veq(ux, uy);
    for (uint32_t i = 0; i < x->len; i++)
      if (!veq(x->e[i], y->e[i])) return false;
    return true;
  }
  case K_ARRAY: return ((ArrT *)a)->ro == ((ArrT *)b)->ro && veq(((ArrT *)a)->el, ((ArrT *)b)->el);
  case K_UNION:
  case K_INTER: {
    SetT *x = (SetT *)a, *y = (SetT *)b;
    if (x->n != y->n) return false;
    // (a parameterless alias's written union is a type of its own to
    // instantiation: ty.c alias_topped)
    if (subst_made && alias_topped(a) != alias_topped(b)) return false;
    for (uint32_t i = 0; i < x->n; i++)
      if (!veq(x->m[i], y->m[i])) return false;
    return true;
  }
  case K_TPL: {
    TplT *x = (TplT *)a, *y = (TplT *)b;
    if (x->n != y->n) return false;
    for (uint32_t i = 0; i <= x->n; i++)
      if (!str_eq(x->texts[i], y->texts[i])) return false;
    for (uint32_t i = 0; i < x->n; i++)
      if (!veq(x->types[i], y->types[i])) return false;
    return true;
  }
  default:
    return false;
  }
}

static void insert(MKey *k) {
  uint64_t m = cap - 1, i = k->h & m;
  while (tab[i]) i = (i + 1) & m;
  tab[i] = k;
  used++;
}

static void grow(void) {
  if (!rooted) {
    gc_add_root(&tab, sizeof tab);
    rooted = true;
  }
  if (cap >= MEMO_MAX * 2) {
    // at the bound: start over
    memset(tab, 0, cap * sizeof(MKey *));
    used = 0;
    return;
  }
  MKey **old = tab;
  uint64_t oc = cap;
  cap = cap ? cap * 2 : 1024;
  tab = gc_alloc(cap * sizeof(MKey *));
  used = 0;
  for (uint64_t i = 0; i < oc; i++)
    if (old[i]) insert(old[i]);
}

// per alias: lookups and hits; an alias whose arguments cannot be hashed or
// whose lookups rarely hit stops being looked up
typedef struct { uint32_t lookups, hits, unhashable, off; } MStat;
static MStat *stats;
static int64_t nstats;
#define MEMO_TRIAL 512

static MStat *stat_of(int64_t id) {
  if (id >= nstats) {
    int64_t n = nstats ? nstats : 256;
    while (n <= id) n *= 2;
    MStat *s = calloc((size_t)n, sizeof(MStat));
    if (!s) die("memo: out of memory");
    if (nstats) memcpy(s, stats, (size_t)nstats * sizeof(MStat));
    free(stats);
    stats = s;
    nstats = n;
  }
  return &stats[id];
}

// the value of alias id with the n arguments in args, or 0; then *key is
// what rt_memo_put records the value under (0: not memoized)
// the flags generated code reads: set, an alias's code calls its body
// without looking it up
#define MEMO_FLAGS (1 << 20)
uint8_t tstc_memo_off[MEMO_FLAGS];
static uint8_t off_dummy;

V rt_memo_get(int64_t id, const V *args, int64_t n, int64_t *key) {
  uint8_t *off = id >= 0 && id < MEMO_FLAGS ? &tstc_memo_off[id] : &off_dummy;
  *key = 0;
  MStat *st = stat_of(id);
  if (st->off) return 0;
  if (++st->lookups >= MEMO_TRIAL && st->hits * 32 < st->lookups) {
    *off = 1;
    st->off = 1;
    return 0;
  }
  int64_t budget = MEMO_BUDGET;
  uint64_t h = mix(0, (uint64_t)id);
  for (int64_t i = 0; i < n && budget >= 0; i++) h = mix(h, vhash(args[i], &budget));
  if (budget < 0) {
    if (++st->unhashable >= 32 && st->hits == 0) *off = 1, st->off = 1;
    return 0;
  }
  if (cap) {
    uint64_t m = cap - 1;
    for (uint64_t i = h & m; tab[i]; i = (i + 1) & m) {
      MKey *k = tab[i];
      if (k->h != h || k->id != id || k->n != n) continue;
      bool eq = true;
      for (int64_t j = 0; j < n && eq; j++) eq = veq(k->a[j], args[j]);
      if (eq) {
        st->hits++;
        return k->v;
      }
    }
  }
  MKey *k = gc_alloc(sizeof(MKey) + (size_t)n * 8);
  k->h = h;
  k->id = id;
  k->n = n;
  memcpy(k->a, args, (size_t)n * 8);
  *key = (int64_t)k;
  return 0;
}

// v may hold a value updated in place (*budget below zero: too large to
// tell)
static bool in_place(V v, int64_t *budget) {
  if (--*budget < 0) return true;
  int k = kind(v);
  if (k == K_STORE || k == K_MAP || k == K_VEC) return true;
  if (v & 3) return false;
  if (k == K_TUPLE) {
    TupT *t = as_tup(v);
    if (tup_uni(t)) return in_place(tup_uni(t), budget);
    for (uint32_t i = 0; i < t->len; i++)
      if (in_place(t->e[i], budget)) return true;
  } else if (k == K_UNION || k == K_INTER) {
    SetT *s = (SetT *)v;
    for (uint32_t i = 0; i < s->n; i++)
      if (in_place(s->m[i], budget)) return true;
  }
  return false;
}

void rt_memo_put(int64_t key, V v) {
  MKey *k = (MKey *)key;
  int64_t budget = MEMO_BUDGET;
  if (!k || !v || in_place(v, &budget)) return;
  k->v = v;
  if ((used + 1) * 2 > cap) grow();
  insert(k);
}

// ---------------------------------------------------------------------------
// Identity of the object types a site makes (an object type literal, a
// mapped type, a function type, an interface): tsgo makes one type per
// declaration and type arguments of the type parameters it may reference
// (getObjectTypeInstantiation), so a site made again with the same values
// of the slots it reads gives the same object. A site without such slots
// holds its object (a global of the section __tstc_ident); the others are in
// a table (bounded as the memo table) by the site and those values.

typedef struct {
  uint64_t h;
  int64_t *site;
  int64_t n;
  V v;
  V a[];
} IKey;

static IKey **itab;
static uint64_t icap, iused;
#define IDENT_MAX (UINT64_C(1) << 20)

static void iinsert(IKey *k) {
  uint64_t m = icap - 1, i = k->h & m;
  while (itab[i]) i = (i + 1) & m;
  itab[i] = k;
  iused++;
}

static void igrow(void) {
  static bool irooted;
  if (!irooted) {
    gc_add_root(&itab, sizeof itab);
    irooted = true;
  }
  if (icap >= IDENT_MAX * 2) {
    memset(itab, 0, icap * sizeof(IKey *));
    iused = 0;
    return;
  }
  IKey **old = itab;
  uint64_t oc = icap;
  icap = icap ? icap * 2 : 1024;
  itab = gc_alloc(icap * sizeof(IKey *));
  iused = 0;
  for (uint64_t i = 0; i < oc; i++)
    if (old[i]) iinsert(old[i]);
}

// the object site made with the n values in keys, or 0; then *out is what
// rt_ident_put records the object under (0: nothing)
V rt_ident_get(int64_t *site, const V *keys, int64_t n, int64_t *out) {
  *out = 0;
  if (n == 0) {
    if (*site) return (V)*site;
    *out = (int64_t)site | 1;
    return 0;
  }
  int64_t budget = MEMO_BUDGET;
  uint64_t h = mix(0, (uint64_t)(uintptr_t)site);
  for (int64_t i = 0; i < n && budget >= 0; i++) h = mix(h, vhash(keys[i], &budget));
  if (budget < 0) return 0;
  for (int64_t i = 0; i < n; i++) {
    int64_t b = MEMO_BUDGET;
    if (in_place(keys[i], &b)) return 0;
  }
  if (icap) {
    uint64_t m = icap - 1;
    for (uint64_t i = h & m; itab[i]; i = (i + 1) & m) {
      IKey *k = itab[i];
      if (k->h != h || k->site != site || k->n != n) continue;
      bool eq = true;
      for (int64_t j = 0; j < n && eq; j++) eq = veq(k->a[j], keys[j]);
      if (eq) return k->v;
    }
  }
  IKey *k = gc_alloc(sizeof(IKey) + (size_t)n * 8);
  k->h = h;
  k->site = site;
  k->n = n;
  memcpy(k->a, keys, (size_t)n * 8);
  *out = (int64_t)k;
  return 0;
}

void rt_ident_put(int64_t key, V v) {
  if (!key || !v) return;
  if (key & 1) {
    *(int64_t *)(key & ~(int64_t)1) = (int64_t)v;
    return;
  }
  IKey *k = (IKey *)key;
  k->v = v;
  if ((iused + 1) * 2 > icap) igrow();
  iinsert(k);
}

// the object of every empty object type literal (tsgo: emptyTypeLiteralType)
int64_t tstc_empty_lit __attribute__((section("__DATA,__tstc_ident")));
