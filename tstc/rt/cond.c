// Conditional types: deciding the branch, inference of `infer` slots from
// patterns, distribution over unions. The inference follows TypeScript's
// checker (tsgo internal/checker/inference.go, inferTypes): candidates with
// priorities from the check type matched against the extends type, the
// inferred type of each slot (or its constraint), then the extends type
// with the inferred types decides (getConditionalType).
#include "desc.h"

#include <math.h>

V get_template_type(Str **texts, const V *types, uint32_t n);
bool infer_literal_parts(Str **stexts, const V *stypes, uint32_t sn, TplT *target, V *matches);
bool infer_from_template(V s, TplT *t, V *out, int R);
bool is_valid_number_string(Str *s, bool round_trip);
bool is_valid_bigint_string(Str *s, bool round_trip);
bool template_matches(V s, V t);
bool strmap_member(V s, V t);
double js_to_number(Str *s);
int64_t sig_param_count(FnT *f);
int64_t sig_min_args(FnT *f);
bool sig_has_effective_rest(FnT *f);
V sig_type_at(FnT *f, int64_t pos);
V sig_effective_rest(FnT *f);
V sig_rest_type_at(FnT *f, int64_t pos, bool ro);

enum {
  IP_NAKED = 1 << 0,
  IP_SPECULATIVE_TUPLE = 1 << 1,
  IP_NO_CONSTRAINTS = 1 << 9,
  IP_ALWAYS_STRICT = 1 << 10,
  IP_MAX = 1 << 11,
};

typedef struct {
  int64_t slot;
  VA cands, contra;
  int priority;
  V explicit_cons;  // `infer X extends C` (its code)
  const PatD *cons_pat;
  VA implied;       // implied constraints (unknown[] for rest, string in templates)
} Inf;

typedef struct {
  Inf *infs;
  uint32_t n;
  int priority;
  int inf_priority;  // the lowest priority of the inferences made
  bool contra;
  V *env;
} IC;

static inline V pcode(const PatD *p, V *env) { return p->cval ? p->cval : call_thunk(p->code, env); }

static bool is_marker(V t) { return kind(t) == K_USYM && ((USymT *)t)->id < 0; }

static Inf *inf_of(IC *c, int64_t slot) {
  for (uint32_t i = 0; i < c->n; i++)
    if (c->infs[i].slot == slot) return &c->infs[i];
  return NULL;
}

static bool va_has(VA *a, V t) {
  for (uint32_t i = 0; i < a->n; i++)
    if (a->d[i] == t || ty_eq(a->d[i], t)) return true;
  return false;
}

// an inference to a type variable
static void infer_to_var(IC *c, V source, int64_t slot) {
  Inf *inf = inf_of(c, slot);
  if (!inf) return;
  if (c->priority < inf->priority) {
    va_init(&inf->cands);
    va_init(&inf->contra);
    inf->priority = c->priority;
  }
  if (c->priority == inf->priority) {
    VA *a = c->contra ? &inf->contra : &inf->cands;
    if (!va_has(a, source)) va_push(a, source);
  }
  if (c->priority < c->inf_priority) c->inf_priority = c->priority;
}

static void infer(IC *c, V source, const PatD *target);

static void infer_with_priority(IC *c, V source, const PatD *target, int p) {
  int save = c->priority;
  c->priority |= p;
  infer(c, source, target);
  c->priority = save;
}

static void infer_contra(IC *c, V source, const PatD *target) {
  c->contra = !c->contra;
  infer(c, source, target);
  c->contra = !c->contra;
}

static void members_v(V t, VA *out) {
  va_init(out);
  if (kind(t) == K_UNION) {
    for (uint32_t i = 0; i < set_n(t); i++) va_push(out, set_m(t, i));
  } else if (t != V_NEVER) {
    va_push(out, t);
  }
}

// ---------------------------------------------------------------------------
// Patterns as types

static PatD *code_pat(V t) {
  PatD *p = gc_alloc(sizeof(PatD));
  p->kind = P_CODE;
  p->cval = t;
  return p;
}

// a pattern's tuple, its spreads of known types expanded: elements and their
// kinds (E_REQ, E_OPT, E_REST: a rest element of the element pattern, and
// E_VARIADIC: a spread of an infer slot)
enum { E_VARIADIC = 3 };
typedef struct {
  const PatD **e;
  int *k;
  uint32_t n;
  bool ro;
} PTup;

static void ptup_push(PTup *t, uint32_t *cap, const PatD *p, int k) {
  if (t->n == *cap) {
    uint32_t nc = *cap ? *cap * 2 : 8;
    const PatD **e = gc_alloc((size_t)nc * 8);
    int *ks = gc_alloc_atomic((size_t)nc * sizeof(int));
    if (t->n) {
      memcpy(e, t->e, (size_t)t->n * 8);
      memcpy(ks, t->k, (size_t)t->n * sizeof(int));
    }
    t->e = e;
    t->k = ks;
    *cap = nc;
  }
  t->e[t->n] = p;
  t->k[t->n] = k;
  t->n++;
}

static void ptup_of(const PatD *pat, V *env, PTup *out) {
  memset(out, 0, sizeof *out);
  uint32_t cap = 0;
  out->ro = pat->ro;
  for (int64_t i = 0; i < pat->n; i++) {
    const PatD *e = pat->elems[i];
    int64_t k = pat->ekinds[i];
    if (k != E_REST) {
      ptup_push(out, &cap, e, (int)k);
      continue;
    }
    if (e->kind == P_INFER) {
      ptup_push(out, &cap, e, E_VARIADIC);
    } else if (e->kind == P_ARRAY) {
      ptup_push(out, &cap, e->sub, E_REST);
    } else if (e->kind == P_CODE) {
      V v = pcode(e, env);
      if (kind(v) == K_TUPLE) {
        TupT *t = as_tup(v);
        for (uint32_t j = 0; j < t->len; j++) {
          int ek = tup_kind(t, j);
          ptup_push(out, &cap, code_pat(t->e[j]), ek);
        }
      } else if (kind(v) == K_ARRAY) {
        ptup_push(out, &cap, code_pat(((ArrT *)v)->el), E_REST);
      } else {
        ptup_push(out, &cap, code_pat(v == V_ANY ? V_ANY : V_UNKNOWN), E_REST);
      }
    } else {
      // (a spread of another pattern: as its elements' rest)
      ptup_push(out, &cap, e, E_VARIADIC);
    }
  }
}

static bool pk_variable(int k) { return k == E_REST || k == E_VARIADIC; }

static uint32_t ptup_fixed(PTup *t) {
  uint32_t i = 0;
  while (i < t->n && !pk_variable(t->k[i])) i++;
  return i;
}

static uint32_t ptup_min(PTup *t) {
  uint32_t m = 0;
  for (uint32_t i = 0; i < t->n; i++)
    if (t->k[i] == E_REQ) m++;
  return m;
}

static bool ptup_has(PTup *t, int k) {
  for (uint32_t i = 0; i < t->n; i++)
    if (t->k[i] == k) return true;
  return false;
}

// ---------------------------------------------------------------------------
// Tuples

static uint32_t tup_fixed(TupT *t) {
  uint32_t i = 0;
  while (i < t->len && tup_kind(t, i) != E_REST) i++;
  return i;
}

static uint32_t tup_min(TupT *t) {
  uint32_t m = 0;
  for (uint32_t i = 0; i < t->len; i++)
    if (tup_kind(t, i) == E_REQ) m++;
  return m;
}

static bool tup_has_rest(TupT *t) { return tup_fixed(t) < t->len; }

// trailing elements that are not rest elements
static uint32_t tup_end_fixed(TupT *t) {
  uint32_t n = 0;
  while (n < t->len && tup_kind(t, t->len - 1 - n) != E_REST) n++;
  return n;
}

static uint32_t ptup_end_fixed(PTup *t) {
  uint32_t n = 0;
  while (n < t->n && !pk_variable(t->k[t->n - 1 - n])) n++;
  return n;
}

