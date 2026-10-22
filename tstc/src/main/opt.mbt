// Optimizations of the program's code before shape analysis and code
// generation. Evaluation is pure, so a value computed once can stand for
// every later evaluation of the same expression:
//
// - a conditional whose checked expression occurs again in the alias (the
//   chains `F<X> extends A ? ... : F<X> extends B ? ...` hand-written code
//   is full of) evaluates it once into a slot of the frame (CLet), and the
//   occurrences it dominates read the slot;
// - an alias whose evaluation can branch into several recursive calls (tree
//   recursion: `[...Fib<N1>, ...Fib<N2>]`) is memoized, as tsc caches the
//   instantiations of an alias: the table is keyed by the arguments
//   (rt/memo.c). Calls in tail position within the recursion go to the body
//   directly, so loops written as tail recursion stay loops.

// 0: nothing memoized, 1: tree-recursive aliases, 2: every alias with
// parameters, 3: recursive aliases (loops too: their calls from outside)
let memo_mode : Ref[Int] = Ref::new(2)

// --memo was given
let memo_explicit : Ref[Bool] = Ref::new(false)

let cse_on : Ref[Bool] = Ref::new(true)

// --no-unwrap: results passed on unchanged stay conditionals
let unwrap_on : Ref[Bool] = Ref::new(true)

// memoized alias -> the alias of its body
let memo_body : Map[Int, Int] = Map::new()

let opt_lets : Ref[Int] = Ref::new(0)

// ---------------------------------------------------------------------------
// Walking code

fn code_each(c : Code, f : (Code) -> Unit) -> Unit {
  match c {
    CTy(_) | CSlot(_) | CUniqueSym(_) => ()
    CCall(_, args) | CNative(_, _, args) => for a in args { f(a) }
    CUnion(cs) | CInter(cs) => for x in cs { f(x) }
    CCond(cd) => {
      f(cd.check)
      f(cd.ext)
      match cd.pat {
        Some(p) => pat_each_code(p, f)
        None => ()
      }
      f(cd.t)
      f(cd.f)
    }
    CTuple(elems, _) => for e in elems { f(e.code) }
    CArray(x, _) | CKeyof(x) => f(x)
    CObj(oc) => {
      for p in oc.props {
        f(p.1)
      }
      for ix in oc.index {
        f(ix.0)
        f(ix.1)
      }
      for cl in oc.calls {
        for p in cl.0 {
          f(p.code)
        }
        f(cl.1)
      }
    }
    CMapped(mc) => {
      f(mc.constraint)
      for x in [mc.homo, mc.mods, mc.as_clause] {
        match x {
          Some(y) => f(y)
          None => ()
        }
      }
      f(mc.body)
    }
    CIndex(o, k) => {
      f(o)
      f(k)
    }
    CTpl(_, cs) => for x in cs { f(x) }
    CFn(params, ret, _) => {
      for p in params {
        f(p.code)
      }
      f(ret)
    }
    CGenericFn(_, body) => f(body)
    CLet(_, v, b) => {
      f(v)
      f(b)
    }
  }
}

fn pat_each_code(p : Pat, f : (Code) -> Unit) -> Unit {
  match p {
    PCode(c) => f(c)
    PInfer(_, cons) =>
      match cons {
        Some(c) => f(c)
        None => ()
      }
    PTuple(elems, _) => for e in elems { pat_each_code(e.pat, f) }
    PArray(sub, _) => pat_each_code(sub, f)
    PObj(props) => for pp in props { pat_each_code(pp.pat, f) }
    PTpl(_, pats) => for x in pats { pat_each_code(x, f) }
    PFn(params, ret) => {
      for x in params {
        pat_each_code(x.pat, f)
      }
      pat_each_code(ret, f)
    }
    PUnion(pats) => for x in pats { pat_each_code(x, f) }
    PVal(c, infs) => {
      f(c)
      for x in infs {
        pat_each_code(x.pat, f)
      }
    }
  }
}

fn calls_into(c : Code, out : Map[Int, Bool]) -> Unit {
  match c {
    CCall(j, _) | CNative(j, _, _) => out.set(j, true)
    _ => ()
  }
  code_each(c, fn(x) { calls_into(x, out) })
}

// ---------------------------------------------------------------------------
// Keys of expressions (equal keys: the same value in the same frame)

