// Construction of types, structural equality, unions and intersections.
#include "desc.h"

#include <math.h>
#include <stdlib.h>

V box_int(int64_t x) {
  int64_t y = x ^ (INT64_C(1) << 62);
  if (y >= -(INT64_C(1) << 60) && y < (INT64_C(1) << 60)) return ((V)y << 3) | 6;
  IntT *t = gc_alloc_atomic(sizeof(IntT));
  t->tag = K_INT;
  t->v = x;
  return (V)t;
}

// small non-negative integers are shared (lengths, indices, counters)
#define SMALL_NUMS 4096
static NumT small_nums[SMALL_NUMS];

V mk_num(double d) {
  if (d >= 0 && d < SMALL_NUMS && !signbit(d)) {
    int i = (int)d;
    if ((double)i == d) {
      NumT *t = &small_nums[i];
      if (!t->tag) {
        t->tag = K_NUMLIT;
        t->d = d;
      }
      return (V)t;
    }
  }
  NumT *t = gc_alloc_atomic(sizeof(NumT));
  t->tag = K_NUMLIT;
  t->d = d;
  return (V)t;
}

V mk_biglit(Str *s) {
  BigT *t = gc_alloc(sizeof(BigT));
  t->tag = K_BIGLIT;
  t->s = s;
  return (V)t;
}

V mk_bigint_text(Str *s) {
  const uint16_t *d = str_d(s);
  int32_t n = s->len, i = 0;
  bool neg = n > 0 && d[0] == '-';
  if (neg) i = 1;
  if (n - i == 0 || n - i > 19) return mk_biglit(s);
  uint64_t v = 0;
  for (int32_t j = i; j < n; j++) {
    if (d[j] < '0' || d[j] > '9') return mk_biglit(s);
    v = v * 10 + (uint64_t)(d[j] - '0');
  }
  uint64_t limit = UINT64_C(9223372036854775807);
  if (!neg && v <= limit) return mk_int((int64_t)v);
  if (neg && v <= limit + 1) return mk_int((int64_t)(0 - v));
  return mk_biglit(s);
}

V mk_tpl(Str **texts, V *types, uint32_t n) {
  TplT *t = gc_alloc(sizeof(TplT) + (size_t)(2 * n + 1) * 8);
  t->tag = K_TPL;
  t->n = n;
  t->types = (V *)(t + 1);
  t->texts = (Str **)(t->types + n);
  memcpy(t->types, types, (size_t)n * 8);
  memcpy(t->texts, texts, (size_t)(n + 1) * 8);
  return (V)t;
}

V mk_array(V el, bool ro) {
  ArrT *a = gc_alloc(sizeof(ArrT));
  a->tag = K_ARRAY;
  a->ro = ro;
  a->el = el;
  return (V)a;
}

V mk_usym(int64_t id) {
  USymT *u = gc_alloc_atomic(sizeof(USymT));
  u->tag = K_USYM;
  u->id = id;
  return (V)u;
}

bool subst_made;

V mk_subst(V base, V cons) {
  if (cons == V_ANY || cons == V_UNKNOWN || base == V_ANY || cons == base || ty_eq(cons, base)) return base;
  SubstT *s = gc_alloc(sizeof(SubstT));
  s->tag = K_SUBST;
  s->base = base;
  s->cons = cons;
  subst_made = true;
  return (V)s;
}

V mk_deferred(V c, V e, V t, V f) {
  DefT *d = gc_alloc(sizeof(DefT));
  d->tag = K_DEFERRED;
  d->c = c;
  d->e = e;
  d->t = t;
  d->f = f;
  return (V)d;
}

void va_push(VA *a, V v) {
  if (a->n == a->cap) {
    uint32_t nc = a->cap ? a->cap * 2 : 8;
    V *d = gc_alloc((size_t)nc * 8);
    if (a->n) memcpy(d, a->d, (size_t)a->n * 8);
    a->d = d;
    a->cap = nc;
  }
  a->d[a->n++] = v;
}

// ---------------------------------------------------------------------------
// Tuples

TupT *tup_alloc(uint32_t n) {
  TupT *t = gc_alloc(sizeof(TupT) + (size_t)n * 8);
  t->tag = K_TUPLE;
  t->len = n;
  t->e = (V *)(t + 1);
  return t;
}

V mk_tuple(const V *e, uint32_t n) {
  TupT *t = tup_alloc(n);
  if (n) memcpy(t->e, e, (size_t)n * 8);
  return (V)t;
}

static TupT empty_tup = {K_TUPLE, 0, NULL, NULL};
V empty_tuple = (V)&empty_tup;

V mk_tuple0(void) { return empty_tuple; }
V mk_tuple1(V a) {
  TupT *t = tup_alloc(1);
  t->e[0] = a;
  return (V)t;
}
V mk_tuple2(V a, V b) {
  TupT *t = tup_alloc(2);
  t->e[0] = a;
  t->e[1] = b;
  return (V)t;
}
V mk_tuple3(V a, V b, V c) {
  TupT *t = tup_alloc(3);
  t->e[0] = a;
  t->e[1] = b;
  t->e[2] = c;
  return (V)t;
}

V tup_slice(TupT *t, uint32_t from, uint32_t to) {
  if (from == 0 && to == t->len) return (V)t;
  TupT *r = gc_alloc(sizeof(TupT));
  r->tag = K_TUPLE;
  r->len = to - from;
  r->e = t->e + from;
  if (t->x && !t->x->kinds && !t->x->names) {
    r->x = t->x;
  } else if (t->x) {
    TupExt *x = gc_alloc(sizeof(TupExt));
    *x = *t->x;
    if (x->kinds) x->kinds += from;
    if (x->names) x->names += from;
    r->x = x;
  }
  return (V)r;
}

int tup_fixed_len(TupT *t) {
  if (!t->x || !t->x->kinds) return (int)t->len;
  for (uint32_t i = 0; i < t->len; i++)
    if (t->x->kinds[i] != E_REQ) return -1;
  return (int)t->len;
}

