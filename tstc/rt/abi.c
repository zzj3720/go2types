// Entry points of generated code into the runtime (see src/main/gen.mbt).
#include "desc.h"

#include <stdio.h>
#include <stdlib.h>

V rt_union(const V *v, int64_t n) { return mk_union(v, (uint32_t)n); }
V rt_inter(const V *v, int64_t n) { return mk_inter(v, (uint32_t)n); }
V rt_inter_node(const V *v, int64_t n) { return mk_inter_node(v, (uint32_t)n); }
V rt_union2(V a, V b) { return mk_union2(a, b); }
V rt_tuplev(const V *v, int64_t n) { return mk_tuple(v, (uint32_t)n); }
V rt_tuple2(V a, V b) { return mk_tuple2(a, b); }
V rt_tuple1(V a) { return mk_tuple1(a); }
// a tuple of n required elements (as written: no descriptor)
V rt_tuplen(const V *e, int64_t n) { return mk_tuple(e, (uint32_t)n); }
V rt_empty_tuple(void) { return empty_tuple; }
V rt_tupled(const TupD *d, V *vals) { return rt_tuple(d, vals); }
V rt_array(V el, int64_t ro) { return mk_array(el, ro != 0); }
V rt_index(V o, V k) { return index_access(o, k); }
V rt_keyof(V t) { return keyof_ty(t); }
V rt_tpl(Str **texts, const V *vals, int64_t n) { return eval_tpl(texts, vals, (uint32_t)n); }
V rt_fnty(const FnD *d, const V *tys, V ret) { return rt_fn(d, tys, ret); }
bool rt_tup_fastok(TupExt *x) { return !x->kinds && !x->ro; }

// the elements of t when it is a plain tuple of n elements (as the prelude's
// tstc_tuplen tests), else NULL
V *rt_tuple_elems(V t, int64_t n) {
  if (t & 3) return NULL;
  TupT *p = (TupT *)t;
  if (p->tag != K_TUPLE || p->len != (uint32_t)n) return NULL;
  if (p->x && !rt_tup_fastok(p->x)) return NULL;
  return p->e;
}

// the elements of the pair (a, b) when it is the value a (b 0), a plain tuple
// of n elements, else NULL
V *rt_pair_elems(V a, V b, int64_t n) { return b ? NULL : rt_tuple_elems(a, n); }

// the elements of the pair (a, b) when it is the value a (b 0), a plain tuple
// of 2 elements, else (0, 0)
VPair rt_pair_elems2(V a, V b) {
  V *e = b ? NULL : rt_tuple_elems(a, 2);
  return e ? (VPair){e[0], e[1]} : (VPair){0, 0};
}

// a tuple from a static template with k elements replaced: pairs of
// (index, value)
V rt_tuple_patch(TupT *tpl, const V *pairs, int64_t k) {
  TupT *t = tup_alloc(tpl->len);
  memcpy(t->e, tpl->e, (size_t)tpl->len * 8);
  for (int64_t i = 0; i < k; i++) t->e[pairs[2 * i]] = pairs[2 * i + 1];
  return (V)t;
}

// `${K}` as the key of a dispatch table: an integer or string literal stands
// for its text (rt_dispatch finds the property an integer's text names, with
// no text made); anything else is the template's value
V rt_tpl_key(V k) {
  if (kind(k) == K_INT || kind(k) == K_STRLIT) return k;
  static Str *texts[2];
  if (!texts[0]) texts[0] = texts[1] = str_of_cstr("");
  return eval_tpl(texts, &k, 1);
}

// `{ ... }[K]`: the index of the property K names (the last of that name),
// -1 when there is none, -2 when K names no property
typedef struct {
  int64_t n;
  Str **names;
  int64_t hcap;
  int32_t *hidx;
  int64_t icap;     // integer keys: the names that are integers' text
  int64_t *ikeys;
  int32_t *iidx;
} DispatchD;

// the integer a name is the canonical text of
static bool name_int(Str *s, int64_t *out) {
  const uint16_t *d = str_d(s);
  int32_t n = s->len, i = 0;
  bool neg = n > 0 && d[0] == '-';
  if (neg) i = 1;
  if (i >= n || n - i > 18) return false;
  if (d[i] == '0' && (n - i > 1 || neg)) return false;
  int64_t v = 0;
  for (; i < n; i++) {
    if (d[i] < '0' || d[i] > '9') return false;
    v = v * 10 + (d[i] - '0');
  }
  *out = neg ? -v : v;
  return true;
}

// an integer key: no text made for it
static int64_t dispatch_int(int64_t key, DispatchD *d) {
  if (!d->iidx) {
    int64_t cap = 16;
    while (cap < d->n * 2) cap *= 2;
    int64_t *ks = malloc((size_t)cap * 8);
    int32_t *ix = malloc((size_t)cap * 4);
    memset(ix, 0xFF, (size_t)cap * 4);
    for (int64_t i = 0; i < d->n; i++) {
      int64_t v;
      if (!name_int(d->names[i], &v)) continue;
      uint32_t j = (uint32_t)((uint64_t)v * 0x9E3779B97F4A7C15ull >> 32) & (uint32_t)(cap - 1);
      while (ix[j] >= 0 && ks[j] != v) j = (j + 1) & (uint32_t)(cap - 1);
      ks[j] = v;
      ix[j] = (int32_t)i;  // the last of the name
    }
    d->icap = cap;
    d->ikeys = ks;
    d->iidx = ix;
  }
  uint32_t j = (uint32_t)((uint64_t)key * 0x9E3779B97F4A7C15ull >> 32) & (uint32_t)(d->icap - 1);
  while (d->iidx[j] >= 0) {
    if (d->ikeys[j] == key) return d->iidx[j];
    j = (j + 1) & (uint32_t)(d->icap - 1);
  }
  return -1;
}

