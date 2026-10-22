// Operations on a store's cell, fused (compile.mbt: mk_call). A library
// works on the value in a cell by reading it, using it and writing it back:
//
//   hset<S, P, pmput<hget<S, P>, K, V>>     the map value in cell P, with K set
//   pmget<hget<S, P>, K>                    the entry of K in the map in P
//   pmstep<hget<S, P>, Ks, I, N>            a step of a range over the map in P
//
// Natively the store's values are updated in place, and a value read out of a
// cell may be kept anywhere, so hget freezes what it reads (a map can no
// longer change in place, rt/heap.c) and pmput copies what it changes. Fused,
// these work on the cell itself: an update changes the value the cell owns in
// place (copying it the first time), a read that only looks into the value
// (it does not keep or return it) leaves it unfrozen. The fused natives
// (cell_<name>) are the runtime's; they apply when the natives they combine
// are bound (accel.mbt).

// natives that only look into their first argument
let borrow_natives : Array[String] = ["pmap_get", "pmap_len", "pmap_keys", "pmap_step"]

// natives whose result is their first argument, changed
let update_natives : Array[String] = ["pmap_put", "pmap_del"]

// how many calls were fused (--accel-report)
let fused_count : Ref[Int] = Ref::new(0)

// the hidden alias of each fused native (by name)
let fused_alias : Map[String, Int] = Map::new()

fn fused_params(name : String) -> Int {
  match name {
    "pmap_get" | "pmap_del" => 3
    "pmap_put" => 4
    "pmap_step" => 5
    _ => 2
  }
}

// after the natives are bound: the fused natives whose parts are
fn add_fused_natives() -> Unit {
  let bound : Map[String, Int] = Map::new()
  for i in 0..<aliases.length() {
    let a = aliases[i]
    if a.native >= 0 {
      bound.set(native_name(a.native), i)
    }
  }
  if !bound.contains("hget") || !bound.contains("hset") {
    return
  }
  for n in borrow_natives + update_natives {
    match bound.get(n) {
      None => ()
      Some(src) => {
        let f = "cell_" + n
        let id = native_id_of_name(f)
        if id < 0 {
          continue
        }
        let np = fused_params(n)
        let idx = aliases.length()
        aliases.push({
          name: "$" + f,
          doc: "",
          file: aliases[src].file,
          nparams: np,
          param_names: Array::makei(np, fn(k) { "P\{k}" }),
          defaults: [],
          body: CTy(TAny),
          frame: np,
          native: id,
          iface_members: [],
          iface_heritage: [],
          decl_params: [],
          decl_body: None,
          is_interface: false,
        })
        fused_alias.set(n, idx)
      }
    }
  }
}

fn same_operand(a : Code, b : Code) -> Bool {
  match (a, b) {
    (CSlot(x), CSlot(y)) => x == y
    _ => false
  }
}

// the store and cell of `hget<S, P>`
fn hget_parts(c : Code) -> (Code, Code)? {
  match c {
    CNative(_, id, args) if args.length() == 2 && native_name(id) == "hget" => Some((args[0], args[1]))
    _ => None
  }
}

fn fused_call(n : String, args : Array[Code]) -> Code? {
  match fused_alias.get(n) {
    Some(fi) => {
      fused_count.val += 1
      Some(CNative(fi, aliases[fi].native, args))
    }
    None => None
  }
}

// a call of a native, fused with what its arguments do to a cell
fn native_call_code(idx : Int, id : Int, args : Array[Code]) -> Code {
  let n = native_name(id)
  if borrow_natives.contains(n) && args.length() >= 1 {
    match hget_parts(args[0]) {
      Some((s, p)) =>
        match fused_call(n, [s, p] + args[1:].to_array()) {
          Some(c) => return c
          None => ()
        }
      None => ()
    }
  }
  if n == "hset" && args.length() == 3 {
    match args[2] {
      CNative(_, uid, uargs) if update_natives.contains(native_name(uid)) && uargs.length() >= 1 =>
        match hget_parts(uargs[0]) {
          Some((s, p)) if same_operand(s, args[0]) && same_operand(p, args[1]) =>
            match fused_call(native_name(uid), [s, p] + uargs[1:].to_array()) {
              Some(c) => return c
              None => ()
            }
          _ => ()
        }
      _ => ()
    }
  }
  CNative(idx, id, args)
}
