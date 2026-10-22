// tstc: compiles type-level TypeScript programs to native executables.

fn usage() -> Unit {
  err(
    (
      #|usage:
      #|  tstc build <file.ts> [-o out] [--entry Name]... [--emit-llvm] [--rt dir] [--cc clang] [-O 0|1|2|3|f|s] [--llvm dir] [--native-fast] [--no-native-fast] [--no-inline] [--check-shapes] [--no-accel] [--no-accel-file f.ts]... [--accel-report] [--no-cse] [--no-ident] [--memo none|auto|rec|all] [-j jobs] [--module-size chars] [--cache dir] [--no-cache] [--cache-verify] [--check] [--checks-warn] [--no-check-generic]
      #|  --check: only parse and compile the aliases (names, arguments), generate nothing
      #|  --checks-warn: report the relations TypeScript requires that do not hold (check.mbt) as warnings
      #|  --no-check-generic: not those relations for type variables (checked by their constraints by default)
      #|
      #|The executable runs the program:
      #|  out run [--entry Main] [--arg-file path]... [--arg text]... [--out path] [--bytes] [--stats]
      #|  out dump      prints every parameterless type alias of the file
      #|
    ),
  )
  c_exit(2)
}

fn setup(file : String) -> Module {
  let _ = load_module_src("<prelude>", prelude_src, true)
  let m = load_module(file, false)
  modules.each(fn(_k, mm) { resolve_imports(mm) })
  accelerate_prelude()
  drop_alias_bodies()
  for i in 0..<aliases.length() {
    // (stubs of an incremental build are compiled when needed, incr.mbt)
    if !incr_is_lazy(i) {
      compile_alias(i)
    }
  }
  check_alias_cycles()
  incr_check_files()
  if accel_report.val {
    err("tstc: fused cell operations: \{fused_count.val}\n")
  }
  m
}

