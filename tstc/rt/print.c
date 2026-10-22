// Printing types as TypeScript source (the output of `dump` and of programs
// whose result is not a string).
#include "tstc.h"

#include <stdio.h>
#include <stdlib.h>

static void quote_str(SB *b, Str *s) {
  static const char hex[] = "0123456789abcdef";
  const uint16_t *d = str_d(s);
  sb_put(b, '"');
  for (int32_t i = 0; i < s->len; i++) {
    uint16_t c = d[i];
    switch (c) {
    case '"': sb_puts(b, "\\\""); break;
    case '\\': sb_puts(b, "\\\\"); break;
    case '\n': sb_puts(b, "\\n"); break;
    case '\r': sb_puts(b, "\\r"); break;
    case '\t': sb_puts(b, "\\t"); break;
    default:
      if (c < 0x20) {
        sb_puts(b, "\\u00");
        sb_put(b, hex[c >> 4]);
        sb_put(b, hex[c & 15]);
      } else {
        sb_put(b, c);
      }
    }
  }
  sb_put(b, '"');
}

static bool is_id_start(uint16_t c) {
  return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || c == '$' || c > 127;
}

static bool is_ident_name(Str *s) {
  const uint16_t *d = str_d(s);
  if (s->len == 0 || !is_id_start(d[0])) return false;
  for (int32_t i = 1; i < s->len; i++)
    if (!is_id_start(d[i]) && !(d[i] >= '0' && d[i] <= '9')) return false;
  return true;
}

static void prop_key(SB *b, Str *s) {
  double d;
  int wk = wk_of_prop_name(s);
  if (wk >= 0) {
    sb_puts(b, "[Symbol.");
    sb_puts(b, wk_symbol_name(WK_SYM_BASE + wk));
    sb_put(b, ']');
    return;
  }
  if (is_ident_name(s) || parse_canonical_number(s, &d)) sb_str(b, s);
  else quote_str(b, s);
}

static void escape_tpl(SB *b, Str *s) {
  const uint16_t *d = str_d(s);
  for (int32_t i = 0; i < s->len; i++) {
    uint16_t c = d[i];
    if (c == '`' || c == '\\') {
      sb_put(b, '\\');
      sb_put(b, c);
    } else if (c == '$' && i + 1 < s->len && d[i + 1] == '{') {
      sb_puts(b, "\\$");
    } else if (c == '\n') {
      sb_puts(b, "\\n");
    } else if (c == '\r') {
      sb_puts(b, "\\r");
    } else if (c < 0x20) {
      static const char hex[] = "0123456789abcdef";
      sb_puts(b, "\\u00");
      sb_put(b, hex[c >> 4]);
      sb_put(b, hex[c & 15]);
    } else {
      sb_put(b, c);
    }
  }
}

static void write_params(SB *b, FnT *f, int depth) {
  sb_put(b, '(');
  for (uint32_t i = 0; i < f->np; i++) {
    if (i > 0) sb_puts(b, ", ");
    Param *p = &f->params[i];
    if (p->rest) sb_puts(b, "...");
    sb_str(b, p->name);
    if (p->opt) sb_put(b, '?');
    sb_puts(b, ": ");
    write_ty(b, p->ty, 0, depth + 1);
  }
  sb_put(b, ')');
}

static void write_sig(SB *b, FnT *f, int depth) {
  if (f->ctor) sb_puts(b, "new ");
  write_params(b, f, depth);
  sb_puts(b, ": ");
  write_ty(b, f->ret, 0, depth + 1);
}

static const char *kw_names[] = {"any",  "unknown",   "never", "string", "number",
                                 "bigint", "symbol", "object", "null",   "undefined",
                                 "void", "true",      "false"};

void map_write(SB *b, V m, int depth);  // map.c