// sliceTupleType
static V tuple_slice(TupT *t, uint32_t index, uint32_t end_skip) {
  uint32_t end = t->len - end_skip;
  uint32_t fixed = tup_fixed(t);
  if (index > fixed) {
    // the rest array
    VA items;
    va_init(&items);
    for (uint32_t i = fixed; i < t->len; i++) {
      va_push(&items, t->e[i]);
      if (tup_kind(t, i) == E_OPT) va_push(&items, V_UNDEFINED);
    }
    return items.n ? mk_array(mk_union(items.d, items.n), false) : empty_tuple;
  }
  if (index >= end) return empty_tuple;
  TB b;
  tb_init(&b);
  for (uint32_t i = index; i < end; i++) tb_push(&b, t->e[i], tup_kind(t, i), tup_name(t, i));
  return tuple_normalize(&b);
}

// getElementTypeOfSliceOfTupleType (0: none)
static V tuple_slice_elem(TupT *t, uint32_t index, uint32_t end_skip) {
  uint32_t len = t->len - end_skip;
  if (index >= len) return 0;
  VA items;
  va_init(&items);
  for (uint32_t i = index; i < len; i++) {
    va_push(&items, t->e[i]);
    if (tup_kind(t, i) == E_OPT) va_push(&items, V_UNDEFINED);
  }
  return mk_union(items.d, items.n);
}

static V elem_type(TupT *t, uint32_t i) { return tup_kind(t, i) == E_OPT ? opt_type(t->e[i]) : t->e[i]; }

static void infer_tuple(IC *c, V source, const PatD *target) {
  PTup tt;
  ptup_of(target, c->env, &tt);
  bool s_tuple = kind(source) == K_TUPLE;
  TupT *st = s_tuple ? as_tup(source) : NULL;
  if (s_tuple) {
    // tupleTypesDefinitelyUnrelated
    uint32_t smin = tup_min(st), tmin = ptup_min(&tt);
    bool t_variadic = ptup_has(&tt, E_VARIADIC);
    bool t_variable = t_variadic || ptup_has(&tt, E_REST);
    if ((!t_variadic && tmin > smin) || (!t_variable && (tup_has_rest(st) || ptup_fixed(&tt) < tup_fixed(st)))) return;
  }
  uint32_t sarity = s_tuple ? st->len : 1, tarity = tt.n;
  // the same structure: element by element
  if (s_tuple && sarity == tarity) {
    bool match = true;
    for (uint32_t i = 0; i < tarity && match; i++)
      match = (tup_kind(st, i) == E_REST) == pk_variable(tt.k[i]);
    if (match) {
      for (uint32_t i = 0; i < tarity; i++) {
        V e = elem_type(st, i);
        if (tt.k[i] == E_VARIADIC) e = mk_array(e, false);
        infer(c, e, tt.e[i]);
      }
      return;
    }
  }
  uint32_t start = 0, end = 0;
  if (s_tuple) {
    uint32_t sf = tup_fixed(st), tf = ptup_fixed(&tt);
    start = sf < tf ? sf : tf;
    if (ptup_has(&tt, E_REST) || ptup_has(&tt, E_VARIADIC)) {
      uint32_t se = tup_end_fixed(st), te = ptup_end_fixed(&tt);
      end = se < te ? se : te;
    }
  }
  for (uint32_t i = 0; i < start; i++) infer(c, elem_type(st, i), tt.e[i]);
  if (!s_tuple || (sarity - start - end == 1 && tup_kind(st, start) == E_REST)) {
    V rest = s_tuple ? st->e[start] : ((ArrT *)source)->el;
    for (uint32_t i = start; i < tarity - end; i++) {
      V t = rest;
      if (tt.k[i] == E_VARIADIC) t = mk_array(t, false);
      infer(c, t, tt.e[i]);
    }
  } else {
    uint32_t middle = tarity - start - end;
    if (middle == 1 && tt.k[start] == E_VARIADIC) {
      int p = tt.k[tarity - 1] == E_OPT ? IP_SPECULATIVE_TUPLE : 0;
      infer_with_priority(c, tuple_slice(st, start, end), tt.e[start], p);
    } else if (middle == 1 && tt.k[start] == E_REST) {
      V r = tuple_slice_elem(st, start, end);
      if (r) infer(c, r, tt.e[start]);
    }
    // (two variadic elements: no inference without implied arities)
  }
  for (uint32_t i = 0; i < end; i++) infer(c, elem_type(st, sarity - i - 1), tt.e[tarity - i - 1]);
}

// ---------------------------------------------------------------------------
// Template literal patterns

// an alternative of a template pattern once its known parts are folded in:
// texts, and per placeholder an infer pattern (pats) or a known type (types)
typedef struct {
  VA texts, pats, types;
} Alt;

static void alt_copy(Alt *dst, const Alt *src) {
  va_init(&dst->texts);
  va_init(&dst->pats);
  va_init(&dst->types);
  for (uint32_t q = 0; q < src->texts.n; q++) va_push(&dst->texts, src->texts.d[q]);
  for (uint32_t q = 0; q < src->pats.n; q++) va_push(&dst->pats, src->pats.d[q]);
  for (uint32_t q = 0; q < src->types.n; q++) va_push(&dst->types, src->types.d[q]);
}

static void alt_append_text(Alt *a, Str *s) {
  a->texts.d[a->texts.n - 1] = (V)str_concat_copy(as_str(a->texts.d[a->texts.n - 1]), s);
}

bool is_pattern_literal(V t);

// the alternatives of getTemplateLiteralType over the pattern's parts
static void tpl_alts_add(const PatD *pat, uint32_t i, Alt *cur, V *env, VA *alts, V type_part, Str *next);

static void tpl_alts(const PatD *pat, uint32_t i, Alt *cur, V *env, VA *alts) {
  if (i == pat->n) {
    Alt *a = gc_alloc(sizeof(Alt));
    *a = *cur;
    va_push(alts, (V)a);
    return;
  }
  const PatD *p = pat->elems[i];
  Str *next = pat->texts[i + 1];
  if (p->kind != P_CODE) {
    Alt n;
    alt_copy(&n, cur);
    va_push(&n.pats, (V)p);
    va_push(&n.types, 0);
    va_push(&n.texts, (V)next);
    tpl_alts(pat, i + 1, &n, env, alts);
    return;
  }
  V v = pcode(p, env);
  if (v == V_NEVER) return;
  VA ms;
  members_v(v, &ms);
  for (uint32_t j = 0; j < ms.n; j++) tpl_alts_add(pat, i, cur, env, alts, ms.d[j], next);
}

static void tpl_alts_add(const PatD *pat, uint32_t i, Alt *cur, V *env, VA *alts, V m, Str *next) {
  Alt n;
  alt_copy(&n, cur);
  Str *lit;
  uint32_t f = ty_flags(m);
  if ((f & (TF_LITERAL | TF_NULL | TF_UNDEFINED)) && lit_to_str(m, &lit)) {
    alt_append_text(&n, lit);
    alt_append_text(&n, next);
  } else if (kind(m) == K_TPL) {
    TplT *it = (TplT *)m;
    alt_append_text(&n, it->texts[0]);
    for (uint32_t q = 0; q < it->n; q++) {
      va_push(&n.pats, 0);
      va_push(&n.types, it->types[q]);
      va_push(&n.texts, (V)it->texts[q + 1]);
    }
    alt_append_text(&n, next);
  } else {
    va_push(&n.pats, 0);
    va_push(&n.types, m);
    va_push(&n.texts, (V)next);
  }
  tpl_alts(pat, i + 1, &n, env, alts);
}

static V cons_of(IC *c, const PatD *p);