fn main {
  let args = @env.args()
  if args.length() < 3 || args[1] != "build" {
    usage()
    return
  }
  let file = args[2]
  let mut out_path = ""
  let mut emit_llvm = false
  let mut rt_dir = ""
  let mut cc = "clang"
  let mut opt = "2"
  let mut jobs = 8
  let mut llvm_dir = ""
  let entry_names : Array[String] = ["Main"]
  let mut cache_dir = ""
  let mut use_cache = true
  let mut check_only = false
  let mut i = 3
  while i < args.length() {
    let a = args[i]
    if a == "-o" && i + 1 < args.length() {
      out_path = args[i + 1]
      i += 2
    } else if a == "--entry" && i + 1 < args.length() {
      entry_names.push(args[i + 1])
      i += 2
    } else if a == "--cache" && i + 1 < args.length() {
      cache_dir = args[i + 1]
      i += 2
    } else if a == "--no-cache" {
      use_cache = false
      i += 1
    } else if a == "--check" {
      check_only = true
      i += 1
    } else if a == "--checks-warn" {
      checks_warn.val = true
      i += 1
    } else if a == "--no-check-generic" {
      generic_checks.val = false
      i += 1
    } else if a == "--cache-verify" {
      unit_cache_verify.val = true
      i += 1
    } else if a == "--emit-llvm" {
      emit_llvm = true
      i += 1
    } else if a == "--rt" && i + 1 < args.length() {
      rt_dir = args[i + 1]
      i += 2
    } else if a == "--cc" && i + 1 < args.length() {
      cc = args[i + 1]
      i += 2
    } else if a == "--llvm" && i + 1 < args.length() {
      llvm_dir = args[i + 1]
      i += 2
    } else if a == "-j" && i + 1 < args.length() {
      jobs = match (try? @strconv.parse_int(args[i + 1])) {
        Ok(n) => n
        Err(_) => 8
      }
      i += 2
    } else if a == "--module-size" && i + 1 < args.length() {
      module_limit.val = match (try? @strconv.parse_int(args[i + 1])) {
        Ok(n) => n
        Err(_) => 3000000
      }
      i += 2
    } else if a == "-O" && i + 1 < args.length() {
      opt = args[i + 1]
      i += 2
    } else if a == "--no-accel" {
      accel_on.val = false
      i += 1
    } else if a == "--no-accel-file" && i + 1 < args.length() {
      accel_off_files.push(base_name(args[i + 1]))
      i += 2
    } else if a == "--accel-report" {
      accel_report.val = true
      i += 1
    } else if a == "--check-shapes" {
      check_shapes.val = true
      i += 1
    } else if a == "--shape-report" {
      shape_report.val = true
      i += 1
    } else if a == "--no-cse" {
      cse_on.val = false
      i += 1
    } else if a == "--no-ident" {
      ident_on.val = false
      i += 1
    } else if a == "--memo" && i + 1 < args.length() {
      memo_explicit.val = true
      memo_mode.val = match args[i + 1] {
        "none" => 0
        "all" => 2
        "rec" => 3
        _ => 1
      }
      i += 2
    } else if a == "--native-fast" {
      native_fast_set.val = 1
      i += 1
    } else if a == "--no-native-fast" {
      native_fast_set.val = -1
      i += 1
    } else if a == "--native-fast-only" && i + 1 < args.length() {
      for n in args[i + 1].split(",") {
        native_fast_only.push(n.to_string())
      }
      i += 2
    } else if a == "--no-dispatch-ic" {
      dispatch_ic_on.val = false
      i += 1
    } else if a == "--frame-pointers" {
      frame_pointers_on.val = true
      i += 1
    } else if a == "--no-loops" {
      loops_on.val = false
      i += 1
    } else if a == "--no-spec" {
      spec_on.val = false
      i += 1
    } else if a == "--no-dispatch-tree" {
      dispatch_tree_on.val = false
      i += 1
    } else if a == "--no-unwrap" {
      unwrap_on.val = false
      i += 1
    } else if a == "--no-incr" {
      incr_allowed.val = false
      i += 1
    } else if a == "--coverage" {
      coverage_on.val = true
      i += 1
    } else if a == "--no-inline" {
      inline_on.val = false
      i += 1
    } else if a == "--split" && i + 1 < args.length() {
      split_limit.val = match (try? @strconv.parse_int(args[i + 1])) {
        Ok(n) => n
        Err(_) => 200000
      }
      i += 2
    } else {
      usage()
      return
    }
  }
  // --check: parse and compile every alias (names resolved, type arguments
  // counted), nothing generated: the programs' text is then valid for tsc
  // and tsgo as far as tstc can tell
  if check_only {
    main_file.val = file
    let _ = setup(file)
    err("tstc: \{file}: no errors\n")
    return
  }
  if out_path == "" {
    out_path = if file.has_suffix(".ts") {
      file.unsafe_substring(start=0, end=file.length() - 3)
    } else {
      file + ".out"
    }
  }
  // the caches (of units and of objects): by default next to the output
  if cache_dir == "" {
    cache_dir = dirname(out_path) + "/tstc-cache"
  }
  c_mkdir(path_bytes(cache_dir))
  let tag = hex_digits(fnv64(out_path), 8)
  let self_hash = utf8_decode(c_self_hash())
  // nothing to do when the inputs (files, compiler, arguments, runtime) are
  // those of the output's build (with --accel-report the front end runs to
  // report: accel_diff.py read nothing from an up-to-date build and took its
  // natives for not replaced)
  let stamp_path = cache_dir + "/build-" + tag + ".stamp"
  let stamp_head = {
    let sb = StringBuilder::new()
    sb.write_string("tstc-stamp 1 " + self_hash)
    for a in args {
      sb.write_char('\u{1}')
      sb.write_string(a)
    }
    sb.to_string()
  }
  if use_cache && !emit_llvm && !accel_report.val && c_file_exists(path_bytes(out_path)) != 0 &&
    stamp_valid(stamp_path, stamp_head) {
    err("tstc: \{out_path} is up to date\n")
    return
  }
  let _ = c_system(path_bytes("rm -f '" + stamp_path + "'"))
  // the front end's snapshot (incr.mbt): read unless --no-incr, written anyway
  if use_cache && inline_on.val && !unit_cache_verify.val && !shape_report.val {
    incr_path.val = cache_dir + "/front-" + tag + ".snap"
    let sb = StringBuilder::new()
    sb.write_string(self_hash)
    for a in args {
      if a != "--no-incr" {
        sb.write_char('\u{1}')
        sb.write_string(a)
      }
    }
    incr_salt.val = sb.to_string()
    for a in args {
      incr_argv.push(a)
    }
    incr_active.val = incr_allowed.val && incr_load_snapshot()
  }
  // the inline fast paths of the cell and tuple natives: by default with a
  // back end that optimizes them (-O 1 to 3), not with the fast one of -O f
  // and -O s (llc -O0: more cycles than calls)
  native_fast_on.val = native_fast_set.val > 0 ||
    (native_fast_set.val == 0 && opt != "f" && opt != "s" && opt != "0")
  let t0 = now_ms()
  main_file.val = file
  let m = setup(file)
  let t1 = now_ms()
  let rss1 = c_max_rss_mb()
  // entry points: the parameterless aliases of the file (for dump), and the
  // named ones
  let entries : Array[Int] = []
  let dump : Array[Int] = []
  for d in m.decls {
    match d {
      DAlias(name, tps, _, _, _) =>
        if tps.is_empty() {
          let idx = m.locals.get(name).unwrap()
          dump.push(idx)
          entries.push(idx)
        }
      _ => ()
    }
  }
  for n in entry_names {
    match m.locals.get(n) {
      Some(idx) => if !entries.contains(idx) { entries.push(idx) }
      None => ()
    }
  }
  // the checks evaluated once the program is linked (check.mbt)
  for c in eval_checks {
    entries.push(c.0)
  }
  // aliases that catch failures: their handlers are called by the runtime
  find_catches(entries)
  let to0 = now_ms()
  if incr_active.val && memo_mode.val > 0 &&
    (memo_explicit.val || !aliases.iter().any(fn(a) { native_has_effects(a.native) })) {
    // (memoization is planned from every alias's code)
    incr_restart_now("memoization is planned")
  }
  optimize_program()
  let to1 = now_ms()
  if inline_on.val {
    analyze_shapes(entries)
    if shape_report.val {
      print_shape_report()
    }
    incr_shapes_done()
  }
  incr_before_codegen()
  let ta = now_ms()
  let rssa = c_max_rss_mb()
  unit_cache_on.val = use_cache
  unit_cache_base.val = cache_dir + "/units-" + tag
  let nfo = native_fast_only.join(",")
  unit_salt.val = self_hash + " inline=\{inline_on.val} check=\{check_shapes.val} split=\{split_limit.val} accel=\{accel_on.val} unwrap=\{unwrap_on.val} nfast=\{native_fast_on.val} nfo=\{nfo} dtree=\{dispatch_tree_on.val} dic=\{dispatch_ic_on.val} spec=\{spec_on.val} loops=\{loops_on.val} fp=\{frame_pointers_on.val} cov=\{coverage_on.val} ident=\{ident_on.val}"
  let mods = gen_program(entries, dump)
  incr_save(m)
  let t2 = now_ms()
  if incr_path.val != "" {
    err("tstc: incremental: \{incr_parsed_chunks.val} of \{incr_chunks.length()} chunks parsed, \{incr_mat.length()} stubs compiled, \{incr_lazy.length()} stubs kept\n")
  }
  let ninline = inline_conds.values().fold(init=0, fn(n, b) { if b { n + 1 } else { n } })
  err(
    "tstc: front end \{t1 - t0} ms (\{rss1} MB), optimizations \{to1 - to0} ms, shapes \{ta - to1} ms (\{ninline} of \{inline_conds.length()} conditionals inline, \{opt_lets.val} lets, \{unwrap_count.val} unwrapped, \{memo_body.length()} memoized; \{rssa} MB), code generation \{t2 - ta} ms (\{c_max_rss_mb()} MB), \{mods.length()} modules\n",
  )
  if emit_llvm {
    for k in 0..<mods.length() {
      let p = out_path + "." + k.to_string() + ".ll"
      let m = (mods[k].make)()
      if c_bufs_write(FixedArray::from_array(m), path_bytes(p)) == 0 {
        die("cannot write " + p)
      }
      free_module(m)
    }
    return
  }
  if rt_dir == "" {
    die("--rt: the directory of the runtime (libtstcrt.a) is needed")
  }
  // -O f: cheap IR optimizations (opt; the runtime's small helpers inlined)
  // and the fast back end (llc -O0) of an LLVM installation (--llvm): the
  // back end at -O1 and above is where compile time goes. A module's object
  // is B.o for its text $0.ll, $0 = B.<tag> (builds of other outputs sharing
  // the cache use other tags).
  // -O s: the same with a register allocator that spills less (about a
  // third less code, the back end about twice as slow)
  let compile = if opt == "f" || opt == "s" {
    let l = if llvm_dir != "" { llvm_dir } else { "/opt/homebrew/opt/llvm/bin" }
    let ra = if opt == "s" { " -optimize-regalloc -regalloc=basic" } else { "" }
    "sh -c '" + l + "/opt -passes=\"always-inline,function(early-cse,instcombine<no-verify-fixpoint>,simplifycfg)\" \"$0.ll\" -o \"$0.bc\" && " +
    l + "/llc -O0" + ra + " -mtriple=\"$TSTC_TRIPLE\" -filetype=obj \"$0.bc\" -o \"$0.o\" && mv \"$0.o\" \"${0%.*}.o\" && rm -f \"$0.bc\" \"$0.ll\"' {}"
  } else {
    "sh -c '" + cc + " -O" + opt + " -Wno-override-module -c \"$0.ll\" -o \"$0.o\" && mv \"$0.o\" \"${0%.*}.o\" && rm -f \"$0.ll\"' {}"
  }
  // llc targets the C compiler's triple, which the link expects (on macOS
  // with an old minimum version: llc reads darwinN as a newer macOS than the
  // linker's, which warns for every object)
  let triple = if opt == "f" || opt == "s" {
    "TSTC_TRIPLE=$(" + cc +
    " -print-target-triple) && case $TSTC_TRIPLE in *-apple-darwin*) TSTC_TRIPLE=${TSTC_TRIPLE%%-*}-apple-macosx11.0 ;; esac && export TSTC_TRIPLE && "
  } else {
    ""
  }
  // the module cache: objects by a hash of how they are compiled and of the
  // module's text, or of its key (made of its units' keys)
  let salt = path_bytes("tstc 1\n" + triple + compile + "\n" + cc + "\n")
  let todo = StringBuilder::new()
  let objs = StringBuilder::new()
  let mut nhit = 0
  let mut nmiss = 0
  let scheduled : Map[String, Bool] = Map::new()
  for mo in mods {
    let mut text : Array[Int]? = None
    let key = if mo.key != "" {
      let kb = c_buf_new()
      c_buf_str(kb, mo.key)
      let k = utf8_decode(c_bufs_hash(FixedArray::from_array([kb]), salt))
      c_buf_free(kb)
      "u" + k
    } else {
      let m = (mo.make)()
      text = Some(m)
      utf8_decode(c_bufs_hash(FixedArray::from_array(m), salt))
    }
    let base = cache_dir + "/" + key
    if scheduled.contains(base) {
      // a module identical to an earlier one: compiled and linked once
      match text {
        Some(m) => free_module(m)
        None => ()
      }
      continue
    }
    scheduled.set(base, true)
    if use_cache && c_file_exists(path_bytes(base + ".o")) != 0 {
      c_touch(path_bytes(base + ".o"))
      nhit += 1
    } else {
      let m = match text {
        Some(m) => m
        None => {
          let m = (mo.make)()
          text = Some(m)
          m
        }
      }
      let tmp = base + "." + tag
      if c_bufs_write(FixedArray::from_array(m), path_bytes(tmp + ".ll")) == 0 {
        die("cannot write " + tmp + ".ll")
      }
      todo.write_string(tmp + "\n")
      nmiss += 1
    }
    match text {
      Some(m) => free_module(m)
      None => ()
    }
    objs.write_string(" '" + base + ".o'")
  }
  // (the constants' store stays while builds use it)
  for b in 0..<data_modules {
    c_touch(path_bytes(consts_path(b)))
  }
  let lst = out_path + ".modules"
  if !write_file(lst, todo.to_string()) {
    die("cannot write " + lst)
  }
  let t2b = now_ms()
  if nmiss > 0 {
    let cmd = triple + "xargs -P " + jobs.to_string() + " -I{} " + compile + " < '" + lst + "'"
    if system(cmd) != 0 {
      die("the C compiler failed: " + cmd)
    }
  }
  let t3 = now_ms()
  let cmd = cc + " -o '" + out_path + "'" + objs.to_string() + " '" + rt_dir +
    "/libtstcrt.a' -lm -lpthread -Wl,-export_dynamic"
  if system(cmd) != 0 {
    die("the link failed: " + cmd)
  }
  let t4 = now_ms()
  run_eval_checks(out_path)
  if use_cache {
    write_stamp(stamp_path, stamp_head, rt_dir + "/libtstcrt.a")
  }
  // what no build used for a day goes
  let _ = system("find '" + cache_dir + "' -type f -mmin +1440 -delete")
  err(
    "tstc: modules hashed \{t2b - t2} ms (\{nhit} cached, \{nmiss} compiled), native code \{t3 - t2b} ms, link \{t4 - t3} ms\n",
  )
}