// t uniform (tup_uni): the tuple of len of its elements, a view of its
// buffer, which grows (with the element) when needed
V tup_uni_view(TupT *t, uint32_t len) {
  VBuf *b = t->x->buf;
  if ((int64_t)len > b->used) {
    if ((int64_t)len > b->cap) {
      int64_t nc = (int64_t)len * 2 + 4;
      if (nc > INT32_MAX) nc = len;
      V *d = gc_alloc((size_t)nc * 8);
      memcpy(d, b->d, (size_t)b->used * 8);
      // views keep pointing into the old elements, which stay valid
      b->d = d;
      b->cap = (int32_t)nc;
    }
    for (int64_t i = b->used; i < (int64_t)len; i++) b->d[i] = b->uni;
    b->used = (int32_t)len;
  }
  TupT *r = gc_alloc(sizeof(TupT));
  r->tag = K_TUPLE;
  r->len = len;
  r->e = b->d;
  r->x = t->x;
  return (V)r;
}

// [...a, ...xs]: in place when a ends at the end of its buffer
V tup_append_n(TupT *a, const V *xs, uint32_t n) {
  if (n == 0) return (V)a;
  if (tup_nokinds(a) && (!a->x || !a->x->names)) {
    TupExt *ax = a->x;
    VBuf *b = ax ? ax->buf : NULL;
    if (b && b->uni) {
      bool same = true;
      for (uint32_t i = 0; i < n && same; i++) same = same_el(xs[i], b->uni);
      if (same) return tup_uni_view(a, a->len + n);
      // the uniform buffer stays so: a copy below
    } else if (b && a->e + a->len == b->d + b->used) {
      int32_t off = (int32_t)(a->e - b->d);
      if (b->used + (int64_t)n > b->cap) {
        int32_t nc = (b->used + (int32_t)n) * 2 + 4;
        V *d = gc_alloc((size_t)nc * 8);
        memcpy(d, b->d, (size_t)b->used * 8);
        // views keep pointing into the old elements, which stay valid
        b->d = d;
        b->cap = nc;
      }
      memcpy(b->d + b->used, xs, (size_t)n * 8);
      b->used += (int32_t)n;
      TupT *r = gc_alloc(sizeof(TupT));
      r->tag = K_TUPLE;
      r->len = a->len + n;
      r->e = b->d + off;
      r->x = ax;
      return (V)r;
    }
    VBuf *nb = gc_alloc(sizeof(VBuf));
    nb->cap = (int32_t)(a->len + n) * 2 + 4;
    nb->d = gc_alloc((size_t)nb->cap * 8);
    if (a->len) memcpy(nb->d, a->e, (size_t)a->len * 8);
    memcpy(nb->d + a->len, xs, (size_t)n * 8);
    nb->used = (int32_t)(a->len + n);
    // uniform when every element is the same
    V u = nb->d[0];
    bool same = true;
    for (int32_t i = 1; i < nb->used && same; i++) same = same_el(nb->d[i], u);
    if (same) nb->uni = u;
    TupExt *nx = gc_alloc(sizeof(TupExt));
    nx->ro = tup_ro(a);
    nx->buf = nb;
    TupT *r = gc_alloc(sizeof(TupT));
    r->tag = K_TUPLE;
    r->len = a->len + n;
    r->e = nb->d;
    r->x = nx;
    return (V)r;
  }
  TB b;
  tb_init(&b);
  b.ro = tup_ro(a);
  for (uint32_t i = 0; i < a->len; i++) tb_push(&b, a->e[i], tup_kind(a, i), tup_name(a, i));
  for (uint32_t i = 0; i < n; i++) tb_push(&b, xs[i], E_REQ, NULL);
  return tb_finish(&b);
}

V tup_append(TupT *a, V x) { return tup_append_n(a, &x, 1); }

void tb_init(TB *b) { memset(b, 0, sizeof *b); }

void tb_push(TB *b, V t, int kind, Str *name) {
  if (b->n == b->cap) {
    uint32_t nc = b->cap ? b->cap * 2 : 8;
    V *e = gc_alloc((size_t)nc * 8);
    uint8_t *k = gc_alloc_atomic(nc);
    Str **nm = gc_alloc((size_t)nc * 8);
    if (b->n) {
      memcpy(e, b->e, (size_t)b->n * 8);
      memcpy(k, b->k, b->n);
      memcpy(nm, b->nm, (size_t)b->n * 8);
    }
    b->e = e;
    b->k = k;
    b->nm = nm;
    b->cap = nc;
  }
  b->e[b->n] = t;
  b->k[b->n] = (uint8_t)kind;
  b->nm[b->n] = name;
  if (kind != E_REQ) b->any_k = true;
  if (name) b->any_n = true;
  b->n++;
}

V tb_finish(TB *b) {
  if (b->n == 0 && !b->ro) return empty_tuple;
  // optional elements have undefined in their type
  if (b->any_k)
    for (uint32_t i = 0; i < b->n; i++)
      if (b->k[i] == E_OPT) b->e[i] = opt_type(b->e[i]);
  TupT *t = gc_alloc(sizeof(TupT));
  t->tag = K_TUPLE;
  t->len = b->n;
  t->e = b->e;
  if (b->any_k || b->any_n || b->ro) {
    TupExt *x = gc_alloc(sizeof(TupExt));
    x->ro = b->ro;
    x->kinds = b->any_k ? b->k : NULL;
    x->names = b->any_n ? b->nm : NULL;
    t->x = x;
  }
  return (V)t;
}

// ---------------------------------------------------------------------------
// Objects

static uint64_t seq_counter = 1;
uint64_t fresh_seq(void) { return seq_counter++; }

V prop_value(Prop *p) {
  if (p->ty) return p->ty;
  if (p->th && !p->forcing) {
    // guard against re-entrant forcing of the same property
    p->forcing = 1;
    V t = call_thunk(p->th, p->env);
    // (optional properties have undefined in their type)
    t = prop_post(p->post, t);
    p->ty = t;
    p->th = NULL;
    p->env = NULL;
    return t;
  }
  return V_ANY;
}

Prop *obj_get(ObjT *o, Str *name) {
  if (!o->hidx) {
    for (uint32_t i = 0; i < o->np; i++)
      if (str_eq(o->props[i].name, name)) return &o->props[i];
    return NULL;
  }
  uint32_t m = o->hcap - 1, h = str_hash(name) & m;
  for (;;) {
    int32_t i = o->hidx[h];
    if (i < 0) return NULL;
    if (str_eq(o->props[i].name, name)) return &o->props[i];
    h = (h + 1) & m;
  }
}

