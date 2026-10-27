// Relations between types as TypeScript's checker computes them (tsgo,
// internal/checker/relater.go): assignability, the strict subtype relation
// (of union subtype reduction) and identity, for the types tstc has. The
// structure follows the checker's functions (named in the comments) so that
// the two can be compared rule by rule.
#include "tstc.h"

#include <math.h>
#include <stdlib.h>

enum { R_ASSIGN, R_STRICT, R_IDENT };
enum { IS_NONE = 0, IS_SOURCE = 1, IS_TARGET = 2 };

static bool related(V s, V t, int R, int ist);
static bool tuple_elems_related(TupT *s, V el, int R);
static bool tpl_matched(V s, TplT *t, int R);
static bool member_of_strmap(V s, V t);
static bool sigs_related(V s, V t, bool ctor, int R, int ist);
static bool excluded_name(VA *ex, Str *n);
static bool discriminated_related(V s, V t, int R);
static bool generic_fn_related(GenFnT *a, GenFnT *b, int R);

// ---------------------------------------------------------------------------
// Flags

uint32_t ty_flags(V t) {
  switch (kind(t)) {
  case K_ANY: return TF_ANY;
  case K_UNKNOWN: return TF_UNKNOWN;
  case K_NEVER: return TF_NEVER;
  case K_STRING: return TF_STRING;
  case K_NUMBER: return TF_NUMBER;
  case K_BIGINT: return TF_BIGINT;
  case K_SYMBOL: return TF_ESSYMBOL;
  case K_OBJECTKW: return TF_NONPRIM;
  case K_NULL: return TF_NULL;
  case K_UNDEFINED: return TF_UNDEFINED;
  case K_VOID: return TF_VOID;
  case K_TRUE: case K_FALSE: return TF_BOOLLIT;
  case K_STRLIT: return TF_STRLIT;
  case K_NUMLIT: return TF_NUMLIT;
  case K_BIGLIT: case K_INT: return TF_BIGLIT;
  case K_TPL: return TF_TPL;
  case K_STRMAP: return TF_STRMAP;
  case K_UNION: {
    SetT *u = (SetT *)t;
    if (u->n == 2 && kind(u->m[0]) >= K_TRUE && kind(u->m[0]) <= K_FALSE && kind(u->m[1]) >= K_TRUE &&
        kind(u->m[1]) <= K_FALSE)
      return TF_UNION | TF_BOOLEAN;
    return TF_UNION;
  }
  case K_INTER: return TF_INTER;
  case K_USYM: return ((USymT *)t)->id < 0 ? TF_TPARAM : TF_USYM;
  case K_DEFERRED: return TF_COND;
  case K_SUBST: return TF_SUBST;
  default: return TF_OBJECT;
  }
}

// the same type (the checker interns these: literals, tuples, arrays,
// templates, mappings, unions, intersections; objects are distinct)
static inline bool same(V a, V b) { return a == b || ty_eq(a, b); }

// the same type when that is cheap to see (scalars); composite types are
// compared by their structure anyway
static inline bool same_scalar(V a, V b) {
  if (a == b) return true;
  if ((a | b) & 3) return false;
  int k = kind(a);
  if (k != kind(b)) return false;
  switch (k) {
  case K_STRLIT: case K_NUMLIT: case K_BIGLIT: case K_INT: case K_USYM: case K_TPL: case K_STRMAP:
    return ty_eq(a, b);
  default: return false;
  }
}

static bool is_empty_obj(V t) {
  if (kind(t) != K_OBJ) return false;
  ObjT *o = as_obj(t);
  return o->np == 0 && o->ni == 0 && o->nc == 0;
}

// IsEmptyAnonymousObjectType
bool is_empty_anon_obj(V t) { return is_empty_obj(t) && !(as_obj(t)->aux & (OBJ_MAPPED | OBJ_IFACE)); }

static bool union_has(V u, V t) {
  if (kind(u) != K_UNION) return same(u, t);
  return set_has(u, t);
}

// isUnknownLikeUnionType: undefined | null | {} (and more)
static bool unknown_like_union(V t) {
  if (kind(t) != K_UNION || set_n(t) < 3) return false;
  bool u = false, n = false, e = false;
  for (uint32_t i = 0; i < set_n(t); i++) {
    V m = set_m(t, i);
    if (m == V_UNDEFINED) u = true;
    else if (m == V_NULL) n = true;
    else if (is_empty_anon_obj(m)) e = true;
  }
  return u && n && e;
}

// ---------------------------------------------------------------------------
// isSimpleTypeRelatedTo

static bool simple(V s, V t, uint32_t sf, uint32_t tf, int R) {
  if ((tf & TF_ANY) || (sf & TF_NEVER)) return true;
  if ((tf & TF_UNKNOWN) && !(R == R_STRICT && (sf & TF_ANY))) return true;
  if (tf & TF_NEVER) return false;
  if ((sf & TF_STRINGLIKE) && (tf & TF_STRING)) return true;
  if ((sf & TF_NUMBERLIKE) && (tf & TF_NUMBER)) return true;
  if ((sf & TF_BIGINTLIKE) && (tf & TF_BIGINT)) return true;
  if ((sf & TF_BOOLEANLIKE) && (tf & TF_BOOLEAN)) return true;
  if ((sf & TF_SYMBOLLIKE) && (tf & TF_ESSYMBOL)) return true;
  if ((sf & TF_UNDEFINED) && (tf & (TF_UNDEFINED | TF_VOID))) return true;
  if ((sf & TF_NULL) && (tf & TF_NULL)) return true;
  if ((sf & TF_OBJECT) && (tf & TF_NONPRIM) && !(R == R_STRICT && is_empty_anon_obj(s))) return true;
  if (R == R_ASSIGN) {
    if (sf & TF_ANY) return true;
    if (unknown_like_union(t)) return true;
  }
  return false;
}

// ---------------------------------------------------------------------------
// Members of apparent types

V opt_type(V t) {
  switch (kind(t)) {
  case K_UNDEFINED: case K_ANY: case K_UNKNOWN: return t;
  case K_UNION:
    for (uint32_t i = 0; i < set_n(t); i++)
      if (set_m(t, i) == V_UNDEFINED) return t;
    break;
  default: break;
  }
  return mk_union2(t, V_UNDEFINED);
}

// the number index type of an array or tuple (the T of Array<T>)
V tuple_elem_union(TupT *t);
static V num_index_of(V t) {
  switch (kind(t)) {
  case K_ARRAY: return ((ArrT *)t)->el;
  case K_TUPLE: return tuple_elem_union(as_tup(t));
  default: return 0;
  }
}

typedef struct { PInfo *d; uint32_t n, cap; } PV;
static void pv_push(PV *v, PInfo p) {
  if (v->n == v->cap) {
    uint32_t nc = v->cap ? v->cap * 2 : 16;
    PInfo *d = gc_alloc((size_t)nc * sizeof(PInfo));
    if (v->n) memcpy(d, v->d, (size_t)v->n * sizeof(PInfo));
    v->d = d;
    v->cap = nc;
  }
  v->d[v->n++] = p;
}

// the members' names, made once
static Str **lib_names(int app) {
  static Str **names[APP_EMPTY + 1];
  if (!names[app]) {
    int n;
    const LibMember *ms = lib_members(app, &n);
    Str **a = malloc((size_t)(n ? n : 1) * sizeof(Str *));
    for (int i = 0; i < n; i++) {
      a[i] = ms[i].name ? str_of_cstr(ms[i].name) : NULL;
      if (a[i]) gc_add_root(&a[i], sizeof(Str *));
    }
    names[app] = a;
  }
  return names[app];
}

static void lib_props(int app, V base, PV *out, bool skip_length) {
  int n;
  const LibMember *ms = lib_members(app, &n);
  Str **names = lib_names(app);
  for (int i = 0; i < n; i++) {
    const LibMember *m = &ms[i];
    if (skip_length && m->name && strcmp(m->name, "length") == 0) continue;
    PInfo p;
    memset(&p, 0, sizeof p);
    p.name = names[i];
    p.sym = m->name ? 0 : WK_SYM_BASE + m->sym;
    p.ty = lib_member_type(app, base, m, names[i]);
    p.ro = m->ro;
    pv_push(out, p);
  }
}

// the member of lib_props(app, base, ., skip_length) named name (wk >= 0:
// the well-known symbol wk), without making the others
static bool lib_prop(int app, V base, Str *name, int wk, bool skip_length, PInfo *out) {
  if (app == APP_NONE || app == APP_EMPTY) return false;
  int n;
  const LibMember *ms = lib_members(app, &n);
  Str **names = lib_names(app);
  for (int i = 0; i < n; i++) {
    const LibMember *m = &ms[i];
    if (wk >= 0 ? (m->name || m->sym != wk) : (!m->name || !str_eq(names[i], name))) continue;
    if (skip_length && m->name && strcmp(m->name, "length") == 0) continue;
    memset(out, 0, sizeof *out);
    out->name = name;
    out->sym = m->name ? 0 : WK_SYM_BASE + m->sym;
    out->ty = lib_member_type(app, base, m, names[i]);
    out->ro = m->ro;
    return true;
  }
  return false;
}

// "0", "1", ... (and "length" for -1), made once for small indexes
static Str *index_name(int64_t i) {
  static Str *names[257];
  static bool rooted;
  if (i >= 256) return str_of_int(i);
  if (!rooted) {
    gc_add_root(names, sizeof names);
    rooted = true;
  }
  Str **slot = &names[i + 1];
  if (!*slot) *slot = i < 0 ? str_of_cstr("length") : str_of_int(i);
  return *slot;
}

