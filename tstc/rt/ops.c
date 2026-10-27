// Type operators: property access, keyof, template literals, tuples, object
// and function types, mapped types, generic functions.
#include "desc.h"

#include <math.h>
#include <stdlib.h>

V *env_copy(const V *env, int64_t frame) {
  V *e = gc_alloc((size_t)(frame > 0 ? frame : 1) * 8);
  if (frame > 0) memcpy(e, env, (size_t)frame * 8);
  return e;
}

bool lit_to_str(V t, Str **out) {
  switch (kind(t)) {
  case K_STRLIT: *out = as_str(t); return true;
  case K_INT: *out = str_of_int(int_val(t)); return true;
  case K_NUMLIT: *out = str_of_number(num_val(t)); return true;
  case K_BIGLIT: *out = ((BigT *)t)->s; return true;
  case K_TRUE: *out = str_of_cstr("true"); return true;
  case K_FALSE: *out = str_of_cstr("false"); return true;
  case K_NULL: *out = str_of_cstr("null"); return true;
  case K_UNDEFINED: *out = str_of_cstr("undefined"); return true;
  default: return false;
  }
}

bool key_name(V k, Str **out) {
  switch (kind(k)) {
  case K_STRLIT: *out = as_str(k); return true;
  case K_NUMLIT: *out = str_of_number(num_val(k)); return true;
  case K_INT: *out = str_of_int(int_val(k)); return true;
  case K_USYM: {
    int64_t id = ((USymT *)k)->id;
    if (id < WK_SYM_BASE || id >= WK_SYM_BASE + WK_COUNT) return false;
    *out = wk_prop_name((int)(id - WK_SYM_BASE));
    return true;
  }
  default: return false;
  }
}

// the type of property name of t (with undefined when optional) and whether
// it is optional (getPropertyOfType)
bool get_prop_of(V t, Str *name, V *ty, bool *opt) {
  PInfo p;
  if (!member_prop(t, name, &p)) return false;
  *ty = p.ty;
  *opt = p.opt;
  return true;
}

V tuple_elem_union(TupT *t) {
  VA items;
  va_init(&items);
  V u = tup_uni(t);
  if (u) return u;
  for (uint32_t i = 0; i < t->len; i++) {
    va_push(&items, t->e[i]);
    if (tup_kind(t, i) == E_OPT) va_push(&items, V_UNDEFINED);
  }
  return mk_union(items.d, items.n);
}

// the union of the element types from index on (getElementTypeOfSliceOfTupleType)
static V tuple_slice_union(TupT *t, uint32_t from) {
  VA items;
  va_init(&items);
  for (uint32_t i = from; i < t->len; i++) {
    va_push(&items, t->e[i]);
    if (tup_kind(t, i) == E_OPT) va_push(&items, V_UNDEFINED);
  }
  return mk_union(items.d, items.n);
}

static uint32_t tuple_fixed(TupT *t) {
  for (uint32_t i = 0; i < t->len; i++)
    if (tup_kind(t, i) == E_REST) return i;
  return t->len;
}

// isStringIndexSignatureOnlyType
static bool string_index_only(V t) {
  switch (kind(t)) {
  case K_OBJ: {
    ObjT *o = as_obj(t);
    return o->np == 0 && o->nc == 0 && o->ni == 1 && o->index[0].key == V_STRING;
  }
  case K_UNION: case K_INTER:
    for (uint32_t i = 0; i < set_n(t); i++)
      if (!string_index_only(set_m(t, i))) return false;
    return true;
  default: return false;
  }
}

static bool assignable_to_kind(V t, uint32_t flags) {
  uint32_t f = ty_flags(t);
  if (f & flags) return true;
  if (kind(t) == K_UNION) {
    for (uint32_t i = 0; i < set_n(t); i++)
      if (!(ty_flags(set_m(t, i)) & flags)) return false;
    return true;
  }
  if (kind(t) == K_INTER) {
    for (uint32_t i = 0; i < set_n(t); i++)
      if (ty_flags(set_m(t, i)) & flags) return true;
  }
  return false;
}

static bool sym_member(V t, int64_t sym, V *out) {
  Members m;
  members_of(t, &m);
  for (uint32_t i = 0; i < m.np; i++)
    if (!m.p[i].name && m.p[i].sym == sym) {
      *out = m.p[i].ty;
      return true;
    }
  return false;
}

// getPropertyTypeForIndexType (0: none)
static V prop_for_index(V o, V k) {
  int kk = kind(k);
  Str *name = NULL;
  bool has_name = key_name(k, &name);
  if (has_name) {
    PInfo p;
    if (member_prop(o, name, &p)) return p.ty;
    if (kind(o) == K_TUPLE) {
      double d;
      if (parse_canonical_number(name, &d) && d >= 0) {
        TupT *t = as_tup(o);
        uint32_t fixed = tuple_fixed(t);
        if (fixed == t->len) return V_UNDEFINED;
        return tuple_slice_union(t, fixed);
      }
    }
  }
  if (kk == K_USYM && ((USymT *)k)->id >= 0) {
    V v;
    if (sym_member(o, ((USymT *)k)->id, &v)) return v;
  }
  if (!(ty_flags(k) & TF_NULLABLE) && assignable_to_kind(k, TF_STRINGLIKE | TF_NUMBERLIKE | TF_SYMBOLLIKE)) {
    int ko = kind(o);
    if (ko == K_ANY || ko == K_NEVER) return o;
    Members m;
    members_of(o, &m);
    IndexSig *info = NULL, *str = NULL;
    for (uint32_t i = 0; i < m.ni; i++) {
      IndexSig *ix = &m.ix[i];
      if (ix->key == V_STRING) str = ix;
      else if (!info && (is_assignable(k, ix->key) || (ix->key == V_NUMBER && kk == K_STRLIT && parse_canonical_number(as_str(k), &(double){0}))))
        info = ix;
    }
    if (!info && str) info = str;
    if (info) return info->ty;
    if (kk == K_NEVER) return V_NEVER;
  }
  return 0;
}