fn ty_key(t : Ty, sb : StringBuilder) -> Unit {
  match t {
    TAny => sb.write_string("Ka")
    TUnknown => sb.write_string("Ku")
    TNever => sb.write_string("Kn")
    TString => sb.write_string("Ks")
    TNumber => sb.write_string("Kd")
    TBigInt => sb.write_string("Kb")
    TSymbol => sb.write_string("Ky")
    TObjectKw => sb.write_string("Ko")
    TNull => sb.write_string("Kl")
    TUndefined => sb.write_string("Kf")
    TVoid => sb.write_string("Kv")
    TTrue => sb.write_string("Kt")
    TFalse => sb.write_string("Kx")
    TStrLit(s) => {
      sb.write_string("S\{s.len}:")
      sb.write_string(s.to_string())
    }
    TNumLit(d) => sb.write_string("N\{d.reinterpret_as_int64()}")
    TBigLit(s) => sb.write_string("B\{s.length()}:" + s)
    TInt(v) => sb.write_string("I\{v}")
    TUnion(ms) => {
      sb.write_string("U(")
      for m in ms {
        ty_key(m, sb)
        sb.write_char(',')
      }
      sb.write_char(')')
    }
  }
}

fn code_key_into(c : Code, sb : StringBuilder, budget : Ref[Int]) -> Bool {
  budget.val -= 1
  if budget.val < 0 {
    return false
  }
  let all = fn(cs : Array[Code]) -> Bool {
    for x in cs {
      if !code_key_into(x, sb, budget) {
        return false
      }
      sb.write_char(',')
    }
    true
  }
  match c {
    CSlot(i) => {
      sb.write_string("s\{i}")
      true
    }
    CTy(t) => {
      ty_key(t, sb)
      true
    }
    CCall(j, args) => {
      sb.write_string("c\{j}(")
      let ok = all(args)
      sb.write_char(')')
      ok
    }
    CNative(j, id, args) => {
      sb.write_string("n\{j}.\{id}(")
      let ok = all(args)
      sb.write_char(')')
      ok
    }
    CIndex(o, k) => {
      sb.write_string("i(")
      let ok = all([o, k])
      sb.write_char(')')
      ok
    }
    CKeyof(x) => {
      sb.write_string("k(")
      let ok = all([x])
      sb.write_char(')')
      ok
    }
    CArray(x, ro) => {
      sb.write_string(if ro { "A(" } else { "a(" })
      let ok = all([x])
      sb.write_char(')')
      ok
    }
    CUnion(cs) => {
      sb.write_string("u(")
      let ok = all(cs)
      sb.write_char(')')
      ok
    }
    CTpl(texts, cs) => {
      sb.write_string("t(")
      for s in texts {
        sb.write_string("\{s.len}:")
        sb.write_string(s.to_string())
      }
      let ok = all(cs)
      sb.write_char(')')
      ok
    }
    CTuple(elems, ro) => {
      sb.write_string(if ro { "R(" } else { "r(" })
      for e in elems {
        sb.write_string("\{e.kind}")
        match e.name {
          Some(n) => sb.write_string("\{n.len}:" + n.to_string())
          None => ()
        }
        if !code_key_into(e.code, sb, budget) {
          return false
        }
        sb.write_char(',')
      }
      sb.write_char(')')
      true
    }
    _ => false
  }
}

fn code_key(c : Code) -> String? {
  let sb = StringBuilder::new()
  if code_key_into(c, sb, Ref::new(64)) {
    Some(sb.to_string())
  } else {
    None
  }
}

// expressions worth a slot: they compute something
fn cse_candidate(c : Code) -> Bool {
  match c {
    CCall(_, _) | CNative(_, _, _) | CIndex(_, _) | CKeyof(_) | CTpl(_, _) => true
    _ => false
  }
}

fn key_reads(key : String, slot : Int) -> Bool {
  key.contains("s\{slot},") || key.contains("s\{slot})") || key == "s\{slot}"
}

// ---------------------------------------------------------------------------
// Common check expressions

struct CseCx {
  alias : Alias
  counts : Map[String, Int]
  // what the checked expressions of conditionals start with: only
  // expressions starting so get a key (keys are not cheap)
  heads : Map[String, Bool]
}

fn cse_head(c : Code) -> String {
  match c {
    CCall(j, _) => "c\{j}"
    CNative(j, _, _) => "n\{j}"
    CIndex(_, _) => "i"
    CKeyof(_) => "k"
    CTpl(_, _) => "t"
    _ => ""
  }
}

