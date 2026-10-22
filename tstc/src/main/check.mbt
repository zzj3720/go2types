// Checks of the relations tsc and tsgo require between the types of a
// program (a type argument and its parameter's constraint, a property and
// an index signature, a template literal's placeholder and the types a
// placeholder may have, ...): a program they report an error for is not a
// TypeScript program, and tstc rejects it too.
//
// A relation between types without type variables is decided when the
// compiler knows both (literals and keywords), and otherwise by the program
// itself: the check becomes a parameterless alias `[S] extends [T] ? 1 : 0`
// that the build evaluates once the program is linked (main.mbt). Relations
// between generic types are decided by the declared constraints of the type
// variables where tsc's rules make that simple, and are otherwise left to
// the evaluation of the instantiations (not checked).

// checks evaluated after the link: (alias, what fails when it is 0)
let eval_checks : Array[(Int, String)] = []

// the aliases made for checks (no checks of their own, no cycles)
let synthetic : Map[Int, Bool] = Map::new()

// "<alias>/<parameter>" -> the alias `[P] extends [C] ? 1 : 0` with the
// parameters of the alias
let constraint_helpers : Map[String, Int] = Map::new()

let checks_on : Ref[Bool] = Ref::new(true)

// the relations of type variables are checked too (by what they are known to
// be where they are used), as tsc and tsgo check them; --no-check-generic
// turns that off
let generic_checks : Ref[Bool] = Ref::new(true)

// --checks-warn: a relation that does not hold is reported, not an error
let checks_warn : Ref[Bool] = Ref::new(false)

fn check_fail(ctx : Ctx, msg : String) -> Unit {
  if checks_warn.val {
    err("tstc: warning: " + ctx.module.path + " (in type " + ctx.alias.name + "): " + msg + "\n")
  } else {
    cfail(ctx, msg)
  }
}

// ---------------------------------------------------------------------------
// Type variables

// whether code refers to no type variable (slot) it does not bind itself
fn code_is_concrete(c : Code) -> Bool {
  let refs : Array[Int] = []
  let bound : Map[Int, Bool] = Map::new()
  fn walk(c : Code) -> Unit {
    match c {
      CSlot(s) => refs.push(s)
      CCond(cd) => for s in cd.infer_slots { bound.set(s, true) }
      CMapped(mc) => bound.set(mc.slot, true)
      CGenericFn(slots, _) => for s in slots { bound.set(s, true) }
      CLet(s, _, _) => bound.set(s, true)
      _ => ()
    }
    code_each(c, walk)
  }

  walk(c)
  refs.iter().all(fn(s) { bound.contains(s) })
}

// ---------------------------------------------------------------------------
// Relations the compiler decides

// whether s is assignable to t (tsc's assignability) when both are known
// literals, keywords or unions of them; None when that takes more
fn ty_assignable(s : Ty, t : Ty) -> Bool? {
  match (s, t) {
    (_, TAny) | (_, TUnknown) => Some(true)
    (TNever, _) => Some(true)
    (TAny, TNever) => Some(false)
    (TAny, _) => Some(true)
    (TUnion(ms), _) => {
      let mut all = true
      for m in ms {
        match ty_assignable(m, t) {
          Some(true) => ()
          Some(false) => all = false
          None => return None
        }
      }
      Some(all)
    }
    (_, TUnion(ms)) => {
      for m in ms {
        match ty_assignable(s, m) {
          Some(true) => return Some(true)
          Some(false) => ()
          None => return None
        }
      }
      Some(false)
    }
    (TUnknown, _) => Some(false)
    (_, TNever) => Some(false)
    (TStrLit(a), TStrLit(b)) => Some(a.equals(b))
    (TStrLit(_), TString) => Some(true)
    (TNumLit(a), TNumLit(b)) => Some(a == b || a.is_nan() && b.is_nan())
    (TNumLit(_), TNumber) => Some(true)
    (TInt(a), TInt(b)) => Some(a == b)
    (TBigLit(a), TBigLit(b)) => Some(a == b)
    (TInt(_), TBigInt) | (TBigLit(_), TBigInt) => Some(true)
    (TTrue, TTrue) | (TFalse, TFalse) => Some(true)
    (TUndefined, TVoid) => Some(true)
    (TString, TString) | (TNumber, TNumber) | (TBigInt, TBigInt) | (TSymbol, TSymbol)
    | (TNull, TNull) | (TUndefined, TUndefined) | (TVoid, TVoid) | (TObjectKw, TObjectKw) =>
      Some(true)
    // primitives and object
    (
      TStrLit(_) | TString | TNumLit(_) | TNumber | TInt(_) | TBigLit(_) | TBigInt | TTrue | TFalse
      | TSymbol | TNull | TUndefined | TVoid,
      TStrLit(_) | TString | TNumLit(_) | TNumber | TInt(_) | TBigLit(_) | TBigInt | TTrue | TFalse
      | TSymbol | TNull | TUndefined | TVoid | TObjectKw,
    ) => Some(false)
    _ => None
  }
}