// the tuple's own properties: elements before a rest element, length
static void tuple_props(TupT *t, PV *out) {
  bool ro = tup_ro(t);
  uint32_t req = 0;
  bool rest = false;
  for (uint32_t i = 0; i < t->len; i++) {
    int k = tup_kind(t, i);
    if (k == E_REST) rest = true;
    if (k == E_REQ) req++;
    if (!rest) {
      PInfo p;
      memset(&p, 0, sizeof p);
      p.name = index_name(i);
      p.opt = k == E_OPT;
      p.ty = p.opt ? opt_type(t->e[i]) : t->e[i];
      p.ro = ro;
      pv_push(out, p);
    }
  }
  PInfo l;
  memset(&l, 0, sizeof l);
  l.name = index_name(-1);
  l.ro = ro;
  if (rest) {
    l.ty = V_NUMBER;
  } else if (req == t->len) {
    l.ty = mk_num(t->len);
  } else {
    V *ls = gc_alloc((size_t)(t->len - req + 1) * 8);
    for (uint32_t i = req; i <= t->len; i++) ls[i - req] = mk_num(i);
    l.ty = mk_union(ls, t->len - req + 1);
  }
  pv_push(out, l);
}

static void index_push(IndexSig **ix, uint32_t *n, uint32_t *cap, V key, V ty, bool ro) {
  for (uint32_t i = 0; i < *n; i++)
    if (same((*ix)[i].key, key)) {
      // (an intersection: the value types intersected)
      V it[2] = {(*ix)[i].ty, ty};
      (*ix)[i].ty = mk_inter(it, 2);
      (*ix)[i].ro = (*ix)[i].ro && ro;
      return;
    }
  if (*n == *cap) {
    uint32_t nc = *cap ? *cap * 2 : 4;
    IndexSig *d = gc_alloc((size_t)nc * sizeof(IndexSig));
    if (*n) memcpy(d, *ix, (size_t)*n * sizeof(IndexSig));
    *ix = d;
    *cap = nc;
  }
  (*ix)[*n].key = key;
  (*ix)[*n].ty = ty;
  (*ix)[*n].ro = ro;
  (*n)++;
}

static void sig_push(V **d, uint32_t *n, uint32_t *cap, V f) {
  if (*n == *cap) {
    uint32_t nc = *cap ? *cap * 2 : 4;
    V *x = gc_alloc((size_t)nc * 8);
    if (*n) memcpy(x, *d, (size_t)*n * 8);
    *d = x;
    *cap = nc;
  }
  (*d)[(*n)++] = f;
}

static void members_of_self(V t, V self, Members *m);
static bool member_prop_self(V t, V self, Str *name, PInfo *out);

// a property of an object type as its members show it
static void obj_pinfo(Prop *pp, PInfo *p) {
  memset(p, 0, sizeof *p);
  p->name = pp->name;
  int wk = wk_of_prop_name(pp->name);
  if (wk >= 0) {
    p->name = NULL;
    p->sym = WK_SYM_BASE + wk;
  }
  p->opt = pp->opt;
  V v = prop_value(pp);
  p->ty = p->opt ? opt_type(v) : v;
  p->ro = pp->ro;
  p->numeric = pp->numeric;
}

// the members of t's apparent type; self is the `this` type (an
// intersection's members see the intersection)
static void members_into(V t, V self, PV *props, Members *m, uint32_t *icap, uint32_t *ccap, uint32_t *tcap) {
  int k = kind(t);
  switch (k) {
  case K_OBJ: {
    ObjT *o = as_obj(t);
    for (uint32_t i = 0; i < o->np; i++) {
      PInfo p;
      obj_pinfo(&o->props[i], &p);
      pv_push(props, p);
    }
    for (uint32_t i = 0; i < o->ni; i++) index_push(&m->ix, &m->ni, icap, o->index[i].key, o->index[i].ty, o->index[i].ro);
    for (uint32_t i = 0; i < o->nc; i++) {
      if (o->calls[i]->ctor) sig_push(&m->ctors, &m->nct, tcap, (V)o->calls[i]);
      else sig_push(&m->calls, &m->nc, ccap, (V)o->calls[i]);
    }
    return;
  }
  case K_FN:
    if (((FnT *)t)->ctor) sig_push(&m->ctors, &m->nct, tcap, t);
    else sig_push(&m->calls, &m->nc, ccap, t);
    return;
  case K_GENFN:
  case K_LIBM:
    sig_push(&m->calls, &m->nc, ccap, t);
    return;
  case K_TUPLE: {
    TupT *tp = as_tup(t);
    tuple_props(tp, props);
    lib_props(tup_ro(tp) ? APP_RO_ARRAY : APP_ARRAY, self, props, true);
    index_push(&m->ix, &m->ni, icap, V_NUMBER, tuple_elem_union(tp), tup_ro(tp));
    return;
  }
  case K_ARRAY: {
    ArrT *a = (ArrT *)t;
    lib_props(a->ro ? APP_RO_ARRAY : APP_ARRAY, self, props, false);
    index_push(&m->ix, &m->ni, icap, V_NUMBER, a->el, a->ro);
    return;
  }
  case K_INTER: {
    // getPropertiesOfUnionOrIntersectionType: each name once, combined
    SetT *u = (SetT *)t;
    for (uint32_t i = 0; i < u->n; i++) {
      Members sub;
      members_of_self(u->m[i], self, &sub);
      for (uint32_t j = 0; j < sub.np; j++) {
        PInfo *p = &sub.p[j];
        bool seen = false;
        for (uint32_t q = 0; q < props->n && !seen; q++)
          seen = p->name ? (props->d[q].name && str_eq(props->d[q].name, p->name)) : props->d[q].sym == p->sym;
        if (seen) continue;
        PInfo c;
        if (p->name && member_prop_self(t, self, p->name, &c)) pv_push(props, c);
        else if (!p->name) pv_push(props, *p);
      }
      for (uint32_t j = 0; j < sub.ni; j++) index_push(&m->ix, &m->ni, icap, sub.ix[j].key, sub.ix[j].ty, sub.ix[j].ro);
      for (uint32_t j = 0; j < sub.nc; j++) sig_push(&m->calls, &m->nc, ccap, sub.calls[j]);
      for (uint32_t j = 0; j < sub.nct; j++) sig_push(&m->ctors, &m->nct, tcap, sub.ctors[j]);
    }
    return;
  }
  case K_SUBST:
    members_into(((SubstT *)t)->base, self, props, m, icap, ccap, tcap);
    return;
  default: {
    int app = apparent_of(t);
    if (app == APP_NONE || app == APP_EMPTY) return;
    lib_props(app, self, props, false);
    if (app == APP_STRING) index_push(&m->ix, &m->ni, icap, V_NUMBER, V_STRING, true);
    return;
  }
  }
}

static void members_of_self(V t, V self, Members *m) {
  memset(m, 0, sizeof *m);
  PV props = {0};
  uint32_t icap = 0, ccap = 0, tcap = 0;
  members_into(t, self, &props, m, &icap, &ccap, &tcap);
  m->p = props.d;
  m->np = props.n;
}

void members_of(V t, Members *m) { members_of_self(t, t, m); }

// whether one of the members of t (members_of) that is required and named
// is not in(ctx, name): for arrays, tuples and primitives from the names
// alone, without making the members' types
bool required_member_not_in(V t, bool (*in)(const void *ctx, Str *name), const void *ctx) {
  int k = kind(t);
  if (k == K_TUPLE || k == K_ARRAY || (k != K_OBJ && k != K_FN && k != K_GENFN && k != K_LIBM && k != K_INTER && k != K_SUBST)) {
    bool skip_length = false;
    if (k == K_TUPLE) {
      TupT *tp = as_tup(t);
      for (uint32_t i = 0; i < tp->len; i++) {
        int ek = tup_kind(tp, i);
        if (ek == E_REST) break;
        if (ek != E_OPT && !in(ctx, index_name(i))) return true;
      }
      if (!in(ctx, index_name(-1))) return true;
      skip_length = true;
    }
    int app = apparent_of(t);
    if (app == APP_NONE || app == APP_EMPTY) return false;
    int n;
    const LibMember *ms = lib_members(app, &n);
    Str **names = lib_names(app);
    for (int i = 0; i < n; i++) {
      if (!ms[i].name) continue;
      if (skip_length && strcmp(ms[i].name, "length") == 0) continue;
      if (!in(ctx, names[i])) return true;
    }
    return false;
  }
  Members m;
  members_of(t, &m);
  for (uint32_t i = 0; i < m.np; i++) {
    if (m.p[i].opt || !m.p[i].name) continue;
    if (!in(ctx, m.p[i].name)) return true;
  }
  return false;
}

// getPropertyOfType (no augmentation with Object's and Function's members)
bool member_prop(V t, Str *name, PInfo *out) { return member_prop_self(t, t, name, out); }