fn CseCx::wanted(self : CseCx, c : Code) -> Bool {
  cse_candidate(c) && self.heads.contains(cse_head(c))
}

fn CseCx::find_heads(self : CseCx, c : Code) -> Unit {
  match c {
    CObj(_) | CMapped(_) | CGenericFn(_, _) | CFn(_, _, _) => return
    CCond(cd) => if cse_candidate(cd.check) { self.heads.set(cse_head(cd.check), true) }
    _ => ()
  }
  code_each(c, fn(x) { self.find_heads(x) })
}

// occurrences of the candidates, in the parts evaluated with the frame
// (not in object types, mapped types or generic functions, whose parts run
// later or with slots bound again)
fn CseCx::count(self : CseCx, c : Code) -> Unit {
  match c {
    CObj(_) | CMapped(_) | CGenericFn(_, _) | CFn(_, _, _) => return
    _ => ()
  }
  if self.wanted(c) {
    match code_key(c) {
      Some(k) => self.counts.set(k, self.counts.get(k).unwrap_or(0) + 1)
      None => ()
    }
  }
  code_each(c, fn(x) { self.count(x) })
}

fn CseCx::rw_all(self : CseCx, cs : Array[Code], avail : Map[String, Int]) -> Array[Code] {
  cs.map(fn(x) { self.rw(x, avail) })
}

fn CseCx::rw(self : CseCx, c : Code, avail : Map[String, Int]) -> Code {
  match c {
    CTy(_) | CSlot(_) | CUniqueSym(_) => return c
    CObj(_) | CMapped(_) | CGenericFn(_, _) | CFn(_, _, _) => return c
    _ => ()
  }
  if !avail.is_empty() && self.wanted(c) {
    match code_key(c) {
      Some(k) =>
        match avail.get(k) {
          Some(s) => return CSlot(s)
          None => ()
        }
      None => ()
    }
  }
  match c {
    CCall(j, args) => CCall(j, self.rw_all(args, avail))
    CNative(j, id, args) => CNative(j, id, self.rw_all(args, avail))
    CUnion(cs) => CUnion(self.rw_all(cs, avail))
    CInter(cs) => CInter(self.rw_all(cs, avail))
    CTuple(elems, ro) =>
      CTuple(elems.map(fn(e) { { code: self.rw(e.code, avail), kind: e.kind, name: e.name } }), ro)
    CArray(x, ro) => CArray(self.rw(x, avail), ro)
    CKeyof(x) => CKeyof(self.rw(x, avail))
    CIndex(o, k) => CIndex(self.rw(o, avail), self.rw(k, avail))
    CTpl(texts, cs) => CTpl(texts, self.rw_all(cs, avail))
    CLet(s, v, b) => CLet(s, self.rw(v, avail), self.rw(b, avail))
    CCond(cd) => {
      let check = self.rw(cd.check, avail)
      // distributing evaluates the parts again with the slot bound to each
      // member: what reads it is not available there
      let inner = if cd.dist_slot >= 0 {
        let m : Map[String, Int] = Map::new()
        avail.each(fn(k, s) { if !key_reads(k, cd.dist_slot) { m.set(k, s) } })
        m
      } else {
        avail
      }
      let mut let_slot = -1
      let mut let_key = ""
      if self.wanted(check) {
        match code_key(check) {
          Some(k) =>
            if self.counts.get(k).unwrap_or(0) >= 2 {
              let_slot = self.alias.frame
              self.alias.frame += 1
              let_key = k
            }
          None => ()
        }
      }
      let inner2 = if let_slot >= 0 {
        let m : Map[String, Int] = Map::new()
        inner.each(fn(k, s) { m.set(k, s) })
        m.set(let_key, let_slot)
        m
      } else {
        inner
      }
      let pat = match cd.pat {
        Some(p) => Some(self.rw_pat(p, inner2))
        None => None
      }
      let nd : Cond = {
        check: if let_slot >= 0 { CSlot(let_slot) } else { check },
        ext: self.rw(cd.ext, inner2),
        pat,
        t: self.rw(cd.t, inner2),
        f: self.rw(cd.f, inner2),
        dist_slot: cd.dist_slot,
        infer_slots: cd.infer_slots,
        fast: cd.fast,
        fslots: cd.fslots,
        id: cd.id,
      }
      if let_slot >= 0 {
        opt_lets.val += 1
        CLet(let_slot, check, CCond(nd))
      } else {
        CCond(nd)
      }
    }
    _ => c
  }
}

