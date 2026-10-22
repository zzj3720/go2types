// Static descriptors that generated code passes to the runtime for the
// constructs it does not compile inline. Every field is 8 bytes wide, so the
// code generator lays them out as LLVM structs of i64 and ptr.
#ifndef TSTC_DESC_H
#define TSTC_DESC_H

#include "tstc.h"

// infer patterns (the extends clause of a conditional with `infer`)
// P_VAL: a type with `infer` declarations in it that is no pattern (an alias
// with them among its arguments, ...): code is the type with each slot of
// elems (P_INFER, by occurrence; ekinds: 1 in a rest position, 2 in a
// template) bound to a type parameter, inferred to as that type is.
// P_INTER (made at run time): inferences to each of elems.
enum { P_CODE, P_INFER, P_TUPLE, P_ARRAY, P_OBJ, P_TPL, P_FN, P_UNION, P_VAL, P_INTER };
typedef struct PatD PatD;
struct PatD {
  int64_t kind;
  int64_t slot;            // P_INFER
  Thunk code;              // P_CODE: the type; P_INFER: its constraint (or NULL)
  V cval;                  // P_CODE: a constant type instead of code (or 0)
  int64_t n;               // elements / properties / spans / params / members
  const PatD *const *elems;
  const int64_t *ekinds;   // P_TUPLE: element kinds
  const PatD *sub;         // P_ARRAY: element; P_FN: return type
  Str *const *names;       // P_OBJ
  const int64_t *opts;     // P_OBJ
  Str *const *texts;       // P_TPL: n + 1 texts
  int64_t ro;              // P_TUPLE / P_ARRAY
};

typedef struct {
  int64_t frame;           // slots of the environment
  int64_t dist_slot;       // -1 when not distributive
  Thunk ext;               // the extends type (or NULL: ext_cval, if needed)
  V ext_cval;
  const PatD *pat;         // NULL without `infer`
  const int64_t *infer_slots;
  int64_t ninfer;
  Thunk t;                 // the branches as values: functions or constants
  V t_cval;
  Thunk f;
  V f_cval;
  Thunk whole;             // the conditional itself (as a value)
} CondD;

// decides a conditional whose check type is checkv: 0 the true branch (infer
// slots are bound in env), 1 the false branch, 2 the value is in *out
int64_t rt_decide(const CondD *d, V checkv, V *env, V *out);
// a distributive conditional over the union checkv
V rt_distribute(const CondD *d, V checkv, V *env);
// the general case: distributes, or decides as rt_decide
int64_t rt_cond(const CondD *d, V checkv, V *env, V *out);

// object types
typedef struct {
  Str *name;
  Thunk th;                // lazy type (or NULL)
  V cval;                  // constant type (or 0)
  int64_t slot;            // the type is this slot (or -1)
  int64_t opt, ro, numeric;
} PropD;
typedef struct { Thunk key, ty; int64_t ro; } IndexD;
typedef struct { Str *name; Thunk ty; int64_t opt, rest; } ParamD;
typedef struct { int64_t np; const ParamD *params; Thunk ret; int64_t ctor; } CallD;
typedef struct {
  int64_t frame;
  int64_t np;
  const PropD *props;
  int64_t ni;
  const IndexD *index;
  int64_t nc;
  const CallD *calls;
} ObjD;
V rt_obj(const ObjD *d, V *env);
// a function type from evaluated parameter types
typedef struct { int64_t np; const ParamD *params; int64_t ctor; } FnD;
V rt_fn(const FnD *d, const V *tys, V ret);

// mapped types
typedef struct {
  int64_t frame;
  int64_t slot;            // the key
  Thunk constraint;
  Thunk homo;              // `keyof T` with T a type parameter (or NULL)
  Thunk mods;              // where modifiers come from (or NULL)
  Thunk as_clause;         // or NULL
  Thunk body;
  V body_cval;             // the body is a constant (or 0)
  int64_t body_slot;       // the body is a slot (or -1)
  int64_t ro, opt;         // +1 / -1 / 0
  int64_t kof;             // the constraint is written `keyof X`
  int64_t homo_slot;       // the slot of the T of a homomorphic `keyof T` (or -1)
} MappedD;
V rt_mapped(const MappedD *d, V *env);

// tuples with optional, rest or named elements, or readonly
typedef struct { int64_t n; const int64_t *kinds; Str *const *names; int64_t ro; } TupD;
V rt_tuple(const TupD *d, V *vals);

// generic function types
V rt_genfn(const int64_t *slots, int64_t nslots, Thunk code, V *env, int64_t frame);

// copies an environment (for lazily evaluated parts)
V *env_copy(const V *env, int64_t frame);

// the top of the environment stack of the running thread (see gen.mbt)
extern V *tstc_top;

// evaluates a part of a frame others still use: the top is moved past it,
// so the code does not take the frame over
static inline V call_thunk(Thunk k, V *env) {
  V *saved = tstc_top;
  tstc_top = saved + 1;
  V r = pair_v(k(env));
  tstc_top = saved;
  return r;
}

#endif