// the type to infer from a matched piece for a constrained slot (the
// `choose` of inferToTemplateLiteralType); 0: none
static V choose_for_constraint(Str *str, V cons) {
  if (cons == V_ANY) return 0;
  VA ms;
  members_v(cons, &ms);
  uint32_t all = 0;
  for (uint32_t i = 0; i < ms.n; i++) all |= ty_flags(ms.d[i]);
  if (all & TF_STRING) return 0;
  if ((all & TF_NUMBERLIKE) && !is_valid_number_string(str, true)) all &= ~TF_NUMBERLIKE;
  if ((all & TF_BIGINTLIKE) && !is_valid_bigint_string(str, true)) all &= ~TF_BIGINTLIKE;
  V source = (V)str;
  V left = V_NEVER;
  for (uint32_t i = 0; i < ms.n; i++) {
    V right = ms.d[i];
    uint32_t lf = ty_flags(left), rf = ty_flags(right);
    V r;
    if (!(rf & all)) r = left;
    else if (lf & TF_STRING) r = left;
    else if (rf & TF_STRING) r = source;
    else if (lf & TF_TPL) r = left;
    else if ((rf & TF_TPL) && template_matches(source, right)) r = source;
    else if (lf & TF_STRMAP) r = left;
    else if ((rf & TF_STRMAP) && ty_eq(string_mapping((int)((StrMapT *)right)->mode, source), source)) r = source;
    else if (lf & TF_STRLIT) r = left;
    else if ((rf & TF_STRLIT) && ty_eq(right, source)) r = right;
    else if (lf & TF_NUMBER) r = left;
    else if (rf & TF_NUMBER) r = mk_num(js_to_number(str));
    else if (lf & TF_NUMLIT) r = left;
    else if ((rf & TF_NUMLIT) && num_val(right) == js_to_number(str)) r = right;
    else if (lf & TF_BIGINT) r = left;
    else if (rf & TF_BIGINT) r = mk_bigint_text(str);
    else if (lf & TF_BIGLIT) r = left;
    else if ((rf & TF_BIGLIT) && ty_eq(right, mk_bigint_text(str))) r = right;
    else if (lf & TF_BOOLEAN) r = left;
    else if (rf & TF_BOOLEAN)
      r = str_eq_c(str, "true") ? V_TRUE : str_eq_c(str, "false") ? V_FALSE : mk_union2(V_TRUE, V_FALSE);
    else if (lf & TF_BOOLLIT) r = left;
    else if ((rf & TF_BOOLLIT) && str_eq_c(str, right == V_TRUE ? "true" : "false")) r = right;
    else if (lf & TF_UNDEFINED) r = left;
    else if ((rf & TF_UNDEFINED) && str_eq_c(str, "undefined")) r = right;
    else if (lf & TF_NULL) r = left;
    else if ((rf & TF_NULL) && str_eq_c(str, "null")) r = right;
    else r = left;
    left = r;
  }
  return left == V_NEVER ? 0 : left;
}

// a "boolean" member list is two members: choose sees true and false
// separately as tsgo distributes boolean into its literals

static void infer_tpl(IC *c, V source, const PatD *target) {
  Alt start;
  va_init(&start.texts);
  va_init(&start.pats);
  va_init(&start.types);
  va_push(&start.texts, (V)target->texts[0]);
  VA alts;
  va_init(&alts);
  tpl_alts(target, 0, &start, c->env, &alts);
  for (uint32_t ai = 0; ai < alts.n; ai++) {
    Alt *a = (Alt *)alts.d[ai];
    uint32_t np = a->texts.n - 1;
    TplT tt;
    tt.tag = K_TPL;
    tt.n = np;
    tt.texts = (Str **)a->texts.d;
    // (an infer placeholder: its constraint, as getBaseConstraintOrType)
    V *types = gc_alloc((size_t)(np ? np : 1) * 8);
    for (uint32_t i = 0; i < np; i++) {
      const PatD *tp = (const PatD *)a->pats.d[i];
      V cons = tp && tp->kind == P_INFER ? cons_of(c, tp) : 0;
      types[i] = tp ? (cons ? cons : V_UNKNOWN) : a->types.d[i];
    }
    tt.types = types;
    V matches[np ? np : 1];
    bool ok = infer_from_template(source, &tt, matches, 0);
    bool all_empty = true;
    for (uint32_t i = 0; i <= np && all_empty; i++) all_empty = as_str(a->texts.d[i])->len == 0;
    if (!ok && !all_empty) continue;
    for (uint32_t i = 0; i < np; i++) {
      const PatD *tp = (const PatD *)a->pats.d[i];
      if (!tp) continue;
      V s = ok ? matches[i] : V_NEVER;
      if (kind(s) == K_STRLIT && tp->kind == P_INFER) {
        V cons = cons_of(c, tp);
        if (cons) {
          V m = choose_for_constraint(as_str(s), cons);
          if (m) {
            infer(c, m, tp);
            continue;
          }
        }
      }
      infer(c, s, tp);
    }
  }
}

// ---------------------------------------------------------------------------
// Signatures

// the signature of a function pattern: parameters with kinds (rest last)
static int64_t pfn_kind(const PatD *p, int64_t i) { return p->ekinds ? p->ekinds[i] : E_REQ; }

static bool pfn_has_rest(const PatD *p) { return p->n > 0 && pfn_kind(p, p->n - 1) == E_REST; }

// the target parameter pattern's type at a position: an optional parameter's
// type has undefined (a union pattern with undefined)
static void infer_to_param(IC *c, V s, const PatD *tp, bool optional) {
  if (optional && tp->kind != P_CODE) {
    // inferring to X | undefined: undefined of the source matches undefined
    if (kind(s) == K_UNION) {
      VA rest;
      va_init(&rest);
      bool had = false;
      for (uint32_t i = 0; i < set_n(s); i++)
        if (set_m(s, i) == V_UNDEFINED) had = true;
        else va_push(&rest, set_m(s, i));
      if (had) {
        if (rest.n) infer_contra(c, mk_union(rest.d, rest.n), tp);
        return;
      }
    } else if (s == V_UNDEFINED) {
      int save = c->priority;
      c->priority |= IP_NAKED;
      if (tp->kind == P_INFER) infer_contra(c, s, tp);
      c->priority = save;
      return;
    }
    if (tp->kind == P_INFER) {
      // the naked type variable of the union
      int save = c->priority;
      c->priority |= 0;
      infer_contra(c, s, tp);
      c->priority = save;
      return;
    }
  }
  infer_contra(c, s, tp);
}

static FnT *sig_of(V src) {
  switch (kind(src)) {
  case K_FN: return ((FnT *)src)->ctor ? NULL : (FnT *)src;
  case K_GENFN: {
    V f = instantiate_generic((GenFnT *)src, NULL, 0);
    return kind(f) == K_FN ? (FnT *)f : NULL;
  }
  default: return NULL;
  }
}

// the call signatures of a source (getSignaturesOfType)
static void call_sigs(V src, VA *out) {
  va_init(out);
  switch (kind(src)) {
  case K_FN: case K_GENFN: {
    FnT *f = sig_of(src);
    if (f) va_push(out, (V)f);
    return;
  }
  case K_OBJ: {
    ObjT *o = as_obj(src);
    for (uint32_t i = 0; i < o->nc; i++)
      if (!o->calls[i]->ctor) va_push(out, (V)o->calls[i]);
    return;
  }
  case K_INTER:
    for (uint32_t i = 0; i < set_n(src); i++) {
      VA sub;
      call_sigs(set_m(src, i), &sub);
      for (uint32_t j = 0; j < sub.n; j++) va_push(out, sub.d[j]);
    }
    return;
  default: return;
  }
}

// inferFromSignature (a function type pattern is one call signature)
static void infer_signature(IC *c, FnT *s, const PatD *t) {
  // applyToParameterTypes
  int64_t scount = sig_param_count(s);
  V srest = sig_effective_rest(s);
  bool trest = pfn_has_rest(t);
  int64_t tcount = t->n;
  int64_t t_nonrest = tcount - (trest ? 1 : 0);
  int64_t pc = srest ? t_nonrest : (scount < t_nonrest ? scount : t_nonrest);
  for (int64_t i = 0; i < pc; i++) {
    V st = sig_type_at(s, i);
    if (!st) st = V_ANY;
    infer_to_param(c, st, t->elems[i], pfn_kind(t, i) == E_OPT);
  }
  if (trest) {
    const PatD *rp = t->elems[t->n - 1];
    V st = sig_rest_type_at(s, pc, false);
    // a rest parameter's pattern: an array pattern or infer
    infer_contra(c, st, rp);
  }
  // applyToReturnTypes
  if (t->sub->kind != P_CODE) infer(c, s->ret, t->sub);
}