fn CseCx::rw_pat(self : CseCx, p : Pat, avail : Map[String, Int]) -> Pat {
  match p {
    PCode(c) => PCode(self.rw(c, avail))
    PInfer(s, cons) =>
      PInfer(
        s,
        match cons {
          Some(c) => Some(self.rw(c, avail))
          None => None
        },
      )
    PTuple(elems, ro) => PTuple(elems.map(fn(e) { { pat: self.rw_pat(e.pat, avail), kind: e.kind } }), ro)
    PArray(sub, ro) => PArray(self.rw_pat(sub, avail), ro)
    PObj(props) =>
      PObj(props.map(fn(pp) { { name: pp.name, pat: self.rw_pat(pp.pat, avail), optional: pp.optional } }))
    PTpl(texts, pats) => PTpl(texts, pats.map(fn(x) { self.rw_pat(x, avail) }))
    PFn(params, ret) => PFn(params.map(fn(x) { { pat: self.rw_pat(x.pat, avail), kind: x.kind } }), self.rw_pat(ret, avail))
    PUnion(pats) => PUnion(pats.map(fn(x) { self.rw_pat(x, avail) }))
    PVal(c, infs) => PVal(self.rw(c, avail), infs.map(fn(x) { { pat: self.rw_pat(x.pat, avail), kind: x.kind } }))
  }
}

fn cse_alias(a : Alias) -> Unit {
  if a.native >= 0 || a.is_interface {
    return
  }
  let cx = { alias: a, counts: Map::new(), heads: Map::new() }
  cx.find_heads(a.body)
  if cx.heads.is_empty() {
    return
  }
  cx.count(a.body)
  let mut any = false
  cx.counts.each(fn(_k, n) { if n >= 2 { any = true } })
  if any {
    a.body = cx.rw(a.body, Map::new())
  }
}

// ---------------------------------------------------------------------------
// Memoization

// strongly connected components of the call graph (iterative Tarjan)
fn call_sccs(edges : Array[Array[Int]]) -> Array[Int] {
  let n = edges.length()
  let index = Array::make(n, -1)
  let low = Array::make(n, 0)
  let on = Array::make(n, false)
  let comp = Array::make(n, -1)
  let stack : Array[Int] = []
  let mut next = 0
  let mut ncomp = 0
  for root in 0..<n {
    if index[root] >= 0 {
      continue
    }
    // (node, next edge)
    let work : Array[(Int, Int)] = [(root, 0)]
    index[root] = next
    low[root] = next
    next += 1
    stack.push(root)
    on[root] = true
    while !work.is_empty() {
      let (v, ei) = work[work.length() - 1]
      if ei < edges[v].length() {
        work[work.length() - 1] = (v, ei + 1)
        let w = edges[v][ei]
        if index[w] < 0 {
          index[w] = next
          low[w] = next
          next += 1
          stack.push(w)
          on[w] = true
          work.push((w, 0))
        } else if on[w] && index[w] < low[v] {
          low[v] = index[w]
        }
      } else {
        let _ = work.pop()
        if !work.is_empty() {
          let (u, _) = work[work.length() - 1]
          if low[v] < low[u] {
            low[u] = low[v]
          }
        }
        if low[v] == index[v] {
          while true {
            let w = stack.pop().unwrap()
            on[w] = false
            comp[w] = ncomp
            if w == v {
              break
            }
          }
          ncomp += 1
        }
      }
    }
  }
  comp
}

// the most calls into the component one evaluation of the code can make
// that are not in tail position (a call in a distributive conditional's
// branch counts twice: it runs for each member)
fn rec_calls(c : Code, tail : Bool, comp : Array[Int], k : Int) -> Int {
  match c {
    CCall(j, args) => {
      let mut n = 0
      for x in args {
        n += rec_calls(x, false, comp, k)
      }
      if !tail && j < comp.length() && comp[j] == k {
        n += 1
      }
      n
    }
    CCond(cd) => {
      let mut n = rec_calls(cd.check, false, comp, k) + rec_calls(cd.ext, false, comp, k)
      match cd.pat {
        Some(p) => pat_each_code(p, fn(x) { n += rec_calls(x, false, comp, k) })
        None => ()
      }
      let t = rec_calls(cd.t, tail, comp, k)
      let f = rec_calls(cd.f, tail, comp, k)
      let b = if t > f { t } else { f }
      n + (if cd.dist_slot >= 0 { b * 2 } else { b })
    }
    CLet(_, v, b) => rec_calls(v, false, comp, k) + rec_calls(b, tail, comp, k)
    _ => {
      let mut n = 0
      code_each(c, fn(x) { n += rec_calls(x, false, comp, k) })
      n
    }
  }
}