// getIndexedAccessType
V index_access(V o, V k) {
  if (kind(o) == K_SUBST) o = ((SubstT *)o)->base;
  if (kind(k) == K_SUBST) k = ((SubstT *)k)->base;
  o = reduced_type(o);
  int kk = kind(k), ko = kind(o);
  if (kk == K_NEVER) return V_NEVER;
  if (ko == K_ANY) return V_ANY;
  if (ko == K_NEVER) return V_NEVER;
  if (ko == K_UNION) {
    SetT *u = (SetT *)o;
    V *r = gc_alloc((size_t)u->n * 8);
    for (uint32_t i = 0; i < u->n; i++) r[i] = index_access(u->m[i], k);
    return mk_union(r, u->n);
  }
  // an element of a tuple of required elements, or its length (by number or
  // by name: the members of the tuple are not made for one of them)
  if (ko == K_TUPLE && (kk == K_NUMLIT || kk == K_STRLIT) && tup_nokinds(as_tup(o))) {
    TupT *t = as_tup(o);
    double d;
    bool idx = true;
    if (kk == K_NUMLIT) d = num_val(k);
    else if (str_eq_c(as_str(k), "length")) return mk_num(t->len);
    else idx = parse_canonical_number(as_str(k), &d);
    if (idx && d >= 0 && d < t->len && d == (double)(uint32_t)d) return t->e[(uint32_t)d];
  }
  if (string_index_only(o) && !(ty_flags(k) & TF_NULLABLE) && assignable_to_kind(k, TF_STRING | TF_NUMBER)) k = V_STRING;
  if (kind(k) == K_UNION && !(ty_flags(k) & TF_BOOLEAN)) {
    SetT *u = (SetT *)k;
    V *r = gc_alloc((size_t)u->n * 8);
    for (uint32_t i = 0; i < u->n; i++) {
      r[i] = prop_for_index(o, u->m[i]);
      if (!r[i]) die("type %s cannot index type %s", ty_to_cstr_short(u->m[i]), ty_to_cstr_short(o));
    }
    return mk_union(r, u->n);
  }
  V r = prop_for_index(o, k);
  if (!r) die("type %s cannot index type %s", ty_to_cstr_short(k), ty_to_cstr_short(o));
  return r;
}

// Whether tsc and tsgo accept the indexed access type O[K] of a program
// (tstc check.mbt: the access's types are concrete): 0 when they report an
// error (a property that does not exist, a tuple index out of range, a type
// that cannot index O), 1 otherwise, also when it takes more than this
// knows (members of primitives and functions).
static const char *object_members[] = {
    "constructor", "toString", "toLocaleString", "valueOf", "hasOwnProperty", "isPrototypeOf",
    "propertyIsEnumerable", NULL};

static bool in_list(Str *name, const char *const *list) {
  for (int i = 0; list[i]; i++)
    if (str_eq_c(name, list[i])) return true;
  return false;
}

// -1: not decided, 0: an error, 1: accepted
static int index_ok1(V o, V k) {
  int ko = kind(o), kk = kind(k);
  if (kk == K_NEVER) return 1;
  if (kk == K_UNION) {
    // (each member of the index)
    int r = 1;
    for (uint32_t i = 0; i < set_n(k); i++) {
      int x = index_ok1(o, set_m(k, i));
      if (x == 0) return 0;
      if (x < 0) r = -1;
    }
    return r;
  }
  if (ko == K_UNION) {
    // (a property of every member)
    int r = 1;
    for (uint32_t i = 0; i < set_n(o); i++) {
      int x = index_ok1(set_m(o, i), k);
      if (x == 0) return 0;
      if (x < 0) r = -1;
    }
    return r;
  }
  if (ko == K_INTER) {
    // (a property of some member)
    int r = 0;
    for (uint32_t i = 0; i < set_n(o); i++) {
      int x = index_ok1(set_m(o, i), k);
      if (x == 1) return 1;
      if (x < 0) r = -1;
    }
    return r;
  }
  if (ko != K_OBJ && ko != K_TUPLE && ko != K_ARRAY) return -1;
  if (ko == K_OBJ && as_obj(o)->nc > 0) return -1;
  double d;
  if (kk == K_STRLIT || kk == K_NUMLIT) {
    Str *name;
    key_name(k, &name);
    if (in_list(name, object_members)) return 1;
    bool numeric = kk == K_NUMLIT || parse_canonical_number(name, &d);
    if (kk == K_NUMLIT) d = num_val(k);
    if (ko == K_OBJ) {
      ObjT *ob = as_obj(o);
      if (obj_get(ob, name)) return 1;
      int r = 0;
      for (uint32_t i = 0; i < ob->ni; i++) {
        V key = ob->index[i].key;
        if (key == V_STRING || (key == V_NUMBER && numeric)) return 1;
        if (key != V_NUMBER && key != V_SYMBOL) {
          // a pattern (template literal) key
          if (is_assignable(kk == K_NUMLIT ? (V)name : k, key)) return 1;
        }
      }
      return r;
    }
    {
      // (Array's or ReadonlyArray's members)
      int nm;
      const LibMember *ms = lib_members(apparent_of(o), &nm);
      for (int i = 0; i < nm; i++)
        if (ms[i].name && str_eq_c(name, ms[i].name)) return 1;
    }
    if (ko == K_ARRAY) return numeric ? 1 : 0;
    TupT *t = as_tup(o);
    for (uint32_t i = 0; i < t->len; i++)
      if (tup_kind(t, i) == E_REST) return numeric ? 1 : 0;
    if (!numeric) return 0;
    return d >= 0 && d < t->len && d == floor(d) ? 1 : 0;
  }
  if (kk == K_STRING || kk == K_NUMBER || kk == K_SYMBOL || kk == K_USYM) {
    if (ko != K_OBJ) return kk == K_NUMBER ? 1 : 0;
    // (a symbol indexes by a symbol index signature, else by the string one)
    ObjT *ob = as_obj(o);
    for (uint32_t i = 0; i < ob->ni; i++) {
      V key = ob->index[i].key;
      if (key == V_STRING || key == k || (kk == K_USYM && key == V_SYMBOL)) return 1;
    }
    return 0;
  }
  if (kk == K_TPL || kk == K_ANY) return -1;
  // booleans, null, undefined, objects, bigints, ...: not index types
  return 0;
}

V n_indexok(V o, V k) { return mk_num(index_ok1(o, k) == 0 ? 0 : 1); }

// the literal type of a property's name
static V prop_name_type(PInfo *p) {
  if (!p->name) return wk_symbol((int)(p->sym - WK_SYM_BASE));
  double d;
  if (p->numeric && parse_canonical_number(p->name, &d)) return mk_num(d);
  return (V)p->name;
}

// getIndexType
V keyof_ty(V t) {
  if (kind(t) == K_SUBST) t = ((SubstT *)t)->base;
  t = reduced_type(t);
  VA items;
  va_init(&items);
  switch (kind(t)) {
  case K_UNION: {
    SetT *u = (SetT *)t;
    V *ks = gc_alloc((size_t)u->n * 8);
    for (uint32_t i = 0; i < u->n; i++) ks[i] = keyof_ty(u->m[i]);
    return mk_inter(ks, u->n);
  }
  case K_INTER: {
    SetT *u = (SetT *)t;
    V *ks = gc_alloc((size_t)u->n * 8);
    for (uint32_t i = 0; i < u->n; i++) ks[i] = keyof_ty(u->m[i]);
    return mk_union(ks, u->n);
  }
  case K_UNKNOWN: return V_NEVER;
  case K_ANY:
  case K_NEVER: {
    V it[3] = {V_STRING, V_NUMBER, V_SYMBOL};
    return mk_union(it, 3);
  }
  case K_OBJ:
    if (as_obj(t)->keys) return as_obj(t)->keys;
    break;
  default: break;
  }
  Members m;
  members_of(t, &m);
  for (uint32_t i = 0; i < m.np; i++) va_push(&items, prop_name_type(&m.p[i]));
  for (uint32_t i = 0; i < m.ni; i++) {
    V k = m.ix[i].key;
    va_push(&items, k);
    if (k == V_STRING) va_push(&items, V_NUMBER);
  }
  V r = mk_union(items.d, items.n);
  if (kind(t) == K_OBJ) as_obj(t)->keys = r;
  return r;
}