// ---------------------------------------------------------------------------
// Objects

// getUnmatchedProperty(source, target pattern, matchDiscriminants)
static bool unmatched_in_source(V source, const PatD *t, V *env) {
  for (int64_t i = 0; i < t->n; i++) {
    if (t->opts[i]) continue;
    PInfo p;
    if (!member_prop(source, t->names[i], &p)) return true;
    const PatD *tp = t->elems[i];
    if (tp->kind == P_CODE) {
      V tv = pcode(tp, env);
      if (ty_flags(tv) & TF_UNIT) {
        if (!(p.ty == V_ANY || ty_eq(p.ty, tv))) return true;
      }
    }
  }
  return false;
}

static bool pat_has_prop(const void *pat, Str *name) {
  const PatD *t = pat;
  for (int64_t i = 0; i < t->n; i++)
    if (str_eq(t->names[i], name)) return true;
  return false;
}

// getUnmatchedProperty(target pattern, source)
static bool unmatched_in_target(V source, const PatD *t) {
  return required_member_not_in(source, pat_has_prop, t);
}

static void infer_obj_props(IC *c, V source, const PatD *t) {
  if (unmatched_in_source(source, t, c->env) && unmatched_in_target(source, t)) return;
  for (int64_t i = 0; i < t->n; i++) {
    PInfo p;
    if (!member_prop(source, t->names[i], &p)) continue;
    const PatD *tp = t->elems[i];
    if (t->opts[i] && tp->kind != P_CODE) {
      // the target property's type is X | undefined
      V s = p.ty;
      if (kind(s) == K_UNION) {
        VA rest;
        va_init(&rest);
        bool had = false;
        for (uint32_t j = 0; j < set_n(s); j++)
          if (set_m(s, j) == V_UNDEFINED) had = true;
          else va_push(&rest, set_m(s, j));
        if (had) {
          if (rest.n) infer(c, mk_union(rest.d, rest.n), tp);
          continue;
        }
      } else if (s == V_UNDEFINED) {
        if (tp->kind == P_INFER) infer_with_priority(c, s, tp, IP_NAKED);
        continue;
      }
    }
    infer(c, p.ty, tp);
  }
}

// ---------------------------------------------------------------------------

static void infer_union_target(IC *c, V source, const PatD *target) {
  // inferFromMatchingTypes: identical (or literal and base) source and
  // known target constituents are removed
  VA sources;
  members_v(source, &sources);
  if (source == V_NEVER) va_init(&sources);
  VA targets;  // const PatD *
  va_init(&targets);
  for (int64_t i = 0; i < target->n; i++) {
    const PatD *p = target->elems[i];
    if (p->kind == P_CODE) {
      VA ms;
      members_v(pcode(p, c->env), &ms);
      for (uint32_t j = 0; j < ms.n; j++) va_push(&targets, (V)code_pat(ms.d[j]));
    } else {
      va_push(&targets, (V)p);
    }
  }
  bool smatched[sources.n ? sources.n : 1];
  bool tmatched[targets.n ? targets.n : 1];
  memset(smatched, 0, sizeof smatched);
  memset(tmatched, 0, sizeof tmatched);
  for (uint32_t ti = 0; ti < targets.n; ti++) {
    const PatD *tp = (const PatD *)targets.d[ti];
    if (tp->kind != P_CODE) continue;
    V t = tp->cval;
    for (uint32_t si = 0; si < sources.n; si++) {
      V s = sources.d[si];
      if (ty_identical(s, t) || (t == V_STRING && kind(s) == K_STRLIT) || (t == V_NUMBER && kind(s) == K_NUMLIT)) {
        smatched[si] = true;
        tmatched[ti] = true;
      }
    }
  }
  VA rs, rt;
  va_init(&rs);
  va_init(&rt);
  for (uint32_t si = 0; si < sources.n; si++)
    if (!smatched[si]) va_push(&rs, sources.d[si]);
  for (uint32_t ti = 0; ti < targets.n; ti++)
    if (!tmatched[ti]) va_push(&rt, targets.d[ti]);
  // closely matched: arrays and array patterns
  bool rsm[rs.n ? rs.n : 1];
  bool rtm[rt.n ? rt.n : 1];
  memset(rsm, 0, sizeof rsm);
  memset(rtm, 0, sizeof rtm);
  for (uint32_t ti = 0; ti < rt.n; ti++) {
    const PatD *tp = (const PatD *)rt.d[ti];
    if (tp->kind != P_ARRAY) continue;
    for (uint32_t si = 0; si < rs.n; si++) {
      V s = rs.d[si];
      if (kind(s) == K_ARRAY && ((ArrT *)s)->ro == (bool)tp->ro) {
        infer(c, s, tp);
        rsm[si] = true;
        rtm[ti] = true;
      }
    }
  }
  VA src2, tgt2;
  va_init(&src2);
  va_init(&tgt2);
  for (uint32_t si = 0; si < rs.n; si++)
    if (!rsm[si]) va_push(&src2, rs.d[si]);
  for (uint32_t ti = 0; ti < rt.n; ti++)
    if (!rtm[ti]) va_push(&tgt2, rt.d[ti]);
  if (tgt2.n == 0) return;
  if (src2.n == 0) {
    // all matched: a lower priority inference from the whole source
    int save = c->priority;
    c->priority |= IP_NAKED;
    for (uint32_t ti = 0; ti < tgt2.n; ti++) {
      const PatD *tp = (const PatD *)tgt2.d[ti];
      if (tp->kind == P_INFER) infer(c, source, tp);
    }
    // (non-naked targets get the whole source too, as inferToMultipleTypes)
    for (uint32_t ti = 0; ti < tgt2.n; ti++) {
      const PatD *tp = (const PatD *)tgt2.d[ti];
      if (tp->kind != P_INFER && tp->kind != P_CODE) infer(c, source, tp);
    }
    c->priority = save;
    return;
  }
  V src = mk_union(src2.d, src2.n);
  // inferToMultipleTypes (union target)
  VA srcs;
  members_v(src, &srcs);
  bool matched[srcs.n ? srcs.n : 1];
  memset(matched, 0, sizeof matched);
  const PatD *naked = NULL;
  uint32_t nvars = 0;
  for (uint32_t ti = 0; ti < tgt2.n; ti++) {
    const PatD *tp = (const PatD *)tgt2.d[ti];
    if (tp->kind == P_INFER) {
      naked = tp;
      nvars++;
    } else if (tp->kind != P_CODE) {
      for (uint32_t si = 0; si < srcs.n; si++) {
        int save = c->inf_priority;
        c->inf_priority = IP_MAX;
        infer(c, srcs.d[si], tp);
        if (c->inf_priority == c->priority) matched[si] = true;
        if (save < c->inf_priority) c->inf_priority = save;
      }
    }
  }
  if (nvars == 0) return;
  if (nvars == 1) {
    VA unmatched;
    va_init(&unmatched);
    for (uint32_t si = 0; si < srcs.n; si++)
      if (!matched[si]) va_push(&unmatched, srcs.d[si]);
    if (unmatched.n) {
      infer(c, mk_union(unmatched.d, unmatched.n), naked);
      return;
    }
  }
  int save = c->priority;
  c->priority |= IP_NAKED;
  for (uint32_t ti = 0; ti < tgt2.n; ti++) {
    const PatD *tp = (const PatD *)tgt2.d[ti];
    if (tp->kind == P_INFER) infer(c, src, tp);
  }
  c->priority = save;
}

// ---------------------------------------------------------------------------
// Types with `infer` declarations that are no patterns (P_VAL): the type
// with type parameters (markers) for the slots, as a pattern of its own

