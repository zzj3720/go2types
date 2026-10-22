// Substitution types (tsgo getConditionalFlowTypeOfType). Where a type is
// written in the true branch of a conditional whose check type is known as
// written (no type parameter in it), a type that is that check type is a
// substitution type constrained by the extends type: a template of it is
// string, an intersection keeps it, a relation sees it as base & constraint.
// The runtime decides (n_subst: the written type's value against the check
// type's); instantiation resolves substitution types to their base (n_strip):
// where code of no type parameter is part of code of some (a template the
// checker instantiates), in conditionals instantiated (with infer, or of type
// parameters), mapped types' templates and generic aliases' results.

priv struct SubstSite {
  slot : Int
  ext : Code
  check : Ty? // the check type when it is a constant
  co : Bool // a covariant position as seen from the site's conditional
}

// the sites as seen inside a parameter
fn subst_flip(sites : Array[SubstSite]) -> Array[SubstSite] {
  sites.map(fn(s) { { ..s, co: !s.co } })
}

// [the alias of n_subst, its native, the alias of n_strip, its native]
let subst_ids : Ref[Array[Int]?] = Ref::new(None)

fn subst_natives() -> Array[Int] {
  match subst_ids.val {
    Some(x) => x
    None => {
      let m = modules.get("<prelude>").unwrap()
      let sa = m.locals.get("__TstcSubst").unwrap()
      let ta = m.locals.get("__TstcStrip").unwrap()
      let r = [sa, aliases[sa].native, ta, aliases[ta].native]
      subst_ids.val = Some(r)
      r
    }
  }
}

fn code_closed(c : Code) -> Bool {
  code_free(c).is_empty()
}

// isGenericIndexType of the type code makes where it is written: with a
// type parameter at its top (a substitution type of it is a template's
// placeholder, and nothing is computed with it before instantiation)
fn generic_index_code(c : Code) -> Bool {
  match c {
    CSlot(_) => true
    CUnion(cs) | CInter(cs) => cs.iter().any(generic_index_code)
    CIndex(_, _) | CKeyof(_) | CCond(_) | CTpl(_, _) => !code_closed(c)
    CNative(_, _, args) => !native_is_lib(native_of(c)) && !code_closed(CUnion(args))
    _ => false
  }
}

fn native_of(c : Code) -> Int {
  match c {
    CNative(_, id, _) => id
    _ => -1
  }
}

// can code's value be the constant check type t
fn subst_may_be(c : Code, t : Ty) -> Bool {
  match c {
    CTy(u) => ty_same(u, t)
    // (objects are no constant)
    CTuple(_, _) | CArray(_, _) | CObj(_) | CFn(_, _, _) | CGenericFn(_, _) | CMapped(_) | CUniqueSym(_) => false
    _ => true
  }
}

fn ty_same(a : Ty, b : Ty) -> Bool {
  ty_key_of(a) == ty_key_of(b)
}

fn ty_key_of(t : Ty) -> String {
  let sb = StringBuilder::new()
  ty_key(t, sb)
  sb.to_string()
}

// c: the code with its sites (closed: before them)
fn subst_wrap(c : Code, closed : Bool, sites : Array[SubstSite]) -> Code {
  if sites.is_empty() || !closed {
    return c
  }
  let ids = subst_natives()
  let mut r = c
  // (the sites of one written type make one substitution type, of the
  // intersection of their constraints: the fourth argument is the type
  // before them, n_subst)
  for s in sites {
    if !s.co {
      continue
    }
    match s.check {
      Some(t) => if !subst_may_be(c, t) { continue }
      None => ()
    }
    r = CNative(ids[0], ids[1], [r, CSlot(s.slot), s.ext, c])
  }
  r
}