// the parts of an object type: 1 its index signatures, 2 its properties, 3 all
static void write_obj_parts(SB *b, ObjT *o, int which, int depth) {
  sb_puts(b, "{ ");
  if (which & 1)
    for (uint32_t i = 0; i < o->nc; i++) {
      write_sig(b, o->calls[i], depth);
      sb_puts(b, "; ");
    }
  if (which & 1)
    for (uint32_t i = 0; i < o->ni; i++) {
      IndexSig *ix = &o->index[i];
      if (ix->ro) sb_puts(b, "readonly ");
      sb_puts(b, "[x: ");
      write_ty(b, ix->key, 0, depth + 1);
      sb_puts(b, "]: ");
      write_ty(b, ix->ty, 0, depth + 1);
      sb_puts(b, "; ");
    }
  if (which & 2)
    for (uint32_t i = 0; i < o->np; i++) {
      Prop *p = &o->props[i];
      if (p->ro) sb_puts(b, "readonly ");
      prop_key(b, p->name);
      if (p->opt) sb_put(b, '?');
      sb_puts(b, ": ");
      write_ty(b, prop_value(p), 0, depth + 1);
      sb_puts(b, "; ");
    }
  sb_put(b, '}');
}

// a property an index signature applies to whose type it does not admit
static bool index_conflict(ObjT *o) {
  for (uint32_t i = 0; i < o->np; i++) {
    Prop *p = &o->props[i];
    double d;
    bool numeric = parse_canonical_number(p->name, &d);
    V pt = prop_value(p);
    for (uint32_t j = 0; j < o->ni; j++) {
      V k = o->index[j].key;
      bool applies = k == V_STRING || (k == V_NUMBER && numeric) || (kind(k) == K_TPL && is_assignable((V)p->name, k));
      if (applies && !is_assignable(pt, o->index[j].ty)) return true;
    }
  }
  return false;
}

// the values being written (a multiset): one met again within itself is
// written as the name of the alias it is the value of
typedef struct { V v; uint32_t n; } PEnt;
static PEnt *pset;
static uint32_t pcap, pused;

static PEnt *pset_at(V v) {
  uint32_t m = pcap - 1;
  uint32_t i = (uint32_t)((v >> 3) * UINT64_C(0x9E3779B97F4A7C15) >> 32) & m;
  while (pset[i].v && pset[i].v != v) i = (i + 1) & m;
  return &pset[i];
}

static void pset_grow(void) {
  PEnt *old = pset;
  uint32_t oc = pcap;
  pcap = pcap ? pcap * 2 : 256;
  pset = calloc(pcap, sizeof(PEnt));
  if (!pset) die("print: out of memory");
  pused = 0;
  for (uint32_t i = 0; i < oc; i++)
    if (old[i].v && old[i].n) {
      *pset_at(old[i].v) = old[i];
      pused++;
    }
  free(old);
}

const char *knot_name(V v);  // main.c
static void write_ty_s(SB *b, V t, int prec, int depth);

void write_ty(SB *b, V t, int prec, int depth) {
  if (t & 3) {
    write_ty_s(b, t, prec, depth);
    return;
  }
  switch (kind(t)) {
  case K_OBJ: case K_ARRAY: case K_TUPLE: case K_FN: case K_GENFN: case K_UNION: case K_INTER: break;
  default: write_ty_s(b, t, prec, depth); return;
  }
  if ((pused + 1) * 2 > pcap) pset_grow();
  PEnt *e = pset_at(t);
  if (e->n) {
    const char *nm = knot_name(t);
    if (nm) {
      sb_puts(b, nm);
      return;
    }
  }
  if (!e->v) {
    e->v = t;
    pused++;
  }
  e->n++;
  write_ty_s(b, t, prec, depth);
  // (the set may have grown)
  pset_at(t)->n--;
}