// calls in tail position of a memoized alias of the component go to its body
fn tail_to_body(c : Code, comp : Array[Int], k : Int) -> Code? {
  match c {
    CCall(j, args) =>
      if j < comp.length() && comp[j] == k {
        match memo_body.get(j) {
          Some(b) => Some(CCall(b, args))
          None => None
        }
      } else {
        None
      }
    CCond(cd) => {
      let t = tail_to_body(cd.t, comp, k)
      let f = tail_to_body(cd.f, comp, k)
      if t is None && f is None {
        return None
      }
      Some(CCond({ ..cd, t: t.unwrap_or(cd.t), f: f.unwrap_or(cd.f) }))
    }
    CLet(s, v, b) =>
      match tail_to_body(b, comp, k) {
        Some(nb) => Some(CLet(s, v, nb))
        None => None
      }
    _ => None
  }
}

fn plan_memo() -> Unit {
  let n = aliases.length()
  let edges : Array[Array[Int]] = []
  for i in 0..<n {
    let a = aliases[i]
    let out : Map[Int, Bool] = Map::new()
    if a.native < 0 {
      calls_into(a.body, out)
      for d in a.defaults {
        match d {
          Some(c) => calls_into(c, out)
          None => ()
        }
      }
    }
    let es : Array[Int] = []
    out.each(fn(j, _b) { es.push(j) })
    edges.push(es)
  }
  // not memoized: aliases that can reach a native with effects (a store
  // threaded linearly, updated in place, output and threads through their
  // arguments: lookups would not hit, and effects must happen again)
  let effects : Array[Bool] = Array::make(n, false)
  let callers : Array[Array[Int]] = Array::make(n, [])
  for i in 0..<n {
    callers[i] = []
  }
  for i in 0..<n {
    for j in edges[i] {
      callers[j].push(i)
    }
  }
  let work : Array[Int] = []
  for i in 0..<n {
    if native_has_effects(aliases[i].native) {
      effects[i] = true
      work.push(i)
    }
  }
  while !work.is_empty() {
    let j = work.pop().unwrap()
    for i in callers[j] {
      if !effects[i] {
        effects[i] = true
        work.push(i)
      }
    }
  }
  let comp = call_sccs(edges)
  // aliases in a cycle of the call graph
  let csize : Map[Int, Int] = Map::new()
  for c in comp {
    csize.set(c, csize.get(c).unwrap_or(0) + 1)
  }
  let cyclic = fn(i : Int) -> Bool {
    csize.get(comp[i]).unwrap_or(0) > 1 || edges[i].contains(i)
  }
  let chosen : Array[Int] = []
  for i in 0..<n {
    let a = aliases[i]
    if a.native >= 0 || a.is_interface || a.nparams == 0 || effects[i] {
      continue
    }
    let pick = match memo_mode.val {
      2 => true
      3 => cyclic(i)
      _ => rec_calls(a.body, true, comp, comp[i]) >= 2
    }
    if pick {
      chosen.push(i)
    }
  }
  for i in chosen {
    let a = aliases[i]
    let bi = aliases.length()
    aliases.push({
      name: a.name + "$body",
      doc: a.doc,
      file: a.file,
      nparams: a.nparams,
      param_names: a.param_names,
      defaults: a.defaults,
      body: a.body,
      frame: a.frame,
      native: -1,
      iface_members: a.iface_members,
      iface_heritage: a.iface_heritage,
      decl_params: a.decl_params,
      decl_body: a.decl_body,
      is_interface: false,
    })
    comp.push(comp[i])
    memo_body.set(i, bi)
    let slots : Array[Code] = []
    for p in 0..<a.nparams {
      slots.push(CSlot(p))
    }
    a.body = CCall(bi, slots)
  }
  // loops of the components stay loops
  if !chosen.is_empty() {
    for i in 0..<aliases.length() {
      let a = aliases[i]
      if a.native >= 0 || memo_body.contains(i) {
        continue
      }
      match tail_to_body(a.body, comp, comp[i]) {
        Some(b) => a.body = b
        None => ()
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Results passed on unchanged
//
//   F<...> extends infer X ? X extends [infer A, infer B] ? [A, B] : X : _
//
// (go2types' tail calls: the results, or a panic object, as they are) is F<...>:
// a plain tuple of two (one) elements is rebuilt as itself, anything else is
// X, and never distributes to never. Compiled as the call, a call in tail
// position is a jump that hands the callee's results on, instead of a call,
// a pattern match on its results and a rebuilt pair.

let unwrap_count : Ref[Int] = Ref::new(0)

fn identity_cond(cd : Cond) -> Bool {
  if cd.fast != 1 || cd.fslots.length() != 1 {
    return false
  }
  let x = cd.fslots[0]
  match cd.t {
    CCond(c2) => {
      if c2.fast != 2 || c2.dist_slot != x || c2.fslots.length() < 1 || c2.fslots.length() > 2 {
        return false
      }
      match c2.check {
        CSlot(s) if s == x => ()
        _ => return false
      }
      match c2.f {
        CSlot(s) if s == x => ()
        _ => return false
      }
      match c2.pat {
        Some(PTuple(_, false)) => ()
        _ => return false
      }
      match c2.t {
        CTuple(elems, false) => {
          if elems.length() != c2.fslots.length() {
            return false
          }
          for k in 0..<elems.length() {
            let e = elems[k]
            if e.kind != 0 || e.name is Some(_) {
              return false
            }
            match e.code {
              CSlot(s) if s == c2.fslots[k] => ()
              _ => return false
            }
          }
          true
        }
        _ => false
      }
    }
    _ => false
  }
}

fn unwrap_all(cs : Array[Code]) -> Array[Code] {
  cs.map(unwrap_identity)
}

fn unwrap_identity(c : Code) -> Code {
  match c {
    CTy(_) | CSlot(_) | CUniqueSym(_) => c
    CMapped(_) | CGenericFn(_, _) | CFn(_, _, _) => c
    CCall(j, args) => CCall(j, unwrap_all(args))
    CNative(j, id, args) => CNative(j, id, unwrap_all(args))
    CUnion(cs) => CUnion(unwrap_all(cs))
    CInter(cs) => CInter(unwrap_all(cs))
    CTuple(elems, ro) => CTuple(elems.map(fn(e) { { code: unwrap_identity(e.code), kind: e.kind, name: e.name } }), ro)
    CArray(x, ro) => CArray(unwrap_identity(x), ro)
    CKeyof(x) => CKeyof(unwrap_identity(x))
    CIndex(o, k) => CIndex(unwrap_identity(o), unwrap_identity(k))
    CTpl(texts, cs) => CTpl(texts, unwrap_all(cs))
    CLet(s, v, b) => CLet(s, unwrap_identity(v), unwrap_identity(b))
    CObj(oc) =>
      CObj({
        props: oc.props.map(fn(p) { (p.0, unwrap_identity(p.1), p.2, p.3, p.4) }),
        index: oc.index,
        calls: oc.calls,
        lookup: oc.lookup,
        id: oc.id,
      })
    CCond(cd) => {
      if identity_cond(cd) {
        unwrap_count.val += 1
        return unwrap_identity(cd.check)
      }
      CCond({
        check: unwrap_identity(cd.check),
        ext: cd.ext,
        pat: cd.pat,
        t: unwrap_identity(cd.t),
        f: unwrap_identity(cd.f),
        dist_slot: cd.dist_slot,
        infer_slots: cd.infer_slots,
        fast: cd.fast,
        fslots: cd.fslots,
        id: cd.id,
      })
    }
  }
}

fn optimize_program() -> Unit {
  if unwrap_on.val {
    for a in aliases {
      if a.native < 0 && !a.is_interface {
        a.body = unwrap_identity(a.body)
      }
    }
  }
  if cse_on.val {
    for i in 0..<aliases.length() {
      cse_alias(aliases[i])
    }
  }
  // a program that threads a store is not memoized unless asked for
  // (--memo): the lookups cost about 5% on tstst (the 270-test sample)
  // without hits
  let store_program = aliases.iter().any(fn(a) { native_has_effects(a.native) })
  if memo_mode.val > 0 && (memo_explicit.val || !store_program) {
    plan_memo()
  }
}