// the type of written code, when it is one known to the compiler
fn code_ty(c : Code) -> Ty? {
  match c {
    CTy(t) => Some(t)
    CUnion(cs) => {
      let ts : Array[Ty] = []
      for x in cs {
        match code_ty(x) {
          Some(t) => ts.push(t)
          None => return None
        }
      }
      Some(TUnion(ts))
    }
    _ => None
  }
}

// ---------------------------------------------------------------------------
// Checks evaluated after the link

fn new_synthetic_alias(name : String, file : String, params : Array[TParamE], body : TE?) -> Int {
  let idx = aliases.length()
  aliases.push({
    name,
    doc: "",
    file,
    nparams: params.length(),
    param_names: params.map(fn(p) { p.name }),
    defaults: [],
    body: CTy(TAny),
    frame: 0,
    native: -1,
    iface_members: [],
    iface_heritage: [],
    decl_params: params,
    decl_body: body,
    is_interface: false,
  })
  synthetic.set(idx, true)
  idx
}

// a check alias: its body is made by mk (in a context of the module of ctx,
// outside of every scope: the check's types are concrete)
fn add_eval_check(ctx : Ctx, msg : String, mk : (Ctx) -> Code) -> Unit {
  let idx = new_synthetic_alias(
    "tstc$check$" + eval_checks.length().to_string(),
    ctx.module.path,
    [],
    None,
  )
  let c2 = {
    module: ctx.module,
    alias: aliases[idx],
    frame: 0,
    cons: Map::new(),
    idx,
    eager: false,
    in_ext: 0,
    checks: false,
    vcons: Map::new(),
    narrow: Map::new(),
  }
  let body = mk(c2)
  aliases[idx].body = body
  aliases[idx].frame = frame_size(c2.frame)
  eval_checks.push((idx, ctx.module.path + " (in type " + ctx.alias.name + "): " + msg))
}

// `[s] extends [t] ? 1 : 0`
fn rel_te(s : TE, t : TE) -> TE {
  ECond(
    ETuple([{ ty: s, kind: K_REQ, name: "" }], false),
    ETuple([{ ty: t, kind: K_REQ, name: "" }], false),
    ENum(1.0),
    ENum(0.0),
  )
}