static bool member_prop_self(V t, V self, Str *name, PInfo *out) {
  memset(out, 0, sizeof *out);
  switch (kind(t)) {
  case K_OBJ: {
    Prop *pp = obj_get(as_obj(t), name);
    if (!pp) return false;
    out->name = pp->name;
    out->opt = pp->opt;
    V v = prop_value(pp);
    out->ty = out->opt ? opt_type(v) : v;
    out->ro = pp->ro;
    out->numeric = pp->numeric;
    return true;
  }
  case K_INTER: {
    // createUnionOrIntersectionProperty for an intersection
    SetT *u = (SetT *)t;
    VA tys;
    va_init(&tys);
    bool opt = true, ro = true, numeric = false;
    for (uint32_t i = 0; i < u->n; i++) {
      PInfo p;
      if (kind(u->m[i]) == K_NEVER || !member_prop_self(u->m[i], self, name, &p)) continue;
      va_push(&tys, p.ty);
      opt = opt && p.opt;
      ro = ro && p.ro;
      numeric = numeric || p.numeric;
    }
    if (!tys.n) return false;
    out->name = name;
    out->ty = tys.n == 1 ? tys.d[0] : mk_inter(tys.d, tys.n);
    out->opt = opt;
    out->ro = ro;
    out->numeric = numeric;
    return true;
  }
  case K_FN: case K_GENFN: case K_LIBM: case K_UNION: case K_DEFERRED:
    return false;
  default: {
    if (kind(t) == K_TUPLE) {
      // the elements directly
      TupT *tp = as_tup(t);
      double d;
      if (parse_canonical_number(name, &d) && d >= 0 && d == floor(d) && d < tp->len) {
        uint32_t i = (uint32_t)d;
        for (uint32_t j = 0; j <= i; j++)
          if (tup_kind(tp, j) == E_REST) return false;
        out->name = name;
        out->opt = tup_kind(tp, i) == E_OPT;
        out->ty = out->opt ? opt_type(tp->e[i]) : tp->e[i];
        out->ro = tup_ro(tp);
        return true;
      }
    }
    int wk = wk_of_prop_name(name);
    // (an array, a tuple or a primitive: its own properties, then its
    // interface's, found without making all of them)
    int k = kind(t);
    if (k == K_TUPLE) {
      // (of its own properties only length is left: the elements are above)
      if (wk < 0 && str_eq(name, index_name(-1))) {
        PV own = {0};
        tuple_props(as_tup(t), &own);
        *out = own.d[own.n - 1];
        out->name = name;
        return true;
      }
      return lib_prop(apparent_of(t), self, name, wk, true, out);
    }
    if (k != K_SUBST) return lib_prop(apparent_of(t), self, name, wk, false, out);
    Members m;
    members_of_self(t, self, &m);
    for (uint32_t i = 0; i < m.np; i++)
      if (wk >= 0 ? (!m.p[i].name && m.p[i].sym == WK_SYM_BASE + wk) : (m.p[i].name && str_eq(m.p[i].name, name))) {
        *out = m.p[i];
        out->name = name;
        return true;
      }
    return false;
  }
  }
}

// ---------------------------------------------------------------------------
// Index signatures

static bool is_numeric_name(Str *s) {
  double d;
  return parse_canonical_number(s, &d);
}

// isApplicableIndexType
static bool applicable_index(V source, V target) {
  if (is_assignable(source, target)) return true;
  if (target == V_STRING && is_assignable(source, V_NUMBER)) return true;
  if (target == V_NUMBER && kind(source) == K_STRLIT && is_numeric_name(as_str(source))) return true;
  return false;
}

// getApplicableIndexInfo
static IndexSig *applicable_info(Members *m, V key) {
  IndexSig *str = NULL, *app = NULL;
  for (uint32_t i = 0; i < m->ni; i++) {
    IndexSig *ix = &m->ix[i];
    if (ix->key == V_STRING) str = ix;
    else if (!app && applicable_index(key, ix->key)) app = ix;
  }
  if (app) return app;
  if (str && applicable_index(key, V_STRING)) return str;
  return NULL;
}

// isObjectTypeWithInferableIndex: object type literals (and mapped types)
// without signatures, intersections of them
static bool inferable_index(V t) {
  if (kind(t) == K_INTER) {
    for (uint32_t i = 0; i < set_n(t); i++)
      if (!inferable_index(set_m(t, i))) return false;
    return true;
  }
  return kind(t) == K_OBJ && as_obj(t)->nc == 0 && !(as_obj(t)->aux & OBJ_IFACE);
}

static bool index_infos_related(V s, Members *sm, V t, Members *tm, bool src_prim, int R, int ist) {
  bool target_has_string = false;
  for (uint32_t i = 0; i < tm->ni; i++)
    if (tm->ix[i].key == V_STRING) target_has_string = true;
  for (uint32_t i = 0; i < tm->ni; i++) {
    IndexSig *ti = &tm->ix[i];
    if (R != R_STRICT && !src_prim && target_has_string && ti->ty == V_ANY) continue;
    // typeRelatedToIndexInfo
    IndexSig *si = applicable_info(sm, ti->key);
    if (si) {
      if (!related(si->ty, ti->ty, R, ist)) return false;
      continue;
    }
    if (!(ist & IS_SOURCE) && R != R_STRICT && inferable_index(s)) {
      // membersRelatedToIndexInfo
      for (uint32_t j = 0; j < sm->np; j++) {
        PInfo *p = &sm->p[j];
        if (!p->name) continue;
        if (!applicable_index((V)p->name, ti->key)) continue;
        V pt = p->ty;
        if (p->opt && ti->key != V_NUMBER && kind(pt) != K_UNDEFINED) pt = remove_undefined(pt);
        if (!related(pt, ti->ty, R, ist)) return false;
      }
      for (uint32_t j = 0; j < sm->ni; j++)
        if (applicable_index(sm->ix[j].key, ti->key) && !related(sm->ix[j].ty, ti->ty, R, ist)) return false;
      continue;
    }
    return false;
  }
  return true;
}

static bool index_infos_identical(Members *sm, Members *tm) {
  if (sm->ni != tm->ni) return false;
  for (uint32_t i = 0; i < tm->ni; i++) {
    IndexSig *ti = &tm->ix[i], *si = NULL;
    for (uint32_t j = 0; j < sm->ni && !si; j++)
      if (same(sm->ix[j].key, ti->key)) si = &sm->ix[j];
    if (!si || si->ro != ti->ro || !related(si->ty, ti->ty, R_IDENT, IS_NONE)) return false;
  }
  return true;
}

// ---------------------------------------------------------------------------
// Signatures

static bool is_tuple(V t) { return kind(t) == K_TUPLE; }

static bool tuple_has_rest(TupT *t) {
  if (!t->x || !t->x->kinds) return false;
  for (uint32_t i = 0; i < t->len; i++)
    if (t->x->kinds[i] == E_REST) return true;
  return false;
}

// elements before the first rest element
static uint32_t tuple_fixed_len(TupT *t) {
  for (uint32_t i = 0; i < t->len; i++)
    if (tup_kind(t, i) == E_REST) return i;
  return t->len;
}

static bool has_rest_param(FnT *f) { return f->np > 0 && f->params[f->np - 1].rest; }

// getParameterCount
int64_t sig_param_count(FnT *f) {
  int64_t n = f->np;
  if (has_rest_param(f)) {
    V rt = f->params[f->np - 1].ty;
    if (is_tuple(rt)) {
      TupT *t = as_tup(rt);
      return n + tuple_fixed_len(t) - (tuple_has_rest(t) ? 0 : 1);
    }
  }
  return n;
}

// hasEffectiveRestParameter
bool sig_has_effective_rest(FnT *f) {
  if (!has_rest_param(f)) return false;
  V rt = f->params[f->np - 1].ty;
  return !is_tuple(rt) || tuple_has_rest(as_tup(rt));
}

// getTypeOfParameter
static V param_type(Param *p) { return p->opt && !p->rest ? opt_type(p->ty) : p->ty; }

// tryGetTypeAtPosition (0: none)
V sig_type_at(FnT *f, int64_t pos) {
  int64_t pc = f->np - (has_rest_param(f) ? 1 : 0);
  if (pos < pc) return param_type(&f->params[pos]);
  if (has_rest_param(f)) {
    V rt = f->params[pc].ty;
    int64_t index = pos - pc;
    if (!is_tuple(rt) || tuple_has_rest(as_tup(rt)) || index < (int64_t)tuple_fixed_len(as_tup(rt)))
      return index_access(rt, mk_num((double)index));
  }
  return 0;
}

// getMinArgumentCount
int64_t sig_min_args(FnT *f) {
  int64_t min = -1;
  if (has_rest_param(f)) {
    V rt = f->params[f->np - 1].ty;
    if (is_tuple(rt)) {
      TupT *t = as_tup(rt);
      int64_t first_opt = -1;
      for (uint32_t i = 0; i < t->len; i++)
        if (tup_kind(t, i) != E_REQ) {
          first_opt = i;
          break;
        }
      int64_t req = first_opt < 0 ? (int64_t)tuple_fixed_len(t) : first_opt;
      if (req > 0) min = f->np - 1 + req;
    }
  }
  if (min < 0) {
    min = 0;
    for (uint32_t i = 0; i < f->np; i++)
      if (!f->params[i].opt && !f->params[i].rest) min = i + 1;
  }
  // trailing parameters that accept void are optional
  for (int64_t i = min - 1; i >= 0; i--) {
    V t = sig_type_at(f, i);
    if (!t) break;
    bool has_void = t == V_VOID;
    if (kind(t) == K_UNION)
      for (uint32_t j = 0; j < set_n(t) && !has_void; j++) has_void = set_m(t, j) == V_VOID;
    if (!has_void) break;
    min = i;
  }
  return min;
}

static V tuple_slice_from(TupT *t, uint32_t index) {
  TB b;
  tb_init(&b);
  for (uint32_t i = index; i < t->len; i++) tb_push(&b, t->e[i], tup_kind(t, i), tup_name(t, i));
  return tb_finish(&b);
}

// getEffectiveRestType (0: none)
V sig_effective_rest(FnT *f) {
  if (!has_rest_param(f)) return 0;
  V rt = f->params[f->np - 1].ty;
  if (!is_tuple(rt)) return rt == V_ANY ? mk_array(V_ANY, false) : rt;
  TupT *t = as_tup(rt);
  if (tuple_has_rest(t)) return tuple_slice_from(t, tuple_fixed_len(t));
  return 0;
}

static V sig_non_array_rest(FnT *f) {
  V r = sig_effective_rest(f);
  if (r && kind(r) != K_ARRAY && r != V_ANY) return r;
  return 0;
}