// the code with substitution sites (sites: the enclosing true branches'
// check slots and extends types; co: a covariant position)
fn subst_code(ctx : Ctx, c : Code, sites : Array[SubstSite], co : Bool) -> Code {
  let closed = !sites.is_empty() && sites.iter().any(fn(s) { s.co }) && code_closed(c)
  let w = fn(x : Code) { subst_code(ctx, x, sites, co) }
  let r = match c {
    CTy(_) | CSlot(_) | CUniqueSym(_) => c
    CCall(i, args) => CCall(i, args.map(w))
    CNative(i, n, args) => CNative(i, n, args.map(w))
    CUnion(cs) => CUnion(cs.map(w))
    CInter(cs) => CInter(cs.map(w))
    CTuple(es, ro) => CTuple(es.map(fn(e) { { code: w(e.code), kind: e.kind, name: e.name } }), ro)
    CArray(x, ro) => CArray(w(x), ro)
    CKeyof(x) => CKeyof(w(x))
    CIndex(o, k) => CIndex(w(o), w(k))
    CTpl(ts, cs) => CTpl(ts, cs.map(w))
    CObj(oc) =>
      CObj({
        props: oc.props.map(fn(p) { (p.0, w(p.1), p.2, p.3, p.4) }),
        index: oc.index.map(fn(x) { (w(x.0), w(x.1), x.2) }),
        calls: oc.calls.map(fn(cl) {
          (cl.0.map(fn(p) { { ..p, code: subst_code(ctx, p.code, subst_flip(sites), !co) } }), w(cl.1), cl.2)
        }),
        lookup: Ref::new(None),
        id: fresh_code_id(),
      })
    CFn(ps, ret, ctor) => CFn(ps.map(fn(p) { { ..p, code: subst_code(ctx, p.code, subst_flip(sites), !co) } }), w(ret), ctor)
    CGenericFn(slots, body) => CGenericFn(slots, w(body))
    CMapped(mc) =>
      CMapped({
        ..mc,
        constraint: w(mc.constraint),
        homo: mc.homo.map(w),
        mods: mc.mods.map(w),
        as_clause: mc.as_clause.map(w),
        body: w(mc.body),
        id: fresh_code_id(),
      })
    CLet(s, v, b) => CLet(s, w(v), w(b))
    CCond(cd) => subst_cond(ctx, cd, sites, co)
  }
  subst_wrap(r, closed, sites)
}

fn subst_pat(ctx : Ctx, p : Pat, sites : Array[SubstSite], co : Bool) -> Pat {
  let w = fn(x : Pat) { subst_pat(ctx, x, sites, co) }
  match p {
    PCode(c) => PCode(subst_code(ctx, c, sites, co))
    PInfer(s, cons) => PInfer(s, cons.map(fn(c) { subst_code(ctx, c, sites, co) }))
    PTuple(es, ro) => PTuple(es.map(fn(e) { { pat: w(e.pat), kind: e.kind } }), ro)
    PArray(x, ro) => PArray(w(x), ro)
    PObj(ps) => PObj(ps.map(fn(pp) { { name: pp.name, pat: w(pp.pat), optional: pp.optional } }))
    PTpl(ts, ps) => PTpl(ts, ps.map(w))
    PFn(ps, ret) => PFn(ps.map(fn(e) { { pat: subst_pat(ctx, e.pat, subst_flip(sites), !co), kind: e.kind } }), w(ret))
    PUnion(ps) => PUnion(ps.map(w))
    PVal(c, infs) => PVal(subst_code(ctx, c, sites, co), infs.map(fn(e) { { pat: w(e.pat), kind: e.kind } }))
  }
}

// a conditional of constants that is false (`false extends true`): its
// true branch is never taken
fn cond_never_true(cd : Cond) -> Bool {
  match (cd.check, cd.ext, cd.pat) {
    (CTy(TNever), _, _) => false
    // (extends a unit type: the true branch's check type is that type, a
    // substitution type of which is the type itself; a check type computed
    // as never aside)
    (_, CTy(u), None) if ty_unit(u) => true
    (CTy(t), CTy(u), None) => !ty_may_extend(t, u)
    _ => false
  }
}

