// Incremental builds of a large program (go2types output).
//
// A build leaves a snapshot of what the front end knew of the main file's
// aliases: per top-level chunk of the source (stub.c: tstc_chunks) its hash,
// and per alias its signature (parameters, doc tags), frame, native, catch
// handler, shapes (result, slots, what it passed to each callee), callees and
// unit key. The next build reads the source, hashes its chunks and parses
// only the chunks whose hash is new: the other chunks' aliases are stubs
// taken from the snapshot (not compiled, not optimized, not analyzed; their
// units come from the unit cache by their keys). A stub is parsed and
// compiled after all ("materialized") when something needs its code: the
// shapes of a changed alias raise those of the stub, a callee's signature
// (frame, parameters) changed, or its unit is not in the cache.
//
// The snapshot holds while the compiler, its arguments and the other files
// are those of the build that wrote it (aliases of the main file added or
// removed are fine: the snapshot's alias indices are mapped to this
// build's by name); a change that could lower a shape (a changed alias whose
// result or arguments are now simpler than before) cannot be followed
// incrementally either. Then the build starts over without the snapshot
// (--no-incr), which gives what a build from scratch gives.

let incr_allowed : Ref[Bool] = Ref::new(true)

// this build uses a snapshot
let incr_active : Ref[Bool] = Ref::new(false)

let incr_salt : Ref[String] = Ref::new("")

let incr_path : Ref[String] = Ref::new("")

let incr_argv : Array[String] = []

let incr_main : Ref[String] = Ref::new("")

let incr_src : Ref[Src] = Ref::new({ h: -1, n: 0 })

struct IChunk {
  start : Int
  end : Int
  hash : String
}

let incr_chunks : Array[IChunk] = []

// what the snapshot says of an alias of the main file
struct IRec {
  name : String
  nparams : Int
  exported : Bool
  params : Array[String]
  frame : Int
  native : Int
  catch_ : Int
  defaults : Bool
  res : Int
  // (where in the snapshot's text: read when needed)
  slots_s : Int
  slots_e : Int
  callees_s : Int
  callees_e : Int
  contrib_s : Int
  contrib_e : Int
  line_s : Int
  line_e : Int
  ak : String
  doc : String
  chunk : Int
}

// the snapshot's text
let snap_bytes : Ref[Bytes] = Ref::new(b"")

fn slots_t(r : IRec) -> String {
  c_utf8_slice(snap_bytes.val, r.slots_s, r.slots_e)
}

fn callees_t(r : IRec) -> String {
  c_utf8_slice(snap_bytes.val, r.callees_s, r.callees_e)
}

fn contrib_t(r : IRec) -> String {
  c_utf8_slice(snap_bytes.val, r.contrib_s, r.contrib_e)
}

let snap_recs : Array[IRec] = []

// the other files of the previous build: path -> hash
let snap_files : Map[String, String] = Map::new()

// the index of the main file's first alias, and its alias count
let incr_base : Ref[Int] = Ref::new(0)

let incr_count : Ref[Int] = Ref::new(0)

// stubs not materialized yet (alias index -> record)
let incr_lazy : Map[Int, Int] = Map::new()

// the chunk of each alias of the main file
let incr_chunk_of : Map[Int, Int] = Map::new()

// aliases materialized in this build (not stubs at the start)
let incr_mat : Map[Int, Bool] = Map::new()

// what each alias analyzed in this build passed to its callees
let incr_contrib : Map[Int, Map[Int, Array[Int]]] = Map::new()

let incr_parsed_chunks : Ref[Int] = Ref::new(0)

// the previous build's index of the main file's first alias; the other
// aliases (index -> name) in it
let snap_base : Ref[Int] = Ref::new(-1)

let snap_other_names : Map[Int, String] = Map::new()

// the other files' hashes in this build
let incr_file_hashes : Map[String, String] = Map::new()

// per record: the alias it is now (-1: removed); per main alias: its record
let incr_rec_new : Array[Int] = []

let incr_rec_of : Map[Int, Int] = Map::new()

// the indices of the main file's aliases are those of the previous build
let incr_same_idx : Ref[Bool] = Ref::new(true)

