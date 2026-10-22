// Code generation of functions (see codegen.mbt for the module and constants).

struct Fun {
  buf : Int // the text of its blocks (a buffer of stub.c)
  mut tmp : Int
  mut lbl : Int
  mut cur : String // the current block
  frame : Int // slots of the frame
  tail_ok : Bool // a function of the frame (musttail is possible)
  mut scratch : Int // values the scratch array must hold
  mut uses_out : Bool
  mut size : Int // the instructions' text so far
  // a function of a frame: returns a pair (see pair_ty); the others an i64
  mut ret_pair : Bool
  // slots bound to a native's boolean result (true or false, never never)
  bool_slots : Map[Int, Bool]
  // the i1 of a value that is a comparison's true or false (branched on
  // directly instead of comparing the value with true)
  bool_i1 : Map[String, String]
  // values known to be immediate integers (the result of iand with a
  // constant, padd, ...): operations on them need no runtime path
  int_vals : Map[String, Bool]
  // a value's text as the key of a table, where the conditional that bound
  // it as a bigint made it already (`X extends infer N extends bigint ?
  // {...}[`${N}`]`, go2types' tables): its own value when it is an integer
  // immediate
  tpl_keys : Map[String, String]
  // jump tables (indirectbr): global, labels; defined with the function
  jts : Array[(String, Array[String])]
  // slots held in registers; stored: the frame has the value too. Bindings
  // are undone by the trail when the code generating them leaves its scope,
  // so a register is only used where its definition dominates.
  regs : Map[Int, String]
  stored : Map[Int, Bool]
  trail : Array[(Int, String?, Bool?)]
  // a call's result as a pair -> the call's value (returned as it is)
  pair_src : Map[String, String]
  // an alias's function: entered with its frame at the top (every call of
  // an alias sets the top to the end of the callee's frame), so a call in
  // tail position takes the frame over without testing
  mut owns_frame : Bool
  // an alias's function: its body and parameter count (an object type site
  // that is the whole body is the same object for the same arguments, all
  // of them: gen_ident)
  mut ident_top : (Code, Int)?
  // the site gen_ident makes on a miss (made as it is)
  mut ident_skip : Code?
  // the fast copy of an alias's function (gen_alias): anything but its
  // inline paths jumps to the function itself, which starts over
  mut spec : String?
  // calls on the way of the code (not those of slow paths), and ways out
  // (returns and calls in tail position) other than to the function itself
  mut hard : Int
  mut slow : Int
  mut commits : Int
  // (the block bail opened: its ways out are not counted)
  mut in_dead : Bool
  // the inline caches of its dispatches, by object type and occurrence: a
  // fast copy has the function's own (filled where it is the function that
  // looks a key up)
  ics : Map[String, String]
  // an alias's function whose calls of the alias in tail position with all
  // its arguments jump back to its start (loop_back): the alias, its
  // parameters, where they come from (block, arguments) besides the entry
  mut loop_of : Int
  mut loop_np : Int
  loop_in : Array[(String, Array[String])]
}

fn Fun::new(frame : Int, tail_ok : Bool) -> Fun {
  {
    buf: c_buf_new(),
    tmp: 0,
    lbl: 0,
    cur: "",
    frame,
    tail_ok,
    scratch: 0,
    uses_out: false,
    size: 0,
    ret_pair: true,
    bool_slots: Map::new(),
    bool_i1: Map::new(),
    int_vals: Map::new(),
    tpl_keys: Map::new(),
    jts: [],
    regs: Map::new(),
    stored: Map::new(),
    trail: [],
    pair_src: Map::new(),
    owns_frame: false,
    ident_top: None,
    ident_skip: None,
    spec: None,
    hard: 0,
    slow: 0,
    commits: 0,
    in_dead: false,
    ics: Map::new(),
    loop_of: -1,
    loop_np: 0,
    loop_in: [],
  }
}

fn Fun::t(self : Fun) -> String {
  self.tmp += 1
  "%t" + self.tmp.to_string()
}

fn Fun::l(self : Fun) -> String {
  self.lbl += 1
  "L" + self.lbl.to_string()
}

fn Fun::e(self : Fun, s : String) -> Unit {
  self.size += s.length() + 3
  c_buf_line(self.buf, s)
}

fn Fun::block(self : Fun, l : String) -> Unit {
  c_buf_str(self.buf, l)
  c_buf_str(self.buf, ":\n")
  self.cur = l
  self.in_dead = false
}

fn Fun::br(self : Fun, l : String) -> Unit {
  self.e("br label %" + l)
}

// (a fast copy) the function itself from the start, then a block nothing
// reaches for the code that follows
fn Fun::bail(self : Fun) -> Unit {
  match self.spec {
    Some(full) => {
      let r = self.t()
      self.e(r + " = musttail call " + pair_ty + " " + full + "(" + fwd_params + ")")
      self.e("ret " + pair_ty + " " + r)
      self.block(self.l())
      self.in_dead = true
    }
    None => abort("bail outside a fast copy")
  }
}

// (a fast copy) the function itself unless ok
fn Fun::bail_unless(self : Fun, ok : String) -> Unit {
  let lok = self.l()
  let lb = self.l()
  self.e("br i1 " + ok + ", label %" + lok + ", label %" + lb)
  self.block(lb)
  self.bail()
  self.br(lok)
  self.block(lok)
}

// a call in tail position of a fast copy: the callee stays out of it (what
// it calls would want a frame of the copy's)
fn Fun::commit_attrs(self : Fun) -> String {
  if self.spec is Some(_) {
    " noinline"
  } else {
    ""
  }
}

// a value of the code nothing reaches
fn Fun::dead(self : Fun) -> String {
  let v = self.t()
  self.e(v + " = add i64 0, 0")
  v
}

// a call of the code's way (not of a slow path): a fast copy has none
fn Fun::count_call(self : Fun) -> Unit {
  if self.slow == 0 {
    self.hard += 1
  }
}

fn Fun::slot_ptr_in(self : Fun, base : String, i : Int) -> String {
  let p = self.t()
  self.e(p + " = getelementptr inbounds i64, ptr " + base + ", i64 \{i}")
  p
}

fn Fun::load_slot(self : Fun, i : Int) -> String {
  match self.regs.get(i) {
    Some(v) => return v
    None => ()
  }
  let p = self.slot_ptr_in("%env", i)
  let v = self.t()
  self.e(v + " = load i64, ptr " + p)
  self.bind(i, v, true)
  v
}

// stores into the frame, which the runtime reads (and may bind there too)
fn Fun::store_slot(self : Fun, i : Int, v : String) -> Unit {
  let p = self.slot_ptr_in("%env", i)
  self.e("store i64 " + v + ", ptr " + p)
  self.forget(i)
}

fn Fun::bind(self : Fun, i : Int, v : String, stored : Bool) -> Unit {
  self.trail.push((i, self.regs.get(i), self.stored.get(i)))
  self.regs.set(i, v)
  self.stored.set(i, stored)
}

fn Fun::forget(self : Fun, i : Int) -> Unit {
  if self.regs.contains(i) {
    self.trail.push((i, self.regs.get(i), self.stored.get(i)))
    self.regs.remove(i)
    self.stored.remove(i)
  }
}

fn Fun::mark(self : Fun) -> Int {
  self.trail.length()
}

fn Fun::undo(self : Fun, m : Int) -> Unit {
  while self.trail.length() > m {
    let (i, r, st) = self.trail.pop().unwrap()
    match r {
      Some(v) => self.regs.set(i, v)
      None => self.regs.remove(i)
    }
    match st {
      Some(b) => self.stored.set(i, b)
      None => self.stored.remove(i)
    }
  }
}

// before the frame is passed to code: the slots it reads that are only in
// registers are stored
fn Fun::flush(self : Fun, reads : Code) -> Unit {
  let dirty : Array[(Int, String)] = []
  let mut free : Map[Int, Bool]? = None
  self.regs.each(fn(i, v) {
    if self.stored.get(i) != Some(true) {
      let b = match free {
        Some(b) => b
        None => {
          let b = code_free(reads)
          free = Some(b)
          b
        }
      }
      if b.contains(i) {
        dirty.push((i, v))
      }
    }
  })
  for d in dirty {
    let v = self.val(d.1)
    let p = self.slot_ptr_in("%env", d.0)
    self.e("store i64 " + v + ", ptr " + p)
    self.bind(d.0, v, true)
  }
}

// the arguments past the registers
fn Fun::store_args(self : Fun, base : String, vals : Array[String]) -> Unit {
  for i in reg_args..<vals.length() {
    let p = self.slot_ptr_in(base, i)
    self.e("store i64 " + vals[i] + ", ptr " + p)
  }
}

// stores values into the scratch array; returns its pointer
fn Fun::scratch_of(self : Fun, vals : Array[String]) -> String {
  if self.spec is Some(_) {
    return "null"
  }
  if vals.length() > self.scratch {
    self.scratch = vals.length()
  }
  if self.scratch == 0 {
    self.scratch = 1
  }
  for i in 0..<vals.length() {
    let p = self.t()
    self.e(p + " = getelementptr inbounds i64, ptr %scr, i64 \{i}")
    self.e("store i64 " + vals[i] + ", ptr " + p)
  }
  "%scr"
}

// Pairs. A function of a frame returns { i64, i64 }: (v, 0) is the value v,
// (a, 4) the tuple [a], (a, b) with any other b nonzero the tuple [a, b],
// without allocating it (results, e.g. [heap, value]; 4 is no value). The
// result of such a call is an operand "a##b" until
// something needs it as a value (val): a tuple pattern takes its elements,
// a return passes it on.

let pair_ty : String = "{ i64, i64 }"

// the second part of the pair (a, pair_one): the tuple [a]
let pair_one : String = "4"

fn lazy_pair(a : String, b : String) -> String {
  a + "##" + b
}

fn pair_parts(op : String) -> (String, String)? {
  match op.find("##") {
    Some(i) => Some((op.unsafe_substring(start=0, end=i), op.unsafe_substring(start=i + 2, end=op.length())))
    None => None
  }
}

// an operand as a value (a pair is made the tuple it is)
fn Fun::val(self : Fun, op : String) -> String {
  match pair_parts(op) {
    Some((a, b)) if self.spec is Some(_) => {
      // (the value a; a tuple is made by the function itself)
      let z = self.t()
      self.e(z + " = icmp eq i64 " + b + ", 0")
      self.bail_unless(z)
      a
    }
    Some((a, b)) => {
      let v = self.t()
      self.e(v + " = call i64 @tstc_box(i64 " + a + ", i64 " + b + ")")
      v
    }
    None => op
  }
}

fn Fun::ret(self : Fun, op : String) -> Unit {
  if !self.in_dead {
    self.commits += 1
  }
  if !self.ret_pair {
    let v = self.val(op)
    self.e("ret i64 " + v)
    return
  }
  match self.pair_src.get(op) {
    Some(c) => {
      self.e("ret " + pair_ty + " " + c)
      return
    }
    None => ()
  }
  match pair_parts(op) {
    Some((a, b)) => {
      let r0 = self.t()
      self.e(r0 + " = insertvalue " + pair_ty + " poison, i64 " + a + ", 0")
      let r1 = self.t()
      self.e(r1 + " = insertvalue " + pair_ty + " " + r0 + ", i64 " + b + ", 1")
      self.e("ret " + pair_ty + " " + r1)
    }
    None =>
      if op.has_prefix("%") {
        let r = self.t()
        self.e(r + " = insertvalue " + pair_ty + " { i64 poison, i64 0 }, i64 " + op + ", 0")
        self.e("ret " + pair_ty + " " + r)
      } else {
        self.e("ret " + pair_ty + " { i64 " + op + ", i64 0 }")
      }
  }
}

// the result of a call of a function of a frame
fn Fun::call_pair(self : Fun, callee_args : String) -> String {
  self.count_call()
  if self.spec is Some(_) {
    self.bail()
    return lazy_pair(self.dead(), self.dead())
  }
  let c = self.t()
  self.e(c + " = call " + pair_ty + " " + callee_args)
  let a = self.t()
  self.e(a + " = extractvalue " + pair_ty + " " + c + ", 0")
  let b = self.t()
  self.e(b + " = extractvalue " + pair_ty + " " + c + ", 1")
  let p = lazy_pair(a, b)
  self.pair_src.set(p, c)
  p
}

// the value in tail position is returned
fn Fun::finish(self : Fun, v : String, tail : Bool) -> String? {
  if tail {
    self.ret(v)
    None
  } else {
    Some(v)
  }
}

fn args_list(vals : Array[String]) -> String {
  let sb = StringBuilder::new()
  for i in 0..<vals.length() {
    if i > 0 {
      sb.write_string(", ")
    }
    sb.write_string("i64 " + vals[i])
  }
  sb.to_string()
}

fn rt(name : String, sig : String) -> String {
  declare("@" + name, sig)
  "@" + name
}

fn Fun::rtcall(self : Fun, name : String, sig : String, args : String) -> String {
  if args.contains("%env") {
    abort("rtcall with the frame: rtcall_env")
  }
  let f = rt(name, sig)
  self.count_call()
  if self.spec is Some(_) {
    self.bail()
    return self.dead()
  }
  let v = self.t()
  self.e(v + " = call i64 " + f + "(" + args + ")")
  v
}

// a call of the runtime with the frame, for the parts of reads
fn Fun::rtcall_env(self : Fun, name : String, sig : String, args : String, reads : Code) -> String {
  self.count_call()
  if self.spec is Some(_) {
    self.bail()
    return self.dead()
  }
  self.flush(reads)
  let f = rt(name, sig)
  let v = self.t()
  self.e(v + " = call i64 " + f + "(" + args + ")")
  v
}

fn Fun::gen_v(self : Fun, c : Code) -> String {
  self.val(self.gen_op(c))
}

// an operand (possibly a pair)
fn Fun::gen_op(self : Fun, c : Code) -> String {
  match self.gen(c, false) {
    Some(v) => v
    None => abort("value expected")
  }
}

fn Fun::gen_all(self : Fun, cs : Array[Code]) -> Array[String] {
  cs.map(fn(c) { self.gen_v(c) })
}

// one arm of a branching construct: its value flows to the join block (a
// pair as its two parts: the join is a pair too, boxed only where a value
// is needed)
fn Fun::arm(self : Fun, v : String?, results : Array[(String, String)], lj : String) -> Unit {
  match v {
    Some(x) => {
      results.push((x, self.cur))
      self.br(lj)
    }
    None => ()
  }
}

fn Fun::join(self : Fun, results : Array[(String, String)], lj : String, tail : Bool) -> String? {
  if tail {
    return None
  }
  self.block(lj)
  if results.is_empty() {
    self.e("unreachable")
    return Some(v_never)
  }
  let any_pair = results.iter().any(fn(r) { pair_parts(r.0) is Some(_) })
  if !any_pair {
    let v = self.t()
    let sb = StringBuilder::new()
    sb.write_string(v + " = phi i64 ")
    for i in 0..<results.length() {
      if i > 0 {
        sb.write_string(", ")
      }
      sb.write_string("[ " + results[i].0 + ", %" + results[i].1 + " ]")
    }
    self.e(sb.to_string())
    return Some(v)
  }
  // (v, 0) is the value v
  let va = self.t()
  let vb = self.t()
  let sa = StringBuilder::new()
  let sb = StringBuilder::new()
  sa.write_string(va + " = phi i64 ")
  sb.write_string(vb + " = phi i64 ")
  for i in 0..<results.length() {
    if i > 0 {
      sa.write_string(", ")
      sb.write_string(", ")
    }
    let (a, b) = match pair_parts(results[i].0) {
      Some(ab) => ab
      None => (results[i].0, "0")
    }
    sa.write_string("[ " + a + ", %" + results[i].1 + " ]")
    sb.write_string("[ " + b + ", %" + results[i].1 + " ]")
  }
  self.e(sa.to_string())
  self.e(sb.to_string())
  Some(lazy_pair(va, vb))
}

// ---------------------------------------------------------------------------
// Calls
//
// Every function of a frame has one prototype (musttail needs it): the frame,
// and the first reg_args arguments of an alias in registers (its frame has
// slots for them, stored only when something else reads the frame). The
// others ignore the registers, and pass on their own.

// (5: what the hot functions of compiled Go take (heap, receiver, a few
// arguments); each register more is a move per call and a store in the
// callee under llc -O0: 7 cost 2.4% more instructions and cycles on
// intersectionMini20)
let reg_args : Int = 5

