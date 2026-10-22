// Failures caught: an alias whose doc comment has `@catch H` evaluates to
// H<M, S> when a failure (a native's Panic<M>, which TypeScript makes never)
// happens while it is evaluated: M is the message, S the current version of
// the program's store (when H takes two parameters). The alias runs under
// tstc_try (rt/try.c). In TypeScript a failure is never: H does not change
// what the alias means there, it is how a runtime with failures continues.
// (tstst's go2types tags the bodies of Go functions with deferred calls, so
// that Go runtime errors are panics they recover.)

// the handler of each alias that has one
let catch_of : Map[Int, Int] = Map::new()

fn catch_handler_name(doc : String) -> String? {
  match doc.find("@catch ") {
    None => None
    Some(i) => {
      let sb = StringBuilder::new()
      for ch in doc.unsafe_substring(start=i + 7, end=doc.length()) {
        if (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '_' || ch == '$' {
          sb.write_char(ch)
        } else {
          break
        }
      }
      Some(sb.to_string())
    }
  }
}

// finds the handlers (entries of the program: the runtime calls them)
fn find_catches(entries : Array[Int]) -> Unit {
  for idx in 0..<aliases.length() {
    let a = aliases[idx]
    match catch_handler_name(a.doc) {
      None => ()
      Some(h) => {
        let m = match modules.get(a.file) {
          Some(m) => m
          None => die("\{a.name}: no module for @catch")
        }
        let hi = match m.locals.get(h) {
          Some(k) => k
          None =>
            match m.imports.get(h) {
              Some(k) => k
              None => die("\{a.name}: @catch names '\{h}', which is not defined")
            }
        }
        let n = aliases[hi].nparams
        if n < 1 || n > 2 {
          die("\{a.name}: the handler \{h} of @catch takes \{n} parameters (1 or 2: the message, the store)")
        }
        catch_of.set(idx, hi)
        if !entries.contains(hi) {
          entries.push(hi)
        }
      }
    }
  }
}
