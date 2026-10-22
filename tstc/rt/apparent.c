// The global interfaces of TypeScript's lib (target esnext) that are the
// apparent types of primitives, arrays and tuples: String, Number, Boolean,
// BigInt, Symbol, Array<T>, ReadonlyArray<T>. Their members' names are
// exact (keyof string, keyof unknown[], ...); the types of methods are lib
// member types (K_LIBM, printed as an indexed access the checker resolves).
#include "tstc.h"

#define M(n) {n, -1, 1, 0}
#define P(n, ro) {n, -1, 0, ro}
#define SM(s) {NULL, s, 1, 0}
#define SP(s) {NULL, s, 0, 1}

static const LibMember string_members[] = {
    M("anchor"), M("at"), M("big"), M("blink"), M("bold"), M("charAt"), M("charCodeAt"),
    M("codePointAt"), M("concat"), M("endsWith"), M("fixed"), M("fontcolor"), M("fontsize"),
    M("includes"), M("indexOf"), M("isWellFormed"), M("italics"), M("lastIndexOf"), P("length", 1),
    M("link"), M("localeCompare"), M("match"), M("matchAll"), M("normalize"), M("padEnd"),
    M("padStart"), M("repeat"), M("replace"), M("replaceAll"), M("search"), M("slice"), M("small"),
    M("split"), M("startsWith"), M("strike"), M("sub"), M("substr"), M("substring"), M("sup"),
    M("toLocaleLowerCase"), M("toLocaleUpperCase"), M("toLowerCase"), M("toString"),
    M("toUpperCase"), M("toWellFormed"), M("trim"), M("trimEnd"), M("trimLeft"), M("trimRight"),
    M("trimStart"), M("valueOf"), SM(WK_ITERATOR)};
static const LibMember number_members[] = {M("toExponential"), M("toFixed"), M("toLocaleString"),
                                           M("toPrecision"), M("toString"), M("valueOf")};
static const LibMember boolean_members[] = {M("valueOf")};
static const LibMember bigint_members[] = {M("toLocaleString"), M("toString"), M("valueOf"),
                                           SP(WK_TO_STRING_TAG)};
static const LibMember symbol_members[] = {P("description", 1), M("toString"), M("valueOf"),
                                           SM(WK_TO_PRIMITIVE), SP(WK_TO_STRING_TAG)};
static const LibMember array_members[] = {
    M("at"), M("concat"), M("copyWithin"), M("entries"), M("every"), M("fill"), M("filter"),
    M("find"), M("findIndex"), M("findLast"), M("findLastIndex"), M("flat"), M("flatMap"),
    M("forEach"), M("includes"), M("indexOf"), M("join"), M("keys"), M("lastIndexOf"),
    P("length", 0), M("map"), M("pop"), M("push"), M("reduce"), M("reduceRight"), M("reverse"),
    M("shift"), M("slice"), M("some"), M("sort"), M("splice"), M("toLocaleString"),
    M("toReversed"), M("toSorted"), M("toSpliced"), M("toString"), M("unshift"), M("values"),
    M("with"), SM(WK_ITERATOR), SP(WK_UNSCOPABLES)};
static const LibMember ro_array_members[] = {
    M("at"), M("concat"), M("entries"), M("every"), M("filter"), M("find"), M("findIndex"),
    M("findLast"), M("findLastIndex"), M("flat"), M("flatMap"), M("forEach"), M("includes"),
    M("indexOf"), M("join"), M("keys"), M("lastIndexOf"), P("length", 1), M("map"), M("reduce"),
    M("reduceRight"), M("slice"), M("some"), M("toLocaleString"), M("toReversed"), M("toSorted"),
    M("toSpliced"), M("toString"), M("values"), M("with"), SM(WK_ITERATOR), SP(WK_UNSCOPABLES)};

#define N(a) (int)(sizeof(a) / sizeof(a[0]))

const LibMember *lib_members(int app, int *n) {
  switch (app) {
  case APP_STRING: *n = N(string_members); return string_members;
  case APP_NUMBER: *n = N(number_members); return number_members;
  case APP_BOOLEAN: *n = N(boolean_members); return boolean_members;
  case APP_BIGINT: *n = N(bigint_members); return bigint_members;
  case APP_SYMBOL: *n = N(symbol_members); return symbol_members;
  case APP_ARRAY: *n = N(array_members); return array_members;
  case APP_RO_ARRAY: *n = N(ro_array_members); return ro_array_members;
  default: *n = 0; return NULL;
  }
}

// the interface whose members t has (APP_NONE: t's own members)
int apparent_of(V t) {
  switch (kind(t)) {
  case K_STRING: case K_STRLIT: case K_TPL: case K_STRMAP: return APP_STRING;
  case K_NUMBER: case K_NUMLIT: return APP_NUMBER;
  case K_TRUE: case K_FALSE: return APP_BOOLEAN;
  case K_BIGINT: case K_BIGLIT: case K_INT: return APP_BIGINT;
  case K_SYMBOL: return APP_SYMBOL;
  case K_USYM: return ((USymT *)t)->id >= 0 ? APP_SYMBOL : APP_NONE;
  case K_ARRAY: return ((ArrT *)t)->ro ? APP_RO_ARRAY : APP_ARRAY;
  case K_TUPLE: return tup_ro(as_tup(t)) ? APP_RO_ARRAY : APP_ARRAY;
  case K_OBJECTKW: case K_UNKNOWN: return APP_EMPTY;
  default: return APP_NONE;
  }
}

static V wk[WK_COUNT];
static const char *wk_names[WK_COUNT] = {"iterator", "unscopables", "toStringTag", "toPrimitive"};

V wk_symbol(int i) {
  if (!wk[i]) {
    wk[i] = mk_usym(WK_SYM_BASE + i);
    gc_add_root(&wk[i], sizeof(V));
  }
  return wk[i];
}

// a property named by a well-known symbol: its name is U+FFFF and the
// symbol's name (no string property name begins so in a program's types)
Str *wk_prop_name(int i) {
  static Str *names[WK_COUNT];
  if (!names[i]) {
    const char *n = wk_names[i];
    size_t len = strlen(n);
    Str *s = str_alloc((int32_t)len + 1);
    uint16_t *d = str_wd(s);
    d[0] = 0xFFFF;
    for (size_t j = 0; j < len; j++) d[j + 1] = (uint8_t)n[j];
    names[i] = s;
    gc_add_root(&names[i], sizeof(Str *));
  }
  return names[i];
}

int wk_of_prop_name(Str *s) {
  if (s->len < 2 || str_d(s)[0] != 0xFFFF) return -1;
  for (int i = 0; i < WK_COUNT; i++)
    if (str_eq(s, wk_prop_name(i))) return i;
  return -1;
}

const char *wk_symbol_name(int64_t id) {
  if (id >= WK_SYM_BASE && id < WK_SYM_BASE + WK_COUNT) return wk_names[id - WK_SYM_BASE];
  return NULL;
}

V lib_member_type(int app, V base, const LibMember *m, Str *name) {
  if (m->method || (m->name == NULL && m->sym == WK_UNSCOPABLES))
    return mk_libm(app, base, m->name ? name : NULL, m->name ? 0 : WK_SYM_BASE + m->sym);
  if (m->name == NULL) {
    // [Symbol.toStringTag]
    return app == APP_BIGINT ? mk_strlit_c("BigInt") : V_STRING;
  }
  if (m->name[0] == 'l') return V_NUMBER;  // length
  // Symbol's description
  return mk_union2(V_STRING, V_UNDEFINED);
}
