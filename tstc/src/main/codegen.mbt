// LLVM IR generation: every type alias becomes a native function.
//
// Values are 64-bit words (rt/tstc.h). The slots of an alias live in a frame
// on the environment stack (a stack of words beside the native one, whose
// top is the runtime's tstc_top); every generated function takes its frame,
// `i64 f(ptr env)`, so calls in tail position are musttail jumps and
// recursion written as iteration runs in constant space. A conditional is a
// function of its own: it computes its check type, takes the fast paths the
// shapes of its values allow (shape.mbt), and otherwise asks the runtime with a
// descriptor whose parts are again functions of the frame. Each part of a
// program is compiled once (the leaves of conditionals twice).
//
// A frame is owned by the code running in it when it ends at the top of the
// stack: a tail call then reuses it. Code evaluating a part of a frame that
// others still use (a conditional nested in an expression, a thunk the
// runtime calls) runs with the top moved past the frame, so its tail calls
// take a fresh frame instead.

// text buffers outside the MoonBit heap (stub.c)
extern "c" fn c_buf_new() -> Int = "tstc_buf_new"

#borrow(s)
extern "c" fn c_buf_str(h : Int, s : String) = "tstc_buf_str"

extern "c" fn c_buf_buf(dst : Int, src : Int) = "tstc_buf_buf"

// "  " s "\n"
#borrow(s)
extern "c" fn c_buf_line(h : Int, s : String) = "tstc_buf_line"

extern "c" fn c_buf_len(h : Int) -> Int64 = "tstc_buf_len"

extern "c" fn c_max_rss_mb() -> Int = "tstc_max_rss_mb"

extern "c" fn c_buf_stats() = "tstc_buf_stats"

extern "c" fn c_buf_free(h : Int) = "tstc_buf_free"

// the hex SHA-256 (128 bits) of salt and the buffers' text
#borrow(hs, salt)
extern "c" fn c_bufs_hash(hs : FixedArray[Int], salt : Bytes) -> Bytes = "tstc_bufs_hash"

#borrow(hs, path)
extern "c" fn c_bufs_write(hs : FixedArray[Int], path : Bytes) -> Int = "tstc_bufs_write"

// a module's buffers (but the prelude) are freed
fn free_module(m : Array[Int]) -> Unit {
  for h in m {
    if h != prelude_buf.val {
      c_buf_free(h)
    }
  }
}

#borrow(path)
extern "c" fn c_touch(path : Bytes) = "tstc_touch"

#borrow(path)
extern "c" fn c_mkdir(path : Bytes) = "tstc_mkdir"

// kinds and immediate values (rt/tstc.h)

let v_any : String = "2"

let v_unknown : String = "10"

let v_never : String = "18"

let v_null : String = "66"

let v_undefined : String = "74"

let v_true : String = "90"

let v_false : String = "98"

fn imm_of(k : Int) -> String {
  (k * 8 + 2).to_string()
}

// ---------------------------------------------------------------------------
// Units
//
// Code is generated in units: one part of one alias (its function, its value
// when it has no parameters, a filler of missing arguments, an entry point) with the functions and descriptors only it uses.
// The names a unit defines derive from its alias's name and the unit's own
// counters, and the constants units share are named by a hash of their
// definitions, so the text of a unit depends only on what it compiles: an
// unchanged alias gives the same text in every build (given what it knows
// of the others: their names, frame sizes and shapes).
//
// Names: an alias is @"N" (N: its name, "file/N" outside the main file, a
// suffix ~k when names collide), its parts @"N.c" (value), @"N.dK" (filler
// of K arguments), @"N.w" (entry); what a unit
// keeps to itself is @"P:Tk", @"P:Ck" (functions) and @"P:Dk" (data) after
// its own name P; shared constants are @k<hash>, strings @s<hash>.

struct GenUnit {
  prefix : String
  mut buf : Int
  // its globals (uw), put after its functions: LLVM's parser resolves a
  // reference to what comes later through a placeholder, and replacing
  // one inside a large constant costs the constant's size each time
  mut dbuf : Int
  // the symbols its text refers to (a superset), and the one it defines
  // for the others
  refs : Map[String, Bool]
  defs : Array[String]
  pending : Array[() -> Unit]
  fn_names : Map[String, String]
  descs : Map[String, String]
  locals : Map[String, String]
  mut nfn : Int
  mut nglob : Int
  // the unit cache: its key, where its text is in the blob, its length
  mut key : String
  mut cached : (Int64, Int64)?
  mut len : Int64
}

fn GenUnit::new(prefix : String) -> GenUnit {
  GenUnit::with_buf(prefix, c_buf_new())
}

// (buf -1: the text is in the blob)
fn GenUnit::with_buf(prefix : String, buf : Int) -> GenUnit {
  {
    prefix,
    buf,
    dbuf: -1,
    refs: Map::new(),
    defs: [],
    pending: [],
    fn_names: Map::new(),
    descs: Map::new(),
    locals: Map::new(),
    nfn: 0,
    nglob: 0,
    key: "",
    cached: None,
    len: 0L,
  }
}

// its text (read from the blob when not generated now)
fn GenUnit::text(self : GenUnit) -> Int {
  if self.buf < 0 {
    match self.cached {
      Some((off, len)) => {
        let h = c_blob_read(path_bytes(blob_path()), off, len)
        if h < 0 {
          die("tstc: the unit cache's blob cannot be read (" + blob_path() + "); build with --no-cache")
        }
        self.buf = h
      }
      None => abort("a unit without text")
    }
  }
  self.buf
}

let cur_unit : Ref[GenUnit?] = Ref::new(None)

fn cu() -> GenUnit {
  match cur_unit.val {
    Some(u) => u
    None => abort("code generation outside of a unit")
  }
}

// a symbol the current unit refers to
fn uref(sym : String) -> String {
  match cur_unit.val {
    Some(u) => u.refs.set(sym, true)
    None => ()
  }
  sym
}

// globals of the current unit
fn uw(s : String) -> Unit {
  let u = cu()
  if u.dbuf < 0 {
    u.dbuf = c_buf_new()
  }
  c_buf_str(u.dbuf, s)
}

// the unit's globals after its functions
fn GenUnit::finish_text(self : GenUnit) -> Unit {
  if self.dbuf >= 0 {
    c_buf_buf(self.buf, self.dbuf)
    c_buf_free(self.dbuf)
    self.dbuf = -1
  }
}

// the declarations of the symbols units define, for the modules using them
let sym_decls : Map[String, String] = Map::new()

// the runtime's functions: their signatures
let declared : Map[String, String] = Map::new()

fn declare(name : String, sig : String) -> Unit {
  if !declared.contains(name) {
    declared.set(name, sig)
  }
  let _ = uref(name)

}

// the units to generate: alias, part, the symbol, the job
let unit_queue : Array[(Int, String, String, () -> Unit)] = []

let generated : Map[String, Bool] = Map::new()

// the units of each alias, by part
let alias_units : Map[Int, Array[(String, GenUnit)]] = Map::new()

fn request(idx : Int, part : String, pre : String, post : String, job : () -> Unit) -> String {
  let name = "@\"" + stable_names[idx] + part + "\""
  if !generated.contains(name) {
    generated.set(name, true)
    sym_decls.set(name, pre + name + post)
    unit_queue.push((idx, part, name, job))
  }
  uref(name)
}

