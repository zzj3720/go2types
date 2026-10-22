// Shape analysis: which values can be any, a union or a marker.
//
// A value is simple when it is none of these, and when it is a tuple or an
// object, so are its elements or properties. A conditional with a fast path whose checked value is simple
// needs none of the general machinery: `X extends infer V` binds, a tuple
// pattern binds the elements of a plain tuple of its length and rejects the
// rest, `extends true` and `extends null` compare; never is the one case left
// (the result is never when the conditional distributes, otherwise the true
// branch with never bound). Such conditionals are compiled inline, their
// slots kept in registers (gen.mbt).
//
// Shapes: 0 nothing known yet, 1 simple, 2 anything. A native's result
// follows from its arguments (natives.mbt: native_shape), and values loaded
// from a store are simple when the store declares so (@store-simple);
// --check-shapes makes the compiled code verify every checked value instead
// of trusting this.

let shape_res : Array[Int] = []

let shape_slots : Array[Array[Int]] = []

// callers of each alias (whose shapes depend on its result)
let shape_callers : Array[Map[Int, Bool]] = []

// conditionals compiled inline, by id
let inline_conds : Map[Int, Bool] = Map::new()

let check_shapes : Ref[Bool] = Ref::new(false)

let inline_on : Ref[Bool] = Ref::new(true)

// the size of a function (its instructions' text) past which the branches of
// its inline conditionals are functions of their own
let split_limit : Ref[Int] = Ref::new(200000)

let shape_queue : Array[Int] = []

let shape_queued : Array[Bool] = []

fn shape_enqueue(idx : Int) -> Unit {
  // (a stub waits until the others are done: incr_wake)
  if incr_is_lazy(idx) {
    incr_poked.set(idx, true)
    return
  }
  if !shape_queued[idx] {
    shape_queued[idx] = true
    shape_queue.push(idx)
  }
}

fn shape_join(a : Int, b : Int) -> Int {
  if a > b {
    a
  } else {
    b
  }
}

fn ty_shape(t : Ty) -> Int {
  match t {
    TAny | TUnion(_) => 2
    _ => 1
  }
}

// the alias being analyzed
struct ShapeCx {
  ai : Int
  read : Array[Bool] // slots read in this pass
  mut changed : Bool // one of them changed after it was read
}

fn ShapeCx::bind(self : ShapeCx, slot : Int, s : Int) -> Unit {
  let slots = shape_slots[self.ai]
  if slot >= 0 && slot < slots.length() && s > slots[slot] {
    slots[slot] = s
    if shape_report.val && s == 2 {
      match shape_bind_cause.val {
        Some(c) => shape_scause.set(self.ai * 4096 + slot, c)
        None => ()
      }
    }
    if self.read[slot] {
      self.changed = true
    }
  }
}

fn ShapeCx::slot(self : ShapeCx, slot : Int) -> Int {
  let slots = shape_slots[self.ai]
  if slot >= 0 && slot < slots.length() {
    self.read[slot] = true
    slots[slot]
  } else {
    2
  }
}

fn ShapeCx::call(self : ShapeCx, idx : Int, args : Array[Code]) -> Int {
  let a = aliases[idx]
  let shapes = args.map(fn(c) { self.code(c) })
  if a.native >= 0 {
    return native_shape(a.native, shapes)
  }
  incr_record_contrib(self.ai, idx, shapes)
  let ps = shape_slots[idx]
  for k in 0..<shapes.length() {
    if k < ps.length() && shapes[k] > ps[k] {
      ps[k] = shapes[k]
      shape_enqueue(idx)
      if shape_report.val && shapes[k] == 2 {
        shape_pcause.set(idx * 4096 + k, (self.ai, args[k]))
      }
    }
  }
  shape_callers[idx].set(self.ai, true)
  shape_res[idx]
}