// an index of the previous build, now (-1: an alias removed)
fn incr_new_idx(o : Int) -> Int {
  let n = snap_recs.length()
  if o < snap_base.val {
    o
  } else if o < snap_base.val + n {
    incr_rec_new[o - snap_base.val]
  } else {
    o - n + incr_count.val
  }
}

// an index of an alias of another file, in the previous build
fn incr_old_other(i : Int) -> Int {
  if i < incr_base.val {
    i
  } else {
    i - incr_count.val + snap_recs.length()
  }
}

fn incr_map_ints(t : String) -> String {
  if incr_same_idx.val || t == "" {
    return t
  }
  let out : Array[Int] = []
  for o in ints_of_text(t) {
    let i = incr_new_idx(o)
    if i >= 0 {
      out.push(i)
    }
  }
  out.sort()
  ints_text(out)
}

fn incr_map_contrib(t : String) -> String {
  if incr_same_idx.val || t == "" {
    return t
  }
  let m : Map[Int, Array[Int]] = Map::new()
  rec_contrib_text(t).each(fn(o, sh) {
    let i = incr_new_idx(o)
    if i >= 0 {
      m.set(i, sh)
    }
  })
  contrib_text(m)
}

// ---------------------------------------------------------------------------
// Snapshot text

fn incr_esc(s : String) -> String {
  let sb = StringBuilder::new()
  for ch in s {
    match ch {
      '\\' => sb.write_string("\\\\")
      '\n' => sb.write_string("\\n")
      '\t' => sb.write_string("\\t")
      _ => sb.write_char(ch)
    }
  }
  sb.to_string()
}

fn incr_unesc(s : String) -> String {
  if !s.contains("\\") {
    return s
  }
  let sb = StringBuilder::new()
  let mut esc = false
  for ch in s {
    if esc {
      sb.write_char(
        match ch {
          'n' => '\n'
          't' => '\t'
          c => c
        },
      )
      esc = false
    } else if ch == '\\' {
      esc = true
    } else {
      sb.write_char(ch)
    }
  }
  sb.to_string()
}

fn shapes_text(xs : Array[Int]) -> String {
  let sb = StringBuilder::new()
  for x in xs {
    sb.write_char(Int::unsafe_to_char(48 + x))
  }
  sb.to_string()
}

fn shapes_of_text(s : String) -> Array[Int] {
  let out : Array[Int] = []
  for i in 0..<s.length() {
    out.push(s.unsafe_charcode_at(i) - 48)
  }
  out
}

fn parse_int0(s : String) -> Int {
  @strconv.parse_int(s) catch {
    _ => -1
  }
}

fn ints_of_text(s : String) -> Array[Int] {
  if s == "" {
    return []
  }
  s.split(",").map(fn(x) { parse_int0(x.to_string()) }).collect()
}

fn ints_text(xs : Array[Int]) -> String {
  xs.map(fn(x) { x.to_string() }).join(",")
}

// reads the snapshot; false when there is none for this compiler and these
// arguments
fn incr_load_snapshot() -> Bool {
  let b = match read_bytes(incr_path.val) {
    Some(b) => b
    None => return false
  }
  snap_bytes.val = b
  let n = b.length()
  let e0 = line_end(b, 0)
  if c_utf8_slice(b, 0, e0) != "tstc-front 1 " + incr_salt.val {
    return false
  }
  let f : Array[Int] = []
  let str = fn(k : Int) { c_utf8_slice(b, f[2 * k], f[2 * k + 1]) }
  let num = fn(k : Int) { int_at(b, f[2 * k], f[2 * k + 1]) }
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
    match b[s] {
      b'A' if nf == 16 => {
        let doc = str(14)
        snap_recs.push({
          name: str(1),
          nparams: num(2),
          exported: num(3) == 1,
          params: if f[8] == f[9] { [] } else { str(4).split(",").map(fn(x) { x.to_string() }).collect() },
          frame: num(5),
          native: num(6),
          catch_: num(7),
          defaults: num(8) == 1,
          res: num(9),
          slots_s: f[20],
          slots_e: f[21],
          callees_s: f[22],
          callees_e: f[23],
          ak: str(12),
          contrib_s: f[26],
          contrib_e: f[27],
          doc: if doc.contains("\\") { incr_unesc(doc) } else { doc },
          chunk: num(15),
          line_s: s,
          line_e: e + 1,
        })
      }
      b'F' if nf == 3 => snap_files.set(str(1), str(2))
      b'L' if nf == 5 => {
        let i = num(1)
        snap_other_res.set(i, num(2))
        snap_other_slots.set(i, str(3))
        snap_other_names.set(i, str(4))
      }
      b'B' if nf == 2 => snap_base.val = num(1)
      b'C' if nf == 3 => {
        // (the chunks of the previous build: their hashes)
        let h = str(1)
        snap_chunk_hashes.push(h)
        if num(2) == 1 {
          snap_parse_chunks.set(h, true)
        }
      }
      _ => ()
    }
  }
  true
}

