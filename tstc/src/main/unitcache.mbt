// The unit cache: a unit's text is reused from an earlier build when what it
// is generated from has not changed, without generating it again.
//
// A unit is generated from its alias (its Code, frame size, parameters,
// defaults, native id, name), the inlining decisions of its conditionals,
// what it knows of the aliases it calls (their names, parameter counts,
// frame sizes, native ids), the compiler itself and its flags. Its key is a
// hash of these. A build records each unit's text (in a blob file, appended
// to) and the symbols it refers to (in an index file, rewritten); the next
// build replays the references of a unit whose key it finds (requesting the
// units it calls, marking the constants it uses) instead of generating it.
// A module's object is then found by a key made of its units' keys, and a
// unit's text is only read when its module must be compiled again.
// --cache-verify generates the cached units anyway and compares.

// what the key of every unit includes: the compiler and its flags
let unit_salt : Ref[String] = Ref::new("")

let unit_cache_on : Ref[Bool] = Ref::new(false)

let unit_cache_verify : Ref[Bool] = Ref::new(false)

// files: <dir>/units-<tag>.idx, .blob, consts-<tag>-<bucket>.ll
let unit_cache_base : Ref[String] = Ref::new("")

// ---------------------------------------------------------------------------
// Keys

// two 64-bit FNV-1a lanes over integers
struct Hasher {
  mut a : Int64
  mut b : Int64
}

fn Hasher::new() -> Hasher {
  { a: 0xCBF29CE484222325UL.reinterpret_as_int64(), b: 0x84222325CBF29CE4UL.reinterpret_as_int64() }
}

fn Hasher::int(self : Hasher, x : Int) -> Unit {
  let v = x.to_int64()
  self.a = (self.a ^ v) * 0x100000001B3L
  self.b = (self.b ^ v) * 0x9E3779B97F4A7C15UL.reinterpret_as_int64()
  self.b = self.b ^ self.b.reinterpret_as_uint64().lsr(29).reinterpret_as_int64()
}

fn Hasher::i64(self : Hasher, x : Int64) -> Unit {
  self.int(x.to_int())
  self.int((x >> 32).to_int())
}

fn Hasher::bool(self : Hasher, x : Bool) -> Unit {
  self.int(if x { 1 } else { 0 })
}

fn Hasher::str(self : Hasher, s : String) -> Unit {
  self.int(s.length())
  for i in 0..<s.length() {
    self.int(s.unsafe_charcode_at(i))
  }
}

fn Hasher::sstr(self : Hasher, s : Str) -> Unit {
  self.int(s.len)
  for i in 0..<s.len {
    self.int(s.at(i))
  }
}

fn Hasher::hex(self : Hasher) -> String {
  hex_digits(self.a, 16) + hex_digits(self.b, 16)
}

fn Hasher::ty(self : Hasher, t : Ty) -> Unit {
  match t {
    TAny => self.int(1)
    TUnknown => self.int(2)
    TNever => self.int(3)
    TString => self.int(4)
    TNumber => self.int(5)
    TBigInt => self.int(6)
    TSymbol => self.int(7)
    TObjectKw => self.int(8)
    TNull => self.int(9)
    TUndefined => self.int(10)
    TVoid => self.int(11)
    TTrue => self.int(12)
    TFalse => self.int(13)
    TStrLit(s) => {
      self.int(14)
      self.sstr(s)
    }
    TNumLit(d) => {
      self.int(15)
      self.i64(d.reinterpret_as_int64())
    }
    TBigLit(s) => {
      self.int(16)
      self.str(s)
    }
    TInt(v) => {
      self.int(17)
      self.i64(v)
    }
    TUnion(ms) => {
      self.int(18)
      self.int(ms.length())
      for m in ms {
        self.ty(m)
      }
    }
  }
}

// what code generation knows of a called alias
fn Hasher::callee(self : Hasher, idx : Int) -> Unit {
  let a = aliases[idx]
  self.str(stable_names[idx])
  self.int(a.nparams)
  self.int(a.frame)
  self.int(a.native)
  match catch_of.get(idx) {
    Some(h) => self.str("catch " + stable_names[h])
    None => ()
  }
}

fn Hasher::codes(self : Hasher, cs : Array[Code]) -> Unit {
  self.int(cs.length())
  for c in cs {
    self.code(c)
  }
}

fn Hasher::opt(self : Hasher, c : Code?) -> Unit {
  match c {
    Some(x) => {
      self.int(1)
      self.code(x)
    }
    None => self.int(0)
  }
}

fn Hasher::params(self : Hasher, ps : Array[CParam]) -> Unit {
  self.int(ps.length())
  for p in ps {
    self.sstr(p.name)
    self.code(p.code)
    self.bool(p.optional)
    self.bool(p.rest)
  }
}