void ob_init(OB *b) { memset(b, 0, sizeof *b); }

int32_t nix_get(NameIx *x, Str *name) {
  if (!x->cap) return -1;
  uint32_t k = str_hash(name) & (x->cap - 1);
  while (x->k[k]) {
    if (str_eq(x->k[k], name)) return x->v[k];
    k = (k + 1) & (x->cap - 1);
  }
  return -1;
}

void nix_put(NameIx *x, Str *name, int32_t i) {
  if ((x->n + 1) * 2 > x->cap) {
    NameIx y = {0};
    y.cap = x->cap ? x->cap * 2 : 32;
    y.k = gc_alloc((size_t)y.cap * sizeof(Str *));
    y.v = gc_alloc_atomic((size_t)y.cap * 4);
    for (uint32_t j = 0; j < x->cap; j++)
      if (x->k[j]) nix_put(&y, x->k[j], x->v[j]);
    *x = y;
  }
  uint32_t k = str_hash(name) & (x->cap - 1);
  while (x->k[k]) {
    if (str_eq(x->k[k], name)) {
      x->v[k] = i;
      return;
    }
    k = (k + 1) & (x->cap - 1);
  }
  x->k[k] = name;
  x->v[k] = i;
  x->n++;
}

// (the last property of the name; past a few, through the index of the
// names, brought up to date with the properties added since)
int32_t ob_find(OB *b, Str *name) {
  if (b->n <= 16) {
    for (int32_t i = (int32_t)b->n - 1; i >= 0; i--)
      if (str_eq(b->p[i].name, name)) return i;
    return -1;
  }
  for (; b->hn < b->n; b->hn++) nix_put(&b->names, b->p[b->hn].name, (int32_t)b->hn);
  return nix_get(&b->names, name);
}

// may t be undefined or void (maybeTypeOfKind)
static bool maybe_undef_void(V t) {
  if (t == V_UNDEFINED || t == V_VOID) return true;
  if (kind(t) == K_UNION || kind(t) == K_INTER)
    for (uint32_t i = 0; i < set_n(t); i++)
      if (maybe_undef_void(set_m(t, i))) return true;
  return false;
}

V prop_post(int post, V t) {
  switch (post) {
  case PROP_OPT: return opt_type(t);
  case PROP_MAPPED_OPT: return maybe_undef_void(t) ? t : opt_type(t);
  case PROP_STRIP: return remove_undefined(t);
  default: return t;
  }
}

void ob_prop(OB *b, Str *name, V ty, Thunk th, V *env, bool opt, bool ro, bool numeric,
             bool keep_seq) {
  ob_prop_x(b, name, ty, th, env, opt, ro, numeric, keep_seq, opt ? PROP_OPT : PROP_AS_IS);
}

void ob_prop_x(OB *b, Str *name, V ty, Thunk th, V *env, bool opt, bool ro, bool numeric,
               bool keep_seq, int post) {
  int32_t i = b->n > 0 ? ob_find(b, name) : -1;
  Prop *p;
  uint64_t seq;
  if (i >= 0) {
    p = &b->p[i];
    seq = keep_seq ? p->seq : fresh_seq();
  } else {
    if (b->n == b->cap) {
      uint32_t nc = b->cap ? b->cap * 2 : 8;
      Prop *np = gc_alloc((size_t)nc * sizeof(Prop));
      if (b->n) memcpy(np, b->p, (size_t)b->n * sizeof(Prop));
      b->p = np;
      b->cap = nc;
    }
    p = &b->p[b->n++];
    seq = fresh_seq();
  }
  p->name = name;
  p->ty = ty ? prop_post(post, ty) : 0;
  p->th = ty ? NULL : th;
  p->env = ty ? NULL : env;
  p->seq = seq;
  p->opt = opt;
  p->ro = ro;
  p->numeric = numeric;
  p->forcing = 0;
  p->post = (uint8_t)post;
}

void ob_index(OB *b, V key, V ty, bool ro) {
  if (b->ni == b->icap) {
    uint32_t nc = b->icap ? b->icap * 2 : 4;
    IndexSig *n = gc_alloc((size_t)nc * sizeof(IndexSig));
    if (b->ni) memcpy(n, b->ix, (size_t)b->ni * sizeof(IndexSig));
    b->ix = n;
    b->icap = nc;
  }
  b->ix[b->ni].key = key;
  b->ix[b->ni].ty = ty;
  b->ix[b->ni].ro = ro;
  b->ni++;
}

void ob_call(OB *b, FnT *f) {
  if (b->nc == b->ccap) {
    uint32_t nc = b->ccap ? b->ccap * 2 : 2;
    FnT **n = gc_alloc((size_t)nc * 8);
    if (b->nc) memcpy(n, b->c, (size_t)b->nc * 8);
    b->c = n;
    b->ccap = nc;
  }
  b->c[b->nc++] = f;
}

static int prop_seq_cmp(const void *a, const void *b) {
  uint64_t x = ((const Prop *)a)->seq, y = ((const Prop *)b)->seq;
  return x < y ? -1 : x > y;
}

V ob_finish(OB *b) {
  ObjT *o = gc_alloc(sizeof(ObjT));
  o->tag = K_OBJ;
  o->np = b->n;
  o->props = b->p;
  bool sorted = true;
  for (uint32_t i = 1; i < b->n; i++)
    if (b->p[i - 1].seq > b->p[i].seq) sorted = false;
  if (!sorted) qsort(b->p, b->n, sizeof(Prop), prop_seq_cmp);
  if (b->n > 8) {
    uint32_t cap = 16;
    while (cap < b->n * 2) cap *= 2;
    int32_t *h = gc_alloc_atomic((size_t)cap * 4);
    memset(h, 0xFF, (size_t)cap * 4);
    for (uint32_t i = 0; i < b->n; i++) {
      uint32_t k = str_hash(b->p[i].name) & (cap - 1);
      while (h[k] >= 0) k = (k + 1) & (cap - 1);
      h[k] = (int32_t)i;
    }
    o->hidx = h;
    o->hcap = cap;
  }
  o->ni = b->ni;
  o->index = b->ix;
  o->nc = b->nc;
  o->calls = b->c;
  return (V)o;
}