// getRestTypeAtPosition
V sig_rest_type_at(FnT *f, int64_t pos, bool ro) {
  int64_t pc = sig_param_count(f), min = sig_min_args(f);
  V rest = sig_effective_rest(f);
  if (rest && pos >= pc - 1) {
    if (pos == pc - 1) return rest;
    return mk_array(index_access(rest, V_NUMBER), false);
  }
  TB b;
  tb_init(&b);
  b.ro = ro;
  int64_t len = pc - pos;
  for (int64_t i = 0; i < len; i++) {
    int64_t p = i + pos;
    // the label: the parameter's name, or a rest tuple's element's
    Str *name = NULL;
    int64_t npc = f->np - (has_rest_param(f) ? 1 : 0);
    if (p < npc) {
      name = f->params[p].name;
    } else if (has_rest_param(f)) {
      Param *rp = &f->params[npc];
      if (is_tuple(rp->ty)) {
        int64_t idx = p - npc;
        if (idx < as_tup(rp->ty)->len) name = tup_name(as_tup(rp->ty), (uint32_t)idx);
      } else {
        name = rp->name;
      }
    }
    if (!rest || i < len - 1) {
      V t = sig_type_at(f, p);
      tb_push(&b, t ? t : V_ANY, p < min ? E_REQ : E_OPT, name);
    } else {
      // a variadic element: spread the rest type
      switch (kind(rest)) {
      case K_TUPLE: {
        TupT *rt = as_tup(rest);
        for (uint32_t j = 0; j < rt->len; j++) tb_push(&b, rt->e[j], tup_kind(rt, j), tup_name(rt, j));
        break;
      }
      case K_ARRAY: tb_push(&b, ((ArrT *)rest)->el, E_REST, name); break;
      default: tb_push(&b, rest, E_REST, name);
      }
    }
  }
  return tuple_normalize(&b);
}

static V rest_or_any_at(FnT *f, int64_t pos) {
  V r = sig_rest_type_at(f, pos, false);
  if (r && kind(r) == K_ARRAY && ((ArrT *)r)->el == V_ANY) return V_ANY;
  return r;
}

// isTopSignature: (...args: any) => any / unknown
static bool is_top_sig(FnT *f) {
  if (f->np != 1 || !f->params[0].rest) return false;
  V pt = f->params[0].ty;
  V rt = kind(pt) == K_ARRAY ? ((ArrT *)pt)->el : pt;
  return (rt == V_ANY || rt == V_NEVER) && (f->ret == V_ANY || f->ret == V_UNKNOWN);
}

// getNonNullableType
static V non_nullable(V t) {
  if (kind(t) != K_UNION) return t == V_NULL || t == V_UNDEFINED || t == V_VOID ? V_NEVER : t;
  VA r;
  va_init(&r);
  for (uint32_t i = 0; i < set_n(t); i++) {
    V m = set_m(t, i);
    if (m != V_NULL && m != V_UNDEFINED && m != V_VOID) va_push(&r, m);
  }
  return mk_union(r.d, r.n);
}

// getSingleCallSignature (0: none)
static FnT *single_call_sig(V t) {
  switch (kind(t)) {
  case K_FN: return ((FnT *)t)->ctor ? NULL : (FnT *)t;
  case K_OBJ: {
    ObjT *o = as_obj(t);
    if (o->nc == 1 && o->np == 0 && o->ni == 0 && !o->calls[0]->ctor) return o->calls[0];
    return NULL;
  }
  default: return NULL;
  }
}

static int null_facts(V t) {
  if (t == V_UNDEFINED) return 1;
  if (t == V_NULL) return 2;
  if (kind(t) == K_UNION) {
    int f = 0;
    for (uint32_t i = 0; i < set_n(t); i++) f |= null_facts(set_m(t, i));
    return f;
  }
  return 0;
}

enum { SC_STRICT_CB = 1, SC_BIVARIANT_CB = 2, SC_CALLBACK = 3, SC_STRICT_ARITY = 4, SC_STRICT_TOP = 8 };

// compareSignaturesRelated
static bool fn_related(FnT *s, FnT *t, int mode, int R, int ist) {
  if (s == t) return true;
  if (!((mode & SC_STRICT_TOP) && is_top_sig(s)) && is_top_sig(t)) return true;
  if ((mode & SC_STRICT_TOP) && is_top_sig(s) && !is_top_sig(t)) return false;
  int64_t tc = sig_param_count(t);
  bool more = false;
  if (!sig_has_effective_rest(t)) {
    if (mode & SC_STRICT_ARITY) more = sig_has_effective_rest(s) || sig_param_count(s) > tc;
    else more = sig_min_args(s) > tc;
  }
  if (more) return false;
  int64_t sc = sig_param_count(s);
  V srest = sig_non_array_rest(s), trest = sig_non_array_rest(t);
  bool strict_variance = !(mode & SC_CALLBACK);
  int64_t pc = (srest || trest) ? (sc < tc ? sc : tc) : (sc > tc ? sc : tc);
  int64_t rest_index = (srest || trest) ? pc - 1 : -1;
  for (int64_t i = 0; i < pc; i++) {
    V st = i == rest_index ? rest_or_any_at(s, i) : sig_type_at(s, i);
    V tt = i == rest_index ? rest_or_any_at(t, i) : sig_type_at(t, i);
    if (!st || !tt || (same(st, tt) && !(mode & SC_STRICT_ARITY))) continue;
    FnT *ssig = !(mode & SC_CALLBACK) ? single_call_sig(non_nullable(st)) : NULL;
    FnT *tsig = !(mode & SC_CALLBACK) ? single_call_sig(non_nullable(tt)) : NULL;
    bool callbacks = ssig && tsig && null_facts(st) == null_facts(tt);
    bool rel;
    if (callbacks) {
      rel = fn_related(tsig, ssig, (mode & SC_STRICT_ARITY) | (strict_variance ? SC_STRICT_CB : SC_BIVARIANT_CB), R, ist);
    } else {
      rel = false;
      if (!(mode & SC_CALLBACK) && !strict_variance) rel = related(st, tt, R, ist);
      if (!rel) rel = related(tt, st, R, ist);
    }
    if (rel && (mode & SC_STRICT_ARITY) && i >= sig_min_args(s) && i < sig_min_args(t) && related(st, tt, R, ist))
      rel = false;
    if (!rel) return false;
  }
  V tr = t->ret;
  if (tr == V_VOID || tr == V_ANY) return true;
  bool rel = false;
  if (mode & SC_BIVARIANT_CB) rel = related(tr, s->ret, R, ist);
  if (!rel) rel = related(s->ret, tr, R, ist);
  return rel;
}

// compareSignaturesIdentical
static bool fn_identical(FnT *s, FnT *t) {
  if (s == t) return true;
  if (sig_param_count(s) != sig_param_count(t) || sig_min_args(s) != sig_min_args(t) ||
      sig_has_effective_rest(s) != sig_has_effective_rest(t) || s->ctor != t->ctor)
    return false;
  int64_t n = t->np;
  for (int64_t i = 0; i < n; i++) {
    V a = sig_type_at(s, i), b = sig_type_at(t, i);
    if (!a) a = V_ANY;
    if (!b) b = V_ANY;
    if (!related(b, a, R_IDENT, IS_NONE)) return false;
  }
  return related(s->ret, t->ret, R_IDENT, IS_NONE);
}

static FnT *as_fn(V f) {
  if (kind(f) == K_FN) return (FnT *)f;
  if (kind(f) == K_GENFN) {
    V i = instantiate_generic((GenFnT *)f, NULL, 0);
    return kind(i) == K_FN ? (FnT *)i : NULL;
  }
  return NULL;
}

static bool sig_related(V s, V t, bool erase, int R, int ist) {
  if (s == t) return true;
  int ks = kind(s), kt = kind(t);
  if (ks == K_LIBM || kt == K_LIBM) return ks == kt && ty_identical(s, t);
  if (ks == K_GENFN && kt == K_GENFN) return generic_fn_related((GenFnT *)s, (GenFnT *)t, R);
  FnT *a = as_fn(s), *b = as_fn(t);
  if (!a || !b) return false;
  if (R == R_IDENT) return fn_identical(a, b);
  int mode = R == R_STRICT ? SC_STRICT_TOP | SC_STRICT_ARITY : 0;
  return fn_related(a, b, mode, R, ist);
}

// signaturesRelatedTo
static bool sigs_list_related(V *ss, uint32_t ns, V *ts, uint32_t nt, int R, int ist) {
  if (R == R_IDENT) {
    if (ns != nt) return false;
    for (uint32_t i = 0; i < ns; i++)
      if (!sig_related(ss[i], ts[i], false, R, ist)) return false;
    return true;
  }
  if (ns == 1 && nt == 1) return sig_related(ss[0], ts[0], false, R, ist);
  for (uint32_t i = 0; i < nt; i++) {
    bool ok = false;
    for (uint32_t j = 0; j < ns && !ok; j++) ok = sig_related(ss[j], ts[i], true, R, ist);
    if (!ok) return false;
  }
  return true;
}

static int64_t marker_counter = -1;

static bool generic_fn_related(GenFnT *a, GenFnT *b, int R) {
  if (a->nslots != b->nslots) return false;
  V markers[a->nslots ? a->nslots : 1];
  for (uint32_t i = 0; i < a->nslots; i++) markers[i] = mk_usym(marker_counter--);
  // (as tsgo instantiates the signatures: eq_strip)
  V fa = eq_strip(instantiate_generic(a, markers, a->nslots));
  V fb = eq_strip(instantiate_generic(b, markers, a->nslots));
  return related(fa, fb, R, IS_NONE);
}

// ---------------------------------------------------------------------------
// Properties

static bool is_weak(V t) {
  switch (kind(t)) {
  case K_OBJ: {
    ObjT *o = as_obj(t);
    if (o->nc || o->ni || !o->np) return false;
    for (uint32_t i = 0; i < o->np; i++)
      if (!o->props[i].opt) return false;
    return true;
  }
  case K_INTER:
    for (uint32_t i = 0; i < set_n(t); i++)
      if (!is_weak(set_m(t, i))) return false;
    return true;
  default: return false;
  }
}