fn params_def() -> String {
  let sb = StringBuilder::new()
  sb.write_string("ptr %env")
  for i in 0..<reg_args {
    sb.write_string(", i64 %a\{i}")
  }
  sb.to_string()
}

let fwd_params : String = params_def()

fn frame_proto() -> String {
  frame_proto_text
}

let frame_proto_text : String = make_frame_proto()

fn make_frame_proto() -> String {
  let sb = StringBuilder::new()
  sb.write_string("(ptr")
  for _i in 0..<reg_args {
    sb.write_string(", i64")
  }
  sb.write_string(")")
  sb.to_string()
}

// the arguments of a call of an alias: the frame, the registers
fn reg_call_args(base : String, vals : Array[String]) -> String {
  let sb = StringBuilder::new()
  sb.write_string("ptr " + base)
  for i in 0..<reg_args {
    // (unused registers get 0 for llc -O0, which loads a stack slot for
    // poison; an optimizing back end leaves them as they are)
    sb.write_string(
      if i < vals.length() {
        ", i64 " + vals[i]
      } else if native_fast_on.val {
        ", i64 poison"
      } else {
        ", i64 0"
      },
    )
  }
  sb.to_string()
}

// a call of a function of a frame of callee_frame slots with these arguments
fn Fun::call_frame(
  self : Fun,
  fname : String,
  vals : Array[String],
  callee_frame : Int,
  tail : Bool,
) -> String? {
  if tail && self.tail_ok {
    // the frame is reused when it is owned (it ends at the top)
    let base = self.tail_base()
    self.store_args(base, vals)
    // (the callee moves the top past its frame: entry_top)
    let r = self.t()
    self.e(r + " = musttail call " + pair_ty + " " + fname + "(" + reg_call_args(base, vals) + ")" + self.commit_attrs())
    self.e("ret " + pair_ty + " " + r)
    if !self.in_dead {
      self.commits += 1
    }
    return None
  }
  let _ = callee_frame
  if self.spec is Some(_) {
    return self.finish(self.call_pair(""), tail)
  }
  let t0 = self.top_ptr()
  self.store_args(t0, vals)
  let r = self.call_pair(fname + "(" + reg_call_args(t0, vals) + ")")
  self.restore_top(t0)
  self.finish(r, tail)
}

// the top of the environment stack (an alias's function: the end of its
// frame, see owns_frame)
fn Fun::top_ptr(self : Fun) -> String {
  if self.owns_frame {
    return self.slot_ptr_in("%env", self.frame)
  }
  let t0 = self.t()
  self.e(t0 + " = load ptr, ptr @tstc_top")
  t0
}

// after a call: the top back where it was, but in a function owning its
// frame (it computes its callees' frames from its own, top_ptr; what is
// above is dead, and its calls set the top again)
fn Fun::restore_top(self : Fun, t0 : String) -> Unit {
  if !self.owns_frame {
    self.e("store ptr " + t0 + ", ptr @tstc_top")
  }
}

// an alias's (or filler's) function moves the top past its frame first: its
// callers call it with its frame at the top (from %env on), and it takes
// the frame over (owns_frame)
fn Fun::entry_top(self : Fun) -> Unit {
  let nt = self.slot_ptr_in("%env", self.frame)
  self.e("store ptr " + nt + ", ptr @tstc_top")
}

// where the callee of a call in tail position has its frame: this one's when
// it is owned (it ends at the top), else from the top on
fn Fun::tail_base(self : Fun) -> String {
  if self.owns_frame {
    return "%env"
  }
  let t0 = self.t()
  self.e(t0 + " = load ptr, ptr @tstc_top")
  let fend = self.slot_ptr_in("%env", self.frame)
  let own = self.t()
  self.e(own + " = icmp eq ptr " + t0 + ", " + fend)
  let base = self.t()
  self.e(base + " = select i1 " + own + ", ptr %env, ptr " + t0)
  base
}

// a function of this frame: a jump in tail position; otherwise a call that
// must not take the frame over (the top is moved past it meanwhile)
fn Fun::call_here(self : Fun, fname : String, tail : Bool, reads : Code) -> String? {
  if !(tail && self.tail_ok) && self.spec is Some(_) {
    return self.finish(self.call_pair(""), tail)
  }
  self.flush(reads)
  if tail && self.tail_ok {
    if self.owns_frame {
      // (the top at the frame's end again: the function takes it over when
      // it is owned)
      self.entry_top()
    }
    let r = self.t()
    self.e(r + " = musttail call " + pair_ty + " " + fname + "(" + fwd_params + ")" + self.commit_attrs())
    self.e("ret " + pair_ty + " " + r)
    if !self.in_dead {
      self.commits += 1
    }
    return None
  }
  let t0 = self.top_ptr()
  let t1 = self.t()
  self.e(t1 + " = getelementptr inbounds i64, ptr " + t0 + ", i64 1")
  self.e("store ptr " + t1 + ", ptr @tstc_top")
  let r = self.call_pair(fname + "(" + fwd_params + ")")
  self.restore_top(t0)
  self.finish(r, tail)
}

// ---------------------------------------------------------------------------
// Expressions

fn Fun::gen(self : Fun, code : Code, tail : Bool) -> String? {
  match code {
    CObj(_) | CMapped(_) | CFn(_, _, _) | CGenericFn(_, _) if self.ident_site(code) =>
      return self.gen_ident(code, tail)
    CNative(_, id, _) if native_name(id) == "iface" && self.ident_site(code) => return self.gen_ident(code, tail)
    _ => ()
  }
  match code {
    CTy(t) => self.finish(ty_const(t), tail)
    CSlot(i) => self.finish(self.load_slot(i), tail)
    CCall(idx, args) => self.gen_call(idx, args, tail)
    CNative(idx, id, args) => self.gen_native(idx, id, args, tail)
    CCond(cd) =>
      if inline_conds.get(cd.id) == Some(true) {
        self.gen_cond_inline(cd, tail)
      } else {
        self.call_here(cond_fn(cd, self.frame), tail, code)
      }
    CUnion(cs) => {
      let vals = self.gen_all(cs)
      let p = self.scratch_of(vals)
      let v = self.rtcall(
        "rt_union",
        "i64 @rt_union(ptr nocapture readonly, i64)",
        "ptr " + p + ", i64 \{vals.length()}",
      )
      self.finish(v, tail)
    }
    CInter(cs) => {
      let vals = self.gen_all(cs)
      let p = self.scratch_of(vals)
      // an intersection of no type variable is one the checker resolves
      // as written (getTypeFromIntersectionTypeNode: string & {} stays)
      let name = if cs.length() == 2 && code_free(code).is_empty() {
        "rt_inter_node"
      } else {
        "rt_inter"
      }
      let v = self.rtcall(
        name,
        "i64 @" + name + "(ptr nocapture readonly, i64)",
        "ptr " + p + ", i64 \{vals.length()}",
      )
      self.finish(v, tail)
    }
    CTuple(elems, ro) => self.gen_tuple(elems, ro, tail)
    CArray(c, ro) => {
      let v = self.gen_v(c)
      let r = self.rtcall(
        "rt_array",
        "i64 @rt_array(i64, i64)",
        "i64 " + v + ", i64 " + (if ro { "1" } else { "0" }),
      )
      self.finish(r, tail)
    }
    CObj(oc) => {
      let d = obj_desc(oc, self.frame)
      let r = self.rtcall_env("rt_obj", "i64 @rt_obj(ptr, ptr nocapture)", "ptr " + d + ", ptr %env", code)
      self.finish(r, tail)
    }
    CMapped(mc) => {
      let d = mapped_desc(mc, self.frame)
      let r = self.rtcall_env(
        "rt_mapped",
        "i64 @rt_mapped(ptr, ptr nocapture)",
        "ptr " + d + ", ptr %env",
        code,
      )
      self.finish(r, tail)
    }
    CIndex(CObj(oc), k) if oc.index.length() <= 1 && oc.calls.is_empty() =>
      self.gen_dispatch(oc, k, tail)
    CIndex(o, k) => {
      let ov = self.gen_v(o)
      let kv = self.gen_v(k)
      let r = self.rtcall("rt_index", "i64 @rt_index(i64, i64)", "i64 " + ov + ", i64 " + kv)
      self.finish(r, tail)
    }
    CKeyof(c) => {
      let v = self.gen_v(c)
      let r = self.rtcall("rt_keyof", "i64 @rt_keyof(i64)", "i64 " + v)
      self.finish(r, tail)
    }
    CTpl(texts, cs) => {
      if cs.is_empty() {
        return self.finish(ty_const(TStrLit(texts[0])), tail)
      }
      let vals = self.gen_all(cs)
      let tg = ptr_array(texts.map(fn(s) { str_global(s) }))
      let p = self.scratch_of(vals)
      let r = self.rtcall(
        "rt_tpl",
        "i64 @rt_tpl(ptr, ptr nocapture readonly, i64)",
        "ptr " + tg + ", ptr " + p + ", i64 \{vals.length()}",
      )
      self.finish(r, tail)
    }
    CFn(params, ret, ctor) => {
      let tys = params.map(fn(p) { self.gen_v(p.code) })
      let rv = self.gen_v(ret)
      let d = fn_desc(params, ctor)
      let p = self.scratch_of(tys)
      let r = self.rtcall(
        "rt_fnty",
        "i64 @rt_fnty(ptr, ptr nocapture readonly, i64)",
        "ptr " + d + ", ptr " + p + ", i64 " + rv,
      )
      self.finish(r, tail)
    }
    CGenericFn(slots, body) => {
      let k = code_fn(body, self.frame, "")
      let sg = i64_array(slots.map(fn(s) { s.to_string() }))
      let r = self.rtcall_env(
        "rt_genfn",
        "i64 @rt_genfn(ptr, i64, ptr, ptr nocapture, i64)",
        "ptr " + sg + ", i64 \{slots.length()}, ptr " + k + ", ptr %env, i64 \{self.frame}",
        code,
      )
      self.finish(r, tail)
    }
    CLet(slot, v, body) => {
      // the value stays in a register (stored when other code reads the
      // frame); the conditional in its scope is generated here, as it would
      // have been as the body of a function
      let x = self.gen_op(v)
      self.bind(slot, x, false)
      if tail && self.tail_ok && self.size <= split_limit.val {
        self.gen_top(body)
      } else if tail && self.tail_ok {
        self.call_here(code_fn(body, self.frame, ""), true, body)
      } else {
        self.gen(body, tail)
      }
    }
    CUniqueSym(id) => {
      let g = intern(" = hidden constant { i32, i32, i64 } { i32 26, i32 0, i64 \{id} }, align 8\n")
      self.finish(ptr_val(g), tail)
    }
  }
}

fn Fun::gen_call(self : Fun, idx : Int, args : Array[Code], tail : Bool) -> String? {
  let a = aliases[idx]
  if a.native >= 0 {
    return self.gen_native(idx, a.native, args, tail)
  }
  if a.nparams == 0 && args.is_empty() {
    self.count_call()
    if self.spec is Some(_) {
      self.bail()
      return self.finish(self.dead(), tail)
    }
    let v = self.t()
    self.e(v + " = call i64 " + const_fn(idx) + "()")
    return self.finish(v, tail)
  }
  let vals = self.gen_all(args)
  if tail && self.tail_ok && idx == self.loop_of && vals.length() == a.nparams {
    self.loop_in.push((self.cur, vals))
    self.br("Lhdr")
    return None
  }
  let fname = if vals.length() < a.nparams {
    filler_fn(idx, vals.length())
  } else {
    alias_fn(idx)
  }
  self.call_frame(fname, vals, a.frame, tail)
}

// (an alias's function, loop_of) the parameters in phis of the block Lhdr,
// which the start of the body (Lb) follows: the arguments come from the
// registers and the frame at the entry, from the calls of the alias in tail
// position after that (loop_back), without storing them into the frame (the
// slots past the registers are bound as not stored)
fn Fun::loop_start(self : Fun, idx : Int, np : Int) -> Unit {
  self.loop_of = idx
  self.loop_np = np
  let init : Array[String] = []
  for i in 0..<np {
    if i < reg_args {
      init.push("%a\{i}")
    } else {
      let p = self.slot_ptr_in("%env", i)
      let v = self.t()
      self.e(v + " = load i64, ptr " + p)
      init.push(v)
    }
  }
  self.loop_in.push((self.cur, init))
  self.br("Lhdr")
  self.block("Lb")
  // (the top at the frame's end, as at the entry)
  self.entry_top()
  for i in 0..<np {
    self.bind(i, "%q\{i}", false)
  }
}

// the block Lhdr (loop_start), after the others
fn Fun::loop_end(self : Fun) -> Unit {
  self.block("Lhdr")
  for i in 0..<self.loop_np {
    let sb = StringBuilder::new()
    sb.write_string("%q\{i} = phi i64 ")
    for k, inc in self.loop_in {
      if k > 0 {
        sb.write_string(", ")
      }
      sb.write_string("[ " + inc.1[i] + ", %" + inc.0 + " ]")
    }
    self.e(sb.to_string())
  }
  self.br("Lb")
}

fn native_sig(sym : String, n : Int) -> String {
  let sig = StringBuilder::new()
  sig.write_string("i64 @" + sym + "(")
  for i in 0..<n {
    if i > 0 {
      sig.write_string(", ")
    }
    sig.write_string("i64")
  }
  sig.write_string(")")
  sig.to_string()
}

fn Fun::gen_native(self : Fun, idx : Int, id : Int, args : Array[Code], tail : Bool) -> String? {
  if native_name(id) == "rtok" {
    // natively a failing operation does not return (rt/try.c): every result
    // is one
    return self.finish(v_true, tail)
  }
  let n = aliases[idx].nparams
  let mut vals : Array[String] = []
  if native_is_lib(id) && native_name(id) == "tget" && args.length() == 2 && native_fast_on.val &&
    self.spec is None {
    // an element of a pair (a struct's two cells loaded as one, hloadt
    // below): no tuple made
    let op = self.gen_op(args[0])
    let k = self.gen_v(args[1])
    let mut elem = ""
    match (pair_parts(op), const_int(k)) {
      (Some((a, b)), Some(i)) =>
        if i == 0L || i == 1L {
          elem = self.t()
          self.e(elem + " = call i64 @tstc_pget(i64 " + a + ", i64 " + b + ", i64 " + k + ")")
        }
      _ => ()
    }
    if elem != "" {
      return self.finish(elem, tail)
    }
    vals = [self.val(op), k]
  } else {
    vals = self.gen_all(args)
  }
  while vals.length() < n {
    vals.push(v_unknown)
  }
  if native_is_lib(id) && native_name(id) == "halloc" && vals.length() == 3 && native_fast_on.val &&
    store_in_place() && self.spec is None && const_int(vals[2]) == Some(1L) {
    match halloc_zeros(args[1]) {
      Some(zs) => return self.finish(self.gen_halloc(vals, zs), tail)
      None => ()
    }
  }
  if native_is_lib(id) && native_name(id) == "hloadt" && args.length() == 3 && native_fast_on.val &&
    store_in_place() && self.spec is None && (match args[2] {
      CTy(TStrLit(l)) => l.equals_string("(ss)")
      _ => false
    }) {
    // a struct of two cells: their values as a pair, the tuple made only
    // where a value is needed
    self.count_call()
    let c = self.t()
    self.e(c + " = call " + pair_ty + " @tstc_hload2(" + args_list(vals) + ")")
    let a = self.t()
    self.e(a + " = extractvalue " + pair_ty + " " + c + ", 0")
    let b = self.t()
    self.e(b + " = extractvalue " + pair_ty + " " + c + ", 1")
    return self.finish(lazy_pair(a, b), tail)
  }
  let sym = native_symbol(id)
  if native_is_lib(id) && native_name(id) == "iwrap" && vals.length() == 2 && small_wrap(vals[1]) {
    return self.finish(self.gen_iwrap(vals[0], const_int(vals[1]).unwrap(), sym), tail)
  }
  if native_is_lib(id) && vals.length() == 2 {
    match self.gen_int_op(native_name(id), vals[0], vals[1], sym) {
      Some(v) => return self.finish(v, tail)
      None => ()
    }
  }
  if native_is_lib(id) && native_fast_on.val && native_name(id) == "ta2" && vals.length() == 3 {
    if self.spec is Some(_) {
      // (the function itself where the inline path does not do)
      let c = self.splice("ta2", vals)
      let a = self.t()
      self.e(a + " = extractvalue " + pair_ty + " " + c + ", 0")
      let b = self.t()
      self.e(b + " = extractvalue " + pair_ty + " " + c + ", 1")
      return self.finish(lazy_pair(a, b), tail)
    }
    let c = self.t()
    self.e(c + " = call " + pair_ty + " @tstc_ta2(" + args_list(vals) + ")")
    let a = self.t()
    self.e(a + " = extractvalue " + pair_ty + " " + c + ", 0")
    let b = self.t()
    self.e(b + " = extractvalue " + pair_ty + " " + c + ", 1")
    let p = lazy_pair(a, b)
    self.pair_src.set(p, c)
    return self.finish(p, tail)
  }
  if native_is_lib(id) {
    match inline_native(native_name(id), vals.length()) {
      Some(f) => {
        if self.spec is Some(_) {
          if !spec_natives.contains(native_name(id)) {
            // (what changes the cells: by the function itself)
            self.bail()
            return self.finish(self.dead(), tail)
          }
          let _ = f
          return self.finish(self.splice(native_name(id), vals), tail)
        }
        if !spec_natives.contains(native_name(id)) {
          // (a fast copy has it by the function itself)
          self.count_call()
        }
        let v = self.t()
        self.e(v + " = call i64 " + f + "(" + args_list(vals) + ")")
        let nm = native_name(id)
        if nm == "sidx" || nm == "slen" || nm == "sat" {
          // (an immediate integer always)
          self.int_vals.set(v, true)
        }
        return self.finish(v, tail)
      }
      None => ()
    }
  }
  // (a failure: seldom on the way)
  let panic = native_name(id) == "panic"
  if panic {
    self.slow += 1
  }
  let r = self.native_call(id, sym, vals)
  if panic {
    self.slow -= 1
  }
  // natives whose result is always an immediate integer: a slice element's
  // address, a string's length, an integer wrapped to 8, 16 or 32 bits
  let nm = native_name(id)
  if native_is_lib(id) &&
    (nm == "sidx" || nm == "slen" || (nm == "iwrap" && vals.length() == 2 && small_wrap(vals[1]))) {
    self.int_vals.set(r, true)
  }
  self.finish(r, tail)
}