FnT *mk_fn(Param *params, uint32_t np, V ret, bool ctor) {
  FnT *f = gc_alloc(sizeof(FnT));
  f->tag = K_FN;
  f->ctor = ctor;
  f->np = np;
  f->ret = ret;
  f->params = params;
  return f;
}

V mk_genfn(const int64_t *slots, uint32_t nslots, Thunk code, V *env, uint32_t frame) {
  GenFnT *g = gc_alloc(sizeof(GenFnT));
  g->tag = K_GENFN;
  g->nslots = nslots;
  g->frame = frame;
  g->slots = slots;
  g->code = code;
  V *e = gc_alloc((size_t)(frame ? frame : 1) * 8);
  memcpy(e, env, (size_t)frame * 8);
  g->env = e;
  return (V)g;
}

// ---------------------------------------------------------------------------
// Equality

bool is_literal(V t) {
  switch (kind(t)) {
  case K_STRLIT: case K_NUMLIT: case K_BIGLIT: case K_INT: case K_TRUE: case K_FALSE:
    return true;
  default:
    return false;
  }
}

static bool union_has(const V *ms, uint32_t n, V t) {
  for (uint32_t i = 0; i < n; i++)
    if (ty_eq(ms[i], t)) return true;
  return false;
}

// ---------------------------------------------------------------------------
// Parameterless aliases referenced while computed (tsgo defers array and
// tuple element types: `type A = [A]` is a tuple whose element is itself).
// The reference gets a placeholder (an empty object while the alias is
// computed); the alias's value is then copied into it, so that the
// placeholder is the value, with every reference to itself.

// the most a value copied into a placeholder takes (a union of 30 members)
#define KNOT_CAP (8 + 8 * 30)
int64_t knots_made;

typedef struct { V v, busy, knot; const char *name; } ConstCache;

V rt_knot_open(ConstCache *c) {
  if (!c->knot) {
    ObjT *o = gc_alloc(KNOT_CAP);
    memset(o, 0, KNOT_CAP);
    o->tag = K_OBJ;
    c->knot = (V)o;
  }
  return c->knot;
}

static size_t knot_size(V v) {
  if (v & 3) return 0;
  switch (kind(v)) {
  case K_ARRAY: return sizeof(ArrT);
  case K_TUPLE: return sizeof(TupT);
  case K_FN: return sizeof(FnT);
  case K_GENFN: return sizeof(GenFnT);
  case K_OBJ: return sizeof(ObjT);
  case K_UNION:
  case K_INTER: return sizeof(SetT) + (size_t)((SetT *)v)->n * 8;
  default: return 0;
  }
}

// the unions and intersections that are the types of parameterless aliases
// written as such (tsgo: their alias is theirs, so instantiation leaves them
// as they are: isNonGenericTopLevelType)
static V *atop;
static uint64_t atop_cap, atop_n;

static uint64_t atop_slot(V v) {
  uint64_t m = atop_cap - 1, i = (uint64_t)(v >> 3) * UINT64_C(0x9E3779B97F4A7C15) >> 20 & m;
  while (atop[i] && atop[i] != v) i = (i + 1) & m;
  return i;
}

bool alias_topped(V v) {
  return atop_n && atop[atop_slot(v)] == v;
}

static void atop_add(V v) {
  if ((atop_n + 1) * 2 > atop_cap) {
    V *old = atop;
    uint64_t oc = atop_cap;
    atop_cap = atop_cap ? atop_cap * 2 : 64;
    atop = gc_alloc(atop_cap * sizeof(V));
    if (!old) gc_add_root(&atop, sizeof atop);
    atop_n = 0;
    for (uint64_t i = 0; i < oc; i++)
      if (old[i]) {
        atop[atop_slot(old[i])] = old[i];
        atop_n++;
      }
  }
  uint64_t i = atop_slot(v);
  if (!atop[i]) {
    atop[i] = v;
    atop_n++;
  }
}

V rt_knot_close(ConstCache *c, V v, int64_t written_set) {
  if (written_set && !(v & 3) && (kind(v) == K_UNION || kind(v) == K_INTER)) atop_add(v);
  if (c->knot && c->knot != v) {
    size_t n = knot_size(v);
    if (n && n <= KNOT_CAP) {
      memcpy((void *)c->knot, (void *)v, n);
      v = c->knot;
      knots_made++;
    }
  }
  c->v = v;
  c->busy = 0;
  return v;
}

// with values that contain themselves: the pairs being compared, assumed
// equal
static struct { V a, b; } eq_stack[1024];
static int eq_sp;

static bool ty_eq_s(V a, V b, int ka);

bool ty_eq(V a, V b) {
  if (a == b) return true;
  int ka = kind(a), kb = kind(b);
  if (ka != kb) return false;
  if (ka < K_STRLIT) return true;
  if (knots_made && (ka == K_TUPLE || ka == K_ARRAY || ka == K_UNION || ka == K_INTER)) {
    for (int i = 0; i < eq_sp; i++)
      if (eq_stack[i].a == a && eq_stack[i].b == b) return true;
    if (eq_sp >= 1024) return false;
    eq_stack[eq_sp].a = a;
    eq_stack[eq_sp].b = b;
    eq_sp++;
    bool r = ty_eq_s(a, b, ka);
    eq_sp--;
    return r;
  }
  return ty_eq_s(a, b, ka);
}