static bool has_marker(V t, int depth) {
  if ((t & 3) || depth > 32) return false;
  switch (kind(t)) {
  case K_USYM: return ((USymT *)t)->id < 0;
  case K_UNION:
  case K_INTER:
    for (uint32_t i = 0; i < set_n(t); i++)
      if (has_marker(set_m(t, i), depth + 1)) return true;
    return false;
  case K_TUPLE: {
    TupT *x = as_tup(t);
    V u = tup_uni(x);
    if (u) return has_marker(u, depth + 1);
    for (uint32_t i = 0; i < x->len; i++)
      if (has_marker(x->e[i], depth + 1)) return true;
    return false;
  }
  case K_ARRAY: return has_marker(((ArrT *)t)->el, depth + 1);
  case K_TPL: {
    TplT *x = (TplT *)t;
    for (uint32_t i = 0; i < x->n; i++)
      if (has_marker(x->types[i], depth + 1)) return true;
    return false;
  }
  case K_STRMAP: return has_marker(((StrMapT *)t)->t, depth + 1);
  case K_SUBST: return has_marker(((SubstT *)t)->base, depth + 1);
  case K_DEFERRED: {
    DefT *d = (DefT *)t;
    return has_marker(d->c, depth + 1) || has_marker(d->e, depth + 1) || has_marker(d->t, depth + 1) ||
           has_marker(d->f, depth + 1);
  }
  case K_FN: {
    FnT *f = (FnT *)t;
    for (uint32_t i = 0; i < f->np; i++)
      if (has_marker(f->params[i].ty, depth + 1)) return true;
    return has_marker(f->ret, depth + 1);
  }
  case K_OBJ: {
    ObjT *o = as_obj(t);
    for (uint32_t i = 0; i < o->np; i++)
      if (has_marker(prop_value(&o->props[i]), depth + 1)) return true;
    for (uint32_t i = 0; i < o->ni; i++)
      if (has_marker(o->index[i].key, depth + 1) || has_marker(o->index[i].ty, depth + 1)) return true;
    for (uint32_t i = 0; i < o->nc; i++)
      if (has_marker((V)o->calls[i], depth + 1)) return true;
    return false;
  }
  default: return false;
  }
}

typedef struct {
  const V *marks;
  const PatD *const *slots;  // the P_INFER of each marker
  int64_t n;
} ValPat;

static PatD *pat_new(int64_t kind, int64_t n) {
  PatD *p = gc_alloc(sizeof(PatD));
  p->kind = kind;
  p->n = n;
  if (n) p->elems = gc_alloc((size_t)n * 8);
  return p;
}

static const PatD *value_pat(const ValPat *vp, V t, int depth) {
  for (int64_t i = 0; i < vp->n; i++)
    if (vp->marks[i] == t) return vp->slots[i];
  if (depth > 32 || !has_marker(t, 0)) return code_pat(t);
  switch (kind(t)) {
  case K_SUBST: return value_pat(vp, ((SubstT *)t)->base, depth + 1);
  case K_UNION:
  case K_INTER: {
    PatD *p = pat_new(kind(t) == K_UNION ? P_UNION : P_INTER, set_n(t));
    for (uint32_t i = 0; i < set_n(t); i++) ((const PatD **)p->elems)[i] = value_pat(vp, set_m(t, i), depth + 1);
    return p;
  }
  case K_DEFERRED: {
    // inferToConditionalType: to both branches
    PatD *p = pat_new(P_INTER, 2);
    ((const PatD **)p->elems)[0] = value_pat(vp, ((DefT *)t)->t, depth + 1);
    ((const PatD **)p->elems)[1] = value_pat(vp, ((DefT *)t)->f, depth + 1);
    return p;
  }
  case K_TUPLE: {
    TupT *x = as_tup(t);
    PatD *p = pat_new(P_TUPLE, x->len);
    int64_t *ks = gc_alloc_atomic((size_t)(x->len ? x->len : 1) * 8);
    V u = tup_uni(x);
    for (uint32_t i = 0; i < x->len; i++) {
      V e = u ? u : x->e[i];
      int k = tup_kind(x, i);
      const PatD *ep = value_pat(vp, e, depth + 1);
      if (k == E_REST) {
        // (a rest element `...T[]`: a spread of an array pattern)
        PatD *a = pat_new(P_ARRAY, 0);
        a->sub = ep;
        ep = a;
      }
      ((const PatD **)p->elems)[i] = ep;
      ks[i] = k;
    }
    p->ekinds = ks;
    p->ro = tup_ro(x);
    return p;
  }
  case K_ARRAY: {
    PatD *p = pat_new(P_ARRAY, 0);
    p->sub = value_pat(vp, ((ArrT *)t)->el, depth + 1);
    p->ro = ((ArrT *)t)->ro;
    return p;
  }
  case K_TPL: {
    TplT *x = (TplT *)t;
    PatD *p = pat_new(P_TPL, x->n);
    for (uint32_t i = 0; i < x->n; i++) ((const PatD **)p->elems)[i] = value_pat(vp, x->types[i], depth + 1);
    p->texts = x->texts;
    return p;
  }
  case K_FN: {
    FnT *f = (FnT *)t;
    PatD *p = pat_new(P_FN, f->np);
    int64_t *ks = gc_alloc_atomic((size_t)(f->np ? f->np : 1) * 8);
    for (uint32_t i = 0; i < f->np; i++) {
      ((const PatD **)p->elems)[i] = value_pat(vp, f->params[i].ty, depth + 1);
      ks[i] = f->params[i].rest ? E_REST : f->params[i].opt ? E_OPT : E_REQ;
    }
    p->ekinds = ks;
    p->sub = value_pat(vp, f->ret, depth + 1);
    return p;
  }
  case K_OBJ: {
    ObjT *o = as_obj(t);
    if (o->ni || o->nc) return code_pat(t);
    PatD *p = pat_new(P_OBJ, o->np);
    Str **ns = gc_alloc((size_t)(o->np ? o->np : 1) * 8);
    int64_t *os = gc_alloc_atomic((size_t)(o->np ? o->np : 1) * 8);
    for (uint32_t i = 0; i < o->np; i++) {
      Prop *pr = &o->props[i];
      // (an optional property's declared type, without the undefined added)
      V pt = prop_value(pr);
      ((const PatD **)p->elems)[i] = value_pat(vp, pr->opt ? remove_undefined(pt) : pt, depth + 1);
      ns[i] = pr->name;
      os[i] = pr->opt;
    }
    p->names = ns;
    p->opts = os;
    return p;
  }
  default: return code_pat(t);
  }
}

static int64_t val_marker_next = -((int64_t)1 << 40);

static void infer_val(IC *c, V source, const PatD *target) {
  int64_t n = target->n;
  V marks[n ? n : 1], saved[n ? n : 1];
  for (int64_t i = 0; i < n; i++) {
    int64_t slot = target->elems[i]->slot;
    marks[i] = 0;
    for (int64_t j = 0; j < i; j++)
      if (target->elems[j]->slot == slot) marks[i] = marks[j];
    if (!marks[i]) marks[i] = mk_usym(val_marker_next--);
    saved[i] = c->env[slot];
  }
  for (int64_t i = 0; i < n; i++) c->env[target->elems[i]->slot] = marks[i];
  V t = call_thunk(target->code, c->env);
  for (int64_t i = n; i > 0; i--) c->env[target->elems[i - 1]->slot] = saved[i - 1];
  ValPat vp = {marks, target->elems, n};
  infer(c, source, value_pat(&vp, t, 0));
}