// an integer wrapped to 8, 16 or 32 bits (k < 0: unsigned), as wrap_int in
// rt/prim.c: inline for an immediate, the runtime for the rest
fn Fun::gen_iwrap(self : Fun, a : String, k : Int64, sym : String) -> String {
  let bits = if k < 0L { -k } else { k }
  let ty = "i\{bits}"
  let isi = self.t()
  self.e(isi + " = trunc i64 " + a + " to i1")
  let lentry = self.cur
  let lfast = self.l()
  let lslow = self.l()
  let lj = self.l()
  self.e("br i1 " + isi + ", label %" + lfast + ", label %" + lslow)
  self.block(lfast)
  let x = self.t()
  self.e(x + " = ashr i64 " + a + ", 1")
  let n = self.t()
  self.e(n + " = trunc i64 " + x + " to " + ty)
  let w = self.t()
  self.e(w + " = " + (if k < 0L { "zext" } else { "sext" }) + " " + ty + " " + n + " to i64")
  let s2 = self.t()
  self.e(s2 + " = shl i64 " + w + ", 1")
  let r = self.t()
  self.e(r + " = or i64 " + s2 + ", 1")
  self.br(lj)
  let _ = lentry
  self.block(lslow)
  self.slow += 1
  let rs = self.rtcall(sym, native_sig(sym, 2), args_list([a, ((k * 2L) + 1L).to_string()]))
  self.slow -= 1
  let lslow_end = self.cur
  self.br(lj)
  self.block(lj)
  let v = self.t()
  self.e(v + " = phi i64 [ " + r + ", %" + lfast + " ], [ " + rs + ", %" + lslow_end + " ]")
  self.int_vals.set(v, true)
  v
}

fn small_wrap(k : String) -> Bool {
  match const_int(k) {
    Some(w) => w == 8L || w == -8L || w == 16L || w == -16L || w == 32L || w == -32L
    None => false
  }
}

// the cells of a constant zero pattern of halloc and their values' kinds
// (K_* of rt/tstc.h): a constant or a tuple of up to 32 constants
fn halloc_zeros(c : Code) -> Array[(String, Int)]? {
  let one = fn(c : Code) -> (String, Int)? {
    match c {
      CTy(t) => {
        let k = match t {
          TAny => 0
          TUnknown => 1
          TNever => 2
          TString => 3
          TNumber => 4
          TBigInt => 5
          TSymbol => 6
          TObjectKw => 7
          TNull => 8
          TUndefined => 9
          TVoid => 10
          TTrue => 11
          TFalse => 12
          TStrLit(_) => 16
          TNumLit(_) => 17
          TInt(v) => if v >= -4611686018427387904L && v < 4611686018427387904L { 29 } else { -1 }
          _ => -1
        }
        if k < 0 {
          None
        } else {
          Some((ty_const(t), k))
        }
      }
      _ => None
    }
  }
  match c {
    CTuple(elems, false) if elems.length() >= 1 && elems.length() <= 32 => {
      let out : Array[(String, Int)] = []
      for e in elems {
        if e.kind != 0 || e.name is Some(_) {
          return None
        }
        match one(e.code) {
          Some(z) => out.push(z)
          None => return None
        }
      }
      Some(out)
    }
    CTuple(_, _) => None
    _ =>
      match one(c) {
        Some(z) => Some([z])
        None => None
      }
  }
}

// halloc<H, zero, 1n> of store 0 inline: the cells from the run the cell
// store allocates from (rt/cellgc.c cells_alloc_kind, its CellGc's first
// fields), their start and kinds bits, the zero values; the native for
// anything else (another store, a collection due, no room in the run)
fn Fun::gen_halloc(self : Fun, vals : Array[String], zs : Array[(String, Int)]) -> String {
  // (a write: a fast copy has it by the function itself)
  self.count_call()
  sym_decls.set("@cells_since", "@cells_since = external global i64")
  sym_decls.set("@cells_threshold", "@cells_threshold = external global i64")
  sym_decls.set("@cells_stress", "@cells_stress = external global i64")
  sym_decls.set("@gc_grown_since", "@gc_grown_since = external global i64")
  sym_decls.set("@gc_due_at", "@gc_due_at = external global i64")
  sym_decls.set("@cells_kind_of", "@cells_kind_of = external global [64 x i8]")
  let g_since = uref("@cells_since")
  let g_thr = uref("@cells_threshold")
  let g_stress = uref("@cells_stress")
  let g_grown = uref("@gc_grown_since")
  let g_due = uref("@gc_due_at")
  let g_kof = uref("@cells_kind_of")
  let h = vals[0]
  let nz = zs.length()
  let la = self.l()
  let lb = self.l()
  let lc = self.l()
  let lslow = self.l()
  let lj = self.l()
  let t = fn(s : String) {
    let v = self.t()
    self.e(v + " = " + s)
    v
  }
  let hl = t("and i64 " + h + ", 65535")
  let okh = t("icmp eq i64 " + hl + ", 258")
  self.e("br i1 " + okh + ", label %" + la + ", label %" + lslow)
  self.block(la)
  let cs = t("load i64, ptr " + g_since)
  let ct = t("load i64, ptr " + g_thr)
  let d1 = t("icmp sge i64 " + cs + ", " + ct)
  let gg = t("load i64, ptr " + g_grown)
  let gd = t("load i64, ptr " + g_due)
  let d2 = t("icmp ugt i64 " + gg + ", " + gd)
  let st = t("load i64, ptr " + g_stress)
  let d3 = t("icmp sgt i64 " + st + ", 0")
  let d12 = t("or i1 " + d1 + ", " + d2)
  let due = t("or i1 " + d12 + ", " + d3)
  self.e("br i1 " + due + ", label %" + lslow + ", label %" + lb)
  self.block(lb)
  let gp = t("getelementptr inbounds i8, ptr @tstc_store0, i64 40")
  let g = t("load ptr, ptr " + gp)
  let cur = t("load i64, ptr " + g)
  let endp = t("getelementptr inbounds i8, ptr " + g + ", i64 8")
  let end = t("load i64, ptr " + endp)
  let nc = t("add i64 " + cur + ", \{nz}")
  let fits = t("icmp sle i64 " + nc + ", " + end)
  self.e("br i1 " + fits + ", label %" + lc + ", label %" + lslow)
  self.block(lc)
  self.e("store i64 " + nc + ", ptr " + g)
  // (set_start)
  let spp = t("getelementptr inbounds i8, ptr " + g + ", i64 16")
  let sp = t("load ptr, ptr " + spp)
  let wi = t("lshr i64 " + cur + ", 6")
  let wp = t("getelementptr inbounds i64, ptr " + sp + ", i64 " + wi)
  let w = t("load i64, ptr " + wp)
  let bi = t("and i64 " + cur + ", 63")
  let bit = t("shl i64 1, " + bi)
  let w2 = t("or i64 " + w + ", " + bit)
  self.e("store i64 " + w2 + ", ptr " + wp)
  let l1pp = t("getelementptr inbounds i8, ptr " + g + ", i64 24")
  let l1p = t("load ptr, ptr " + l1pp)
  let li = t("lshr i64 " + cur + ", 12")
  let lwp = t("getelementptr inbounds i64, ptr " + l1p + ", i64 " + li)
  let lw = t("load i64, ptr " + lwp)
  let lb6 = t("and i64 " + wi + ", 63")
  let lbit = t("shl i64 1, " + lb6)
  let lw2 = t("or i64 " + lw + ", " + lbit)
  self.e("store i64 " + lw2 + ", ptr " + lwp)
  // (the kinds, two bits a cell: cells_kind_of of each zero value's kind)
  let mut kb = "0"
  for i in 0..<nz {
    let kp = t("getelementptr inbounds [64 x i8], ptr " + g_kof + ", i64 0, i64 \{zs[i].1}")
    let k8 = t("load i8, ptr " + kp)
    let k64 = t("zext i8 " + k8 + " to i64")
    let ks = if i == 0 { k64 } else { t("shl i64 " + k64 + ", \{2 * i}") }
    kb = if i == 0 { ks } else { t("or i64 " + kb + ", " + ks) }
  }
  let mask = if nz >= 32 { -1L } else { (1L << (2 * nz)) - 1L }
  let kpp = t("getelementptr inbounds i8, ptr " + g + ", i64 48")
  let kpt = t("load ptr, ptr " + kpp)
  let ki = t("lshr i64 " + cur + ", 5")
  let kwp = t("getelementptr inbounds i64, ptr " + kpt + ", i64 " + ki)
  let c31 = t("and i64 " + cur + ", 31")
  let sh = t("shl i64 " + c31 + ", 1")
  let kw = t("load i64, ptr " + kwp)
  let m0 = t("shl i64 \{mask}, " + sh)
  let nm0 = t("xor i64 " + m0 + ", -1")
  let kw1 = t("and i64 " + kw + ", " + nm0)
  let kbs = t("shl i64 " + kb + ", " + sh)
  let kw2 = t("or i64 " + kw1 + ", " + kbs)
  self.e("store i64 " + kw2 + ", ptr " + kwp)
  if nz > 1 {
    // (into the next word too)
    let top = t("add i64 " + sh + ", \{2 * nz}")
    let cross = t("icmp ugt i64 " + top + ", 64")
    let lx = self.l()
    let ly = self.l()
    self.e("br i1 " + cross + ", label %" + lx + ", label %" + ly)
    self.block(lx)
    let rs = t("sub i64 64, " + sh)
    let kwp1 = t("getelementptr inbounds i64, ptr " + kwp + ", i64 1")
    let kx = t("load i64, ptr " + kwp1)
    let m1 = t("lshr i64 \{mask}, " + rs)
    let nm1 = t("xor i64 " + m1 + ", -1")
    let kx1 = t("and i64 " + kx + ", " + nm1)
    let kbr = t("lshr i64 " + kb + ", " + rs)
    let kx2 = t("or i64 " + kx1 + ", " + kbr)
    self.e("store i64 " + kx2 + ", ptr " + kwp1)
    self.br(ly)
    self.block(ly)
  }
  // the zero values
  let cpp = t("getelementptr inbounds i8, ptr @tstc_store0, i64 8")
  let cells = t("load ptr, ptr " + cpp)
  for i in 0..<nz {
    let ix = if i == 0 { cur } else { t("add i64 " + cur + ", \{i}") }
    let ap = t("getelementptr i64, ptr " + cells + ", i64 " + ix)
    self.e("store i64 " + zs[i].0 + ", ptr " + ap)
  }
  // a write: the next version; cells_since
  let vp = t("getelementptr inbounds i8, ptr @tstc_store0, i64 32")
  let ver = t("load i64, ptr " + vp)
  let ver1 = t("add i64 " + ver + ", 1")
  self.e("store i64 " + ver1 + ", ptr " + vp)
  let cs2 = t("load i64, ptr " + g_since)
  let cs3 = t("add i64 " + cs2 + ", \{nz}")
  self.e("store i64 " + cs3 + ", ptr " + g_since)
  let h1 = t("add i64 " + h + ", 65536")
  let pv0 = t("shl i64 " + cur + ", 1")
  let pv = t("or i64 " + pv0 + ", 1")
  let lfast_end = self.cur
  self.br(lj)
  self.block(lslow)
  self.slow += 1
  declare("@n_halloc", pair_ty + " @n_halloc(i64, i64, i64)")
  let c = t("call " + pair_ty + " @n_halloc(" + args_list(vals) + ")")
  self.slow -= 1
  let sa = t("extractvalue " + pair_ty + " " + c + ", 0")
  let sb = t("extractvalue " + pair_ty + " " + c + ", 1")
  let lslow_end = self.cur
  self.br(lj)
  self.block(lj)
  let ra = t("phi i64 [ " + h1 + ", %" + lfast_end + " ], [ " + sa + ", %" + lslow_end + " ]")
  let rb = t("phi i64 [ " + pv + ", %" + lfast_end + " ], [ " + sb + ", %" + lslow_end + " ]")
  lazy_pair(ra, rb)
}

// --native-fast: natives with an inline fast path (the prelude's
// tstc_<name>, which calls the native for everything else). On by default at
// -O 1 to 3 (intersectionConstructorReductionCrash: -O 1 162 s, with them
// 120 s); off at -O f and -O s, whose back end (llc -O0) makes them cost
// cycles (intersectionMini20: 12% fewer instructions, 26% more cycles than
// calls of the natives)
let native_fast_on : Ref[Bool] = Ref::new(false)

// --native-fast 1, --no-native-fast -1, else 0 (by -O)
let native_fast_set : Ref[Int] = Ref::new(0)

// --native-fast-only a,b: those natives' inline fast paths only
let native_fast_only : Array[String] = []

// --no-dispatch-tree: dispatch switches stay switches
let dispatch_tree_on : Ref[Bool] = Ref::new(true)

fn inline_native(name : String, nargs : Int) -> String? {
  // (a comparison and a branch: cheaper than the call in any case)
  if name == "nilchk" && nargs == 1 {
    return Some("@tstc_nilchk")
  }
  if !native_fast_on.val && !native_fast_only.contains(name) {
    return None
  }
  match (name, nargs) {
    ("tget", 2) | ("geq", 2) | ("gne", 2) | ("sidx", 3) | ("ta1", 2) | ("nilchk", 1) | ("slen", 1) | ("sat", 2) =>
      Some("@tstc_" + name)
    ("fadd", 2) | ("fsub", 2) | ("fmul", 2) | ("fdiv", 2) | ("feq", 2) | ("fne", 2) | ("flt", 2) | ("fle", 2) =>
      Some("@tstc_" + name)
    ("fneg", 1) | ("ffloor", 1) | ("i2f", 1) | ("f2i", 1) | ("isnan", 1) => Some("@tstc_" + name)
    ("hget", 2) | ("hset", 3) | ("hgetf", 3) | ("hgets", 4) | ("hsets", 5) =>
      if store_in_place() { Some("@tstc_" + name) } else { None }
    _ => None
  }
}

// the inline natives a fast copy has (their helpers spliced in, splice);
// the others change the cells
let spec_natives : Array[String] = [
  "tget", "geq", "gne", "sidx", "ta1", "nilchk", "hget", "hgetf", "hgets", "slen", "sat", "fadd", "fsub",
  "fmul", "fdiv", "feq", "fne", "flt", "fle", "fneg", "ffloor", "i2f", "f2i", "isnan",
]

// a helper of the prelude: its parameters and the lines of its body
let helper_texts : Map[String, (Array[String], Array[String])] = Map::new()