// isKnownProperty
static bool known_prop(V t, PInfo *p) {
  if (ty_flags(t) & TF_OBJECT) {
    if (!p->name) {
      Members m;
      members_of(t, &m);
      for (uint32_t i = 0; i < m.ni; i++)
        if (m.ix[i].key == V_STRING) return true;
      return false;
    }
    PInfo q;
    if (member_prop(t, p->name, &q)) return true;
    Members m;
    members_of(t, &m);
    if (applicable_info(&m, (V)p->name)) return true;
    return false;
  }
  if (kind(t) == K_UNION || kind(t) == K_INTER) {
    for (uint32_t i = 0; i < set_n(t); i++)
      if (known_prop(set_m(t, i), p)) return true;
  }
  return false;
}

static bool has_common_props(V s, V t) {
  Members m;
  members_of(s, &m);
  for (uint32_t i = 0; i < m.np; i++)
    if (known_prop(t, &m.p[i])) return true;
  return false;
}

static bool is_array_or_tuple(V t) { return kind(t) == K_ARRAY || kind(t) == K_TUPLE; }

// propertyRelatedTo
static bool prop_related(PInfo *sp, PInfo *tp, int R, int ist) {
  if (R == R_STRICT && sp->ro && !tp->ro) return false;
  V et = tp->ty;
  if (et == V_ANY || (R != R_STRICT && et == V_UNKNOWN)) {
    // (related)
  } else if (!related(sp->ty, et, R, ist)) {
    return false;
  }
  if (sp->opt && !tp->opt) return false;
  return true;
}

static bool numeric_or_length(Str *n) { return is_numeric_name(n) || str_eq_c(n, "length"); }

// the tuple part of propertiesRelatedTo: s an array or tuple, t a tuple
static bool tuple_props_related_ex(V s, TupT *t, int R, int ist, VA *ex);

static bool tuple_props_related(V s, TupT *t, int R, int ist) { return tuple_props_related_ex(s, t, R, ist, NULL); }

static bool tuple_props_related_ex(V s, TupT *t, int R, int ist, VA *ex) {
  bool can_exclude = ex && ex->n;
  bool s_tuple = is_tuple(s);
  TupT *st = s_tuple ? as_tup(s) : NULL;
  bool s_ro = s_tuple ? tup_ro(st) : ((ArrT *)s)->ro;
  if (!tup_ro(t) && s_ro) return false;
  int64_t sarity = s_tuple ? st->len : 1, tarity = t->len;
  bool src_rest = s_tuple ? tuple_has_rest(st) : true;
  bool t_rest = tuple_has_rest(t);
  int64_t smin = 0, tmin = 0;
  if (s_tuple)
    for (uint32_t i = 0; i < st->len; i++) smin += tup_kind(st, i) == E_REQ;
  for (uint32_t i = 0; i < t->len; i++) tmin += tup_kind(t, i) == E_REQ;
  if (!src_rest && sarity < tmin) return false;
  if (!t_rest && tarity < smin) return false;
  if (!t_rest && (src_rest || tarity < sarity)) return false;
  int64_t tstart = 0, tend = 0;
  while (tstart < tarity && tup_kind(t, (uint32_t)tstart) != E_REST) tstart++;
  while (tend < tarity && tup_kind(t, (uint32_t)(tarity - 1 - tend)) != E_REST) tend++;
  for (int64_t sp = 0; sp < sarity; sp++) {
    int sk = s_tuple ? tup_kind(st, (uint32_t)sp) : E_REST;
    V se = s_tuple ? st->e[sp] : ((ArrT *)s)->el;
    int64_t sfe = sarity - 1 - sp;
    int64_t tpos;
    if (t_rest && sp >= tstart) {
      tpos = tarity - 1 - (sfe < tend ? sfe : tend);
    } else {
      if (sp >= tarity) return false;
      tpos = sp;
    }
    int tk = tpos >= 0 ? tup_kind(t, (uint32_t)tpos) : -1;
    if (tk == E_REQ && sk != E_REQ) return false;
    if (can_exclude) {
      if (sk == E_REST || tk == E_REST) can_exclude = false;
      if (can_exclude && excluded_name(ex, str_of_int(sp))) continue;
    }
    V ste = sk == E_OPT ? opt_type(se) : se;
    V tte = t->e[tpos];
    if (tk == E_OPT) tte = opt_type(tte);
    if (!related(ste, tte, R, ist)) return false;
  }
  return true;
}

// propertiesIdenticalTo for objects; tuples and arrays separately
static bool props_identical(Members *sm, Members *tm) {
  if (sm->np != tm->np) return false;
  for (uint32_t i = 0; i < sm->np; i++) {
    PInfo *p = &sm->p[i], *q = NULL;
    for (uint32_t j = 0; j < tm->np && !q; j++)
      if (p->name ? (tm->p[j].name && str_eq(tm->p[j].name, p->name)) : tm->p[j].sym == p->sym) q = &tm->p[j];
    if (!q || p->ro != q->ro || p->opt != q->opt) return false;
    if (!related(p->ty, q->ty, R_IDENT, IS_NONE)) return false;
  }
  return true;
}

// propertiesRelatedTo (not identity)
static bool excluded_name(VA *ex, Str *n) {
  if (!ex || !n) return false;
  for (uint32_t i = 0; i < ex->n; i++)
    if (str_eq((Str *)ex->d[i], n)) return true;
  return false;
}

static bool props_related_ex(V s, V t, int R, bool optionals_only, int ist, VA *ex);

static bool props_related(V s, V t, int R, bool optionals_only, int ist) {
  return props_related_ex(s, t, R, optionals_only, ist, NULL);
}

static bool tuple_props_related_ex(V s, TupT *t, int R, int ist, VA *ex);

static bool props_related_ex(V s, V t, int R, bool optionals_only, int ist, VA *ex) {
  if (is_tuple(t)) {
    if (is_array_or_tuple(s)) return tuple_props_related_ex(s, as_tup(t), R, ist, ex);
    if (tuple_has_rest(as_tup(t))) return false;
  }
  bool require_opt = R == R_STRICT && !is_tuple(s);
  // (an object type's properties read in place: they can be many)
  ObjT *to = kind(t) == K_OBJ ? as_obj(t) : NULL;
  Members tm;
  if (to) tm.np = to->np;
  else members_of(t, &tm);
  PInfo tpi;
#define TARGET_PROP(i) (to ? (obj_pinfo(&to->props[i], &tpi), &tpi) : &tm.p[i])
  // getUnmatchedProperty
  for (uint32_t i = 0; i < tm.np; i++) {
    PInfo *tp = TARGET_PROP(i);
    if (!(require_opt || !tp->opt)) continue;
    PInfo sp;
    bool found = tp->name ? member_prop(s, tp->name, &sp) : false;
    if (!found && !tp->name) {
      Members sm;
      members_of(s, &sm);
      for (uint32_t j = 0; j < sm.np && !found; j++)
        if (!sm.p[j].name && sm.p[j].sym == tp->sym) found = true;
    }
    if (!found) return false;
  }
  bool numeric_only = is_tuple(s) && is_tuple(t);
  for (uint32_t i = 0; i < tm.np; i++) {
    PInfo *tp = TARGET_PROP(i);
    if (!tp->name || excluded_name(ex, tp->name)) continue;
    if (numeric_only && !numeric_or_length(tp->name)) continue;
    if (optionals_only && !tp->opt) continue;
    PInfo sp;
    if (!member_prop(s, tp->name, &sp)) continue;
    if (!prop_related(&sp, tp, R, ist)) return false;
  }
  return true;
}
#undef TARGET_PROP

// ---------------------------------------------------------------------------
// The structure

static bool union_or_inter_related(V s, V t, int R, int ist) {
  int ks = kind(s), kt = kind(t);
  if (ks == K_UNION) {
    // eachTypeRelatedToType
    for (uint32_t i = 0; i < set_n(s); i++)
      if (!related(set_m(s, i), t, R, ist)) return false;
    return true;
  }
  if (kt == K_UNION) {
    // typeRelatedToSomeType
    if (union_has(t, s)) return true;
    uint32_t sf = ty_flags(s);
    if (sf & (TF_STRLIT | TF_BOOLLIT | TF_BIGLIT | (R == R_STRICT ? TF_NUMLIT : 0))) {
      // a literal against a union of primitives: its base type or itself
      if (set_prim_union(t)) {
        V base = (sf & TF_STRLIT) ? V_STRING : (sf & TF_NUMLIT) ? V_NUMBER : (sf & TF_BIGLIT) ? V_BIGINT : 0;
        return base && union_has(t, base);
      }
    }
    for (uint32_t i = 0; i < set_n(t); i++)
      if (related(s, set_m(t, i), R, ist)) return true;
    return false;
  }
  if (kt == K_INTER) {
    for (uint32_t i = 0; i < set_n(t); i++)
      if (!related(s, set_m(t, i), R, IS_TARGET)) return false;
    return true;
  }
  // the source is an intersection
  for (uint32_t i = 0; i < set_n(s); i++)
    if (related(set_m(s, i), t, R, IS_SOURCE)) return true;
  return false;
}

static bool each_related_to_some(V s, V t) {
  for (uint32_t i = 0; i < set_n(s); i++) {
    bool ok = false;
    V m = set_m(s, i);
    if (kind(t) == K_UNION || kind(t) == K_INTER) {
      for (uint32_t j = 0; j < set_n(t) && !ok; j++) ok = related(m, set_m(t, j), R_IDENT, IS_NONE);
    } else {
      ok = related(m, t, R_IDENT, IS_NONE);
    }
    if (!ok) return false;
  }
  return true;
}

