// tstc runtime: values of type-level TypeScript programs compiled to native
// code, and the operations generated code calls.
//
// A value (V) is a 64-bit word:
//   ...1    a 63-bit integer (a bigint literal type that fits)
//   ..110   an integer x outside those with y = x ^ 2^62 a 61-bit integer:
//           y << 3 | 6 (lib/pure's floats are the integers of their IEEE 754
//           bits: with the 63-bit ones, those of all finite floats of
//           magnitude 2^-255 to 2^256 but -0 are immediate)
//   ..010   a keyword type (any, string, true, ...): kind << 3 | 2
//   ..000   a pointer to a heap object whose first word is its kind
#ifndef TSTC_H
#define TSTC_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

typedef uint64_t V;

enum {
  K_ANY, K_UNKNOWN, K_NEVER, K_STRING, K_NUMBER, K_BIGINT, K_SYMBOL, K_OBJECTKW,
  K_NULL, K_UNDEFINED, K_VOID, K_TRUE, K_FALSE,
  K_STRLIT = 16, K_NUMLIT, K_BIGLIT, K_TPL, K_TUPLE, K_ARRAY, K_OBJ, K_UNION,
  K_INTER, K_FN, K_USYM, K_GENFN, K_DEFERRED, K_INT, K_VEC, K_MAP, K_STORE,
  K_STRMAP, K_LIBM, K_SUBST,
  K_COUNT
};

#define IMM(k) ((((V)(k)) << 3) | 2)
#define V_ANY IMM(K_ANY)
#define V_UNKNOWN IMM(K_UNKNOWN)
#define V_NEVER IMM(K_NEVER)
#define V_STRING IMM(K_STRING)
#define V_NUMBER IMM(K_NUMBER)
#define V_BIGINT IMM(K_BIGINT)
#define V_SYMBOL IMM(K_SYMBOL)
#define V_OBJECTKW IMM(K_OBJECTKW)
#define V_NULL IMM(K_NULL)
#define V_UNDEFINED IMM(K_UNDEFINED)
#define V_VOID IMM(K_VOID)
#define V_TRUE IMM(K_TRUE)
#define V_FALSE IMM(K_FALSE)

typedef struct { uint32_t tag, aux; } Hdr;

static inline int kind(V v) {
  if (v & 1) return K_INT;
  if (v & 2) return (v & 4) ? K_INT : (int)((v >> 3) & 63);  // (a heap's version and id are above)
  return (int)((Hdr *)v)->tag;
}

// ---------------------------------------------------------------------------
// Memory (gc.c): a conservative mark-sweep collector. Memory is zeroed.

void *gc_alloc(size_t n);         // may hold pointers
void *gc_alloc_atomic(size_t n);  // holds no pointers
void *gc_realloc_atomic(void *p, size_t old, size_t n);
void gc_add_root(void *p, size_t n);
void gc_collect(void);
void gc_init(void *stack_base);
// threads: stacks to scan while they do not run program code
typedef struct GcThread GcThread;
GcThread *gc_thread_register(void *stack_base);
GcThread *gc_current(void);
V *env_stack_new(void);
void gc_set_env_stack(V *base);  // of the current thread
void gc_thread_unregister(GcThread *t);
void gc_thread_leave(GcThread *t);  // about to block: record registers and sp
void gc_thread_enter(GcThread *t);
extern size_t gc_bytes_live, gc_collections;
extern double gc_ms;
// objects of a typed layout are scanned by a function of their own
enum { GC_PLAIN, GC_ATOMIC, GC_MAP, GC_MNODE, GC_CELLS, GC_NFLAVORS };
void *gc_alloc_flavor(size_t n, int flavor);
typedef void (*GcScanner)(char *p, size_t n, bool cand);
void gc_set_scanner(int flavor, GcScanner f);
// marks what the value refers to; with cand, an integer in it may be a cell
// index of the cell store (scanners use this for their fields)
void gc_mark(V w, bool cand);
void gc_mark_cells32(const V *c, uint64_t kw);  // 32 cells of the cell store and their word of kinds
void gc_scan_range(void *p, size_t n, bool cand);
// a range for the marking threads: n bytes at p, scanned by the flavor's
// scanner (GC_CELLS: cells of the cell store); with the cells marked so far
void gc_push_range(void *p, size_t n, int flavor);
void gc_add_marked_cells(int64_t n);
extern int64_t gc_marked_cells;
// The cell store (cellgc.c): collected with the rest at its safe points.
typedef struct {
  void (*roots)(void);    // a plain collection: the cells are roots
  void (*begin)(void);    // a collection of the store begins (sets gc_cand_lo/hi)
  void (*cand)(int64_t);  // an integer in [gc_cand_lo, gc_cand_hi) found by a candidate scan
  void (*sweep)(void);    // frees the cells not marked
} GcCellHooks;
void gc_set_cell_hooks(const GcCellHooks *h);
void gc_each_marked(void (*f)(char *p, size_t n, int flavor));
extern int64_t gc_cand_lo, gc_cand_hi;
// the cell store's bitmaps, for a quick test of candidates (one heap only)
typedef struct { uint64_t *start, *mark; } GcCellsFast;
extern GcCellsFast gc_cells_fast;
void gc_collect_cells(void);
bool gc_due(void);  // !gc_is_disabled() && gc_grown_since > gc_due_at
extern size_t gc_grown_since, gc_due_at;
bool gc_is_disabled(void);
extern size_t gc_extra_live;  // bytes of store cells in use (counted in the collection threshold)

