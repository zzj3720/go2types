// Stores: what a library declares about a mutable store of cells it defines,
// with tags in the doc comment of the alias that makes one (lib/pure's hinit):
//
//   @store cells          the alias makes a store of cells; the runtime may
//                         implement it as an array updated in place
//   @store-ref bigint     references to cells are their indices
//   @store-linear         every version of a store is used at most once (a
//                         write makes the next): updates in place are not seen
//   @store-scalar T...    a cell allocated with a value of one of these types
//                         (bigint number string boolean null undefined) never
//                         holds a reference
//   @store-reuse          which cells an allocation gets is not observable:
//                         cells nothing refers to may be freed and reused
//   @store-simple         cells hold simple values (no unions, any or
//                         unknown, nor tuples or objects with them): what is
//                         loaded needs no general matching (shape.mbt)
//
// The runtime follows the declaration (tstc_store, read by rt/cellgc.c) rather
// than rules of its own: without @store-reuse cells are never freed, and only
// cells of declared scalar types are known to hold no reference. The natives
// implementing a store in place need it declared linear (accel.mbt).

struct StoreDecl {
  alias : String
  mut ref_int : Bool
  mut linear : Bool
  mut reuse : Bool
  mut simple : Bool
  mut scalar : Int // bits: STORE_S_* of rt/cellgc.c
}

let store_decl : Ref[StoreDecl?] = Ref::new(None)

// the scalar types a declaration can name, and their bits (rt/cellgc.c)
let store_scalar_names : Array[(String, Int)] = [
  ("bigint", 1),
  ("number", 2),
  ("string", 4),
  ("boolean", 8),
  ("null", 16),
  ("undefined", 32),
]

// the tags of a doc comment starting with @store: (tag, its words), one line
// each
fn store_tags(doc : String) -> Array[(String, Array[String])] {
  let out : Array[(String, Array[String])] = []
  for line in doc.split("\n") {
    let l = line.to_string()
    match l.find("@store") {
      None => ()
      Some(i) => {
        let rest = l.unsafe_substring(start=i + 1, end=l.length())
        let words : Array[String] = []
        for w in rest.split(" ") {
          let w = w.to_string()
          if w == "*/" || w == "*" {
            break
          }
          if w != "" {
            words.push(w)
          }
        }
        if words.length() > 0 {
          let tag = words[0]
          out.push((tag, words[1:].to_array()))
        }
      }
    }
  }
  out
}

fn parse_store_decl(name : String, doc : String) -> StoreDecl? {
  let tags = store_tags(doc)
  if tags.is_empty() {
    return None
  }
  let d = { alias: name, ref_int: false, linear: false, reuse: false, simple: false, scalar: 0 }
  let mut kind_ok = false
  for t in tags {
    let bad = fn() { die("\{name}: bad store declaration '@" + t.0 + " " + t.1.join(" ") + "'") }
    match t.0 {
      "store" => if t.1 == ["cells"] { kind_ok = true } else { bad() }
      "store-ref" => if t.1 == ["bigint"] { d.ref_int = true } else { bad() }
      "store-linear" => if t.1.is_empty() { d.linear = true } else { bad() }
      "store-reuse" => if t.1.is_empty() { d.reuse = true } else { bad() }
      "store-simple" => if t.1.is_empty() { d.simple = true } else { bad() }
      "store-scalar" =>
        for w in t.1 {
          let mut bit = 0
          for row in store_scalar_names {
            if row.0 == w {
              bit = row.1
            }
          }
          if bit == 0 {
            bad()
          }
          d.scalar = d.scalar | bit
        }
      _ => bad()
    }
  }
  if !kind_ok {
    die("\{name}: a store declaration needs '@store cells'")
  }
  Some(d)
}

// the program's store declaration (one at most)
fn find_store_decl() -> Unit {
  for a in aliases {
    if a.doc.contains("@store") {
      match parse_store_decl(a.name, a.doc) {
        Some(d) =>
          match store_decl.val {
            Some(o) => die("two store declarations: \{o.alias} and \{d.alias}")
            None => store_decl.val = Some(d)
          }
        None => ()
      }
    }
  }
}

// whether natives may implement the store in place
fn store_in_place() -> Bool {
  match store_decl.val {
    Some(d) => d.linear && d.ref_int
    None => false
  }
}

// whether what is loaded from the store is a simple value
fn store_simple() -> Bool {
  match store_decl.val {
    Some(d) => d.simple
    None => false
  }
}

// the runtime's copy: { scalar types, flags (1 declared, 2 linear, 4 reuse) }
fn store_global() -> String {
  match store_decl.val {
    None => "@tstc_store = constant { i64, i64 } { i64 0, i64 0 }\n"
    Some(d) => {
      let flags = 1 + (if d.linear { 2 } else { 0 }) + (if d.reuse { 4 } else { 0 })
      "@tstc_store = constant { i64, i64 } { i64 \{d.scalar}, i64 \{flags} }\n"
    }
  }
}