static bool ty_eq_s(V a, V b, int ka) {
  switch (ka) {
  case K_STRLIT: return str_eq(as_str(a), as_str(b));
  case K_NUMLIT: return num_val(a) == num_val(b);
  case K_BIGLIT: return str_eq(((BigT *)a)->s, ((BigT *)b)->s);
  case K_USYM: return ((USymT *)a)->id == ((USymT *)b)->id;
  case K_INT: return int_val(a) == int_val(b);
  case K_SUBST:
    return ty_eq(((SubstT *)a)->base, ((SubstT *)b)->base) && ty_eq(((SubstT *)a)->cons, ((SubstT *)b)->cons);
  case K_TPL: {
    TplT *x = (TplT *)a, *y = (TplT *)b;
    if (x->n != y->n) return false;
    for (uint32_t i = 0; i <= x->n; i++)
      if (!str_eq(x->texts[i], y->texts[i])) return false;
    for (uint32_t i = 0; i < x->n; i++)
      if (!ty_eq(x->types[i], y->types[i])) return false;
    return true;
  }
  case K_TUPLE: {
    TupT *x = as_tup(a), *y = as_tup(b);
    if (x->len != y->len || tup_ro(x) != tup_ro(y)) return false;
    if (x->e == y->e && (x->x ? x->x->kinds : NULL) == (y->x ? y->x->kinds : NULL)) return true;
    V ux = tup_uni(x), uy = tup_uni(y);
    if (ux && uy) return ty_eq(ux, uy);
    for (uint32_t i = 0; i < x->len; i++)
      if (tup_kind(x, i) != tup_kind(y, i) || !ty_eq(x->e[i], y->e[i])) return false;
    return true;
  }
  case K_ARRAY: {
    ArrT *x = (ArrT *)a, *y = (ArrT *)b;
    return x->ro == y->ro && ty_eq(x->el, y->el);
  }
  case K_UNION: {
    SetT *x = (SetT *)a, *y = (SetT *)b;
    if (x->n != y->n) return false;
    for (uint32_t i = 0; i < x->n; i++)
      if (!union_has(y->m, y->n, x->m[i])) return false;
    return true;
  }
  case K_INTER: {
    SetT *x = (SetT *)a, *y = (SetT *)b;
    if (x->n != y->n) return false;
    for (uint32_t i = 0; i < x->n; i++)
      if (!ty_eq(x->m[i], y->m[i])) return false;
    return true;
  }
  default:
    // objects, functions, generic functions, vectors, maps, heaps: identity
    return false;
  }
}

// ---------------------------------------------------------------------------
// Unions

static V mk_set(int tag, const V *m, uint32_t n) {
  SetT *s = gc_alloc(sizeof(SetT) + (size_t)n * 8);
  s->tag = (uint32_t)tag;
  s->n = n;
  memcpy(s->m, m, (size_t)n * 8);
  return (V)s;
}

static inline uint64_t hmix(uint64_t h, uint64_t x) {
  x *= UINT64_C(0x9E3779B97F4A7C15);
  x ^= x >> 29;
  return (h ^ x) * UINT64_C(0xBF58476D1CE4E5B9) + 0x94D049BB133111EBu;
}

// a hash of a type, equal for types ty_eq finds equal: it reads a bounded
// part of the structure (the first and last elements of tuples, nesting to
// a fixed depth, a union's members only at the top), so that any two
// representations of equal types read the same positions
static uint64_t ty_hash(V t, int depth) {
  int k = kind(t);
  if (k < K_STRLIT) return (uint64_t)k + 1;
  switch (k) {
  case K_STRLIT: return hmix(16, str_hash(as_str(t)));
  case K_NUMLIT: {
    double d = num_val(t);
    uint64_t u;
    if (d == 0) d = 0;
    memcpy(&u, &d, 8);
    return hmix(17, u);
  }
  case K_INT: return hmix(18, (uint64_t)int_val(t));
  case K_BIGLIT: return hmix(19, str_hash(((BigT *)t)->s));
  case K_USYM: return hmix(20, (uint64_t)((USymT *)t)->id);
  case K_SUBST: return hmix(28, ty_hash(((SubstT *)t)->base, depth + 1));
  default: break;
  }
  if (depth >= 3) return (uint64_t)k * 977;
  switch (k) {
  case K_TUPLE: {
    TupT *x = as_tup(t);
    uint64_t h = hmix(21, (uint64_t)x->len * 2 + tup_ro(x));
    V u = tup_uni(x);
    for (uint32_t i = 0; i < x->len; i++) {
      if (i == 8 && x->len > 12) i = x->len - 4;
      h = hmix(h, (uint64_t)tup_kind(x, i));
      h = hmix(h, ty_hash(u ? u : x->e[i], depth + 1));
    }
    return h;
  }
  case K_ARRAY: return hmix(22 + ((ArrT *)t)->ro, ty_hash(((ArrT *)t)->el, depth + 1));
  case K_TPL: {
    TplT *x = (TplT *)t;
    uint64_t h = hmix(24, x->n);
    for (uint32_t i = 0; i <= x->n; i++) h = hmix(h, str_hash(x->texts[i]));
    for (uint32_t i = 0; i < x->n && i < 8; i++) h = hmix(h, ty_hash(x->types[i], depth + 1));
    return h;
  }
  case K_UNION: {
    // members in any order
    SetT *x = (SetT *)t;
    uint64_t h = 0;
    if (depth == 0)
      for (uint32_t i = 0; i < x->n; i++) h += ty_hash(x->m[i], depth + 1);
    return hmix(25 + h, x->n);
  }
  case K_INTER: {
    SetT *x = (SetT *)t;
    uint64_t h = hmix(26, x->n);
    for (uint32_t i = 0; i < x->n && i < 8; i++) h = hmix(h, ty_hash(x->m[i], depth + 1));
    return h;
  }
  default:
    // objects, functions, ...: identity
    return hmix(27, t);
  }
}

static uint32_t lit_hash(V t) {
  uint64_t h = ty_hash(t, 0);
  return (uint32_t)(h ^ (h >> 32)) | 1;
}

typedef struct {
  VA out;
  bool any, unknown, string, number, bigint, symbol, strlit, pattern;
  // literal index (open addressing over positions in out) once out is big
  int32_t *h;
  uint32_t hcap, hn;
} UB;

static void ub_hinsert(UB *u, uint32_t pos) {
  uint32_t m = u->hcap - 1, k = lit_hash(u->out.d[pos]) & m;
  while (u->h[k] >= 0) k = (k + 1) & m;
  u->h[k] = (int32_t)pos;
  u->hn++;
}