// ---------------------------------------------------------------------------
// Integers

typedef struct { uint32_t tag, aux; int64_t v; } IntT;

// (beyond 63 bits: the ..110 form, else an IntT)
V box_int(int64_t x);
static inline V mk_int(int64_t x) {
  if (x >= -(INT64_C(1) << 62) && x < (INT64_C(1) << 62)) return ((V)x << 1) | 1;
  return box_int(x);
}
static inline int64_t int_val(V v) {
  if (v & 1) return ((int64_t)v) >> 1;
  if (v & 2) return (((int64_t)v) >> 3) ^ (INT64_C(1) << 62);
  return ((IntT *)v)->v;
}
static inline V mk_bool(bool b) { return b ? V_TRUE : V_FALSE; }

// ---------------------------------------------------------------------------
// Strings: views of UTF-16 code units (bytes for lib/pure's strings) in a shared,
// append-only buffer. A view that ends at the end of its buffer appends in
// place (nobody can observe code units past a view's end).

typedef struct { int32_t used, cap; uint16_t *d; } StrBuf;  // cap < 0: static
typedef struct { uint32_t tag, hash; int32_t start, len; StrBuf *buf; } Str;

static inline const uint16_t *str_d(const Str *s) { return s->buf->d + s->start; }
Str *str_new(const uint16_t *d, int32_t n);
Str *str_of_cstr(const char *c);
Str *str_of_bytes(const uint8_t *b, int32_t n);
Str *str_alloc(int32_t n);  // n code units to fill through str_wd
static inline uint16_t *str_wd(Str *s) { return s->buf->d + s->start; }
Str *str_slice(Str *s, int32_t from, int32_t to);
Str *str_concat(Str *a, Str *b);
Str *str_concat_copy(Str *a, Str *b);
bool str_eq(Str *a, Str *b);
bool str_eq_c(Str *a, const char *c);
uint32_t str_hash(Str *s);
int str_cmp(Str *a, Str *b);
bool str_starts(Str *s, Str *p);
bool str_ends(Str *s, Str *p);
int32_t str_index(Str *s, Str *p, int32_t from, int32_t limit);
extern Str *str_empty;
// growable output buffer of code units
typedef struct { uint16_t *d; int32_t n, cap; } SB;
void sb_put(SB *b, uint16_t c);
void sb_puts(SB *b, const char *c);
void sb_str(SB *b, Str *s);
Str *sb_finish(SB *b);
char *str_to_utf8(Str *s, size_t *len);  // malloc'd, NUL-terminated

static inline V V_str(Str *s) { return (V)s; }
static inline Str *as_str(V v) { return (Str *)v; }
V mk_strlit_c(const char *c);

// ---------------------------------------------------------------------------
// Other literal and structural types