// ---------------------------------------------------------------------------
// Template literal types and string mappings

static bool is_pattern_placeholder(V t);

// isPatternLiteralType
bool is_pattern_literal(V t) {
  switch (kind(t)) {
  case K_TPL: {
    TplT *p = (TplT *)t;
    for (uint32_t i = 0; i < p->n; i++)
      if (!is_pattern_placeholder(p->types[i])) return false;
    return true;
  }
  case K_STRMAP: return is_pattern_placeholder(((StrMapT *)t)->t);
  default: return false;
  }
}

// isPatternLiteralPlaceholderType
static bool is_pattern_placeholder(V t) {
  if (kind(t) == K_INTER) {
    bool seen = false;
    for (uint32_t i = 0; i < set_n(t); i++) {
      V m = set_m(t, i);
      if ((ty_flags(m) & (TF_LITERAL | TF_NULLABLE)) || is_pattern_placeholder(m)) seen = true;
      else if (!(ty_flags(m) & TF_OBJECT)) return false;
    }
    return seen;
  }
  return (ty_flags(t) & (TF_ANY | TF_STRING | TF_NUMBER | TF_BIGINT)) || is_pattern_literal(t);
}

bool is_literal_type(V t) {
  if (ty_flags(t) & TF_UNIT) return true;
  if (kind(t) == K_UNION) {
    for (uint32_t i = 0; i < set_n(t); i++)
      if (!(ty_flags(set_m(t, i)) & TF_UNIT)) return false;
    return true;
  }
  return false;
}

static bool is_generic_index(V t) { return (ty_flags(t) & (TF_TPARAM | TF_COND)) != 0; }

typedef struct {
  SB sb;
  VA texts, types;
} TplB;

static Str *sb_take(SB *b) {
  Str *s = b->n ? sb_finish(b) : str_empty;
  memset(b, 0, sizeof *b);
  return s;
}

static bool tpl_spans(TplB *b, Str **texts, const V *types, uint32_t n) {
  for (uint32_t i = 0; i < n; i++) {
    V t = types[i];
    uint32_t f = ty_flags(t);
    Str *lit;
    if ((f & (TF_LITERAL | TF_NULL | TF_UNDEFINED)) && lit_to_str(t, &lit)) {
      sb_str(&b->sb, lit);
      sb_str(&b->sb, texts[i + 1]);
    } else if (kind(t) == K_TPL) {
      TplT *p = (TplT *)t;
      sb_str(&b->sb, p->texts[0]);
      if (!tpl_spans(b, p->texts, p->types, p->n)) return false;
      sb_str(&b->sb, texts[i + 1]);
    } else if (is_generic_index(t) || is_pattern_placeholder(t)) {
      va_push(&b->types, t);
      va_push(&b->texts, (V)sb_take(&b->sb));
      sb_str(&b->sb, texts[i + 1]);
    } else {
      return false;
    }
  }
  return true;
}

// getTemplateLiteralType
V get_template_type(Str **texts, const V *types, uint32_t n) {
  for (uint32_t i = 0; i < n; i++) {
    int k = kind(types[i]);
    if (k == K_NEVER) return V_NEVER;
    if (k == K_UNION) {
      SetT *u = (SetT *)types[i];
      V *rs = gc_alloc((size_t)u->n * 8);
      V *v2 = gc_alloc((size_t)n * 8);
      for (uint32_t j = 0; j < u->n; j++) {
        memcpy(v2, types, (size_t)n * 8);
        v2[i] = u->m[j];
        rs[j] = get_template_type(texts, v2, n);
      }
      return mk_union(rs, u->n);
    }
  }
  // all literals: a string literal (the common case)
  bool lits = true;
  for (uint32_t i = 0; i < n && lits; i++) lits = (ty_flags(types[i]) & (TF_LITERAL | TF_NULL | TF_UNDEFINED)) != 0;
  if (lits) {
    Str *acc = texts[0];
    for (uint32_t i = 0; i < n; i++) {
      Str *l;
      lit_to_str(types[i], &l);
      acc = str_concat(acc, l);
      acc = str_concat(acc, texts[i + 1]);
    }
    return (V)acc;
  }
  TplB b;
  memset(&b, 0, sizeof b);
  sb_str(&b.sb, texts[0]);
  if (!tpl_spans(&b, texts, types, n)) return V_STRING;
  if (b.types.n == 0) return (V)sb_take(&b.sb);
  va_push(&b.texts, (V)sb_take(&b.sb));
  bool empty = true;
  for (uint32_t i = 0; i < b.texts.n && empty; i++) empty = as_str(b.texts.d[i])->len == 0;
  if (empty) {
    bool strs = true;
    for (uint32_t i = 0; i < b.types.n && strs; i++) strs = (ty_flags(b.types.d[i]) & TF_STRING) != 0;
    if (strs) return V_STRING;
    if (b.types.n == 1 && is_pattern_literal(b.types.d[0])) return b.types.d[0];
  }
  return mk_tpl((Str **)b.texts.d, b.types.d, b.types.n);
}

V eval_tpl(Str **texts, const V *vals, uint32_t n) { return get_template_type(texts, vals, n); }

// JavaScript's toUpperCase / toLowerCase (Latin-1 and the common cases)
static void case_map(SB *b, const uint16_t *d, int32_t n, bool upper) {
  for (int32_t i = 0; i < n; i++) {
    uint16_t c = d[i];
    if (upper) {
      if (c >= 'a' && c <= 'z') c -= 32;
      else if (c == 0xDF) {
        sb_put(b, 'S');
        c = 'S';
      } else if (c == 0xB5) c = 0x39C;
      else if (c == 0xFF) c = 0x178;
      else if (c >= 0xE0 && c <= 0xFE && c != 0xF7) c -= 32;
      else if (c >= 0x3B1 && c <= 0x3C9 && c != 0x3C2) c -= 32;
      else if (c >= 0x430 && c <= 0x44F) c -= 32;
      else if (c >= 0x450 && c <= 0x45F) c -= 80;
      else if (c >= 0x100 && c <= 0x17F && (c & 1) && c != 0x131 && c != 0x138 && c != 0x149 && !(c >= 0x139 && c <= 0x148) && !(c >= 0x179 && c <= 0x17E)) c -= 1;
      else if (((c >= 0x139 && c <= 0x148) || (c >= 0x179 && c <= 0x17E)) && !(c & 1)) c -= 1;
    } else {
      if (c >= 'A' && c <= 'Z') c += 32;
      else if (c >= 0xC0 && c <= 0xDE && c != 0xD7) c += 32;
      else if (c >= 0x391 && c <= 0x3A9 && c != 0x3A2) c += 32;
      else if (c >= 0x410 && c <= 0x42F) c += 32;
      else if (c >= 0x400 && c <= 0x40F) c += 80;
      else if (c == 0x178) c = 0xFF;
      else if (c >= 0x100 && c <= 0x17F && !(c & 1) && c != 0x130 && c != 0x138 && !(c >= 0x139 && c <= 0x148) && !(c >= 0x179 && c <= 0x17E)) c += 1;
      else if (((c >= 0x139 && c <= 0x148) || (c >= 0x179 && c <= 0x17E)) && (c & 1)) c += 1;
    }
    sb_put(b, c);
  }
}