let snap_chunk_hashes : Array[String] = []

let snap_other_slots : Map[Int, String] = Map::new()

fn rec_slots(r : IRec) -> Array[Int] {
  shapes_of_text(slots_t(r))
}

// (in this build's indices)
fn rec_callees(r : IRec) -> Array[Int] {
  ints_of_text(incr_map_ints(callees_t(r)))
}

fn rec_contrib(r : IRec) -> Map[Int, Array[Int]] {
  rec_contrib_text(incr_map_contrib(contrib_t(r)))
}

fn rec_contrib_text(t : String) -> Map[Int, Array[Int]] {
  let contrib : Map[Int, Array[Int]] = Map::new()
  if t != "" {
    for e in t.split(" ") {
      let e = e.to_string()
      match e.find(":") {
        Some(i) =>
          contrib.set(
            parse_int0(e.unsafe_substring(start=0, end=i)),
            shapes_of_text(e.unsafe_substring(start=i + 1, end=e.length())),
          )
        None => ()
      }
    }
  }
  contrib
}

// ---------------------------------------------------------------------------
// The main file

fn u32_at(b : Bytes, i : Int) -> Int {
  b[i].to_int() | (b[i + 1].to_int() << 8) | (b[i + 2].to_int() << 16) | (b[i + 3].to_int() << 24)
}

fn incr_split(src : Src) -> Unit {
  let r = c_src_chunks(src.h)
  let n = r.length() / 16
  for i in 0..<n {
    let s = u32_at(r, i * 16)
    let e = u32_at(r, i * 16 + 4)
    let lo = u32_at(r, i * 16 + 8).to_int64() & 0xFFFFFFFFL
    let hi = u32_at(r, i * 16 + 12).to_int64() & 0xFFFFFFFFL
    incr_chunks.push({ start: s, end: e, hash: hex_digits((hi << 32) | lo, 16) })
  }
}

fn incr_chunk_decls(k : Int, path : String) -> Array[Decl] {
  let c = incr_chunks[k]
  parse_source(utf8_decode(incr_src.val.slice(c.start, c.end)), path)
}