fn ShapeCx::pat(self : ShapeCx, p : Pat) -> Unit {
  match p {
    PCode(c) => {
      let _ = self.code(c)

    }
    PInfer(s, cons) => {
      self.bind(s, 2)
      match cons {
        Some(c) => {
          let _ = self.code(c)

        }
        None => ()
      }
    }
    PTuple(elems, _) => for e in elems { self.pat(e.pat) }
    PArray(sub, _) => self.pat(sub)
    PObj(props) => for pp in props { self.pat(pp.pat) }
    PTpl(_, pats) => for x in pats { self.pat(x) }
    PFn(params, ret) => {
      for x in params {
        self.pat(x.pat)
      }
      self.pat(ret)
    }
    PUnion(pats) => for x in pats { self.pat(x) }
    // (its slots are type parameters while it is computed)
    PVal(c, infs) => {
      for x in infs {
        self.pat(x.pat)
      }
      let _ = self.code(c)

    }
  }
}

fn ShapeCx::all(self : ShapeCx, cs : Array[Code]) -> Int {
  let mut s = 1
  for c in cs {
    s = shape_join(s, self.code(c))
  }
  s
}

fn ShapeCx::code(self : ShapeCx, c : Code) -> Int {
  match c {
    CTy(t) => ty_shape(t)
    CSlot(i) => self.slot(i)
    CCall(idx, args) => self.call(idx, args)
    CNative(idx, _, args) => self.call(idx, args)
    CCond(cd) => self.cond(cd)
    CUnion(cs) | CInter(cs) => {
      let _ = self.all(cs)
      2
    }
    CTuple(elems, _) => {
      let mut s = 1
      for el in elems {
        s = shape_join(s, self.code(el.code))
        if el.kind != 0 {
          s = 2
        }
      }
      s
    }
    CArray(x, _) => {
      let _ = self.code(x)
      1
    }
    // simple when its properties are (an index signature or call
    // signature gives types it does not list)
    CObj(oc) => {
      let s = self.obj(oc)
      if oc.index.is_empty() && oc.calls.is_empty() {
        s
      } else {
        2
      }
    }
    CMapped(mc) => {
      self.bind(mc.slot, 2)
      let _ = self.code(mc.constraint)
      for x in [mc.homo, mc.mods, mc.as_clause] {
        match x {
          Some(y) => {
            let _ = self.code(y)

          }
          None => ()
        }
      }
      let _ = self.code(mc.body)
      2
    }
    // `{ ... }[K]` of a table: one of its properties, or the index
    // signature's type for a key it lacks (a key that is not a literal is
    // trusted not to occur; --check-shapes verifies)
    CIndex(CObj(oc), k) if oc.index.length() <= 1 && oc.calls.is_empty() => {
      let ks = self.code(k)
      let ps = self.obj(oc)
      if oc.index.is_empty() {
        shape_join(ks, ps)
      } else {
        shape_join(shape_join(ks, ps), self.code(oc.index[0].1))
      }
    }
    CIndex(o, k) => {
      let _ = self.code(o)
      let _ = self.code(k)
      2
    }
    CKeyof(x) => {
      let _ = self.code(x)
      2
    }
    CTpl(_, cs) => self.all(cs)
    CFn(params, ret, _) => {
      for p in params {
        let _ = self.code(p.code)

      }
      let _ = self.code(ret)
      1
    }
    CGenericFn(slots, body) => {
      for s in slots {
        self.bind(s, 2)
      }
      let _ = self.code(body)
      1
    }
    CUniqueSym(_) => 1
    CLet(s, v, b) => {
      self.bind(s, self.code(v))
      self.code(b)
    }
  }
}

// the join of the properties' shapes (optional ones add undefined: a union)
fn ShapeCx::obj(self : ShapeCx, oc : ObjCode) -> Int {
  let mut s = 1
  for p in oc.props {
    s = shape_join(s, self.code(p.1))
    if p.2 {
      s = 2
    }
  }
  for ix in oc.index {
    let _ = self.code(ix.0)
    let _ = self.code(ix.1)

  }
  for cl in oc.calls {
    for p in cl.0 {
      let _ = self.code(p.code)

    }
    let _ = self.code(cl.1)

  }
  s
}

