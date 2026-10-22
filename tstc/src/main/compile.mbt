// Name resolution: turns parsed declarations into executable Code.

enum Code {
  CTy(Ty)
  CSlot(Int)
  CCall(Int, Array[Code])
  CUnion(Array[Code])
  CInter(Array[Code])
  CCond(Cond)
  CTuple(Array[CElem], Bool)
  CArray(Code, Bool)
  CObj(ObjCode)
  CMapped(MappedCode)
  CIndex(Code, Code)
  CKeyof(Code)
  CTpl(Array[Str], Array[Code])
  CFn(Array[CParam], Code, Bool)
  CGenericFn(Array[Int], Code) // type parameter slots, CFn body
  CUniqueSym(Int)
  CNative(Int, Int, Array[Code]) // alias index, native id, args
  CLet(Int, Code, Code) // slot, its value, the code in its scope (opt.mbt)
}

struct Cond {
  check : Code
  ext : Code
  pat : Pat? // None when the extends clause has no `infer`
  t : Code
  f : Code
  dist_slot : Int // -1 when not distributive
  infer_slots : Array[Int]
  // fast paths: 1 `X extends infer V`, 2 `X extends [infer A, infer B, ...]`,
  // 3 `X extends true`, 4 `X extends null`, 0 general
  fast : Int
  fslots : Array[Int]
  id : Int // for the code generator
}

fn cond_fast(pat : Pat?, ext : Code) -> (Int, Array[Int]) {
  match pat {
    Some(PInfer(s, None)) => (1, [s])
    // `X extends infer V extends bigint` (go2types' table keys): an integer
    // binds V; anything else is left to the runtime
    Some(PInfer(s, Some(CTy(TBigInt)))) => (5, [s])
    Some(PTuple(elems, _)) => {
      let slots : Array[Int] = []
      for e in elems {
        match (e.kind, e.pat) {
          (0, PInfer(s, None)) =>
            // (an infer name twice: candidates of both positions)
            if slots.contains(s) {
              return (0, [])
            } else {
              slots.push(s)
            }
          _ => return (0, [])
        }
      }
      (2, slots)
    }
    Some(_) => (0, [])
    None =>
      match ext {
        CTy(TTrue) => (3, [])
        CTy(TNull) => (4, [])
        _ => (0, [])
      }
  }
}

enum Pat {
  PCode(Code)
  PInfer(Int, Code?)
  PTuple(Array[PElem], Bool)
  PArray(Pat, Bool)
  PObj(Array[PProp])
  PTpl(Array[Str], Array[Pat])
  PFn(Array[PElem], Pat) // parameters (kind: required, optional, rest), return type
  PUnion(Array[Pat])
  // a type with infer declarations that is no pattern (an alias with them
  // among its arguments): its code, and its slots by occurrence (kind: 1 in
  // a rest position, 2 in a template, tsc's implied constraints)
  PVal(Code, Array[PElem])
}

struct PElem {
  pat : Pat
  kind : Int
}

struct PProp {
  name : Str
  pat : Pat
  optional : Bool
}

struct CElem {
  code : Code
  kind : Int
  name : Str?
}

struct ObjCode {
  props : Array[(Str, Code, Bool, Bool, Bool)] // name, type, optional, readonly, numeric name
  index : Array[(Code, Code, Bool)]
  calls : Array[(Array[CParam], Code, Bool)]
  lookup : Ref[Map[Str, Int]?]
  id : Int
}

struct MappedCode {
  slot : Int
  constraint : Code
  homo : Code? // `keyof T` with T a type parameter: maps arrays/tuples, distributes
  homo_slot : Int // T's slot (or -1)
  mods : Code? // where property modifiers are copied from
  kof : Bool // the constraint is written `keyof X`
  as_clause : Code?
  body : Code
  ro : Int
  opt : Int
  id : Int
}

struct CParam {
  name : Str
  code : Code
  optional : Bool
  rest : Bool
}

struct Alias {
  name : String
  doc : String
  file : String
  nparams : Int
  param_names : Array[String]
  mut defaults : Array[Code?]
  mut body : Code
  mut frame : Int
  mut native : Int
  // for interfaces: merged declarations
  iface_members : Array[Member]
  iface_heritage : Array[TE]
  decl_params : Array[TParamE]
  mut decl_body : TE? // dropped once compiled
  is_interface : Bool
}

let aliases : Array[Alias] = []

let code_ids : Ref[Int] = Ref::new(0)

fn fresh_code_id() -> Int {
  code_ids.val += 1
  code_ids.val
}

struct Module {
  path : String
  mut decls : Array[Decl]
  locals : Map[String, Int] // alias name -> alias index
  exports : Map[String, Int]
  ns_imports : Map[String, Module]
  imports : Map[String, Int]
  mut done_exports : Bool
}

let modules : Map[String, Module] = Map::new()

fn file_ordinal(path : String) -> Int {
  let mut k = 0
  let mut r = -1
  modules.each(fn(p, _m) {
    if p == path {
      r = k
    }
    k += 1
  })
  r
}

let globals : Map[String, Int] = Map::new()

fn dirname(p : String) -> String {
  match p.rev_find("/") {
    Some(i) => p.unsafe_substring(start=0, end=i)
    None => "."
  }
}

fn normalize_path(p : String) -> String {
  let parts : Array[String] = []
  let abs = p.has_prefix("/")
  for seg in p.split("/") {
    let s = seg.to_string()
    if s == "" || s == "." {
      continue
    }
    if s == ".." && parts.length() > 0 && parts[parts.length() - 1] != ".." {
      let _ = parts.pop()
      continue
    }
    parts.push(s)
  }
  let joined = parts.join("/")
  if abs {
    "/" + joined
  } else {
    joined
  }
}

fn resolve_module_path(from : String, spec : String) -> String {
  let base = if spec.has_prefix("/") {
    spec
  } else {
    normalize_path(dirname(from) + "/" + spec)
  }
  let candidates = [
    base,
    base + ".ts",
    base + ".d.ts",
    base + "/index.ts",
  ]
  let stripped = if base.has_suffix(".js") {
    base.unsafe_substring(start=0, end=base.length() - 3) + ".ts"
  } else {
    base
  }
  candidates.push(stripped)
  for c in candidates {
    if c.has_suffix(".ts") && c_file_exists(path_bytes(c)) != 0 {
      return c
    }
  }
  die("cannot resolve module '" + spec + "' from " + from)
}