// the declarations of the main file, parsed chunk by chunk; the unchanged
// chunks' aliases as stubs from the snapshot when there is one (None: the
// file is not one this works for)
fn incr_main_decls(path : String, b : Src) -> Array[Decl]? {
  if incr_path.val == "" || b.n < 1000000 || !incr_is_go2types(b.slice(0, 64)) {
    incr_active.val = false
    incr_path.val = ""
    return None
  }
  incr_main.val = path
  incr_src.val = b
  incr_split(b)
  // the records of each previous chunk, by its hash (chunks that declare
  // more than aliases are parsed every time)
  let first_rec : Map[String, Int] = Map::new()
  let nrec : Map[String, Int] = Map::new()
  if incr_active.val {
    for i in 0..<snap_recs.length() {
      let h = snap_chunk_hashes[snap_recs[i].chunk]
      if !first_rec.contains(h) {
        first_rec.set(h, i)
      }
      nrec.set(h, nrec.get(h).unwrap_or(0) + 1)
    }
  }
  let decls : Array[Decl] = []
  // per alias: the record of a stub (-1: parsed), its chunk
  let stub_of : Array[Int] = []
  let chunk_of : Array[Int] = []
  for k in 0..<incr_chunks.length() {
    let h = incr_chunks[k].hash
    let known = if incr_active.val && !snap_parse_chunks.contains(h) { first_rec.get(h) } else { None }
    match known {
      Some(r0) => {
        let n = nrec.get(h).unwrap_or(0)
        for j in r0..<(r0 + n) {
          let r = snap_recs[j]
          if r.defaults {
            // (its defaults are code: parsed every time)
            incr_active.val = false
            return incr_main_decls_again(path, b, "a stub with defaults")
          }
          decls.push(
            DAlias(r.name, r.params.map(fn(p) { { name: p, constraint: None, default: None } }), EBool(true), r.doc, r.exported),
          )
          stub_of.push(j)
          chunk_of.push(k)
        }
      }
      None => {
        incr_parsed_chunks.val += 1
        for d in incr_chunk_decls(k, path) {
          match d {
            DAlias(_, tps, _, _, _) => {
              stub_of.push(-1)
              chunk_of.push(k)
              if tps.iter().any(fn(p) { p.default is Some(_) }) {
                incr_parse_chunks.set(h, true)
              }
            }
            DInterface(_, _, _, _, _, _) => {
              // (interfaces merge across declarations: no snapshot)
              incr_active.val = false
              incr_path.val = ""
              return None
            }
            _ => incr_parse_chunks.set(h, true)
          }
          decls.push(d)
        }
      }
    }
  }
  incr_stub_of.val = stub_of
  incr_decl_chunk.val = chunk_of
  Some(decls)
}

// a go2types output (whose top-level chunks are where tstc_chunks finds them)
fn incr_is_go2types(b : Bytes) -> Bool {
  let p = b"// Generated by go2types"
  if b.length() < p.length() {
    return false
  }
  for i in 0..<p.length() {
    if b[i] != p[i] {
      return false
    }
  }
  true
}

// without the snapshot after all
fn incr_main_decls_again(path : String, b : Src, why : String) -> Array[Decl]? {
  err("tstc: incremental build: " + why + "; building from scratch\n")
  incr_chunks.clear()
  incr_parse_chunks.clear()
  incr_parsed_chunks.val = 0
  incr_main_decls(path, b)
}

// chunks that are parsed every time (they declare more than aliases, or
// aliases with defaults), by hash: of this build, of the previous one
let incr_parse_chunks : Map[String, Bool] = Map::new()

let snap_parse_chunks : Map[String, Bool] = Map::new()

let incr_stub_of : Ref[Array[Int]] = Ref::new([])

let incr_decl_chunk : Ref[Array[Int]] = Ref::new([])

// after the main file's aliases were registered from incr_main_decls
fn incr_registered(base : Int, n : Int) -> Unit {
  incr_base.val = base
  incr_count.val = n
  let stubs = incr_stub_of.val
  if stubs.length() != n {
    die("incremental build: \{n} aliases registered for \{stubs.length()} declared")
  }
  if incr_active.val {
    if base != snap_base.val {
      incr_restart_now("the main file's aliases do not start where they did")
    }
    // the records of the aliases parsed now, by name
    let by_name : Map[String, Int] = Map::new()
    for ri in 0..<snap_recs.length() {
      by_name.set(snap_recs[ri].name, ri)
      incr_rec_new.push(-1)
    }
    for i in 0..<n {
      let ri = if stubs[i] >= 0 {
        stubs[i]
      } else {
        by_name.get(aliases[base + i].name).unwrap_or(-1)
      }
      if ri >= 0 {
        if incr_rec_new[ri] >= 0 {
          incr_restart_now("an alias of the main file declared twice")
        }
        incr_rec_new[ri] = base + i
        incr_rec_of.set(base + i, ri)
      }
      if ri != i {
        incr_same_idx.val = false
      }
    }
    if n != snap_recs.length() {
      incr_same_idx.val = false
    }
  }
  for i in 0..<n {
    incr_chunk_of.set(base + i, incr_decl_chunk.val[i])
    if !incr_active.val || stubs[i] < 0 {
      continue
    }
    let r = snap_recs[stubs[i]]
    let a = aliases[base + i]
    a.frame = r.frame
    a.native = r.native
    a.decl_body = None
    incr_lazy.set(base + i, stubs[i])
    if r.ak != "" {
      alias_keys.set(base + i, r.ak)
    }
  }
}