// that s (compiled: sc) is assignable to t (a type without type variables)
// where tsc and tsgo require it: decided now when the compiler knows both,
// else evaluated after the link. Generic s are not checked.
fn check_assignable(ctx : Ctx, s : TE, sc : Code, t : TE, tc : Code, msg : String) -> Unit {
  if !ctx.checks || !checks_on.val || !code_is_concrete(tc) {
    return
  }
  // a type variable: what it is known to be (tsc relates a type variable's
  // constraint to the target)
  let (s, sc) = match sc {
    CSlot(_) if !generic_checks.val => return
    CSlot(slot) =>
      match effective_constraint(ctx, slot) {
        Some(e) => (e, compile_quiet(ctx, e))
        None => return
      }
    _ => (s, sc)
  }
  if !code_is_concrete(sc) {
    return
  }
  match (code_ty(sc), code_ty(tc)) {
    (Some(a), Some(b)) =>
      match ty_assignable(a, b) {
        Some(true) => return
        Some(false) => {
          check_fail(ctx, msg)
          return
        }
        None => ()
      }
    _ => ()
  }
  add_eval_check(ctx, msg, fn(c2) { compile_te(c2, None, rel_te(s, t)) })
}

// what a type variable is known to be where it is referred to: the
// intersection of its constraint and of the extends types of the
// conditionals whose true branch this is (unknown without); None when one is
// not concrete
fn effective_constraint(ctx : Ctx, slot : Int) -> TE? {
  let parts : Array[TE] = []
  for src in [ctx.vcons.get(slot), ctx.narrow.get(slot)] {
    match src {
      Some(a) =>
        for x in a {
          if !x.1 {
            return None
          }
          match x.0 {
            // (a type parameter constrained to any relates as one without)
            EKw("any") => ()
            t => parts.push(t)
          }
        }
      None => ()
    }
  }
  match parts.length() {
    0 => Some(EKw("unknown"))
    1 => Some(parts[0])
    _ => Some(EInter(parts))
  }
}

// a concrete type compiled for the checks only
fn compile_quiet(ctx : Ctx, t : TE) -> Code {
  let c2 = { ..ctx, checks: false, eager: false }
  compile_te(c2, None, t)
}

// The constraints of an alias's parameters for the arguments of a reference
// (tsc and tsgo: checkTypeArgumentConstraints)
fn check_type_arguments(ctx : Ctx, idx : Int, args : Array[TE], cargs : Array[Code]) -> Unit {
  if !ctx.checks || !checks_on.val {
    return
  }
  let a = aliases[idx]
  let ps = a.decl_params
  for i in 0..<ps.length() {
    let c = match ps[i].constraint {
      Some(EKw("unknown" | "any")) | None => continue
      Some(c) => c
    }
    // generic arguments: a type variable is checked by what it is known to
    // be when the constraint does not depend on the other arguments
    if !cargs.iter().all(code_is_concrete) {
      if generic_checks.val && i < cargs.length() && !te_refers_to(c, ps) {
        match cargs[i] {
          CSlot(slot) =>
            match effective_constraint(ctx, slot) {
              Some(e) => {
                let msg = "type argument \{i + 1} of '\{a.name}' (a type parameter) does not satisfy the constraint of '\{ps[i].name}'"
                match (te_ty(e), te_ty(c)) {
                  (Some(et), Some(ct)) =>
                    match ty_assignable(et, ct) {
                      Some(true) => continue
                      Some(false) => {
                        check_fail(ctx, msg)
                        continue
                      }
                      None => ()
                    }
                  _ => ()
                }
                let helper = constraint_helper(idx, i)
                let n = ps.length()
                add_eval_check(ctx, msg, fn(c2) {
                  CCall(
                    helper,
                    Array::makei(n, fn(j) {
                      compile_te(c2, None, if j == i { e } else { EKw("unknown") })
                    }),
                  )
                })
              }
              None => ()
            }
          _ => ()
        }
      }
      continue
    }
    let msg = "type argument \{i + 1} of '\{a.name}' does not satisfy the constraint of '\{ps[i].name}'"
    // a constraint of keywords and literals and an argument the compiler
    // knows: decided now
    if i < cargs.length() && !te_refers_to(c, ps) {
      match code_ty(cargs[i]) {
        Some(at) =>
          match te_ty(c) {
            Some(ct) =>
              match ty_assignable(at, ct) {
                Some(true) => continue
                Some(false) => {
                  check_fail(ctx, msg)
                  continue
                }
                None => ()
              }
            None => ()
          }
        None => ()
      }
    }
    let helper = constraint_helper(idx, i)
    add_eval_check(ctx, msg, fn(c2) {
      CCall(helper, args.map(fn(t) { compile_te(c2, None, t) }))
    })
  }
}