fn helper_text(name : String) -> (Array[String], Array[String]) {
  match helper_texts.get(name) {
    Some(h) => return h
    None => ()
  }
  // (its definition: other helpers call it too)
  let head = " @tstc_" + name + "("
  let start = match llvm_prelude.find("define internal i64" + head) {
    Some(i) => i + "define internal i64".length() + head.length()
    None =>
      match llvm_prelude.find("define internal " + pair_ty + head) {
        Some(i) => i + ("define internal " + pair_ty).length() + head.length()
        None => abort("no helper " + name)
      }
  }
  let rest = llvm_prelude.unsafe_substring(start~, end=llvm_prelude.length())
  let close = rest.find(")").unwrap()
  let params = rest
    .unsafe_substring(start=0, end=close)
    .split(", ")
    .map(fn(p) {
      let p = p.to_string()
      match p.rev_find("%") {
        Some(i) => p.unsafe_substring(start=i + 1, end=p.length())
        None => abort("helper parameter " + p)
      }
    })
    .collect()
  let body_start = rest.find("{\n").unwrap() + 2
  let body_end = rest.find("\n}\n").unwrap()
  let lines = rest
    .unsafe_substring(start=body_start, end=body_end)
    .split("\n")
    .map(fn(l) { l.to_string() })
    .collect()
  let h = (params, lines)
  helper_texts.set(name, h)
  h
}

// a local name's character
fn local_char(c : Int) -> Bool {
  (c >= 'a'.to_int() && c <= 'z'.to_int()) || (c >= 'A'.to_int() && c <= 'Z'.to_int()) ||
  (c >= '0'.to_int() && c <= '9'.to_int()) ||
  c == '_'.to_int() ||
  c == '.'.to_int()
}

// (a fast copy) the prelude's helper tstc_<name> in this function, with the
// function itself where it would call the native: the checks of its inline
// path branch out of the copy, so what follows them knows they held (a
// second access to the same tuple loads nothing again). Its value
fn Fun::splice(self : Fun, name : String, args : Array[String]) -> String {
  let (params, lines) = helper_text(name)
  self.lbl += 1
  let sfx = ".h\{self.lbl}"
  let rename = fn(line : String) -> String {
    let sb = StringBuilder::new()
    let n = line.length()
    let mut i = 0
    while i < n {
      let c = line.unsafe_charcode_at(i)
      if c == '%'.to_int() {
        let st = i + 1
        let mut j = st
        while j < n && local_char(line.unsafe_charcode_at(j)) {
          j += 1
        }
        let id = line.unsafe_substring(start=st, end=j)
        let mut k = -1
        for q in 0..<params.length() {
          if params[q] == id {
            k = q
          }
        }
        if k >= 0 {
          sb.write_string(args[k])
        } else {
          sb.write_string("%" + id + sfx)
        }
        i = j
      } else {
        sb.write_char(Int::unsafe_to_char(c))
        i += 1
      }
    }
    sb.to_string()
  }
  let lcont = self.l()
  self.br("entry" + sfx)
  let mut result = ""
  let mut in_slow = false
  for line in lines {
    let t = line.trim(" ").to_string()
    if t.has_suffix(":") && !t.has_prefix(";") {
      let lbl = t.unsafe_substring(start=0, end=t.length() - 1)
      in_slow = lbl == "slow"
      self.block(lbl + sfx)
      if in_slow {
        self.bail()
        self.e("unreachable")
      }
      continue
    }
    if in_slow || t.length() == 0 || t.has_prefix(";") {
      continue
    }
    if t.has_prefix("ret ") {
      if result != "" {
        abort("helper with two results: " + name)
      }
      let r = rename(t)
      result = match r.rev_find(" ") {
        Some(i) => r.unsafe_substring(start=i + 1, end=r.length())
        None => abort("helper result " + t)
      }
      self.br(lcont)
      continue
    }
    self.e(rename(t))
  }
  self.block(lcont)
  result
}

// a call of a native: a pair for those returning two results
fn Fun::native_call(self : Fun, id : Int, sym : String, vals : Array[String]) -> String {
  if native_returns_pair(id) {
    let sig = native_sig(sym, vals.length())
    declare("@" + sym, pair_ty + sig.unsafe_substring(start=3, end=sig.length()))
    self.call_pair("@" + sym + "(" + args_list(vals) + ")")
  } else {
    self.rtcall(sym, native_sig(sym, vals.length()), args_list(vals))
  }
}

// the integer an operand is, when it is a constant immediate
fn const_int(s : String) -> Int64? {
  if s.length() == 0 || s.has_prefix("%") || s.has_prefix("ptrtoint") {
    return None
  }
  match (try? @strconv.parse_int64(s)) {
    Ok(v) => if (v & 1L) == 1L { Some(v >> 1) } else { None }
    Err(_) => None
  }
}

// integer operations on two immediate integers (bit 0 set: 2x + 1) inline;
// the runtime handles the others and overflow
fn Fun::gen_int_op(self : Fun, name : String, a : String, b : String, sym : String) -> String? {
  let kind = match name {
    // padd: a pointer is a cell index, an integer (the runtime reports others)
    "iadd" | "isub" | "imul" | "padd" => 1
    "ilt" | "ile" | "igt" | "ige" | "ieq" | "ine" => 2
    "iand" | "ior" | "ixor" => 3
    _ => 0
  }
  if kind == 0 {
    return None
  }
  // both constant immediates: folded
  match (const_int(a), const_int(b)) {
    (Some(x), Some(y)) => {
      let r : Int64? = match name {
        "iadd" | "padd" => Some(x + y)
        "isub" => Some(x - y)
        "imul" => Some(x * y)
        "iand" => Some(x & y)
        "ior" => Some(x | y)
        "ixor" => Some(x ^ y)
        _ => None
      }
      match r {
        Some(v) =>
          // the immediate range: what does not fit goes to the runtime
          if v >= -4611686018427387904L && v < 4611686018427387904L &&
            (name != "imul" || x == 0L || (v / x == y && v % x == 0L)) &&
            ((name != "iadd" && name != "padd") || ((x >= 0L) != (y >= 0L) || (v >= 0L) == (x >= 0L))) &&
            (name != "isub" || ((x >= 0L) == (y >= 0L) || (v >= 0L) == (x >= 0L))) {
            return Some((v * 2L + 1L).to_string())
          }
        None => {
          let c = match name {
            "ilt" => x < y
            "ile" => x <= y
            "igt" => x > y
            "ige" => x >= y
            "ieq" => x == y
            _ => x != y
          }
          return Some(if c { v_true } else { v_false })
        }
      }
    }
    _ => ()
  }
  // both known immediates: comparisons and bitwise operations are the
  // machine's, no runtime path
  if self.is_int(a) && self.is_int(b) && (kind == 2 || kind == 3) {
    let r = self.t()
    if kind == 2 {
      let cmp = match name {
        "ilt" => "slt"
        "ile" => "sle"
        "igt" => "sgt"
        "ige" => "sge"
        "ieq" => "eq"
        _ => "ne"
      }
      let c = self.t()
      self.e(c + " = icmp " + cmp + " i64 " + a + ", " + b)
      self.e(r + " = select i1 " + c + ", i64 " + v_true + ", i64 " + v_false)
      self.bool_i1.set(r, c)
    } else {
      match name {
        "iand" => self.e(r + " = and i64 " + a + ", " + b)
        "ior" => self.e(r + " = or i64 " + a + ", " + b)
        _ => {
          let x = self.t()
          self.e(x + " = xor i64 " + a + ", " + b)
          self.e(r + " = or i64 " + x + ", 1")
        }
      }
      self.int_vals.set(r, true)
    }
    return Some(r)
  }
  let both = self.t()
  self.e(both + " = and i64 " + a + ", " + b)
  // (kind 1 but padd tests both without overflow, as an integer)
  let bit = if kind == 1 && name != "padd" {
    ""
  } else {
    let x = self.t()
    self.e(x + " = trunc i64 " + both + " to i1")
    x
  }
  // the result as if both were immediates, computed first (harmless
  // otherwise): one branch to the runtime, which llc -O0 spills least around
  let lslow = self.l()
  let lj = self.l()
  let lentry = self.cur
  let mut r = self.t()
  let mut ok = bit
  let mut cmp_i1 : String? = None
  match kind {
    1 if name == "padd" => {
      // a cell index stays far from the immediate range's ends: no overflow
      let rhs = match const_int(b) {
        Some(y) => (y * 2L).to_string()
        None => {
          let x = self.t()
          self.e(x + " = sub i64 " + b + ", 1")
          x
        }
      }
      self.e(r + " = add i64 " + a + ", " + rhs)
    }
    1 => {
      let (op, rhs) = match name {
        "iadd" | "padd" => ("sadd", self.t())
        "isub" => ("ssub", self.t())
        _ => ("smul", self.t())
      }
      let lhs = if op == "smul" {
        let x = self.t()
        self.e(x + " = ashr i64 " + a + ", 1")
        x
      } else {
        a
      }
      // (b - 1: an immediate's 2y)
      let rhs = match const_int(b) {
        Some(y) => (y * 2L).to_string()
        None => {
          self.e(rhs + " = sub i64 " + b + ", 1")
          rhs
        }
      }
      let ov = self.t()
      self.e(ov + " = call { i64, i1 } @llvm." + op + ".with.overflow.i64(i64 " + lhs + ", i64 " + rhs + ")")
      let raw = self.t()
      self.e(raw + " = extractvalue { i64, i1 } " + ov + ", 0")
      let o = self.t()
      self.e(o + " = extractvalue { i64, i1 } " + ov + ", 1")
      if op == "smul" {
        self.e(r + " = or i64 " + raw + ", 1")
      } else {
        r = raw
      }
      // both immediates and no overflow, as one integer test (the fast back
      // end splits a branch on an i1 `and` into two)
      let ow = self.t()
      self.e(ow + " = zext i1 " + o + " to i64")
      let nov = self.t()
      self.e(nov + " = xor i64 " + ow + ", 1")
      let okw = self.t()
      self.e(okw + " = and i64 " + both + ", " + nov)
      let ok2 = self.t()
      self.e(ok2 + " = icmp ne i64 " + okw + ", 0")
      ok = ok2
    }
    2 => {
      let cmp = match name {
        "ilt" => "slt"
        "ile" => "sle"
        "igt" => "sgt"
        "ige" => "sge"
        "ieq" => "eq"
        _ => "ne"
      }
      let c = self.t()
      self.e(c + " = icmp " + cmp + " i64 " + a + ", " + b)
      self.e(r + " = select i1 " + c + ", i64 " + v_true + ", i64 " + v_false)
      cmp_i1 = Some(c)
    }
    _ => {
      let op = match name {
        "iand" => "and"
        "ior" => "or"
        _ => "xor"
      }
      if op == "xor" {
        let x = self.t()
        self.e(x + " = xor i64 " + a + ", " + b)
        self.e(r + " = or i64 " + x + ", 1")
      } else {
        self.e(r + " = " + op + " i64 " + a + ", " + b)
      }
    }
  }
  // (the comparison's i1: r is select c, true, false)
  let ci = cmp_i1
  self.e("br i1 " + ok + ", label %" + lj + ", label %" + lslow)
  self.block(lslow)
  self.slow += 1
  let rs = self.rtcall(sym, native_sig(sym, 2), args_list([a, b]))
  self.slow -= 1
  let cs = match ci {
    Some(_) => {
      let x = self.t()
      self.e(x + " = icmp eq i64 " + rs + ", " + v_true)
      Some(x)
    }
    None => None
  }
  let lslow_end = self.cur
  self.br(lj)
  self.block(lj)
  let v = self.t()
  self.e(v + " = phi i64 [ " + r + ", %" + lentry + " ], [ " + rs + ", %" + lslow_end + " ]")
  match (ci, cs) {
    (Some(c), Some(x)) => {
      let bv = self.t()
      self.e(bv + " = phi i1 [ " + c + ", %" + lentry + " ], [ " + x + ", %" + lslow_end + " ]")
      self.bool_i1.set(v, bv)
    }
    _ => ()
  }
  // results that are always immediates: a pointer moved (the runtime raises
  // for anything else), and bits of a non-negative constant
  let nonneg_const = fn(x : String) { match const_int(x) { Some(k) => k >= 0L; None => false } }
  if name == "padd" || (name == "iand" && (nonneg_const(a) || nonneg_const(b))) {
    self.int_vals.set(v, true)
  }
  Some(v)
}

// a plain tuple of constants is static data (0: the element is not constant)
fn const_operand(c : Code) -> String? {
  match c {
    CTy(t) => Some(ty_const(t))
    CTuple(elems, false) => {
      let vals : Array[String] = []
      for el in elems {
        if el.kind != 0 || el.name is Some(_) {
          return None
        }
        match const_operand(el.code) {
          Some(v) => vals.push(v)
          None => return None
        }
      }
      if vals.is_empty() {
        return None
      }
      Some(static_tuple(vals))
    }
    _ => None
  }
}

fn static_tuple(vals : Array[String]) -> String {
  let e = i64_array(vals)
  ptr_val(
    intern(
      " = hidden global { i32, i32, ptr, ptr } { i32 20, i32 \{vals.length()}, ptr " + e +
      ", ptr null }, align 8\n",
    ),
  )
}

fn Fun::gen_tuple(self : Fun, elems : Array[CElem], ro : Bool, tail : Bool) -> String? {
  match const_operand(CTuple(elems, ro)) {
    Some(v) => return self.finish(v, tail)
    None => ()
  }
  let mut plain = !ro
  let mut named = false
  for el in elems {
    if el.kind != 0 || el.name is Some(_) {
      plain = false
    }
    if el.name is Some(_) {
      named = true
    }
  }
  // a big tuple of mostly constants: a static template, patched
  if plain && elems.length() >= 16 {
    let consts = elems.map(fn(el) { const_operand(el.code) })
    let mut nconst = 0
    for c in consts {
      if c is Some(_) {
        nconst += 1
      }
    }
    if nconst * 2 >= elems.length() {
      let tpl : Array[String] = []
      let pairs : Array[String] = []
      for j in 0..<elems.length() {
        match consts[j] {
          Some(v) => tpl.push(v)
          None => {
            tpl.push("0")
            pairs.push(j.to_string())
            pairs.push(self.gen_v(elems[j].code))
          }
        }
      }
      let t = static_tuple(tpl)
      let p = self.scratch_of(pairs)
      let v = self.rtcall(
        "rt_tuple_patch",
        "i64 @rt_tuple_patch(i64, ptr nocapture readonly, i64)",
        "i64 " + t + ", ptr " + p + ", i64 \{pairs.length() / 2}",
      )
      return self.finish(v, tail)
    }
  }
  let vals = elems.map(fn(el) { self.gen_v(el.code) })
  if plain {
    if vals.is_empty() {
      let v = self.rtcall("rt_empty_tuple", "i64 @rt_empty_tuple()", "")
      return self.finish(v, tail)
    }
    if vals.length() == 2 {
      // allocated only when something needs it as a value
      return self.finish(lazy_pair(vals[0], vals[1]), tail)
    }
    if vals.length() == 1 {
      return self.finish(lazy_pair(vals[0], pair_one), tail)
    }
    let p = self.scratch_of(vals)
    let v = self.rtcall(
      "rt_tuplev",
      "i64 @rt_tuplev(ptr nocapture readonly, i64)",
      "ptr " + p + ", i64 \{vals.length()}",
    )
    return self.finish(v, tail)
  }
  let kinds = i64_array(elems.map(fn(el) { el.kind.to_string() }))
  let names = if named {
    ptr_array(
      elems.map(fn(el) {
        match el.name {
          Some(s) => str_global(s)
          None => "null"
        }
      }),
    )
  } else {
    "null"
  }
  let d = struct_global(
    [ival(elems.length()), pval(kinds), pval(names), ival(if ro { 1 } else { 0 })],
    false,
  )
  let p = self.scratch_of(vals)
  let v = self.rtcall(
    "rt_tupled",
    "i64 @rt_tupled(ptr, ptr nocapture readonly)",
    "ptr " + d + ", ptr " + p,
  )
  self.finish(v, tail)
}