static void ub_rehash(UB *u) {
  uint32_t cap = 64;
  while (cap < u->out.n * 4) cap *= 2;
  u->h = gc_alloc_atomic((size_t)cap * 4);
  memset(u->h, 0xFF, (size_t)cap * 4);
  u->hcap = cap;
  u->hn = 0;
  for (uint32_t i = 0; i < u->out.n; i++)
    if (lit_hash(u->out.d[i])) ub_hinsert(u, i);
}

static void ub_add(UB *u, V t) {
  int k = kind(t);
  switch (k) {
  case K_NEVER: return;
  case K_ANY: u->any = true; return;
  case K_UNKNOWN: u->unknown = true; return;
  case K_UNION: {
    SetT *s = (SetT *)t;
    for (uint32_t i = 0; i < s->n; i++) ub_add(u, s->m[i]);
    return;
  }
  case K_STRING: u->string = true; break;
  case K_NUMBER: u->number = true; break;
  case K_BIGINT: u->bigint = true; break;
  case K_SYMBOL: u->symbol = true; break;
  case K_STRLIT: u->strlit = true; break;
  case K_TPL: case K_STRMAP: u->pattern = true; break;
  default: break;
  }
  uint32_t h = u->h ? lit_hash(t) : 0;
  if (h) {
    uint32_t m = u->hcap - 1, j = h & m;
    while (u->h[j] >= 0) {
      if (ty_eq(u->out.d[u->h[j]], t)) return;
      j = (j + 1) & m;
    }
    va_push(&u->out, t);
    if ((u->hn + 1) * 2 > u->hcap) ub_rehash(u);
    else ub_hinsert(u, u->out.n - 1);
    return;
  }
  if (union_has(u->out.d, u->out.n, t)) return;
  va_push(&u->out, t);
  if (u->out.n > 16) ub_rehash(u);
}

bool is_pattern_literal(V t);
bool template_matches(V s, V t);
bool strmap_member(V s, V t);

V mk_union(const V *items, uint32_t n) {
  if (n == 1 && kind(items[0]) != K_UNION) return items[0];
  if (n == 0) return V_NEVER;
  UB u;
  memset(&u, 0, sizeof u);
  for (uint32_t i = 0; i < n; i++) ub_add(&u, items[i]);
  if (u.any) return V_ANY;
  if (u.unknown) return V_UNKNOWN;
  V *res = u.out.d;
  uint32_t rn = u.out.n;
  // removeRedundantLiteralTypes
  if (u.string || u.number || u.bigint || u.symbol) {
    uint32_t j = 0;
    for (uint32_t i = 0; i < rn; i++) {
      int k = kind(res[i]);
      bool keep = true;
      if ((k == K_STRLIT || k == K_TPL || k == K_STRMAP) && u.string) keep = false;
      if (k == K_NUMLIT && u.number) keep = false;
      if ((k == K_BIGLIT || k == K_INT) && u.bigint) keep = false;
      if (k == K_USYM && u.symbol && ((USymT *)res[i])->id >= 0) keep = false;
      if (keep) res[j++] = res[i];
    }
    rn = j;
  }
  // removeStringLiteralsMatchedByTemplateLiterals
  if (u.strlit && u.pattern && !u.string) {
    VA pats;
    va_init(&pats);
    for (uint32_t i = 0; i < rn; i++)
      if (is_pattern_literal(res[i])) va_push(&pats, res[i]);
    if (pats.n) {
      uint32_t j = 0;
      for (uint32_t i = 0; i < rn; i++) {
        bool keep = true;
        if (kind(res[i]) == K_STRLIT)
          for (uint32_t q = 0; q < pats.n && keep; q++)
            keep = !(kind(pats.d[q]) == K_TPL ? template_matches(res[i], pats.d[q]) : strmap_member(res[i], pats.d[q]));
        if (keep) res[j++] = res[i];
      }
      rn = j;
    }
  }
  if (rn == 0) return V_NEVER;
  if (rn == 1) return res[0];
  return mk_set(K_UNION, res, rn);
}

V mk_union2(V a, V b) {
  V it[2] = {a, b};
  return mk_union(it, 2);
}

// ---------------------------------------------------------------------------
// Intersections (getIntersectionType)

bool is_empty_anon_obj(V t);

// IncludesEmptyObject, the flag addTypeToIntersection records
#define INC_EMPTY (1u << 26)

static uint32_t add_to_inter(VA *set, uint32_t inc, V t) {
  if (kind(t) == K_INTER) {
    SetT *s = (SetT *)t;
    for (uint32_t i = 0; i < s->n; i++) inc = add_to_inter(set, inc, s->m[i]);
    return inc;
  }
  if (is_empty_anon_obj(t)) {
    if (!(inc & INC_EMPTY)) {
      inc |= INC_EMPTY;
      va_push(set, t);
    }
    return inc;
  }
  uint32_t f = ty_flags(t);
  if (!(f & (TF_ANY | TF_UNKNOWN))) {
    bool has = false;
    for (uint32_t i = 0; i < set->n && !has; i++) has = set->d[i] == t || ty_eq(set->d[i], t);
    if (!has) {
      // two distinct unit types: the intersection is empty
      if ((f & TF_UNIT) && (inc & TF_UNIT)) inc |= TF_NONPRIM;
      va_push(set, t);
    }
  }
  return inc | (f & TF_INCLUDES_MASK);
}

static bool is_primitive_union(V t) {
  if (kind(t) != K_UNION) return false;
  for (uint32_t i = 0; i < set_n(t); i++)
    if (ty_flags(set_m(t, i)) & TF_NOT_PRIMITIVE_UNION) return false;
  return true;
}

static bool union_contains(V u, V t) {
  for (uint32_t i = 0; i < set_n(u); i++)
    if (ty_eq(set_m(u, i), t)) return true;
  V prim = 0;
  switch (kind(t)) {
  case K_STRLIT: prim = V_STRING; break;
  case K_NUMLIT: prim = V_NUMBER; break;
  case K_BIGLIT: case K_INT: prim = V_BIGINT; break;
  case K_USYM: prim = ((USymT *)t)->id >= 0 ? V_SYMBOL : 0; break;
  default: break;
  }
  if (!prim) return false;
  for (uint32_t i = 0; i < set_n(u); i++)
    if (set_m(u, i) == prim) return true;
  return false;
}

static V inter_of(VA *set, uint32_t ninputs);