typedef struct { uint32_t tag, aux; double d; } NumT;
typedef struct { uint32_t tag, aux; Str *s; } BigT;  // decimal text beyond int64
typedef struct { uint32_t tag, n; Str **texts; V *types; } TplT;  // n types, n+1 texts
typedef struct { uint32_t tag, ro; V el; } ArrT;
// union / intersection members (ix: a big union's index of its members by
// their hashes after its size and whether it is a union of primitives, or
// NULL)
typedef struct { uint32_t tag, n; int32_t *ix; V m[]; } SetT;
bool set_has(V u, V t);       // (a member of the union ty_eq to t)
bool set_prim_union(V u);     // (no member any, unknown, void, never, object, intersection or instantiable)
typedef struct { uint32_t tag, aux; int64_t id; } USymT;
typedef struct { uint32_t tag, aux; V c, e, t, f; } DefT;
// Uppercase<T> (mode 0), Lowercase (1), Capitalize (2), Uncapitalize (3) of a
// type that is no literal (string, any, a template, another mapping)
typedef struct { uint32_t tag, mode; V t; } StrMapT;
// the member `name` (a method, or a symbol-named member when name is NULL and
// sym its unique symbol) of the global interface (String, Array, ...) that is
// the apparent type of base: printed as base[name]
typedef struct { uint32_t tag, app; V base; Str *name; int64_t sym; } LibmT;
// a substitution type: base in the true branch of a conditional whose check
// type it is, constrained by the extends type (getConditionalFlowTypeOfType)
typedef struct { uint32_t tag, aux; V base, cons; } SubstT;

V mk_num(double d);
static inline double num_val(V v) { return ((NumT *)v)->d; }
V mk_biglit(Str *s);
V mk_bigint_text(Str *s);  // canonical decimal text: an integer when it fits
V mk_tpl(Str **texts, V *types, uint32_t n);
V mk_array(V el, bool ro);
V mk_usym(int64_t id);
V mk_deferred(V c, V e, V t, V f);
V mk_strmap(int mode, V t);  // as is (string_mapping applies the mapping)
V string_mapping(int mode, V t);
V mk_libm(int app, V base, Str *name, int64_t sym);
V mk_subst(V base, V cons);  // getSubstitutionType
V subst_strip(V t);          // its substitution types instantiated (as base)
V eq_strip(V t);             // as an instantiated signature has it (ops.c)
extern bool subst_made;      // some substitution type was made

// Tuples. Element kinds:
enum { E_REQ = 0, E_OPT = 1, E_REST = 2 };
// a tuple's elements in a growable buffer; uni nonzero: every element in it
// is that value (a uniform buffer: views of any length up to used are the
// same tuple, so [...A, ...B] and [...A, x] of uniform tuples make a view)
typedef struct { int32_t used, cap; V *d; V uni; } VBuf;
typedef struct {
  uint32_t ro;
  VBuf *buf;      // elements live in buf (appends in place) when not NULL
  uint8_t *kinds; // NULL: all required
  Str **names;    // NULL: unnamed (or entries NULL)
} TupExt;
typedef struct { uint32_t tag, len; V *e; TupExt *x; } TupT;

static inline TupT *as_tup(V v) { return (TupT *)v; }
static inline int tup_kind(TupT *t, uint32_t i) { return t->x && t->x->kinds ? t->x->kinds[i] : E_REQ; }
static inline Str *tup_name(TupT *t, uint32_t i) { return t->x && t->x->names ? t->x->names[i] : NULL; }
static inline bool tup_ro(TupT *t) { return t->x && t->x->ro; }
static inline bool tup_plain(TupT *t) { return !t->x || (!t->x->kinds && !t->x->names && !t->x->ro); }
static inline bool tup_nokinds(TupT *t) { return !t->x || !t->x->kinds; }
// the element of a uniform tuple, 0 when it is not one (or empty)
static inline V tup_uni(TupT *t) { return t->len && t->x && t->x->buf ? t->x->buf->uni : 0; }
V mk_tuple(const V *e, uint32_t n);          // plain
V mk_tuple0(void);
V mk_tuple1(V a);
V mk_tuple2(V a, V b);
V mk_tuple3(V a, V b, V c);
TupT *tup_alloc(uint32_t n);                 // plain, elements to fill
V tup_slice(TupT *t, uint32_t from, uint32_t to);
V tup_append(TupT *t, V x);                  // [...t, x]
V tup_append_n(TupT *t, const V *xs, uint32_t n);  // [...t, ...xs]
V tup_uni_view(TupT *t, uint32_t len);       // t uniform: the tuple of len such elements
int tup_fixed_len(TupT *t);                  // -1 when it has optional/rest elements
extern V empty_tuple;
// tuple builder (kinds and names)
typedef struct { V *e; uint8_t *k; Str **nm; uint32_t n, cap; bool any_k, any_n, ro; } TB;
void tb_init(TB *b);
void tb_push(TB *b, V t, int kind, Str *name);
V tb_finish(TB *b);
V tuple_normalize(TB *b);  // as the checker normalizes tuple types, then tb_finish