fn Hasher::ints(self : Hasher, xs : Array[Int]) -> Unit {
  self.int(xs.length())
  for x in xs {
    self.int(x)
  }
}

fn Hasher::code(self : Hasher, c : Code) -> Unit {
  match c {
    CTy(t) => {
      self.int(101)
      self.ty(t)
    }
    CSlot(i) => {
      self.int(102)
      self.int(i)
    }
    CCall(idx, args) => {
      self.int(103)
      self.callee(idx)
      self.codes(args)
    }
    CUnion(cs) => {
      self.int(104)
      self.codes(cs)
    }
    CInter(cs) => {
      self.int(105)
      self.codes(cs)
    }
    CCond(cd) => {
      self.int(106)
      self.code(cd.check)
      self.code(cd.ext)
      match cd.pat {
        Some(p) => {
          self.int(1)
          self.pat(p)
        }
        None => self.int(0)
      }
      self.code(cd.t)
      self.code(cd.f)
      self.int(cd.dist_slot)
      self.ints(cd.infer_slots)
      self.int(cd.fast)
      self.ints(cd.fslots)
      self.int(
        match inline_conds.get(cd.id) {
          Some(true) => 1
          Some(false) => 0
          None => 2
        },
      )
    }
    CTuple(elems, ro) => {
      self.int(107)
      self.int(elems.length())
      for e in elems {
        self.code(e.code)
        self.int(e.kind)
        match e.name {
          Some(n) => {
            self.int(1)
            self.sstr(n)
          }
          None => self.int(0)
        }
      }
      self.bool(ro)
    }
    CArray(x, ro) => {
      self.int(108)
      self.code(x)
      self.bool(ro)
    }
    CObj(oc) => {
      self.int(109)
      self.int(oc.props.length())
      for p in oc.props {
        self.sstr(p.0)
        self.code(p.1)
        self.bool(p.2)
        self.bool(p.3)
        self.bool(p.4)
      }
      self.int(oc.index.length())
      for ix in oc.index {
        self.code(ix.0)
        self.code(ix.1)
        self.bool(ix.2)
      }
      self.int(oc.calls.length())
      for cl in oc.calls {
        self.params(cl.0)
        self.code(cl.1)
        self.bool(cl.2)
      }
    }
    CMapped(mc) => {
      self.int(110)
      self.int(mc.slot)
      self.code(mc.constraint)
      self.opt(mc.homo)
      self.opt(mc.mods)
      self.opt(mc.as_clause)
      self.code(mc.body)
      self.int(mc.ro)
      self.int(mc.opt)
      self.bool(mc.kof)
      self.int(mc.homo_slot)
    }
    CIndex(o, k) => {
      self.int(111)
      self.code(o)
      self.code(k)
    }
    CKeyof(x) => {
      self.int(112)
      self.code(x)
    }
    CTpl(texts, cs) => {
      self.int(113)
      self.int(texts.length())
      for t in texts {
        self.sstr(t)
      }
      self.codes(cs)
    }
    CFn(params, ret, ctor) => {
      self.int(114)
      self.params(params)
      self.code(ret)
      self.bool(ctor)
    }
    CGenericFn(slots, body) => {
      self.int(115)
      self.ints(slots)
      self.code(body)
    }
    CUniqueSym(id) => {
      self.int(116)
      self.int(id)
    }
    CNative(idx, id, args) => {
      self.int(117)
      self.int(id)
      self.int(aliases[idx].nparams)
      self.codes(args)
    }
    CLet(slot, v, body) => {
      self.int(118)
      self.int(slot)
      self.code(v)
      self.code(body)
    }
  }
}

fn Hasher::pat(self : Hasher, p : Pat) -> Unit {
  match p {
    PCode(c) => {
      self.int(201)
      self.code(c)
    }
    PInfer(slot, cons) => {
      self.int(202)
      self.int(slot)
      self.opt(cons)
    }
    PTuple(elems, ro) => {
      self.int(203)
      self.int(elems.length())
      for e in elems {
        self.pat(e.pat)
        self.int(e.kind)
      }
      self.bool(ro)
    }
    PArray(sub, ro) => {
      self.int(204)
      self.pat(sub)
      self.bool(ro)
    }
    PObj(props) => {
      self.int(205)
      self.int(props.length())
      for pp in props {
        self.sstr(pp.name)
        self.pat(pp.pat)
        self.bool(pp.optional)
      }
    }
    PTpl(texts, pats) => {
      self.int(206)
      self.int(texts.length())
      for t in texts {
        self.sstr(t)
      }
      self.int(pats.length())
      for x in pats {
        self.pat(x)
      }
    }
    PFn(params, ret) => {
      self.int(207)
      self.int(params.length())
      for x in params {
        self.pat(x.pat)
        self.int(x.kind)
      }
      self.pat(ret)
    }
    PUnion(pats) => {
      self.int(208)
      self.int(pats.length())
      for x in pats {
        self.pat(x)
      }
    }
    PVal(c, infs) => {
      self.int(209)
      self.code(c)
      self.int(infs.length())
      for x in infs {
        self.pat(x.pat)
        self.int(x.kind)
      }
    }
  }
}