// `{ a: X, b: Y }[K]`: only the selected property is evaluated (by the
// function the object type's descriptor has for it)
fn Fun::gen_dispatch(self : Fun, oc : ObjCode, k : Code, tail : Bool) -> String? {
  let kv = match k {
    // `{ ... }[`${K}`]` (go2types: an index TypeScript accepts for a bigint
    // K): the integer itself finds the property its text names
    CTpl(texts, cs) if cs.length() == 1 && texts.length() == 2 && texts[0].len == 0 && texts[1].len == 0 &&
      (match cs[0] {
        CSlot(_) => self.tpl_keys.get(self.gen_v(cs[0])) is Some(_)
        _ => false
      }) => self.tpl_keys.get(self.gen_v(cs[0])).unwrap()
    CTpl(texts, cs) if cs.length() == 1 && texts.length() == 2 && texts[0].len == 0 && texts[1].len == 0 => {
      let xv = self.gen_v(cs[0])
      // (an integer is its own key)
      let isi = self.t()
      self.e(isi + " = and i64 " + xv + ", 1")
      let isb = self.t()
      self.e(isb + " = icmp ne i64 " + isi + ", 0")
      let lki = self.l()
      let lkg = self.l()
      let lkj = self.l()
      self.e("br i1 " + isb + ", label %" + lki + ", label %" + lkg)
      self.block(lkg)
      self.slow += 1
      let kg = self.rtcall("rt_tpl_key", "i64 @rt_tpl_key(i64)", "i64 " + xv)
      self.slow -= 1
      let lkg_end = self.cur
      self.br(lkj)
      self.block(lki)
      self.br(lkj)
      self.block(lkj)
      let kv = self.t()
      self.e(kv + " = phi i64 [ " + xv + ", %" + lki + " ], [ " + kg + ", %" + lkg_end + " ]")
      kv
    }
    _ => self.gen_v(k)
  }
  let names = ptr_array(oc.props.map(fn(p) { str_global(p.0) }))
  // n, names, then the runtime's lookup tables (by name, by integer key)
  let tbl = struct_global(
    [ival(oc.props.length()), pval(names), ival(0), pval("null"), ival(0), pval("null"), pval("null")],
    true,
  )
  let ldef = self.l()
  let lmiss = self.l()
  let use_ic = dispatch_ic_on.val && oc.props.length() >= 4
  // (through the jump table: properties of a kind share a block)
  let groups = if use_ic { prop_groups(oc) } else { [] }
  let group_of : Array[Int] = Array::make(oc.props.length(), -1)
  let glabels = groups.map(fn(_g) { self.l() })
  for g in 0..<groups.length() {
    for j in groups[g].members {
      group_of[j] = g
    }
  }
  let labels = Array::makei(oc.props.length(), fn(j) {
    if group_of[j] >= 0 {
      glabels[group_of[j]]
    } else {
      self.l()
    }
  })
  let idx = if use_ic {
    self.dispatch_ic(kv, tbl, ldef, lmiss, labels, oc.id)
  } else {
    self.dispatch_tree(oc, kv, tbl, ldef, lmiss, labels)
    ""
  }
  let results : Array[(String, String)] = []
  let lj = self.l()
  let m = self.mark()
  for g in 0..<groups.length() {
    self.undo(m)
    self.block(glabels[g])
    self.arm(self.gen_prop_group(oc, groups[g], idx, tail), results, lj)
  }
  for j in 0..<labels.length() {
    if group_of[j] >= 0 {
      continue
    }
    self.undo(m)
    self.block(labels[j])
    let p = oc.props[j]
    // a call (go2types' method and closure tables) is made here: in tail
    // position a jump to the callee, not a call of a function for the
    // property that calls it
    let small = match p.1 {
      CTy(_) | CSlot(_) | CCall(_, _) | CNative(_, _, _) => true
      _ => false
    }
    if p.2 {
      let v = if small { self.gen_v(p.1) } else { self.gen_v_here(prop_fn(oc, j, self.frame), p.1) }
      let r = self.rtcall(
        "rt_union2",
        "i64 @rt_union2(i64, i64)",
        "i64 " + v + ", i64 " + ty_const(TUndefined),
      )
      self.arm(self.finish(r, tail), results, lj)
    } else if small {
      self.arm(self.gen(p.1, tail), results, lj)
    } else {
      // (here, unless this function is large already)
      self.arm(self.gen_split(p.1, tail), results, lj)
    }
  }
  // no such property: the index signature, or the general case
  self.undo(m)
  self.block(lmiss)
  self.slow += 1
  if oc.index.length() == 1 {
    let ix = code_fn(oc.index[0].1, self.frame, "o" + oc.id.to_string() + "ix")
    self.arm(self.call_here(ix, tail, oc.index[0].1), results, lj)
  } else {
    self.br(ldef)
  }
  self.undo(m)
  self.block(ldef)
  if self.spec is Some(_) {
    // (nothing of the function's frame for the runtime's object)
    self.bail()
    self.slow -= 1
    self.arm(self.finish(self.dead(), tail), results, lj)
    return self.join(results, lj, tail)
  }
  let d = obj_desc_of(oc, self.frame, use_ic)
  let o = self.rtcall_env("rt_obj", "i64 @rt_obj(ptr, ptr nocapture)", "ptr " + d + ", ptr %env", CObj(oc))
  let r = self.rtcall("rt_index", "i64 @rt_index(i64, i64)", "i64 " + o + ", i64 " + kv)
  self.slow -= 1
  self.arm(self.finish(r, tail), results, lj)
  self.join(results, lj, tail)
}

// --no-dispatch-ic: dispatch by comparisons (dispatch_tree)
let dispatch_ic_on : Ref[Bool] = Ref::new(true)

// `{ ... }[K]` dispatch through an inline cache: the last integer key of the
// site and the index it found; else the runtime's lookup (rt_dispatch),
// remembered for integer keys (other keys' objects may not live). The index
// (-2 no name, -1 none, 0.. the property) goes through a jump table: llc -O0
// has no jump tables of its own (a switch is a chain of comparisons).
fn Fun::dispatch_ic(
  self : Fun,
  kv : String,
  tbl : String,
  ldef : String,
  lmiss : String,
  labels : Array[String],
  site : Int,
) -> String {
  let mut n = 0
  while self.ics.contains("\{site}#\{n}#") {
    n += 1
  }
  let key = "\{site}#\{n}"
  let ic = match self.ics.get(key) {
    Some(g) => g
    None => {
      let g = struct_global([ival(0), ival(-2)], true)
      self.ics.set(key, g)
      g
    }
  }
  // (taken: the next occurrence has the next)
  self.ics.set(key + "#", ic)
  let ck = self.t()
  self.e(ck + " = load i64, ptr " + ic)
  let hit = self.t()
  self.e(hit + " = icmp eq i64 " + kv + ", " + ck)
  let lhit = self.l()
  let lfind = self.l()
  let lstore = self.l()
  let ljt = self.l()
  self.e("br i1 " + hit + ", label %" + lhit + ", label %" + lfind)
  self.block(lhit)
  let ip = self.t()
  self.e(ip + " = getelementptr inbounds i64, ptr " + ic + ", i64 1")
  let ci = self.t()
  self.e(ci + " = load i64, ptr " + ip)
  self.br(ljt)
  self.block(lfind)
  self.slow += 1
  let i = self.rtcall("rt_dispatch", "i64 @rt_dispatch(i64, ptr)", "i64 " + kv + ", ptr " + tbl)
  self.slow -= 1
  let lfind_end = self.cur
  let isi = self.t()
  self.e(isi + " = trunc i64 " + kv + " to i1")
  self.e("br i1 " + isi + ", label %" + lstore + ", label %" + ljt)
  self.block(lstore)
  self.e("store i64 " + kv + ", ptr " + ic)
  let ip2 = self.t()
  self.e(ip2 + " = getelementptr inbounds i64, ptr " + ic + ", i64 1")
  self.e("store i64 " + i + ", ptr " + ip2)
  self.br(ljt)
  self.block(ljt)
  let idx = self.t()
  self.e(idx + " = phi i64 [ " + ci + ", %" + lhit + " ], [ " + i + ", %" + lfind_end + " ], [ " + i + ", %" + lstore + " ]")
  let targets = [ldef, lmiss] + labels
  let u = cu()
  u.nglob += 1
  let jt = "@\"" + u.prefix + ":J" + u.nglob.to_string() + "\""
  self.jts.push((jt, targets))
  let t = self.t()
  self.e(t + " = add i64 " + idx + ", 2")
  let ap = self.t()
  self.e(ap + " = getelementptr inbounds [\{targets.length()} x ptr], ptr " + jt + ", i64 0, i64 " + t)
  let a = self.t()
  self.e(a + " = load ptr, ptr " + ap)
  let sb = StringBuilder::new()
  sb.write_string("indirectbr ptr " + a + ", [")
  let seen : Map[String, Bool] = Map::new()
  for k in 0..<targets.length() {
    if seen.contains(targets[k]) {
      continue
    }
    seen.set(targets[k], true)
    if k > 0 {
      sb.write_string(", ")
    }
    sb.write_string("label %" + targets[k])
  }
  sb.write_string("]")
  self.e(sb.to_string())
  idx
}

// properties of a dispatch that share a block: constants (their values in a
// table), and calls of aliases with the same arguments (the callees and
// their frames in tables: one call through a pointer)
struct PropGroup {
  // the arguments of the calls (None: constants)
  args : Array[Code]?
  members : Array[Int]
}

fn prop_groups(oc : ObjCode) -> Array[PropGroup] {
  let consts : Array[Int] = []
  let by_args : Map[String, Int] = Map::new()
  let calls : Array[PropGroup] = []
  for j in 0..<oc.props.length() {
    let p = oc.props[j]
    if p.2 {
      continue
    }
    match p.1 {
      CTy(_) => consts.push(j)
      CTuple(_, _) if const_operand(p.1) is Some(_) => consts.push(j)
      CCall(idx, args) => {
        let a = aliases[idx]
        if a.native >= 0 || a.nparams == 0 || args.length() != a.nparams {
          continue
        }
        let h = Hasher::new()
        h.codes(args)
        let key = h.hex()
        match by_args.get(key) {
          Some(g) => calls[g].members.push(j)
          None => {
            by_args.set(key, calls.length())
            calls.push({ args: Some(args), members: [j] })
          }
        }
      }
      _ => ()
    }
  }
  let out : Array[PropGroup] = []
  if consts.length() >= 2 {
    out.push({ args: None, members: consts })
  }
  for g in calls {
    if g.members.length() >= 2 {
      out.push(g)
    }
  }
  out
}

// the block of a group: the property's index is idx
fn Fun::gen_prop_group(self : Fun, oc : ObjCode, g : PropGroup, idx : String, tail : Bool) -> String? {
  let n = oc.props.length()
  match g.args {
    None => {
      let vals = Array::make(n, "0")
      for j in g.members {
        match const_operand(oc.props[j].1) {
          Some(v) => vals[j] = v
          None => ()
        }
      }
      let tb = i64_array(vals)
      let p = self.t()
      self.e(p + " = getelementptr inbounds [\{n} x i64], ptr " + tb + ", i64 0, i64 " + idx)
      let v = self.t()
      self.e(v + " = load i64, ptr " + p)
      self.finish(v, tail)
    }
    Some(args) => {
      let fns = Array::make(n, "null")
      for j in g.members {
        match oc.props[j].1 {
          CCall(ai, _) => fns[j] = alias_fn(ai)
          _ => ()
        }
      }
      let ft = ptr_array(fns)
      let vals = self.gen_all(args)
      let pf = self.t()
      self.e(pf + " = getelementptr inbounds [\{n} x ptr], ptr " + ft + ", i64 0, i64 " + idx)
      let fp = self.t()
      self.e(fp + " = load ptr, ptr " + pf)
      self.call_frame_dyn(fp, vals, tail)
    }
  }
}

// call_frame with the callee in a register
fn Fun::call_frame_dyn(self : Fun, fp : String, vals : Array[String], tail : Bool) -> String? {
  if tail && self.tail_ok {
    let base = self.tail_base()
    self.store_args(base, vals)
    let r = self.t()
    self.e(r + " = musttail call " + pair_ty + " " + fp + "(" + reg_call_args(base, vals) + ")")
    self.e("ret " + pair_ty + " " + r)
    if !self.in_dead {
      self.commits += 1
    }
    return None
  }
  if self.spec is Some(_) {
    return self.finish(self.call_pair(""), tail)
  }
  let t0 = self.top_ptr()
  self.store_args(t0, vals)
  let r = self.call_pair(fp + "(" + reg_call_args(t0, vals) + ")")
  self.restore_top(t0)
  self.finish(r, tail)
}

// dispatch by comparisons: properties named by integers' text are switched
// on with an integer key (in rt_dispatch's range of them, |v| < 10^17, the
// last property of a name is the one); the others through rt_dispatch
fn Fun::dispatch_tree(
  self : Fun,
  oc : ObjCode,
  kv : String,
  tbl : String,
  ldef : String,
  lmiss : String,
  labels : Array[String],
) -> Unit {
  let int_cases : Map[Int64, Int] = Map::new()
  for j in 0..<oc.props.length() {
    match canonical_int_name(oc.props[j].0) {
      Some(v) => int_cases.set(v, j)
      None => ()
    }
  }
  if !int_cases.is_empty() {
    let isi = self.t()
    self.e(isi + " = and i64 " + kv + ", 1")
    let isb = self.t()
    self.e(isb + " = icmp ne i64 " + isi + ", 0")
    let lsw = self.l()
    let lrange = self.l()
    let lgen = self.l()
    self.e("br i1 " + isb + ", label %" + lsw + ", label %" + lgen)
    self.block(lsw)
    let cases : Array[(Int64, String)] = []
    int_cases.each(fn(v, j) { cases.push((v * 2L + 1L, labels[j])) })
    self.switch_tree(kv, cases, lrange)
    self.block(lrange)
    let x = self.t()
    self.e(x + " = add i64 " + kv + ", 199999999999999997")
    let inr = self.t()
    self.e(inr + " = icmp ult i64 " + x + ", 399999999999999997")
    self.e("br i1 " + inr + ", label %" + lmiss + ", label %" + lgen)
    self.block(lgen)
  }
  // (on the way of keys that are no integer's text)
  self.slow += if int_cases.is_empty() { 0 } else { 1 }
  let i = self.rtcall("rt_dispatch", "i64 @rt_dispatch(i64, ptr)", "i64 " + kv + ", ptr " + tbl)
  self.slow -= if int_cases.is_empty() { 0 } else { 1 }
  let cases : Array[(Int64, String)] = [(-1L, lmiss)]
  for j in 0..<labels.length() {
    cases.push((j.to_int64(), labels[j]))
  }
  self.switch_tree(i, cases, ldef)
}

// a switch as a balanced tree of comparisons: the fast back end (llc -O0)
// lowers a switch to a chain of them, one per case
fn Fun::switch_tree(self : Fun, v : String, cases : Array[(Int64, String)], dflt : String) -> Unit {
  if cases.length() <= 4 || !dispatch_tree_on.val {
    let sw = StringBuilder::new()
    sw.write_string("switch i64 " + v + ", label %" + dflt + " [")
    for c in cases {
      sw.write_string(" i64 \{c.0}, label %" + c.1)
    }
    sw.write_string(" ]")
    self.e(sw.to_string())
    return
  }
  let sorted = cases.copy()
  sorted.sort_by(fn(a, b) { a.0.compare(b.0) })
  self.switch_range(v, sorted, 0, sorted.length(), dflt)
}

fn Fun::switch_range(self : Fun, v : String, cases : Array[(Int64, String)], lo : Int, hi : Int, dflt : String) -> Unit {
  if hi - lo <= 4 {
    let sw = StringBuilder::new()
    sw.write_string("switch i64 " + v + ", label %" + dflt + " [")
    for k in lo..<hi {
      sw.write_string(" i64 \{cases[k].0}, label %" + cases[k].1)
    }
    sw.write_string(" ]")
    self.e(sw.to_string())
    return
  }
  let mid = (lo + hi) / 2
  let c = self.t()
  self.e(c + " = icmp slt i64 " + v + ", \{cases[mid].0}")
  let ll = self.l()
  let lr = self.l()
  self.e("br i1 " + c + ", label %" + ll + ", label %" + lr)
  self.block(ll)
  self.switch_range(v, cases, lo, mid, dflt)
  self.block(lr)
  self.switch_range(v, cases, mid, hi, dflt)
}

fn Fun::is_int(self : Fun, x : String) -> Bool {
  const_int(x) is Some(_) || self.int_vals.contains(x)
}

// natives whose result is true or false (never never)
let bool_natives : Array[String] = [
  "ilt", "ile", "igt", "ige", "ieq", "ine", "iult", "iule", "iugt", "iuge", "geq", "gne", "flt", "fle",
  "feq", "fne", "bnot", "seq", "slt", "isnan",
]

fn is_bool_code(c : Code, f : Fun) -> Bool {
  match c {
    CNative(_, id, _) => native_is_lib(id) && bool_natives.contains(native_name(id))
    CCall(idx, _) => aliases[idx].native >= 0 && native_is_lib(aliases[idx].native) &&
      bool_natives.contains(native_name(aliases[idx].native))
    CSlot(s) => f.bool_slots.contains(s)
    _ => false
  }
}