static V apparent(V t) {
  // getApparentType: primitives have their interface's members (members_of
  // sees to that); object is {}
  return t;
}

static bool is_mutable_tuple(V t) { return is_tuple(t) && !tup_ro(as_tup(t)); }

// the element type of an array-like this type (0: none)
static V this_elem(V t) {
  Members m;
  members_of(t, &m);
  for (uint32_t i = 0; i < m.ni; i++)
    if (m.ix[i].key == V_NUMBER) return m.ix[i].ty;
  return 0;
}

static bool libm_identical(LibmT *a, LibmT *b) {
  if (a->app != b->app) return false;
  if ((a->name == NULL) != (b->name == NULL)) return false;
  if (a->name ? !str_eq(a->name, b->name) : a->sym != b->sym) return false;
  if (a->base == b->base || ty_identical(a->base, b->base)) return true;
  if (a->app == APP_ARRAY || a->app == APP_RO_ARRAY) {
    // methods returning this differ by their this type
    if (a->name && (str_eq_c(a->name, "fill") || str_eq_c(a->name, "copyWithin") || str_eq_c(a->name, "sort")))
      return false;
    V x = this_elem(a->base), y = this_elem(b->base);
    return x && y && related(x, y, R_IDENT, IS_NONE);
  }
  return true;
}

static bool structured_worker(V s, V t, int R, int ist) {
  int ks = kind(s), kt = kind(t);
  uint32_t sf = ty_flags(s), tf = ty_flags(t);
  if (R == R_IDENT) {
    if (sf & (TF_UNION | TF_INTER)) return each_related_to_some(s, t) && each_related_to_some(t, s);
    if (ks == K_TPL) {
      TplT *a = (TplT *)s, *b = (TplT *)t;
      if (a->n != b->n) return false;
      for (uint32_t i = 0; i <= a->n; i++)
        if (!str_eq(a->texts[i], b->texts[i])) return false;
      for (uint32_t i = 0; i < a->n; i++)
        if (!related(a->types[i], b->types[i], R, IS_NONE)) return false;
      return true;
    }
    if (ks == K_STRMAP)
      return ((StrMapT *)s)->mode == ((StrMapT *)t)->mode && related(((StrMapT *)s)->t, ((StrMapT *)t)->t, R, IS_NONE);
    if (ks == K_DEFERRED) {
      DefT *a = (DefT *)s, *b = (DefT *)t;
      return related(a->c, b->c, R, IS_NONE) && related(a->e, b->e, R, IS_NONE) && related(a->t, b->t, R, IS_NONE) &&
             related(a->f, b->f, R, IS_NONE);
    }
    if (!(sf & TF_OBJECT)) return false;
  } else if ((sf | tf) & (TF_UNION | TF_INTER)) {
    if (union_or_inter_related(s, t, R, ist)) return true;
    if (!((sf & TF_INSTANTIABLE) || ((sf & TF_OBJECT) && (tf & TF_UNION)) ||
          ((sf & TF_INTER) && (tf & (TF_OBJECT | TF_UNION | TF_INSTANTIABLE)))))
      return false;
  }
  if (R != R_IDENT) {
    if (kt == K_TPL) {
      if (tpl_matched(s, (TplT *)t, R)) return true;
    } else if (kt == K_STRMAP) {
      if (ks != K_STRMAP && member_of_strmap(s, t)) return true;
    }
  }
  if (sf & TF_TPARAM) {
    // a type parameter (constraint unknown)
    return R != R_IDENT && related(V_UNKNOWN, t, R, ist);
  }
  if (ks == K_DEFERRED) {
    DefT *a = (DefT *)s;
    if (kt == K_DEFERRED) {
      DefT *b = (DefT *)t;
      if (ty_identical(a->e, b->e) && (related(a->c, b->c, R, IS_NONE) || related(b->c, a->c, R, IS_NONE)) &&
          related(a->t, b->t, R, IS_NONE) && related(a->f, b->f, R, IS_NONE))
        return true;
    }
    // the default constraint: the union of the branches
    return related(mk_union2(a->t, a->f), t, R, ist);
  }
  if (ks == K_TPL && !(tf & TF_OBJECT)) return false;
  if (ks == K_STRMAP) {
    if (kt == K_STRMAP)
      return ((StrMapT *)s)->mode == ((StrMapT *)t)->mode && related(((StrMapT *)s)->t, ((StrMapT *)t)->t, R, ist);
    return false;
  }
  // structural comparison
  bool src_prim = (sf & TF_PRIMITIVE) != 0;
  if (R != R_IDENT) s = apparent(s);
  ks = kind(s);
  if (ks == K_LIBM || kt == K_LIBM) {
    if (ks == K_LIBM && kt == K_LIBM) return libm_identical((LibmT *)s, (LibmT *)t);
    if (R == R_IDENT) return false;
  }
  if (ks == K_ARRAY && kt == K_ARRAY && ((ArrT *)s)->ro == ((ArrT *)t)->ro) {
    // references to the same generic type: covariant in T
    return related(((ArrT *)s)->el, ((ArrT *)t)->el, R, IS_NONE);
  }
  if (kt == K_ARRAY && ((((ArrT *)t)->ro && is_array_or_tuple(s)) || is_mutable_tuple(s))) {
    if (R == R_IDENT) return false;
    if (ks == K_TUPLE && tup_nokinds(as_tup(s))) return tuple_elems_related(as_tup(s), ((ArrT *)t)->el, R);
    return related(num_index_of(s), ((ArrT *)t)->el, R, IS_NONE);
  }
  if (R == R_IDENT) {
    if (ks == K_TUPLE || kt == K_TUPLE) {
      if (ks != kt) return false;
      TupT *a = as_tup(s), *b = as_tup(t);
      if (a->len != b->len || tup_ro(a) != tup_ro(b)) return false;
      for (uint32_t i = 0; i < a->len; i++)
        if (tup_kind(a, i) != tup_kind(b, i) || !related(a->e[i], b->e[i], R, IS_NONE)) return false;
      return true;
    }
    if (ks == K_ARRAY || kt == K_ARRAY) return false;
    if (ks == K_GENFN && kt == K_GENFN) return generic_fn_related((GenFnT *)s, (GenFnT *)t, R);
    Members sm, tm;
    members_of(s, &sm);
    members_of(t, &tm);
    return props_identical(&sm, &tm) && sigs_list_related(sm.calls, sm.nc, tm.calls, tm.nc, R, ist) &&
           sigs_list_related(sm.ctors, sm.nct, tm.ctors, tm.nct, R, ist) && index_infos_identical(&sm, &tm);
  }
  // tuples: their elements (the number index types follow)
  if (kt == K_TUPLE && (ks == K_TUPLE || ks == K_ARRAY)) return tuple_props_related(s, as_tup(t), R, ist);
  uint32_t asf = ty_flags(s);
  // (primitives: their interface's members; object: {})
  int app = src_prim || ks == K_OBJECTKW ? apparent_of(s) : APP_NONE;
  bool apparent_obj = app != APP_NONE;
  if ((asf & (TF_OBJECT | TF_INTER) || apparent_obj) && kt == K_UNION) {
    // a discriminated union target: per discriminant value
    VA objs;
    va_init(&objs);
    for (uint32_t i = 0; i < set_n(t); i++)
      if (ty_flags(set_m(t, i)) & (TF_OBJECT | TF_INTER)) va_push(&objs, set_m(t, i));
    if (objs.n >= 2) return discriminated_related(s, mk_union(objs.d, objs.n), R);
    return false;
  }
  if ((asf & (TF_OBJECT | TF_INTER) || apparent_obj) && (tf & TF_OBJECT)) {
    if (ks == K_GENFN && kt == K_GENFN) return generic_fn_related((GenFnT *)s, (GenFnT *)t, R);
    if (!props_related(s, t, R, false, ist)) return false;
    if (!sigs_related(s, t, false, R, ist)) return false;
    if (!sigs_related(s, t, true, R, ist)) return false;
    Members sm, tm;
    members_of(s, &sm);
    members_of(t, &tm);
    return index_infos_related(s, &sm, t, &tm, src_prim, R, ist);
  }
  return false;
}

// isDiscriminantProperty: the union's property of the name has literal
// types that differ between its members
static bool discriminant_prop(V u, Str *name) {
  V first = 0;
  bool nonuniform = false, literal = false, property = false;
  for (uint32_t i = 0; i < set_n(u); i++) {
    PInfo p;
    if (!member_prop(set_m(u, i), name, &p)) continue;
    if (kind(p.ty) != K_LIBM) property = true;
    if (!first) first = p.ty;
    else if (!(first == p.ty || ty_eq(first, p.ty))) nonuniform = true;
    if (is_literal_type(p.ty) || is_pattern_literal(p.ty)) literal = true;
  }
  return property && nonuniform && literal;
}