// the relations of check.mbt the program evaluates: the build fails (and
// its output is removed) when one does not hold
fn run_eval_checks(exe : String) -> Unit {
  if eval_checks.is_empty() {
    return
  }
  let outf = exe + ".checks"
  // (a name without a directory is run from here, not looked up in PATH)
  let run = if exe.contains("/") { exe } else { "./" + exe }
  let r = system("'" + run + "' check > '" + outf + "'")
  let text = read_file(outf).unwrap_or("")
  let _ = system("rm -f '" + outf + "'")
  let values : Map[String, String] = Map::new()
  for line in text.split("\n") {
    let l = line.to_string()
    match l.find(" = ") {
      Some(i) =>
        values.set(
          l.unsafe_substring(start=0, end=i),
          l.unsafe_substring(start=i + 3, end=l.length()),
        )
      None => ()
    }
  }
  let failed : Array[String] = []
  for c in eval_checks {
    match values.get(aliases[c.0].name) {
      Some("1") => ()
      Some(_) => failed.push(c.1)
      None => if r == 0 { failed.push(c.1 + " (not evaluated)") }
    }
  }
  if checks_warn.val {
    for f in failed {
      err("tstc: warning: " + f + "\n")
    }
    if r != 0 {
      err("tstc: warning: evaluating the program's type checks failed\n")
    }
    return
  }
  if r != 0 || !failed.is_empty() {
    let _ = system("rm -f '" + exe + "'")
    if r != 0 && failed.is_empty() {
      die("tstc: evaluating the program's type checks failed (\{exe} check)")
    }
    die(failed.join("\n"))
  }
}

