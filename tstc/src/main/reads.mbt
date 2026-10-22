// The slots of the frame a piece of code can read: what a register must be
// stored for before the frame is passed to the code (as a function of the
// frame, or to the runtime with the parts of a descriptor).
//
// Only the slots bound outside the code count (its free slots): what the
// code binds itself it writes before reading, and a slot held in a register
// where the frame is passed is bound outside. So a conditional's set is about
// the values live across it, small even where chains of thousands of
// conditionals nest (a set of every slot read below would grow with the
// chain). A conditional's set is computed once, sorted.

let cond_free_memo : Map[Int, Array[Int]] = Map::new()

// while aliases are compiled (their code changes later: CSE keeps a
// conditional's id), the sets are not kept
let cond_free_nomemo : Ref[Bool] = Ref::new(false)

fn cond_free(cd : Cond) -> Array[Int] {
  match cond_free_memo.get(cd.id) {
    Some(b) => if !cond_free_nomemo.val { return b }
    None => ()
  }
  let acc : Map[Int, Bool] = Map::new()
  free_into(cd.check, acc)
  free_into(cd.ext, acc)
  match cd.pat {
    Some(p) => pat_free_into(p, acc)
    None => ()
  }
  free_into(cd.t, acc)
  free_into(cd.f, acc)
  for s in cd.infer_slots {
    acc.remove(s)
  }
  let b = acc.keys().collect()
  b.sort()
  if !cond_free_nomemo.val {
    cond_free_memo.set(cd.id, b)
  }
  b
}

// the free slots of code
fn code_free(c : Code) -> Map[Int, Bool] {
  let acc : Map[Int, Bool] = Map::new()
  free_into(c, acc)
  acc
}

fn free_all(cs : Array[Code], acc : Map[Int, Bool]) -> Unit {
  for c in cs {
    free_into(c, acc)
  }
}

fn free_into(c : Code, acc : Map[Int, Bool]) -> Unit {
  match c {
    CTy(_) | CUniqueSym(_) => ()
    CSlot(i) => acc.set(i, true)
    CCall(_, args) | CNative(_, _, args) => free_all(args, acc)
    CUnion(cs) | CInter(cs) => free_all(cs, acc)
    CCond(cd) => for s in cond_free(cd) { acc.set(s, true) }
    CTuple(elems, _) => for e in elems { free_into(e.code, acc) }
    CArray(x, _) | CKeyof(x) => free_into(x, acc)
    CObj(oc) => {
      for p in oc.props {
        free_into(p.1, acc)
      }
      for ix in oc.index {
        free_into(ix.0, acc)
        free_into(ix.1, acc)
      }
      for cl in oc.calls {
        for p in cl.0 {
          free_into(p.code, acc)
        }
        free_into(cl.1, acc)
      }
    }
    CMapped(mc) => {
      // the key slot is bound by the mapped type: what reads it inside is
      // not free (a fresh set, then the rest)
      let inner : Map[Int, Bool] = Map::new()
      for x in [mc.homo, mc.mods, mc.as_clause] {
        match x {
          Some(y) => free_into(y, inner)
          None => ()
        }
      }
      free_into(mc.body, inner)
      inner.remove(mc.slot)
      inner.each(fn(k, _v) { acc.set(k, true) })
      free_into(mc.constraint, acc)
    }
    CIndex(o, k) => {
      free_into(o, acc)
      free_into(k, acc)
    }
    CTpl(_, cs) => free_all(cs, acc)
    CFn(params, ret, _) => {
      for p in params {
        free_into(p.code, acc)
      }
      free_into(ret, acc)
    }
    CGenericFn(slots, body) => {
      let inner : Map[Int, Bool] = Map::new()
      free_into(body, inner)
      for s in slots {
        inner.remove(s)
      }
      inner.each(fn(k, _v) { acc.set(k, true) })
    }
    CLet(s, v, body) => {
      // the slot is the let's own
      let inner : Map[Int, Bool] = Map::new()
      free_into(body, inner)
      inner.remove(s)
      inner.each(fn(k, _v) { acc.set(k, true) })
      free_into(v, acc)
    }
  }
}

fn pat_free_into(p : Pat, acc : Map[Int, Bool]) -> Unit {
  match p {
    PCode(c) => free_into(c, acc)
    PInfer(_, cons) =>
      match cons {
        Some(c) => free_into(c, acc)
        None => ()
      }
    PTuple(elems, _) => for e in elems { pat_free_into(e.pat, acc) }
    PArray(sub, _) => pat_free_into(sub, acc)
    PObj(props) => for pp in props { pat_free_into(pp.pat, acc) }
    PTpl(_, pats) => for x in pats { pat_free_into(x, acc) }
    PFn(params, ret) => {
      for x in params {
        pat_free_into(x.pat, acc)
      }
      pat_free_into(ret, acc)
    }
    PUnion(pats) => for x in pats { pat_free_into(x, acc) }
    PVal(c, infs) => {
      free_into(c, acc)
      for x in infs {
        pat_free_into(x.pat, acc)
      }
    }
  }
}