let alias_keys : Map[Int, String] = Map::new()

// the key of a unit: part of alias idx
fn unit_key(idx : Int, part : String) -> String {
  if !alias_keys.contains(idx) {
    // (a stub whose key is not known: compiled, incr.mbt)
    incr_ensure(idx)
  }
  let ak = match alias_keys.get(idx) {
    Some(k) => k
    None => {
      let h = Hasher::new()
      let a = aliases[idx]
      h.callee(idx)
      h.str(a.name)
      h.int(a.defaults.length())
      for d in a.defaults {
        h.opt(d)
      }
      h.code(a.body)
      // a memoized alias's code names its index (rt_memo_get)
      if memo_body.contains(idx) {
        h.int(-1)
        h.int(idx)
      }
      let k = h.hex()
      alias_keys.set(idx, k)
      k
    }
  }
  let h = Hasher::new()
  h.str(unit_salt.val)
  h.str(ak)
  h.str(part)
  h.hex()
}

// ---------------------------------------------------------------------------
// The previous build's units

struct UnitRec {
  off : Int64
  len : Int64
  // (where in the index: read when replayed)
  refs_s : Int
  refs_e : Int
}

// the previous build's index
let prev_index : Ref[Bytes] = Ref::new(b"")

let prev_units : Map[String, UnitRec] = Map::new()

#borrow(path)
extern "c" fn c_file_size(path : Bytes) -> Int64 = "tstc_file_size"

extern "c" fn c_self_hash() -> Bytes = "tstc_self_hash"

#borrow(path)
extern "c" fn c_blob_read(path : Bytes, off : Int64, len : Int64) -> Int = "tstc_blob_read"

#borrow(path)
extern "c" fn c_blob_append(path : Bytes, h : Int) -> Int64 = "tstc_blob_append"

#borrow(a, b)
extern "c" fn c_rename(a : Bytes, b : Bytes) -> Int = "tstc_rename"

fn blob_path() -> String {
  unit_cache_base.val + ".blob"
}

fn index_path() -> String {
  unit_cache_base.val + ".idx"
}

fn consts_path(b : Int) -> String {
  unit_cache_base.val + ".consts" + b.to_string() + ".ll"
}

// reads the index of the previous build (nothing when it was made by
// another compiler or with other flags)
fn load_unit_index() -> Unit {
  if !unit_cache_on.val {
    return
  }
  let blob_size = c_file_size(path_bytes(blob_path()))
  let b = match read_bytes(index_path()) {
    Some(b) => b
    None => return
  }
  let n = b.length()
  let e0 = line_end(b, 0)
  if c_utf8_slice(b, 0, e0) != "tstc-units 1 " + unit_salt.val {
    return
  }
  prev_index.val = b
  let f : Array[Int] = []
  let mut p = e0 + 1
  while p < n {
    let e = line_end(b, p)
    let s = p
    p = e + 1
    if e - s < 2 || b[s + 1] != b'\t' {
      continue
    }
    fields_at(b, s, e, b'\t', f)
    let nf = f.length() / 2
    if b[s] == b'S' && nf == 3 {
      let name = c_utf8_slice(b, f[2], f[3])
      if !declared.contains(name) {
        declared.set(name, c_utf8_slice(b, f[4], f[5]))
      }
    } else if b[s] == b'U' && nf >= 4 {
      let off = int64_at(b, f[4], f[5])
      let len = int64_at(b, f[6], f[7])
      if off < 0L || len < 0L || off + len > blob_size {
        continue
      }
      let (rs, re) = if nf > 4 { (f[8], f[9]) } else { (0, 0) }
      prev_units.set(c_utf8_slice(b, f[2], f[3]), { off, len, refs_s: rs, refs_e: re })
    }
  }
}

// the references of a unit of the previous build
fn UnitRec::refs(self : UnitRec) -> Array[String] {
  let b = prev_index.val
  let out : Array[String] = []
  let mut i = self.refs_s
  while i < self.refs_e {
    let mut k = i
    while k < self.refs_e && b[k] != b' ' {
      k += 1
    }
    if k > i {
      out.push(c_utf8_slice(b, i, k))
    }
    i = k + 1
  }
  out
}

// the names of the constants in the store of the last build (data_modules_out),
// read when a cached unit's reference to one is replayed
let stored_consts : Map[String, Bool] = Map::new()