static void write_ty_s(SB *b, V t, int prec, int depth) {
  // (values nested deeper are cut short: the output is no longer TypeScript)
  if (depth > 20000) {
    sb_puts(b, "...");
    return;
  }
  int k = kind(t);
  if (k < K_STRLIT) {
    sb_puts(b, kw_names[k]);
    return;
  }
  char buf[64];
  switch (k) {
  case K_STRLIT: quote_str(b, as_str(t)); return;
  case K_NUMLIT: js_number_to_sb(num_val(t), b); return;
  case K_BIGLIT: sb_str(b, ((BigT *)t)->s); sb_put(b, 'n'); return;
  case K_INT:
    snprintf(buf, sizeof buf, "%lldn", (long long)int_val(t));
    sb_puts(b, buf);
    return;
  case K_USYM: {
    const char *wk = wk_symbol_name(((USymT *)t)->id);
    if (wk) {
      sb_puts(b, "typeof Symbol.");
      sb_puts(b, wk);
      return;
    }
    snprintf(buf, sizeof buf, "unique symbol /*%lld*/", (long long)((USymT *)t)->id);
    sb_puts(b, buf);
    return;
  }
  case K_SUBST: {
    // (written so, the checker makes the same substitution type)
    SubstT *x = (SubstT *)t;
    sb_put(b, '(');
    write_ty(b, x->base, 3, depth + 1);
    sb_puts(b, " extends ");
    write_ty(b, x->cons, 1, depth + 1);
    sb_puts(b, " ? ");
    write_ty(b, x->base, 1, depth + 1);
    sb_puts(b, " : never)");
    return;
  }
  case K_STRMAP: {
    static const char *names[] = {"Uppercase", "Lowercase", "Capitalize", "Uncapitalize"};
    StrMapT *m = (StrMapT *)t;
    sb_puts(b, names[m->mode & 3]);
    sb_put(b, '<');
    write_ty(b, m->t, 0, depth + 1);
    sb_put(b, '>');
    return;
  }
  case K_LIBM: {
    // the member of the apparent type: base[name]
    LibmT *l = (LibmT *)t;
    sb_put(b, '(');
    write_ty(b, l->base, 0, depth + 1);
    sb_puts(b, ")[");
    if (l->name) {
      quote_str(b, l->name);
    } else {
      sb_puts(b, "typeof Symbol.");
      sb_puts(b, wk_symbol_name(l->sym));
    }
    sb_put(b, ']');
    return;
  }
  case K_TPL: {
    TplT *p = (TplT *)t;
    sb_put(b, '`');
    for (uint32_t i = 0; i < p->n; i++) {
      escape_tpl(b, p->texts[i]);
      sb_puts(b, "${");
      write_ty(b, p->types[i], 0, depth + 1);
      sb_put(b, '}');
    }
    escape_tpl(b, p->texts[p->n]);
    sb_put(b, '`');
    return;
  }
  case K_TUPLE: {
    TupT *tp = as_tup(t);
    // (readonly binds looser than [] of an array type)
    bool ro_paren = tup_ro(tp) && prec >= 3;
    if (ro_paren) sb_put(b, '(');
    if (tup_ro(tp)) sb_puts(b, "readonly ");
    sb_put(b, '[');
    for (uint32_t i = 0; i < tp->len; i++) {
      if (i > 0) sb_puts(b, ", ");
      int ek = tup_kind(tp, i);
      Str *n = tup_name(tp, i);
      if (n && n->len == 0) n = NULL;
      if (n) {
        if (ek == E_REST) sb_puts(b, "...");
        sb_str(b, n);
        if (ek == E_OPT) sb_put(b, '?');
        sb_puts(b, ": ");
        if (ek == E_REST) {
          write_ty(b, tp->e[i], 3, depth + 1);
          sb_puts(b, "[]");
        } else {
          write_ty(b, tp->e[i], 0, depth + 1);
        }
      } else if (ek == E_REST) {
        sb_puts(b, "...");
        write_ty(b, tp->e[i], 3, depth + 1);
        sb_puts(b, "[]");
      } else if (ek == E_OPT) {
        write_ty(b, tp->e[i], 3, depth + 1);
        sb_put(b, '?');
      } else {
        write_ty(b, tp->e[i], 0, depth + 1);
      }
    }
    sb_put(b, ']');
    if (ro_paren) sb_put(b, ')');
    return;
  }
  case K_ARRAY: {
    ArrT *a = (ArrT *)t;
    if (a->ro) {
      if (prec >= 3) sb_put(b, '(');
      sb_puts(b, "readonly ");
    }
    write_ty(b, a->el, 3, depth + 1);
    sb_puts(b, "[]");
    if (a->ro && prec >= 3) sb_put(b, ')');
    return;
  }
  case K_OBJ: {
    ObjT *o = as_obj(t);
    if (o->np == 0 && o->ni == 0 && o->nc == 0) {
      // (an empty mapped type is no `{}`: intersections keep it)
      sb_puts(b, o->aux & (OBJ_MAPPED | OBJ_IFACE) ? "{ [K in never]: never }" : "{}");
      return;
    }
    if (o->ni && o->np && !o->nc && index_conflict(o)) {
      // properties an index signature does not admit (from a mapped type):
      // no type literal can be written so, a mapped type over the parts can
      sb_puts(b, "{ [__K in keyof (");
      write_obj_parts(b, o, 1, depth);
      sb_puts(b, " & ");
      write_obj_parts(b, o, 2, depth);
      sb_puts(b, ")]: (");
      write_obj_parts(b, o, 1, depth);
      sb_puts(b, " & ");
      write_obj_parts(b, o, 2, depth);
      sb_puts(b, ")[__K] }");
      return;
    }
    write_obj_parts(b, o, 3, depth);
    return;
  }
  case K_UNION: {
    SetT *s = (SetT *)t;
    bool has_true = false, has_false = false;
    for (uint32_t i = 0; i < s->n; i++) {
      if (s->m[i] == V_TRUE) has_true = true;
      if (s->m[i] == V_FALSE) has_false = true;
    }
    bool boolean = has_true && has_false;
    uint32_t items = 0;
    for (uint32_t i = 0; i < s->n; i++)
      if (!(boolean && (s->m[i] == V_TRUE || s->m[i] == V_FALSE))) items++;
    if (boolean && items == 0) {
      sb_puts(b, "boolean");
      return;
    }
    if (prec >= 1) sb_put(b, '(');
    bool first = true;
    for (uint32_t i = 0; i < s->n; i++) {
      V m = s->m[i];
      if (boolean && (m == V_TRUE || m == V_FALSE)) continue;
      if (!first) sb_puts(b, " | ");
      first = false;
      write_ty(b, m, 1, depth + 1);
    }
    if (boolean) {
      if (!first) sb_puts(b, " | ");
      sb_puts(b, "boolean");
    }
    if (prec >= 1) sb_put(b, ')');
    return;
  }
  case K_INTER: {
    SetT *s = (SetT *)t;
    if (prec >= 2) sb_put(b, '(');
    for (uint32_t i = 0; i < s->n; i++) {
      if (i > 0) sb_puts(b, " & ");
      write_ty(b, s->m[i], 2, depth + 1);
    }
    if (prec >= 2) sb_put(b, ')');
    return;
  }
  case K_FN: {
    FnT *f = (FnT *)t;
    if (prec >= 1) sb_put(b, '(');
    if (f->ctor) sb_puts(b, "new ");
    write_params(b, f, depth);
    sb_puts(b, " => ");
    write_ty(b, f->ret, 0, depth + 1);
    if (prec >= 1) sb_put(b, ')');
    return;
  }
  case K_GENFN: sb_puts(b, "(<T>(...args: any[]) => any)"); return;
  case K_STORE: sb_puts(b, "Heap"); return;
  case K_MAP: map_write(b, t, depth); return;
  case K_DEFERRED: {
    DefT *d = (DefT *)t;
    if (prec >= 1) sb_put(b, '(');
    write_ty(b, d->c, 3, depth + 1);
    sb_puts(b, " extends ");
    write_ty(b, d->e, 1, depth + 1);
    sb_puts(b, " ? ");
    write_ty(b, d->t, 1, depth + 1);
    sb_puts(b, " : ");
    write_ty(b, d->f, 1, depth + 1);
    if (prec >= 1) sb_put(b, ')');
    return;
  }
  default:
    snprintf(buf, sizeof buf, "<kind %d: %#llx>", k, (unsigned long long)t);
    sb_puts(b, buf);
  }
}

char *ty_to_cstr(V t) {
  SB b = {0};
  write_ty(&b, t, 0, 0);
  Str *s = sb_finish(&b);
  return str_to_utf8(s, NULL);
}

char *ty_to_cstr_short(V t) {
  SB b = {0};
  write_ty(&b, t, 0, 0);
  if (b.n > 200) {
    b.n = 200;
    sb_puts(&b, "...");
  }
  Str *s = sb_finish(&b);
  return str_to_utf8(s, NULL);
}