// applyStringMapping
static Str *apply_case(int mode, Str *s) {
  if (s->len == 0) return s;
  SB b = {0};
  const uint16_t *d = str_d(s);
  if (mode <= 1) {
    case_map(&b, d, s->len, mode == 0);
  } else {
    int32_t first = (s->len >= 2 && d[0] >= 0xD800 && d[0] <= 0xDBFF && d[1] >= 0xDC00 && d[1] <= 0xDFFF) ? 2 : 1;
    case_map(&b, d, first, mode == 2);
    for (int32_t i = first; i < s->len; i++) sb_put(&b, d[i]);
  }
  Str *r = sb_finish(&b);
  return str_eq(r, s) ? s : r;
}

V mk_strmap(int mode, V t) {
  StrMapT *m = gc_alloc(sizeof(StrMapT));
  m->tag = K_STRMAP;
  m->mode = (uint32_t)mode;
  m->t = t;
  return (V)m;
}

// getStringMappingType
V string_mapping(int mode, V t) {
  switch (kind(t)) {
  case K_NEVER: return V_NEVER;
  case K_UNION: {
    SetT *u = (SetT *)t;
    V *r = gc_alloc((size_t)u->n * 8);
    for (uint32_t i = 0; i < u->n; i++) r[i] = string_mapping(mode, u->m[i]);
    return mk_union(r, u->n);
  }
  case K_STRLIT: return (V)apply_case(mode, as_str(t));
  case K_TPL: {
    // applyTemplateStringMapping
    TplT *p = (TplT *)t;
    Str **texts = gc_alloc((size_t)(p->n + 1) * 8);
    V *types = gc_alloc((size_t)(p->n ? p->n : 1) * 8);
    memcpy(texts, p->texts, (size_t)(p->n + 1) * 8);
    memcpy(types, p->types, (size_t)p->n * 8);
    if (mode <= 1) {
      for (uint32_t i = 0; i <= p->n; i++) texts[i] = apply_case(mode, texts[i]);
      for (uint32_t i = 0; i < p->n; i++) types[i] = string_mapping(mode, types[i]);
    } else if (texts[0]->len) {
      texts[0] = apply_case(mode, texts[0]);
    } else {
      types[0] = string_mapping(mode, types[0]);
    }
    return get_template_type(texts, types, p->n);
  }
  case K_STRMAP:
    if (((StrMapT *)t)->mode == (uint32_t)mode) return t;
    return mk_strmap(mode, t);
  case K_ANY: case K_STRING: return mk_strmap(mode, t);
  default:
    if (is_generic_index(t)) return mk_strmap(mode, t);
    if (is_pattern_placeholder(t)) {
      static Str *e2[2];
      if (!e2[0]) {
        e2[0] = e2[1] = str_of_cstr("");
        gc_add_root(e2, sizeof e2);
      }
      return mk_strmap(mode, get_template_type(e2, &t, 1));
    }
    return t;
  }
}

V mk_libm(int app, V base, Str *name, int64_t sym) {
  LibmT *l = gc_alloc(sizeof(LibmT));
  l->tag = K_LIBM;
  l->app = (uint32_t)app;
  l->base = base;
  l->name = name;
  l->sym = sym;
  return (V)l;
}

// ---------------------------------------------------------------------------
// Tuples

// The normalization of tuple types (TupleNormalizer): optional elements
// before the last required one are required (of their type with
// undefined); the elements from the first rest element to the last optional
// or rest one are one rest element of their union.
V tuple_normalize(TB *b) {
  int64_t last_req = -1, first_rest = -1, last_opt_rest = -1;
  for (uint32_t i = 0; i < b->n; i++) {
    int k = b->k[i];
    if (k == E_REQ) last_req = i;
    if (k == E_REST && first_rest < 0) first_rest = i;
    if (k == E_OPT || k == E_REST) last_opt_rest = i;
    if (k == E_OPT) b->e[i] = opt_type(b->e[i]);
  }
  for (int64_t i = 0; i < last_req; i++)
    if (b->k[i] == E_OPT) b->k[i] = E_REQ;
  if (first_rest >= 0 && first_rest < last_opt_rest) {
    V u = mk_union(b->e + first_rest, (uint32_t)(last_opt_rest - first_rest + 1));
    b->e[first_rest] = u;
    uint32_t drop = (uint32_t)(last_opt_rest - first_rest);
    uint32_t tail = b->n - (uint32_t)last_opt_rest - 1;
    memmove(b->e + first_rest + 1, b->e + last_opt_rest + 1, (size_t)tail * 8);
    memmove(b->k + first_rest + 1, b->k + last_opt_rest + 1, tail);
    memmove(b->nm + first_rest + 1, b->nm + last_opt_rest + 1, (size_t)tail * 8);
    b->n -= drop;
  }
  b->any_k = false;
  for (uint32_t i = 0; i < b->n; i++)
    if (b->k[i] != E_REQ) b->any_k = true;
  return tb_finish(b);
}

static V build_tuple_vals(const TupD *d, V *vals) {
  // spreads of unions distribute
  for (int64_t i = 0; i < d->n; i++) {
    if (d->kinds[i] != E_REST) continue;
    int k = kind(vals[i]);
    if (k == K_UNION) {
      SetT *u = (SetT *)vals[i];
      V *rs = gc_alloc((size_t)u->n * 8);
      V *v2 = gc_alloc((size_t)d->n * 8);
      for (uint32_t j = 0; j < u->n; j++) {
        memcpy(v2, vals, (size_t)d->n * 8);
        v2[i] = u->m[j];
        rs[j] = build_tuple_vals(d, v2);
      }
      return mk_union(rs, u->n);
    }
    if (k == K_NEVER) return V_NEVER;
  }
  TB b;
  tb_init(&b);
  b.ro = d->ro;
  for (int64_t i = 0; i < d->n; i++) {
    V v = vals[i];
    Str *nm = d->names ? d->names[i] : NULL;
    if (d->kinds[i] == E_REST) {
      switch (kind(v)) {
      case K_TUPLE: {
        TupT *t = as_tup(v);
        for (uint32_t j = 0; j < t->len; j++) tb_push(&b, t->e[j], tup_kind(t, j), tup_name(t, j));
        break;
      }
      case K_ARRAY: tb_push(&b, ((ArrT *)v)->el, E_REST, nm); break;
      case K_ANY: tb_push(&b, V_ANY, E_REST, nm); break;
      default: tb_push(&b, V_UNKNOWN, E_REST, nm);
      }
    } else {
      tb_push(&b, v, (int)d->kinds[i], nm);
    }
  }
  return tuple_normalize(&b);
}