fn load_module(path : String, is_global : Bool) -> Module {
  match modules.get(path) {
    Some(m) => return m
    None => ()
  }
  if c_file_exists(path_bytes(path)) == 0 {
    die("cannot read " + path)
  }
  // (in a buffer: a MoonBit Bytes holds fewer than 2^28 bytes)
  let src = Src::read(path)
  // the main file of an incremental build (incr.mbt)
  if path == main_file.val {
    match incr_main_decls(path, src) {
      Some(decls) => {
        let base = aliases.length()
        let m = load_module_decls(path, decls, is_global)
        incr_registered(base, incr_stub_of.val.length())
        return m
      }
      None => ()
    }
  }
  if src.n <= source_chunk {
    let b = src.slice(0, src.n)
    src.free()
    return load_module_src(path, utf8_decode(b), is_global)
  }
  // a String cannot hold sources of hundreds of megabytes: parse them in
  // pieces that end before a top-level declaration
  let decls : Array[Decl] = []
  let mut start = 0
  while start < src.n {
    let end = src.boundary(start + source_chunk)
    for d in parse_source(utf8_decode(src.slice(start, end)), path) {
      decls.push(d)
    }
    start = end
  }
  src.free()
  load_module_decls(path, decls, is_global)
}

// a source file in a buffer of stub.c (files of any size)
struct Src {
  h : Int
  n : Int
}

extern "c" fn c_src_read(path : Bytes) -> Int = "tstc_src_read"

extern "c" fn c_src_slice(h : Int, s : Int64, e : Int64) -> Bytes = "tstc_src_slice"

extern "c" fn c_src_boundary(h : Int, i : Int64) -> Int64 = "tstc_src_boundary"

extern "c" fn c_src_chunks(h : Int) -> Bytes = "tstc_src_chunks"

fn Src::read(path : String) -> Src {
  let h = c_src_read(path_bytes(path))
  if h < 0 {
    die("cannot read " + path)
  }
  let n = c_buf_len(h)
  if n >= 2147483647L {
    die(path + ": larger than 2 GB")
  }
  { h, n: n.to_int() }
}

fn Src::slice(self : Src, s : Int, e : Int) -> Bytes {
  c_src_slice(self.h, s.to_int64(), e.to_int64())
}

// the first position from i where a top-level declaration starts after a
// blank line ("\n\n" followed by "/**", "export " or "type "), or the end
fn Src::boundary(self : Src, i : Int) -> Int {
  c_src_boundary(self.h, i.to_int64()).to_int()
}

fn Src::free(self : Src) -> Unit {
  c_buf_free(self.h)
}

// bytes of source parsed at a time (when a file is larger)
let source_chunk : Int = 1 << 25

fn load_module_src(path : String, src : String, is_global : Bool) -> Module {
  load_module_decls(path, parse_source(src, path), is_global)
}

fn load_module_decls(path : String, decls : Array[Decl], is_global : Bool) -> Module {
  let m = {
    path,
    decls,
    locals: Map::new(),
    exports: Map::new(),
    ns_imports: Map::new(),
    imports: Map::new(),
    done_exports: false,
  }
  modules.set(path, m)
  // register declarations
  for d in decls {
    match d {
      DAlias(name, tps, body, doc, _) => {
        if m.locals.contains(name) {
          die(path + ": duplicate identifier '" + name + "'")
        }
        let idx = aliases.length()
        aliases.push({
          name,
          doc,
          file: path,
          nparams: tps.length(),
          param_names: tps.map(fn(p) { p.name }),
          defaults: [],
          body: CTy(TAny),
          frame: 0,
          native: native_id_of_doc(doc, name),
          iface_members: [],
          iface_heritage: [],
          decl_params: tps,
          decl_body: Some(body),
          is_interface: false,
        })
        m.locals.set(name, idx)
        if is_global {
          globals.set(name, idx)
        }
      }
      DInterface(name, tps, heritage, members, doc, _) =>
        match m.locals.get(name) {
          Some(idx) if !aliases[idx].is_interface =>
            die(path + ": duplicate identifier '" + name + "'")
          Some(idx) => {
            let a = aliases[idx]
            for mm in members {
              a.iface_members.push(mm)
            }
            for h in heritage {
              a.iface_heritage.push(h)
            }
          }
          _ => {
            let idx = aliases.length()
            aliases.push({
              name,
              doc,
              file: path,
              nparams: tps.length(),
              param_names: tps.map(fn(p) { p.name }),
              defaults: [],
              body: CTy(TAny),
              frame: 0,
              native: native_id_of_doc(doc, name),
              iface_members: members.copy(),
              iface_heritage: heritage.copy(),
              decl_params: tps,
              decl_body: None,
              is_interface: true,
            })
            m.locals.set(name, idx)
            if is_global {
              globals.set(name, idx)
            }
          }
        }
      _ => ()
    }
  }
  // load imported modules
  for d in decls {
    match d {
      DImport(_, spec) | DImportNs(_, spec) | DExportStar(spec) => {
        let p = resolve_module_path(path, spec)
        let _ = load_module(p, false)

      }
      DExportNames(_, Some(spec)) => {
        let p = resolve_module_path(path, spec)
        let _ = load_module(p, false)

      }
      _ => ()
    }
  }
  m
}

fn module_exports(m : Module) -> Map[String, Int] {
  if m.done_exports {
    return m.exports
  }
  m.done_exports = true
  // every top-level declaration is visible to importers
  m.locals.each(fn(k, v) { m.exports.set(k, v) })
  for d in m.decls {
    match d {
      DExportStar(spec) => {
        let other = modules.get(resolve_module_path(m.path, spec)).unwrap()
        module_exports(other).each(fn(k, v) {
          if !m.exports.contains(k) {
            m.exports.set(k, v)
          }
        })
      }
      DExportNames(names, Some(spec)) => {
        let other = modules.get(resolve_module_path(m.path, spec)).unwrap()
        let ex = module_exports(other)
        for p in names {
          match ex.get(p.0) {
            Some(v) => m.exports.set(p.1, v)
            None => die(m.path + ": '" + p.0 + "' is not exported by " + spec)
          }
        }
      }
      _ => ()
    }
  }
  // local re-exports: export { A as B }
  for d in m.decls {
    match d {
      DExportNames(names, None) =>
        for p in names {
          match lookup_module_name(m, p.0) {
            Some(v) => m.exports.set(p.1, v)
            None => ()
          }
        }
      _ => ()
    }
  }
  m.exports
}