// inferFromTypes
static void infer(IC *c, V source, const PatD *target) {
  switch (target->kind) {
  case P_CODE: return;
  case P_INFER: infer_to_var(c, source, target->slot); return;
  case P_UNION: infer_union_target(c, source, target); return;
  case P_VAL: infer_val(c, source, target); return;
  case P_INTER:
    // inferToMultipleTypes of an intersection (or both branches of a
    // conditional type)
    for (int64_t i = 0; i < target->n; i++) infer(c, source, target->elems[i]);
    return;
  default: break;
  }
  int ks = kind(source);
  if (ks == K_SUBST) {
    // (from the base)
    infer(c, ((SubstT *)source)->base, target);
    return;
  }
  if (ks == K_UNION) {
    for (uint32_t i = 0; i < set_n(source); i++) infer(c, set_m(source, i), target);
    return;
  }
  if (target->kind == P_TPL) {
    infer_tpl(c, source, target);
    return;
  }
  source = reduced_type(source);
  ks = kind(source);
  // the apparent type of a primitive: its interface's members
  uint32_t f = ty_flags(source);
  if (!(f & (TF_OBJECT | TF_INTER | TF_PRIMITIVE))) return;
  if ((f & TF_PRIMITIVE) && target->kind != P_OBJ) {
    // (String's members are no array, tuple or signature)
    return;
  }
  switch (target->kind) {
  case P_TUPLE:
    if (ks == K_TUPLE || ks == K_ARRAY) infer_tuple(c, source, target);
    else if (ks == K_INTER) {
      // (properties of an intersection: its members)
      for (uint32_t i = 0; i < set_n(source); i++) {
        int k = kind(set_m(source, i));
        if (k == K_TUPLE || k == K_ARRAY) infer_tuple(c, set_m(source, i), target);
      }
    }
    return;
  case P_ARRAY:
    if (ks == K_ARRAY) {
      infer(c, ((ArrT *)source)->el, target->sub);
    } else if (ks == K_TUPLE) {
      // inferFromIndexTypes: the number index type
      infer(c, tuple_elem_union(as_tup(source)), target->sub);
    } else if (ks == K_INTER) {
      // (the members' methods and index signatures: candidates of each)
      for (uint32_t i = 0; i < set_n(source); i++) infer(c, set_m(source, i), target);
    } else if (ks == K_OBJ) {
      // inferFromIndexTypes: an object type literal's numeric properties,
      // then the applicable index signature
      Members m;
      members_of(source, &m);
      bool inferable = ks == K_OBJ && as_obj(source)->nc == 0 && !(as_obj(source)->aux & OBJ_IFACE);
      if (ks == K_INTER) {
        inferable = true;
        for (uint32_t i = 0; i < set_n(source) && inferable; i++) {
          V x = set_m(source, i);
          inferable = kind(x) == K_OBJ && as_obj(x)->nc == 0 && !(as_obj(x)->aux & OBJ_IFACE);
        }
      }
      if (inferable) {
        VA tys;
        va_init(&tys);
        for (uint32_t i = 0; i < m.np; i++) {
          double d;
          if (m.p[i].name && parse_canonical_number(m.p[i].name, &d))
            va_push(&tys, m.p[i].opt ? remove_undefined(m.p[i].ty) : m.p[i].ty);
        }
        for (uint32_t i = 0; i < m.ni; i++)
          if (is_assignable(m.ix[i].key, V_NUMBER) || m.ix[i].key == V_STRING) va_push(&tys, m.ix[i].ty);
        if (tys.n) infer(c, mk_union(tys.d, tys.n), target->sub);
      }
      for (uint32_t i = 0; i < m.ni; i++)
        if (m.ix[i].key == V_NUMBER) {
          infer(c, m.ix[i].ty, target->sub);
          return;
        }
      for (uint32_t i = 0; i < m.ni; i++)
        if (m.ix[i].key == V_STRING) {
          infer(c, m.ix[i].ty, target->sub);
          return;
        }
    }
    return;
  case P_OBJ:
    infer_obj_props(c, source, target);
    return;
  case P_FN: {
    VA sigs;
    call_sigs(source, &sigs);
    if (!sigs.n) return;
    // the last source signature against the (single) target signature
    infer_signature(c, (FnT *)sigs.d[sigs.n - 1], target);
    return;
  }
  default: return;
  }
}

// ---------------------------------------------------------------------------
// Constraints of slots

static void collect_infs(const PatD *p, IC *c, int ctx) {
  // ctx: 1 in a rest position, 2 in a template placeholder
  switch (p->kind) {
  case P_INFER: {
    Inf *inf = inf_of(c, p->slot);
    if (!inf) return;
    if (p->code && !inf->cons_pat) inf->cons_pat = p;
    if (ctx == 1) va_push(&inf->implied, mk_array(V_UNKNOWN, false));
    else if (ctx == 2) va_push(&inf->implied, V_STRING);
    return;
  }
  case P_CODE: return;
  case P_ARRAY: collect_infs(p->sub, c, 0); return;
  case P_TUPLE:
    for (int64_t i = 0; i < p->n; i++) collect_infs(p->elems[i], c, p->ekinds[i] == E_REST ? 1 : 0);
    return;
  case P_TPL:
    for (int64_t i = 0; i < p->n; i++) collect_infs(p->elems[i], c, 2);
    return;
  case P_FN:
    for (int64_t i = 0; i < p->n; i++) collect_infs(p->elems[i], c, pfn_kind(p, i) == E_REST ? 1 : 0);
    collect_infs(p->sub, c, 0);
    return;
  case P_VAL:
    for (int64_t i = 0; i < p->n; i++) collect_infs(p->elems[i], c, (int)p->ekinds[i]);
    return;
  default:
    for (int64_t i = 0; i < p->n; i++) collect_infs(p->elems[i], c, 0);
  }
}

// the constraint of a slot (0: none)
static V cons_of(IC *c, const PatD *p) {
  Inf *inf = inf_of(c, p->slot);
  if (!inf) return p->code ? call_thunk(p->code, c->env) : 0;
  if (inf->cons_pat) return call_thunk(inf->cons_pat->code, c->env);
  if (inf->implied.n == 1) return inf->implied.d[0];
  if (inf->implied.n > 1) return mk_inter(inf->implied.d, inf->implied.n);
  return 0;
}

// getUnionType(candidates, UnionReductionSubtype)
V union_subtype(V *items, uint32_t n) {
  // (a single candidate is the type as it is)
  if (n == 1) return items[0];
  V u = mk_union(items, n);
  if (kind(u) != K_UNION) return u;
  VA ts;
  va_init(&ts);
  bool has_void = false;
  for (uint32_t i = 0; i < set_n(u); i++)
    if (set_m(u, i) == V_VOID) has_void = true;
  for (uint32_t i = 0; i < set_n(u); i++)
    if (!(has_void && set_m(u, i) == V_UNDEFINED)) va_push(&ts, set_m(u, i));
  bool has_empty = false;
  for (uint32_t i = 0; i < ts.n; i++) {
    V t = ts.d[i];
    if (kind(t) == K_OBJ && as_obj(t)->np == 0 && as_obj(t)->ni == 0 && as_obj(t)->nc == 0) has_empty = true;
  }
  // removeSubtypes
  for (uint32_t i = ts.n; i > 0; i--) {
    V s = ts.d[i - 1];
    if (!has_empty && !(ty_flags(s) & (TF_STRUCTURED | TF_INSTANTIABLE))) continue;
    for (uint32_t j = 0; j < ts.n; j++) {
      V t = ts.d[j];
      if (t == s) continue;
      if (is_subtype(s, t)) {
        memmove(ts.d + i - 1, ts.d + i, (size_t)(ts.n - i) * 8);
        ts.n--;
        break;
      }
    }
  }
  return mk_union(ts.d, ts.n);
}

// ---------------------------------------------------------------------------
// Fast paths: a plain tuple against a tuple pattern of infers, types,
// spreads of fixed tuples and tuple patterns (`[infer H, ...infer R]`,
// `[...N, ...infer R]`, `[["id", infer N], ...infer R]`),
// and a string literal against a template of infers (`${infer C}${infer R}`),
// bind the slots directly. -1: not such a case, otherwise as rt_decide.

enum { FI_INFER, FI_VAL, FI_SPREAD, FI_REST, FI_SUB };
typedef struct { int kind; const PatD *p; TupT *sp; } FItem;

// (seen holds up to 64 slots)
static bool fast_slot_new(int64_t *seen, int *ns, int64_t slot) {
  if (*ns >= 64) return false;
  for (int i = 0; i < *ns; i++)
    if (seen[i] == slot) return false;
  seen[(*ns)++] = slot;
  return true;
}

static inline bool elem_ok(V s, V t) { return s == t || is_assignable(s, t); }