// typeRelatedToDiscriminatedType
static bool discriminated_related(V s, V t, int R) {
  Members sm;
  members_of(s, &sm);
  VA disc;  // PInfo *
  va_init(&disc);
  for (uint32_t i = 0; i < sm.np; i++)
    if (sm.p[i].name && discriminant_prop(t, sm.p[i].name)) va_push(&disc, (V)&sm.p[i]);
  if (!disc.n) return false;
  uint64_t combos = 1;
  for (uint32_t i = 0; i < disc.n; i++) {
    V ty = ((PInfo *)disc.d[i])->ty;
    combos *= ty == V_NEVER ? 0 : kind(ty) == K_UNION ? set_n(ty) : 1;
    if (combos > 25) return false;
    if (combos == 0) return false;
  }
  VA ex;
  va_init(&ex);
  for (uint32_t i = 0; i < disc.n; i++) va_push(&ex, (V)((PInfo *)disc.d[i])->name);
  VA matching;
  va_init(&matching);
  for (uint64_t c = 0; c < combos; c++) {
    V combo[disc.n];
    uint64_t r = c;
    for (int64_t j = (int64_t)disc.n - 1; j >= 0; j--) {
      V ty = ((PInfo *)disc.d[j])->ty;
      uint32_t len = kind(ty) == K_UNION ? set_n(ty) : 1;
      combo[j] = kind(ty) == K_UNION ? set_m(ty, (uint32_t)(r % len)) : ty;
      r /= len;
    }
    bool has = false;
    for (uint32_t k = 0; k < set_n(t); k++) {
      V m = set_m(t, k);
      bool ok = true;
      for (uint32_t i = 0; i < disc.n && ok; i++) {
        PInfo *sp = (PInfo *)disc.d[i];
        PInfo tp;
        if (!member_prop(m, sp->name, &tp)) {
          ok = false;
          break;
        }
        // (the source property as the one discriminant type; optionality
        // not compared)
        PInfo one = *sp;
        one.ty = combo[i];
        one.opt = false;
        if (R == R_STRICT && one.ro && !tp.ro) ok = false;
        else if (!(tp.ty == V_ANY || (R != R_STRICT && tp.ty == V_UNKNOWN)) && !related(one.ty, tp.ty, R, IS_NONE)) ok = false;
      }
      if (!ok) continue;
      bool dup = false;
      for (uint32_t q = 0; q < matching.n && !dup; q++) dup = matching.d[q] == m;
      if (!dup) va_push(&matching, m);
      has = true;
    }
    if (!has) return false;
  }
  for (uint32_t k = 0; k < matching.n; k++) {
    V m = matching.d[k];
    if (!props_related_ex(s, m, R, false, IS_NONE, &ex)) return false;
    if (!sigs_related(s, m, false, R, IS_NONE)) return false;
    if (!sigs_related(s, m, true, R, IS_NONE)) return false;
    if (!(is_tuple(s) && is_tuple(m))) {
      Members a, b;
      members_of(s, &a);
      members_of(m, &b);
      if (!index_infos_related(s, &a, m, &b, false, R, IS_NONE)) return false;
    }
  }
  return true;
}

static bool sigs_related(V s, V t, bool ctor, int R, int ist) {
  Members sm, tm;
  members_of(t, &tm);
  if (!(ctor ? tm.nct : tm.nc)) return true;
  members_of(s, &sm);
  return ctor ? sigs_list_related(sm.ctors, sm.nct, tm.ctors, tm.nct, R, ist)
              : sigs_list_related(sm.calls, sm.nc, tm.calls, tm.nc, R, ist);
}

static bool is_nongeneric_object(V t) { return (ty_flags(t) & TF_OBJECT) != 0; }

static bool structured(V s, V t, int R, int ist) {
  bool r = structured_worker(s, t, R, ist);
  if (R != R_IDENT && r) {
    uint32_t sf = ty_flags(s);
    if (!(ist & IS_TARGET) && kind(t) == K_INTER && (sf & (TF_OBJECT | TF_INTER))) {
      r = props_related(s, t, R, false, IS_NONE);
    } else if (is_nongeneric_object(t) && !is_array_or_tuple(t) && kind(s) == K_INTER) {
      bool has_t = false;
      for (uint32_t i = 0; i < set_n(s) && !has_t; i++) has_t = set_m(s, i) == t;
      if (!has_t) r = props_related(s, t, R, true, ist);
    }
  }
  return r;
}

typedef struct { V s, t; int R, ist; } RelKey;
static RelKey rel_stack[128];
static int rel_sp;

// recursiveTypeRelatedTo: a comparison in progress is assumed to hold
static bool recursive(V s, V t, int R, int ist) {
  for (int i = 0; i < rel_sp; i++)
    if (rel_stack[i].s == s && rel_stack[i].t == t && rel_stack[i].R == R && rel_stack[i].ist == ist) return true;
  if (rel_sp >= 100) return true;
  rel_stack[rel_sp].s = s;
  rel_stack[rel_sp].t = t;
  rel_stack[rel_sp].R = R;
  rel_stack[rel_sp].ist = ist;
  rel_sp++;
  bool r = structured(s, t, R, ist);
  rel_sp--;
  return r;
}

// an intersection with mutually exclusive discriminants is never
// (getReducedType)
V reduced_type(V t);

// isRelatedTo
// A tuple of required elements against an array: each element against its
// element type (as their union is). The rests a list is taken apart into
// (`[infer H, ...infer R extends T[]]`, step by step) are views of the same
// elements: which suffix of them is known to be related is remembered (by
// the elements' end and the target, until the next collection), so that
// each step checks only what it has not seen.
typedef struct { const V *end, *from; V el; int R; size_t epoch; } SufEnt;
static SufEnt suf_cache[256];

static bool tuple_elems_related(TupT *s, V el, int R) {
  const V *end = s->e + s->len;
  SufEnt *c = &suf_cache[(((uintptr_t)end >> 3) ^ ((uintptr_t)el >> 3) * 31) & 255];
  bool hit = c->end == end && c->el == el && c->R == R && c->epoch == gc_collections;
  const V *stop = hit ? c->from : end;
  if (hit && s->e >= c->from) return true;
  for (const V *p = s->e; p < stop; p++)
    if (!related(*p, el, R, IS_NONE)) return false;
  // (the elements are s's, live: the entry holds past a collection during
  // the checks, and is recorded in the epoch after it)
  size_t ep = gc_collections;
  c->end = end;
  c->from = s->e;
  c->el = el;
  c->R = R;
  c->epoch = ep;
  return true;
}

static bool related(V s, V t, int R, int ist) {
  if (s == t) return true;
  int ks = kind(s), kt = kind(t);
  if ((ks >= K_VEC && ks <= K_STORE) || (kt >= K_VEC && kt <= K_STORE))
    return R != R_IDENT && (kt == K_ANY || kt == K_UNKNOWN || ks == K_NEVER);
  uint32_t sf = ty_flags(s), tf = ty_flags(t);
  if ((sf & TF_OBJECT) && (tf & TF_PRIMITIVE)) return R != R_IDENT && simple(s, t, sf, tf, R);
  // getNormalizedType: a substitution type is its constraint & its base as
  // the source, its base as the target
  if (ks == K_SUBST || kt == K_SUBST) {
    if (ks == K_SUBST) {
      V it[2] = {((SubstT *)s)->cons, ((SubstT *)s)->base};
      s = mk_inter(it, 2);
    }
    if (kt == K_SUBST) t = ((SubstT *)t)->base;
    return related(s, t, R, ist);
  }
  if (ks == K_INTER) {
    s = reduced_type(s);
    if (s != (V)0 && kind(s) != K_INTER) {
      ks = kind(s);
      sf = ty_flags(s);
    }
  }
  if (kt == K_INTER) {
    t = reduced_type(t);
    kt = kind(t);
    tf = ty_flags(t);
  }
  if (same_scalar(s, t)) return true;
  if (R == R_IDENT) {
    if (sf != tf) return false;
    if (sf & TF_SINGLETON) return true;
    return recursive(s, t, R, IS_NONE);
  }
  if ((sf & TF_DEFNONNULL) && kt == K_UNION) {
    // a definitely non-null source and T | null | undefined: T
    uint32_t n = set_n(t), nn = 0;
    V cand = 0;
    for (uint32_t i = 0; i < n; i++) {
      V m = set_m(t, i);
      if (m == V_NULL || m == V_UNDEFINED) nn++;
      else cand = m;
    }
    if (cand && nn >= 1 && nn + 1 == n && n <= 3) {
      t = cand;
      kt = kind(t);
      tf = ty_flags(t);
      if (same(s, t)) return true;
    }
  }
  if (simple(s, t, sf, tf, R)) return true;
  if ((sf | tf) & (TF_STRUCTURED | TF_INSTANTIABLE)) {
    // the weak type check
    if (!(ist & IS_TARGET) && (sf & (TF_PRIMITIVE | TF_OBJECT | TF_INTER)) && (tf & (TF_OBJECT | TF_INTER)) &&
        is_weak(t)) {
      Members sm;
      members_of(s, &sm);
      if ((sm.np > 0 || sm.nc > 0 || sm.nct > 0) && !has_common_props(s, t)) return false;
    }
    bool skip = (ks == K_UNION && set_n(s) < 4 && kt != K_UNION) ||
                (kt == K_UNION && set_n(t) < 4 && !(sf & (TF_STRUCTURED | TF_INSTANTIABLE)));
    return skip ? union_or_inter_related(s, t, R, ist) : recursive(s, t, R, ist);
  }
  return false;
}

// isTypeRelatedTo
static bool type_related(V s, V t, int R) {
  if (s == t) return true;
  int ks = kind(s), kt = kind(t);
  // literal fast paths (the common case of generated code)
  if (ks == kt && ks >= K_STRLIT && ks <= K_BIGLIT) return ty_eq(s, t);
  if (R != R_IDENT) {
    uint32_t sf = ty_flags(s), tf = ty_flags(t);
    if (simple(s, t, sf, tf, R)) return true;
    if (!((sf | tf) & (TF_STRUCTURED | TF_INSTANTIABLE))) return same(s, t);
  } else {
    uint32_t sf = ty_flags(s), tf = ty_flags(t);
    if (!((sf | tf) & (TF_UNION | TF_INTER | TF_COND))) {
      if (sf != tf) return false;
      if (sf & TF_SINGLETON) return true;
    }
  }
  return related(s, t, R, IS_NONE);
}

bool is_assignable(V s, V t) { return type_related(s, t, R_ASSIGN); }
// `X extends infer V extends bigint` of a value that is no integer immediate
// (gen.mbt: the inline conditionals of simple values)
bool rt_is_bigint(V v) { return is_assignable(v, V_BIGINT); }
bool is_subtype(V s, V t) { return type_related(s, t, R_STRICT); }
bool ty_identical(V a, V b) { return type_related(a, b, R_IDENT); }