fn ty_unit(t : Ty) -> Bool {
  match t {
    TTrue | TFalse | TNull | TUndefined | TStrLit(_) | TNumLit(_) | TBigLit(_) | TInt(_) => true
    _ => false
  }
}

fn ty_may_extend(t : Ty, u : Ty) -> Bool {
  if ty_same(t, u) {
    return true
  }
  match (t, u) {
    (_, TAny) | (_, TUnknown) | (TNever, _) | (TAny, _) => true
    (TUnion(ts), _) => ts.iter().any(fn(x) { ty_may_extend(x, u) })
    (_, TUnion(us)) => us.iter().any(fn(y) { ty_may_extend(t, y) })
    (TStrLit(_), TString) | (TNumLit(_), TNumber) | (TBigLit(_), TBigInt) | (TInt(_), TBigInt) => true
    (TTrue, _) | (TFalse, _) | (TNull, _) | (TUndefined, _) => match u {
      TVoid => t is TUndefined
      _ => false
    }
    (TStrLit(_), _) | (TNumLit(_), _) | (TBigLit(_), _) | (TInt(_), _) => false
    (TString, _) | (TNumber, _) | (TBigInt, _) | (TSymbol, _) | (TVoid, _) => false
    _ => true
  }
}

fn subst_cond(ctx : Ctx, cd : Cond, sites : Array[SubstSite], co : Bool) -> Code {
  let check = subst_code(ctx, cd.check, sites, co)
  let ext = subst_code(ctx, cd.ext, sites, co)
  let pat = cd.pat.map(fn(p) { subst_pat(ctx, p, sites, co) })
  let f = subst_code(ctx, cd.f, sites, co)
  if cond_never_true(cd) {
    return CCond({ ..cd, check, ext, pat, t: cd.t, f, id: fresh_code_id() })
  }
  if !code_closed(cd.check) || generic_index_code(cd.ext) {
    let t = subst_code(ctx, cd.t, sites, co)
    return CCond({ ..cd, check, ext, pat, t, f, id: fresh_code_id() })
  }
  // a site: the true branch's types against the check type (kept in a slot)
  let slot = ctx.alloc()
  let inner = sites.copy()
  let cc = match cd.check {
    CTy(t) => Some(t)
    _ => None
  }
  inner.push({ slot, ext: cd.ext, check: cc, co: true })
  let t = subst_code(ctx, cd.t, inner, co)
  // (instantiated with the inferences, or with type parameters from outside:
  // the true branch's substitution types resolved)
  let instantiated = !cd.infer_slots.is_empty() || !cond_free(cd).is_empty()
  let t2 = if instantiated && subst_has_sites(t) { subst_strip_code(t) } else { t }
  CLet(slot, check, CCond({ ..cd, check: CSlot(slot), ext, pat, t: t2, f, id: fresh_code_id() }))
}

fn subst_strip_code(c : Code) -> Code {
  let ids = subst_natives()
  CNative(ids[2], ids[3], [c])
}

fn subst_has_sites(c : Code) -> Bool {
  let ids = subst_natives()
  let found = Ref::new(false)
  fn walk(x : Code) -> Unit {
    if found.val {
      return
    }
    match x {
      CNative(_, id, _) if id == ids[1] => found.val = true
      _ => code_each(x, walk)
    }
  }
  walk(c)
  found.val
}