V rt_tuple(const TupD *d, V *vals) {
  // required elements and spreads of plain tuples: [...A, ...B, x] appends
  // B and x to A in place when it can, otherwise one copy
  if (!d->names && !d->ro && d->n >= 1) {
    uint64_t total = 0;
    bool plain = true;
    for (int64_t i = 0; i < d->n && plain; i++) {
      if (d->kinds[i] == E_REST) {
        if (kind(vals[i]) == K_TUPLE && tup_plain(as_tup(vals[i]))) total += as_tup(vals[i])->len;
        else plain = false;
      } else if (d->kinds[i] == E_REQ) {
        total++;
      } else {
        plain = false;
      }
    }
    if (plain && total < (UINT64_C(1) << 31)) {
      if (total == 0) return empty_tuple;
      // empty spreads add nothing
      int64_t first = 0;
      while (d->kinds[first] == E_REST && as_tup(vals[first])->len == 0) first++;
      // the same element everywhere and a uniform spread: a view of its
      // buffer ([...A, ...B], [x, ...A], [...A, x] of 0s are O(1))
      V u = 0;
      TupT *ut = NULL;
      for (int64_t i = first; i < d->n; i++)
        if (d->kinds[i] == E_REST && tup_uni(as_tup(vals[i]))) {
          ut = as_tup(vals[i]);
          u = tup_uni(ut);
          break;
        }
      if (ut) {
        bool same = true;
        for (int64_t i = first; i < d->n && same; i++) {
          if (d->kinds[i] != E_REST) {
            same = same_el(vals[i], u);
          } else {
            TupT *t = as_tup(vals[i]);
            V tu = tup_uni(t);
            if (tu) {
              same = same_el(tu, u);
            } else {
              for (uint32_t j = 0; j < t->len && same; j++) same = same_el(t->e[j], u);
            }
          }
        }
        if (same) return ut->len == total ? (V)ut : tup_uni_view(ut, (uint32_t)total);
      }
      if (d->kinds[first] == E_REST) {
        V acc = vals[first];
        uint64_t rest = total - as_tup(acc)->len;
        if (rest == 0) return acc;
        // the rest, gathered, appended (in place when acc ends its buffer)
        V small[16];
        V *xs = rest <= 16 ? small : gc_alloc(rest * 8);
        uint64_t k = 0;
        for (int64_t i = first + 1; i < d->n; i++) {
          if (d->kinds[i] == E_REST) {
            TupT *t = as_tup(vals[i]);
            if (t->len) memcpy(xs + k, t->e, (size_t)t->len * 8);
            k += t->len;
          } else {
            xs[k++] = vals[i];
          }
        }
        return tup_append_n(as_tup(acc), xs, (uint32_t)rest);
      }
      TupT *r = tup_alloc((uint32_t)total);
      uint64_t k = 0;
      for (int64_t i = first; i < d->n; i++) {
        if (d->kinds[i] == E_REST) {
          TupT *t = as_tup(vals[i]);
          if (t->len) memcpy(r->e + k, t->e, (size_t)t->len * 8);
          k += t->len;
        } else {
          r->e[k++] = vals[i];
        }
      }
      return (V)r;
    }
  }
  // [...A, x, y]: appends in place
  if (d->n >= 1 && d->kinds[0] == E_REST) {
    bool plain_tail = true;
    for (int64_t i = 1; i < d->n; i++)
      if (d->kinds[i] != E_REQ || (d->names && d->names[i])) plain_tail = false;
    if (plain_tail && kind(vals[0]) == K_TUPLE) {
      TupT *t = as_tup(vals[0]);
      if (tup_nokinds(t) && (!t->x || !t->x->names) && tup_ro(t) == (bool)d->ro) {
        V acc = vals[0];
        for (int64_t i = 1; i < d->n; i++) acc = tup_append(as_tup(acc), vals[i]);
        return acc;
      }
    }
  }
  return build_tuple_vals(d, vals);
}

// ---------------------------------------------------------------------------
// Object and function types

V rt_obj(const ObjD *d, V *env) {
  OB b;
  ob_init(&b);
  V *lazy_env = NULL;
  for (int64_t i = 0; i < d->np; i++) {
    const PropD *p = &d->props[i];
    if (p->cval) {
      ob_prop(&b, p->name, p->cval, NULL, NULL, p->opt, p->ro, p->numeric, false);
    } else if (p->slot >= 0) {
      ob_prop(&b, p->name, env[p->slot], NULL, NULL, p->opt, p->ro, p->numeric, false);
    } else if (p->slot <= -2) {
      // one function evaluates the properties: the index past the frame
      V *e = gc_alloc((size_t)(d->frame + 1) * 8);
      if (d->frame > 0) memcpy(e, env, (size_t)d->frame * 8);
      e[d->frame] = mk_int(-2 - p->slot);
      ob_prop(&b, p->name, 0, p->th, e, p->opt, p->ro, p->numeric, false);
    } else {
      if (!lazy_env) lazy_env = env_copy(env, d->frame);
      ob_prop(&b, p->name, 0, p->th, lazy_env, p->opt, p->ro, p->numeric, false);
    }
  }
  for (int64_t i = 0; i < d->ni; i++) ob_index(&b, call_thunk(d->index[i].key, env), call_thunk(d->index[i].ty, env), d->index[i].ro);
  for (int64_t i = 0; i < d->nc; i++) {
    const CallD *c = &d->calls[i];
    Param *ps = gc_alloc((size_t)(c->np ? c->np : 1) * sizeof(Param));
    for (int64_t j = 0; j < c->np; j++) {
      ps[j].name = c->params[j].name;
      ps[j].ty = call_thunk(c->params[j].ty, env);
      ps[j].opt = (uint8_t)c->params[j].opt;
      ps[j].rest = (uint8_t)c->params[j].rest;
    }
    ob_call(&b, mk_fn(ps, (uint32_t)c->np, call_thunk(c->ret, env), c->ctor));
  }
  return ob_finish(&b);
}

V rt_fn(const FnD *d, const V *tys, V ret) {
  Param *ps = gc_alloc((size_t)(d->np ? d->np : 1) * sizeof(Param));
  for (int64_t j = 0; j < d->np; j++) {
    ps[j].name = d->params[j].name;
    ps[j].ty = tys[j];
    ps[j].opt = (uint8_t)d->params[j].opt;
    ps[j].rest = (uint8_t)d->params[j].rest;
  }
  return (V)mk_fn(ps, (uint32_t)d->np, ret, d->ctor);
}

