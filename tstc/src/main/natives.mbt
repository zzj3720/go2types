// Aliases implemented by the runtime: a doc comment `@native <name>` binds an
// alias to the runtime's implementation <name>. TypeScript's intrinsic string
// types (the prelude) always are; the natives of a library (tstst's lib/pure:
// integers, strings, floats, the store of cells, maps, processes) only while
// its files are the versions they were checked against (accel.mbt).
// A native's id is its index in all_natives.

let native_names : Array[String] = [
  "uppercase", "lowercase", "capitalize", "uncapitalize", "indexok", "subst", "strip", "iface",
]

// what lib/pure's tags can name

let lib_native_names : Array[String] = [
  "iadd", "isub", "imul", "idiv", "irem", "iand", "ior", "ixor", "iandnot", "ishl",
  "ishr", "iushr", "ineg", "inot", "ieq", "ine", "ilt", "ile", "igt", "ige", "iult",
  "iule", "iugt", "iuge", "iwrap", "i2f", "u2f", "f2i", "f2u", "fadd", "fsub", "fmul",
  "fdiv", "feq", "flt", "fle", "fneg", "fne", "slen", "sat", "sslice", "scat", "seq",
  "scmp", "slt", "runestr", "decoderune", "vnew", "vget", "pmap_empty", "hget", "hset",
  "halloc", "panic", "tset", "tget", "itoa", "bnot", "geq", "gne", "udiv", "urem",
  "f2bits", "bits2f", "fround32", "uitoa", "ffloor", "fsqrt", "isnan", "ftoa",
  "sappend", "scopy", "salloc", "hinit", "sidx", "reslice", "aslice", "bytes2s",
  "s2bytes", "runes2sl", "s2runesl", "srange", "snext", "sindexbyte",
  "sindex", "scountbyte", "sswap", "ptrstr", "sdata", "f32bits", "bits2f32", "sclear",
  "padd", "hcopy", "hloadt", "hstoret", "shash128", "shash64", "write_out", "fork",
  "wait", "exit", "crash_note", "nilchk", "ta1", "ta2", "bytestr", "bstr", "bappend", "clock_ms",
  "rterr", "rtok", "hgetf", "hsetf",
  "hgets", "hsets", "pmap_get", "pmap_put", "pmap_del", "pmap_len", "pmap_keys", "pmap_step",
  "cell_pmap_get", "cell_pmap_put", "cell_pmap_del", "cell_pmap_len", "cell_pmap_keys", "cell_pmap_step",
  "sappendv",
]


// What the compiler knows of each native's result and effects: the
// runtime's own contract, not rules about the programs using them.
//   shape (shape.mbt): 0 a simple value whatever the arguments (integers,
//   strings, booleans, an opaque store or map, tuples of those), 1 made of
//   its arguments (simple when they are), 2 also a value loaded from the
//   store (simple when the store declares @store-simple and the arguments
//   are), 3 anything
//   effects (opt.mbt): it reads or writes a store or the process, so calls
//   reaching it are not memoized

// results made of the arguments
let args_natives : Array[String] = [
  "tget", "tset", "vnew", "vget", "ta1", "ta2", "nilchk", "reslice", "aslice", "sdata", "sappend", "sappendv",
  "pmap_get", "pmap_keys", "pmap_step",
]

// results loaded from the store
let load_natives : Array[String] = [
  "hget", "hgetf", "hgets", "hloadt", "cell_pmap_get", "cell_pmap_keys", "cell_pmap_step",
]

// natives that read or write a store or the process
let effect_natives : Array[String] = [
  "hget", "hset", "hgetf", "hsetf", "hgets", "hsets", "halloc", "hinit", "hcopy", "hloadt", "hstoret", "salloc", "sappend", "sappendv", "scopy", "sclear",
  "sswap", "bytes2s", "ptrstr", "s2bytes", "runes2sl", "s2runesl", "srange", "snext", "bstr", "bappend",
  "write_out", "fork", "wait", "exit", "crash_note", "clock_ms", "cell_pmap_get", "cell_pmap_put",
  "cell_pmap_del", "cell_pmap_len", "cell_pmap_keys", "cell_pmap_step",
]

let all_natives : Array[String] = native_names + lib_native_names

fn native_name(id : Int) -> String {
  all_natives[id]
}

// a native of a library (not one of TypeScript's intrinsics)
fn native_is_lib(id : Int) -> Bool {
  id >= native_names.length()
}

fn native_shape_kind(id : Int) -> Int {
  if !native_is_lib(id) {
    return 3
  }
  let n = native_name(id)
  if load_natives.contains(n) {
    2
  } else if args_natives.contains(n) {
    1
  } else {
    0
  }
}

// the shape of a native's result, from those of its arguments
fn native_shape(id : Int, args : Array[Int]) -> Int {
  let k = native_shape_kind(id)
  if k == 3 {
    return 2
  }
  if k == 0 {
    return 1
  }
  let mut s = 1
  for x in args {
    if x > s {
      s = x
    }
  }
  if k == 2 && !store_simple() {
    2
  } else {
    s
  }
}

fn native_has_effects(id : Int) -> Bool {
  id >= 0 && effect_natives.contains(native_name(id))
}

// natives returning two results as a pair (gen.mbt; rt: PAIR)
let pair_natives : Array[String] = [
  "halloc", "salloc", "sappend", "sappendv", "scopy", "s2bytes", "s2runesl", "ta2", "srange", "decoderune",
  "shash128", "clock_ms", "pmap_get", "cell_pmap_get",
]

fn native_returns_pair(id : Int) -> Bool {
  pair_natives.contains(native_name(id))
}

// the name of the runtime function implementing native id
fn native_symbol(id : Int) -> String {
  "n_" + native_name(id)
}

// the name in a doc comment's @native tag
fn native_tag(doc : String) -> String? {
  match doc.find("@native ") {
    None => None
    Some(i) => {
      let rest = doc.unsafe_substring(start=i + 8, end=doc.length())
      let sb = StringBuilder::new()
      for ch in rest {
        if (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') || ch == '_' {
          sb.write_char(ch)
        } else {
          break
        }
      }
      Some(sb.to_string())
    }
  }
}

fn native_id_of_name(n : String) -> Int {
  for j in 0..<all_natives.length() {
    if all_natives[j] == n {
      return j
    }
  }
  -1
}

// the native an alias's tag names (-1: none, or one the runtime does not
// have; accel.mbt reports those of libraries and may still unbind them)
fn native_id_of_doc(doc : String, _name : String) -> Int {
  match native_tag(doc) {
    None => -1
    Some(n) => native_id_of_name(n)
  }
}