static V mk_inter_ex(const V *items, uint32_t n, bool no_supertype_reduction);

V mk_inter(const V *items, uint32_t n) { return mk_inter_ex(items, n, false); }

// an intersection written in the program (getTypeFromIntersectionTypeNode):
// X & {} and {} & X with X string, number, bigint or a pattern template
// stay so (they keep literals in unions)
V mk_inter_node(const V *items, uint32_t n) {
  bool keep = false;
  if (n == 2) {
    int e = is_empty_anon_obj(items[0]) ? 0 : is_empty_anon_obj(items[1]) ? 1 : -1;
    if (e >= 0) {
      V t = items[1 - e];
      int k = kind(t);
      keep = k == K_STRING || k == K_NUMBER || k == K_BIGINT || (k == K_TPL && is_pattern_literal(t));
    }
  }
  return mk_inter_ex(items, n, keep);
}

static V mk_inter_ex(const V *items, uint32_t n, bool no_supertype_reduction) {
  VA set;
  va_init(&set);
  uint32_t inc = 0;
  for (uint32_t i = 0; i < n; i++) inc = add_to_inter(&set, inc, items[i]);
  if (inc & TF_NEVER) return V_NEVER;
  if (((inc & TF_NULLABLE) && (inc & (TF_OBJECT | TF_NONPRIM | INC_EMPTY))) ||
      ((inc & TF_NONPRIM) && (inc & (TF_DISJOINT & ~TF_NONPRIM))) ||
      ((inc & TF_STRINGLIKE) && (inc & (TF_DISJOINT & ~TF_STRINGLIKE))) ||
      ((inc & TF_NUMBERLIKE) && (inc & (TF_DISJOINT & ~TF_NUMBERLIKE))) ||
      ((inc & TF_BIGINTLIKE) && (inc & (TF_DISJOINT & ~TF_BIGINTLIKE))) ||
      ((inc & TF_SYMBOLLIKE) && (inc & (TF_DISJOINT & ~TF_SYMBOLLIKE))) ||
      ((inc & TF_VOIDLIKE) && (inc & (TF_DISJOINT & ~TF_VOIDLIKE))))
    return V_NEVER;
  if ((inc & (TF_TPL | TF_STRMAP)) && (inc & TF_STRLIT)) {
    // extractRedundantTemplateLiterals
    for (uint32_t i = set.n; i > 0; i--) {
      V t = set.d[i - 1];
      int k = kind(t);
      if (k != K_TPL && k != K_STRMAP) continue;
      for (uint32_t j = 0; j < set.n; j++) {
        V l = set.d[j];
        if (kind(l) != K_STRLIT) continue;
        if (is_subtype(l, t)) {
          memmove(set.d + i - 1, set.d + i, (size_t)(set.n - i) * 8);
          set.n--;
          break;
        }
        if (is_pattern_literal(t)) return V_NEVER;
      }
    }
  }
  if (inc & TF_ANY) return V_ANY;
  if (((inc & TF_STRING) && (inc & (TF_STRLIT | TF_TPL | TF_STRMAP))) || ((inc & TF_NUMBER) && (inc & TF_NUMLIT)) ||
      ((inc & TF_BIGINT) && (inc & TF_BIGLIT)) || ((inc & TF_ESSYMBOL) && (inc & TF_USYM)) ||
      ((inc & TF_VOID) && (inc & TF_UNDEFINED)) || ((inc & INC_EMPTY) && (inc & TF_DEFNONNULL) && !no_supertype_reduction)) {
    // removeRedundantSupertypes
    uint32_t j = 0;
    for (uint32_t i = 0; i < set.n; i++) {
      V t = set.d[i];
      int k = kind(t);
      bool remove = (k == K_STRING && (inc & (TF_STRLIT | TF_TPL | TF_STRMAP))) || (k == K_NUMBER && (inc & TF_NUMLIT)) ||
                    (k == K_BIGINT && (inc & TF_BIGLIT)) || (k == K_SYMBOL && (inc & TF_USYM)) ||
                    (k == K_VOID && (inc & TF_UNDEFINED)) || (is_empty_anon_obj(t) && (inc & TF_DEFNONNULL));
      if (!remove) set.d[j++] = t;
    }
    set.n = j;
  }
  if (set.n == 0) return V_UNKNOWN;
  if (set.n == 1) return set.d[0];
  return inter_of(&set, n);
}

static bool has_undefined(V t) {
  if (kind(t) != K_UNION) return false;
  for (uint32_t i = 0; i < set_n(t); i++)
    if (set_m(t, i) == V_UNDEFINED) return true;
  return false;
}

static bool has_null(V t) {
  if (kind(t) != K_UNION) return false;
  for (uint32_t i = 0; i < set_n(t); i++)
    if (set_m(t, i) == V_NULL) return true;
  return false;
}

static V without(V u, V m) {
  VA r;
  va_init(&r);
  for (uint32_t i = 0; i < set_n(u); i++)
    if (set_m(u, i) != m) va_push(&r, set_m(u, i));
  return mk_union(r.d, r.n);
}