let stored_consts_read : Ref[Bool] = Ref::new(false)

fn stored_const(name : String) -> Bool {
  if !stored_consts_read.val {
    stored_consts_read.val = true
    for k in 0..<data_modules {
      match read_bytes(consts_path(k)) {
        Some(b) => {
          let n = b.length()
          let mut p = 0
          while p < n {
            let e = line_end(b, p)
            if e > p && b[p] == b'@' {
              let mut q = p
              while q < e && b[q] != b' ' {
                q += 1
              }
              stored_consts.set(c_utf8_slice(b, p, q), true)
            }
            p = e + 1
          }
        }
        None => ()
      }
    }
  }
  stored_consts.contains(name)
}

// the index of the stable names
let name_index : Map[String, Int] = Map::new()

// a reference of a cached unit, made again: requests the part of an alias
// it refers to (false: it names no part of this program)
fn replay_ref(r : String) -> Bool {
  if generated.contains(r) {
    // (an alias part requested already)
    let _ = uref(r)
    return true
  }
  if r.has_prefix("@\"") {
    let inner = r.unsafe_substring(start=2, end=r.length() - 1)
    let (sn, part) = match inner.find(".") {
      Some(i) => (inner.unsafe_substring(start=0, end=i), inner.unsafe_substring(start=i, end=inner.length()))
      None => (inner, "")
    }
    let idx = match name_index.get(sn) {
      Some(i) => i
      None => return false
    }
    if part == "" {
      let _ = alias_fn(idx)
    } else if part == ".c" {
      let _ = const_fn(idx)
    } else if part == ".w" {
      let _ = entry_fn(idx)
    } else if part.has_prefix(".d") {
      let k = match (try? @strconv.parse_int(part.unsafe_substring(start=2, end=part.length()))) {
        Ok(k) => k
        Err(_) => return false
      }
      let _ = filler_fn(idx, k)
    } else {
      return false
    }
  } else if r.has_prefix("@k") || r.has_prefix("@s") {
    // (a constant defined neither now nor in the store of the last build: an
    // interrupted build left the index and the store out of step)
    if !shared.contains(r) && !stored_const(r) {
      return false
    }
    if !sym_decls.contains(r) {
      sym_decls.set(r, r + " = external hidden global i8")
    }
    let _ = uref(r)
  } else {
    if !declared.contains(r) {
      return false
    }
    let _ = uref(r)
  }
  true
}

// the units' texts generated now, appended to the blob; the index of all
fn save_unit_index(units : Array[GenUnit]) -> Unit {
  if !unit_cache_on.val {
    return
  }
  let blob = blob_path()
  // a blob holding mostly texts no build uses any more is copied anew
  let mut live = 0L
  for u in units {
    live += u.len
  }
  let size = c_file_size(path_bytes(blob))
  if size > live * 2L + (64L << 20) {
    let tmp = blob + ".new"
    let _ = c_rename(path_bytes(blob), path_bytes(tmp))
    for u in units {
      match u.cached {
        Some((off, len)) => {
          let h = c_blob_read(path_bytes(tmp), off, len)
          if h >= 0 {
            let o = c_blob_append(path_bytes(blob), h)
            c_buf_free(h)
            u.cached = if o >= 0L { Some((o, len)) } else { None }
          } else {
            u.cached = None
          }
        }
        None => ()
      }
    }
    let _ = c_system(path_bytes("rm -f '" + tmp + "'"))
  }
  let idx = c_buf_new()
  c_buf_str(idx, "tstc-units 1 " + unit_salt.val + "\n")
  declared.each(fn(name, sig) { c_buf_str(idx, "S\t" + name + "\t" + sig + "\n") })
  for u in units {
    let at = match u.cached {
      Some((off, _)) => off
      None =>
        if u.buf >= 0 {
          let o = c_blob_append(path_bytes(blob), u.buf)
          if o >= 0L {
            u.cached = Some((o, u.len))
          }
          o
        } else {
          -1L
        }
    }
    if at < 0L || u.key == "" {
      continue
    }
    let sb = StringBuilder::new()
    sb.write_string("U\t" + u.key + "\t" + at.to_string() + "\t" + u.len.to_string() + "\t")
    let mut first = true
    u.refs.each(fn(r, _v) {
      if !first {
        sb.write_char(' ')
      }
      first = false
      sb.write_string(r)
    })
    sb.write_char('\n')
    c_buf_str(idx, sb.to_string())
  }
  let tmp = index_path() + ".new"
  if c_bufs_write(FixedArray::from_array([idx]), path_bytes(tmp)) != 0 {
    let _ = c_rename(path_bytes(tmp), path_bytes(index_path()))
  }
  c_buf_free(idx)
  c_touch(path_bytes(blob))
}