fn incr_restart_now(why : String) -> Unit {
  err("tstc: incremental build: " + why + "; building from scratch\n")
  let sb = StringBuilder::new()
  for a in incr_argv {
    sb.write_string("'" + a.replace_all(old="'", new="'\\''") + "' ")
  }
  sb.write_string("--no-incr")
  c_exit(system(sb.to_string()) / 256)
}

// the other files are those of the previous build
fn incr_check_files() -> Unit {
  if !incr_active.val {
    return
  }
  let mut n = 0
  let mut bad = ""
  modules.each(fn(p, _m) {
    if p != "<prelude>" && p != incr_main.val {
      n += 1
      let h = utf8_decode(c_file_hash(path_bytes(p)))
      incr_file_hashes.set(p, h)
      if snap_files.get(p) != Some(h) {
        bad = p
      }
    }
  })
  if bad != "" || n != snap_files.length() {
    incr_restart_now("other files changed (" + bad + ")")
  }
  // (their aliases where they were, after the main file's; the aliases of
  // check.mbt come last)
  if snap_other_names.length() != aliases.length() - incr_count.val - synthetic.length() {
    incr_restart_now("other aliases added or removed")
  }
  for i in 0..<aliases.length() {
    if i >= incr_base.val && i < incr_base.val + incr_count.val || synthetic.contains(i) {
      continue
    }
    if snap_other_names.get(incr_old_other(i)) != Some(aliases[i].name) {
      incr_restart_now("other aliases moved")
    }
  }
}

// ---------------------------------------------------------------------------
// Materializing stubs

fn incr_is_lazy(idx : Int) -> Bool {
  incr_lazy.contains(idx)
}

// the aliases of idx's chunk compiled (and optimized) as a build from
// scratch does
fn incr_materialize(idx : Int) -> Unit {
  if !incr_lazy.contains(idx) {
    return
  }
  let k = incr_chunk_of.get(idx).unwrap()
  let m = modules.get(incr_main.val).unwrap()
  let compiled : Array[Int] = []
  for d in incr_chunk_decls(k, incr_main.val) {
    match d {
      DAlias(name, tps, body, _, _) => {
        let j = m.locals.get(name).unwrap()
        if !incr_lazy.contains(j) {
          continue
        }
        incr_lazy.remove(j)
        incr_mat.set(j, true)
        alias_keys.remove(j)
        let a = aliases[j]
        a.decl_params.clear()
        for p in tps {
          a.decl_params.push(p)
        }
        a.decl_body = Some(body)
        compile_alias(j)
        a.decl_body = None
        if unwrap_on.val && a.native < 0 && !a.is_interface {
          a.body = unwrap_identity(a.body)
        }
        if cse_on.val {
          cse_alias(a)
        }
        if a.frame != snap_recs[incr_rec_of.get(j).unwrap()].frame {
          incr_restart_now("a stub's frame differs from the snapshot's")
        }
        compiled.push(j)
      }
      _ => ()
    }
  }
  // (their conditionals' inline decisions, from their known shapes)
  if shape_res.length() > 0 {
    for j in compiled {
      // (its parameters as the stubs called them)
      let old = rec_slots(snap_recs[incr_rec_of.get(j).unwrap()])
      let ps = shape_slots[j]
      for k in 0..<aliases[j].nparams {
        if k < ps.length() && k < old.length() && old[k] > ps[k] {
          ps[k] = old[k]
        }
      }
      analyze_alias(j)
    }
  }
}

// before code generation needs idx's code
fn incr_ensure(idx : Int) -> Unit {
  incr_materialize(idx)
}

// ---------------------------------------------------------------------------
// Shapes