// a phase of matching t against pat: 0 lays the items out, checks lengths
// and spreads and binds the slots; 1 checks the types and the constraints
// (which may read slots bound anywhere in the pattern). Elements that are
// tuple patterns themselves are matched the same way (seen: the slots of the
// whole pattern, each bound once).
static int64_t fast_tuple_phase(TupT *t, const PatD *pat, V *env, int64_t *seen, int *ns, int phase) {
  int64_t np = pat->n;
  if (np > 16) return -1;
  int fixed = tup_fixed_len(t);
  if (fixed < 0) return -1;
  if (tup_ro(t) && !pat->ro) return 1;
  FItem it[16];
  int64_t rest_at = -1, need = 0;
  for (int64_t i = 0; i < np; i++) {
    const PatD *e = pat->elems[i];
    int64_t k = pat->ekinds[i];
    it[i].p = e;
    it[i].sp = NULL;
    if (k == E_OPT) return -1;
    if (k == E_REST) {
      if (e->kind == P_INFER) {
        if (rest_at >= 0 || (phase == 0 && !fast_slot_new(seen, ns, e->slot))) return -1;
        it[i].kind = FI_REST;
        rest_at = i;
      } else if (e->kind == P_CODE) {
        V v = pcode(e, env);
        if (kind(v) != K_TUPLE || tup_fixed_len(as_tup(v)) < 0) return -1;
        it[i].kind = FI_SPREAD;
        it[i].sp = as_tup(v);
        need += as_tup(v)->len;
      } else {
        return -1;
      }
    } else if (e->kind == P_INFER) {
      if (phase == 0 && !fast_slot_new(seen, ns, e->slot)) return -1;
      it[i].kind = FI_INFER;
      need++;
    } else if (e->kind == P_CODE) {
      it[i].kind = FI_VAL;
      need++;
    } else if (e->kind == P_TUPLE) {
      it[i].kind = FI_SUB;
      need++;
    } else {
      return -1;
    }
  }
  int64_t n = fixed;
  if (rest_at < 0 ? n != need : n < need) return 1;
  // positions: the items before the rest from the start, the others from
  // the end
  int64_t pos[16];
  int64_t p = 0;
  int64_t stop = rest_at < 0 ? np : rest_at;
  for (int64_t i = 0; i < stop; i++) {
    pos[i] = p;
    p += it[i].kind == FI_SPREAD ? it[i].sp->len : 1;
  }
  int64_t rest_from = p;
  if (rest_at >= 0) {
    p = n;
    for (int64_t i = np - 1; i > rest_at; i--) {
      p -= it[i].kind == FI_SPREAD ? it[i].sp->len : 1;
      pos[i] = p;
    }
    pos[rest_at] = rest_from;
  }
  if (phase == 0) {
    // spreads first (their elements are known), then the bindings
    for (int64_t i = 0; i < np; i++) {
      if (it[i].kind != FI_SPREAD) continue;
      TupT *sp = it[i].sp;
      const V *src = t->e + pos[i];
      V tu = tup_uni(t), su = tup_uni(sp);
      if (tu && su) {
        if (!elem_ok(tu, su)) return 1;
      } else if (src != sp->e)
        for (uint32_t j = 0; j < sp->len; j++)
          if (!elem_ok(src[j], sp->e[j])) return 1;
    }
    for (int64_t i = 0; i < np; i++) {
      if (it[i].kind == FI_INFER) env[it[i].p->slot] = t->e[pos[i]];
      else if (it[i].kind == FI_REST) env[it[i].p->slot] = tup_slice(t, (uint32_t)rest_from, (uint32_t)p);
      else if (it[i].kind == FI_SUB) {
        // (an element that is no tuple: the general case decides)
        V v = t->e[pos[i]];
        if ((v & 3) || kind(v) != K_TUPLE) return -1;
        int64_t r = fast_tuple_phase(as_tup(v), it[i].p, env, seen, ns, 0);
        if (r != 0) return r;
      }
    }
    return 0;
  }
  // then the types (which may read the slots), then the constraints
  for (int64_t i = 0; i < np; i++) {
    if (it[i].kind == FI_VAL && !elem_ok(t->e[pos[i]], pcode(it[i].p, env))) return 1;
    if (it[i].kind == FI_SUB) {
      int64_t r = fast_tuple_phase(as_tup(t->e[pos[i]]), it[i].p, env, seen, ns, 1);
      if (r != 0) return r;
    }
  }
  for (int64_t i = 0; i < np; i++) {
    const PatD *e = it[i].p;
    if ((it[i].kind == FI_INFER || it[i].kind == FI_REST) && e->code &&
        !is_assignable(env[e->slot], call_thunk(e->code, env)))
      return 1;
  }
  return 0;
}

static int64_t fast_tuple(TupT *t, const PatD *pat, V *env) {
  int64_t seen[64];
  int ns = 0;
  int64_t r = fast_tuple_phase(t, pat, env, seen, &ns, 0);
  return r != 0 ? r : fast_tuple_phase(t, pat, env, seen, &ns, 1);
}

bool match_template(Str *s, Str **texts, uint32_t ntexts, Str **pieces);

static int64_t fast_tpl(Str *s, const PatD *pat, V *env) {
  int64_t np = pat->n;
  if (np > 16) return -1;
  int64_t seen[16];
  int ns = 0;
  for (int64_t i = 0; i < np; i++) {
    const PatD *e = pat->elems[i];
    if (e->kind != P_INFER || !fast_slot_new(seen, &ns, e->slot)) return -1;
  }
  Str *pieces[17];
  if (!match_template(s, (Str **)pat->texts, (uint32_t)np + 1, pieces)) {
    // no match: every placeholder infers never when all texts are empty,
    // which fails the check too
    return 1;
  }
  for (int64_t i = 0; i < np; i++) {
    const PatD *e = pat->elems[i];
    if (!e->code) {
      env[e->slot] = (V)pieces[i];
    } else {
      V cons = call_thunk(e->code, env);
      V m = choose_for_constraint(pieces[i], cons);
      V v = m ? m : (V)pieces[i];
      // (the constraint instead: the general case decides)
      if (!is_assignable(v, cons)) return -1;
      // (the inferred type must give the piece back in the template)
      Str *back;
      if (!lit_to_str(v, &back) || !str_eq(back, pieces[i])) return -1;
      env[e->slot] = v;
    }
  }
  return 0;
}

// an object against `{ a: infer A; b: infer B }` (required properties,
// distinct slots, no constraints): the slots are the properties' types and
// the check holds when the object has them (required)
static int64_t fast_obj(ObjT *o, const PatD *pat, V *env) {
  int64_t np = pat->n;
  if (np > 16) return -1;
  int64_t seen[16];
  int ns = 0;
  for (int64_t i = 0; i < np; i++) {
    const PatD *e = pat->elems[i];
    if (e->kind != P_INFER || e->code || pat->opts[i] || !fast_slot_new(seen, &ns, e->slot)) return -1;
  }
  Prop *ps[16];
  for (int64_t i = 0; i < np; i++) {
    ps[i] = obj_get(o, pat->names[i]);
    if (!ps[i] || ps[i]->opt) return 1;
  }
  for (int64_t i = 0; i < np; i++) {
    env[pat->elems[i]->slot] = prop_value(ps[i]);
  }
  return 0;
}

// a tuple against an object pattern one of whose required properties the
// tuple does not have (`R extends { tstst_panic: infer V; ... }` of a
// return value): not assignable, whatever is inferred
static int64_t fast_tuple_obj(V t, const PatD *pat) {
  for (int64_t i = 0; i < pat->n; i++) {
    PInfo p;
    if (!pat->opts[i] && !member_prop(t, pat->names[i], &p)) return 1;
  }
  return -1;
}

static int64_t fast_decide(V checkv, const PatD *pat, V *env) {
  if (checkv & 3) return -1;
  int k = kind(checkv);
  if (pat->kind == P_OBJ && k == K_OBJ) return fast_obj(as_obj(checkv), pat, env);
  if (pat->kind == P_OBJ && k == K_TUPLE) return fast_tuple_obj(checkv, pat);
  if (pat->kind == P_TUPLE && k == K_TUPLE) return fast_tuple(as_tup(checkv), pat, env);
  if (pat->kind == P_TPL && k == K_STRLIT) return fast_tpl(as_str(checkv), pat, env);
  return -1;
}