fn lookup_module_name(m : Module, name : String) -> Int? {
  match m.locals.get(name) {
    Some(v) => return Some(v)
    None => ()
  }
  match m.imports.get(name) {
    Some(v) => return Some(v)
    None => ()
  }
  globals.get(name)
}

fn resolve_imports(m : Module) -> Unit {
  for d in m.decls {
    match d {
      DImport(names, spec) => {
        let other = modules.get(resolve_module_path(m.path, spec)).unwrap()
        let ex = module_exports(other)
        for p in names {
          match ex.get(p.0) {
            Some(v) => m.imports.set(p.1, v)
            None => die(m.path + ": '" + p.0 + "' is not exported by " + spec)
          }
        }
      }
      DImportNs(ns, spec) => {
        let other = modules.get(resolve_module_path(m.path, spec)).unwrap()
        m.ns_imports.set(ns, other)
      }
      _ => ()
    }
  }
}

// ---------------------------------------------------------------------------
// Compilation of type expressions

// A scope holds every visible name (flattened), so lookups do not walk the
// chain of nested scopes (compiled Go code nests thousands of `infer` lets).
struct Scope {
  flat : @immut/hashmap.HashMap[String, Int]
}

fn scope_child(parent : Scope?, names : Map[String, Int]) -> Scope {
  let mut flat = match parent {
    Some(p) => p.flat
    None => @immut/hashmap.HashMap::new()
  }
  names.each(fn(k, v) { flat = flat.add(k, v) })
  { flat, }
}

struct Ctx {
  module : Module
  alias : Alias
  mut frame : Int
  cons : Map[Int, TE] // declared constraints of type parameters by slot
  idx : Int // the alias's index
  // resolving the alias's declared type resolves this part too (tsc and
  // tsgo: a type alias circularly references itself through such parts)
  mut eager : Bool
  // within the extends clause of a conditional type (where `infer` may be)
  mut in_ext : Int
  // the relations tsc requires are checked (check.mbt)
  checks : Bool
  // what the type variables (by slot) are known to be: their constraints,
  // and the extends types of the conditionals in whose true branches they
  // are (with whether those types are concrete)
  vcons : Map[Int, Array[(TE, Bool)]]
  narrow : Map[Int, Array[(TE, Bool)]]
}

// the aliases whose declared types resolving an alias's declared type
// resolves (Ctx::eager)
let eager_edges : Map[Int, Array[Int]] = Map::new()

// compiles te as a part resolved later than the alias's declared type
fn compile_lazy(ctx : Ctx, sc : Scope?, te : TE) -> Code {
  let saved = ctx.eager
  ctx.eager = false
  let c = compile_te(ctx, sc, te)
  ctx.eager = saved
  c
}

// a type alias that circularly references itself (in the parts resolved
// with its declared type): tsc and tsgo report it, and use an error type
fn check_alias_cycles() -> Unit {
  // 0 unvisited, 1 on the path, 2 done
  let state : Map[Int, Int] = Map::new()
  fn visit(i : Int) -> Unit {
    match state.get(i) {
      Some(1) => {
        let msg = aliases[i].file + ": type alias '" + aliases[i].name + "' circularly references itself"
        if !checks_warn.val {
          die(msg)
        }
        err("tstc: warning: " + msg + "\n")
        return
      }
      Some(_) => return
      None => ()
    }
    state.set(i, 1)
    match eager_edges.get(i) {
      Some(es) => for j in es { visit(j) }
      None => ()
    }
    state.set(i, 2)
  }
  eager_edges.each(fn(i, _) { visit(i) })
}

fn Ctx::alloc(self : Ctx) -> Int {
  let s = self.frame
  self.frame += 1
  // (a slot of a sibling branch's variable)
  self.vcons.remove(s)
  s
}

fn scope_lookup(sc : Scope?, name : String) -> Int? {
  match sc {
    None => None
    Some(s) => s.flat.get(name)
  }
}

fn[T] cfail(ctx : Ctx, msg : String) -> T {
  die(ctx.module.path + " (in type " + ctx.alias.name + "): " + msg)
}

fn compile_alias(idx : Int) -> Unit {
  cond_free_nomemo.val = true
  compile_alias_body(idx)
  cond_free_nomemo.val = false
}

fn compile_alias_body(idx : Int) -> Unit {
  let a = aliases[idx]
  let m = modules.get(a.file).unwrap()
  let ctx = {
    module: m,
    alias: a,
    frame: 0,
    cons: Map::new(),
    idx,
    eager: !a.is_interface && !synthetic.contains(idx),
    in_ext: 0,
    checks: !synthetic.contains(idx) && m.path != "<prelude>",
    vcons: Map::new(),
    narrow: Map::new(),
  }
  let names : Map[String, Int] = Map::new()
  for p in a.decl_params {
    let slot = ctx.alloc()
    names.set(p.name, slot)
    match p.constraint {
      Some(c) => ctx.cons.set(slot, c)
      None => ()
    }
  }
  let sc = Some(scope_child(None, names))
  a.defaults = a.decl_params.map(fn(p) {
    match p.default {
      Some(d) => Some(compile_lazy(ctx, sc, d))
      None => None
    }
  })
  if ctx.checks {
    // (the constraints' references are resolved and checked)
    for i, p in a.decl_params {
      match p.constraint {
        Some(c) => {
          let cc = compile_lazy(ctx, sc, c)
          ctx.vcons.set(i, [(c, code_is_concrete(cc))])
          match (p.default, a.defaults[i]) {
            (Some(d), Some(dc)) if !te_refers_to(c, a.decl_params) =>
              check_assignable(
                ctx,
                d,
                dc,
                c,
                cc,
                "the default of '\{p.name}' does not satisfy its constraint",
              )
            _ => ()
          }
        }
        None => ()
      }
    }
  }
  if a.native >= 0 {
    // (the fused natives have no declared parameters, fuse.mbt)
    a.frame = if ctx.frame > a.nparams { ctx.frame } else { a.nparams }
    return
  }
  if a.is_interface {
    let parts : Array[Code] = []
    for h in a.iface_heritage {
      parts.push(compile_te(ctx, sc, h))
    }
    parts.push(compile_te(ctx, sc, EObj(a.iface_members)))
    let body = if parts.length() == 1 { parts[0] } else { CInter(parts) }
    // (an interface: one object type of its bases' members and its own, no
    // anonymous type: n_iface)
    let m = modules.get("<prelude>").unwrap()
    a.body = match m.locals.get("__TstcIface") {
      Some(ia) => CNative(ia, aliases[ia].native, [body])
      None => body
    }
  } else {
    match a.decl_body {
      Some(ERef("intrinsic", [], [], _)) =>
        die("intrinsic type '" + a.name + "' is not supported")
      Some(b) => {
        a.body = compile_te(ctx, sc, b)
        subst_alias(ctx, a)
      }
      None => ()
    }
    // (the syntax tree's memory serves the next aliases)
    a.decl_body = None
  }
  a.frame = frame_size(ctx.frame)
}