// the integer a property name is the canonical text of (rt_dispatch's
// name_int: up to 18 digits, no leading zeros, no "-0")
fn canonical_int_name(s : Str) -> Int64? {
  let n = s.len
  let neg = n > 0 && s.at(0) == '-'.to_int()
  let i0 = if neg { 1 } else { 0 }
  if i0 >= n || n - i0 > 18 {
    return None
  }
  if s.at(i0) == '0'.to_int() && (n - i0 > 1 || neg) {
    return None
  }
  let mut v = 0L
  for i in i0..<n {
    let c = s.at(i)
    if c < '0'.to_int() || c > '9'.to_int() {
      return None
    }
    v = v * 10L + (c - '0'.to_int()).to_int64()
  }
  // (dispatch_int's range)
  if v >= 100000000000000000L {
    return None
  }
  Some(if neg { -v } else { v })
}

fn Fun::gen_v_here(self : Fun, fname : String, reads : Code) -> String {
  match self.call_here(fname, false, reads) {
    Some(v) => self.val(v)
    None => abort("value expected")
  }
}

// whether v is a plain tuple of n elements, and (n > 0) its elements: a call
// of the runtime (inline, the test is some fifteen instructions at each of
// many sites, most of them seldom run)
fn Fun::tuple_check(self : Fun, v : String, n : Int) -> (String, String) {
  if self.spec is Some(_) {
    // (anything else by the function itself)
    let lo = self.t()
    self.e(lo + " = and i64 " + v + ", 3")
    let isp = self.t()
    self.e(isp + " = icmp eq i64 " + lo + ", 0")
    self.bail_unless(isp)
    let tp = self.t()
    self.e(tp + " = inttoptr i64 " + v + " to ptr")
    let hdr = self.t()
    self.e(hdr + " = load i64, ptr " + tp + ", !invariant.load !0")
    let want = self.t()
    self.e(want + " = icmp eq i64 " + hdr + ", " + ((n.to_int64() << 32) | 20L).to_string())
    self.bail_unless(want)
    let xp = self.t()
    self.e(xp + " = getelementptr inbounds i8, ptr " + tp + ", i64 16")
    let x = self.t()
    self.e(x + " = load ptr, ptr " + xp + ", !invariant.load !0")
    let plain = self.t()
    self.e(plain + " = icmp eq ptr " + x + ", null")
    self.bail_unless(plain)
    let ep = self.t()
    self.e(ep + " = getelementptr inbounds i8, ptr " + tp + ", i64 8")
    let el = self.t()
    self.e(el + " = load ptr, ptr " + ep + ", !invariant.load !0")
    return ("true", el)
  }
  let ok = self.t()
  if n == 0 {
    self.e(ok + " = call i1 @tstc_tuplen(i64 " + v + ", i32 0)")
    return (ok, "")
  }
  let f = rt("rt_tuple_elems", "ptr @rt_tuple_elems(i64, i64)")
  let el = self.t()
  self.e(el + " = call ptr " + f + "(i64 " + v + ", i64 \{n})")
  self.e(ok + " = icmp ne ptr " + el + ", null")
  (ok, el)
}

// ---------------------------------------------------------------------------
// Conditionals

fn Fun::gen_cond(self : Fun, cd : Cond, tail : Bool) -> String? {
  let cv = self.gen_v(cd.check)
  let lt = self.l()
  let lf = self.l()
  let ls = self.l()
  match cd.fast {
    1 => {
      // `X extends infer V`: anything but a union, never or any binds V
      let ok = self.t()
      self.e(ok + " = call i1 @tstc_plain1(i64 " + cv + ")")
      let lb = self.l()
      self.e("br i1 " + ok + ", label %" + lb + ", label %" + ls)
      self.block(lb)
      self.store_slot(cd.fslots[0], cv)
      self.br(lt)
    }
    2 => {
      // `X extends [infer A, infer B, ...]` with X a plain tuple of that length
      let n = cd.fslots.length()
      let (ok, el) = self.tuple_check(cv, n)
      let lb = self.l()
      self.e("br i1 " + ok + ", label %" + lb + ", label %" + ls)
      self.block(lb)
      if n > 0 {
        for k in 0..<n {
          let p = self.t()
          self.e(p + " = getelementptr inbounds i64, ptr " + el + ", i64 \{k}")
          let v = self.t()
          self.e(v + " = load i64, ptr " + p + ", !invariant.load !0")
          self.store_slot(cd.fslots[k], v)
        }
      }
      self.br(lt)
    }
    3 => {
      let a = self.t()
      self.e(a + " = icmp eq i64 " + cv + ", " + v_true)
      let lb = self.l()
      self.e("br i1 " + a + ", label %" + lt + ", label %" + lb)
      self.block(lb)
      let b = self.t()
      self.e(b + " = icmp eq i64 " + cv + ", " + v_false)
      self.e("br i1 " + b + ", label %" + lf + ", label %" + ls)
    }
    4 => {
      let a = self.t()
      self.e(a + " = icmp eq i64 " + cv + ", " + v_null)
      let lb = self.l()
      self.e("br i1 " + a + ", label %" + lt + ", label %" + lb)
      self.block(lb)
      let b = self.t()
      self.e(b + " = call i1 @tstc_notnull(i64 " + cv + ")")
      self.e("br i1 " + b + ", label %" + lf + ", label %" + ls)
    }
    5 => {
      // `X extends infer V extends bigint`: an integer (an immediate) binds V
      let isi = self.t()
      self.e(isi + " = and i64 " + cv + ", 1")
      let ok = self.t()
      self.e(ok + " = icmp ne i64 " + isi + ", 0")
      let lb = self.l()
      self.e("br i1 " + ok + ", label %" + lb + ", label %" + ls)
      self.block(lb)
      self.store_slot(cd.fslots[0], cv)
      self.br(lt)
    }
    _ => self.br(ls)
  }
  let results : Array[(String, String)] = []
  let lj = self.l()
  // the runtime binds the slots in the frame too (and jumps here)
  for s in cd.infer_slots {
    self.forget(s)
  }
  let m = self.mark()
  self.block(lt)
  self.arm(self.gen_branch(cd.t, tail), results, lj)
  self.undo(m)
  self.block(lf)
  self.arm(self.gen_branch(cd.f, tail), results, lj)
  self.undo(m)
  // the general case
  self.block(ls)
  self.slow += 1
  self.uses_out = true
  let d = if cd.fast >= 1 && cd.fast <= 4 && cd.fslots.length() <= 64 {
    // the parts of a descriptor as arguments: no data to relocate
    let id = cd.id.to_string()
    let pat = match cd.pat {
      Some(p) => pat_desc(p, self.frame)
      None => "null"
    }
    let (t, tc) = code_field(cd.t, self.frame, "t" + id)
    let (f, fc) = code_field(cd.f, self.frame, "f" + id)
    let whole = if cd.dist_slot >= 0 { cond_fn(cd, self.frame) } else { "null" }
    self.rtcall_env(
      "rt_condf",
      "i64 @rt_condf(i64, i64, ptr nocapture, ptr nocapture, i64, i64, ptr, ptr, i64, ptr, i64, ptr)",
      "i64 \{cd.fast}, i64 " + cv + ", ptr %env, ptr %out, i64 \{self.frame}, i64 \{cd.dist_slot}, ptr " +
      pat + ", " + t + ", " + tc + ", " + f + ", " + fc + ", ptr " + whole,
      CCond(cd),
    )
  } else {
    let desc = cond_desc(cd, self.frame)
    self.rtcall_env(
      "rt_cond",
      "i64 @rt_cond(ptr, i64, ptr nocapture, ptr nocapture)",
      "ptr " + desc + ", i64 " + cv + ", ptr %env, ptr %out",
      CCond(cd),
    )
  }
  let ldone = self.l()
  self.e(
    "switch i64 " + d + ", label %" + ldone + " [ i64 0, label %" + lt + " i64 1, label %" +
    lf + " ]",
  )
  self.slow -= 1
  self.block(ldone)
  let v = self.t()
  self.e(v + " = load i64, ptr %out")
  self.arm(self.finish(v, tail), results, lj)
  self.undo(m)
  self.join(results, lj, tail)
}

// a branch of a conditional the runtime may decide: one that is itself a
// conditional stays the function the runtime calls as its thunk
fn Fun::gen_branch(self : Fun, c : Code, tail : Bool) -> String? {
  match c {
    CCond(cd) => self.call_here(cond_fn(cd, self.frame), tail, c)
    _ => self.gen(c, tail)
  }
}

// a conditional whose checked value is simple (shape.mbt): no general case
// `ine<iand<X, C>, 0n> extends true` (or ieq), C a non-negative constant
// immediate: a test of bits (Go's flag tests). Its parts: X, C, the iand,
// whether set bits are true
fn flag_test(cd : Cond) -> (Code, Int64, Int, Bool)? {
  if cd.fast != 3 {
    return None
  }
  let cint = fn(c : Code) {
    match c {
      CTy(t) => const_int(ty_const(t))
      _ => None
    }
  }
  match cd.check {
    CNative(j, id, args) if args.length() == 2 &&
      aliases[j].nparams == 2 &&
      native_is_lib(id) &&
      (native_name(id) == "ine" || native_name(id) == "ieq") &&
      cint(args[1]) == Some(0L) =>
      match args[0] {
        CNative(j2, id2, a2) if a2.length() == 2 &&
          aliases[j2].nparams == 2 &&
          native_is_lib(id2) &&
          native_name(id2) == "iand" => {
          let (x, k) = match (cint(a2[0]), cint(a2[1])) {
            (_, Some(k)) => (a2[0], k)
            (Some(k), None) => (a2[1], k)
            _ => return None
          }
          if k < 0L {
            return None
          }
          Some((x, k, id2, native_name(id) == "ine"))
        }
        _ => None
      }
    _ => None
  }
}

// a flag test: where X is an immediate, its bits; otherwise the runtime's
// iand. Both paths branch to the arms (no join of the iand's result, which
// llc -O0 would store and load again)
fn Fun::gen_flag_test(
  self : Fun,
  cd : Cond,
  tail : Bool,
  x : Code,
  k : Int64,
  iand : Int,
  set_true : Bool,
) -> String? {
  let xv = self.gen_v(x)
  let m = self.mark()
  let results : Array[(String, String)] = []
  let lj = self.l()
  let lt = self.l()
  let lfl = self.l()
  let (lset, lclear) = if set_true { (lt, lfl) } else { (lfl, lt) }
  if !self.is_int(xv) {
    let lfast = self.l()
    let lslow = self.l()
    let bit = self.t()
    self.e(bit + " = trunc i64 " + xv + " to i1")
    self.e("br i1 " + bit + ", label %" + lfast + ", label %" + lslow)
    self.block(lslow)
    let sym = native_symbol(iand)
    self.slow += 1
    let r = self.rtcall(sym, native_sig(sym, 2), args_list([xv, (k * 2L + 1L).to_string()]))
    self.slow -= 1
    let z = self.t()
    self.e(z + " = icmp ne i64 " + r + ", 1")
    self.e("br i1 " + z + ", label %" + lset + ", label %" + lclear)
    self.block(lfast)
  }
  let a = self.t()
  self.e(a + " = and i64 " + xv + ", " + (k * 2L).to_string())
  let z = self.t()
  self.e(z + " = icmp ne i64 " + a + ", 0")
  self.e("br i1 " + z + ", label %" + lset + ", label %" + lclear)
  self.block(lt)
  self.arm(self.gen_split(cd.t, tail), results, lj)
  self.undo(m)
  self.block(lfl)
  self.arm(self.gen_split(cd.f, tail), results, lj)
  self.undo(m)
  self.join(results, lj, tail)
}

// `ilt<A, B> extends true` (ile, igt, ige, ieq, ine; geq and gne of
// immediates): an integer comparison branching to the arms. Its parts: A, B, the native, the comparison
fn compare_test(cd : Cond) -> (Code, Code, Int, String)? {
  if cd.fast != 3 {
    return None
  }
  match cd.check {
    CNative(j, id, args) if args.length() == 2 && aliases[j].nparams == 2 && native_is_lib(id) => {
      let cmp = match native_name(id) {
        "ilt" => "slt"
        "ile" => "sle"
        "igt" => "sgt"
        "ige" => "sge"
        "ieq" => "eq"
        "ine" => "ne"
        // (equal immediates are the same integer; the runtime compares the
        // rest)
        "geq" => "eq"
        "gne" => "ne"
        _ => return None
      }
      Some((args[0], args[1], id, cmp))
    }
    _ => None
  }
}

// a comparison: of the immediates where both are, otherwise the runtime's.
// Both paths branch to the arms (no join of the result)
fn Fun::gen_compare_test(
  self : Fun,
  cd : Cond,
  tail : Bool,
  a : Code,
  b : Code,
  id : Int,
  cmp : String,
) -> String? {
  let av = self.gen_v(a)
  let bv = self.gen_v(b)
  let m = self.mark()
  let results : Array[(String, String)] = []
  let lj = self.l()
  let lt = self.l()
  let lfl = self.l()
  if !(self.is_int(av) && self.is_int(bv)) {
    let lfast = self.l()
    let lslow = self.l()
    let both = self.t()
    self.e(both + " = and i64 " + av + ", " + bv)
    let bit0 = self.t()
    self.e(bit0 + " = trunc i64 " + both + " to i1")
    let nm = native_name(id)
    if nm == "geq" || nm == "gne" {
      // (else the same word, or an integer and null, Go's nil checks of
      // pointers: the comparison of the words, as n_geq; tested past the
      // integers, whose way stays as short)
      let lchk = self.l()
      self.e("br i1 " + bit0 + ", label %" + lfast + ", label %" + lchk)
      self.block(lchk)
      let same = self.t()
      self.e(same + " = icmp eq i64 " + av + ", " + bv)
      let ai = self.t()
      self.e(ai + " = trunc i64 " + av + " to i1")
      let bi = self.t()
      self.e(bi + " = trunc i64 " + bv + " to i1")
      let an = self.t()
      self.e(an + " = icmp eq i64 " + av + ", " + v_null)
      let bn = self.t()
      self.e(bn + " = icmp eq i64 " + bv + ", " + v_null)
      let x = self.t()
      self.e(x + " = and i1 " + ai + ", " + bn)
      let y = self.t()
      self.e(y + " = and i1 " + bi + ", " + an)
      let xy = self.t()
      self.e(xy + " = or i1 " + x + ", " + y)
      let f = self.t()
      self.e(f + " = or i1 " + same + ", " + xy)
      self.e("br i1 " + f + ", label %" + lfast + ", label %" + lslow)
    } else {
      self.e("br i1 " + bit0 + ", label %" + lfast + ", label %" + lslow)
    }
    self.block(lslow)
    let sym = native_symbol(id)
    self.slow += 1
    let r = self.rtcall(sym, native_sig(sym, 2), args_list([av, bv]))
    self.slow -= 1
    let z = self.t()
    self.e(z + " = icmp eq i64 " + r + ", " + v_true)
    self.e("br i1 " + z + ", label %" + lt + ", label %" + lfl)
    self.block(lfast)
  }
  let c = self.t()
  self.e(c + " = icmp " + cmp + " i64 " + av + ", " + bv)
  self.e("br i1 " + c + ", label %" + lt + ", label %" + lfl)
  self.block(lt)
  self.arm(self.gen_split(cd.t, tail), results, lj)
  self.undo(m)
  self.block(lfl)
  self.arm(self.gen_split(cd.f, tail), results, lj)
  self.undo(m)
  self.join(results, lj, tail)
}