// Objects
// Generated functions of a frame return a pair: (v, 0) is the value v,
// (a, b) with b nonzero the tuple [a, b], not allocated (two results,
// e.g. [heap, value]). pair_v makes it a value.
typedef struct { V a, b; } VPair;
typedef VPair (*Thunk)(V *env);
V mk_tuple2(V a, V b);
// (a, PAIR_ONE) is the tuple [a] (PAIR_ONE is no value: not an integer,
// keyword or object pointer)
#define PAIR_ONE ((V)4)
V mk_tuple1(V a);
static inline V pair_v(VPair p) { return p.b ? (p.b == PAIR_ONE ? mk_tuple1(p.a) : mk_tuple2(p.a, p.b)) : p.a; }
// natives with two results return them so too (natives.mbt: pair_natives)
#define PAIR(a, b) ((VPair){(a), (b)})
typedef struct {
  Str *name;
  V ty;          // 0 while lazy
  Thunk th;
  V *env;
  uint64_t seq;
  uint8_t opt, ro, numeric, forcing;
  uint8_t post;  // applied to the type once evaluated: PROP_*
} Prop;
// what a property's type gets once evaluated
enum { PROP_AS_IS, PROP_OPT, PROP_MAPPED_OPT, PROP_STRIP };
typedef struct { V key, ty; uint32_t ro; } IndexSig;
typedef struct { Str *name; V ty; uint8_t opt, rest; } Param;
typedef struct { uint32_t tag, ctor; uint32_t np, aux; V ret; Param *params; } FnT;
typedef struct {
  uint32_t tag, np;
  uint32_t ni, nc, hcap, aux;
  Prop *props;      // by seq
  int32_t *hidx;    // open addressing over props (hcap slots) when np > 8
  IndexSig *index;
  FnT **calls;
} ObjT;
typedef struct {
  uint32_t tag, nslots;
  uint32_t frame, aux;
  const int64_t *slots;
  Thunk code;
  V *env;
} GenFnT;

static inline ObjT *as_obj(V v) { return (ObjT *)v; }
// ObjT.aux: the object type of a mapped type (not an anonymous object type
// literal: an empty one is no `{}` to intersections)
#define OBJ_MAPPED 1u
// ObjT.aux: an interface's type (no anonymous type: no inferable index)
#define OBJ_IFACE 2u
uint64_t fresh_seq(void);
V prop_value(Prop *p);
Prop *obj_get(ObjT *o, Str *name);
// object builder
// a table of names to indices (open addressing), for builders that would
// otherwise look each name up in all those before it
typedef struct { Str **k; int32_t *v; uint32_t n, cap; } NameIx;
int32_t nix_get(NameIx *x, Str *name);
void nix_put(NameIx *x, Str *name, int32_t i);
// object builder (names: an index of the first hn properties' names)
typedef struct { Prop *p; uint32_t n, cap; IndexSig *ix; uint32_t ni, icap; FnT **c; uint32_t nc, ccap; NameIx names; uint32_t hn; } OB;
int32_t ob_find(OB *b, Str *name);
void ob_init(OB *b);
// adds or replaces a property; keep_seq keeps the order of a replaced one
void ob_prop(OB *b, Str *name, V ty, Thunk th, V *env, bool opt, bool ro, bool numeric, bool keep_seq);
// the same with the treatment of the type (PROP_*; ty given: applied now)
void ob_prop_x(OB *b, Str *name, V ty, Thunk th, V *env, bool opt, bool ro, bool numeric, bool keep_seq, int post);
V prop_post(int post, V t);
void ob_index(OB *b, V key, V ty, bool ro);
void ob_call(OB *b, FnT *f);
V ob_finish(OB *b);
FnT *mk_fn(Param *params, uint32_t np, V ret, bool ctor);
V mk_genfn(const int64_t *slots, uint32_t nslots, Thunk code, V *env, uint32_t frame);

// ---------------------------------------------------------------------------
// Type operations (ty.c, relate.c, ops.c)