V rt_genfn(const int64_t *slots, int64_t nslots, Thunk code, V *env, int64_t frame) {
  return mk_genfn(slots, (uint32_t)nslots, code, env, (uint32_t)frame);
}

V instantiate_generic(GenFnT *g, const V *markers, uint32_t n) {
  V *e = env_copy(g->env, g->frame);
  for (uint32_t i = 0; i < g->nslots; i++) e[g->slots[i]] = i < n ? markers[i] : V_UNKNOWN;
  return call_thunk(g->code, e);
}

// ---------------------------------------------------------------------------
// Mapped types

// getTypeWithFacts(t, NEUndefined): without undefined and void
V remove_undefined(V t) {
  if (t == V_UNDEFINED || t == V_VOID) return V_NEVER;
  if (kind(t) == K_UNION) {
    SetT *u = (SetT *)t;
    VA r;
    va_init(&r);
    for (uint32_t i = 0; i < u->n; i++)
      if (u->m[i] != V_UNDEFINED && u->m[i] != V_VOID) va_push(&r, u->m[i]);
    return mk_union(r.d, r.n);
  }
  return t;
}

static void members_v(V t, VA *out) {
  va_init(out);
  if (kind(t) == K_UNION) {
    for (uint32_t i = 0; i < set_n(t); i++) va_push(out, set_m(t, i));
  } else if (t != V_NEVER) {
    va_push(out, t);
  }
}

// the template instantiated for a key (with undefined for `?`)
static V template_at(const MappedD *m, V *env, V key, V **env_out) {
  V *e2 = env_copy(env, m->frame);
  e2[m->slot] = key;
  if (env_out) *env_out = e2;
  V v = m->body_cval ? m->body_cval : m->body_slot >= 0 ? e2[m->body_slot] : call_thunk(m->body, e2);
  return m->opt > 0 ? opt_type(v) : v;
}

// keys of a type as a mapped type `[K in keyof X]` iterates them
// (forEachMappedTypePropertyKeyTypeAndIndexSignatureKeyType)
static void keyof_syntax_keys(V t, VA *keys) {
  va_init(keys);
  Members mm;
  members_of(t, &mm);
  for (uint32_t i = 0; i < mm.np; i++) {
    PInfo *p = &mm.p[i];
    double d;
    if (!p->name) va_push(keys, wk_symbol((int)(p->sym - WK_SYM_BASE)));
    else if (p->numeric && parse_canonical_number(p->name, &d)) va_push(keys, mk_num(d));
    else va_push(keys, (V)p->name);
  }
  if (t == V_ANY) {
    va_push(keys, V_STRING);
  } else {
    for (uint32_t i = 0; i < mm.ni; i++) va_push(keys, mm.ix[i].key);
  }
}

static bool usable_as_prop_name(V t) {
  int k = kind(t);
  return k == K_STRLIT || k == K_NUMLIT || (k == K_USYM && ((USymT *)t)->id >= 0);
}

typedef struct {
  Str *name;
  V name_ty;
  VA keys;
} MProp;

// resolveMappedTypeMembers
static V mapped_keys(const MappedD *m, VA *keys, V mods, V *env) {
  VA props;  // MProp*
  va_init(&props);
  NameIx pix = {0};  // their names
  OB b;
  ob_init(&b);
  for (uint32_t ki = 0; ki < keys->n; ki++) {
    V key = keys->d[ki];
    VA names;
    if (m->as_clause) {
      V *e2 = env_copy(env, m->frame);
      e2[m->slot] = key;
      members_v(call_thunk(m->as_clause, e2), &names);
    } else {
      members_v(key, &names);
    }
    for (uint32_t j = 0; j < names.n; j++) {
      V nm = names.d[j];
      if (usable_as_prop_name(nm)) {
        Str *n;
        if (!key_name(nm, &n)) continue;  // (symbol-named properties: not represented)
        int32_t q = nix_get(&pix, n);
        MProp *mp = q >= 0 ? (MProp *)props.d[q] : NULL;
        if (!mp) {
          nix_put(&pix, n, (int32_t)props.n);
          mp = gc_alloc(sizeof(MProp));
          mp->name = n;
          mp->name_ty = nm;
          va_init(&mp->keys);
          va_push(&props, (V)mp);
        }
        va_push(&mp->keys, key);
      } else {
        int k = kind(nm);
        V ik;
        if (k == K_ANY || k == K_STRING) ik = V_STRING;
        else if (k == K_NUMBER) ik = V_NUMBER;
        else if (k == K_SYMBOL || k == K_TPL || k == K_STRMAP) ik = nm;
        else continue;
        V v = template_at(m, env, key, NULL);
        bool ro = m->ro > 0;
        if (m->ro == 0 && mods) {
          Members mm;
          members_of(mods, &mm);
          for (uint32_t q = 0; q < mm.ni; q++)
            if (is_assignable(nm, mm.ix[q].key) && mm.ix[q].ro) ro = true;
        }
        // appendIndexInfo(union): the same key type's values unioned
        bool merged = false;
        for (uint32_t q = 0; q < b.ni && !merged; q++)
          if (ty_eq(b.ix[q].key, ik)) {
            b.ix[q].ty = mk_union2(b.ix[q].ty, v);
            b.ix[q].ro = b.ix[q].ro || ro;
            merged = true;
          }
        if (!merged) ob_index(&b, ik, v, ro);
      }
    }
  }
  for (uint32_t i = 0; i < props.n; i++) {
    MProp *mp = (MProp *)props.d[i];
    V key = mp->keys.n == 1 ? mp->keys.d[0] : mk_union(mp->keys.d, mp->keys.n);
    // the property of the modifiers type the key names
    PInfo mprop;
    bool has_mod = false;
    Str *kn;
    if (mods && usable_as_prop_name(key) && key_name(key, &kn)) has_mod = member_prop(mods, kn, &mprop);
    bool opt = m->opt > 0 || (m->opt == 0 && has_mod && mprop.opt);
    bool ro = m->ro > 0 || (m->ro == 0 && has_mod && mprop.ro);
    bool strip = !opt && has_mod && mprop.opt;
    int post = m->opt > 0 ? PROP_OPT : opt ? PROP_MAPPED_OPT : strip ? PROP_STRIP : PROP_AS_IS;
    bool numeric = kind(mp->name_ty) == K_NUMLIT;
    V *e2 = env_copy(env, m->frame);
    e2[m->slot] = key;
    if (m->body_cval) ob_prop_x(&b, mp->name, m->body_cval, NULL, NULL, opt, ro, numeric, true, post);
    else if (m->body_slot >= 0) ob_prop_x(&b, mp->name, e2[m->body_slot], NULL, NULL, opt, ro, numeric, true, post);
    else ob_prop_x(&b, mp->name, 0, m->body, e2, opt, ro, numeric, true, post);
  }
  V r = ob_finish(&b);
  as_obj(r)->aux |= OBJ_MAPPED;
  return r;
}