fn Fun::gen_cond_inline(self : Fun, cd : Cond, tail : Bool) -> String? {
  match flag_test(cd) {
    Some((x, k, iand, set_true)) => return self.gen_flag_test(cd, tail, x, k, iand, set_true)
    None => ()
  }
  match compare_test(cd) {
    Some((a, b, id, cmp)) => return self.gen_compare_test(cd, tail, a, b, id, cmp)
    None => ()
  }
  // `X extends infer V` binds a pair as it is, `X extends [infer A, infer B]`
  // takes its parts
  let op = self.gen_op(cd.check)
  let pp = if check_shapes.val { None } else { pair_parts(op) }
  let keep_pair = pp is Some(_) &&
    (cd.fast == 1 || (cd.fast == 2 && (cd.fslots.length() == 2 || cd.fslots.length() == 1)))
  let cv = if keep_pair { op } else { self.val(op) }
  if check_shapes.val {
    let f = rt("rt_shape_check", "void @rt_shape_check(i64, i64)")
    self.e("call void " + f + "(i64 " + cv + ", i64 \{cd.id})")
  }
  let dist = cd.dist_slot >= 0
  // distributing over never gives never, which is what the false branch
  // gives when it is the checked slot
  let never_false = dist &&
    (match (cd.check, cd.f) {
      (CSlot(a), CSlot(b)) => a == b
      _ => false
    })
  let m = self.mark()
  let results : Array[(String, String)] = []
  let lj = self.l()
  let lt = self.l()
  let ln = self.l()
  let mut lf : String? = None
  let mut never_out = false
  match cd.fast {
    1 => {
      // anything simple binds; never distributes to never
      if dist {
        // (a pair (a, b) is never only as (never, 0))
        let isn = self.t()
        match pp {
          Some((a, b)) if keep_pair => {
            let n0 = self.t()
            self.e(n0 + " = icmp eq i64 " + a + ", " + v_never)
            let bz = self.t()
            self.e(bz + " = icmp eq i64 " + b + ", 0")
            self.e(isn + " = and i1 " + n0 + ", " + bz)
          }
          _ => self.e(isn + " = icmp eq i64 " + cv + ", " + v_never)
        }
        let lb = self.l()
        self.e("br i1 " + isn + ", label %" + ln + ", label %" + lb)
        self.block(lb)
        never_out = true
      }
      // the true branch follows in the same block
      self.bind(cd.fslots[0], cv, false)
      if is_bool_code(cd.check, self) {
        self.bool_slots.set(cd.fslots[0], true)
      }
    }
    2 => {
      // a plain tuple of the length binds its elements, never binds never
      // (or distributes to never), anything else is false
      let n = cd.fslots.length()
      // a pair: its parts; otherwise the value (its first part) is checked
      let mut cv = cv
      let mut from_pair : (String, String, String)? = None
      let lfl = self.l()
      // (the elements, when the runtime tested the pair's value)
      let mut fused : (String, String)? = None
      // (n = 2: the elements themselves)
      let mut fused2 : (String, String, String)? = None
      match pp {
        Some((a, b)) if keep_pair => {
          // (a, 0) is the value a, (a, 4) the tuple [a], others [a, b]: the
          // expected shape tested first, with one comparison
          let lnp = self.l()
          let lchk = self.l()
          let hit = self.t()
          if n == 1 {
            self.e(hit + " = icmp eq i64 " + b + ", " + pair_one)
          } else {
            let m = self.t()
            self.e(m + " = and i64 " + b + ", -5")
            self.e(hit + " = icmp ne i64 " + m + ", 0")
          }
          // (straight to the bound branch: its phis take the parts from here)
          let lpair = self.cur
          self.e("br i1 " + hit + ", label %" + lt + ", label %" + lchk)
          self.block(lchk)
          from_pair = Some((a, b, lpair))
          cv = a
          if never_false && n == 2 {
            // (a, 0) with a a plain tuple of 2: its elements (the second is
            // not 0); anything else is the false branch
            if self.spec is Some(_) {
              self.bail()
            }
            let f = rt("rt_pair_elems2", pair_ty + " @rt_pair_elems2(i64, i64)")
            let r = self.t()
            self.e(r + " = call " + pair_ty + " " + f + "(i64 " + a + ", i64 " + b + ")")
            let x = self.t()
            self.e(x + " = extractvalue " + pair_ty + " " + r + ", 0")
            let y = self.t()
            self.e(y + " = extractvalue " + pair_ty + " " + r + ", 1")
            let ok = self.t()
            self.e(ok + " = icmp ne i64 " + y + ", 0")
            fused2 = Some((ok, x, y))
          } else if never_false && n > 0 {
            // (a, 0) with a a plain tuple of n: its elements; anything else
            // is the false branch
            if self.spec is Some(_) {
              self.bail()
            }
            let f = rt("rt_pair_elems", "ptr @rt_pair_elems(i64, i64, i64)")
            let el = self.t()
            self.e(el + " = call ptr " + f + "(i64 " + a + ", i64 " + b + ", i64 \{n})")
            let ok = self.t()
            self.e(ok + " = icmp ne ptr " + el + ", null")
            fused = Some((ok, el))
          } else {
            let isv = self.t()
            self.e(isv + " = icmp eq i64 " + b + ", 0")
            self.e("br i1 " + isv + ", label %" + lnp + ", label %" + lfl)
            self.block(lnp)
          }
        }
        _ => ()
      }
      let lno = self.l()
      let elems : Array[String] = []
      let lb = match fused2 {
        Some((ok, x, y)) => {
          // (straight to the bound branch)
          let lc = self.cur
          self.e("br i1 " + ok + ", label %" + lt + ", label %" + lfl)
          elems.push(x)
          elems.push(y)
          lc
        }
        None => {
          let (ok, el) = match fused {
            Some(x) => x
            None => self.tuple_check(cv, n)
          }
          let lb = self.l()
          // (never_false: what is not the tuple is the false branch's)
          self.e("br i1 " + ok + ", label %" + lb + ", label %" + (if never_false { lfl } else { lno }))
          self.block(lb)
          if n > 0 {
            for k in 0..<n {
              let p = self.t()
              self.e(p + " = getelementptr inbounds i64, ptr " + el + ", i64 \{k}")
              let v = self.t()
              self.e(v + " = load i64, ptr " + p + ", !invariant.load !0")
              elems.push(v)
            }
          }
          self.br(lt)
          lb
        }
      }
      lf = Some(lfl)
      let lnv = self.l()
      if never_false {
        // (never's value is the false branch's)
        ()
      } else if dist {
        self.block(lno)
        let isn = self.t()
        self.e(isn + " = icmp eq i64 " + cv + ", " + v_never)
        self.e("br i1 " + isn + ", label %" + ln + ", label %" + lfl)
        never_out = true
      } else {
        self.block(lno)
        let isn = self.t()
        self.e(isn + " = icmp eq i64 " + cv + ", " + v_never)
        self.e("br i1 " + isn + ", label %" + lnv + ", label %" + lfl)
        self.block(lnv)
        self.br(lt)
      }
      self.block(lt)
      for k in 0..<n {
        let v = self.t()
        let extra = match from_pair {
          Some((a, b, lpair)) => ", [ " + (if k == 0 { a } else { b }) + ", %" + lpair + " ]"
          None => ""
        }
        if dist {
          self.e(v + " = phi i64 [ " + elems[k] + ", %" + lb + " ]" + extra)
        } else {
          self.e(
            v + " = phi i64 [ " + elems[k] + ", %" + lb + " ], [ " + v_never + ", %" + lnv +
            " ]" + extra,
          )
        }
        self.bind(cd.fslots[k], v, false)
      }
    }
    5 => {
      // `extends infer V extends bigint`: an integer immediate binds V at
      // once; never binds never (or distributes to never); anything else
      // binds when it is assignable to bigint (a boxed or long integer, the
      // keyword, a branded one). When the true branch looks a table up by
      // V's text, the key is made on the way (no second test of V)
      let keyed = match cd.t {
        CIndex(CObj(oc), CTpl(tx, [CSlot(ks)])) =>
          ks == cd.fslots[0] && tx.length() == 2 && tx[0].len == 0 && tx[1].len == 0 &&
          oc.index.length() <= 1 && oc.calls.is_empty()
        _ => false
      }
      let isi = self.t()
      self.e(isi + " = and i64 " + cv + ", 1")
      let imm = self.t()
      self.e(imm + " = icmp ne i64 " + isi + ", 0")
      let lk = self.l()
      let li = if keyed { self.l() } else { lt }
      let lo = if keyed { self.l() } else { lt }
      self.e("br i1 " + imm + ", label %" + li + ", label %" + lk)
      self.block(lk)
      let lfl = self.l()
      lf = Some(lfl)
      let lr = self.l()
      let isn = self.t()
      self.e(isn + " = icmp eq i64 " + cv + ", " + v_never)
      if never_false {
        // (never's value is the false branch's)
        self.e("br i1 " + isn + ", label %" + lfl + ", label %" + lr)
      } else if dist {
        self.e("br i1 " + isn + ", label %" + ln + ", label %" + lr)
        never_out = true
      } else {
        self.e("br i1 " + isn + ", label %" + lo + ", label %" + lr)
      }
      self.block(lr)
      if self.spec is Some(_) {
        self.bail()
        self.br(lfl)
      } else {
        let f = rt("rt_is_bigint", "i1 @rt_is_bigint(i64)")
        let ok = self.t()
        self.e(ok + " = call i1 " + f + "(i64 " + cv + ")")
        self.e("br i1 " + ok + ", label %" + lo + ", label %" + lfl)
      }
      if keyed {
        self.block(lo)
        self.slow += 1
        let kg = self.rtcall("rt_tpl_key", "i64 @rt_tpl_key(i64)", "i64 " + cv)
        self.slow -= 1
        let lo2 = self.cur
        self.br(lt)
        self.block(li)
        self.br(lt)
        self.block(lt)
        let kv = self.t()
        self.e(kv + " = phi i64 [ " + cv + ", %" + li + " ], [ " + kg + ", %" + lo2 + " ]")
        self.tpl_keys.set(cv, kv)
      } else {
        self.block(lt)
      }
      // (the value itself on every way here)
      self.bind(cd.fslots[0], cv, false)
    }
    _ => {
      // `extends true` / `extends null`: never is true unless it distributes
      let lit = if cd.fast == 3 { v_true } else { v_null }
      let a = self.t()
      self.e(a + " = icmp eq i64 " + cv + ", " + lit)
      if cd.fast == 3 && (is_bool_code(cd.check, self) || self.bool_i1.contains(cv)) {
        // a comparison's result: true or false, no never to look for
        let lfl = self.l()
        lf = Some(lfl)
        let c = match self.bool_i1.get(cv) {
          Some(x) => x
          None => a
        }
        self.e("br i1 " + c + ", label %" + lt + ", label %" + lfl)
        self.block(lt)
        self.arm(self.gen_split(cd.t, tail), results, lj)
        self.undo(m)
        self.block(lfl)
        self.arm(self.gen_split(cd.f, tail), results, lj)
        self.undo(m)
        return self.join(results, lj, tail)
      }
      let lb = self.l()
      self.e("br i1 " + a + ", label %" + lt + ", label %" + lb)
      self.block(lb)
      let lfl = self.l()
      lf = Some(lfl)
      if never_false {
        // (never's value is the false branch's)
        self.br(lfl)
      } else if dist {
        let isn = self.t()
        self.e(isn + " = icmp eq i64 " + cv + ", " + v_never)
        self.e("br i1 " + isn + ", label %" + ln + ", label %" + lfl)
        never_out = true
      } else {
        let isn = self.t()
        self.e(isn + " = icmp eq i64 " + cv + ", " + v_never)
        self.e("br i1 " + isn + ", label %" + lt + ", label %" + lfl)
      }
      self.block(lt)
    }
  }
  self.arm(self.gen_split(cd.t, tail), results, lj)
  self.tpl_keys.clear()
  self.undo(m)
  match lf {
    Some(l) => {
      self.block(l)
      self.arm(self.gen_split(cd.f, tail), results, lj)
      self.undo(m)
    }
    None => ()
  }
  if never_out {
    self.block(ln)
    self.arm(self.finish(v_never, tail), results, lj)
  }
  self.join(results, lj, tail)
}

// a branch of an inline conditional: in a function of its own once this one
// is large (LLVM's time grows faster than the size of a function); the slots
// in registers are stored for it
fn Fun::gen_split(self : Fun, c : Code, tail : Bool) -> String? {
  match c {
    CTy(_) | CSlot(_) => return self.gen(c, tail)
    _ => ()
  }
  if self.size > split_limit.val {
    self.call_here(code_fn(c, self.frame, ""), tail, c)
  } else {
    self.gen(c, tail)
  }
}

// ---------------------------------------------------------------------------
// Function bodies

fn Fun::header(self : Fun) -> String {
  let h = StringBuilder::new()
  h.write_string("entry:\n")
  if self.uses_out {
    h.write_string("  %out = alloca i64, align 8\n")
  }
  if self.scratch > 0 {
    h.write_string("  %scr = alloca [\{self.scratch} x i64], align 8\n")
  }
  h.write_string("  br label %L0\n")
  h.to_string()
}

fn emit_function(def : String, f : Fun) -> Unit {
  if !f.jts.is_empty() {
    // the function's name: what follows the last space before "("
    let open = def.find("(").unwrap()
    let head = def.unsafe_substring(start=0, end=open)
    let fname = match head.rev_find(" ") {
      Some(i) => head.unsafe_substring(start=i + 1, end=head.length())
      None => head
    }
    for jt in f.jts {
      let sb = StringBuilder::new()
      sb.write_string(jt.0 + " = internal constant [\{jt.1.length()} x ptr] [")
      for k in 0..<jt.1.length() {
        if k > 0 {
          sb.write_string(", ")
        }
        sb.write_string("ptr blockaddress(" + fname + ", %" + jt.1[k] + ")")
      }
      sb.write_string("]\n")
      uw(sb.to_string())
    }
  }
  let buf = cu().buf
  c_buf_str(buf, def)
  if frame_pointers_on.val {
    c_buf_str(buf, " \"frame-pointer\"=\"all\"")
  }
  c_buf_str(buf, " {\n")
  c_buf_str(buf, f.header())
  c_buf_buf(buf, f.buf)
  c_buf_free(f.buf)
  c_buf_str(buf, "}\n\n")
}

// the body of a function: a conditional is this function
fn Fun::gen_top(self : Fun, code : Code) -> String? {
  match code {
    CCond(cd) =>
      if inline_conds.get(cd.id) == Some(true) {
        self.gen_cond_inline(cd, true)
      } else {
        self.gen_cond(cd, true)
      }
    c => self.gen(c, true)
  }
}

// a function of a frame evaluating code in tail position
fn gen_env_fn(name : String, code : Code, frame : Int) -> Unit {
  let f = Fun::new(frame, true)
  f.block("L0")
  let _ = f.gen_top(code)
  // (hidden: what only its unit calls is not exported)
  emit_function("define hidden " + pair_ty + " " + name + "(" + fwd_params + ")", f)
}

// a property an object type's descriptor holds (a constant or a slot): no
// code evaluates it
fn prop_in_desc(c : Code) -> Bool {
  match c {
    CSlot(_) => true
    _ => const_operand(c) is Some(_)
  }
}

// prop_eval_fn's function: the property whose index is in slot `frame` (an
// integer), as the property's code in tail position
fn gen_prop_eval(name : String, oc : ObjCode, frame : Int) -> Unit {
  let f = Fun::new(frame + 1, true)
  f.block("L0")
  let n = oc.props.length()
  let jv = f.load_slot(frame)
  let ji = f.t()
  f.e(ji + " = ashr i64 " + jv + ", 1")
  let groups = prop_groups(oc)
  let group_of : Array[Int] = Array::make(n, -1)
  for g in 0..<groups.length() {
    for j in groups[g].members {
      group_of[j] = g
    }
  }
  let glabels = groups.map(fn(_g) { f.l() })
  let lnone = f.l()
  let labels = Array::makei(n, fn(j) {
    if prop_in_desc(oc.props[j].1) {
      lnone
    } else if group_of[j] >= 0 {
      glabels[group_of[j]]
    } else {
      f.l()
    }
  })
  f.jump_table(ji, labels)
  let m = f.mark()
  for g in 0..<groups.length() {
    f.undo(m)
    f.block(glabels[g])
    let _ = f.gen_prop_group(oc, groups[g], ji, true)
  }
  for j in 0..<n {
    if prop_in_desc(oc.props[j].1) || group_of[j] >= 0 {
      continue
    }
    f.undo(m)
    f.block(labels[j])
    let _ = f.gen(oc.props[j].1, true)
  }
  f.undo(m)
  f.block(lnone)
  f.e("unreachable")
  emit_function("define hidden " + pair_ty + " " + name + "(" + fwd_params + ")", f)
}