// a pattern whose bindings are parts of a simple value it matches: elements
// of a tuple, or the rest of it (a tuple of them)
fn simple_binding_pat(p : Pat) -> Bool {
  match p {
    // (a constraint decides whether the value matches, not what is bound:
    // `X extends infer V extends C` binds X itself)
    PInfer(_, _) => true
    PTuple(elems, _) =>
      elems.iter().all(fn(e) {
        match e.pat {
          PInfer(_, _) | PCode(_) => true
          _ => false
        }
      })
    // properties of an object (simple: so are its property types)
    PObj(props) =>
      props.iter().all(fn(pp) {
        match pp.pat {
          PInfer(_, _) | PCode(_) => true
          _ => false
        }
      })
    _ => false
  }
}

fn ShapeCx::cond(self : ShapeCx, cd : Cond) -> Int {
  let cs = self.code(cd.check)
  let _ = self.code(cd.ext)
  // nothing known yet (0) is optimistic: a later pass sees what binds it
  let simple = cs <= 1
  let inline = cd.fast >= 1 && cd.fast <= 5 && simple
  match cd.pat {
    Some(p) =>
      if inline {
        // the fast pattern binds the value, or elements of it
        for s in cd.fslots {
          self.bind(s, 1)
        }
      } else if simple && simple_binding_pat(p) {
        // the runtime decides, binding parts of a simple value
        for s in cd.infer_slots {
          self.bind(s, 1)
        }
        let _ = self.pat_codes(p)

      } else {
        shape_bind_cause.val = Some(cd.check)
        self.pat(p)
        shape_bind_cause.val = None
      }
    None => ()
  }
  if !simple && cd.dist_slot >= 0 {
    // distributing binds the members of a union
    self.bind(cd.dist_slot, 2)
  }
  inline_conds.set(cd.id, inline)
  if shape_report.val {
    if inline {
      shape_why.remove(cd.id)
    } else {
      shape_why.set(cd.id, self.why(cd))
    }
  }
  let ts = self.code(cd.t)
  let fs = self.code(cd.f)
  // a simple value is not distributed, and selects one of the branches
  if simple {
    shape_join(ts, fs)
  } else {
    2
  }
}

// the codes in a pattern (evaluated for what they bind and call)
fn ShapeCx::pat_codes(self : ShapeCx, p : Pat) -> Unit {
  match p {
    PCode(c) => {
      let _ = self.code(c)

    }
    PInfer(_, Some(c)) => {
      let _ = self.code(c)

    }
    PTuple(elems, _) => for e in elems { self.pat_codes(e.pat) }
    PObj(props) => for pp in props { self.pat_codes(pp.pat) }
    _ => ()
  }
}

// --shape-report: why conditionals are not inline
let shape_report : Ref[Bool] = Ref::new(false)

let shape_why : Map[Int, String] = Map::new()

// why the result of an alias became anything (when it did)
let shape_rcause : Map[Int, String] = Map::new()

// the checked value whose pattern made a slot anything
let shape_scause : Map[Int, Code] = Map::new()

let shape_bind_cause : Ref[Code?] = Ref::new(None)

// the first argument that made a parameter anything: caller, code
let shape_pcause : Map[Int, (Int, Code)] = Map::new()

fn ShapeCx::why(self : ShapeCx, cd : Cond) -> String {
  if cd.fast < 1 || cd.fast > 5 {
    return "general pattern"
  }
  match cd.check {
    CCall(idx, _) => "result of " + aliases[idx].name
    CNative(idx, _, _) => "native " + aliases[idx].name
    CSlot(_) => "slot in " + aliases[self.ai].name
    CCond(_) => "conditional"
    CIndex(_, _) => "index"
    CUnion(_) => "union"
    CTy(_) => "type"
    _ => "other"
  }
}