// the alias `[P] extends [C] ? 1 : 0` for parameter i of alias idx
fn constraint_helper(idx : Int, i : Int) -> Int {
  let key = "\{idx}/\{i}"
  match constraint_helpers.get(key) {
    Some(h) => return h
    None => ()
  }
  let a = aliases[idx]
  let p = a.decl_params[i]
  let h = new_synthetic_alias(
    a.name + "$tstc$c" + i.to_string(),
    a.file,
    a.decl_params,
    Some(rel_te(ERef(p.name, [], [], 0), p.constraint.unwrap())),
  )
  constraint_helpers.set(key, h)
  compile_alias(h)
  h
}

// whether te refers to one of the parameters (by name)
fn te_refers_to(te : TE, ps : Array[TParamE]) -> Bool {
  let mut found = false
  fn walk(t : TE) -> Unit {
    if found {
      return
    }
    match t {
      ERef(n, [], _, _) if ps.iter().any(fn(p) { p.name == n }) => found = true
      _ => te_each(t, walk)
    }
  }

  walk(te)
  found
}

// the children of a written type
fn te_each(te : TE, f : (TE) -> Unit) -> Unit {
  match te {
    ERef(_, _, args, _) => for x in args { f(x) }
    EUnion(xs) | EInter(xs) => for x in xs { f(x) }
    ECond(a, b, c, d) => {
      f(a)
      f(b)
      f(c)
      f(d)
    }
    EInfer(_, Some(c)) => f(c)
    ETuple(es, _) => for e in es { f(e.ty) }
    EArray(x, _) | EKeyof(x) | ENullable(x, _) => f(x)
    EObj(ms) =>
      for m in ms {
        match m {
          MProp(_, t, _, _) => f(t)
          MIndex(_, k, v, _) => {
            f(k)
            f(v)
          }
          MCall(tps, ps, r, _) => {
            for tp in tps {
              match tp.constraint {
                Some(c) => f(c)
                None => ()
              }
              match tp.default {
                Some(c) => f(c)
                None => ()
              }
            }
            for p in ps {
              f(p.ty)
            }
            f(r)
          }
        }
      }
    EMapped(mp) => {
      f(mp.constraint)
      match mp.as_clause {
        Some(x) => f(x)
        None => ()
      }
      match mp.body {
        Some(x) => f(x)
        None => ()
      }
    }
    EIndex(a, b) => {
      f(a)
      f(b)
    }
    ETpl(_, xs) => for x in xs { f(x) }
    EFn(tps, ps, r, _) => {
      for tp in tps {
        match tp.constraint {
          Some(c) => f(c)
          None => ()
        }
        match tp.default {
          Some(c) => f(c)
          None => ()
        }
      }
      for p in ps {
        f(p.ty)
      }
      f(r)
    }
    _ => ()
  }
}

// a written type of keywords and literals
fn te_ty(te : TE) -> Ty? {
  match te {
    EKw(k) => Some(kw_ty(k))
    EStr(s) => Some(TStrLit(Str::of_string(s)))
    ENum(d) => Some(TNumLit(d))
    EBig(s) => Some(bigint_ty(normalize_bigint(s)))
    EBool(b) => Some(bool_ty(b))
    EUnion(xs) => {
      let ts : Array[Ty] = []
      for x in xs {
        match te_ty(x) {
          Some(t) => ts.push(t)
          None => return None
        }
      }
      Some(TUnion(ts))
    }
    _ => None
  }
}