// a jump through a table of labels by an index in range
fn Fun::jump_table(self : Fun, idx : String, targets : Array[String]) -> Unit {
  let u = cu()
  u.nglob += 1
  let jt = "@\"" + u.prefix + ":J" + u.nglob.to_string() + "\""
  self.jts.push((jt, targets))
  let ap = self.t()
  self.e(ap + " = getelementptr inbounds [\{targets.length()} x ptr], ptr " + jt + ", i64 0, i64 " + idx)
  let a = self.t()
  self.e(a + " = load ptr, ptr " + ap)
  let sb = StringBuilder::new()
  sb.write_string("indirectbr ptr " + a + ", [")
  let seen : Map[String, Bool] = Map::new()
  for k in 0..<targets.length() {
    if seen.contains(targets[k]) {
      continue
    }
    seen.set(targets[k], true)
    if k > 0 {
      sb.write_string(", ")
    }
    sb.write_string("label %" + targets[k])
  }
  sb.write_string("]")
  self.e(sb.to_string())
}

// the parameters an alias has in registers
fn Fun::bind_params(self : Fun, n : Int) -> Unit {
  for i in 0..<n {
    if i < reg_args {
      self.bind(i, "%a\{i}", false)
    }
  }
}

// an alias: a function of its frame (the caller allocated it, and stored the
// arguments past the registers)
fn gen_alias(idx : Int) -> Unit {
  let a = aliases[idx]
  let f = Fun::new(a.frame, true)
  f.owns_frame = true
  f.block("L0")
  f.entry_top()
  if coverage_on.val {
    // --coverage: the alias ran (rt/main.c writes the names at exit)
    sym_decls.set("@tstc_cov", "@tstc_cov = external global i8")
    let _ = uref("@tstc_cov")
    f.e("store i8 1, ptr getelementptr inbounds (i8, ptr @tstc_cov, i64 \{idx})")
  }
  let looping = loops_on.val && a.nparams > 0 && !memo_body.contains(idx) && catch_of.get(idx) is None
  if looping {
    f.loop_start(idx, a.nparams)
  } else {
    f.bind_params(a.nparams)
  }
  if a.nparams > 0 {
    f.ident_top = Some((a.body, a.nparams))
  }
  if memo_body.contains(idx) {
    gen_memo(f, idx)
    emit_function("define " + pair_ty + " " + alias_fn(idx) + "(" + fwd_params + ")", f)
    return
  }
  let _ = f.gen_top(a.body)
  if looping {
    f.loop_end()
  }
  if catch_of.get(idx) is None && f.hard == 0 && spec_on.val && native_fast_on.val && !coverage_on.val &&
    !check_shapes.val {
    // no call on its way but in slow paths: a copy with its inline paths
    // only (no frame of the machine's to set up), which jumps to this
    // function, from the start, for anything else
    let name = alias_fn(idx)
    let full = name.unsafe_substring(start=0, end=name.length() - 1) + ".s\""
    let g = Fun::new(a.frame, true)
    g.owns_frame = true
    g.spec = Some(full)
    f.ics.each(fn(k, v) { if !k.has_suffix("#") { g.ics.set(k, v) } })
    g.block("L0")
    g.bind_params(a.nparams)
    if a.nparams > 0 {
      g.ident_top = Some((a.body, a.nparams))
    }
    let _ = g.gen_top(a.body)
    if g.commits > 0 {
      // (not inlined at the copy's jumps to it: that would make the copy
      // the function again)
      emit_function("define internal " + pair_ty + " " + full + "(" + fwd_params + ") noinline", f)
      emit_function("define " + pair_ty + " " + name + "(" + fwd_params + ")", g)
      return
    }
    c_buf_free(g.buf)
  }
  match catch_of.get(idx) {
    Some(h) => {
      // `@catch H` (catch.mbt): runs under tstc_try, which makes a failure
      // inside the handler's value (rt/try.c)
      let name = alias_fn(idx)
      let inner = name.unsafe_substring(start=0, end=name.length() - 1) + ".try\""
      emit_function("define " + pair_ty + " " + inner + "(" + fwd_params + ")", f)
      declare("@tstc_try", pair_ty + " @tstc_try(ptr, ptr, i64, ptr" + ", i64".repeat(reg_args) + ")")
      let hf = entry_fn(h)
      let w = Fun::new(a.frame, false)
      w.block("L0")
      w.entry_top()
      let r = w.t()
      w.e(
        r + " = call " + pair_ty + " @tstc_try(ptr " + inner + ", ptr " + hf + ", i64 \{aliases[h].nparams}, " +
        fwd_params + ")",
      )
      w.e("ret " + pair_ty + " " + r)
      emit_function("define " + pair_ty + " " + name + "(" + fwd_params + ")", w)
      return
    }
    None => ()
  }
  emit_function("define " + pair_ty + " " + alias_fn(idx) + "(" + fwd_params + ")", f)
}

// --no-spec: no fast copies of aliases' functions (gen_alias)
let spec_on : Ref[Bool] = Ref::new(true)

// --no-loops: an alias's calls of itself in tail position are calls
// (Fun::loop_start)
let loops_on : Ref[Bool] = Ref::new(true)

// --frame-pointers: functions keep a frame record (x29/rbp), so that
// sampling profilers walk the stacks of generated code
let frame_pointers_on : Ref[Bool] = Ref::new(false)

// --coverage: which aliases run (TSTC_COVERAGE=<path> at run time)
let coverage_on : Ref[Bool] = Ref::new(false)

// the flags of memoized aliases in the runtime (rt/memo.c: MEMO_FLAGS)
let memo_flags : Int = 1048576

// a memoized alias (opt.mbt): its arguments are looked up in the runtime's
// table; on a miss its body (a call of the alias of the body) is evaluated
// and the result recorded. The runtime turns the lookups of an alias off
// (its flag) when they do not pay: then the body is called directly.
fn gen_memo(f : Fun, idx : Int) -> Unit {
  let a = aliases[idx]
  // the flag: the runtime's tstc_memo_off[idx] (an alias past its end is
  // always looked up)
  if idx < memo_flags {
    let fp = f.t()
    f.e(fp + " = getelementptr inbounds [\{memo_flags} x i8], ptr @tstc_memo_off, i64 0, i64 \{idx}")
    let o = f.t()
    f.e(o + " = load i8, ptr " + fp)
    let isoff = f.t()
    f.e(isoff + " = icmp ne i8 " + o + ", 0")
    let loff = f.l()
    let lon = f.l()
    f.e("br i1 " + isoff + ", label %" + loff + ", label %" + lon)
    f.block(loff)
    let m = f.mark()
    let _ = f.gen_top(a.body)
    f.undo(m)
    f.block(lon)
  }
  // the arguments in the frame, where the runtime reads them
  for i in 0..<a.nparams {
    if i < reg_args {
      let p = f.slot_ptr_in("%env", i)
      f.e("store i64 %a\{i}, ptr " + p)
      f.bind(i, "%a\{i}", true)
    }
  }
  f.uses_out = true
  let get = rt("rt_memo_get", "i64 @rt_memo_get(i64, ptr nocapture readonly, i64, ptr nocapture)")
  let h = f.t()
  f.e(h + " = call i64 " + get + "(i64 \{idx}, ptr %env, i64 \{a.nparams}, ptr %out)")
  let hit = f.t()
  f.e(hit + " = icmp ne i64 " + h + ", 0")
  let lhit = f.l()
  let lmiss = f.l()
  f.e("br i1 " + hit + ", label %" + lhit + ", label %" + lmiss)
  f.block(lhit)
  f.ret(h)
  f.block(lmiss)
  let k = f.t()
  f.e(k + " = load i64, ptr %out")
  let r = match f.gen(a.body, false) {
    Some(x) => f.val(x)
    None => abort("value expected")
  }
  let put = rt("rt_memo_put", "void @rt_memo_put(i64, i64)")
  f.e("call void " + put + "(i64 " + k + ", i64 " + r + ")")
  f.ret(r)
}

// a frame pushed for the alias, with n arguments loaded from args
fn push_and_call(f : Fun, idx : Int, n : Int, args : String) -> String? {
  let a = aliases[idx]
  if a.nparams == 0 {
    let v = f.t()
    f.e(v + " = call i64 " + const_fn(idx) + "()")
    return f.finish(v, true)
  }
  let vals : Array[String] = []
  for i in 0..<n {
    let p = f.t()
    f.e(p + " = getelementptr inbounds i64, ptr " + args + ", i64 \{i}")
    let v = f.t()
    f.e(v + " = load i64, ptr " + p)
    vals.push(v)
  }
  let fname = if n < a.nparams { filler_fn(idx, n) } else { alias_fn(idx) }
  f.call_frame(fname, vals, a.frame, true)
}

// --no-ident: object type sites make a new object each time
let ident_on : Ref[Bool] = Ref::new(true)

fn Fun::is_ident_top(self : Fun, code : Code) -> Int? {
  match self.ident_top {
    Some((c, n)) => if physical_equal(c, code) { Some(n) } else { None }
    None => None
  }
}

// code makes an object type whose identity counts (tsgo: one type per
// declaration and type arguments): an interface only as an alias's body
fn Fun::ident_site(self : Fun, code : Code) -> Bool {
  if !ident_on.val {
    return false
  }
  match self.ident_skip {
    Some(c) => if physical_equal(c, code) { return false }
    None => ()
  }
  match code {
    CNative(_, _, _) => self.is_ident_top(code) is Some(_)
    _ => true
  }
}

// an object type site: the object it made with the same values of the
// slots it reads (the alias's parameters when it is the alias's body), or
// a new one recorded so (rt/memo.c: rt_ident_get); every empty object type
// literal is one object (tsgo: emptyTypeLiteralType)
fn Fun::gen_ident(self : Fun, code : Code, tail : Bool) -> String? {
  self.count_call()
  if self.spec is Some(_) {
    self.bail()
    return self.finish(self.dead(), tail)
  }
  let top = self.is_ident_top(code)
  let empty = match code {
    CObj(oc) => top is None && oc.props.is_empty() && oc.index.is_empty() && oc.calls.is_empty()
    _ => false
  }
  let keys : Array[Int] = match top {
    Some(n) => Array::makei(n, fn(i) { i })
    None =>
      if empty {
        []
      } else {
        let ks = code_free(code).keys().collect()
        ks.sort()
        ks
      }
  }
  let site = if empty {
    sym_decls.set("@tstc_empty_lit", "@tstc_empty_lit = external global i64")
    uref("@tstc_empty_lit")
  } else {
    let u = cu()
    u.nglob += 1
    let g = "@\"" + u.prefix + ":I" + u.nglob.to_string() + "\""
    uw(g + " = internal global i64 0, section \"__DATA,__tstc_ident\", align 8\n")
    g
  }
  self.flush(code)
  let vals = keys.map(fn(s) { self.val(self.load_slot(s)) })
  let p = if vals.is_empty() { "null" } else { self.scratch_of(vals) }
  self.uses_out = true
  let get = rt("rt_ident_get", "i64 @rt_ident_get(ptr, ptr nocapture readonly, i64, ptr nocapture)")
  let h = self.t()
  self.e(h + " = call i64 " + get + "(ptr " + site + ", ptr " + p + ", i64 \{vals.length()}, ptr %out)")
  let hit = self.t()
  self.e(hit + " = icmp ne i64 " + h + ", 0")
  let pre = self.cur
  let lb = self.l()
  let lj = self.l()
  self.e("br i1 " + hit + ", label %" + lj + ", label %" + lb)
  self.block(lb)
  let m = self.mark()
  let k = self.t()
  self.e(k + " = load i64, ptr %out")
  let saved = self.ident_skip
  self.ident_skip = Some(code)
  let v = self.gen_v(code)
  self.ident_skip = saved
  let put = rt("rt_ident_put", "void @rt_ident_put(i64, i64)")
  self.e("call void " + put + "(i64 " + k + ", i64 " + v + ")")
  let endb = self.cur
  self.br(lj)
  self.undo(m)
  self.block(lj)
  let r = self.t()
  self.e(r + " = phi i64 [ " + h + ", %" + pre + " ], [ " + v + ", %" + endb + " ]")
  self.finish(r, tail)
}

// an alias without parameters: evaluated once
fn gen_const(idx : Int) -> Unit {
  let a = aliases[idx]
  // the value, the flag "being computed", the value handed out while it was
  // (rt_knot_open) and the alias's name, where the GC and the printer find
  // them (rt_knot_name)
  let cache = "@\"" + cu().prefix + ":cache\""
  let nm = cstr_global(a.name)
  uw(
    cache + " = internal global { i64, i64, i64, ptr } { i64 0, i64 0, i64 0, ptr " + nm +
    " }, section \"__DATA,__tstc_cache\", align 8\n",
  )
  let f = Fun::new(0, false)
  f.ret_pair = false
  f.block("L0")
  f.e("%cp = getelementptr inbounds i64, ptr " + cache + ", i64 0")
  f.e("%c = load i64, ptr %cp")
  f.e("%hit = icmp ne i64 %c, 0")
  f.e("br i1 %hit, label %Lhit, label %Lmiss")
  f.block("Lhit")
  f.e("ret i64 %c")
  f.block("Lmiss")
  f.e("%fp = getelementptr inbounds i64, ptr " + cache + ", i64 1")
  f.e("%fl = load i64, ptr %fp")
  f.e("%busy = icmp ne i64 %fl, 0")
  f.e("br i1 %busy, label %Lcyc, label %Lgo")
  // referenced again while computed (through an array or tuple element,
  // which tsgo defers): a value that becomes the alias's once computed
  f.block("Lcyc")
  let open = rt("rt_knot_open", "i64 @rt_knot_open(ptr)")
  f.e("%k = call i64 " + open + "(ptr " + cache + ")")
  f.e("ret i64 %k")
  f.block("Lgo")
  f.e("store i64 1, ptr %fp")
  let v = match f.call_frame(alias_fn(idx), [], a.frame, false) {
    Some(x) => f.val(x)
    None => abort("value expected")
  }
  // (stores the value and clears the flag)
  // (a union or intersection written as the alias's type: rt/ty.c alias_topped)
  let written_set = match a.body {
    CUnion(_) | CInter(_) => 1
    _ => 0
  }
  let close = rt("rt_knot_close", "i64 @rt_knot_close(ptr, i64, i64)")
  let r = f.t()
  f.e(r + " = call i64 " + close + "(ptr " + cache + ", i64 " + v + ", i64 \{written_set})")
  f.e("ret i64 " + r)
  emit_function("define i64 " + const_fn(idx) + "()", f)
}

// an alias called with k < nparams arguments: the defaults are evaluated in
// the callee's frame
fn gen_filler(idx : Int, k : Int) -> Unit {
  let a = aliases[idx]
  let f = Fun::new(a.frame, true)
  f.owns_frame = true
  f.block("L0")
  f.entry_top()
  f.bind_params(k)
  for i in k..<a.nparams {
    let v = match a.defaults[i] {
      Some(d) => f.gen_v(d)
      None => v_unknown
    }
    // a default can read the parameters before it
    f.bind(i, v, false)
  }
  let vals : Array[String] = []
  for i in 0..<a.nparams {
    vals.push(f.val(f.load_slot(i)))
  }
  let _ = if a.native >= 0 {
    let sym = native_symbol(a.native)
    f.finish(f.native_call(a.native, sym, vals), true)
  } else {
    // the alias takes this frame over
    f.store_args("%env", vals)
    let r = f.t()
    f.e(r + " = musttail call " + pair_ty + " " + alias_fn(idx) + "(" + reg_call_args("%env", vals) + ")")
    f.e("ret " + pair_ty + " " + r)
    None
  }
  emit_function("define " + pair_ty + " " + filler_fn(idx, k) + "(" + fwd_params + ")", f)
}

// entry points: called with n of the alias's arguments in an array
fn entry_fn(idx : Int) -> String {
  request(idx, ".w", "declare i64 ", "(ptr, i64)", fn() { gen_entry(idx) })
}

fn gen_entry(idx : Int) -> Unit {
  let a = aliases[idx]
  let name = "@\"" + stable_names[idx] + ".w\""
  let f = Fun::new(0, false)
  f.ret_pair = false
  f.block("L0")
  if a.nparams == 0 {
    let _ = push_and_call(f, idx, 0, "%args")
  } else {
    let labels : Array[String] = []
    for _k in 0..<a.nparams {
      labels.push(f.l())
    }
    let lfull = f.l()
    let sw = StringBuilder::new()
    sw.write_string("switch i64 %n, label %" + lfull + " [")
    for k in 0..<a.nparams {
      sw.write_string(" i64 \{k}, label %" + labels[k])
    }
    sw.write_string(" ]")
    f.e(sw.to_string())
    for k in 0..<a.nparams {
      f.block(labels[k])
      let _ = push_and_call(f, idx, k, "%args")
    }
    f.block(lfull)
    let _ = push_and_call(f, idx, a.nparams, "%args")
  }
  emit_function("define i64 " + name + "(ptr %args, i64 %n)", f)
}