// strips: closed code with sites inside code of type parameters
fn subst_strips(c : Code) -> Code {
  if !subst_has_sites(c) {
    return c
  }
  let closed = code_closed(c)
  let g = fn(x : Code) {
    let y = subst_strips(x)
    if !closed && code_closed(y) && subst_has_sites(y) {
      subst_strip_code(y)
    } else {
      y
    }
  }
  match c {
    CTy(_) | CSlot(_) | CUniqueSym(_) => c
    CCall(i, args) => CCall(i, args.map(g))
    CNative(i, n, args) => CNative(i, n, args.map(g))
    CUnion(cs) => CUnion(cs.map(g))
    CInter(cs) => CInter(cs.map(g))
    CTuple(es, ro) => CTuple(es.map(fn(e) { { code: g(e.code), kind: e.kind, name: e.name } }), ro)
    CArray(x, ro) => CArray(g(x), ro)
    CKeyof(x) => CKeyof(g(x))
    CIndex(o, k) => CIndex(g(o), g(k))
    CTpl(ts, cs) => CTpl(ts, cs.map(g))
    CObj(oc) =>
      CObj({
        props: oc.props.map(fn(p) { (p.0, g(p.1), p.2, p.3, p.4) }),
        index: oc.index.map(fn(x) { (g(x.0), g(x.1), x.2) }),
        calls: oc.calls.map(fn(cl) { (cl.0.map(fn(p) { { ..p, code: g(p.code) } }), g(cl.1), cl.2) }),
        lookup: Ref::new(None),
        id: fresh_code_id(),
      })
    CFn(ps, ret, ctor) => CFn(ps.map(fn(p) { { ..p, code: g(p.code) } }), g(ret), ctor)
    CGenericFn(slots, body) => CGenericFn(slots, g(body))
    CMapped(mc) => {
      // (a mapped type's template is instantiated for every key)
      let b = subst_strips(mc.body)
      let b2 = if code_closed(b) && subst_has_sites(b) { subst_strip_code(b) } else { b }
      CMapped({
        ..mc,
        constraint: g(mc.constraint),
        homo: mc.homo.map(g),
        mods: mc.mods.map(g),
        as_clause: mc.as_clause.map(g),
        body: b2,
        id: fresh_code_id(),
      })
    }
    CLet(s, v, b) => CLet(s, g(v), g(b))
    CCond(cd) =>
      CCond({
        ..cd,
        check: g(cd.check),
        ext: g(cd.ext),
        t: g(cd.t),
        f: g(cd.f),
        id: fresh_code_id(),
      })
  }
}

// an alias's body with substitution types
fn subst_alias(ctx : Ctx, a : Alias) -> Unit {
  if !has_site_cond(a.body) {
    return
  }
  let b = subst_code(ctx, a.body, [], true)
  if !subst_has_sites(b) {
    return
  }
  let b2 = subst_strips(b)
  // (a generic alias's result is its body instantiated)
  a.body = if a.nparams > 0 && code_closed(b2) { subst_strip_code(b2) } else { b2 }
}

// a conditional whose true branch may have substitution types
fn has_site_cond(c : Code) -> Bool {
  let found = Ref::new(false)
  fn walk(x : Code) -> Unit {
    if found.val {
      return
    }
    match x {
      CCond(cd) =>
        if cond_never_true(cd) {
          walk(cd.check)
          walk(cd.ext)
          walk(cd.f)
        } else if code_closed(cd.check) && !generic_index_code(cd.ext) && cond_t_may_match(cd) {
          found.val = true
        } else {
          code_each(x, walk)
        }
      _ => code_each(x, walk)
    }
  }
  walk(c)
  found.val
}

// may some closed code in the true branch be the (constant) check type
fn cond_t_may_match(cd : Cond) -> Bool {
  match cd.check {
    CTy(t) => {
      let found = Ref::new(false)
      fn walk(x : Code) -> Unit {
        if found.val {
          return
        }
        match x {
          CTy(u) => if ty_same(u, t) { found.val = true }
          CSlot(_) | CUniqueSym(_) => ()
          CCall(_, _) | CNative(_, _, _) | CCond(_) | CIndex(_, _) | CKeyof(_) | CTpl(_, _) | CUnion(_) | CInter(_) =>
            // (computed: possibly the check type)
            if code_closed(x) { found.val = true } else { code_each(x, walk) }
          _ => code_each(x, walk)
        }
      }
      walk(cd.t)
      found.val
    }
    _ => true
  }
}