// a frame's slots, rounded up (by up to a quarter): callers set the top of
// the stack past the callee's frame, so a frame's size is in its callers'
// code, and an edit adding a slot or two should mostly leave them as they
// are (for the module cache)
fn frame_size(n : Int) -> Int {
  if n <= 4 {
    return n
  }
  let mut p = 1
  while p * 2 <= n {
    p *= 2
  }
  let g = if p / 4 > 4 { p / 4 } else { 4 }
  (n + g - 1) / g * g
}

// the modules' declarations without the aliases' bodies (compile_alias
// drops its own reference after compiling)
fn drop_alias_bodies() -> Unit {
  modules.each(fn(_k, m) {
    m.decls = m.decls.map(fn(d) {
      match d {
        DAlias(name, tps, _, doc, exported) => DAlias(name, tps, EBool(true), doc, exported)
        other => other
      }
    })
  })
}

fn kw_ty(k : String) -> Ty {
  match k {
    "any" => TAny
    "unknown" => TUnknown
    "never" => TNever
    "string" => TString
    "number" => TNumber
    "boolean" => t_boolean
    "bigint" => TBigInt
    "symbol" => TSymbol
    "object" => TObjectKw
    "null" => TNull
    "undefined" => TUndefined
    "void" => TVoid
    _ => TAny
  }
}

fn compile_te(ctx : Ctx, sc : Scope?, te : TE) -> Code {
  match te {
    // (members and signatures are resolved later than the declared type)
    EObj(_) | EFn(_, _, _, _) if ctx.eager => {
      ctx.eager = false
      let c = compile_te_inner(ctx, sc, te)
      ctx.eager = true
      c
    }
    _ => compile_te_inner(ctx, sc, te)
  }
}

// `{ ... } extends infer T ? K extends infer N extends keyof T ? T[N] : D :
// never` (an object of properties only, D not naming T or N): the members,
// K and D
fn lookup_idiom(te : TE) -> (Array[Member], TE, TE)? {
  match te {
    ECond(
      EObj(members),
      EInfer(tn, None),
      ECond(key, EInfer(kn, Some(EKeyof(ERef(tn2, [], [], _)))), EIndex(ERef(tn3, [], [], _), ERef(kn2, [], [], _)), dflt),
      EKw("never")
    ) if tn == tn2 && tn == tn3 && kn == kn2 && tn != kn &&
      members.iter().all(fn(m) { m is MProp(_, _, false, _) }) &&
      !te_refers_to(dflt, [{ name: tn, constraint: None, default: None }, { name: kn, constraint: None, default: None }]) &&
      !te_refers_to(key, [{ name: tn, constraint: None, default: None }]) =>
      Some((members, key, dflt))
    _ => None
  }
}

// the order of a tuple's elements: optional ones after required ones, rest
// ones last (tsc and tsgo: checkTupleType)
fn check_tuple_order(ctx : Ctx, elems : Array[TElem]) -> Unit {
  let mut seen_opt = false
  let mut seen_rest = false
  for e in elems {
    if e.kind == K_REST {
      // a variadic element is a rest element when its type is an array or
      // a tuple with a rest element
      if te_is_rest_spread(e.ty) {
        if seen_rest {
          cfail(ctx, "a rest element cannot follow another rest element")
        }
        seen_rest = true
      }
    } else if e.kind == K_OPT {
      if seen_rest {
        cfail(ctx, "an optional element cannot follow a rest element")
      }
      seen_opt = true
    } else if seen_opt {
      cfail(ctx, "a required element cannot follow an optional element")
    }
  }
}

// a written type that is an array, or a tuple with a rest element
fn te_is_rest_spread(t : TE) -> Bool {
  match t {
    EArray(_, _) => true
    ETuple(elems, _) => elems.iter().any(fn(e) { e.kind == K_REST && te_is_rest_spread(e.ty) })
    _ => false
  }
}