bool ty_eq(V a, V b);
bool ty_identical(V a, V b);
bool is_subtype(V s, V t);         // TypeScript's strict subtype relation
// TypeScript's type flags (relate.c)
uint32_t ty_flags(V t);
#define TF_ANY (1u << 0)
#define TF_UNKNOWN (1u << 1)
#define TF_UNDEFINED (1u << 2)
#define TF_NULL (1u << 3)
#define TF_VOID (1u << 4)
#define TF_STRING (1u << 5)
#define TF_NUMBER (1u << 6)
#define TF_BIGINT (1u << 7)
#define TF_BOOLEAN (1u << 8)
#define TF_ESSYMBOL (1u << 9)
#define TF_STRLIT (1u << 10)
#define TF_NUMLIT (1u << 11)
#define TF_BIGLIT (1u << 12)
#define TF_BOOLLIT (1u << 13)
#define TF_USYM (1u << 14)
#define TF_NONPRIM (1u << 17)
#define TF_NEVER (1u << 18)
#define TF_TPARAM (1u << 19)
#define TF_OBJECT (1u << 20)
#define TF_TPL (1u << 22)
#define TF_STRMAP (1u << 23)
#define TF_SUBST (1u << 24)
#define TF_COND (1u << 26)
#define TF_UNION (1u << 27)
#define TF_INTER (1u << 28)
#define TF_STRINGLIKE (TF_STRING | TF_STRLIT | TF_TPL | TF_STRMAP)
#define TF_NUMBERLIKE (TF_NUMBER | TF_NUMLIT)
#define TF_BIGINTLIKE (TF_BIGINT | TF_BIGLIT)
#define TF_BOOLEANLIKE (TF_BOOLEAN | TF_BOOLLIT)
#define TF_SYMBOLLIKE (TF_ESSYMBOL | TF_USYM)
#define TF_VOIDLIKE (TF_VOID | TF_UNDEFINED)
#define TF_NULLABLE (TF_UNDEFINED | TF_NULL)
#define TF_LITERAL (TF_STRLIT | TF_NUMLIT | TF_BIGLIT | TF_BOOLLIT)
#define TF_UNIT (TF_LITERAL | TF_USYM | TF_NULLABLE)
#define TF_PRIMITIVE (TF_STRINGLIKE | TF_NUMBERLIKE | TF_BIGINTLIKE | TF_BOOLEANLIKE | TF_SYMBOLLIKE | TF_VOIDLIKE | TF_NULL)
#define TF_DEFNONNULL (TF_STRINGLIKE | TF_NUMBERLIKE | TF_BIGINTLIKE | TF_BOOLEANLIKE | TF_SYMBOLLIKE | TF_OBJECT | TF_NONPRIM)
#define TF_DISJOINT (TF_NONPRIM | TF_STRINGLIKE | TF_NUMBERLIKE | TF_BIGINTLIKE | TF_BOOLEANLIKE | TF_SYMBOLLIKE | TF_VOIDLIKE | TF_NULL)
#define TF_SINGLETON (TF_ANY | TF_UNKNOWN | TF_STRING | TF_NUMBER | TF_BOOLEAN | TF_BIGINT | TF_ESSYMBOL | TF_VOID | TF_UNDEFINED | TF_NULL | TF_NEVER | TF_NONPRIM)
#define TF_INSTANTIABLE (TF_TPARAM | TF_COND | TF_TPL | TF_STRMAP | TF_SUBST)
#define TF_STRUCTURED (TF_OBJECT | TF_UNION | TF_INTER)
#define TF_INCLUDES_MASK (TF_ANY | TF_UNKNOWN | TF_PRIMITIVE | TF_NEVER | TF_OBJECT | TF_UNION | TF_INTER | TF_NONPRIM | TF_TPL | TF_STRMAP)
#define TF_NOT_PRIMITIVE_UNION (TF_ANY | TF_UNKNOWN | TF_VOID | TF_NEVER | TF_OBJECT | TF_INTER | TF_INSTANTIABLE)
bool is_empty_anon_obj(V t);  // `{}` (an empty object type literal)
V reduced_type(V t);          // getReducedType
bool is_pattern_literal(V t);
bool is_literal_type(V t);    // a unit type or a union of them
// the well-known symbols (Symbol.iterator, ...) as unique symbol types
#define WK_SYM_BASE ((int64_t)1 << 40)
enum { WK_ITERATOR, WK_UNSCOPABLES, WK_TO_STRING_TAG, WK_TO_PRIMITIVE, WK_COUNT };
V wk_symbol(int i);
const char *wk_symbol_name(int64_t id);  // NULL: no well-known symbol
Str *wk_prop_name(int i);             // the name of a property it names
int wk_of_prop_name(Str *s);          // -1: no such name
// The global interfaces of the lib (apparent.c): the apparent types of
// primitives, arrays and tuples
enum { APP_NONE, APP_STRING, APP_NUMBER, APP_BOOLEAN, APP_BIGINT, APP_SYMBOL, APP_ARRAY, APP_RO_ARRAY, APP_EMPTY };
int apparent_of(V t);
typedef struct {
  const char *name;  // NULL: symbol-named (sym)
  int sym;           // WK_*
  uint8_t method;    // a method (its type is a lib member type), or a property
  uint8_t ro;
} LibMember;
const LibMember *lib_members(int app, int *n);
// the type of a member of the interface app for base (name: m's name as a
// string, made once)
V lib_member_type(int app, V base, const LibMember *m, Str *name);
// the members of a type's apparent type, as relations and property access
// see them (getPropertiesOfType, getIndexInfosOfType, signatures)
typedef struct {
  Str *name;   // NULL: symbol-named (sym)
  int64_t sym;
  V ty;        // the declared type (with undefined when optional)
  bool opt, ro, numeric;
} PInfo;
typedef struct {
  PInfo *p;
  uint32_t np;
  IndexSig *ix;
  uint32_t ni;
  V *calls, *ctors;  // FnT or GenFnT
  uint32_t nc, nct;
} Members;
void members_of(V t, Members *m);
// whether a required named member of t is not in(ctx, name)
bool required_member_not_in(V t, bool (*in)(const void *ctx, Str *name), const void *ctx);
bool member_prop(V t, Str *name, PInfo *out);  // getPropertyOfType
V opt_type(V t);       // t | undefined (as optional properties and elements have it)
V remove_undefined(V t);
bool is_literal(V t);
// the same element type: identical, or equal string/number literals
static inline bool same_el(V a, V b) {
  if (a == b) return true;
  if ((a | b) & 3) return false;
  int k = kind(a);
  return (k == K_STRLIT || k == K_NUMLIT) && kind(b) == k && ty_eq(a, b);
}
V mk_union(const V *items, uint32_t n);
V mk_union2(V a, V b);
V mk_inter(const V *items, uint32_t n);
V mk_inter_node(const V *items, uint32_t n);  // as written in a program
static inline uint32_t set_n(V u) { return ((SetT *)u)->n; }
static inline V set_m(V u, uint32_t i) { return ((SetT *)u)->m[i]; }
bool is_assignable(V s, V t);
V index_access(V o, V k);
V keyof_ty(V t);
V eval_tpl(Str **texts, const V *vals, uint32_t n);
V instantiate_generic(GenFnT *g, const V *markers, uint32_t n);
bool lit_to_str(V t, Str **out);
bool key_name(V k, Str **out);
bool get_prop_of(V t, Str *name, V *ty, bool *opt);
V tuple_elem_union(TupT *t);
V merge_objects(ObjT **objs, uint32_t n);

// growable array of values
typedef struct { V *d; uint32_t n, cap; } VA;
static inline void va_init(VA *a) { a->d = 0; a->n = a->cap = 0; }
void va_push(VA *a, V v);

// numbers
void js_number_to_sb(double d, SB *b);
Str *str_of_number(double d);
bool parse_js_number(Str *s, double *out);
bool parse_canonical_number(Str *s, double *out);
Str *str_of_int(int64_t v);
Str *str_of_uint(uint64_t v);

// printing (print.c)
void write_ty(SB *b, V t, int prec, int depth);
char *ty_to_cstr(V t);         // malloc'd
char *ty_to_cstr_short(V t);   // at most 200 characters

// errors
_Noreturn void die(const char *fmt, ...);
// a failure (a native where its definition is Panic<M>): the value of an
// enclosing alias with a handler (`@catch`, try.c), or the end of the program
_Noreturn void rt_error(const char *fmt, ...);
void rt_trace_push(const char *name);

#endif
