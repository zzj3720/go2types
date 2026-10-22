// Natives of libraries: an alias tagged `@native <name>` (natives.mbt) in a
// library file (tstst's lib/pure) is implemented by the runtime. The
// library's definitions are plain TypeScript, and they are the semantics: a
// definition is implemented natively only while the files its meaning
// depends on (its file and those it imports, transitively) are the versions
// the natives were checked against (same hashes, accel_hash.mbt). Natives
// that share a representation import each other's files (map.ts imports
// heap.ts: map natives need the heap's), so they go together.
// (rterr.ts: rtok is constantly true natively, as a failing operation does
// not return. That holds whichever natives are on: a definition compiled as
// written fails through rterr, which is native while rterr.ts is checked.)

let accel_on : Ref[Bool] = Ref::new(true)

// FNV-1a over the contents
fn file_hash(p : String) -> Int64 {
  let mut h = 0xCBF29CE484222325UL.reinterpret_as_int64()
  for b in c_read_file(path_bytes(p)) {
    h = (h ^ b.to_int().to_int64()) * 0x100000001B3L
  }
  h
}

fn base_name(p : String) -> String {
  match p.rev_find("/") {
    Some(i) => p.unsafe_substring(start=i + 1, end=p.length())
    None => p
  }
}

// --accel-report: which tagged definitions natives replaced, and which are
// compiled as written (and why)
let accel_report : Ref[Bool] = Ref::new(false)

// --no-accel-file f.ts (repeatable): the definitions of these files, and of
// the files importing them, are compiled as written, the others still
// replaced (to find which file a difference between the natives and the
// definitions comes from)
let accel_off_files : Array[String] = []

// the files a module imports from (or re-exports), directly
fn module_deps(m : Module) -> Array[String] {
  let out : Array[String] = []
  let add = fn(p : String) { if p != m.path && !out.contains(p) { out.push(p) } }
  m.imports.each(fn(_n, idx) { add(aliases[idx].file) })
  m.exports.each(fn(_n, idx) { add(aliases[idx].file) })
  m.ns_imports.each(fn(_n, mm) { add(mm.path) })
  out
}

// a file and the files it depends on, transitively
fn file_closure(path : String, memo : Map[String, Array[String]]) -> Array[String] {
  match memo.get(path) {
    Some(c) => return c
    None => ()
  }
  let out : Array[String] = [path]
  memo.set(path, out)
  let work = [path]
  while !work.is_empty() {
    let p = work.pop().unwrap()
    match modules.get(p) {
      Some(m) =>
        for d in module_deps(m) {
          if !out.contains(d) {
            out.push(d)
            work.push(d)
          }
        }
      None => ()
    }
  }
  out
}

// whether the file is a version the natives were checked against
fn file_checked(path : String, memo : Map[String, Bool]) -> Bool {
  match memo.get(path) {
    Some(b) => return b
    None => ()
  }
  let n = base_name(path)
  let h = file_hash(path)
  let mut ok = false
  for row in pure_file_hashes {
    if row.0 == n && row.1 == h {
      ok = true
    }
  }
  memo.set(path, ok)
  ok
}

fn accelerate_prelude() -> Unit {
  find_store_decl()
  let closures : Map[String, Array[String]] = Map::new()
  let checked : Map[String, Bool] = Map::new()
  // report rows: (name, file, why not replaced or "")
  let rows : Array[(String, String, String)] = []
  let changed : Array[String] = []
  for a in aliases {
    if a.is_interface || a.file == "<prelude>" {
      continue
    }
    let tag = match native_tag(a.doc) {
      Some(t) => t
      None => continue
    }
    let n = base_name(a.file)
    let mut why = ""
    if a.native < 0 {
      why = "the runtime has no native '" + tag + "'"
    } else if !accel_on.val {
      why = "--no-accel"
    } else {
      let bad : Array[String] = []
      let off : Array[String] = []
      for f in file_closure(a.file, closures) {
        if f == "<prelude>" {
          continue
        }
        if !file_checked(f, checked) {
          bad.push(base_name(f))
          if !changed.contains(base_name(f)) {
            changed.push(base_name(f))
          }
        }
        if accel_off_files.contains(base_name(f)) {
          off.push(base_name(f))
        }
      }
      if !bad.is_empty() {
        why = "changed: " + bad.join(", ")
      } else if !off.is_empty() {
        why = "--no-accel-file " + off.join(", ")
      } else if native_has_effects(a.native) && !store_in_place() {
        // the natives update the store in place
        why = "no linear store of cells declared (@store, @store-linear, @store-ref bigint)"
      }
    }
    if why != "" {
      a.native = -1
    }
    rows.push((a.name, n, why))
  }
  if accel_on.val && !changed.is_empty() {
    err(
      "tstc: files differ from the versions the natives were checked against (" + changed.join(", ") +
      "): their definitions and those depending on them are compiled as written\n",
    )
  }
  if accel_report.val {
    print_accel_report(rows)
  }
  add_fused_natives()
}

fn print_accel_report(rows : Array[(String, String, String)]) -> Unit {
  let sb = StringBuilder::new()
  let mut nrep = 0
  for r in rows {
    if r.2 == "" {
      nrep += 1
    }
  }
  sb.write_string(
    "tstc: accel report: \{nrep} of \{rows.length()} runtime definitions of lib/pure replaced by natives\n",
  )
  for r in rows {
    if r.2 == "" {
      sb.write_string("  replaced  " + r.0 + " (" + r.1 + ")\n")
    }
  }
  for r in rows {
    if r.2 != "" {
      sb.write_string("  as TS     " + r.0 + " (" + r.1 + "; " + r.2 + ")\n")
    }
  }
  err(sb.to_string())
}