fn compile_te_inner(ctx : Ctx, sc : Scope?, te : TE) -> Code {
  match te {
    EKw(k) => CTy(kw_ty(k))
    EStr(s) => CTy(TStrLit(Str::of_string(s)))
    ENum(d) => CTy(TNumLit(d))
    EBig(s) => CTy(bigint_ty(normalize_bigint(s)))
    EBool(b) => CTy(bool_ty(b))
    EThis => cfail(ctx, "'this' types are not supported")
    ENullable(_, _) =>
      cfail(ctx, "JSDoc types can only be used inside documentation comments")
    ETypeofUnsupported(_) => cfail(ctx, "'typeof' is not supported")
    // by position in the file, and the file's place in the load order: the
    // same in every build of an unchanged file
    EUniqueSymbol(pos) => CUniqueSym(pos + 1000000 * (file_ordinal(ctx.module.path) + 1))
    ERef(name, quals, args, _) => compile_ref(ctx, sc, name, quals, args)
    EUnion(items) => node_union(items.map(fn(t) { compile_te(ctx, sc, t) }))
    EInter(items) => node_inter(items.map(fn(t) { compile_te(ctx, sc, t) }))
    ECond(_, _, _, _) if lookup_idiom(te) is Some(_) => {
      // a table lookup with a default (go2types' dispatch tables):
      // `{ "1": A; "2": B } extends infer T ? K extends infer N extends
      // keyof T ? T[N] : D : never` is the property of the object K names,
      // else D: the object indexed by K, with D as its index signature
      // (only the selected property is evaluated)
      let (members, key, dflt) = lookup_idiom(te).unwrap()
      let oc = match compile_te(ctx, sc, EObj(members)) {
        CObj(oc) => oc
        _ => abort("lookup")
      }
      let kc = compile_te(ctx, sc, key)
      let index = match dflt {
        EKw("never") => []
        d => [(CTy(TString), compile_lazy(ctx, sc, d), false)]
      }
      CIndex(
        CObj({ props: oc.props, index, calls: [], lookup: Ref::new(None), id: fresh_code_id() }),
        kc,
      )
    }
    ECond(check, ext, t, f) => {
      let c = compile_te(ctx, sc, check)
      let dist = match check {
        ERef(n, [], [], _) =>
          match scope_lookup(sc, n) {
            Some(s) => s
            None => -1
          }
        _ => -1
      }
      let infer_names : Map[String, Int] = Map::new()
      let infer_slots : Array[Int] = []
      ctx.in_ext += 1
      let pat = compile_pat(ctx, sc, ext, infer_names, infer_slots)
      let tsc = if infer_names.is_empty() {
        sc
      } else {
        Some(scope_child(sc, infer_names))
      }
      let ext_code = compile_te(ctx, tsc, ext)
      ctx.in_ext -= 1
      // the branches exclude each other: slots allocated in one can be
      // reused by the other (nothing after the conditional reuses them)
      let base = ctx.frame
      // in the true branch, the checked type variable is known to extend
      // the extends type (tsc: getImpliedConstraint)
      let narrowed = match (check, ext, c, ext_code) {
        (ERef(_, [], [], _), _, CSlot(s), _) => Some((s, ext, code_is_concrete(ext_code)))
        (
          ETuple([{ ty: ERef(_, [], [], _), kind: 0, .. }], _),
          ETuple([{ ty: xt, kind: 0, .. }], _),
          CTuple([{ code: CSlot(s), .. }], _),
          CTuple([{ code: xc, .. }], _),
        ) => Some((s, xt, code_is_concrete(xc)))
        _ => None
      }
      match narrowed {
        Some((s, xt, ok)) =>
          match ctx.narrow.get(s) {
            Some(a) => a.push((xt, ok))
            None => ctx.narrow.set(s, [(xt, ok)])
          }
        None => ()
      }
      let tc = compile_lazy(ctx, tsc, t)
      match narrowed {
        Some((s, _, _)) => {
          let a = ctx.narrow.get(s).unwrap()
          let _ = a.pop()
          if a.is_empty() {
            ctx.narrow.remove(s)
          }
        }
        None => ()
      }
      let after_t = ctx.frame
      ctx.frame = base
      let fc = compile_lazy(ctx, sc, f)
      if after_t > ctx.frame {
        ctx.frame = after_t
      }
      let p = if infer_slots.is_empty() { None } else { Some(pat) }
      let (fast, fslots) = cond_fast(p, ext_code)
      // `rtok<X> extends true ? T : F` (lib/pure rterr.ts): natively rtok is
      // always true, as a failing operation does not return (rt/try.c)
      match c {
        CNative(_, id, _) if fast == 3 && native_name(id) == "rtok" => return tc
        _ => ()
      }
      CCond({
        check: c,
        ext: ext_code,
        pat: p,
        t: tc,
        f: fc,
        dist_slot: dist,
        infer_slots,
        fast,
        fslots,
        id: fresh_code_id(),
      })
    }
    EInfer(name, _) if ctx.in_ext == 0 =>
      cfail(
        ctx,
        "'infer \{name}': 'infer' declarations are only permitted in the 'extends' clause of a conditional type",
      )
    EInfer(name, _) =>
      match scope_lookup(sc, name) {
        Some(s) => CSlot(s)
        None => cfail(ctx, "'infer " + name + "' outside of an extends clause")
      }
    ETuple(elems, ro) => {
      check_tuple_order(ctx, elems)
      CTuple(
        elems.map(fn(e) {
          let code = compile_lazy(ctx, sc, e.ty)
          if e.kind == K_REST && !(e.ty is EArray(_, _)) && !(e.ty is ETuple(_, _)) {
            check_assignable(
              ctx,
              e.ty,
              code,
              any_readonly_array_te,
              compile_te(ctx, None, any_readonly_array_te),
              "a rest element type must be an array type",
            )
          }
          {
            code,
            kind: e.kind,
            name: if e.name == "" { None } else { Some(Str::of_string(e.name)) },
          }
        }),
        ro,
      )
    }
    EArray(t, ro) => CArray(compile_lazy(ctx, sc, t), ro)
    EObj(members) => {
      let props : Array[(Str, Code, Bool, Bool, Bool)] = []
      let index : Array[(Code, Code, Bool)] = []
      let calls : Array[(Array[CParam], Code, Bool)] = []
      for m in members {
        match m {
          MProp(name, t, opt, ro) => {
            let (n, numeric) = split_numeric_name(name)
            props.push((Str::of_string(n), compile_te(ctx, sc, t), opt, ro, numeric))
          }
          MIndex(_, kt, vt, ro) =>
            index.push((compile_te(ctx, sc, kt), compile_te(ctx, sc, vt), ro))
          MCall(tps, params, ret, is_ctor) => {
            let fsc = fn_scope(ctx, sc, tps)
            calls.push(
              (
                compile_params(ctx, fsc, params),
                compile_te(ctx, fsc, ret),
                is_ctor,
              ),
            )
          }
        }
      }
      check_index_constraints(ctx, members, props, index)
      CObj({ props, index, calls, lookup: Ref::new(None), id: fresh_code_id() })
    }
    EMapped(mp) => {
      let slot = ctx.alloc()
      let names : Map[String, Int] = Map::new()
      names.set(mp.param, slot)
      let inner = Some(scope_child(sc, names))
      let is_param = fn(t : TE) {
        match t {
          ERef(n, [], [], _) => scope_lookup(sc, n) is Some(_)
          _ => false
        }
      }
      let homo = match mp.constraint {
        EKeyof(x) => if is_param(x) { Some(compile_te(ctx, sc, x)) } else { None }
        _ => None
      }
      let homo_slot = match (mp.constraint, homo) {
        (EKeyof(ERef(n, [], [], _)), Some(_)) => scope_lookup(sc, n).unwrap_or(-1)
        _ => -1
      }
      let kof = mp.constraint is EKeyof(_)
      let mods = match mp.constraint {
        EKeyof(x) => if is_param(x) { None } else { Some(compile_te(ctx, sc, x)) }
        ERef(n, [], [], _) =>
          match scope_lookup(sc, n) {
            Some(s) =>
              match ctx.cons.get(s) {
                Some(EKeyof(x)) => Some(compile_te(ctx, sc, x))
                _ => None
              }
            None => None
          }
        _ => None
      }
      let constraint = compile_te(ctx, sc, mp.constraint)
      ctx.vcons.set(slot, [(mp.constraint, code_is_concrete(constraint))])
      if mp.as_clause is None && !(mp.constraint is EKeyof(_)) {
        check_assignable(
          ctx,
          mp.constraint,
          constraint,
          property_key_te,
          compile_te(ctx, None, property_key_te),
          "a mapped type's constraint is not assignable to 'string | number | symbol'",
        )
      }
      CMapped({
        slot,
        constraint,
        homo,
        homo_slot,
        mods,
        kof,
        as_clause: match mp.as_clause {
          Some(a) => Some(compile_lazy(ctx, inner, a))
          None => None
        },
        body: match mp.body {
          Some(b) => compile_lazy(ctx, inner, b)
          None => CTy(TAny)
        },
        ro: mp.readonly_mod,
        opt: mp.optional_mod,
        id: fresh_code_id(),
      })
    }
    EIndex(o, i) => {
      let oc = compile_te(ctx, sc, o)
      let ic = compile_te(ctx, sc, i)
      check_index_access(ctx, o, oc, i, ic)
      CIndex(oc, ic)
    }
    EKeyof(t) => CKeyof(compile_te(ctx, sc, t))
    ETpl(texts, spans) => {
      let codes = spans.map(fn(t) { compile_te(ctx, sc, t) })
      for i, t in spans {
        check_assignable(
          ctx,
          t,
          codes[i],
          template_constraint_te,
          compile_te(ctx, None, template_constraint_te),
          "a template literal placeholder's type is not assignable to 'string | number | bigint | boolean | null | undefined'",
        )
      }
      CTpl(texts.map(fn(s) { Str::of_string(s) }), codes)
    }
    EFn(tps, params, ret, is_ctor) =>
      if tps.is_empty() {
        CFn(compile_params(ctx, sc, params), compile_te(ctx, sc, ret), is_ctor)
      } else {
        let fsc = fn_scope(ctx, sc, tps)
        let slots = tps.map(fn(p) { scope_lookup(fsc, p.name).unwrap() })
        CGenericFn(
          slots,
          CFn(compile_params(ctx, fsc, params), compile_te(ctx, fsc, ret), is_ctor),
        )
      }
  }
}