// instantiateMappedTypeTemplate
static V mapped_template(const MappedD *m, V *env, V key, bool is_opt) {
  V v = template_at(m, env, key, NULL);
  if (m->opt > 0) return v;
  if (m->opt < 0 && is_opt) return remove_undefined(v);
  return v;
}

static V mapped_homo(const MappedD *m, V src, V *env);

// a homomorphic mapped type over an array type
static V mapped_array(const MappedD *m, V arr, V *env) {
  V *e = env;
  if (m->homo_slot >= 0) {
    e = env_copy(env, m->frame);
    e[m->homo_slot] = arr;
  }
  V v = mapped_template(m, e, V_NUMBER, true);
  bool ro = m->ro > 0 ? true : (m->ro < 0 ? false : ((ArrT *)arr)->ro);
  return mk_array(v, ro);
}

static V mapped_tuple(const MappedD *m, TupT *t, V *env) {
  TB b;
  tb_init(&b);
  b.ro = m->ro > 0 ? true : (m->ro < 0 ? false : tup_ro(t));
  uint32_t fixed = 0;
  while (fixed < t->len && tup_kind(t, fixed) != E_REST) fixed++;
  for (uint32_t i = 0; i < t->len; i++) {
    int ek = tup_kind(t, i);
    V v;
    if (i < fixed) {
      v = mapped_template(m, env, (V)str_of_int(i), ek == E_OPT);
    } else {
      // the mapped type of an array of the element
      V a = mapped_array(m, mk_array(t->e[i], false), env);
      v = kind(a) == K_ARRAY ? ((ArrT *)a)->el : V_UNKNOWN;
    }
    int nk = ek;
    if (m->opt > 0 && ek == E_REQ) nk = E_OPT;
    else if (m->opt < 0 && ek == E_OPT) nk = E_REQ;
    tb_push(&b, v, nk, tup_name(t, i));
  }
  return tuple_normalize(&b);
}

static bool array_or_tuple_or_inter(V t) {
  if (kind(t) != K_INTER) return false;
  for (uint32_t i = 0; i < set_n(t); i++) {
    int k = kind(set_m(t, i));
    if (k != K_ARRAY && k != K_TUPLE) return false;
  }
  return true;
}

// instantiateMappedType for a homomorphic mapped type, its T being src
static V mapped_homo(const MappedD *m, V src, V *env) {
  if (kind(src) == K_SUBST) src = ((SubstT *)src)->base;
  src = reduced_type(src);
  int k = kind(src);
  if (k == K_UNION) {
    SetT *u = (SetT *)src;
    V *rs = gc_alloc((size_t)u->n * 8);
    for (uint32_t i = 0; i < u->n; i++) rs[i] = mapped_homo(m, u->m[i], env);
    return mk_union(rs, u->n);
  }
  uint32_t f = ty_flags(src);
  if (!(f & (TF_ANY | TF_UNKNOWN | TF_TPARAM | TF_COND | TF_OBJECT | TF_INTER))) return src;
  if (!m->as_clause) {
    // (the body reads T: it is this constituent)
    V *e = env;
    if (m->homo_slot >= 0) {
      e = env_copy(env, m->frame);
      e[m->homo_slot] = src;
    }
    if (k == K_ARRAY) return mapped_array(m, src, e);
    if (k == K_TUPLE) return mapped_tuple(m, as_tup(src), e);
    if (array_or_tuple_or_inter(src)) {
      SetT *u = (SetT *)src;
      V *rs = gc_alloc((size_t)u->n * 8);
      for (uint32_t i = 0; i < u->n; i++) rs[i] = mapped_homo(m, u->m[i], env);
      return mk_inter(rs, u->n);
    }
  }
  V *e = env;
  if (m->homo_slot >= 0) {
    e = env_copy(env, m->frame);
    e[m->homo_slot] = src;
  }
  VA keys;
  keyof_syntax_keys(src, &keys);
  return mapped_keys(m, &keys, src, e);
}

V rt_mapped(const MappedD *m, V *env) {
  if (m->homo) return mapped_homo(m, call_thunk(m->homo, env), env);
  V mods = m->mods ? call_thunk(m->mods, env) : 0;
  VA keys;
  if (m->kof && mods) keyof_syntax_keys(mods, &keys);
  else members_v(call_thunk(m->constraint, env), &keys);
  return mapped_keys(m, &keys, mods, env);
}

// ---------------------------------------------------------------------------
// Instantiation of substitution types: each is its base (when that is
// assignable to the constraint, otherwise constraint & base), the types made
// of them made again

static V strip(V t, int depth);

static V strip_all(const V *in, V *out, uint32_t n, int depth, bool *changed) {
  for (uint32_t i = 0; i < n; i++) {
    out[i] = strip(in[i], depth + 1);
    if (out[i] != in[i]) *changed = true;
  }
  return 0;
}

static V strip(V t, int depth) {
  if ((t & 3) || depth > 100) return t;
  switch (kind(t)) {
  case K_SUBST: {
    SubstT *s = (SubstT *)t;
    V b = strip(s->base, depth + 1), c = strip(s->cons, depth + 1);
    if (c == V_ANY || c == V_UNKNOWN || is_assignable(b, c)) return b;
    V it[2] = {c, b};
    return mk_inter(it, 2);
  }
  case K_UNION:
  case K_INTER: {
    SetT *u = (SetT *)t;
    V *m = gc_alloc((size_t)u->n * 8);
    bool ch = false;
    strip_all(u->m, m, u->n, depth, &ch);
    if (!ch) return t;
    return kind(t) == K_UNION ? mk_union(m, u->n) : mk_inter(m, u->n);
  }
  case K_TUPLE: {
    TupT *tp = as_tup(t);
    V *e = gc_alloc((size_t)(tp->len ? tp->len : 1) * 8);
    bool ch = false;
    strip_all(tp->e, e, tp->len, depth, &ch);
    if (!ch) return t;
    TB b;
    tb_init(&b);
    b.ro = tup_ro(tp);
    for (uint32_t i = 0; i < tp->len; i++) tb_push(&b, e[i], tup_kind(tp, i), tup_name(tp, i));
    return tb_finish(&b);
  }
  case K_ARRAY: {
    V e = strip(((ArrT *)t)->el, depth + 1);
    return e == ((ArrT *)t)->el ? t : mk_array(e, ((ArrT *)t)->ro);
  }
  case K_FN: {
    FnT *f = (FnT *)t;
    bool ch = false;
    Param *ps = gc_alloc((size_t)(f->np ? f->np : 1) * sizeof(Param));
    for (uint32_t i = 0; i < f->np; i++) {
      ps[i] = f->params[i];
      ps[i].ty = strip(f->params[i].ty, depth + 1);
      if (ps[i].ty != f->params[i].ty) ch = true;
    }
    V r = strip(f->ret, depth + 1);
    if (!ch && r == f->ret) return t;
    return (V)mk_fn(ps, f->np, r, f->ctor);
  }
  case K_OBJ: {
    ObjT *o = as_obj(t);
    bool ch = false;
    for (uint32_t i = 0; i < o->np && !ch; i++)
      if (o->props[i].ty && strip(o->props[i].ty, depth + 1) != o->props[i].ty) ch = true;
    for (uint32_t i = 0; i < o->ni && !ch; i++)
      if (strip(o->index[i].ty, depth + 1) != o->index[i].ty) ch = true;
    if (!ch) return t;
    OB b;
    ob_init(&b);
    for (uint32_t i = 0; i < o->np; i++) {
      Prop *p = &o->props[i];
      if (p->ty) ob_prop_x(&b, p->name, strip(p->ty, depth + 1), NULL, NULL, p->opt, p->ro, p->numeric, true, PROP_AS_IS);
      else ob_prop_x(&b, p->name, 0, p->th, p->env, p->opt, p->ro, p->numeric, true, p->post);
      b.p[b.n - 1].seq = p->seq;
    }
    for (uint32_t i = 0; i < o->ni; i++) ob_index(&b, o->index[i].key, strip(o->index[i].ty, depth + 1), o->index[i].ro);
    for (uint32_t i = 0; i < o->nc; i++) ob_call(&b, o->calls[i]);
    V r = ob_finish(&b);
    as_obj(r)->aux = o->aux;
    return r;
  }
  case K_DEFERRED: {
    DefT *d = (DefT *)t;
    V c = strip(d->c, depth + 1), e = strip(d->e, depth + 1), x = strip(d->t, depth + 1), f = strip(d->f, depth + 1);
    if (c == d->c && e == d->e && x == d->t && f == d->f) return t;
    return mk_deferred(c, e, x, f);
  }
  default: return t;
  }
}