// the stubs' shapes from the snapshot; the parameters of the other aliases
// as the stubs called them
fn incr_shapes_init() -> Unit {
  if !incr_active.val {
    return
  }
  incr_lazy.each(fn(idx, ri) { shape_res[idx] = snap_recs[ri].res })
  // the others' parameters as in the previous build (what the stubs passed
  // is in them; that changed aliases pass no less is checked after)
  let redo : Array[Int] = []
  for i in 0..<aliases.length() {
    if incr_lazy.contains(i) || synthetic.contains(i) {
      continue
    }
    let t = if i >= incr_base.val && i < incr_base.val + incr_count.val {
      // (a changed alias: when its parameters are the same; else the stubs
      // calling it are analyzed again)
      match incr_rec_of.get(i) {
        Some(ri) => {
          let r = snap_recs[ri]
          if r.nparams == aliases[i].nparams && r.params == aliases[i].param_names {
            slots_t(r)
          } else {
            for c in incr_callers_of(i) {
              redo.push(c)
            }
            ""
          }
        }
        // (a new alias: no stub calls it)
        None => ""
      }
    } else {
      snap_other_slots.get(incr_old_other(i)).unwrap_or("")
    }
    let ps = shape_slots[i]
    let np = aliases[i].nparams
    for k in 0..<np {
      if k < ps.length() && k < t.length() {
        let v = t.unsafe_charcode_at(k) - 48
        if v > ps[k] {
          ps[k] = v
        }
      }
    }
  }
  for c in redo {
    incr_materialize(c)
  }
}

// stubs a shape analysis raised (the slots of a stub start at nothing:
// compared with the snapshot's by incr_wake)
let incr_poked : Map[Int, Bool] = Map::new()

// the stubs calling each alias (from the snapshot, made when needed)
let incr_stub_callers : Map[Int, Array[Int]] = Map::new()

let incr_stub_callers_made : Ref[Bool] = Ref::new(false)

fn incr_callers_of(c : Int) -> Array[Int] {
  if !incr_stub_callers_made.val {
    incr_stub_callers_made.val = true
    incr_lazy.each(fn(idx, ri) {
      for d in rec_callees(snap_recs[ri]) {
        match incr_stub_callers.get(d) {
          Some(l) => l.push(idx)
          None => incr_stub_callers.set(d, [idx])
        }
      }
    })
  }
  incr_stub_callers.get(c).unwrap_or([])
}

// the shapes the other aliases' results had in the previous build
let snap_other_res : Map[Int, Int] = Map::new()

// after a fixpoint without the stubs: stubs whose callees' results or whose
// own slots are not those of the snapshot any more are compiled and queued
// (false: none)
fn incr_wake() -> Bool {
  if !incr_active.val {
    return false
  }
  let wake : Map[Int, Bool] = Map::new()
  incr_poked.each(fn(idx, _b) {
    match incr_lazy.get(idx) {
      Some(ri) => {
        let old = rec_slots(snap_recs[ri])
        let ps = shape_slots[idx]
        for k in 0..<ps.length() {
          if ps[k] > (if k < old.length() { old[k] } else { 0 }) {
            wake.set(idx, true)
          }
        }
      }
      None => ()
    }
  })
  incr_poked.clear()
  for i in 0..<aliases.length() {
    if incr_lazy.contains(i) || synthetic.contains(i) {
      continue
    }
    let main = i >= incr_base.val && i < incr_base.val + incr_count.val
    let old = if main {
      match incr_rec_of.get(i) {
        Some(ri) => snap_recs[ri].res
        None => 0
      }
    } else {
      match snap_other_res.get(incr_old_other(i)) {
        Some(v) => v
        None => 2
      }
    }
    if shape_res[i] < old && !main {
      incr_restart_now("a shape of another file's alias is simpler than before")
    }
    if shape_res[i] > old {
      for c in incr_callers_of(i) {
        if incr_lazy.contains(c) {
          wake.set(c, true)
        }
      }
    }
  }
  if wake.is_empty() {
    return false
  }
  let todo : Array[Int] = []
  wake.each(fn(idx, _b) { todo.push(idx) })
  for idx in todo {
    incr_materialize(idx)
    shape_enqueue(idx)
  }
  true
}