fn fn_scope(ctx : Ctx, sc : Scope?, tps : Array[TParamE]) -> Scope? {
  if tps.is_empty() {
    return sc
  }
  let names : Map[String, Int] = Map::new()
  for p in tps {
    names.set(p.name, ctx.alloc())
  }
  let fsc = Some(scope_child(sc, names))
  if ctx.checks {
    // (the constraints' and defaults' references are resolved and checked)
    for p in tps {
      match p.constraint {
        Some(t) => {
          let cc = compile_lazy(ctx, fsc, t)
          ctx.vcons.set(names.get(p.name).unwrap(), [(t, code_is_concrete(cc))])
        }
        None => ()
      }
      match p.default {
        Some(t) => {
          let _ = compile_lazy(ctx, fsc, t)

        }
        None => ()
      }
    }
  }
  fsc
}

fn compile_params(ctx : Ctx, sc : Scope?, params : Array[FParam]) -> Array[CParam] {
  params.map(fn(p) {
    let code = compile_te(ctx, sc, p.ty)
    if p.rest && !(p.ty is EArray(_, _)) && !(p.ty is ETuple(_, _)) {
      check_assignable(
        ctx,
        p.ty,
        code,
        any_readonly_array_te,
        compile_te(ctx, None, any_readonly_array_te),
        "a rest parameter must be of an array type",
      )
    }
    {
      name: Str::of_string(p.name),
      code,
      optional: p.optional,
      rest: p.rest,
    }
  })
}

// digits in a radix (ignoring _ separators) as a decimal string
fn radix_to_decimal(digits : String, radix : Int) -> String {
  let dec : Array[Int] = [0] // little-endian decimal digits
  for ch in digits {
    let d = if ch >= '0' && ch <= '9' {
      ch.to_int() - 48
    } else if ch >= 'a' && ch <= 'f' {
      ch.to_int() - 87
    } else if ch >= 'A' && ch <= 'F' {
      ch.to_int() - 55
    } else {
      continue
    }
    let mut carry = d
    for k in 0..<dec.length() {
      let v = dec[k] * radix + carry
      dec[k] = v % 10
      carry = v / 10
    }
    while carry > 0 {
      dec.push(carry % 10)
      carry = carry / 10
    }
  }
  let sb = StringBuilder::new()
  let mut k = dec.length() - 1
  while k >= 0 {
    sb.write_char(Char::from_int(dec[k] + 48))
    k -= 1
  }
  sb.to_string()
}

fn normalize_bigint(s : String) -> String {
  // decimal canonical form for decimal input; leave others as written
  let mut neg = false
  let mut t = s
  if t.has_prefix("-") {
    neg = true
    t = t.unsafe_substring(start=1, end=t.length())
  }
  // 0x, 0o, 0b literals are written in decimal, as tsc prints them
  if t.length() > 2 && t.at(0) == '0' {
    let radix = match t.at(1) {
      'x' | 'X' => 16
      'o' | 'O' => 8
      'b' | 'B' => 2
      _ => 0
    }
    if radix > 0 {
      t = radix_to_decimal(t.unsafe_substring(start=2, end=t.length()), radix)
    }
  }
  let mut i = 0
  while i < t.length() - 1 && t.at(i) == '0' {
    i += 1
  }
  t = t.unsafe_substring(start=i, end=t.length())
  if neg && t != "0" {
    "-" + t
  } else {
    t
  }
}