int64_t rt_dispatch(V k, DispatchD *d) {
  if (kind(k) == K_INT) {
    // (names of up to 18 digits are indexed)
    int64_t v = int_val(k);
    if (v > -INT64_C(100000000000000000) && v < INT64_C(100000000000000000)) return dispatch_int(v, d);
  }
  Str *name;
  if (!key_name(k, &name)) return -2;
  if (d->n <= 8) {
    for (int64_t i = d->n - 1; i >= 0; i--)
      if (str_eq(d->names[i], name)) return i;
    return -1;
  }
  if (!d->hidx) {
    int64_t cap = 16;
    while (cap < d->n * 2) cap *= 2;
    int32_t *h = malloc((size_t)cap * 4);
    memset(h, 0xFF, (size_t)cap * 4);
    for (int64_t i = 0; i < d->n; i++) {
      uint32_t j = str_hash(d->names[i]) & (uint32_t)(cap - 1);
      while (h[j] >= 0 && !str_eq(d->names[h[j]], d->names[i])) j = (j + 1) & (uint32_t)(cap - 1);
      h[j] = (int32_t)i;
    }
    d->hcap = cap;
    d->hidx = h;
  }
  uint32_t j = str_hash(name) & (uint32_t)(d->hcap - 1);
  while (d->hidx[j] >= 0) {
    if (str_eq(d->names[d->hidx[j]], name)) return d->hidx[j];
    j = (j + 1) & (uint32_t)(d->hcap - 1);
  }
  return -1;
}

// ---------------------------------------------------------------------------
// TypeScript's intrinsic string types

static V map_case(V t, int mode) { return string_mapping(mode, t); }

V n_uppercase(V s) { return map_case(s, 0); }
V n_lowercase(V s) { return map_case(s, 1); }
V n_capitalize(V s) { return map_case(s, 2); }
V n_uncapitalize(V s) { return map_case(s, 3); }

// substitution types (src/main/subst.mbt): the type written in a true branch
// is the check type: a substitution type constrained by the extends type
// (written: the type before the sites around it; node differs when they
// made a substitution type of it, whose constraint this site's adds to;
// otherwise a substitution type is substituted again, getActualTypeVariable
// comparing its base)
V n_subst(V node, V check, V ext, V written) {
  bool m = kind(node) == K_SUBST && node != written && !ty_eq(node, written);
  V base = m ? ((SubstT *)node)->base : node;
  V av = node, cb = check;
  while (kind(av) == K_SUBST) av = ((SubstT *)av)->base;
  while (kind(cb) == K_SUBST) cb = ((SubstT *)cb)->base;
  // (the same type: `{}` is one type, other object types are their own)
  if (!(av == cb || ty_eq(av, cb) || (is_empty_anon_obj(av) && is_empty_anon_obj(cb)))) return node;
  if (!m) return mk_subst(node, ext);
  V cons = ext;
  if (m) {
    V it[2] = {((SubstT *)node)->cons, ext};
    cons = mk_inter(it, 2);
  }
  return mk_subst(base, cons);
}

V n_strip(V t) { return subst_strip(t); }

// an interface's type: its bases' members and its own (which replace them)
// in one object type, an interface's (no anonymous type)
V n_iface(V t) {
  ObjT *parts[64];
  uint32_t n = 0;
  if (kind(t) == K_OBJ) {
    parts[n++] = as_obj(t);
  } else if (kind(t) == K_INTER && set_n(t) <= 64) {
    for (uint32_t i = 0; i < set_n(t); i++) {
      if (kind(set_m(t, i)) != K_OBJ) return t;
      parts[n++] = as_obj(set_m(t, i));
    }
  } else {
    return t;
  }
  OB b;
  ob_init(&b);
  for (uint32_t k = 0; k < n; k++) {
    ObjT *o = parts[k];
    for (uint32_t i = 0; i < o->np; i++) {
      Prop *p = &o->props[i];
      ob_prop_x(&b, p->name, p->ty, p->th, p->env, p->opt, p->ro, p->numeric, false, p->ty ? PROP_AS_IS : p->post);
    }
    for (uint32_t i = 0; i < o->ni; i++) ob_index(&b, o->index[i].key, o->index[i].ty, o->index[i].ro);
    for (uint32_t i = 0; i < o->nc; i++) ob_call(&b, o->calls[i]);
  }
  V r = ob_finish(&b);
  as_obj(r)->aux |= OBJ_IFACE;
  return r;
}

// --check-shapes: a conditional compiled inline checks a value its shape
// analysis took to be simple (not any, a union or a marker)
void rt_shape_check(V v, int64_t id) {
  int k = kind(v);
  if (v == V_ANY || k == K_UNION || (k == K_USYM && ((USymT *)v)->id < 0)) {
    fprintf(stderr, "tstc: --check-shapes: conditional %lld checks a value of kind %d\n", (long long)id, k);
    exit(70);
  }
}