// the stamp of a build: the head (compiler, arguments), then the input
// files with hashes of their contents
fn write_stamp(path : String, head : String, runtime : String) -> Unit {
  let sb = StringBuilder::new()
  sb.write_string(head + "\n")
  let files : Array[String] = [runtime]
  modules.each(fn(p, _m) { if p != "<prelude>" { files.push(p) } })
  for f in files {
    sb.write_string(f + "\t" + utf8_decode(c_file_hash(path_bytes(f))) + "\n")
  }
  let _ = write_file(path, sb.to_string())
}

fn stamp_valid(path : String, head : String) -> Bool {
  let text = match read_file(path) {
    Some(t) => t
    None => return false
  }
  let lines = text.split("\n").map(fn(l) { l.to_string() }).collect()
  if lines.length() < 2 || lines[0] != head {
    return false
  }
  for k in 1..<lines.length() {
    let l = lines[k]
    if l == "" {
      continue
    }
    match l.find("\t") {
      Some(i) => {
        let f = l.unsafe_substring(start=0, end=i)
        let h = l.unsafe_substring(start=i + 1, end=l.length())
        if utf8_decode(c_file_hash(path_bytes(f))) != h {
          return false
        }
      }
      None => return false
    }
  }
  true
}

// the hex hash of a file's contents ("" when it cannot be read)
#borrow(path)
extern "c" fn c_file_hash(path : Bytes) -> Bytes = "tstc_file_hash"