fn compile_ref(
  ctx : Ctx,
  sc : Scope?,
  name : String,
  quals : Array[String],
  args : Array[TE],
) -> Code {
  if quals.length() > 0 {
    match ctx.module.ns_imports.get(name) {
      Some(other) => {
        let ex = module_exports(other)
        match ex.get(quals[0]) {
          Some(idx) => return mk_call(ctx, sc, idx, args)
          None => cfail(ctx, "'" + quals[0] + "' is not exported by " + name)
        }
      }
      None => cfail(ctx, "unknown namespace '" + name + "'")
    }
  }
  match scope_lookup(sc, name) {
    Some(slot) => {
      if args.length() > 0 {
        cfail(ctx, "type parameter '" + name + "' is not generic")
      }
      return CSlot(slot)
    }
    None => ()
  }
  match lookup_module_name(ctx.module, name) {
    Some(idx) => return mk_call(ctx, sc, idx, args)
    None => ()
  }
  match name {
    "Array" =>
      if args.length() == 1 {
        CArray(compile_te(ctx, sc, args[0]), false)
      } else {
        cfail(ctx, "Array needs one type argument")
      }
    "ReadonlyArray" =>
      if args.length() == 1 {
        CArray(compile_te(ctx, sc, args[0]), true)
      } else {
        cfail(ctx, "ReadonlyArray needs one type argument")
      }
    "Function" =>
      CFn([{ name: Str::of_string("args"), code: CArray(CTy(TAny), false), optional: false, rest: true }], CTy(TAny), false)
    "Object" => CObj({ props: [], index: [], calls: [], lookup: Ref::new(None), id: fresh_code_id() })
    _ => cfail(ctx, "cannot find name '" + name + "'")
  }
}

fn mk_call(ctx : Ctx, sc : Scope?, idx : Int, args : Array[TE]) -> Code {
  let a = aliases[idx]
  if ctx.eager && !a.is_interface {
    match eager_edges.get(ctx.idx) {
      Some(es) => if !es.contains(idx) { es.push(idx) }
      None => eager_edges.set(ctx.idx, [idx])
    }
  }
  if args.length() > a.nparams {
    cfail(ctx, "too many type arguments for '" + a.name + "'")
  }
  // tsc and tsgo make a reference with too few an error type (any)
  let required = a.decl_params.iter().filter(fn(p) { p.default is None }).count()
  if args.length() < required {
    cfail(ctx, "'" + a.name + "' needs \{required} type arguments, got \{args.length()}")
  }
  let cargs = args.map(fn(t) { compile_te(ctx, sc, t) })
  check_type_arguments(ctx, idx, args, cargs)
  if a.native >= 0 && native_is_lib(a.native) && args.length() == a.nparams {
    return native_call_code(idx, a.native, cargs)
  }
  CCall(idx, cargs)
}

// A union or intersection as the checker resolves it where it is written:
// a member of a type parameter is generic then, so unknown in a union and any
// in an intersection absorb it for good (whatever it is instantiated to);
// never in an intersection absorbs everything
fn node_union(cs : Array[Code]) -> Code {
  if !cs.iter().any(fn(c) { c is CTy(TUnknown) }) || cs.iter().any(fn(c) { c is CTy(TAny) }) {
    return CUnion(cs)
  }
  if cs.iter().all(fn(c) { code_free(c).is_empty() }) {
    return CUnion(cs)
  }
  CUnion(cs.filter(fn(c) { code_free(c).is_empty() }))
}

fn node_inter(cs : Array[Code]) -> Code {
  if cs.iter().any(fn(c) { c is CTy(TNever) }) {
    return CTy(TNever)
  }
  if !cs.iter().any(fn(c) { c is CTy(TAny) }) || cs.iter().all(fn(c) { code_free(c).is_empty() }) {
    return CInter(cs)
  }
  CInter(cs.filter(fn(c) { code_free(c).is_empty() }))
}

// Compiles the extends clause of a conditional type into a pattern,
// allocating slots for `infer` declarations.
fn compile_pat(
  ctx : Ctx,
  sc : Scope?,
  te : TE,
  infer_names : Map[String, Int],
  infer_slots : Array[Int],
) -> Pat {
  if !te_has_infer(te) {
    return PCode(CTy(TNever)) // placeholder; replaced below by the caller's ext code when no infer
  }
  fn sub(t : TE) -> Pat {
    if !te_has_infer(t) {
      // infer names declared so far in this extends clause are visible
      PCode(compile_te(ctx, Some(scope_child(sc, infer_names)), t))
    } else {
      compile_pat(ctx, sc, t, infer_names, infer_slots)
    }
  }

  match te {
    EInfer(name, cons) => {
      let slot = match infer_names.get(name) {
        Some(s) => s
        None => {
          let s = ctx.alloc()
          infer_names.set(name, s)
          infer_slots.push(s)
          s
        }
      }
      let c = match cons {
        Some(ct) => {
          let cc = compile_te(ctx, Some(scope_child(sc, infer_names)), ct)
          ctx.vcons.set(slot, [(ct, code_is_concrete(cc))])
          Some(cc)
        }
        None => None
      }
      PInfer(slot, c)
    }
    ETuple(elems, ro) => {
      let r = PTuple(elems.map(fn(e) { { pat: sub(e.ty), kind: e.kind } }), ro)
      // (an infer declaration as a rest element: unknown[])
      for e in elems {
        if e.kind == K_REST {
          implied_infer_constraint(ctx, e.ty, infer_names, EArray(EKw("unknown"), false))
        }
      }
      r
    }
    EArray(t, ro) => PArray(sub(t), ro)
    EObj(members) => {
      let props : Array[PProp] = []
      for m in members {
        match m {
          MProp(name, t, opt, _) =>
            props.push({ name: Str::of_string(split_numeric_name(name).0), pat: sub(t), optional: opt })
          _ => cfail(ctx, "unsupported member in infer pattern")
        }
      }
      PObj(props)
    }
    ETpl(texts, spans) => {
      let pats = spans.map(fn(t) { sub(t) })
      // (an infer declaration in a placeholder: string, tsc's implied
      // constraint)
      for t in spans {
        implied_infer_constraint(ctx, t, infer_names, EKw("string"))
      }
      PTpl(texts.map(fn(s) { Str::of_string(s) }), pats)
    }
    EFn(_, params, ret, _) => {
      let r = PFn(params.map(fn(p) {
        { pat: sub(p.ty), kind: if p.rest { K_REST } else if p.optional { K_OPT } else { K_REQ } }
      }), sub(ret))
      // (...args: infer A) => R: A is unknown[]
      for p in params {
        if p.rest {
          implied_infer_constraint(ctx, p.ty, infer_names, EArray(EKw("unknown"), false))
        }
      }
      r
    }
    EUnion(items) => PUnion(items.map(fn(t) { sub(t) }))
    ERef(_, _, _, _) | EInter(_) | EIndex(_, _) | EKeyof(_) | ECond(_, _, _, _) | EMapped(_) => {
      // infer nested inside an alias reference or other construct: the
      // runtime instantiates the type with type parameters for the slots
      // and infers to it (tsc: the extends type is instantiated so)
      let infs : Array[PElem] = []
      declare_infers(ctx, sc, te, infer_names, infer_slots, infs, 0)
      PVal(compile_te(ctx, Some(scope_child(sc, infer_names)), te), infs)
    }
    _ => cfail(ctx, "unsupported infer pattern")
  }
}