fn safe_name(s : String) -> String {
  let sb = StringBuilder::new()
  for ch in s {
    if (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') ||
      ch == '_' || ch == '$' {
      sb.write_char(ch)
    } else {
      sb.write_char('_')
    }
  }
  sb.to_string()
}

// the names of the aliases in the generated code (see above)
let stable_names : Array[String] = []

let main_file : Ref[String] = Ref::new("")

fn assign_stable_names() -> Unit {
  let used : Map[String, Bool] = Map::new()
  for a in aliases {
    let base = if a.file == main_file.val {
      safe_name(a.name)
    } else {
      let f = base_name(a.file)
      let f = if f.has_suffix(".ts") { f.unsafe_substring(start=0, end=f.length() - 3) } else { f }
      safe_name(f) + "/" + safe_name(a.name)
    }
    let mut n = base
    let mut k = 1
    while used.contains(n) {
      n = base + "~" + k.to_string()
      k += 1
    }
    used.set(n, true)
    stable_names.push(n)
  }
}

fn alias_fn(idx : Int) -> String {
  request(idx, "", "declare " + pair_ty + " ", frame_proto(), fn() { gen_alias(idx) })
}

fn const_fn(idx : Int) -> String {
  request(idx, ".c", "declare i64 ", "()", fn() { gen_const(idx) })
}

fn filler_fn(idx : Int, k : Int) -> String {
  request(idx, ".d" + k.to_string(), "declare " + pair_ty + " ", frame_proto(), fn() {
    gen_filler(idx, k)
  })
}

// FNV-1a over the code units
fn fnv64(s : String) -> Int64 {
  let mut h = 0xCBF29CE484222325UL.reinterpret_as_int64()
  for i in 0..<s.length() {
    h = (h ^ s.unsafe_charcode_at(i).to_int64()) * 0x100000001B3L
  }
  h
}

fn hex_digits(v : Int64, n : Int) -> String {
  let digits = "0123456789abcdef"
  let u = v.reinterpret_as_uint64()
  let sb = StringBuilder::new()
  let mut sh = n * 4 - 4
  while sh >= 0 {
    sb.write_char(digits.unsafe_char_at(((u >> sh) & 15UL).to_int()))
    sh -= 4
  }
  sb.to_string()
}

// ---------------------------------------------------------------------------
// Modules: runs of aliases in source order, cut where an alias's name hashes
// to a cut point once a module has min_module characters (or past
// max_module), so that a change moves no boundary but nearby ones; the
// shared constants by hash in data_modules modules.

let module_limit : Ref[Int] = Ref::new(3000000)

let data_modules : Int = 16

// constants shared by units: name -> (hash, definition, whether it may
// refer to other symbols)
let shared : Map[String, (Int64, String, Bool)] = Map::new()

let out_base : Ref[String] = Ref::new("")

// symbols every module of functions has (llvm_prelude)
let prelude_syms : Array[String] = [
  "@tstc_top", "@rt_tuple2", "@rt_tuple1", "@rt_tup_fastok", "@tstc_store0", "@tstc_zero16", "@n_hget",
  "@n_hset", "@n_tget", "@n_sidx", "@n_geq", "@n_gne", "@tstc_hget", "@tstc_hset", "@store_freeze", "@tstc_tget", "@tstc_sidx", "@n_hgetf", "@n_hgets", "@tstc_hgetf", "@tstc_hgets", "@tstc_hsets", "@n_hsets", "@tstc_slen", "@tstc_sat", "@n_slen", "@n_sat", "@tstc_hload2", "@n_hloadt", "@tstc_pget",
  "@tstc_fadd", "@n_fadd", "@tstc_fsub", "@n_fsub", "@tstc_fmul", "@n_fmul", "@tstc_fdiv", "@n_fdiv", "@tstc_feq", "@n_feq", "@tstc_fne", "@n_fne", "@tstc_flt", "@n_flt", "@tstc_fle", "@n_fle", "@tstc_fneg", "@n_fneg", "@tstc_ffloor", "@n_ffloor", "@tstc_i2f", "@n_i2f", "@tstc_f2i", "@n_f2i", "@tstc_isnan", "@n_isnan", "@llvm.floor.f64", "@llvm.fabs.f64",
  "@tstc_geq", "@tstc_gne", "@n_ta1", "@n_ta2", "@tstc_ta", "@tstc_ta1", "@tstc_ta2", "@n_nilchk", "@tstc_nilchk", "@tstc_box", "@tstc_kind", "@tstc_plain1",
  "@tstc_distributes", "@tstc_tuplen", "@tstc_notnull", "@tstc_memo_off",
]

// the symbols text refers to
fn scan_refs(s : String, refs : Map[String, Bool]) -> Unit {
  let n = s.length()
  let mut i = 0
  while i < n {
    if s.unsafe_charcode_at(i) == '@'.to_int() {
      let st = i
      i += 1
      if i < n && s.unsafe_charcode_at(i) == '"'.to_int() {
        i += 1
        while i < n && s.unsafe_charcode_at(i) != '"'.to_int() {
          i += 1
        }
        i += 1
      } else {
        while i < n {
          let c = s.unsafe_charcode_at(i)
          if (c >= 'a'.to_int() && c <= 'z'.to_int()) || (c >= 'A'.to_int() && c <= 'Z'.to_int()) ||
            (c >= '0'.to_int() && c <= '9'.to_int()) || c == '_'.to_int() || c == '.'.to_int() ||
            c == '$'.to_int() {
            i += 1
          } else {
            break
          }
        }
      }
      refs.set(s.unsafe_substring(start=st, end=i), true)
    } else {
      i += 1
    }
  }
}

// the declarations of what a module refers to and does not define, sorted
fn module_decls(refs : Map[String, Bool], defined : Map[String, Bool]) -> String {
  let syms : Array[String] = []
  refs.each(fn(sym, _x) {
    if !defined.contains(sym) && !prelude_syms.contains(sym) && !sym.has_prefix("@llvm.") {
      syms.push(sym)
    }
  })
  syms.sort()
  let sb = StringBuilder::new()
  for sym in syms {
    match declared.get(sym) {
      Some(sig) => {
        sb.write_string("declare ")
        sb.write_string(sig)
      }
      None =>
        match sym_decls.get(sym) {
          Some(d) => sb.write_string(d)
          None => abort("no declaration of " + sym)
        }
    }
    sb.write_char('\n')
  }
  sb.to_string()
}

// the text every module of functions starts with
let prelude_buf : Ref[Int] = Ref::new(-1)

// a module's text: buffers one after the other (not copied into one)
fn module_of_units(units : Array[GenUnit]) -> Array[Int] {
  if prelude_buf.val < 0 {
    prelude_buf.val = c_buf_new()
    c_buf_str(prelude_buf.val, llvm_prelude)
  }
  // (the declarations first: no reference to them is a placeholder)
  let refs : Map[String, Bool] = Map::new()
  let defined : Map[String, Bool] = Map::new()
  for u in units {
    for d in u.defs {
      defined.set(d, true)
    }
    u.refs.each(fn(k, _v) { refs.set(k, true) })
  }
  let d = c_buf_new()
  c_buf_str(d, module_decls(refs, defined))
  let m = [prelude_buf.val, d]
  for u in units {
    m.push(u.text())
  }
  m
}

// the bucket of a shared constant: by its hash (in its name)
fn shared_bucket(name : String) -> Int {
  let mut v = 0UL
  for i in 2..<18 {
    if i >= name.length() {
      break
    }
    let c = name.unsafe_charcode_at(i)
    let d = if c >= '0'.to_int() && c <= '9'.to_int() { c - '0'.to_int() } else { c - 'a'.to_int() + 10 }
    v = v * 16UL + d.to_uint64()
  }
  (v % data_modules.to_uint64()).to_int()
}

// the modules of the shared constants the units use. A module's key is its
// constants' names (hashes of their definitions). The definitions come from
// this build, or from the store of the last build (a file per module, kept
// up to date: the units of the last build use only what it has)
fn data_modules_out(units : Array[GenUnit]) -> Array[ModOut] {
  let parts : Array[Map[String, Bool]] = Array::makei(data_modules, fn(_i) { Map::new() })
  for u in units {
    u.refs.each(fn(r, _v) {
      if r.has_prefix("@k") || r.has_prefix("@s") {
        parts[shared_bucket(r)].set(r, true)
      }
    })
  }
  Array::makei(data_modules, fn(b) {
    let names = parts[b].keys().collect()
    names.sort()
    let sb = StringBuilder::new()
    sb.write_string("constants " + unit_salt.val + "\n")
    for n in names {
      sb.write_string(n)
      sb.write_char('\n')
    }
    let key = sb.to_string()
    let kh = Hasher::new()
    kh.str(key)
    let header = "; constants " + kh.hex() + "\n"
    // the definitions, one after the other
    let defs_of = fn() {
      let stored : Map[String, String] = Map::new()
      let mut loaded = false
      let d : Array[String] = []
      for n in names {
        let def = match shared.get(n) {
          Some((_, def, _)) => def
          None => {
            if !loaded {
              loaded = true
              match read_file(consts_path(b)) {
                Some(t) =>
                  for line in t.split("\n") {
                    let l = line.to_string()
                    if !l.has_prefix(";") {
                      match l.find(" ") {
                        Some(k) => stored.set(l.unsafe_substring(start=0, end=k), l + "\n")
                        None => ()
                      }
                    }
                  }
                None => ()
              }
            }
            match stored.get(n) {
              Some(x) => x
              None => die("tstc: the unit cache has no constant " + n + " (" + consts_path(b) + "); build with --no-cache")
            }
          }
        }
        d.push(def)
      }
      d
    }
    let mut defs : Array[String]? = None
    if unit_cache_on.val {
      let old = c_blob_read(path_bytes(consts_path(b)), 0L, header.length().to_int64())
      let same = old >= 0 &&
        c_bufs_hash(FixedArray::from_array([old]), b"") == {
          let hb = c_buf_new()
          c_buf_str(hb, header)
          let x = c_bufs_hash(FixedArray::from_array([hb]), b"")
          c_buf_free(hb)
          x
        }
      if old >= 0 {
        c_buf_free(old)
      }
      if !same {
        let d = defs_of()
        defs = Some(d)
        let hb = c_buf_new()
        c_buf_str(hb, header)
        for x in d {
          c_buf_str(hb, x)
        }
        let tmp = consts_path(b) + ".new"
        if c_bufs_write(FixedArray::from_array([hb]), path_bytes(tmp)) != 0 {
          let _ = c_rename(path_bytes(tmp), path_bytes(consts_path(b)))
        }
        c_buf_free(hb)
      }
    }
    let make = fn() {
      let d = match defs {
        Some(d) => d
        None => defs_of()
      }
      let m = c_buf_new()
      c_buf_str(m, "; generated by tstc (constants)\n")
      let refs : Map[String, Bool] = Map::new()
      let defined : Map[String, Int] = Map::new()
      let own_refs : Array[Array[String]] = []
      for k in 0..<names.length() {
        defined.set(names[k], k)
      }
      for k in 0..<names.length() {
        // (strings' bytes may have an @)
        let r : Map[String, Bool] = Map::new()
        if names[k].has_prefix("@k") {
          scan_refs(d[k], r)
        }
        let own : Array[String] = []
        r.each(fn(x, _v) {
          refs.set(x, true)
          if defined.contains(x) && x != names[k] {
            own.push(x)
          }
        })
        own.sort()
        own_refs.push(own)
      }
      let defs_set : Map[String, Bool] = Map::new()
      defined.each(fn(n, _k) { defs_set.set(n, true) })
      // the declarations, then each definition after those it refers to
      c_buf_str(m, module_decls(refs, defs_set))
      let state = Array::make(names.length(), 0)
      fn visit(k : Int) -> Unit {
        if state[k] != 0 {
          return
        }
        state[k] = 1
        for x in own_refs[k] {
          visit(defined.get(x).unwrap())
        }
        state[k] = 2
        c_buf_str(m, d[k])
      }
      for k in 0..<names.length() {
        visit(k)
      }
      [m]
    }
    { key: if unit_cache_on.val { key } else { "" }, make }
  })
}

// the units in modules: runs of aliases in source order
fn function_modules() -> Array[ModOut] {
  let min = module_limit.val / 2
  let max = module_limit.val * 2
  let mods : Array[ModOut] = []
  let cur : Array[GenUnit] = []
  let mut acc = 0L
  let close = fn() {
    let us = cur.copy()
    // the key: its units' keys (when each has one)
    let sb = StringBuilder::new()
    sb.write_string("functions\n")
    for u in us {
      if u.key == "" {
        sb.reset()
        break
      }
      sb.write_string(u.key)
      sb.write_char('\n')
    }
    let key = sb.to_string()
    mods.push({ key, make: fn() { module_of_units(us) } })
    cur.clear()
  }
  for idx in 0..<aliases.length() {
    match alias_units.get(idx) {
      Some(list) => {
        list.sort_by(fn(a, b) { a.0.compare(b.0) })
        for pu in list {
          cur.push(pu.1)
          acc += pu.1.len
        }
        if acc >= max.to_int64() ||
          (acc >= min.to_int64() && (fnv64(stable_names[idx]) & 15L) == 0L) {
          close()
          acc = 0L
        }
      }
      None => ()
    }
  }
  if !cur.is_empty() {
    close()
  }
  mods
}

// a module: the key of its object in the cache ("": its text's hash), and
// its text (buffers)
struct ModOut {
  key : String
  make : () -> Array[Int]
}
// ---------------------------------------------------------------------------
// Constants

fn hex64(v : Int64) -> String {
  let digits = "0123456789ABCDEF"
  let u = v.reinterpret_as_uint64()
  let sb = StringBuilder::new()
  sb.write_string("0x")
  let mut sh = 60
  while sh >= 0 {
    let d = ((u >> sh) & 15UL).to_int()
    sb.write_char(digits.unsafe_char_at(d))
    sh -= 4
  }
  sb.to_string()
}

fn ptr_val(g : String) -> String {
  "ptrtoint (ptr " + g + " to i64)"
}

let str_consts : Map[Str, String] = Map::new()

// a shared constant: its name from a hash of its definition (names with
// different definitions get a suffix)
fn add_shared(prefix : String, h : Int64, def : String) -> String {
  let mut g = prefix + hex_digits(h, 16)
  while shared.contains(g) {
    g = g + "x"
  }
  shared.set(g, (h, g + def, true))
  sym_decls.set(g, g + " = external hidden global i8")
  g
}

// a static string object (one global: the string, its buffer, the UTF-16
// code units); returns its global
fn str_global(s : Str) -> String {
  match str_consts.get(s) {
    Some(g) => return uref(g)
    None => ()
  }
  let n = s.len
  let mut h = 0xCBF29CE484222325UL.reinterpret_as_int64()
  for i in 0..<n {
    h = (h ^ s.at(i).to_int64()) * 0x100000001B3L
  }
  h = (h ^ n.to_int64()) * 0x100000001B3L
  let mut g = "@s" + hex_digits(h, 16)
  while shared.contains(g) {
    g = g + "x"
  }
  let sb = StringBuilder::new()
  sb.write_string(g)
  if n == 0 {
    sb.write_string(
      " = hidden global { i32, i32, i32, i32, ptr, i32, i32, ptr } { i32 16, i32 0, i32 0, i32 0, ptr getelementptr inbounds (i8, ptr " +
      g + ", i64 24), i32 0, i32 -1, ptr null }, align 8\n",
    )
  } else {
    sb.write_string(
      " = hidden global { i32, i32, i32, i32, ptr, i32, i32, ptr, [\{2 * n} x i8] } { i32 16, i32 0, i32 0, i32 \{n}, ptr getelementptr inbounds (i8, ptr " +
      g + ", i64 24), i32 \{n}, i32 -1, ptr getelementptr inbounds (i8, ptr " + g +
      ", i64 40), [\{2 * n} x i8] c\"",
    )
    let hex = "0123456789ABCDEF"
    let put = fn(b : Int) {
      if b >= 32 && b < 127 && b != 34 && b != 92 {
        sb.write_char(Int::unsafe_to_char(b))
      } else {
        sb.write_char('\\')
        sb.write_char(hex.unsafe_char_at(b >> 4))
        sb.write_char(hex.unsafe_char_at(b & 15))
      }
    }
    for i in 0..<n {
      let c = s.at(i)
      put(c & 255)
      put((c >> 8) & 255)
    }
    sb.write_string("\" }, align 8\n")
  }
  shared.set(g, (h, sb.to_string(), false))
  sym_decls.set(g, g + " = external hidden global i8")
  str_consts.set(s, g)
  uref(g)
}

fn int_const(v : Int64) -> String {
  // (the runtime's forms: rt/tstc.h)
  let y = v ^ 4611686018427387904L
  if v >= -4611686018427387904L && v < 4611686018427387904L {
    (v * 2L + 1L).to_string()
  } else if y >= -1152921504606846976L && y < 1152921504606846976L {
    ((y << 3) | 6L).to_string()
  } else {
    ptr_val(
      intern(" = hidden constant { i32, i32, i64 } { i32 29, i32 0, i64 " + v.to_string() + " }, align 8\n"),
    )
  }
}

// the operand of a constant type
fn ty_const(t : Ty) -> String {
  match t {
    TAny => imm_of(0)
    TUnknown => imm_of(1)
    TNever => imm_of(2)
    TString => imm_of(3)
    TNumber => imm_of(4)
    TBigInt => imm_of(5)
    TSymbol => imm_of(6)
    TObjectKw => imm_of(7)
    TNull => imm_of(8)
    TUndefined => imm_of(9)
    TVoid => imm_of(10)
    TTrue => imm_of(11)
    TFalse => imm_of(12)
    TStrLit(s) => ptr_val(str_global(s))
    TInt(v) => int_const(v)
    TNumLit(d) =>
      ptr_val(
        intern(
          " = hidden constant { i32, i32, double } { i32 17, i32 0, double " +
          hex64(d.reinterpret_as_int64()) + " }, align 8\n",
        ),
      )
    TBigLit(s) => {
      let sg = str_global(Str::of_string(s))
      ptr_val(intern(" = hidden constant { i32, i32, ptr } { i32 18, i32 0, ptr " + sg + " }, align 8\n"))
    }
    TUnion(ms) => {
      let items = ms.map(ty_const)
      let sb = StringBuilder::new()
      sb.write_string(
        " = hidden constant { i32, i32, ptr, [\{ms.length()} x i64] } { i32 23, i32 \{ms.length()}, ptr null, [\{ms.length()} x i64] [",
      )
      for i in 0..<items.length() {
        if i > 0 {
          sb.write_string(", ")
        }
        sb.write_string("i64 " + items[i])
      }
      sb.write_string("] }, align 8\n")
      ptr_val(intern(sb.to_string()))
    }
  }
}

// globals with the same definition are one: shared by units when they refer
// to no symbol of a unit (only to other shared constants), otherwise the
// unit's own
let interned : Map[String, String] = Map::new()

fn intern(def : String) -> String {
  if def.contains("@\"") {
    let u = cu()
    match u.locals.get(def) {
      Some(g) => return g
      None => ()
    }
    u.nglob += 1
    let g = "@\"" + u.prefix + ":D" + u.nglob.to_string() + "\""
    // " = hidden ..." -> " = internal ..."
    uw(g + " = internal" + def.unsafe_substring(start=9, end=def.length()))
    u.locals.set(def, g)
    return g
  }
  match interned.get(def) {
    Some(g) => uref(g)
    None => {
      let g = add_shared("@k", fnv64(def), def)
      interned.set(def, g)
      uref(g)
    }
  }
}

// a static array of i64
fn i64_array(vals : Array[String]) -> String {
  if vals.is_empty() {
    return "null"
  }
  let sb = StringBuilder::new()
  sb.write_string(" = hidden constant [\{vals.length()} x i64] [")
  for i in 0..<vals.length() {
    if i > 0 {
      sb.write_string(", ")
    }
    sb.write_string("i64 " + vals[i])
  }
  sb.write_string("], align 8\n")
  intern(sb.to_string())
}

// a static array of pointers
fn ptr_array(vals : Array[String]) -> String {
  if vals.is_empty() {
    return "null"
  }
  let sb = StringBuilder::new()
  sb.write_string(" = hidden constant [\{vals.length()} x ptr] [")
  for i in 0..<vals.length() {
    if i > 0 {
      sb.write_string(", ")
    }
    sb.write_string("ptr " + vals[i])
  }
  sb.write_string("], align 8\n")
  intern(sb.to_string())
}

// a static struct of i64 / ptr fields: "i64 3", "ptr @x" (writable: the
// runtime caches something in it)
fn struct_global(fields : Array[String], writable : Bool) -> String {
  let sb = StringBuilder::new()
  sb.write_string(if writable { " = hidden global { " } else { " = hidden constant { " })
  for i in 0..<fields.length() {
    if i > 0 {
      sb.write_string(", ")
    }
    sb.write_string(if fields[i].has_prefix("ptr") { "ptr" } else { "i64" })
  }
  sb.write_string(" } { ")
  for i in 0..<fields.length() {
    if i > 0 {
      sb.write_string(", ")
    }
    sb.write_string(fields[i])
  }
  sb.write_string(" }, align 8\n")
  if writable {
    // the runtime writes into it: one per use
    let u = cu()
    u.nglob += 1
    let g = "@\"" + u.prefix + ":D" + u.nglob.to_string() + "\""
    let d = sb.to_string()
    uw(g + " = internal" + d.unsafe_substring(start=9, end=d.length()))
    g
  } else {
    intern(sb.to_string())
  }
}

// an array of structs of the same field types
fn struct_array(rows : Array[Array[String]]) -> String {
  if rows.is_empty() {
    return "null"
  }
  let types = StringBuilder::new()
  types.write_string("{ ")
  let r0 = rows[0]
  for i in 0..<r0.length() {
    if i > 0 {
      types.write_string(", ")
    }
    types.write_string(if r0[i].has_prefix("ptr") { "ptr" } else { "i64" })
  }
  types.write_string(" }")
  let ty = types.to_string()
  let sb = StringBuilder::new()
  sb.write_string(" = hidden constant [\{rows.length()} x " + ty + "] [")
  for j in 0..<rows.length() {
    if j > 0 {
      sb.write_string(", ")
    }
    sb.write_string(ty + " { ")
    let r = rows[j]
    for i in 0..<r.length() {
      if i > 0 {
        sb.write_string(", ")
      }
      sb.write_string(r[i])
    }
    sb.write_string(" }")
  }
  sb.write_string("], align 8\n")
  intern(sb.to_string())
}

fn ival(n : Int) -> String {
  "i64 " + n.to_string()
}

fn pval(g : String) -> String {
  "ptr " + g
}


// ---------------------------------------------------------------------------
// Functions of the environment and descriptors

// the function evaluating code in an environment (memoized by key when
// given): conditionals are their own functions, shared by everything that
// refers to them
fn code_fn(code : Code, frame : Int, key : String) -> String {
  match code {
    CCond(cd) => return cond_fn(cd, frame)
    _ => ()
  }
  let u = cu()
  if key != "" {
    match u.fn_names.get(key) {
      Some(n) => return n
      None => ()
    }
  }
  u.nfn += 1
  let name = "@\"" + u.prefix + ":T" + u.nfn.to_string() + "\""
  if key != "" {
    u.fn_names.set(key, name)
  }
  u.pending.push(fn() { gen_env_fn(name, code, frame) })
  name
}

fn cond_fn(cd : Cond, frame : Int) -> String {
  let u = cu()
  let key = "c" + cd.id.to_string()
  match u.fn_names.get(key) {
    Some(n) => return n
    None => ()
  }
  u.nfn += 1
  let name = "@\"" + u.prefix + ":C" + u.nfn.to_string() + "\""
  u.fn_names.set(key, name)
  u.pending.push(fn() { gen_env_fn(name, CCond(cd), frame) })
  name
}

// a function, or the constant the code is
fn code_field(c : Code, frame : Int, key : String) -> (String, String) {
  match c {
    CTy(t) => ("ptr null", "i64 " + ty_const(t))
    _ => ("ptr " + code_fn(c, frame, key), "i64 0")
  }
}

fn pat_desc(p : Pat, frame : Int) -> String {
  // kind, slot, code, cval, n, elems, ekinds, sub, names, opts, texts, ro
  let null = "ptr null"
  match p {
    PCode(c) => {
      let (code, cval) = code_field(c, frame, "")
      struct_global([ival(0), ival(0), code, cval, ival(0), null, null, null, null, null, null, ival(0)], false)
    }
    PInfer(slot, cons) => {
      let code = match cons {
        Some(c) => "ptr " + code_fn(c, frame, "")
        None => null
      }
      struct_global([ival(1), ival(slot), code, ival(0), ival(0), null, null, null, null, null, null, ival(0)], false)
    }
    PTuple(elems, ro) => {
      let es = ptr_array(elems.map(fn(e) { pat_desc(e.pat, frame) }))
      let ks = i64_array(elems.map(fn(e) { e.kind.to_string() }))
      struct_global([ival(2), ival(0), null, ival(0), ival(elems.length()), pval(es), pval(ks), null, null, null, null, ival(if ro { 1 } else { 0 })], false)
    }
    PArray(sub, ro) => {
      let s = pat_desc(sub, frame)
      struct_global([ival(3), ival(0), null, ival(0), ival(0), null, null, pval(s), null, null, null, ival(if ro { 1 } else { 0 })], false)
    }
    PObj(props) => {
      let es = ptr_array(props.map(fn(pp) { pat_desc(pp.pat, frame) }))
      let ns = ptr_array(props.map(fn(pp) { str_global(pp.name) }))
      let os = i64_array(props.map(fn(pp) { if pp.optional { "1" } else { "0" } }))
      struct_global([ival(4), ival(0), null, ival(0), ival(props.length()), pval(es), null, null, pval(ns), pval(os), null, ival(0)], false)
    }
    PTpl(texts, pats) => {
      let es = ptr_array(pats.map(fn(x) { pat_desc(x, frame) }))
      let ts = ptr_array(texts.map(fn(s) { str_global(s) }))
      struct_global([ival(5), ival(0), null, ival(0), ival(pats.length()), pval(es), null, null, null, null, pval(ts), ival(0)], false)
    }
    PFn(params, ret) => {
      let es = ptr_array(params.map(fn(x) { pat_desc(x.pat, frame) }))
      let ks = i64_array(params.map(fn(x) { x.kind.to_string() }))
      let r = pat_desc(ret, frame)
      struct_global([ival(6), ival(0), null, ival(0), ival(params.length()), pval(es), pval(ks), pval(r), null, null, null, ival(0)], false)
    }
    PUnion(pats) => {
      let es = ptr_array(pats.map(fn(x) { pat_desc(x, frame) }))
      struct_global([ival(7), ival(0), null, ival(0), ival(pats.length()), pval(es), null, null, null, null, null, ival(0)], false)
    }
    PVal(c, infs) => {
      let es = ptr_array(infs.map(fn(x) { pat_desc(x.pat, frame) }))
      let ks = i64_array(infs.map(fn(x) { x.kind.to_string() }))
      let code = "ptr " + code_fn(c, frame, "")
      struct_global([ival(8), ival(0), code, ival(0), ival(infs.length()), pval(es), pval(ks), null, null, null, null, ival(0)], false)
    }
  }
}

fn cond_desc(cd : Cond, frame : Int) -> String {
  let key = "cd" + cd.id.to_string()
  match cu().descs.get(key) {
    Some(g) => return g
    None => ()
  }
  let id = cd.id.to_string()
  // `X extends infer V` never needs the extends type
  let (ext, ext_cval) = if cd.fast == 1 {
    ("ptr null", "i64 0")
  } else {
    code_field(cd.ext, frame, "e" + id)
  }
  let pat = match cd.pat {
    Some(p) => pat_desc(p, frame)
    None => "null"
  }
  let slots = i64_array(cd.infer_slots.map(fn(s) { s.to_string() }))
  let (t, t_cval) = code_field(cd.t, frame, "t" + id)
  let (f, f_cval) = code_field(cd.f, frame, "f" + id)
  let whole = if cd.dist_slot >= 0 { cond_fn(cd, frame) } else { "null" }
  let g = struct_global(
    [
      ival(frame),
      ival(cd.dist_slot),
      ext,
      ext_cval,
      pval(pat),
      pval(slots),
      ival(cd.infer_slots.length()),
      t,
      t_cval,
      f,
      f_cval,
      pval(whole),
    ],
    false,
  )
  cu().descs.set(key, g)
  g
}

fn param_rows(params : Array[CParam], frame : Int, with_types : Bool) -> String {
  struct_array(
    params.map(fn(p) {
      [
        pval(str_global(p.name)),
        if with_types {
          pval(code_fn(p.code, frame, ""))
        } else {
          "ptr null"
        },
        ival(if p.optional { 1 } else { 0 }),
        ival(if p.rest { 1 } else { 0 }),
      ]
    }),
  )
}

// the function of property j of an object type
// the function evaluating the property whose index is in slot `frame`
fn prop_eval_fn(oc : ObjCode, frame : Int) -> String {
  let u = cu()
  let key = "pe" + oc.id.to_string()
  match u.fn_names.get(key) {
    Some(n) => return n
    None => ()
  }
  u.nfn += 1
  let name = "@\"" + u.prefix + ":P" + u.nfn.to_string() + "\""
  u.fn_names.set(key, name)
  u.pending.push(fn() { gen_prop_eval(name, oc, frame) })
  name
}

fn prop_fn(oc : ObjCode, j : Int, frame : Int) -> String {
  code_fn(oc.props[j].1, frame, "o" + oc.id.to_string() + "p" + j.to_string())
}

fn obj_desc(oc : ObjCode, frame : Int) -> String {
  obj_desc_of(oc, frame, false)
}

// by_index (the general case of a dispatch, which seldom runs): the
// properties that are code are evaluated by one function, given the
// property's index past the frame (rt_obj: slot -2 - index)
fn obj_desc_of(oc : ObjCode, frame : Int, by_index : Bool) -> String {
  let key = (if by_index { "oi" } else { "o" }) + oc.id.to_string()
  match cu().descs.get(key) {
    Some(g) => return g
    None => ()
  }
  let mut ncode = 0
  for p in oc.props {
    if !prop_in_desc(p.1) {
      ncode += 1
    }
  }
  let ev = if by_index && ncode >= 2 { Some(prop_eval_fn(oc, frame)) } else { None }
  // name, th, cval, slot, opt, ro, numeric
  let rows : Array[Array[String]] = []
  for j in 0..<oc.props.length() {
    let p = oc.props[j]
    let (th, cval, slot) = match p.1 {
      CTy(t) => ("ptr null", "i64 " + ty_const(t), -1)
      CSlot(i) => ("ptr null", "i64 0", i)
      _ if const_operand(p.1) is Some(_) => ("ptr null", "i64 " + const_operand(p.1).unwrap(), -1)
      _ =>
        match ev {
          Some(f) => ("ptr " + f, "i64 0", -2 - j)
          None => ("ptr " + prop_fn(oc, j, frame), "i64 0", -1)
        }
    }
    rows.push([
      pval(str_global(p.0)),
      th,
      cval,
      ival(slot),
      ival(if p.2 { 1 } else { 0 }),
      ival(if p.3 { 1 } else { 0 }),
      ival(if p.4 { 1 } else { 0 }),
    ])
  }
  let props = struct_array(rows)
  let index = struct_array(
    oc.index.map(fn(ix) {
      [
        pval(code_fn(ix.0, frame, "")),
        pval(code_fn(ix.1, frame, "o" + oc.id.to_string() + "ix")),
        ival(if ix.2 { 1 } else { 0 }),
      ]
    }),
  )
  let calls = struct_array(
    oc.calls.map(fn(c) {
      [
        ival(c.0.length()),
        pval(param_rows(c.0, frame, true)),
        pval(code_fn(c.1, frame, "")),
        ival(if c.2 { 1 } else { 0 }),
      ]
    }),
  )
  let g = struct_global(
    [
      ival(frame),
      ival(oc.props.length()),
      pval(props),
      ival(oc.index.length()),
      pval(index),
      ival(oc.calls.length()),
      pval(calls),
    ],
    false,
  )
  cu().descs.set(key, g)
  g
}

fn fn_desc(params : Array[CParam], ctor : Bool) -> String {
  struct_global(
    [ival(params.length()), pval(param_rows(params, 0, false)), ival(if ctor { 1 } else { 0 })],
    false,
  )
}

fn opt_fn(c : Code?, frame : Int) -> String {
  match c {
    Some(x) => pval(code_fn(x, frame, ""))
    None => "ptr null"
  }
}

fn mapped_desc(mc : MappedCode, frame : Int) -> String {
  let key = "m" + mc.id.to_string()
  match cu().descs.get(key) {
    Some(g) => return g
    None => ()
  }
  let (cval, bslot) = match mc.body {
    CTy(t) => ("i64 " + ty_const(t), -1)
    CSlot(i) => ("i64 0", i)
    _ => ("i64 0", -1)
  }
  // frame, slot, constraint, homo, mods, as, body, body_cval, body_slot, ro, opt
  let g = struct_global(
    [
      ival(frame),
      ival(mc.slot),
      pval(code_fn(mc.constraint, frame, "")),
      opt_fn(mc.homo, frame),
      opt_fn(mc.mods, frame),
      opt_fn(mc.as_clause, frame),
      pval(code_fn(mc.body, frame, "")),
      cval,
      ival(bslot),
      ival(mc.ro),
      ival(mc.opt),
      ival(if mc.kof { 1 } else { 0 }),
      ival(mc.homo_slot),
    ],
    false,
  )
  cu().descs.set(key, g)
  g
}

// ---------------------------------------------------------------------------
// The program

let llvm_prelude : String =
  #|; generated by tstc
  #|@tstc_top = external dso_local global ptr
  #|@tstc_memo_off = external dso_local global [1048576 x i8]
  #|declare i64 @rt_tuple2(i64, i64)
  #|declare i64 @rt_tuple1(i64)
  #|
  #|define internal i64 @tstc_box(i64 %a, i64 %b) alwaysinline {
  #|entry:
  #|  %z = icmp eq i64 %b, 0
  #|  br i1 %z, label %v, label %t
  #|v:
  #|  ret i64 %a
  #|t:
  #|  %one = icmp eq i64 %b, 4
  #|  br i1 %one, label %t1, label %t2
  #|t1:
  #|  %p1 = call i64 @rt_tuple1(i64 %a)
  #|  ret i64 %p1
  #|t2:
  #|  %p = call i64 @rt_tuple2(i64 %a, i64 %b)
  #|  ret i64 %p
  #|}
  #|
  #|define internal i32 @tstc_kind(i64 %v) alwaysinline {
  #|entry:
  #|  %a = and i64 %v, 1
  #|  %isint = icmp ne i64 %a, 0
  #|  br i1 %isint, label %int, label %n1
  #|int:
  #|  ret i32 29
  #|n1:
  #|  %b = and i64 %v, 2
  #|  %isimm = icmp ne i64 %b, 0
  #|  br i1 %isimm, label %imm, label %ptr
  #|imm:
  #|  %k = lshr i64 %v, 3
  #|  %km = and i64 %k, 63
  #|  %k32 = trunc i64 %km to i32
  #|  %b4 = and i64 %v, 4
  #|  %isi6 = icmp ne i64 %b4, 0
  #|  %kr = select i1 %isi6, i32 29, i32 %k32
  #|  ret i32 %kr
  #|ptr:
  #|  %p = inttoptr i64 %v to ptr
  #|  %t = load i32, ptr %p
  #|  ret i32 %t
  #|}
  #|
  #|define internal i1 @tstc_plain1(i64 %v) alwaysinline {
  #|entry:
  #|  %a = icmp eq i64 %v, 18
  #|  %b = icmp eq i64 %v, 2
  #|  %ab = or i1 %a, %b
  #|  br i1 %ab, label %no, label %c
  #|c:
  #|  %k = call i32 @tstc_kind(i64 %v)
  #|  %u = icmp ne i32 %k, 23
  #|  ret i1 %u
  #|no:
  #|  ret i1 false
  #|}
  #|
  #|define internal i1 @tstc_distributes(i64 %v) alwaysinline {
  #|entry:
  #|  %a = icmp eq i64 %v, 18
  #|  br i1 %a, label %yes, label %c
  #|c:
  #|  %k = call i32 @tstc_kind(i64 %v)
  #|  %u = icmp eq i32 %k, 23
  #|  ret i1 %u
  #|yes:
  #|  ret i1 true
  #|}
  #|
  #|declare i1 @rt_tup_fastok(ptr)
  #|declare { i64, i1 } @llvm.sadd.with.overflow.i64(i64, i64)
  #|declare { i64, i1 } @llvm.ssub.with.overflow.i64(i64, i64)
  #|declare { i64, i1 } @llvm.smul.with.overflow.i64(i64, i64)
  #|declare i64 @llvm.umin.i64(i64, i64)
  #|
  #|define internal i1 @tstc_tuplen(i64 %v, i32 %n) alwaysinline {
  #|entry:
  #|  %lo = and i64 %v, 3
  #|  %isp = icmp eq i64 %lo, 0
  #|  br i1 %isp, label %p, label %no
  #|p:
  #|  %ptr = inttoptr i64 %v to ptr
  #|  %tag = load i32, ptr %ptr, !invariant.load !0
  #|  %ist = icmp eq i32 %tag, 20
  #|  br i1 %ist, label %t, label %no
  #|t:
  #|  %lp = getelementptr inbounds i8, ptr %ptr, i64 4
  #|  %len = load i32, ptr %lp, !invariant.load !0
  #|  %okl = icmp eq i32 %len, %n
  #|  br i1 %okl, label %x, label %no
  #|x:
  #|  %xp = getelementptr inbounds i8, ptr %ptr, i64 16
  #|  %xv = load ptr, ptr %xp, !invariant.load !0
  #|  %xnull = icmp eq ptr %xv, null
  #|  br i1 %xnull, label %yes, label %chk
  #|chk:
  #|  %ok = call i1 @rt_tup_fastok(ptr %xv)
  #|  ret i1 %ok
  #|yes:
  #|  ret i1 true
  #|no:
  #|  ret i1 false
  #|}
  #|
  #|; Inline cell and tuple accesses (--native-fast): straight-line code with
  #|; one branch to the native for anything uncommon. The first store
  #|; (tstc_store0, heap.c): cells (8), len (16), version (32); a store value is
  #|; version << 16 | id << 9 | K_STORE << 3 | 2. Assumed of a linear store
  #|; (store.mbt): the version a value names is the current one.
  #|@tstc_store0 = external dso_local global { i32, i32, ptr, i64, i64, i64, ptr }
  #|; the kinds of values a cell owns (heap.c: store_owned_kind; K_COUNT 36):
  #|; a pointer to one of those is frozen by the native, the others are read
  #|; out as they are
  #|@store_freeze = external dso_local global [36 x ptr]
  #|@tstc_zero16 = internal constant [2 x i64] zeroinitializer
  #|declare i64 @n_hget(i64, i64)
  #|declare i64 @n_hset(i64, i64, i64)
  #|declare i64 @n_tget(i64, i64)
  #|declare i64 @n_hgetf(i64, i64, i64)
  #|declare i64 @n_hgets(i64, i64, i64, i64)
  #|declare i64 @n_hsets(i64, i64, i64, i64, i64)
  #|declare i64 @n_sidx(i64, i64, i64)
  #|declare i64 @n_geq(i64, i64)
  #|declare i64 @n_gne(i64, i64)
  #|
  #|; a cell of store 0 that holds an immediate (an integer, a keyword, a
  #|; float) or an object no cell owns (a map is frozen by the slow path).
  #|; A freed cell is not looked for here (the natives and stores still do;
  #|; a load of one is a collector's bug). Branches, not selects: a load whose
  #|; address waits for a select cannot start early
  #|define internal i64 @tstc_hget(i64 %h, i64 %p) alwaysinline {
  #|entry:
  #|  %hl = and i64 %h, 65535
  #|  %okh = icmp eq i64 %hl, 258
  #|  %okp = trunc i64 %p to i1
  #|  %ok = and i1 %okh, %okp
  #|  br i1 %ok, label %a, label %slow
  #|a:
  #|  %hp = getelementptr inbounds i8, ptr @tstc_store0, i64 0
  #|  %cp = getelementptr inbounds i8, ptr %hp, i64 8
  #|  %cells = load ptr, ptr %cp
  #|  %i = ashr i64 %p, 1
  #|  %ap = getelementptr i64, ptr %cells, i64 %i
  #|  %v = load i64, ptr %ap
  #|  %plo = and i64 %v, 3
  #|  %imm = icmp ne i64 %plo, 0
  #|  br i1 %imm, label %f, label %pl
  #|pl:
  #|  %pnz = icmp ne i64 %v, 0
  #|  br i1 %pnz, label %pq, label %slow
  #|pq:
  #|  %pvp = inttoptr i64 %v to ptr
  #|  %ptg = load i32, ptr %pvp
  #|  %ptg64 = zext i32 %ptg to i64
  #|  %pin = icmp ult i64 %ptg64, 36
  #|  br i1 %pin, label %pr, label %slow
  #|pr:
  #|  %pfp = getelementptr inbounds [36 x ptr], ptr @store_freeze, i64 0, i64 %ptg64
  #|  %pfz = load ptr, ptr %pfp
  #|  %pno = icmp eq ptr %pfz, null
  #|  br i1 %pno, label %f, label %slow
  #|f:
  #|  ret i64 %v
  #|slow:
  #|  %r = call i64 @n_hget(i64 %h, i64 %p)
  #|  ret i64 %r
  #|}
  #|
  #|define internal i64 @tstc_hset(i64 %h, i64 %p, i64 %x) alwaysinline {
  #|entry:
  #|  %hl = and i64 %h, 65535
  #|  %okh = icmp eq i64 %hl, 258
  #|  %okp = trunc i64 %p to i1
  #|  %ok = and i1 %okh, %okp
  #|  br i1 %ok, label %a, label %slow
  #|a:
  #|  %hp = getelementptr inbounds i8, ptr @tstc_store0, i64 0
  #|  %lp = getelementptr inbounds i8, ptr %hp, i64 16
  #|  %len = load i64, ptr %lp
  #|  %i = ashr i64 %p, 1
  #|  %inb = icmp ult i64 %i, %len
  #|  br i1 %inb, label %f, label %slow
  #|f:
  #|  %cp = getelementptr inbounds i8, ptr %hp, i64 8
  #|  %cells = load ptr, ptr %cp
  #|  %ap = getelementptr i64, ptr %cells, i64 %i
  #|  store i64 %x, ptr %ap
  #|  %vp = getelementptr inbounds i8, ptr %hp, i64 32
  #|  %ver = load i64, ptr %vp
  #|  %ver1 = add i64 %ver, 1
  #|  store i64 %ver1, ptr %vp
  #|  %h1 = add i64 %h, 65536
  #|  ret i64 %h1
  #|slow:
  #|  %r = call i64 @n_hset(i64 %h, i64 %p, i64 %x)
  #|  ret i64 %r
  #|}
  #|
  #|; the cell at p + off of store 0 (hgetf), as tstc_hget
  #|define internal i64 @tstc_hgetf(i64 %h, i64 %p, i64 %off) alwaysinline {
  #|entry:
  #|  %hl = and i64 %h, 65535
  #|  %okh = icmp eq i64 %hl, 258
  #|  %po = and i64 %p, %off
  #|  %okp = trunc i64 %po to i1
  #|  %ok = and i1 %okh, %okp
  #|  br i1 %ok, label %a, label %slow
  #|a:
  #|  %hp = getelementptr inbounds i8, ptr @tstc_store0, i64 0
  #|  %lp = getelementptr inbounds i8, ptr %hp, i64 16
  #|  %len = load i64, ptr %lp
  #|  %pi = ashr i64 %p, 1
  #|  %oi = ashr i64 %off, 1
  #|  %i = add i64 %pi, %oi
  #|  %inb = icmp ult i64 %i, %len
  #|  br i1 %inb, label %b, label %slow
  #|b:
  #|  %cp = getelementptr inbounds i8, ptr %hp, i64 8
  #|  %cells = load ptr, ptr %cp
  #|  %ap = getelementptr i64, ptr %cells, i64 %i
  #|  %v = load i64, ptr %ap
  #|  %plo = and i64 %v, 3
  #|  %imm = icmp ne i64 %plo, 0
  #|  br i1 %imm, label %f, label %pl
  #|pl:
  #|  %pnz = icmp ne i64 %v, 0
  #|  br i1 %pnz, label %pq, label %slow
  #|pq:
  #|  %pvp = inttoptr i64 %v to ptr
  #|  %ptg = load i32, ptr %pvp
  #|  %ptg64 = zext i32 %ptg to i64
  #|  %pin = icmp ult i64 %ptg64, 36
  #|  br i1 %pin, label %pr, label %slow
  #|pr:
  #|  %pfp = getelementptr inbounds [36 x ptr], ptr @store_freeze, i64 0, i64 %ptg64
  #|  %pfz = load ptr, ptr %pfp
  #|  %pno = icmp eq ptr %pfz, null
  #|  br i1 %pno, label %f, label %slow
  #|f:
  #|  ret i64 %v
  #|slow:
  #|  %r = call i64 @n_hgetf(i64 %h, i64 %p, i64 %off)
  #|  ret i64 %r
  #|}
  #|
  #|; a value of two cells at p of store 0 (hloadt of layout "(ss)"): the pair
  #|; of them, as tstc_hgetf reads each (the runtime's tuple, a value, else)
  #|declare i64 @n_hloadt(i64, i64, i64)
  #|define internal { i64, i64 } @tstc_hload2(i64 %h, i64 %p, i64 %lay) alwaysinline {
  #|entry:
  #|  %hl = and i64 %h, 65535
  #|  %okh = icmp eq i64 %hl, 258
  #|  %okp = trunc i64 %p to i1
  #|  %ok = and i1 %okh, %okp
  #|  br i1 %ok, label %a, label %slow
  #|a:
  #|  %hp = getelementptr inbounds i8, ptr @tstc_store0, i64 0
  #|  %lp = getelementptr inbounds i8, ptr %hp, i64 16
  #|  %len = load i64, ptr %lp
  #|  %i = ashr i64 %p, 1
  #|  %i1 = add i64 %i, 1
  #|  %inb = icmp ult i64 %i1, %len
  #|  br i1 %inb, label %b, label %slow
  #|b:
  #|  %cp = getelementptr inbounds i8, ptr %hp, i64 8
  #|  %cells = load ptr, ptr %cp
  #|  %ap = getelementptr i64, ptr %cells, i64 %i
  #|  %x = load i64, ptr %ap
  #|  %ap1 = getelementptr i64, ptr %cells, i64 %i1
  #|  %y = load i64, ptr %ap1
  #|  %xk = and i64 %x, 391
  #|  %xokk = icmp eq i64 %xk, 2
  #|  %xi = trunc i64 %x to i1
  #|  %xokv = or i1 %xi, %xokk
  #|  br i1 %xokv, label %c, label %xpl
  #|xpl:
  #|  %xlo = and i64 %x, 3
  #|  %xis = icmp eq i64 %xlo, 0
  #|  %xnz = icmp ne i64 %x, 0
  #|  %xpok = and i1 %xis, %xnz
  #|  br i1 %xpok, label %xpq, label %xpw
  #|xpw:
  #|  %xw7 = and i64 %x, 7
  #|  %xwi = icmp eq i64 %xw7, 6
  #|  br i1 %xwi, label %c, label %slow
  #|xpq:
  #|  %xvp = inttoptr i64 %x to ptr
  #|  %xtg = load i32, ptr %xvp
  #|  %xtg64 = zext i32 %xtg to i64
  #|  %xin = icmp ult i64 %xtg64, 36
  #|  br i1 %xin, label %xpr, label %slow
  #|xpr:
  #|  %xfp = getelementptr inbounds [36 x ptr], ptr @store_freeze, i64 0, i64 %xtg64
  #|  %xfz = load ptr, ptr %xfp
  #|  %xno = icmp eq ptr %xfz, null
  #|  br i1 %xno, label %c, label %slow
  #|c:
  #|  %yk = and i64 %y, 391
  #|  %yokk = icmp eq i64 %yk, 2
  #|  %yi = trunc i64 %y to i1
  #|  %yokv = or i1 %yi, %yokk
  #|  br i1 %yokv, label %f, label %ypl
  #|ypl:
  #|  %ylo = and i64 %y, 3
  #|  %yis = icmp eq i64 %ylo, 0
  #|  %ynz = icmp ne i64 %y, 0
  #|  %ypok = and i1 %yis, %ynz
  #|  br i1 %ypok, label %ypq, label %ypw
  #|ypw:
  #|  %yw7 = and i64 %y, 7
  #|  %ywi = icmp eq i64 %yw7, 6
  #|  br i1 %ywi, label %f, label %slow
  #|ypq:
  #|  %yvp = inttoptr i64 %y to ptr
  #|  %ytg = load i32, ptr %yvp
  #|  %ytg64 = zext i32 %ytg to i64
  #|  %yin = icmp ult i64 %ytg64, 36
  #|  br i1 %yin, label %ypr, label %slow
  #|ypr:
  #|  %yfp = getelementptr inbounds [36 x ptr], ptr @store_freeze, i64 0, i64 %ytg64
  #|  %yfz = load ptr, ptr %yfp
  #|  %yno = icmp eq ptr %yfz, null
  #|  br i1 %yno, label %f, label %slow
  #|f:
  #|  %r0 = insertvalue { i64, i64 } poison, i64 %x, 0
  #|  %r1 = insertvalue { i64, i64 } %r0, i64 %y, 1
  #|  ret { i64, i64 } %r1
  #|slow:
  #|  %rs = call i64 @n_hloadt(i64 %h, i64 %p, i64 %lay)
  #|  %s0 = insertvalue { i64, i64 } { i64 poison, i64 0 }, i64 %rs, 0
  #|  ret { i64, i64 } %s0
  #|}
  #|
  #|; element k (0 or 1) of the pair (a, b) as a tuple: b (0: a is the value, 4:
  #|; the tuple [a]) else by the runtime
  #|define internal i64 @tstc_pget(i64 %a, i64 %b, i64 %k) alwaysinline {
  #|entry:
  #|  %z = icmp eq i64 %b, 0
  #|  %o = icmp eq i64 %b, 4
  #|  %zo = or i1 %z, %o
  #|  br i1 %zo, label %slow, label %f
  #|f:
  #|  %k0 = icmp eq i64 %k, 1
  #|  %r = select i1 %k0, i64 %a, i64 %b
  #|  ret i64 %r
  #|slow:
  #|  %t = call i64 @tstc_box(i64 %a, i64 %b)
  #|  %rs = call i64 @tstc_tget(i64 %t, i64 %k)
  #|  ret i64 %rs
  #|}
  #|
  #|; the cell of element i of slice s (stride cells each) of store 0 (hgets): s
  #|; the tuple [pointer, length, capacity], as slice_cell in heap.c
  #|define internal i64 @tstc_hgets(i64 %h, i64 %s, i64 %iv, i64 %stride) alwaysinline {
  #|entry:
  #|  %hl = and i64 %h, 65535
  #|  %okh = icmp eq i64 %hl, 258
  #|  %lo = and i64 %s, 3
  #|  %isp = icmp eq i64 %lo, 0
  #|  %is = and i64 %iv, %stride
  #|  %oki = trunc i64 %is to i1
  #|  %ok1 = and i1 %okh, %isp
  #|  %ok = and i1 %ok1, %oki
  #|  br i1 %ok, label %a, label %slow
  #|a:
  #|  %sp = inttoptr i64 %s to ptr
  #|  %hdr = load i64, ptr %sp, !invariant.load !0
  #|  %tag = and i64 %hdr, 4294967295
  #|  %ist = icmp eq i64 %tag, 20
  #|  %tl = lshr i64 %hdr, 32
  #|  %okl = icmp uge i64 %tl, 3
  #|  %okt = and i1 %ist, %okl
  #|  br i1 %okt, label %b, label %slow
  #|b:
  #|  %ep = getelementptr inbounds i8, ptr %sp, i64 8
  #|  %e = load ptr, ptr %ep, !invariant.load !0
  #|  %e0 = load i64, ptr %e, !invariant.load !0
  #|  %e1p = getelementptr inbounds i64, ptr %e, i64 1
  #|  %e1 = load i64, ptr %e1p, !invariant.load !0
  #|  %ee = and i64 %e0, %e1
  #|  %oke = trunc i64 %ee to i1
  #|  %i = ashr i64 %iv, 1
  #|  %n = ashr i64 %e1, 1
  #|  %inr = icmp ult i64 %i, %n
  #|  %st = ashr i64 %stride, 1
  #|  %sts = icmp ult i64 %st, 2147483648
  #|  %ok2 = and i1 %oke, %inr
  #|  %ok3 = and i1 %ok2, %sts
  #|  br i1 %ok3, label %c, label %slow
  #|c:
  #|  %base = ashr i64 %e0, 1
  #|  %m = mul i64 %i, %st
  #|  %r0 = add i64 %base, %m
  #|  %hp = getelementptr inbounds i8, ptr @tstc_store0, i64 0
  #|  %lp = getelementptr inbounds i8, ptr %hp, i64 16
  #|  %len = load i64, ptr %lp
  #|  %inb = icmp ult i64 %r0, %len
  #|  br i1 %inb, label %d, label %slow
  #|d:
  #|  %cp = getelementptr inbounds i8, ptr %hp, i64 8
  #|  %cells = load ptr, ptr %cp
  #|  %ap = getelementptr i64, ptr %cells, i64 %r0
  #|  %v = load i64, ptr %ap
  #|  %plo = and i64 %v, 3
  #|  %imm = icmp ne i64 %plo, 0
  #|  br i1 %imm, label %f, label %pl
  #|pl:
  #|  %pnz = icmp ne i64 %v, 0
  #|  br i1 %pnz, label %pq, label %slow
  #|pq:
  #|  %pvp = inttoptr i64 %v to ptr
  #|  %ptg = load i32, ptr %pvp
  #|  %ptg64 = zext i32 %ptg to i64
  #|  %pin = icmp ult i64 %ptg64, 36
  #|  br i1 %pin, label %pr, label %slow
  #|pr:
  #|  %pfp = getelementptr inbounds [36 x ptr], ptr @store_freeze, i64 0, i64 %ptg64
  #|  %pfz = load ptr, ptr %pfp
  #|  %pno = icmp eq ptr %pfz, null
  #|  br i1 %pno, label %f, label %slow
  #|f:
  #|  ret i64 %v
  #|slow:
  #|  %r = call i64 @n_hgets(i64 %h, i64 %s, i64 %iv, i64 %stride)
  #|  ret i64 %r
  #|}
  #|
  #|; element i of slice s (stride cells each) of store 0 set to x (hsets),
  #|; as tstc_hgets finds it
  #|define internal i64 @tstc_hsets(i64 %h, i64 %s, i64 %iv, i64 %stride, i64 %x) alwaysinline {
  #|entry:
  #|  %hl = and i64 %h, 65535
  #|  %okh = icmp eq i64 %hl, 258
  #|  %lo = and i64 %s, 3
  #|  %isp = icmp eq i64 %lo, 0
  #|  %is = and i64 %iv, %stride
  #|  %oki = trunc i64 %is to i1
  #|  %ok1 = and i1 %okh, %isp
  #|  %ok = and i1 %ok1, %oki
  #|  br i1 %ok, label %a, label %slow
  #|a:
  #|  %sp = inttoptr i64 %s to ptr
  #|  %hdr = load i64, ptr %sp, !invariant.load !0
  #|  %tag = and i64 %hdr, 4294967295
  #|  %ist = icmp eq i64 %tag, 20
  #|  %tl = lshr i64 %hdr, 32
  #|  %okl = icmp uge i64 %tl, 3
  #|  %okt = and i1 %ist, %okl
  #|  br i1 %okt, label %b, label %slow
  #|b:
  #|  %ep = getelementptr inbounds i8, ptr %sp, i64 8
  #|  %e = load ptr, ptr %ep, !invariant.load !0
  #|  %e0 = load i64, ptr %e, !invariant.load !0
  #|  %e1p = getelementptr inbounds i64, ptr %e, i64 1
  #|  %e1 = load i64, ptr %e1p, !invariant.load !0
  #|  %ee = and i64 %e0, %e1
  #|  %oke = trunc i64 %ee to i1
  #|  %i = ashr i64 %iv, 1
  #|  %n0 = ashr i64 %e1, 1
  #|  ; (an index below 2^32 too, as slice_cell: i * stride does not overflow)
  #|  %n = call i64 @llvm.umin.i64(i64 %n0, i64 4294967296)
  #|  %inr = icmp ult i64 %i, %n
  #|  %st = ashr i64 %stride, 1
  #|  %sts = icmp ult i64 %st, 2147483648
  #|  %ok2 = and i1 %oke, %inr
  #|  %ok3 = and i1 %ok2, %sts
  #|  br i1 %ok3, label %c, label %slow
  #|c:
  #|  %base = ashr i64 %e0, 1
  #|  %m = mul i64 %i, %st
  #|  %r0 = add i64 %base, %m
  #|  %hp = getelementptr inbounds i8, ptr @tstc_store0, i64 0
  #|  %lp = getelementptr inbounds i8, ptr %hp, i64 16
  #|  %len = load i64, ptr %lp
  #|  %inb = icmp ult i64 %r0, %len
  #|  br i1 %inb, label %d, label %slow
  #|d:
  #|  %cp = getelementptr inbounds i8, ptr %hp, i64 8
  #|  %cells = load ptr, ptr %cp
  #|  %ap = getelementptr i64, ptr %cells, i64 %r0
  #|  %v = load i64, ptr %ap
  #|  ; a live cell (not a freed one: no FREE header, POISON or 0)
  #|  %v9 = and i64 %v, 511
  #|  %np = icmp ne i64 %v9, 490
  #|  %nf = icmp ne i64 %v9, 498
  #|  %nz = icmp ne i64 %v, 0
  #|  %l1 = and i1 %np, %nf
  #|  %live = and i1 %l1, %nz
  #|  br i1 %live, label %f, label %slow
  #|f:
  #|  store i64 %x, ptr %ap
  #|  %vp = getelementptr inbounds i8, ptr %hp, i64 32
  #|  %ver = load i64, ptr %vp
  #|  %ver1 = add i64 %ver, 1
  #|  store i64 %ver1, ptr %vp
  #|  %h1 = add i64 %h, 65536
  #|  ret i64 %h1
  #|slow:
  #|  %r = call i64 @n_hsets(i64 %h, i64 %s, i64 %iv, i64 %stride, i64 %x)
  #|  ret i64 %r
  #|}
  #|
  #|; a tuple does not change once made (its header, its elements: loads of
  #|; them are !invariant.load, which calls and stores do not clobber)
  #|!0 = !{}
  #|
  #|; an element of a tuple (tag 20, length, elements)
  #|define internal i64 @tstc_tget(i64 %t, i64 %k) alwaysinline {
  #|entry:
  #|  %lo = and i64 %t, 3
  #|  %isp = icmp eq i64 %lo, 0
  #|  br i1 %isp, label %a, label %slow
  #|a:
  #|  %tp = inttoptr i64 %t to ptr
  #|  %hdr = load i64, ptr %tp, !invariant.load !0
  #|  %tag = and i64 %hdr, 4294967295
  #|  %ist = icmp eq i64 %tag, 20
  #|  %len = lshr i64 %hdr, 32
  #|  %kk = ashr i64 %k, 1
  #|  %inb = icmp ult i64 %kk, %len
  #|  %oki = trunc i64 %k to i1
  #|  %ok1 = and i1 %ist, %inb
  #|  %ok = and i1 %ok1, %oki
  #|  br i1 %ok, label %f, label %slow
  #|f:
  #|  %ep = getelementptr inbounds i8, ptr %tp, i64 8
  #|  %e = load ptr, ptr %ep, !invariant.load !0
  #|  %xp = getelementptr inbounds i64, ptr %e, i64 %kk
  #|  %x = load i64, ptr %xp, !invariant.load !0
  #|  ret i64 %x
  #|slow:
  #|  %r = call i64 @n_tget(i64 %t, i64 %k)
  #|  ret i64 %r
  #|}
  #|
  #|; strings (rt/tstc.h Str: tag 16, start (8), len (12), buf (16); StrBuf: d
  #|; (8)): a view does not change once made, its buffer's code units in it
  #|; neither (appends go past it; the buffer may move, d is loaded)
  #|declare i64 @n_slen(i64)
  #|declare i64 @n_sat(i64, i64)
  #|define internal i64 @tstc_slen(i64 %s) alwaysinline {
  #|entry:
  #|  %lo = and i64 %s, 3
  #|  %isp = icmp eq i64 %lo, 0
  #|  %nz = icmp ne i64 %s, 0
  #|  %ok0 = and i1 %isp, %nz
  #|  br i1 %ok0, label %a, label %slow
  #|a:
  #|  %sp = inttoptr i64 %s to ptr
  #|  %tag = load i32, ptr %sp, !invariant.load !0
  #|  %ist = icmp eq i32 %tag, 16
  #|  br i1 %ist, label %f, label %slow
  #|f:
  #|  %lp = getelementptr inbounds i8, ptr %sp, i64 12
  #|  %len = load i32, ptr %lp, !invariant.load !0
  #|  %l64 = sext i32 %len to i64
  #|  %s2 = shl i64 %l64, 1
  #|  %r = or i64 %s2, 1
  #|  ret i64 %r
  #|slow:
  #|  %rs = call i64 @n_slen(i64 %s)
  #|  ret i64 %rs
  #|}
  #|
  #|define internal i64 @tstc_sat(i64 %s, i64 %iv) alwaysinline {
  #|entry:
  #|  %lo = and i64 %s, 3
  #|  %isp = icmp eq i64 %lo, 0
  #|  %nz = icmp ne i64 %s, 0
  #|  %ii = trunc i64 %iv to i1
  #|  %ok1 = and i1 %isp, %nz
  #|  %ok0 = and i1 %ok1, %ii
  #|  br i1 %ok0, label %a, label %slow
  #|a:
  #|  %sp = inttoptr i64 %s to ptr
  #|  %tag = load i32, ptr %sp, !invariant.load !0
  #|  %ist = icmp eq i32 %tag, 16
  #|  br i1 %ist, label %b, label %slow
  #|b:
  #|  %lp = getelementptr inbounds i8, ptr %sp, i64 12
  #|  %len = load i32, ptr %lp, !invariant.load !0
  #|  %l64 = sext i32 %len to i64
  #|  %i = ashr i64 %iv, 1
  #|  %inb = icmp ult i64 %i, %l64
  #|  br i1 %inb, label %f, label %slow
  #|f:
  #|  %stp = getelementptr inbounds i8, ptr %sp, i64 8
  #|  %st = load i32, ptr %stp, !invariant.load !0
  #|  %st64 = sext i32 %st to i64
  #|  %bp = getelementptr inbounds i8, ptr %sp, i64 16
  #|  %buf = load ptr, ptr %bp, !invariant.load !0
  #|  %dp = getelementptr inbounds i8, ptr %buf, i64 8
  #|  %d = load ptr, ptr %dp
  #|  %ix = add i64 %st64, %i
  #|  %cp = getelementptr inbounds i16, ptr %d, i64 %ix
  #|  %c = load i16, ptr %cp
  #|  %c64 = zext i16 %c to i64
  #|  %c2 = shl i64 %c64, 1
  #|  %r = or i64 %c2, 1
  #|  ret i64 %r
  #|slow:
  #|  %rs = call i64 @n_sat(i64 %s, i64 %iv)
  #|  ret i64 %rs
  #|}
  #|
  #|declare i64 @n_fadd(i64, i64)
  #|declare i64 @n_fsub(i64, i64)
  #|declare i64 @n_fmul(i64, i64)
  #|declare i64 @n_fdiv(i64, i64)
  #|declare i64 @n_feq(i64, i64)
  #|declare i64 @n_fne(i64, i64)
  #|declare i64 @n_flt(i64, i64)
  #|declare i64 @n_fle(i64, i64)
  #|declare i64 @n_fneg(i64)
  #|declare i64 @n_ffloor(i64)
  #|declare double @llvm.floor.f64(double)
  #|declare i64 @n_i2f(i64)
  #|declare i64 @n_f2i(i64)
  #|declare double @llvm.fabs.f64(double)
  #|declare i64 @n_isnan(i64)
  #|; floats (lib/pure's: the integers of their IEEE 754 bits) in the immediate
  #|; forms (rt/tstc.h: 2x + 1, (x ^ 2^62) << 3 | 6) or boxed (IntT: the
  #|; constants of the largest, math.MaxFloat64, ...); results in the immediate
  #|; forms, NaN results (the runtime's are one NaN) and the others by the runtime
  #|define internal i64 @tstc_fadd(i64 %a, i64 %b) alwaysinline {
  #|entry:
  #|  %dai = trunc i64 %a to i1
  #|  br i1 %dai, label %da1, label %da2
  #|da1:
  #|  %daa = ashr i64 %a, 1
  #|  br label %da
  #|da2:
  #|  %da7 = and i64 %a, 7
  #|  %da6 = icmp eq i64 %da7, 6
  #|  br i1 %da6, label %da3, label %da4
  #|da3:
  #|  %das = ashr i64 %a, 3
  #|  %dab = xor i64 %das, 4611686018427387904
  #|  br label %da
  #|da4:
  #|  %danz = icmp ne i64 %a, 0
  #|  %dalo = icmp eq i64 %da7, 0
  #|  %dap = and i1 %danz, %dalo
  #|  br i1 %dap, label %da5, label %slow
  #|da5:
  #|  %dapp = inttoptr i64 %a to ptr
  #|  %datg = load i32, ptr %dapp, !invariant.load !0
  #|  %daisi = icmp eq i32 %datg, 29
  #|  br i1 %daisi, label %da8, label %slow
  #|da8:
  #|  %davp = getelementptr inbounds i8, ptr %dapp, i64 8
  #|  %dac = load i64, ptr %davp, !invariant.load !0
  #|  br label %da
  #|da:
  #|  %av = phi i64 [ %daa, %da1 ], [ %dab, %da3 ], [ %dac, %da8 ]
  #|  br label %db0
  #|db0:
  #|  %dbi = trunc i64 %b to i1
  #|  br i1 %dbi, label %db1, label %db2
  #|db1:
  #|  %dba = ashr i64 %b, 1
  #|  br label %db
  #|db2:
  #|  %db7 = and i64 %b, 7
  #|  %db6 = icmp eq i64 %db7, 6
  #|  br i1 %db6, label %db3, label %db4
  #|db3:
  #|  %dbs = ashr i64 %b, 3
  #|  %dbb = xor i64 %dbs, 4611686018427387904
  #|  br label %db
  #|db4:
  #|  %dbnz = icmp ne i64 %b, 0
  #|  %dblo = icmp eq i64 %db7, 0
  #|  %dbp = and i1 %dbnz, %dblo
  #|  br i1 %dbp, label %db5, label %slow
  #|db5:
  #|  %dbpp = inttoptr i64 %b to ptr
  #|  %dbtg = load i32, ptr %dbpp, !invariant.load !0
  #|  %dbisi = icmp eq i32 %dbtg, 29
  #|  br i1 %dbisi, label %db8, label %slow
  #|db8:
  #|  %dbvp = getelementptr inbounds i8, ptr %dbpp, i64 8
  #|  %dbc = load i64, ptr %dbvp, !invariant.load !0
  #|  br label %db
  #|db:
  #|  %bv = phi i64 [ %dba, %db1 ], [ %dbb, %db3 ], [ %dbc, %db8 ]
  #|  %af = bitcast i64 %av to double
  #|  %bf = bitcast i64 %bv to double
  #|  %rf = fadd double %af, %bf
  #|  %nan = fcmp uno double %rf, 0.0
  #|  br i1 %nan, label %slow, label %enc
  #|enc:
  #|  %rx = bitcast double %rf to i64
  #|  %e2 = shl i64 %rx, 1
  #|  %e2b = ashr i64 %e2, 1
  #|  %efit = icmp eq i64 %e2b, %rx
  #|  br i1 %efit, label %eimm, label %e6
  #|eimm:
  #|  %er1 = or i64 %e2, 1
  #|  br label %done
  #|e6:
  #|  %ey = xor i64 %rx, 4611686018427387904
  #|  %ey3 = shl i64 %ey, 3
  #|  %ey3b = ashr i64 %ey3, 3
  #|  %eyfit = icmp eq i64 %ey3b, %ey
  #|  br i1 %eyfit, label %eimm6, label %slow
  #|eimm6:
  #|  %er6 = or i64 %ey3, 6
  #|  br label %done
  #|done:
  #|  %r = phi i64 [ %er1, %eimm ], [ %er6, %eimm6 ]
  #|  ret i64 %r
  #|slow:
  #|  %rs = call i64 @n_fadd(i64 %a, i64 %b)
  #|  ret i64 %rs
  #|}
  #|
  #|define internal i64 @tstc_fsub(i64 %a, i64 %b) alwaysinline {
  #|entry:
  #|  %dai = trunc i64 %a to i1
  #|  br i1 %dai, label %da1, label %da2
  #|da1:
  #|  %daa = ashr i64 %a, 1
  #|  br label %da
  #|da2:
  #|  %da7 = and i64 %a, 7
  #|  %da6 = icmp eq i64 %da7, 6
  #|  br i1 %da6, label %da3, label %da4
  #|da3:
  #|  %das = ashr i64 %a, 3
  #|  %dab = xor i64 %das, 4611686018427387904
  #|  br label %da
  #|da4:
  #|  %danz = icmp ne i64 %a, 0
  #|  %dalo = icmp eq i64 %da7, 0
  #|  %dap = and i1 %danz, %dalo
  #|  br i1 %dap, label %da5, label %slow
  #|da5:
  #|  %dapp = inttoptr i64 %a to ptr
  #|  %datg = load i32, ptr %dapp, !invariant.load !0
  #|  %daisi = icmp eq i32 %datg, 29
  #|  br i1 %daisi, label %da8, label %slow
  #|da8:
  #|  %davp = getelementptr inbounds i8, ptr %dapp, i64 8
  #|  %dac = load i64, ptr %davp, !invariant.load !0
  #|  br label %da
  #|da:
  #|  %av = phi i64 [ %daa, %da1 ], [ %dab, %da3 ], [ %dac, %da8 ]
  #|  br label %db0
  #|db0:
  #|  %dbi = trunc i64 %b to i1
  #|  br i1 %dbi, label %db1, label %db2
  #|db1:
  #|  %dba = ashr i64 %b, 1
  #|  br label %db
  #|db2:
  #|  %db7 = and i64 %b, 7
  #|  %db6 = icmp eq i64 %db7, 6
  #|  br i1 %db6, label %db3, label %db4
  #|db3:
  #|  %dbs = ashr i64 %b, 3
  #|  %dbb = xor i64 %dbs, 4611686018427387904
  #|  br label %db
  #|db4:
  #|  %dbnz = icmp ne i64 %b, 0
  #|  %dblo = icmp eq i64 %db7, 0
  #|  %dbp = and i1 %dbnz, %dblo
  #|  br i1 %dbp, label %db5, label %slow
  #|db5:
  #|  %dbpp = inttoptr i64 %b to ptr
  #|  %dbtg = load i32, ptr %dbpp, !invariant.load !0
  #|  %dbisi = icmp eq i32 %dbtg, 29
  #|  br i1 %dbisi, label %db8, label %slow
  #|db8:
  #|  %dbvp = getelementptr inbounds i8, ptr %dbpp, i64 8
  #|  %dbc = load i64, ptr %dbvp, !invariant.load !0
  #|  br label %db
  #|db:
  #|  %bv = phi i64 [ %dba, %db1 ], [ %dbb, %db3 ], [ %dbc, %db8 ]
  #|  %af = bitcast i64 %av to double
  #|  %bf = bitcast i64 %bv to double
  #|  %rf = fsub double %af, %bf
  #|  %nan = fcmp uno double %rf, 0.0
  #|  br i1 %nan, label %slow, label %enc
  #|enc:
  #|  %rx = bitcast double %rf to i64
  #|  %e2 = shl i64 %rx, 1
  #|  %e2b = ashr i64 %e2, 1
  #|  %efit = icmp eq i64 %e2b, %rx
  #|  br i1 %efit, label %eimm, label %e6
  #|eimm:
  #|  %er1 = or i64 %e2, 1
  #|  br label %done
  #|e6:
  #|  %ey = xor i64 %rx, 4611686018427387904
  #|  %ey3 = shl i64 %ey, 3
  #|  %ey3b = ashr i64 %ey3, 3
  #|  %eyfit = icmp eq i64 %ey3b, %ey
  #|  br i1 %eyfit, label %eimm6, label %slow
  #|eimm6:
  #|  %er6 = or i64 %ey3, 6
  #|  br label %done
  #|done:
  #|  %r = phi i64 [ %er1, %eimm ], [ %er6, %eimm6 ]
  #|  ret i64 %r
  #|slow:
  #|  %rs = call i64 @n_fsub(i64 %a, i64 %b)
  #|  ret i64 %rs
  #|}
  #|
  #|define internal i64 @tstc_fmul(i64 %a, i64 %b) alwaysinline {
  #|entry:
  #|  %dai = trunc i64 %a to i1
  #|  br i1 %dai, label %da1, label %da2
  #|da1:
  #|  %daa = ashr i64 %a, 1
  #|  br label %da
  #|da2:
  #|  %da7 = and i64 %a, 7
  #|  %da6 = icmp eq i64 %da7, 6
  #|  br i1 %da6, label %da3, label %da4
  #|da3:
  #|  %das = ashr i64 %a, 3
  #|  %dab = xor i64 %das, 4611686018427387904
  #|  br label %da
  #|da4:
  #|  %danz = icmp ne i64 %a, 0
  #|  %dalo = icmp eq i64 %da7, 0
  #|  %dap = and i1 %danz, %dalo
  #|  br i1 %dap, label %da5, label %slow
  #|da5:
  #|  %dapp = inttoptr i64 %a to ptr
  #|  %datg = load i32, ptr %dapp, !invariant.load !0
  #|  %daisi = icmp eq i32 %datg, 29
  #|  br i1 %daisi, label %da8, label %slow
  #|da8:
  #|  %davp = getelementptr inbounds i8, ptr %dapp, i64 8
  #|  %dac = load i64, ptr %davp, !invariant.load !0
  #|  br label %da
  #|da:
  #|  %av = phi i64 [ %daa, %da1 ], [ %dab, %da3 ], [ %dac, %da8 ]
  #|  br label %db0
  #|db0:
  #|  %dbi = trunc i64 %b to i1
  #|  br i1 %dbi, label %db1, label %db2
  #|db1:
  #|  %dba = ashr i64 %b, 1
  #|  br label %db
  #|db2:
  #|  %db7 = and i64 %b, 7
  #|  %db6 = icmp eq i64 %db7, 6
  #|  br i1 %db6, label %db3, label %db4
  #|db3:
  #|  %dbs = ashr i64 %b, 3
  #|  %dbb = xor i64 %dbs, 4611686018427387904
  #|  br label %db
  #|db4:
  #|  %dbnz = icmp ne i64 %b, 0
  #|  %dblo = icmp eq i64 %db7, 0
  #|  %dbp = and i1 %dbnz, %dblo
  #|  br i1 %dbp, label %db5, label %slow
  #|db5:
  #|  %dbpp = inttoptr i64 %b to ptr
  #|  %dbtg = load i32, ptr %dbpp, !invariant.load !0
  #|  %dbisi = icmp eq i32 %dbtg, 29
  #|  br i1 %dbisi, label %db8, label %slow
  #|db8:
  #|  %dbvp = getelementptr inbounds i8, ptr %dbpp, i64 8
  #|  %dbc = load i64, ptr %dbvp, !invariant.load !0
  #|  br label %db
  #|db:
  #|  %bv = phi i64 [ %dba, %db1 ], [ %dbb, %db3 ], [ %dbc, %db8 ]
  #|  %af = bitcast i64 %av to double
  #|  %bf = bitcast i64 %bv to double
  #|  %rf = fmul double %af, %bf
  #|  %nan = fcmp uno double %rf, 0.0
  #|  br i1 %nan, label %slow, label %enc
  #|enc:
  #|  %rx = bitcast double %rf to i64
  #|  %e2 = shl i64 %rx, 1
  #|  %e2b = ashr i64 %e2, 1
  #|  %efit = icmp eq i64 %e2b, %rx
  #|  br i1 %efit, label %eimm, label %e6
  #|eimm:
  #|  %er1 = or i64 %e2, 1
  #|  br label %done
  #|e6:
  #|  %ey = xor i64 %rx, 4611686018427387904
  #|  %ey3 = shl i64 %ey, 3
  #|  %ey3b = ashr i64 %ey3, 3
  #|  %eyfit = icmp eq i64 %ey3b, %ey
  #|  br i1 %eyfit, label %eimm6, label %slow
  #|eimm6:
  #|  %er6 = or i64 %ey3, 6
  #|  br label %done
  #|done:
  #|  %r = phi i64 [ %er1, %eimm ], [ %er6, %eimm6 ]
  #|  ret i64 %r
  #|slow:
  #|  %rs = call i64 @n_fmul(i64 %a, i64 %b)
  #|  ret i64 %rs
  #|}
  #|
  #|define internal i64 @tstc_fdiv(i64 %a, i64 %b) alwaysinline {
  #|entry:
  #|  %dai = trunc i64 %a to i1
  #|  br i1 %dai, label %da1, label %da2
  #|da1:
  #|  %daa = ashr i64 %a, 1
  #|  br label %da
  #|da2:
  #|  %da7 = and i64 %a, 7
  #|  %da6 = icmp eq i64 %da7, 6
  #|  br i1 %da6, label %da3, label %da4
  #|da3:
  #|  %das = ashr i64 %a, 3
  #|  %dab = xor i64 %das, 4611686018427387904
  #|  br label %da
  #|da4:
  #|  %danz = icmp ne i64 %a, 0
  #|  %dalo = icmp eq i64 %da7, 0
  #|  %dap = and i1 %danz, %dalo
  #|  br i1 %dap, label %da5, label %slow
  #|da5:
  #|  %dapp = inttoptr i64 %a to ptr
  #|  %datg = load i32, ptr %dapp, !invariant.load !0
  #|  %daisi = icmp eq i32 %datg, 29
  #|  br i1 %daisi, label %da8, label %slow
  #|da8:
  #|  %davp = getelementptr inbounds i8, ptr %dapp, i64 8
  #|  %dac = load i64, ptr %davp, !invariant.load !0
  #|  br label %da
  #|da:
  #|  %av = phi i64 [ %daa, %da1 ], [ %dab, %da3 ], [ %dac, %da8 ]
  #|  br label %db0
  #|db0:
  #|  %dbi = trunc i64 %b to i1
  #|  br i1 %dbi, label %db1, label %db2
  #|db1:
  #|  %dba = ashr i64 %b, 1
  #|  br label %db
  #|db2:
  #|  %db7 = and i64 %b, 7
  #|  %db6 = icmp eq i64 %db7, 6
  #|  br i1 %db6, label %db3, label %db4
  #|db3:
  #|  %dbs = ashr i64 %b, 3
  #|  %dbb = xor i64 %dbs, 4611686018427387904
  #|  br label %db
  #|db4:
  #|  %dbnz = icmp ne i64 %b, 0
  #|  %dblo = icmp eq i64 %db7, 0
  #|  %dbp = and i1 %dbnz, %dblo
  #|  br i1 %dbp, label %db5, label %slow
  #|db5:
  #|  %dbpp = inttoptr i64 %b to ptr
  #|  %dbtg = load i32, ptr %dbpp, !invariant.load !0
  #|  %dbisi = icmp eq i32 %dbtg, 29
  #|  br i1 %dbisi, label %db8, label %slow
  #|db8:
  #|  %dbvp = getelementptr inbounds i8, ptr %dbpp, i64 8
  #|  %dbc = load i64, ptr %dbvp, !invariant.load !0
  #|  br label %db
  #|db:
  #|  %bv = phi i64 [ %dba, %db1 ], [ %dbb, %db3 ], [ %dbc, %db8 ]
  #|  %af = bitcast i64 %av to double
  #|  %bf = bitcast i64 %bv to double
  #|  %rf = fdiv double %af, %bf
  #|  %nan = fcmp uno double %rf, 0.0
  #|  br i1 %nan, label %slow, label %enc
  #|enc:
  #|  %rx = bitcast double %rf to i64
  #|  %e2 = shl i64 %rx, 1
  #|  %e2b = ashr i64 %e2, 1
  #|  %efit = icmp eq i64 %e2b, %rx
  #|  br i1 %efit, label %eimm, label %e6
  #|eimm:
  #|  %er1 = or i64 %e2, 1
  #|  br label %done
  #|e6:
  #|  %ey = xor i64 %rx, 4611686018427387904
  #|  %ey3 = shl i64 %ey, 3
  #|  %ey3b = ashr i64 %ey3, 3
  #|  %eyfit = icmp eq i64 %ey3b, %ey
  #|  br i1 %eyfit, label %eimm6, label %slow
  #|eimm6:
  #|  %er6 = or i64 %ey3, 6
  #|  br label %done
  #|done:
  #|  %r = phi i64 [ %er1, %eimm ], [ %er6, %eimm6 ]
  #|  ret i64 %r
  #|slow:
  #|  %rs = call i64 @n_fdiv(i64 %a, i64 %b)
  #|  ret i64 %rs
  #|}
  #|
  #|define internal i64 @tstc_feq(i64 %a, i64 %b) alwaysinline {
  #|entry:
  #|  %dai = trunc i64 %a to i1
  #|  br i1 %dai, label %da1, label %da2
  #|da1:
  #|  %daa = ashr i64 %a, 1
  #|  br label %da
  #|da2:
  #|  %da7 = and i64 %a, 7
  #|  %da6 = icmp eq i64 %da7, 6
  #|  br i1 %da6, label %da3, label %da4
  #|da3:
  #|  %das = ashr i64 %a, 3
  #|  %dab = xor i64 %das, 4611686018427387904
  #|  br label %da
  #|da4:
  #|  %danz = icmp ne i64 %a, 0
  #|  %dalo = icmp eq i64 %da7, 0
  #|  %dap = and i1 %danz, %dalo
  #|  br i1 %dap, label %da5, label %slow
  #|da5:
  #|  %dapp = inttoptr i64 %a to ptr
  #|  %datg = load i32, ptr %dapp, !invariant.load !0
  #|  %daisi = icmp eq i32 %datg, 29
  #|  br i1 %daisi, label %da8, label %slow
  #|da8:
  #|  %davp = getelementptr inbounds i8, ptr %dapp, i64 8
  #|  %dac = load i64, ptr %davp, !invariant.load !0
  #|  br label %da
  #|da:
  #|  %av = phi i64 [ %daa, %da1 ], [ %dab, %da3 ], [ %dac, %da8 ]
  #|  br label %db0
  #|db0:
  #|  %dbi = trunc i64 %b to i1
  #|  br i1 %dbi, label %db1, label %db2
  #|db1:
  #|  %dba = ashr i64 %b, 1
  #|  br label %db
  #|db2:
  #|  %db7 = and i64 %b, 7
  #|  %db6 = icmp eq i64 %db7, 6
  #|  br i1 %db6, label %db3, label %db4
  #|db3:
  #|  %dbs = ashr i64 %b, 3
  #|  %dbb = xor i64 %dbs, 4611686018427387904
  #|  br label %db
  #|db4:
  #|  %dbnz = icmp ne i64 %b, 0
  #|  %dblo = icmp eq i64 %db7, 0
  #|  %dbp = and i1 %dbnz, %dblo
  #|  br i1 %dbp, label %db5, label %slow
  #|db5:
  #|  %dbpp = inttoptr i64 %b to ptr
  #|  %dbtg = load i32, ptr %dbpp, !invariant.load !0
  #|  %dbisi = icmp eq i32 %dbtg, 29
  #|  br i1 %dbisi, label %db8, label %slow
  #|db8:
  #|  %dbvp = getelementptr inbounds i8, ptr %dbpp, i64 8
  #|  %dbc = load i64, ptr %dbvp, !invariant.load !0
  #|  br label %db
  #|db:
  #|  %bv = phi i64 [ %dba, %db1 ], [ %dbb, %db3 ], [ %dbc, %db8 ]
  #|  %af = bitcast i64 %av to double
  #|  %bf = bitcast i64 %bv to double
  #|  %c = fcmp oeq double %af, %bf
  #|  %r = select i1 %c, i64 90, i64 98
  #|  ret i64 %r
  #|slow:
  #|  %rs = call i64 @n_feq(i64 %a, i64 %b)
  #|  ret i64 %rs
  #|}
  #|
  #|define internal i64 @tstc_fne(i64 %a, i64 %b) alwaysinline {
  #|entry:
  #|  %dai = trunc i64 %a to i1
  #|  br i1 %dai, label %da1, label %da2
  #|da1:
  #|  %daa = ashr i64 %a, 1
  #|  br label %da
  #|da2:
  #|  %da7 = and i64 %a, 7
  #|  %da6 = icmp eq i64 %da7, 6
  #|  br i1 %da6, label %da3, label %da4
  #|da3:
  #|  %das = ashr i64 %a, 3
  #|  %dab = xor i64 %das, 4611686018427387904
  #|  br label %da
  #|da4:
  #|  %danz = icmp ne i64 %a, 0
  #|  %dalo = icmp eq i64 %da7, 0
  #|  %dap = and i1 %danz, %dalo
  #|  br i1 %dap, label %da5, label %slow
  #|da5:
  #|  %dapp = inttoptr i64 %a to ptr
  #|  %datg = load i32, ptr %dapp, !invariant.load !0
  #|  %daisi = icmp eq i32 %datg, 29
  #|  br i1 %daisi, label %da8, label %slow
  #|da8:
  #|  %davp = getelementptr inbounds i8, ptr %dapp, i64 8
  #|  %dac = load i64, ptr %davp, !invariant.load !0
  #|  br label %da
  #|da:
  #|  %av = phi i64 [ %daa, %da1 ], [ %dab, %da3 ], [ %dac, %da8 ]
  #|  br label %db0
  #|db0:
  #|  %dbi = trunc i64 %b to i1
  #|  br i1 %dbi, label %db1, label %db2
  #|db1:
  #|  %dba = ashr i64 %b, 1
  #|  br label %db
  #|db2:
  #|  %db7 = and i64 %b, 7
  #|  %db6 = icmp eq i64 %db7, 6
  #|  br i1 %db6, label %db3, label %db4
  #|db3:
  #|  %dbs = ashr i64 %b, 3
  #|  %dbb = xor i64 %dbs, 4611686018427387904
  #|  br label %db
  #|db4:
  #|  %dbnz = icmp ne i64 %b, 0
  #|  %dblo = icmp eq i64 %db7, 0
  #|  %dbp = and i1 %dbnz, %dblo
  #|  br i1 %dbp, label %db5, label %slow
  #|db5:
  #|  %dbpp = inttoptr i64 %b to ptr
  #|  %dbtg = load i32, ptr %dbpp, !invariant.load !0
  #|  %dbisi = icmp eq i32 %dbtg, 29
  #|  br i1 %dbisi, label %db8, label %slow
  #|db8:
  #|  %dbvp = getelementptr inbounds i8, ptr %dbpp, i64 8
  #|  %dbc = load i64, ptr %dbvp, !invariant.load !0
  #|  br label %db
  #|db:
  #|  %bv = phi i64 [ %dba, %db1 ], [ %dbb, %db3 ], [ %dbc, %db8 ]
  #|  %af = bitcast i64 %av to double
  #|  %bf = bitcast i64 %bv to double
  #|  %c = fcmp une double %af, %bf
  #|  %r = select i1 %c, i64 90, i64 98
  #|  ret i64 %r
  #|slow:
  #|  %rs = call i64 @n_fne(i64 %a, i64 %b)
  #|  ret i64 %rs
  #|}
  #|
  #|define internal i64 @tstc_flt(i64 %a, i64 %b) alwaysinline {
  #|entry:
  #|  %dai = trunc i64 %a to i1
  #|  br i1 %dai, label %da1, label %da2
  #|da1:
  #|  %daa = ashr i64 %a, 1
  #|  br label %da
  #|da2:
  #|  %da7 = and i64 %a, 7
  #|  %da6 = icmp eq i64 %da7, 6
  #|  br i1 %da6, label %da3, label %da4
  #|da3:
  #|  %das = ashr i64 %a, 3
  #|  %dab = xor i64 %das, 4611686018427387904
  #|  br label %da
  #|da4:
  #|  %danz = icmp ne i64 %a, 0
  #|  %dalo = icmp eq i64 %da7, 0
  #|  %dap = and i1 %danz, %dalo
  #|  br i1 %dap, label %da5, label %slow
  #|da5:
  #|  %dapp = inttoptr i64 %a to ptr
  #|  %datg = load i32, ptr %dapp, !invariant.load !0
  #|  %daisi = icmp eq i32 %datg, 29
  #|  br i1 %daisi, label %da8, label %slow
  #|da8:
  #|  %davp = getelementptr inbounds i8, ptr %dapp, i64 8
  #|  %dac = load i64, ptr %davp, !invariant.load !0
  #|  br label %da
  #|da:
  #|  %av = phi i64 [ %daa, %da1 ], [ %dab, %da3 ], [ %dac, %da8 ]
  #|  br label %db0
  #|db0:
  #|  %dbi = trunc i64 %b to i1
  #|  br i1 %dbi, label %db1, label %db2
  #|db1:
  #|  %dba = ashr i64 %b, 1
  #|  br label %db
  #|db2:
  #|  %db7 = and i64 %b, 7
  #|  %db6 = icmp eq i64 %db7, 6
  #|  br i1 %db6, label %db3, label %db4
  #|db3:
  #|  %dbs = ashr i64 %b, 3
  #|  %dbb = xor i64 %dbs, 4611686018427387904
  #|  br label %db
  #|db4:
  #|  %dbnz = icmp ne i64 %b, 0
  #|  %dblo = icmp eq i64 %db7, 0
  #|  %dbp = and i1 %dbnz, %dblo
  #|  br i1 %dbp, label %db5, label %slow
  #|db5:
  #|  %dbpp = inttoptr i64 %b to ptr
  #|  %dbtg = load i32, ptr %dbpp, !invariant.load !0
  #|  %dbisi = icmp eq i32 %dbtg, 29
  #|  br i1 %dbisi, label %db8, label %slow
  #|db8:
  #|  %dbvp = getelementptr inbounds i8, ptr %dbpp, i64 8
  #|  %dbc = load i64, ptr %dbvp, !invariant.load !0
  #|  br label %db
  #|db:
  #|  %bv = phi i64 [ %dba, %db1 ], [ %dbb, %db3 ], [ %dbc, %db8 ]
  #|  %af = bitcast i64 %av to double
  #|  %bf = bitcast i64 %bv to double
  #|  %c = fcmp olt double %af, %bf
  #|  %r = select i1 %c, i64 90, i64 98
  #|  ret i64 %r
  #|slow:
  #|  %rs = call i64 @n_flt(i64 %a, i64 %b)
  #|  ret i64 %rs
  #|}
  #|
  #|define internal i64 @tstc_fle(i64 %a, i64 %b) alwaysinline {
  #|entry:
  #|  %dai = trunc i64 %a to i1
  #|  br i1 %dai, label %da1, label %da2
  #|da1:
  #|  %daa = ashr i64 %a, 1
  #|  br label %da
  #|da2:
  #|  %da7 = and i64 %a, 7
  #|  %da6 = icmp eq i64 %da7, 6
  #|  br i1 %da6, label %da3, label %da4
  #|da3:
  #|  %das = ashr i64 %a, 3
  #|  %dab = xor i64 %das, 4611686018427387904
  #|  br label %da
  #|da4:
  #|  %danz = icmp ne i64 %a, 0
  #|  %dalo = icmp eq i64 %da7, 0
  #|  %dap = and i1 %danz, %dalo
  #|  br i1 %dap, label %da5, label %slow
  #|da5:
  #|  %dapp = inttoptr i64 %a to ptr
  #|  %datg = load i32, ptr %dapp, !invariant.load !0
  #|  %daisi = icmp eq i32 %datg, 29
  #|  br i1 %daisi, label %da8, label %slow
  #|da8:
  #|  %davp = getelementptr inbounds i8, ptr %dapp, i64 8
  #|  %dac = load i64, ptr %davp, !invariant.load !0
  #|  br label %da
  #|da:
  #|  %av = phi i64 [ %daa, %da1 ], [ %dab, %da3 ], [ %dac, %da8 ]
  #|  br label %db0
  #|db0:
  #|  %dbi = trunc i64 %b to i1
  #|  br i1 %dbi, label %db1, label %db2
  #|db1:
  #|  %dba = ashr i64 %b, 1
  #|  br label %db
  #|db2:
  #|  %db7 = and i64 %b, 7
  #|  %db6 = icmp eq i64 %db7, 6
  #|  br i1 %db6, label %db3, label %db4
  #|db3:
  #|  %dbs = ashr i64 %b, 3
  #|  %dbb = xor i64 %dbs, 4611686018427387904
  #|  br label %db
  #|db4:
  #|  %dbnz = icmp ne i64 %b, 0
  #|  %dblo = icmp eq i64 %db7, 0
  #|  %dbp = and i1 %dbnz, %dblo
  #|  br i1 %dbp, label %db5, label %slow
  #|db5:
  #|  %dbpp = inttoptr i64 %b to ptr
  #|  %dbtg = load i32, ptr %dbpp, !invariant.load !0
  #|  %dbisi = icmp eq i32 %dbtg, 29
  #|  br i1 %dbisi, label %db8, label %slow
  #|db8:
  #|  %dbvp = getelementptr inbounds i8, ptr %dbpp, i64 8
  #|  %dbc = load i64, ptr %dbvp, !invariant.load !0
  #|  br label %db
  #|db:
  #|  %bv = phi i64 [ %dba, %db1 ], [ %dbb, %db3 ], [ %dbc, %db8 ]
  #|  %af = bitcast i64 %av to double
  #|  %bf = bitcast i64 %bv to double
  #|  %c = fcmp ole double %af, %bf
  #|  %r = select i1 %c, i64 90, i64 98
  #|  ret i64 %r
  #|slow:
  #|  %rs = call i64 @n_fle(i64 %a, i64 %b)
  #|  ret i64 %rs
  #|}
  #|
  #|; (the sign bit flipped: of a NaN too)
  #|define internal i64 @tstc_fneg(i64 %a) alwaysinline {
  #|entry:
  #|  %dai = trunc i64 %a to i1
  #|  br i1 %dai, label %da1, label %da2
  #|da1:
  #|  %daa = ashr i64 %a, 1
  #|  br label %da
  #|da2:
  #|  %da7 = and i64 %a, 7
  #|  %da6 = icmp eq i64 %da7, 6
  #|  br i1 %da6, label %da3, label %da4
  #|da3:
  #|  %das = ashr i64 %a, 3
  #|  %dab = xor i64 %das, 4611686018427387904
  #|  br label %da
  #|da4:
  #|  %danz = icmp ne i64 %a, 0
  #|  %dalo = icmp eq i64 %da7, 0
  #|  %dap = and i1 %danz, %dalo
  #|  br i1 %dap, label %da5, label %slow
  #|da5:
  #|  %dapp = inttoptr i64 %a to ptr
  #|  %datg = load i32, ptr %dapp, !invariant.load !0
  #|  %daisi = icmp eq i32 %datg, 29
  #|  br i1 %daisi, label %da8, label %slow
  #|da8:
  #|  %davp = getelementptr inbounds i8, ptr %dapp, i64 8
  #|  %dac = load i64, ptr %davp, !invariant.load !0
  #|  br label %da
  #|da:
  #|  %av = phi i64 [ %daa, %da1 ], [ %dab, %da3 ], [ %dac, %da8 ]
  #|  %rx = xor i64 %av, -9223372036854775808
  #|  %e2 = shl i64 %rx, 1
  #|  %e2b = ashr i64 %e2, 1
  #|  %efit = icmp eq i64 %e2b, %rx
  #|  br i1 %efit, label %eimm, label %e6
  #|eimm:
  #|  %er1 = or i64 %e2, 1
  #|  br label %done
  #|e6:
  #|  %ey = xor i64 %rx, 4611686018427387904
  #|  %ey3 = shl i64 %ey, 3
  #|  %ey3b = ashr i64 %ey3, 3
  #|  %eyfit = icmp eq i64 %ey3b, %ey
  #|  br i1 %eyfit, label %eimm6, label %slow
  #|eimm6:
  #|  %er6 = or i64 %ey3, 6
  #|  br label %done
  #|done:
  #|  %r = phi i64 [ %er1, %eimm ], [ %er6, %eimm6 ]
  #|  ret i64 %r
  #|slow:
  #|  %rs = call i64 @n_fneg(i64 %a)
  #|  ret i64 %rs
  #|}
  #|
  #|define internal i64 @tstc_ffloor(i64 %a) alwaysinline {
  #|entry:
  #|  %dai = trunc i64 %a to i1
  #|  br i1 %dai, label %da1, label %da2
  #|da1:
  #|  %daa = ashr i64 %a, 1
  #|  br label %da
  #|da2:
  #|  %da7 = and i64 %a, 7
  #|  %da6 = icmp eq i64 %da7, 6
  #|  br i1 %da6, label %da3, label %da4
  #|da3:
  #|  %das = ashr i64 %a, 3
  #|  %dab = xor i64 %das, 4611686018427387904
  #|  br label %da
  #|da4:
  #|  %danz = icmp ne i64 %a, 0
  #|  %dalo = icmp eq i64 %da7, 0
  #|  %dap = and i1 %danz, %dalo
  #|  br i1 %dap, label %da5, label %slow
  #|da5:
  #|  %dapp = inttoptr i64 %a to ptr
  #|  %datg = load i32, ptr %dapp, !invariant.load !0
  #|  %daisi = icmp eq i32 %datg, 29
  #|  br i1 %daisi, label %da8, label %slow
  #|da8:
  #|  %davp = getelementptr inbounds i8, ptr %dapp, i64 8
  #|  %dac = load i64, ptr %davp, !invariant.load !0
  #|  br label %da
  #|da:
  #|  %av = phi i64 [ %daa, %da1 ], [ %dab, %da3 ], [ %dac, %da8 ]
  #|  %af = bitcast i64 %av to double
  #|  %rf = call double @llvm.floor.f64(double %af)
  #|  %nan = fcmp uno double %rf, 0.0
  #|  br i1 %nan, label %slow, label %enc
  #|enc:
  #|  %rx = bitcast double %rf to i64
  #|  %e2 = shl i64 %rx, 1
  #|  %e2b = ashr i64 %e2, 1
  #|  %efit = icmp eq i64 %e2b, %rx
  #|  br i1 %efit, label %eimm, label %e6
  #|eimm:
  #|  %er1 = or i64 %e2, 1
  #|  br label %done
  #|e6:
  #|  %ey = xor i64 %rx, 4611686018427387904
  #|  %ey3 = shl i64 %ey, 3
  #|  %ey3b = ashr i64 %ey3, 3
  #|  %eyfit = icmp eq i64 %ey3b, %ey
  #|  br i1 %eyfit, label %eimm6, label %slow
  #|eimm6:
  #|  %er6 = or i64 %ey3, 6
  #|  br label %done
  #|done:
  #|  %r = phi i64 [ %er1, %eimm ], [ %er6, %eimm6 ]
  #|  ret i64 %r
  #|slow:
  #|  %rs = call i64 @n_ffloor(i64 %a)
  #|  ret i64 %rs
  #|}
  #|
  #|; (of an immediate integer)
  #|define internal i64 @tstc_i2f(i64 %a) alwaysinline {
  #|entry:
  #|  %ai = trunc i64 %a to i1
  #|  br i1 %ai, label %ia, label %slow
  #|ia:
  #|  %ax = ashr i64 %a, 1
  #|  %rf = sitofp i64 %ax to double
  #|  %rx = bitcast double %rf to i64
  #|  %e2 = shl i64 %rx, 1
  #|  %e2b = ashr i64 %e2, 1
  #|  %efit = icmp eq i64 %e2b, %rx
  #|  br i1 %efit, label %eimm, label %e6
  #|eimm:
  #|  %er1 = or i64 %e2, 1
  #|  br label %done
  #|e6:
  #|  %ey = xor i64 %rx, 4611686018427387904
  #|  %ey3 = shl i64 %ey, 3
  #|  %ey3b = ashr i64 %ey3, 3
  #|  %eyfit = icmp eq i64 %ey3b, %ey
  #|  br i1 %eyfit, label %eimm6, label %slow
  #|eimm6:
  #|  %er6 = or i64 %ey3, 6
  #|  br label %done
  #|done:
  #|  %r = phi i64 [ %er1, %eimm ], [ %er6, %eimm6 ]
  #|  ret i64 %r
  #|slow:
  #|  %rs = call i64 @n_i2f(i64 %a)
  #|  ret i64 %rs
  #|}
  #|
  #|; (truncation, of a magnitude below 2^62: an immediate)
  #|define internal i64 @tstc_f2i(i64 %a) alwaysinline {
  #|entry:
  #|  %dai = trunc i64 %a to i1
  #|  br i1 %dai, label %da1, label %da2
  #|da1:
  #|  %daa = ashr i64 %a, 1
  #|  br label %da
  #|da2:
  #|  %da7 = and i64 %a, 7
  #|  %da6 = icmp eq i64 %da7, 6
  #|  br i1 %da6, label %da3, label %da4
  #|da3:
  #|  %das = ashr i64 %a, 3
  #|  %dab = xor i64 %das, 4611686018427387904
  #|  br label %da
  #|da4:
  #|  %danz = icmp ne i64 %a, 0
  #|  %dalo = icmp eq i64 %da7, 0
  #|  %dap = and i1 %danz, %dalo
  #|  br i1 %dap, label %da5, label %slow
  #|da5:
  #|  %dapp = inttoptr i64 %a to ptr
  #|  %datg = load i32, ptr %dapp, !invariant.load !0
  #|  %daisi = icmp eq i32 %datg, 29
  #|  br i1 %daisi, label %da8, label %slow
  #|da8:
  #|  %davp = getelementptr inbounds i8, ptr %dapp, i64 8
  #|  %dac = load i64, ptr %davp, !invariant.load !0
  #|  br label %da
  #|da:
  #|  %av = phi i64 [ %daa, %da1 ], [ %dab, %da3 ], [ %dac, %da8 ]
  #|  %af = bitcast i64 %av to double
  #|  %fa = call double @llvm.fabs.f64(double %af)
  #|  %small = fcmp olt double %fa, 4.611686018427388e18
  #|  br i1 %small, label %t, label %slow
  #|t:
  #|  %ti = fptosi double %af to i64
  #|  %t2 = shl i64 %ti, 1
  #|  %r = or i64 %t2, 1
  #|  ret i64 %r
  #|slow:
  #|  %rs = call i64 @n_f2i(i64 %a)
  #|  ret i64 %rs
  #|}
  #|
  #|define internal i64 @tstc_isnan(i64 %a) alwaysinline {
  #|entry:
  #|  %dai = trunc i64 %a to i1
  #|  br i1 %dai, label %da1, label %da2
  #|da1:
  #|  %daa = ashr i64 %a, 1
  #|  br label %da
  #|da2:
  #|  %da7 = and i64 %a, 7
  #|  %da6 = icmp eq i64 %da7, 6
  #|  br i1 %da6, label %da3, label %da4
  #|da3:
  #|  %das = ashr i64 %a, 3
  #|  %dab = xor i64 %das, 4611686018427387904
  #|  br label %da
  #|da4:
  #|  %danz = icmp ne i64 %a, 0
  #|  %dalo = icmp eq i64 %da7, 0
  #|  %dap = and i1 %danz, %dalo
  #|  br i1 %dap, label %da5, label %slow
  #|da5:
  #|  %dapp = inttoptr i64 %a to ptr
  #|  %datg = load i32, ptr %dapp, !invariant.load !0
  #|  %daisi = icmp eq i32 %datg, 29
  #|  br i1 %daisi, label %da8, label %slow
  #|da8:
  #|  %davp = getelementptr inbounds i8, ptr %dapp, i64 8
  #|  %dac = load i64, ptr %davp, !invariant.load !0
  #|  br label %da
  #|da:
  #|  %av = phi i64 [ %daa, %da1 ], [ %dab, %da3 ], [ %dac, %da8 ]
  #|  %af = bitcast i64 %av to double
  #|  %c = fcmp uno double %af, 0.0
  #|  %r = select i1 %c, i64 90, i64 98
  #|  ret i64 %r
  #|slow:
  #|  %rs = call i64 @n_isnan(i64 %a)
  #|  ret i64 %rs
  #|}
  #|
  #|; &s[i]: a slice is the tuple [pointer, length, capacity]
  #|define internal i64 @tstc_sidx(i64 %s, i64 %i, i64 %stride) alwaysinline {
  #|entry:
  #|  %lo = and i64 %s, 3
  #|  %isp = icmp eq i64 %lo, 0
  #|  br i1 %isp, label %a, label %slow
  #|a:
  #|  %sp = inttoptr i64 %s to ptr
  #|  %hdr = load i64, ptr %sp, !invariant.load !0
  #|  %tag = and i64 %hdr, 4294967295
  #|  %ist = icmp eq i64 %tag, 20
  #|  %len = lshr i64 %hdr, 32
  #|  %l3 = icmp ugt i64 %len, 2
  #|  %ok1 = and i1 %ist, %l3
  #|  br i1 %ok1, label %b, label %slow
  #|b:
  #|  %ep = getelementptr inbounds i8, ptr %sp, i64 8
  #|  %e = load ptr, ptr %ep, !invariant.load !0
  #|  %pv = load i64, ptr %e, !invariant.load !0
  #|  %lnp = getelementptr inbounds i64, ptr %e, i64 1
  #|  %ln = load i64, ptr %lnp, !invariant.load !0
  #|  %b1 = and i64 %pv, %ln
  #|  %b2 = and i64 %i, %stride
  #|  %b3 = and i64 %b1, %b2
  #|  %ints = trunc i64 %b3 to i1
  #|  %kk = ashr i64 %i, 1
  #|  %n = ashr i64 %ln, 1
  #|  %inb = icmp ult i64 %kk, %n
  #|  %ok = and i1 %ints, %inb
  #|  br i1 %ok, label %f, label %slow
  #|f:
  #|  %st2 = sub i64 %stride, 1
  #|  %off = mul i64 %kk, %st2
  #|  %r = add i64 %pv, %off
  #|  ret i64 %r
  #|slow:
  #|  %rs = call i64 @n_sidx(i64 %s, i64 %i, i64 %stride)
  #|  ret i64 %rs
  #|}
  #|
  #|declare i64 @n_ta1(i64, i64)
  #|declare { i64, i64 } @n_ta2(i64, i64, i64)
  #|
  #|; the value of interface value x (the tuple [type id, value]) of type id
  #|define internal { i64, i1 } @tstc_ta(i64 %x, i64 %id) alwaysinline {
  #|entry:
  #|  %lo = and i64 %x, 3
  #|  %isp = icmp eq i64 %lo, 0
  #|  br i1 %isp, label %a, label %no
  #|a:
  #|  %xp = inttoptr i64 %x to ptr
  #|  %hdr = load i64, ptr %xp, !invariant.load !0
  #|  %tag = and i64 %hdr, 4294967295
  #|  %ist = icmp eq i64 %tag, 20
  #|  %len = lshr i64 %hdr, 32
  #|  %l2 = icmp ugt i64 %len, 1
  #|  %ok1 = and i1 %ist, %l2
  #|  br i1 %ok1, label %b, label %no
  #|b:
  #|  %ep = getelementptr inbounds i8, ptr %xp, i64 8
  #|  %e = load ptr, ptr %ep, !invariant.load !0
  #|  %t = load i64, ptr %e, !invariant.load !0
  #|  %vp = getelementptr inbounds i64, ptr %e, i64 1
  #|  %v = load i64, ptr %vp, !invariant.load !0
  #|  %same = icmp eq i64 %t, %id
  #|  %idi = trunc i64 %id to i1
  #|  %ok = and i1 %same, %idi
  #|  %r0 = insertvalue { i64, i1 } poison, i64 %v, 0
  #|  %r1 = insertvalue { i64, i1 } %r0, i1 %ok, 1
  #|  ret { i64, i1 } %r1
  #|no:
  #|  ret { i64, i1 } { i64 0, i1 false }
  #|}
  #|
  #|define internal i64 @tstc_ta1(i64 %x, i64 %id) alwaysinline {
  #|entry:
  #|  %r = call { i64, i1 } @tstc_ta(i64 %x, i64 %id)
  #|  %v = extractvalue { i64, i1 } %r, 0
  #|  %ok = extractvalue { i64, i1 } %r, 1
  #|  br i1 %ok, label %f, label %slow
  #|f:
  #|  ret i64 %v
  #|slow:
  #|  %s = call i64 @n_ta1(i64 %x, i64 %id)
  #|  ret i64 %s
  #|}
  #|
  #|define internal { i64, i64 } @tstc_ta2(i64 %x, i64 %id, i64 %z) alwaysinline {
  #|entry:
  #|  %r = call { i64, i1 } @tstc_ta(i64 %x, i64 %id)
  #|  %v = extractvalue { i64, i1 } %r, 0
  #|  %ok = extractvalue { i64, i1 } %r, 1
  #|  br i1 %ok, label %f, label %slow
  #|f:
  #|  %p0 = insertvalue { i64, i64 } poison, i64 %v, 0
  #|  %p1 = insertvalue { i64, i64 } %p0, i64 90, 1
  #|  ret { i64, i64 } %p1
  #|slow:
  #|  %s = call { i64, i64 } @n_ta2(i64 %x, i64 %id, i64 %z)
  #|  ret { i64, i64 } %s
  #|}
  #|
  #|declare i64 @n_nilchk(i64)
  #|define internal i64 @tstc_nilchk(i64 %x) alwaysinline {
  #|entry:
  #|  %isnull = icmp eq i64 %x, 66
  #|  br i1 %isnull, label %slow, label %f
  #|f:
  #|  ret i64 %x
  #|slow:
  #|  %s = call i64 @n_nilchk(i64 %x)
  #|  ret i64 %s
  #|}
  #|
  #|; ==: the same word, or two different integers
  #|define internal i64 @tstc_geq(i64 %a, i64 %b) alwaysinline {
  #|entry:
  #|  %eq = icmp eq i64 %a, %b
  #|  %ab = and i64 %a, %b
  #|  %both = trunc i64 %ab to i1
  #|  %fast = or i1 %eq, %both
  #|  %res = select i1 %eq, i64 90, i64 98
  #|  br i1 %fast, label %f, label %nil
  #|nil:
  #|  ; an integer and null (Go's nil checks of pointers) differ
  #|  %ai = trunc i64 %a to i1
  #|  %bi = trunc i64 %b to i1
  #|  %an = icmp eq i64 %a, 66
  #|  %bn = icmp eq i64 %b, 66
  #|  %ibn = and i1 %ai, %bn
  #|  %ian = and i1 %bi, %an
  #|  %inull = or i1 %ibn, %ian
  #|  br i1 %inull, label %f, label %slow
  #|f:
  #|  ret i64 %res
  #|slow:
  #|  %r = call i64 @n_geq(i64 %a, i64 %b)
  #|  ret i64 %r
  #|}
  #|
  #|define internal i64 @tstc_gne(i64 %a, i64 %b) alwaysinline {
  #|entry:
  #|  %eq = icmp eq i64 %a, %b
  #|  %ab = and i64 %a, %b
  #|  %both = trunc i64 %ab to i1
  #|  %fast = or i1 %eq, %both
  #|  %res = select i1 %eq, i64 98, i64 90
  #|  br i1 %fast, label %f, label %nil
  #|nil:
  #|  ; an integer and null (Go's nil checks of pointers) differ
  #|  %ai = trunc i64 %a to i1
  #|  %bi = trunc i64 %b to i1
  #|  %an = icmp eq i64 %a, 66
  #|  %bn = icmp eq i64 %b, 66
  #|  %ibn = and i1 %ai, %bn
  #|  %ian = and i1 %bi, %an
  #|  %inull = or i1 %ibn, %ian
  #|  br i1 %inull, label %f, label %slow
  #|f:
  #|  ret i64 %res
  #|slow:
  #|  %r = call i64 @n_gne(i64 %a, i64 %b)
  #|  ret i64 %r
  #|}
  #|
  #|define internal i1 @tstc_notnull(i64 %v) alwaysinline {
  #|entry:
  #|  %k = call i32 @tstc_kind(i64 %v)
  #|  switch i32 %k, label %no [ i32 11, label %yes i32 12, label %yes i32 29, label %yes i32 16, label %yes i32 20, label %yes i32 17, label %yes i32 31, label %yes i32 30, label %yes i32 32, label %yes ]
  #|yes:
  #|  ret i1 true
  #|no:
  #|  ret i1 false
  #|}
  #|

fn cstr_global(s : String) -> String {
  let b = utf8_encode(s)
  let u = cu()
  u.nglob += 1
  let g = "@\"" + u.prefix + ":E" + u.nglob.to_string() + "\""
  let sb = StringBuilder::new()
  sb.write_string(g + " = internal unnamed_addr constant [\{b.length() + 1} x i8] c\"")
  for i in 0..<b.length() {
    let c = b[i].to_int()
    if c >= 32 && c < 127 && c != 34 && c != 92 {
      sb.write_char(Int::unsafe_to_char(c))
    } else {
      let hex = "0123456789ABCDEF"
      sb.write_char('\\')
      sb.write_char(hex.unsafe_char_at(c >> 4))
      sb.write_char(hex.unsafe_char_at(c & 15))
    }
  }
  sb.write_string("\\00\"\n")
  uw(sb.to_string())
  g
}

// generates the program: entries are the aliases a run can start from; dump
// lists the parameterless ones of the main module. Returns the texts of the
// modules (each a list of buffers; the first may be the prelude, which they
// share): the entry table, the functions, the shared constants.
fn gen_program(entries : Array[Int], dump : Array[Int]) -> Array[ModOut] {
  assign_stable_names()
  for i in 0..<stable_names.length() {
    name_index.set(stable_names[i], i)
  }
  load_unit_index()
  let main_unit = GenUnit::new("main")
  cur_unit.val = Some(main_unit)
  let rows : Array[Array[String]] = []
  for idx in entries {
    let w = entry_fn(idx)
    rows.push([pval(cstr_global(aliases[idx].name)), pval(w), ival(aliases[idx].nparams)])
  }
  let tbl = struct_array(rows)
  uw("@tstc_entries = constant ptr " + tbl + "\n")
  uw("@tstc_nentries = constant i64 \{rows.length()}\n")
  let dumps = dump.map(fn(d) {
    let mut k = -1
    for j in 0..<entries.length() {
      if entries[j] == d {
        k = j
      }
    }
    k.to_string()
  })
  uw("@tstc_dump = constant ptr " + i64_array(dumps) + "\n")
  uw("@tstc_ndump = constant i64 \{dumps.length()}\n")
  uw(store_global())
  if coverage_on.val {
    let names = aliases.mapi(fn(i, _a) { cstr_global(stable_names[i]) })
    uw("@tstc_cov_names = constant ptr " + ptr_array(names) + "\n")
    uw("@tstc_cov_n = constant i64 \{names.length()}\n")
  } else {
    uw("@tstc_cov_names = constant ptr null\n")
    uw("@tstc_cov_n = constant i64 0\n")
  }
  cur_unit.val = None
  let all_units : Array[GenUnit] = []
  let generate = fn(idx : Int, part : String, name : String, job : () -> Unit) {
    // (a stub's code is needed: compiled, incr.mbt)
    incr_ensure(idx)
    let u = GenUnit::new(stable_names[idx] + part)
    u.defs.push(name)
    cur_unit.val = Some(u)
    job()
    while !u.pending.is_empty() {
      let j = u.pending.pop().unwrap()
      j()
    }
    cur_unit.val = None
    u.finish_text()
    u.len = c_buf_len(u.buf)
    u
  }
  let mut nhit = 0
  let mut nverify = 0
  while !unit_queue.is_empty() {
    let (idx, part, name, job) = unit_queue.pop().unwrap()
    let key = if unit_cache_on.val { unit_key(idx, part) } else { "" }
    let hit = match prev_units.get(key) {
      Some(rec) => {
        let u = GenUnit::with_buf(stable_names[idx] + part, -1)
        u.defs.push(name)
        u.cached = Some((rec.off, rec.len))
        u.len = rec.len
        cur_unit.val = Some(u)
        let mut ok = true
        for r in rec.refs() {
          if !replay_ref(r) {
            ok = false
          }
        }
        cur_unit.val = None
        if ok {
          Some(u)
        } else {
          None
        }
      }
      None => None
    }
    let u = match hit {
      Some(u) => {
        nhit += 1
        if unit_cache_verify.val {
          // generated again: the same text and references
          let g = generate(idx, part, name, job)
          let t = u.text()
          let same = c_bufs_hash(FixedArray::from_array([t]), b"") ==
            c_bufs_hash(FixedArray::from_array([g.buf]), b"") &&
            g.refs.length() == u.refs.length() &&
            g.refs.keys().all(fn(r) { u.refs.contains(r) })
          if !same {
            nverify += 1
            if nverify <= 10 {
              err("tstc: --cache-verify: unit " + name + " differs from its cached text\n")
            }
          }
          c_buf_free(g.buf)
        }
        u
      }
      None => generate(idx, part, name, job)
    }
    u.key = key
    all_units.push(u)
    match alias_units.get(idx) {
      Some(l) => l.push((part, u))
      None => alias_units.set(idx, [(part, u)])
    }
  }
  if nverify > 0 {
    die("tstc: --cache-verify: \{nverify} units differ")
  }
  if unit_cache_on.val {
    err("tstc: \{nhit} of \{all_units.length()} units cached\n")
  }
  c_buf_stats()
  main_unit.finish_text()
  let mods : Array[ModOut] = [{ key: "", make: fn() { module_of_units([main_unit]) } }]
  for m in function_modules() {
    mods.push(m)
  }
  // (the store of constants first: an index never names units whose
  // constants are not stored)
  for m in data_modules_out(all_units + [main_unit]) {
    mods.push(m)
  }
  save_unit_index(all_units)
  mods
}