// TypeScript's inferFromLiteralPartsToTemplateLiteral for a single source
// string: the n-1 pieces between the texts (one character for an empty text)
bool match_template(Str *s, Str **texts, uint32_t ntexts, Str **pieces) {
  uint32_t last = ntexts - 1;
  Str *start = texts[0], *end = texts[last];
  if (s->len < start->len + end->len || !str_starts(s, start) || !str_ends(s, end)) return false;
  int32_t limit = s->len - end->len;
  int32_t pos = start->len;
  uint32_t k = 0;
  const uint16_t *d = str_d(s);
  for (uint32_t i = 1; i < last; i++) {
    Str *delim = texts[i];
    if (delim->len > 0) {
      int32_t p = str_index(s, delim, pos, limit);
      if (p < 0) return false;
      pieces[k++] = str_slice(s, pos, p);
      pos = p + delim->len;
    } else if (pos < limit) {
      int32_t size = (pos + 1 < limit && d[pos] >= 0xD800 && d[pos] <= 0xDBFF && d[pos + 1] >= 0xDC00 && d[pos + 1] <= 0xDFFF) ? 2 : 1;
      pieces[k++] = str_slice(s, pos, pos + size);
      pos += size;
    } else {
      return false;
    }
  }
  pieces[k] = str_slice(s, pos, limit);
  return true;
}

static V ext_of(const CondD *d, V *env) {
  if (d->ext) return call_thunk(d->ext, env);
  if (d->ext_cval) return d->ext_cval;
  // `X extends [infer A, infer B]` (passed without its extends type): the
  // tuple of the bound slots
  if (d->pat && d->pat->kind == P_TUPLE) {
    TupT *t = tup_alloc((uint32_t)d->pat->n);
    for (int64_t i = 0; i < d->pat->n; i++) t->e[i] = env[d->pat->elems[i]->slot];
    return (V)t;
  }
  return V_UNKNOWN;
}
static V t_of(const CondD *d, V *env) { return d->t ? call_thunk(d->t, env) : d->t_cval; }
static V f_of(const CondD *d, V *env) { return d->f ? call_thunk(d->f, env) : d->f_cval; }

// the branch for a check type and the extends type (with inferences)
static int64_t decide_with(const CondD *d, V checkv, V ext, V *env, V *out) {
  if (ext == V_ANY || ext == V_UNKNOWN) return 0;
  if (checkv == V_ANY) {
    // both branches; in the true one the check type is a substitution type
    // constrained by the extends type: any unless that is never (to which
    // any is not assignable): then never & any, never
    V t;
    if (ext == V_NEVER && d->dist_slot >= 0) {
      V save = env[d->dist_slot];
      env[d->dist_slot] = V_NEVER;
      t = t_of(d, env);
      env[d->dist_slot] = save;
    } else {
      t = t_of(d, env);
    }
    V f = f_of(d, env);
    *out = mk_union2(t, f);
    return 2;
  }
  return is_assignable(checkv, ext) ? 0 : 1;
}

int64_t rt_decide(const CondD *d, V checkv, V *env, V *out) {
  if (is_marker(checkv)) {
    for (int64_t i = 0; i < d->ninfer; i++) env[d->infer_slots[i]] = V_UNKNOWN;
    V ext = d->pat ? V_UNKNOWN : ext_of(d, env);
    V t = t_of(d, env);
    V f = f_of(d, env);
    *out = mk_deferred(checkv, ext, t, f);
    return 2;
  }
  if (!d->pat) return decide_with(d, checkv, ext_of(d, env), env, out);
  const PatD *pat = d->pat;
  // `X extends infer V ? ... : ...`
  if (pat->kind == P_INFER && !pat->code) {
    env[pat->slot] = checkv;
    return 0;
  }
  int64_t fr = fast_decide(checkv, pat, env);
  if (fr >= 0) return fr;
  // inferTypes, then getInferredType for each slot
  IC c;
  memset(&c, 0, sizeof c);
  c.n = (uint32_t)d->ninfer;
  c.infs = gc_alloc((size_t)(c.n ? c.n : 1) * sizeof(Inf));
  for (uint32_t i = 0; i < c.n; i++) {
    c.infs[i].slot = d->infer_slots[i];
    c.infs[i].priority = IP_MAX;
    env[d->infer_slots[i]] = V_UNKNOWN;
  }
  c.priority = IP_NO_CONSTRAINTS | IP_ALWAYS_STRICT;
  c.inf_priority = IP_MAX;
  c.env = env;
  collect_infs(pat, &c, 0);
  infer(&c, checkv, pat);
  V inferred[c.n ? c.n : 1];
  for (uint32_t i = 0; i < c.n; i++) {
    Inf *inf = &c.infs[i];
    V v = 0;
    if (inf->cands.n) v = union_subtype(inf->cands.d, inf->cands.n);
    else if (inf->contra.n) v = mk_inter(inf->contra.d, inf->contra.n);
    inferred[i] = v;
    env[inf->slot] = v ? v : V_UNKNOWN;
  }
  for (uint32_t i = 0; i < c.n; i++) {
    Inf *inf = &c.infs[i];
    PatD fake;
    memset(&fake, 0, sizeof fake);
    fake.kind = P_INFER;
    fake.slot = inf->slot;
    V cons = cons_of(&c, &fake);
    if (!cons) continue;
    V v = inferred[i];
    if (v && !is_assignable(v, cons)) v = 0;
    env[inf->slot] = v ? v : cons;
  }
  return decide_with(d, checkv, ext_of(d, env), env, out);
}

V rt_distribute(const CondD *d, V checkv, V *env) {
  if (checkv == V_NEVER) return V_NEVER;
  SetT *u = (SetT *)checkv;
  V *rs = gc_alloc((size_t)u->n * 8);
  for (uint32_t i = 0; i < u->n; i++) {
    // a frame of its own, owned by the conditional
    V *e2 = tstc_top;
    memcpy(e2, env, (size_t)d->frame * 8);
    e2[d->dist_slot] = u->m[i];
    tstc_top = e2 + d->frame;
    rs[i] = pair_v(d->whole(e2));
    tstc_top = e2;
  }
  return mk_union(rs, u->n);
}

int64_t rt_cond(const CondD *d, V checkv, V *env, V *out) {
  if (d->dist_slot >= 0) {
    int k = kind(checkv);
    if (k == K_INTER || k == K_UNION) checkv = reduced_type(checkv);
    if (checkv == V_NEVER || kind(checkv) == K_UNION) {
      *out = rt_distribute(d, checkv, env);
      return 2;
    }
    if (k == K_INTER) env[d->dist_slot] = checkv;
  }
  return rt_decide(d, checkv, env, out);
}

// a conditional with a fast path (1 `X extends infer V`, 2 `X extends [infer
// A, ...]`, 3 `X extends true`, 4 `X extends null`), its parts as arguments
int64_t rt_condf(int64_t fast, V checkv, V *env, V *out, int64_t frame, int64_t dist, const PatD *pat,
                 Thunk t, V t_cval, Thunk f, V f_cval, Thunk whole) {
  CondD d;
  int64_t slots[64];
  d.frame = frame;
  d.dist_slot = dist;
  d.ext = NULL;
  d.ext_cval = fast == 3 ? V_TRUE : fast == 4 ? V_NULL : 0;
  d.pat = pat;
  d.ninfer = 0;
  if (pat && pat->kind == P_INFER) slots[d.ninfer++] = pat->slot;
  else if (pat && pat->kind == P_TUPLE)
    for (int64_t i = 0; i < pat->n && i < 64; i++) slots[d.ninfer++] = pat->elems[i]->slot;
  d.infer_slots = slots;
  d.t = t;
  d.t_cval = t_cval;
  d.f = f;
  d.f_cval = f_cval;
  d.whole = whole;
  return rt_cond(&d, checkv, env, out);
}