// why code can be anything: the path to what makes it so ("call N": the
// result of alias N)
fn why2(c : Code, ai : Int, depth : Int) -> String {
  if depth > 200 {
    return "deep"
  }
  match c {
    CTy(TAny) => "any in " + aliases[ai].name
    CTy(TUnion(_)) => "union type in " + aliases[ai].name
    CTy(_) => "simple"
    CSlot(_) | CCall(_, _) | CNative(_, _, _) if code_shape(c, ai) < 2 => "simple"
    CSlot(i) if i < aliases[ai].nparams =>
      match shape_pcause.get(ai * 4096 + i) {
        Some((caller, arg)) => why2(arg, caller, depth + 1)
        None => "parameter \{i} of " + aliases[ai].name + " (entry or default)"
      }
    CSlot(i) if shape_scause.contains(ai * 4096 + i) =>
      why2(shape_scause.get(ai * 4096 + i).unwrap(), ai, depth + 1)
    CSlot(i) => "slot \{i} of " + aliases[ai].name + (if i < aliases[ai].nparams { " (parameter)" } else { "" })
    CCall(idx, _) | CNative(idx, _, _) =>
      if aliases[idx].native >= 0 {
        "native " + aliases[idx].name
      } else {
        "call \{idx}"
      }
    CCond(cd) =>
      if inline_conds.get(cd.id) == Some(true) {
        let w = why2(cd.t, ai, depth + 1)
        if w.has_prefix("simple") { why2(cd.f, ai, depth + 1) } else { w }
      } else if cd.fast < 1 || cd.fast > 5 {
        "general pattern in " + aliases[ai].name
      } else {
        why2(cd.check, ai, depth + 1)
      }
    CIndex(CObj(oc), _) if oc.index.length() <= 1 && oc.calls.is_empty() => {
      if !oc.index.is_empty() {
        let w = why2(oc.index[0].1, ai, depth + 1)
        if !w.has_prefix("simple") {
          return w
        }
      }
      for p in oc.props {
        if p.2 {
          return "optional property in " + aliases[ai].name
        }
        let w = why2(p.1, ai, depth + 1)
        if !w.has_prefix("simple") {
          return w
        }
      }
      "simple"
    }
    CUnion(_) => "union in " + aliases[ai].name
    CInter(_) => "intersection in " + aliases[ai].name
    CIndex(_, _) => "index in " + aliases[ai].name
    CKeyof(_) => "keyof in " + aliases[ai].name
    CMapped(_) => "mapped in " + aliases[ai].name
    CTuple(elems, _) => {
      for el in elems {
        if el.kind != 0 {
          return "tuple spread/optional in " + aliases[ai].name
        }
        let w = why2(el.code, ai, depth + 1)
        if !w.has_prefix("simple") {
          return w
        }
      }
      "simple"
    }
    CTpl(_, cs) => {
      for x in cs {
        let w = why2(x, ai, depth + 1)
        if !w.has_prefix("simple") {
          return w
        }
      }
      "simple"
    }
    _ => "simple"
  }
}

fn code_shape(c : Code, ai : Int) -> Int {
  match c {
    CTy(t) => ty_shape(t)
    CSlot(i) => if i < shape_slots[ai].length() { shape_slots[ai][i] } else { 2 }
    CCall(idx, args) | CNative(idx, _, args) =>
      if aliases[idx].native >= 0 {
        native_shape(aliases[idx].native, args.map(fn(c) { code_shape(c, ai) }))
      } else {
        shape_res[idx]
      }
    _ => 2
  }
}