// ---------------------------------------------------------------------------
// Template literal types

// inferFromLiteralPartsToTemplateLiteral: the types of target's
// placeholders matched by the source's texts and types (stexts: sn + 1
// texts); false when it does not match
static bool code_point_len(const uint16_t *d, int32_t n) {
  return n >= 2 && d[0] >= 0xD800 && d[0] <= 0xDBFF && d[1] >= 0xDC00 && d[1] <= 0xDFFF;
}

static Str *src_text(Str **stexts, uint32_t last, Str *rem_end, uint32_t i) { return i < last ? stexts[i] : rem_end; }

V get_template_type(Str **texts, const V *types, uint32_t n);

bool infer_literal_parts(Str **stexts, const V *stypes, uint32_t sn, TplT *target, V *matches) {
  uint32_t last = sn;
  Str *sstart = stexts[0], *send = stexts[last];
  Str **tt = target->texts;
  uint32_t tlast = target->n;
  Str *tstart = tt[0], *tend = tt[tlast];
  if ((last == 0 && sstart->len < tstart->len + tend->len) || !str_starts(sstart, tstart) || !str_ends(send, tend))
    return false;
  Str *rem_end = str_slice(send, 0, send->len - tend->len);
  uint32_t seg = 0, nm = 0;
  int32_t pos = tstart->len;
#define ADD_MATCH(S, P)                                                                              \
  do {                                                                                               \
    uint32_t s_ = (S);                                                                               \
    int32_t p_ = (P);                                                                                \
    V mt;                                                                                            \
    if (s_ == seg) {                                                                                 \
      mt = (V)str_slice(src_text(stexts, last, rem_end, s_), pos, p_);                               \
    } else {                                                                                         \
      Str **mtexts = gc_alloc((size_t)(s_ - seg + 1) * 8);                                           \
      mtexts[0] = str_slice(stexts[seg], pos, stexts[seg]->len);                                     \
      for (uint32_t q_ = seg + 1; q_ < s_; q_++) mtexts[q_ - seg] = stexts[q_];                      \
      mtexts[s_ - seg] = str_slice(src_text(stexts, last, rem_end, s_), 0, p_);                      \
      mt = get_template_type(mtexts, stypes + seg, s_ - seg);                                        \
    }                                                                                                \
    matches[nm++] = mt;                                                                              \
    seg = s_;                                                                                        \
    pos = p_;                                                                                        \
  } while (0)
  for (uint32_t i = 1; i < tlast; i++) {
    Str *delim = tt[i];
    if (delim->len > 0) {
      uint32_t s = seg;
      int32_t p = pos;
      for (;;) {
        Str *txt = src_text(stexts, last, rem_end, s);
        int32_t d = p <= txt->len ? str_index(txt, delim, p, txt->len) : -1;
        if (d >= 0) {
          p = d;
          break;
        }
        s++;
        if (s == last + 1) return false;
        p = 0;
      }
      ADD_MATCH(s, p);
      pos += delim->len;
    } else {
      Str *txt = src_text(stexts, last, rem_end, seg);
      if (pos < txt->len) {
        int32_t size = code_point_len(str_d(txt) + pos, txt->len - pos) ? 2 : 1;
        ADD_MATCH(seg, pos + size);
      } else if (seg < last) {
        ADD_MATCH(seg + 1, 0);
      } else {
        return false;
      }
    }
  }
  ADD_MATCH(last, src_text(stexts, last, rem_end, last)->len);
#undef ADD_MATCH
  return true;
}

// getStringLikeTypeForType
static V string_like(V t) {
  if (ty_flags(t) & (TF_ANY | TF_STRINGLIKE)) return t;
  static Str *e2[2];
  if (!e2[0]) {
    e2[0] = e2[1] = str_of_cstr("");
    gc_add_root(e2, sizeof e2);
  }
  return get_template_type(e2, &t, 1);
}

// inferTypesFromTemplateLiteralType
bool infer_from_template(V s, TplT *t, V *out, int R) {
  if (kind(s) == K_STRLIT) {
    Str *txt = as_str(s);
    return infer_literal_parts(&txt, NULL, 0, t, out);
  }
  if (kind(s) == K_TPL) {
    TplT *a = (TplT *)s;
    bool eq = a->n == t->n;
    for (uint32_t i = 0; eq && i <= a->n; i++) eq = str_eq(a->texts[i], t->texts[i]);
    if (eq) {
      for (uint32_t i = 0; i < a->n; i++)
        out[i] = type_related(a->types[i], t->types[i], R) ? a->types[i] : string_like(a->types[i]);
      return true;
    }
    return infer_literal_parts(a->texts, a->types, a->n, t, out);
  }
  return false;
}

// JavaScript's Number(text)
double js_to_number(Str *s);

bool is_valid_number_string(Str *s, bool round_trip) {
  if (s->len == 0) return false;
  double d = js_to_number(s);
  if (isnan(d) || isinf(d)) return false;
  return !round_trip || str_eq(str_of_number(d), s);
}

// isValidBigIntString: an optional minus and a bigint literal's digits
bool is_valid_bigint_string(Str *s, bool round_trip) {
  const uint16_t *d = str_d(s);
  int32_t n = s->len, i = 0;
  if (n == 0) return false;
  if (d[0] == '-') i = 1;
  if (i >= n) return false;
  if (n - i >= 2 && d[i] == '0' && (d[i + 1] == 'x' || d[i + 1] == 'X' || d[i + 1] == 'o' || d[i + 1] == 'O' ||
                                    d[i + 1] == 'b' || d[i + 1] == 'B')) {
    uint16_t base = d[i + 1] | 0x20;
    if (n - i == 2) return false;
    for (int32_t j = i + 2; j < n; j++) {
      uint16_t c = d[j];
      bool ok = base == 'x' ? ((c >= '0' && c <= '9') || ((c | 0x20) >= 'a' && (c | 0x20) <= 'f'))
                : base == 'o' ? (c >= '0' && c <= '7')
                              : (c == '0' || c == '1');
      if (!ok) return false;
    }
    if (round_trip) return false;
    return true;
  }
  for (int32_t j = i; j < n; j++)
    if (d[j] < '0' || d[j] > '9') return false;
  // a decimal literal with a leading zero is no bigint literal
  if (n - i > 1 && d[i] == '0') return false;
  if (round_trip) return !(i == 1 && n == 2 && d[1] == '0');
  return true;
}

static bool name_is(V t, const char *n) {
  Str *s;
  return lit_to_str(t, &s) && str_eq_c(s, n);
}

// isValidTypeForTemplateLiteralPlaceholder
static bool valid_placeholder(V s, V t, int R) {
  if (kind(t) == K_INTER) {
    for (uint32_t i = 0; i < set_n(t); i++) {
      V m = set_m(t, i);
      if (!is_empty_anon_obj(m) && !valid_placeholder(s, m, R)) return false;
    }
    return true;
  }
  if (t == V_STRING || type_related(s, t, R)) return true;
  if (kind(s) == K_STRLIT) {
    Str *v = as_str(s);
    int kt = kind(t);
    return (kt == K_NUMBER && is_valid_number_string(v, false)) || (kt == K_BIGINT && is_valid_bigint_string(v, false)) ||
           ((kt == K_TRUE || kt == K_FALSE || kt == K_NULL || kt == K_UNDEFINED) && name_is(t, "") == false &&
            ((kt == K_TRUE && str_eq_c(v, "true")) || (kt == K_FALSE && str_eq_c(v, "false")) ||
             (kt == K_NULL && str_eq_c(v, "null")) || (kt == K_UNDEFINED && str_eq_c(v, "undefined")))) ||
           (kt == K_STRMAP && member_of_strmap(s, t)) || (kt == K_TPL && tpl_matched(s, (TplT *)t, R));
  }
  if (kind(s) == K_TPL) {
    TplT *a = (TplT *)s;
    return a->n == 1 && a->texts[0]->len == 0 && a->texts[1]->len == 0 && type_related(a->types[0], t, R);
  }
  return false;
}

// isTypeMatchedByTemplateLiteralType
static bool tpl_matched(V s, TplT *t, int R) {
  V out[t->n ? t->n : 1];
  if (!infer_from_template(s, t, out, R)) return false;
  for (uint32_t i = 0; i < t->n; i++)
    if (!valid_placeholder(out[i], t->types[i], R)) return false;
  return true;
}

bool template_matches(V s, V t) { return kind(t) == K_TPL && tpl_matched(s, (TplT *)t, R_ASSIGN); }
bool placeholder_accepts(V s, V t) { return valid_placeholder(s, t, R_ASSIGN); }

// isMemberOfStringMapping
static bool member_of_strmap(V s, V t) {
  int kt = kind(t);
  if (kt == K_ANY) return true;
  if (kt == K_STRING || kt == K_TPL) return is_assignable(s, t);
  if (kt == K_STRMAP) {
    // the same mappings applied to the source give the source, which is in
    // the innermost type
    StrMapT *m = (StrMapT *)t;
    V src = s, inner = m->t;
    if (kind(inner) == K_STRMAP) {
      // applyTargetStringMappingToSource, recursively
      StrMapT *chain[16];
      int n = 0;
      V x = t;
      while (kind(x) == K_STRMAP && n < 16) {
        chain[n++] = (StrMapT *)x;
        x = ((StrMapT *)x)->t;
      }
      for (int i = n - 1; i >= 0; i--) src = string_mapping((int)chain[i]->mode, src);
      return same(src, s) && member_of_strmap(s, x);
    }
    return same(string_mapping((int)m->mode, s), s) && member_of_strmap(s, inner);
  }
  return false;
}

bool strmap_member(V s, V t) { return member_of_strmap(s, t); }