fn incr_record_contrib(caller : Int, callee : Int, shapes : Array[Int]) -> Unit {
  if !incr_active.val && incr_path.val == "" {
    return
  }
  let m = match incr_contrib.get(caller) {
    Some(m) => m
    None => {
      let m = Map::new()
      incr_contrib.set(caller, m)
      m
    }
  }
  match m.get(callee) {
    Some(old) => {
      for k in 0..<shapes.length() {
        if k < old.length() {
          if shapes[k] > old[k] {
            old[k] = shapes[k]
          }
        } else {
          old.push(shapes[k])
        }
      }
    }
    None => m.set(callee, shapes.copy())
  }
}

// after the analysis: nothing a changed alias says now is simpler than
// what the snapshot (the stubs' shapes) assumed
fn incr_shapes_done() -> Unit {
  if !incr_active.val {
    return
  }
  for i in 0..<incr_count.val {
    let idx = incr_base.val + i
    if incr_lazy.contains(idx) || incr_mat.contains(idx) {
      continue
    }
    let r = match incr_rec_of.get(idx) {
      Some(ri) => snap_recs[ri]
      None => continue
    }
    if shape_res[idx] < r.res {
      incr_restart_now("a changed alias's result is simpler than before")
    }
    let now = incr_contrib.get(idx)
    rec_contrib(r).each(fn(c, old) {
      let cur = match now {
        Some(m) => m.get(c).unwrap_or([])
        None => []
      }
      for k in 0..<old.length() {
        let v = if k < cur.length() { cur[k] } else { 0 }
        if v < old[k] {
          incr_restart_now("a changed alias passes simpler arguments than before")
        }
      }
    })
  }
}

// before code generation: stubs that call an alias whose signature changed
// are materialized (their units' keys and code depend on it)
fn incr_before_codegen() -> Unit {
  if !incr_active.val {
    return
  }
  let changed : Map[Int, Bool] = Map::new()
  for i in 0..<incr_count.val {
    let idx = incr_base.val + i
    if incr_lazy.contains(idx) {
      continue
    }
    // (a new alias: no stub calls it)
    let r = match incr_rec_of.get(idx) {
      Some(ri) => snap_recs[ri]
      None => continue
    }
    let a = aliases[idx]
    let c = match catch_of.get(idx) {
      Some(h) => h
      None => -1
    }
    if a.frame != r.frame || a.nparams != r.nparams || a.native != r.native || c != r.catch_ {
      changed.set(idx, true)
    }
  }
  if changed.is_empty() {
    return
  }
  let todo : Array[Int] = []
  incr_lazy.each(fn(idx, ri) {
    for c in rec_callees(snap_recs[ri]) {
      if changed.contains(c) {
        todo.push(idx)
        break
      }
    }
  })
  for idx in todo {
    incr_ensure(idx)
  }
}

// ---------------------------------------------------------------------------
// The snapshot of this build