// the intersection of a reduced set of two or more types
static V inter_of(VA *set, uint32_t ninputs) {
  bool any_union = false;
  for (uint32_t i = 0; i < set->n; i++)
    if (kind(set->d[i]) == K_UNION) any_union = true;
  if (!any_union) return mk_set(K_INTER, set->d, set->n);
  // intersectUnionsOfPrimitiveTypes
  int64_t first = -1;
  uint32_t nprim = 0;
  for (uint32_t i = 0; i < set->n; i++)
    if (is_primitive_union(set->d[i])) {
      if (first < 0) first = i;
      nprim++;
    }
  if (nprim > 1) {
    VA unions, rest;
    va_init(&unions);
    va_init(&rest);
    for (uint32_t i = 0; i < set->n; i++) {
      if (is_primitive_union(set->d[i])) {
        va_push(&unions, set->d[i]);
        if ((int64_t)i == first) va_push(&rest, 0);
      } else {
        va_push(&rest, set->d[i]);
      }
    }
    VA checked, result;
    va_init(&checked);
    va_init(&result);
    for (uint32_t q = 0; q < unions.n; q++) {
      V u = unions.d[q];
      for (uint32_t i = 0; i < set_n(u); i++) {
        V t = set_m(u, i);
        bool seen = false;
        for (uint32_t j = 0; j < checked.n && !seen; j++) seen = ty_eq(checked.d[j], t);
        if (seen) continue;
        va_push(&checked, t);
        bool all = true;
        for (uint32_t j = 0; j < unions.n && all; j++) all = union_contains(unions.d[j], t);
        if (all) va_push(&result, t);
      }
    }
    for (uint32_t i = 0; i < rest.n; i++)
      if (!rest.d[i]) rest.d[i] = mk_union(result.d, result.n);
    return mk_inter(rest.d, rest.n);
  }
  bool all_undef = true, all_null = true;
  for (uint32_t i = 0; i < set->n; i++) {
    if (!has_undefined(set->d[i])) all_undef = false;
    if (!has_null(set->d[i])) all_null = false;
  }
  if (all_undef || all_null) {
    V m = all_undef ? V_UNDEFINED : V_NULL;
    V *ts = gc_alloc((size_t)set->n * 8);
    for (uint32_t i = 0; i < set->n; i++) ts[i] = without(set->d[i], m);
    return mk_union2(mk_inter(ts, set->n), m);
  }
  if (set->n >= 3 && ninputs > 2) {
    uint32_t mid = set->n / 2;
    V halves[2] = {mk_inter(set->d, mid), mk_inter(set->d + mid, set->n - mid)};
    return mk_inter(halves, 2);
  }
  // the cross product: X & (A | B) is X & A | X & B
  uint64_t count = 1;
  for (uint32_t i = 0; i < set->n; i++)
    if (kind(set->d[i]) == K_UNION) count *= set_n(set->d[i]);
  if (count > 100000) die("expression produces a union type that is too complex to represent");
  VA res;
  va_init(&res);
  V *cons = gc_alloc((size_t)set->n * 8);
  for (uint64_t c = 0; c < count; c++) {
    uint64_t r = c;
    for (int64_t j = (int64_t)set->n - 1; j >= 0; j--) {
      V t = set->d[j];
      if (kind(t) == K_UNION) {
        uint32_t len = set_n(t);
        cons[j] = set_m(t, (uint32_t)(r % len));
        r /= len;
      } else {
        cons[j] = t;
      }
    }
    V t = mk_inter(cons, set->n);
    if (t != V_NEVER) va_push(&res, t);
  }
  return mk_union(res.d, res.n);
}

// getReducedType: an intersection where a property's types are literals
// with an empty intersection (a discriminant that reduces to never) is never
V reduced_type(V t) {
  int k = kind(t);
  if (k == K_UNION) {
    SetT *u = (SetT *)t;
    bool any = false;
    for (uint32_t i = 0; i < u->n && !any; i++) any = kind(u->m[i]) == K_INTER;
    if (!any) return t;
    V *r = gc_alloc((size_t)u->n * 8);
    bool changed = false;
    for (uint32_t i = 0; i < u->n; i++) {
      r[i] = reduced_type(u->m[i]);
      if (r[i] != u->m[i]) changed = true;
    }
    return changed ? mk_union(r, u->n) : t;
  }
  if (k != K_INTER) return t;
  SetT *s = (SetT *)t;
  // properties declared in more than one constituent
  VA names;
  va_init(&names);
  for (uint32_t i = 0; i < s->n; i++) {
    Members m;
    members_of(s->m[i], &m);
    for (uint32_t j = 0; j < m.np; j++) {
      Str *nm = m.p[j].name;
      if (!nm) continue;
      bool again = false;
      for (uint32_t q = 0; q < names.n && !again; q++) again = str_eq((Str *)names.d[q], nm);
      if (again) continue;
      // in a later constituent too?
      bool later = false;
      for (uint32_t q = i + 1; q < s->n && !later; q++) {
        PInfo p;
        later = member_prop(s->m[q], nm, &p);
      }
      if (!later) continue;
      va_push(&names, (V)nm);
      // isDiscriminantWithNeverType: not optional, non-uniform with a
      // literal type and no never, intersected to never
      VA tys;
      va_init(&tys);
      bool opt = true, literal = false, nevr = false, nonuniform = false;
      for (uint32_t q = 0; q < s->n; q++) {
        PInfo p;
        if (!member_prop(s->m[q], nm, &p)) continue;
        if (tys.n && !ty_eq(tys.d[0], p.ty)) nonuniform = true;
        va_push(&tys, p.ty);
        opt = opt && p.opt;
        if (is_literal_type(p.ty) || is_pattern_literal(p.ty)) literal = true;
        if (p.ty == V_NEVER) nevr = true;
      }
      if (!opt && nonuniform && literal && !nevr && mk_inter(tys.d, tys.n) == V_NEVER) return V_NEVER;
    }
  }
  return t;
}

V merge_objects(ObjT **objs, uint32_t n) {
  OB b;
  ob_init(&b);
  for (uint32_t k = 0; k < n; k++) {
    ObjT *o = objs[k];
    for (uint32_t i = 0; i < o->np; i++) {
      Prop *p = &o->props[i];
      int32_t j = ob_find(&b, p->name);
      if (j >= 0) {
        Prop *prev = &b.p[j];
        V it[2] = {prop_value(prev), prop_value(p)};
        V t = mk_inter(it, 2);
        prev->ty = t;
        prev->th = NULL;
        prev->env = NULL;
        prev->opt = prev->opt && p->opt;
        prev->ro = prev->ro && p->ro;
      } else {
        if (b.n == b.cap) {
          uint32_t nc = b.cap ? b.cap * 2 : 8;
          Prop *np = gc_alloc((size_t)nc * sizeof(Prop));
          if (b.n) memcpy(np, b.p, (size_t)b.n * sizeof(Prop));
          b.p = np;
          b.cap = nc;
        }
        b.p[b.n++] = *p;
      }
    }
    for (uint32_t i = 0; i < o->ni; i++) ob_index(&b, o->index[i].key, o->index[i].ty, o->index[i].ro);
    for (uint32_t i = 0; i < o->nc; i++) ob_call(&b, o->calls[i]);
  }
  return ob_finish(&b);
}