// the types a template literal's placeholder may have
let template_constraint_te : TE = EUnion([
  EKw("string"),
  EKw("number"),
  EKw("bigint"),
  EKw("boolean"),
  EKw("null"),
  EKw("undefined"),
])

let property_key_te : TE = EUnion([EKw("string"), EKw("number"), EKw("symbol")])

let any_readonly_array_te : TE = EArray(EKw("any"), true)

// The properties of an object type literal and its index signatures (tsc
// and tsgo: checkIndexConstraints): a property's type is assignable to the
// type of each index signature applying to its name, and the number index
// signature's type to the string one's.
fn check_index_constraints(
  ctx : Ctx,
  members : Array[Member],
  props : Array[(Str, Code, Bool, Bool, Bool)],
  index : Array[(Code, Code, Bool)],
) -> Unit {
  if index.is_empty() || !ctx.checks || !checks_on.val {
    return
  }
  // the written members, in the order of props and index
  let pt : Array[(String, TE, Bool)] = []
  let it : Array[(TE, TE)] = []
  for m in members {
    match m {
      MProp(n, t, opt, _) => pt.push((n, t, opt))
      MIndex(_, k, v, _) => it.push((k, v))
      _ => ()
    }
  }
  for j in 0..<index.length() {
    let (kc, vc, _) = index[j]
    let vt = it[j].1
    let keys = match code_ty(kc) {
      Some(TUnion(ts)) => ts
      Some(t) => [t]
      None => continue
    }
    for key in keys {
      for i in 0..<props.length() {
        let (name, pc, opt, _, numeric) = props[i]
        let (_, ptype, _) = pt[i]
        let applies = match key {
          TString => true
          TNumber => numeric || parse_canonical_number(name) is Some(_)
          _ => false
        }
        if !applies {
          continue
        }
        let s = if opt { EUnion([ptype, EKw("undefined")]) } else { ptype }
        let sc = if opt { CUnion([pc, CTy(TUndefined)]) } else { pc }
        let kname = match key {
          TString => "string"
          _ => "number"
        }
        check_assignable(
          ctx,
          s,
          sc,
          vt,
          vc,
          "property '\{name.to_string()}' is not assignable to '\{kname}' index type",
        )
      }
      // the number index signature's type and the string one's
      if key is TNumber {
        for k in 0..<index.length() {
          let (kc2, vc2, _) = index[k]
          let string_key = match code_ty(kc2) {
            Some(TString) => true
            Some(TUnion(ts)) => ts.iter().any(fn(t) { t is TString })
            _ => false
          }
          if k != j && string_key {
            check_assignable(
              ctx,
              vt,
              vc,
              it[k].1,
              vc2,
              "'number' index type is not assignable to 'string' index type",
            )
          }
        }
      }
    }
  }
}

// An indexed access type of concrete types (tsc and tsgo:
// getPropertyTypeForIndexType): the property exists, a tuple has the
// element, the index type can index the object type (rt n_indexok)
fn check_index_access(ctx : Ctx, o : TE, oc : Code, i : TE, ic : Code) -> Unit {
  if !ctx.checks || !checks_on.val || !code_is_concrete(oc) {
    return
  }
  // a type variable indexing a concrete object: assignable to its keys
  // (tsc: checkIndexedAccessIndexType)
  if ic is CSlot(_) {
    if !generic_checks.val {
      return
    }
    let k = EKeyof(o)
    check_assignable(ctx, i, ic, k, compile_quiet(ctx, k), "the index type (a type parameter) cannot index the object type")
    return
  }
  if !code_is_concrete(ic) {
    return
  }
  let helper = match globals.get("__tstc_index_ok") {
    Some(h) => h
    None => return
  }
  add_eval_check(
    ctx,
    "the index type cannot index the object type (a property that does not exist, a tuple element out of range)",
    fn(c2) { CCall(helper, [compile_te(c2, None, o), compile_te(c2, None, i)]) },
  )
}