fn incr_save(m : Module) -> Unit {
  if incr_path.val == "" || incr_count.val == 0 {
    return
  }
  let sb = c_buf_new()
  c_buf_str(sb, "tstc-front 1 " + incr_salt.val + "\n")
  modules.each(fn(p, _m) {
    if p != "<prelude>" && p != incr_main.val {
      let h = match incr_file_hashes.get(p) {
        Some(h) => h
        None => utf8_decode(c_file_hash(path_bytes(p)))
      }
      c_buf_str(sb, "F\t" + p + "\t" + h + "\n")
    }
  })
  c_buf_str(sb, "B\t\{incr_base.val}\n")
  for i in 0..<aliases.length() {
    // (not the aliases of check.mbt: made by the aliases compiled in a
    // build, which an incremental build only partly compiles)
    if (i < incr_base.val || i >= incr_base.val + incr_count.val) && i < shape_res.length() &&
      !synthetic.contains(i) {
      c_buf_str(sb, "L\t\{i}\t\{shape_res[i]}\t" + shapes_text(shape_slots[i]) + "\t" + aliases[i].name + "\n")
    }
  }
  for c in incr_chunks {
    c_buf_str(sb, "C\t" + c.hash + "\t" + (if incr_parse_chunks.contains(c.hash) { "1" } else { "0" }) + "\n")
  }
  // exported, by name (from the main file's declarations)
  let exported : Map[String, Bool] = Map::new()
  for d in m.decls {
    match d {
      DAlias(name, _, _, _, ex) => exported.set(name, ex)
      _ => ()
    }
  }
  for i in 0..<incr_count.val {
    let idx = incr_base.val + i
    let a = aliases[idx]
    match incr_lazy.get(idx) {
      Some(ri) => {
        let r = snap_recs[ri]
        if incr_same_idx.val &&
          r.chunk == incr_chunk_of.get(idx).unwrap() &&
          alias_keys.get(idx).unwrap_or(r.ak) == r.ak {
          // (as it was)
          c_buf_bytes(sb, snap_bytes.val, r.line_s, r.line_e)
          continue
        }
        incr_write_rec(
          sb,
          r.name,
          r.nparams,
          r.exported,
          r.params,
          r.frame,
          r.native,
          r.catch_,
          r.defaults,
          r.res,
          slots_t(r),
          incr_map_ints(callees_t(r)),
          incr_map_contrib(contrib_t(r)),
          alias_keys.get(idx).unwrap_or(r.ak),
          r.doc,
          incr_chunk_of.get(idx).unwrap(),
        )
      }
      None => {
        let calls : Map[Int, Bool] = Map::new()
        calls_into(a.body, calls)
        for d in a.defaults {
          match d {
            Some(c) => calls_into(c, calls)
            None => ()
          }
        }
        let callees : Array[Int] = []
        calls.each(fn(c, _b) { callees.push(c) })
        callees.sort()
        let doc = if a.doc.contains("@") { a.doc } else { "" }
        incr_write_rec(
          sb,
          a.name,
          a.nparams,
          exported.get(a.name).unwrap_or(false),
          a.param_names,
          a.frame,
          a.native,
          match catch_of.get(idx) {
            Some(h) => h
            None => -1
          },
          a.defaults.iter().any(fn(d) { d is Some(_) }),
          if idx < shape_res.length() { shape_res[idx] } else { 2 },
          shapes_text(if idx < shape_slots.length() { shape_slots[idx] } else { [] }),
          ints_text(callees),
          contrib_text(incr_contrib.get(idx).unwrap_or(Map::new())),
          alias_keys.get(idx).unwrap_or(""),
          doc,
          incr_chunk_of.get(idx).unwrap(),
        )
      }
    }
  }
  let tmp = incr_path.val + ".new"
  if c_bufs_write(FixedArray::from_array([sb]), path_bytes(tmp)) != 0 {
    let _ = c_rename(path_bytes(tmp), path_bytes(incr_path.val))

  }
  c_buf_free(sb)
}

fn incr_write_rec(
  sb : Int,
  name : String,
  nparams : Int,
  exported : Bool,
  params : Array[String],
  frame : Int,
  native : Int,
  catch_ : Int,
  defaults : Bool,
  res : Int,
  slots : String,
  callees : String,
  contrib : String,
  ak : String,
  doc : String,
  chunk : Int,
) -> Unit {
  c_buf_str(sb, "A\t" + name + "\t\{nparams}\t" + (if exported { "1" } else { "0" }) + "\t")
  c_buf_str(sb, params.join(",") + "\t\{frame}\t\{native}\t\{catch_}\t" + (if defaults { "1" } else { "0" }))
  c_buf_str(sb, "\t\{res}\t" + slots + "\t" + callees + "\t" + ak + "\t")
  c_buf_str(sb, contrib + "\t" + incr_esc(doc) + "\t\{chunk}\n")
}

fn contrib_text(contrib : Map[Int, Array[Int]]) -> String {
  let parts : Array[String] = []
  contrib.each(fn(c, sh) { parts.push(c.to_string() + ":" + shapes_text(sh)) })
  parts.join(" ")
}