V subst_strip(V t) {
  if (!subst_made) return t;
  return strip(t, 0);
}

bool alias_topped(V v);  // ty.c
static bool eq_has_marker(V t, int depth);
static V eq_strip_d(V t, int depth);

// a type as tsgo's instantiation of a signature leaves it (the identity of
// generic signatures, so TypeScript's Equal): substitution types resolved
// in unions and intersections, except those written as a parameterless
// alias's type, and in what refers to the signature's type parameters
// (markers); tuples, arrays and objects of none are as they are (deferred
// type references, anonymous types of no type parameter)
static V eq_strip_d(V t, int depth) {
  if ((t & 3) || depth > 64 || alias_topped(t)) return t;
  switch (kind(t)) {
  case K_SUBST: return eq_strip_d(strip(t, 0), depth + 1);
  case K_UNION:
  case K_INTER: {
    SetT *u = (SetT *)t;
    V *m = NULL;
    for (uint32_t i = 0; i < u->n; i++) {
      V x = eq_strip_d(u->m[i], depth + 1);
      if (x != u->m[i] && !m) {
        m = gc_alloc((size_t)u->n * 8);
        memcpy(m, u->m, (size_t)i * 8);
      }
      if (m) m[i] = x;
    }
    if (!m) return t;
    return kind(t) == K_UNION ? mk_union(m, u->n) : mk_inter(m, u->n);
  }
  case K_DEFERRED: {
    DefT *d = (DefT *)t;
    V c = eq_strip_d(d->c, depth + 1), e = eq_strip_d(d->e, depth + 1), x = eq_strip_d(d->t, depth + 1), f = eq_strip_d(d->f, depth + 1);
    if (c == d->c && e == d->e && x == d->t && f == d->f) return t;
    return mk_deferred(c, e, x, f);
  }
  case K_FN: {
    // (a function type of no type parameter: an anonymous type as it is)
    if (!eq_has_marker(t, 0)) return t;
    FnT *f = (FnT *)t;
    bool ch = false;
    Param *ps = gc_alloc((size_t)(f->np ? f->np : 1) * sizeof(Param));
    for (uint32_t i = 0; i < f->np; i++) {
      ps[i] = f->params[i];
      ps[i].ty = eq_strip_d(f->params[i].ty, depth + 1);
      if (ps[i].ty != f->params[i].ty) ch = true;
    }
    V r = eq_strip_d(f->ret, depth + 1);
    if (!ch && r == f->ret) return t;
    return (V)mk_fn(ps, f->np, r, f->ctor);
  }
  case K_TUPLE: {
    if (!eq_has_marker(t, 0)) return t;
    TupT *tp = as_tup(t);
    V u = tup_uni(tp);
    TB b;
    tb_init(&b);
    b.ro = tup_ro(tp);
    bool ch = false;
    for (uint32_t i = 0; i < tp->len; i++) {
      V e = u ? u : tp->e[i];
      V x = eq_strip_d(e, depth + 1);
      if (x != e) ch = true;
      // (an optional element's type has undefined: tb_finish adds it again)
      tb_push(&b, tup_kind(tp, i) == E_OPT ? remove_undefined(x) : x, tup_kind(tp, i), tup_name(tp, i));
    }
    return ch ? tb_finish(&b) : t;
  }
  case K_ARRAY: {
    if (!eq_has_marker(t, 0)) return t;
    V e = eq_strip_d(((ArrT *)t)->el, depth + 1);
    return e == ((ArrT *)t)->el ? t : mk_array(e, ((ArrT *)t)->ro);
  }
  default: return t;
  }
}

V eq_strip(V t) { return subst_made ? eq_strip_d(t, 0) : t; }

static bool eq_has_marker(V t, int depth) {
  if ((t & 3) || depth > 16) return false;
  switch (kind(t)) {
  case K_USYM: return ((USymT *)t)->id < 0;
  case K_UNION:
  case K_INTER:
    for (uint32_t i = 0; i < set_n(t); i++)
      if (eq_has_marker(set_m(t, i), depth + 1)) return true;
    return false;
  case K_TUPLE: {
    TupT *x = as_tup(t);
    V u = tup_uni(x);
    if (u) return eq_has_marker(u, depth + 1);
    for (uint32_t i = 0; i < x->len; i++)
      if (eq_has_marker(x->e[i], depth + 1)) return true;
    return false;
  }
  case K_ARRAY: return eq_has_marker(((ArrT *)t)->el, depth + 1);
  case K_FN: {
    FnT *f = (FnT *)t;
    for (uint32_t i = 0; i < f->np; i++)
      if (eq_has_marker(f->params[i].ty, depth + 1)) return true;
    return eq_has_marker(f->ret, depth + 1);
  }
  case K_DEFERRED: {
    DefT *d = (DefT *)t;
    return eq_has_marker(d->c, depth + 1) || eq_has_marker(d->e, depth + 1) || eq_has_marker(d->t, depth + 1) ||
           eq_has_marker(d->f, depth + 1);
  }
  default: return false;
  }
}