// the infer declarations of te (the parts te_has_infer looks into),
// allocated as compile_pat does, in infs by occurrence (ctx: 1 a rest
// element, 2 a template placeholder)
fn declare_infers(
  ctx : Ctx,
  sc : Scope?,
  te : TE,
  infer_names : Map[String, Int],
  infer_slots : Array[Int],
  infs : Array[PElem],
  where : Int,
) -> Unit {
  let go = fn(t : TE, w : Int) { declare_infers(ctx, sc, t, infer_names, infer_slots, infs, w) }
  match te {
    EInfer(name, cons) => {
      let slot = match infer_names.get(name) {
        Some(s) => s
        None => {
          let s = ctx.alloc()
          infer_names.set(name, s)
          infer_slots.push(s)
          s
        }
      }
      let c = match cons {
        Some(ct) => {
          let cc = compile_te(ctx, Some(scope_child(sc, infer_names)), ct)
          ctx.vcons.set(slot, [(ct, code_is_concrete(cc))])
          Some(cc)
        }
        None => None
      }
      if where == 1 {
        implied_infer_constraint(ctx, te, infer_names, EArray(EKw("unknown"), false))
      } else if where == 2 {
        implied_infer_constraint(ctx, te, infer_names, EKw("string"))
      }
      infs.push({ pat: PInfer(slot, c), kind: where })
    }
    ERef(_, _, args, _) => for a in args { go(a, 0) }
    EUnion(items) | EInter(items) => for t in items { go(t, 0) }
    ETuple(elems, _) => for e in elems { go(e.ty, if e.kind == K_REST { 1 } else { 0 }) }
    EArray(t, _) | EKeyof(t) => go(t, 0)
    EObj(members) =>
      for m in members {
        match m {
          MProp(_, t, _, _) => go(t, 0)
          MIndex(_, k, v, _) => {
            go(k, 0)
            go(v, 0)
          }
          MCall(_, ps, r, _) => {
            for p in ps {
              go(p.ty, if p.rest { 1 } else { 0 })
            }
            go(r, 0)
          }
        }
      }
    EIndex(a, b) => {
      go(a, 0)
      go(b, 0)
    }
    ETpl(_, spans) => for t in spans { go(t, 2) }
    EFn(_, ps, r, _) => {
      for p in ps {
        go(p.ty, if p.rest { 1 } else { 0 })
      }
      go(r, 0)
    }
    _ => ()
  }
}

// tsc's constraint of an `infer X` without one, from where it is
fn implied_infer_constraint(ctx : Ctx, t : TE, infer_names : Map[String, Int], c : TE) -> Unit {
  match t {
    EInfer(n, None) =>
      match infer_names.get(n) {
        Some(s) =>
          match ctx.vcons.get(s) {
            Some(a) => a.push((c, true))
            None => ctx.vcons.set(s, [(c, true)])
          }
        None => ()
      }
    _ => ()
  }
}

fn te_has_infer(te : TE) -> Bool {
  match te {
    EInfer(_, _) => true
    ERef(_, _, args, _) => args.iter().any(te_has_infer)
    EUnion(items) | EInter(items) => items.iter().any(te_has_infer)
    ECond(_, _, _, _) => false
    ETuple(elems, _) => elems.iter().any(fn(e) { te_has_infer(e.ty) })
    EArray(t, _) | EKeyof(t) => te_has_infer(t)
    EObj(members) =>
      members
      .iter()
      .any(fn(m) {
        match m {
          MProp(_, t, _, _) => te_has_infer(t)
          MIndex(_, k, v, _) => te_has_infer(k) || te_has_infer(v)
          MCall(_, ps, r, _) =>
            te_has_infer(r) || ps.iter().any(fn(p) { te_has_infer(p.ty) })
        }
      })
    EMapped(_) => false
    EIndex(a, b) => te_has_infer(a) || te_has_infer(b)
    ETpl(_, spans) => spans.iter().any(te_has_infer)
    EFn(_, ps, r, _) => te_has_infer(r) || ps.iter().any(fn(p) { te_has_infer(p.ty) })
    _ => false
  }
}

// bigint literal types that fit in 64 bits are represented natively
fn bigint_ty(s : String) -> Ty {
  let neg = s.has_prefix("-")
  let digits = if neg { s.unsafe_substring(start=1, end=s.length()) } else { s }
  if digits.length() == 0 || digits.length() > 19 ||
    !digits.iter().all(fn(c) { c >= '0' && c <= '9' }) {
    return TBigLit(s)
  }
  let mut v = 0UL
  for c in digits {
    v = v * 10UL + (c.to_int() - 48).to_uint64()
  }
  let limit = 9223372036854775807UL
  if !neg && v <= limit {
    return TInt(v.reinterpret_as_int64())
  }
  if neg && v <= limit + 1UL {
    return TInt((0UL - v).reinterpret_as_int64())
  }
  TBigLit(s)
}

// the parser marks property names written as numbers with a leading U+0001
// (and doubles it on names that start with U+0001, like "\x01")
fn split_numeric_name(name : String) -> (String, Bool) {
  if name.length() > 0 && name.at(0) == '\u{1}' {
    let rest = name.unsafe_substring(start=1, end=name.length())
    (rest, !(rest.length() > 0 && rest.at(0) == '\u{1}'))
  } else {
    (name, false)
  }
}