// the aliases whose result is anything, by the first cause that is not
// another such alias
fn print_root_report() -> Unit {
  let roots : Map[String, Int] = Map::new()
  let mut n2 = 0
  for idx in 0..<aliases.length() {
    if shape_res[idx] < 2 || aliases[idx].native >= 0 {
      continue
    }
    n2 += 1
    let mut cur = idx
    let mut w = ""
    let mut steps = 0
    while steps < 10000 {
      steps += 1
      w = shape_rcause.get(cur).unwrap_or("?")
      if w.has_prefix("call ") {
        let next = match (try? @strconv.parse_int(w.unsafe_substring(start=5, end=w.length()))) {
          Ok(k) => k
          Err(_) => -1
        }
        if next < 0 || next == cur {
          w = w + " (itself) [" + aliases[cur].name + "]"
          break
        }
        cur = next
      } else {
        w = w + " [" + aliases[cur].name + "]"
        break
      }
    }
    roots.set(w, roots.get(w).unwrap_or(0) + 1)
  }
  err("shapes: \{n2} aliases with results that can be anything; their causes:\n")
  let rows = roots.to_array()
  rows.sort_by(fn(a, b) { b.1.compare(a.1) })
  let n = if rows.length() < 40 { rows.length() } else { 40 }
  for i in 0..<n {
    err("shapes: \{rows[i].1} \{rows[i].0}\n")
  }
}

fn print_shape_report() -> Unit {
  print_root_report()
  let counts : Map[String, Int] = Map::new()
  shape_why.each(fn(_id, w) { counts.set(w, counts.get(w).unwrap_or(0) + 1) })
  let rows = counts.to_array()
  rows.sort_by(fn(a, b) { b.1.compare(a.1) })
  let n = if rows.length() < 40 { rows.length() } else { 40 }
  for i in 0..<n {
    err("shapes: \{rows[i].1} \{rows[i].0}\n")
  }
}

fn analyze_alias(idx : Int) -> Unit {
  let a = aliases[idx]
  let cx = { ai: idx, read: Array::make(shape_slots[idx].length(), false), changed: false }
  // a default is evaluated into its parameter's slot
  for k in 0..<a.defaults.length() {
    match a.defaults[k] {
      Some(c) => cx.bind(k, cx.code(c))
      None => ()
    }
  }
  let r = if a.native >= 0 {
    let ps = shape_slots[idx]
    native_shape(a.native, Array::makei(a.nparams, fn(k) { if k < ps.length() { ps[k] } else { 2 } }))
  } else {
    cx.code(a.body)
  }
  if r > shape_res[idx] {
    shape_res[idx] = r
    if shape_report.val && r == 2 {
      // what made it so, while what it depends on is still being raised:
      // the causes form chains back to the first ones
      shape_rcause.set(idx, why2(a.body, idx, 0))
    }
    shape_callers[idx].each(fn(c, _x) { shape_enqueue(c) })
  }
  if cx.changed {
    // a slot was read before a binding raised it (one of a sibling branch)
    shape_enqueue(idx)
  }
}

// entries: called by the runtime with arbitrary arguments
fn analyze_shapes(entries : Array[Int]) -> Unit {
  let n = aliases.length()
  for i in 0..<n {
    shape_res.push(0)
    let a = aliases[i]
    let frame = if a.frame > a.nparams { a.frame } else { a.nparams }
    shape_slots.push(Array::make(frame, 0))
    shape_callers.push(Map::new())
    shape_queued.push(false)
  }
  for e in entries {
    let ps = shape_slots[e]
    for k in 0..<aliases[e].nparams {
      if k < ps.length() {
        ps[k] = 2
      }
    }
  }
  // (an incremental build: the stubs' shapes from the snapshot, incr.mbt)
  incr_shapes_init()
  for i in 0..<n {
    if !incr_is_lazy(i) {
      shape_enqueue(i)
    }
  }
  shape_run_queue()
  // (an incremental build: stubs whose shapes are not those the snapshot
  // says any more are compiled and analyzed too, incr.mbt)
  while incr_wake() {
    shape_run_queue()
  }
}

fn shape_run_queue() -> Unit {
  let mut head = 0
  while head < shape_queue.length() {
    let idx = shape_queue[head]
    head += 1
    shape_queued[idx] = false
    analyze_alias(idx)
    // keep the queue from growing without bound
    if head > 1000000 && head * 2 > shape_queue.length() {
      let rest = shape_queue[head:].to_array()
      shape_queue.clear()
      for x in rest {
        shape_queue.push(x)
      }
      head = 0
    }
  }
  shape_queue.clear()
}
