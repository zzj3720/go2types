// Lexer and parser for the type-level subset of TypeScript.

enum Tok {
  TkEOF
  TkIdent
  TkStr
  TkNum
  TkBigInt
  TkPunct
  TkTplFull // `...` without substitutions; text = cooked
  TkTplHead // `...${
}

struct Lexer {
  src : String
  file : String
  mut pos : Int
  mut tok : Tok
  mut start : Int
  mut text : String
  mut num : Double
  mut nl_before : Bool
  mut doc : String // last /** */ comment seen before the current token
}

fn Lexer::new(src : String, file : String) -> Lexer {
  let l = {
    src,
    file,
    pos: 0,
    tok: TkEOF,
    start: 0,
    text: "",
    num: 0.0,
    nl_before: false,
    doc: "",
  }
  l.next()
  l
}

fn Lexer::line_col(self : Lexer, pos : Int) -> String {
  let mut line = 1
  let mut col = 1
  for i in 0..<pos {
    if i >= self.src.length() {
      break
    }
    if self.src.at(i) == '\n' {
      line += 1
      col = 1
    } else {
      col += 1
    }
  }
  "\{self.file}:\{line}:\{col}"
}

fn[T] Lexer::fail(self : Lexer, msg : String) -> T {
  die(self.line_col(self.start) + ": " + msg + " (at '" + self.text + "')")
}

// an error at an earlier position (tsc and tsgo report these too)
fn[T] Lexer::fail_at(self : Lexer, pos : Int, msg : String) -> T {
  die(self.line_col(pos) + ": " + msg)
}

fn is_id_start(c : Int) -> Bool {
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || c == '$' ||
  c > 127
}

fn is_id_part(c : Int) -> Bool {
  is_id_start(c) || (c >= '0' && c <= '9')
}

fn Lexer::peek_char(self : Lexer, off : Int) -> Int {
  let p = self.pos + off
  if p < self.src.length() {
    self.src.at(p)
  } else {
    -1
  }
}

fn Lexer::skip_trivia(self : Lexer) -> Unit {
  self.nl_before = false
  let n = self.src.length()
  while self.pos < n {
    let c = self.src.at(self.pos)
    if c == '\n' {
      self.nl_before = true
      self.pos += 1
    } else if c == ' ' || c == '\t' || c == '\r' || c == 0xFEFF {
      self.pos += 1
    } else if c == '/' && self.peek_char(1) == '/' {
      while self.pos < n && self.src.at(self.pos) != '\n' {
        self.pos += 1
      }
    } else if c == '/' && self.peek_char(1) == '*' {
      let is_doc = self.peek_char(2) == '*'
      let s = self.pos
      self.pos += 2
      while self.pos < n &&
            !(self.src.at(self.pos) == '*' && self.peek_char(1) == '/') {
        if self.src.at(self.pos) == '\n' {
          self.nl_before = true
        }
        self.pos += 1
      }
      self.pos += 2
      if is_doc {
        self.doc = self.src.unsafe_substring(start=s, end=self.pos)
      }
    } else {
      break
    }
  }
}

fn Lexer::read_escape(self : Lexer, sb : StringBuilder) -> Unit {
  // at backslash
  self.pos += 1
  let c = self.src.at(self.pos)
  self.pos += 1
  match c {
    'n' => sb.write_char('\n')
    't' => sb.write_char('\t')
    'r' => sb.write_char('\r')
    'b' => sb.write_char('\u{8}')
    'f' => sb.write_char('\u{c}')
    'v' => sb.write_char('\u{b}')
    '0' => sb.write_char('\u{0}')
    'x' => {
      let h = self.src.unsafe_substring(start=self.pos, end=self.pos + 2)
      self.pos += 2
      sb.write_char(Int::unsafe_to_char(parse_hex(h)))
    }
    'u' =>
      if self.src.at(self.pos) == '{' {
        let s = self.pos + 1
        while self.src.at(self.pos) != '}' {
          self.pos += 1
        }
        let h = self.src.unsafe_substring(start=s, end=self.pos)
        self.pos += 1
        sb.write_char(Int::unsafe_to_char(parse_hex(h)))
      } else {
        let h = self.src.unsafe_substring(start=self.pos, end=self.pos + 4)
        self.pos += 4
        sb.write_char(Int::unsafe_to_char(parse_hex(h)))
      }
    '\r' => if self.peek_char(0) == '\n' { self.pos += 1 }
    '\n' => ()
    _ => sb.write_char(Int::unsafe_to_char(c))
  }
}

fn parse_hex(s : String) -> Int {
  let mut v = 0
  for i in 0..<s.length() {
    let c = s.at(i)
    let d = if c >= '0' && c <= '9' {
      c - '0'
    } else if c >= 'a' && c <= 'f' {
      c - 'a' + 10
    } else if c >= 'A' && c <= 'F' {
      c - 'A' + 10
    } else {
      0
    }
    v = v * 16 + d
  }
  v
}

// Reads template characters up to `${` or the closing backtick.
// Returns true if it stopped at `${`.
fn Lexer::read_template_chunk(self : Lexer) -> Bool {
  let sb = StringBuilder::new()
  let n = self.src.length()
  while self.pos < n {
    let c = self.src.at(self.pos)
    if c == '`' {
      self.pos += 1
      self.text = sb.to_string()
      return false
    }
    if c == '$' && self.peek_char(1) == '{' {
      self.pos += 2
      self.text = sb.to_string()
      return true
    }
    if c == '\\' {
      self.read_escape(sb)
      continue
    }
    if c == '\r' {
      // normalize CRLF to LF in template text
      self.pos += 1
      if self.peek_char(0) == '\n' {
        self.pos += 1
      }
      sb.write_char('\n')
      continue
    }
    sb.write_char(Int::unsafe_to_char(c))
    self.pos += 1
  }
  self.fail("unterminated template")
}

fn Lexer::next(self : Lexer) -> Unit {
  self.doc = ""
  self.skip_trivia()
  self.start = self.pos
  let n = self.src.length()
  if self.pos >= n {
    self.tok = TkEOF
    self.text = ""
    return
  }
  let c = self.src.at(self.pos)
  if is_id_start(c) {
    let s = self.pos
    while self.pos < n && is_id_part(self.src.at(self.pos)) {
      self.pos += 1
    }
    self.tok = TkIdent
    self.text = self.src.unsafe_substring(start=s, end=self.pos)
    return
  }
  if (c >= '0' && c <= '9') || (c == '.' && self.peek_char(1) >= '0' && self.peek_char(1) <= '9') {
    self.read_number()
    return
  }
  if c == '"' || c == '\'' {
    let q = c
    self.pos += 1
    let sb = StringBuilder::new()
    while self.pos < n && self.src.at(self.pos) != q {
      if self.src.at(self.pos) == '\\' {
        self.read_escape(sb)
      } else {
        sb.write_char(Int::unsafe_to_char(self.src.at(self.pos)))
        self.pos += 1
      }
    }
    self.pos += 1
    self.tok = TkStr
    self.text = sb.to_string()
    return
  }
  if c == '`' {
    self.pos += 1
    let more = self.read_template_chunk()
    self.tok = if more { TkTplHead } else { TkTplFull }
    return
  }
  // punctuation (single-character tokens use interned strings)
  self.tok = TkPunct
  if c == '.' && self.peek_char(1) == '.' && self.peek_char(2) == '.' {
    self.pos += 3
    self.text = "..."
    return
  }
  if c == '=' && self.peek_char(1) == '>' {
    self.pos += 2
    self.text = "=>"
    return
  }
  if c == '?' && self.peek_char(1) == '.' {
    self.pos += 2
    self.text = "?."
    return
  }
  self.pos += 1
  self.text = if c < 128 { punct_strings[c] } else {
    self.src.unsafe_substring(start=self.pos - 1, end=self.pos)
  }
}

let punct_strings : Array[String] = Array::makei(128, fn(i) {
  String::make(1, Int::unsafe_to_char(i))
})

fn Lexer::read_number(self : Lexer) -> Unit {
  let n = self.src.length()
  let s = self.pos
  let c1 = self.peek_char(1)
  if self.src.at(self.pos) == '0' &&
    (c1 == 'x' || c1 == 'X' || c1 == 'b' || c1 == 'B' || c1 == 'o' || c1 == 'O') {
    let base = if c1 == 'x' || c1 == 'X' {
      16
    } else if c1 == 'b' || c1 == 'B' {
      2
    } else {
      8
    }
    self.pos += 2
    let mut v = 0.0
    while self.pos < n {
      let c = self.src.at(self.pos)
      if c == '_' {
        self.pos += 1
        continue
      }
      let d = if c >= '0' && c <= '9' {
        c - '0'
      } else if c >= 'a' && c <= 'f' {
        c - 'a' + 10
      } else if c >= 'A' && c <= 'F' {
        c - 'A' + 10
      } else {
        99
      }
      if d >= base {
        break
      }
      v = v * base.to_double() + d.to_double()
      self.pos += 1
    }
    if self.pos < n && self.src.at(self.pos) == 'n' {
      self.pos += 1
      self.tok = TkBigInt
      self.text = self.src.unsafe_substring(start=s, end=self.pos - 1)
      self.num = v
      return
    }
    self.tok = TkNum
    self.num = v
    self.text = self.src.unsafe_substring(start=s, end=self.pos)
    return
  }
  // plain digits (most numbers): their text without a builder
  let mut e = self.pos
  while e < n && self.src.at(e) >= '0' && self.src.at(e) <= '9' {
    e += 1
  }
  if e > self.pos && !(e < n && (self.src.at(e) == '.' || self.src.at(e) == '_' || self.src.at(e) == 'e' || self.src.at(e) == 'E')) {
    let t = if e == self.pos + 1 {
      punct_strings[self.src.at(self.pos)]
    } else {
      self.src.unsafe_substring(start=self.pos, end=e)
    }
    self.pos = e
    if self.pos < n && self.src.at(self.pos) == 'n' {
      self.pos += 1
      self.tok = TkBigInt
      self.text = t
      return
    }
    self.tok = TkNum
    self.text = t
    self.num = match parse_js_number(t) {
      Some(v) => v
      None => self.fail("bad number")
    }
    return
  }
  let sb = StringBuilder::new()
  while self.pos < n {
    let c = self.src.at(self.pos)
    if (c >= '0' && c <= '9') || c == '.' {
      sb.write_char(Int::unsafe_to_char(c))
      self.pos += 1
    } else if c == '_' {
      self.pos += 1
    } else if c == 'e' || c == 'E' {
      sb.write_char('e')
      self.pos += 1
      if self.src.at(self.pos) == '+' || self.src.at(self.pos) == '-' {
        sb.write_char(Int::unsafe_to_char(self.src.at(self.pos)))
        self.pos += 1
      }
    } else {
      break
    }
  }
  let t = sb.to_string()
  if self.pos < n && self.src.at(self.pos) == 'n' {
    self.pos += 1
    self.tok = TkBigInt
    self.text = t
    return
  }
  self.tok = TkNum
  self.text = t
  self.num = match parse_js_number(if t.has_prefix(".") { "0" + t } else { t }) {
    Some(v) => v
    None => self.fail("bad number")
  }
}

// ---------------------------------------------------------------------------
// AST

enum TE {
  EKw(String) // any unknown never string number boolean bigint symbol object null undefined void
  EStr(String)
  ENum(Double)
  EBig(String)
  EBool(Bool)
  ERef(String, Array[String], Array[TE], Int) // name, qualified tail, args, pos
  EUnion(Array[TE])
  EInter(Array[TE])
  ECond(TE, TE, TE, TE)
  EInfer(String, TE?)
  ETuple(Array[TElem], Bool) // ro
  EArray(TE, Bool)
  EObj(Array[Member])
  EMapped(MappedE)
  EIndex(TE, TE)
  EKeyof(TE)
  ETpl(Array[String], Array[TE])
  EFn(Array[TParamE], Array[FParam], TE, Bool) // type params, params, ret, ctor
  ETypeofUnsupported(Int)
  EThis
  EUniqueSymbol(Int)
  // `T?` outside the end of a tuple element (JSDoc syntax: an error in a
  // TypeScript file)
  ENullable(TE, Int)
}

struct TElem {
  ty : TE
  kind : Int // K_REQ / K_OPT / K_REST
  name : String
}

enum Member {
  MProp(String, TE, Bool, Bool) // name, type, optional, ro
  MIndex(String, TE, TE, Bool) // key name, key type, value type, ro
  MCall(Array[TParamE], Array[FParam], TE, Bool)
}

struct MappedE {
  param : String
  constraint : TE
  as_clause : TE?
  body : TE?
  readonly_mod : Int // 0 none, 1 +, -1 -
  optional_mod : Int
}

struct FParam {
  name : String
  ty : TE
  optional : Bool
  rest : Bool
}

struct TParamE {
  name : String
  constraint : TE?
  default : TE?
}

enum Decl {
  DAlias(String, Array[TParamE], TE, String, Bool) // name, params, body, doc, exported
  DInterface(String, Array[TParamE], Array[TE], Array[Member], String, Bool)
  DImport(Array[(String, String)], String) // (imported, local), module
  DImportNs(String, String) // local ns, module
  DExportNames(Array[(String, String)], String?) // (local, exported), from
  DExportStar(String)
}

struct Parser {
  lx : Lexer
  // directly in the extends clause of a conditional type (TypeScript's
  // "disallow conditional types" context)
  mut in_extends : Bool
  // the type parse_postfix returned is an array or tuple type node (what
  // `readonly` may modify)
  mut arrtup : Bool
  // `unique symbol` types not (yet) the type of a readonly property
  // signature, the only place they may be in a type-level program
  uniq : Array[Int]
}

fn Parser::tok(self : Parser) -> Tok {
  self.lx.tok
}

fn Parser::at_kw(self : Parser, p : String) -> Bool {
  match self.lx.tok {
    TkPunct | TkIdent => self.lx.text == p
    _ => false
  }
}

fn Parser::is_punct(self : Parser, p : String) -> Bool {
  match self.lx.tok {
    TkPunct => self.lx.text == p
    _ => false
  }
}

fn Parser::is_ident(self : Parser) -> Bool {
  self.lx.tok is TkIdent
}

fn Parser::eat(self : Parser, p : String) -> Bool {
  if self.at_kw(p) {
    self.lx.next()
    true
  } else {
    false
  }
}

fn Parser::expect(self : Parser, p : String) -> Unit {
  if !self.eat(p) {
    self.lx.fail("expected '" + p + "'")
  }
}

fn Parser::ident(self : Parser) -> String {
  match self.lx.tok {
    TkIdent => {
      let t = self.lx.text
      self.lx.next()
      t
    }
    _ => self.lx.fail("expected identifier")
  }
}

// Saves and restores lexer state for lookahead.
struct LexState {
  pos : Int
  tok : Tok
  start : Int
  text : String
  num : Double
  nl : Bool
  doc : String
}

fn Parser::save(self : Parser) -> LexState {
  {
    pos: self.lx.pos,
    tok: self.lx.tok,
    start: self.lx.start,
    text: self.lx.text,
    num: self.lx.num,
    nl: self.lx.nl_before,
    doc: self.lx.doc,
  }
}

fn Parser::restore(self : Parser, s : LexState) -> Unit {
  self.lx.pos = s.pos
  self.lx.tok = s.tok
  self.lx.start = s.start
  self.lx.text = s.text
  self.lx.num = s.num
  self.lx.nl_before = s.nl
  self.lx.doc = s.doc
}

fn Parser::parse_type(self : Parser) -> TE {
  self.parse_type_ctx(false)
}

// no_cond: inside an `extends` clause of a conditional type
fn Parser::parse_type_ctx(self : Parser, no_cond : Bool) -> TE {
  let saved = self.in_extends
  self.in_extends = no_cond
  let t = self.parse_type_ctx_inner(no_cond)
  self.in_extends = saved
  t
}

fn Parser::parse_type_ctx_inner(self : Parser, no_cond : Bool) -> TE {
  if self.is_start_of_fn_type() {
    return self.parse_fn_type(false)
  }
  if self.at_kw("new") {
    let s = self.save()
    self.lx.next()
    if self.is_punct("(") || self.is_punct("<") {
      return self.parse_fn_type(true)
    }
    self.restore(s)
  }
  if self.at_kw("abstract") {
    let s = self.save()
    self.lx.next()
    if self.at_kw("new") {
      self.lx.next()
      return self.parse_fn_type(true)
    }
    self.restore(s)
  }
  let t = self.parse_union()
  if !no_cond && self.at_kw("extends") && !self.lx.nl_before {
    self.lx.next()
    let ext = self.parse_type_ctx(true)
    self.expect("?")
    let tt = self.parse_type()
    self.expect(":")
    let ff = self.parse_type()
    return ECond(t, ext, tt, ff)
  }
  t
}

fn Parser::is_start_of_fn_type(self : Parser) -> Bool {
  if self.is_punct("<") {
    return true
  }
  if !self.is_punct("(") {
    return false
  }
  let s = self.save()
  self.lx.next()
  let res = if self.is_punct(")") || self.is_punct("...") {
    true
  } else if self.skip_param_start() {
    if self.is_punct(":") || self.is_punct(",") || self.is_punct("?") ||
      self.is_punct("=") {
      true
    } else if self.is_punct(")") {
      self.lx.next()
      self.is_punct("=>")
    } else {
      false
    }
  } else {
    false
  }
  self.restore(s)
  res
}

fn Parser::skip_param_start(self : Parser) -> Bool {
  if self.is_ident() {
    self.lx.next()
    return true
  }
  if self.is_punct("{") || self.is_punct("[") {
    // destructuring pattern; skip balanced
    let mut depth = 0
    while true {
      if self.is_punct("{") || self.is_punct("[") {
        depth += 1
      } else if self.is_punct("}") || self.is_punct("]") {
        depth -= 1
        if depth == 0 {
          self.lx.next()
          return true
        }
      } else if self.tok() is TkEOF {
        return false
      }
      self.lx.next()
    }
  }
  false
}

// Names a type parameter (or an infer declaration) cannot have: tsc and tsgo
// report "Type parameter name cannot be ..." and the type that uses it
// becomes an error type (any), so a program relying on one would give a
// different result on them than here.
fn Parser::check_type_param_name(self : Parser, name : String) -> Unit {
  match name {
    "any" | "unknown" | "never" | "void" | "null" | "undefined" | "object" |
    "string" | "number" | "bigint" | "boolean" | "symbol" | "true" | "false" | "this" =>
      self.lx.fail("type parameter name cannot be '" + name + "'")
    _ => ()
  }
}

// kind: 0 a type alias or interface, 1 a signature (function or constructor
// type, call, construct or method signature)
fn Parser::parse_type_params_of(self : Parser, kind : Int) -> Array[TParamE] {
  let res : Array[TParamE] = []
  if !self.is_punct("<") {
    return res
  }
  let lt = self.lx.start
  self.lx.next()
  let mut seen_default = false
  while !self.is_punct(">") {
    while self.at_kw("const") || self.at_kw("in") || self.at_kw("out") {
      let s = self.save()
      let m = self.lx.text
      self.lx.next()
      if self.is_punct(",") || self.is_punct(">") || self.is_punct("=") ||
        self.at_kw("extends") {
        self.restore(s)
        break
      }
      if m == "const" && kind == 0 {
        self.lx.fail_at(
          s.start, "'const' modifier can only appear on a type parameter of a function, method or class",
        )
      }
      if m != "const" && kind == 1 {
        self.lx.fail_at(
          s.start, "'\{m}' modifier can only appear on a type parameter of a class, interface or type alias",
        )
      }
    }
    let pos = self.lx.start
    let name = self.ident()
    self.check_type_param_name(name)
    for p in res {
      if p.name == name {
        self.lx.fail_at(pos, "duplicate identifier '\{name}'")
      }
    }
    let constraint = if self.eat("extends") {
      Some(self.parse_type())
    } else {
      None
    }
    let default = if self.eat("=") { Some(self.parse_type()) } else { None }
    if default is Some(_) {
      seen_default = true
    } else if seen_default {
      self.lx.fail_at(pos, "required type parameters may not follow optional type parameters")
    }
    res.push({ name, constraint, default })
    if !self.eat(",") {
      break
    }
  }
  self.expect(">")
  if res.is_empty() {
    self.lx.fail_at(lt, "type parameter list cannot be empty")
  }
  res
}

fn Parser::parse_type_params(self : Parser) -> Array[TParamE] {
  self.parse_type_params_of(1)
}

fn Parser::parse_params(self : Parser) -> Array[FParam] {
  self.expect("(")
  let res : Array[FParam] = []
  let mut seen_opt = false
  let mut rest_at = -1
  while !self.is_punct(")") {
    let ppos = self.lx.start
    if rest_at >= 0 {
      self.lx.fail_at(rest_at, "a rest parameter must be last in a parameter list")
    }
    let rest = self.eat("...")
    let name = if self.is_ident() {
      self.ident()
    } else {
      // destructuring pattern
      if !self.skip_param_start() {
        self.lx.fail("parameter declaration expected")
      }
      "_"
    }
    if name != "_" {
      for p in res {
        if p.name == name {
          self.lx.fail_at(ppos, "duplicate identifier '\{name}'")
        }
      }
    }
    let optional = self.eat("?")
    if rest {
      rest_at = ppos
      if optional {
        self.lx.fail_at(ppos, "a rest parameter cannot be optional")
      }
    } else if optional {
      seen_opt = true
    } else if seen_opt {
      self.lx.fail_at(ppos, "a required parameter cannot follow an optional parameter")
    }
    // (noImplicitAny: a parameter without a type is an error)
    if !self.eat(":") {
      self.lx.fail_at(ppos, "parameter '\{name}' implicitly has an 'any' type")
    }
    let ty = self.parse_type()
    if self.is_punct("=") {
      self.lx.fail(
        "a parameter initializer is only allowed in a function or constructor implementation",
      )
    }
    res.push({ name, ty, optional, rest })
    if !self.eat(",") {
      break
    }
    if rest && self.is_punct(")") {
      self.lx.fail("a rest parameter or binding pattern may not have a trailing comma")
    }
  }
  self.expect(")")
  res
}

fn Parser::parse_fn_type(self : Parser, ctor : Bool) -> TE {
  let tps = self.parse_type_params()
  let params = self.parse_params()
  self.expect("=>")
  let ret = self.parse_return_type()
  EFn(tps, params, ret, ctor)
}

fn Parser::parse_return_type(self : Parser) -> TE {
  // type predicates: `x is T`, `asserts x is T`
  if self.is_ident() {
    let s = self.save()
    let id = self.ident()
    if id == "asserts" && self.is_ident() {
      let _ = self.ident()
      if self.eat("is") {
        let _ = self.parse_type()

      }
      return EKw("void")
    }
    if self.at_kw("is") && !self.lx.nl_before {
      self.lx.next()
      let _ = self.parse_type()
      return EKw("boolean")
    }
    self.restore(s)
  }
  self.parse_type()
}

fn Parser::parse_union(self : Parser) -> TE {
  let _ = self.eat("|")
  let first = self.parse_inter()
  if !self.is_punct("|") {
    return first
  }
  let items = [first]
  while self.eat("|") {
    items.push(self.parse_inter())
  }
  EUnion(items)
}

fn Parser::parse_inter(self : Parser) -> TE {
  let _ = self.eat("&")
  let first = self.parse_operator()
  if !self.is_punct("&") {
    return first
  }
  let items = [first]
  while self.eat("&") {
    items.push(self.parse_operator())
  }
  EInter(items)
}

fn Parser::parse_operator(self : Parser) -> TE {
  // keyof, readonly, unique and infer are operators wherever a type starts
  if self.at_kw("keyof") {
    self.lx.next()
    let t = EKeyof(self.parse_operator())
    self.arrtup = false
    return t
  }
  if self.at_kw("readonly") {
    let pos = self.lx.start
    self.lx.next()
    let t = self.parse_operator()
    if !self.arrtup {
      self.lx.fail_at(
        pos, "'readonly' type modifier is only permitted on array and tuple literal types",
      )
    }
    self.arrtup = false
    return match t {
      ETuple(e, _) => ETuple(e, true)
      EArray(e, _) => EArray(e, true)
      other => other
    }
  }
  if self.at_kw("unique") {
    let pos = self.lx.start
    self.lx.next()
    if !self.at_kw("symbol") {
      self.lx.fail("'symbol' expected")
    }
    self.lx.next()
    self.arrtup = false
    self.uniq.push(pos)
    return EUniqueSymbol(pos)
  }
  if self.at_kw("infer") {
    self.lx.next()
    let name = self.ident()
    self.check_type_param_name(name)
    self.arrtup = false
    // `infer X extends C`: a constraint, unless followed by `?` outside an
    // extends clause (then the extends starts a conditional type)
    if self.at_kw("extends") {
      let s2 = self.save()
      let outer = self.in_extends
      self.lx.next()
      let c = self.parse_type_ctx(true)
      if self.is_punct("?") && !outer {
        self.restore(s2)
        return EInfer(name, None)
      }
      self.arrtup = false
      return EInfer(name, Some(c))
    }
    return EInfer(name, None)
  }
  self.parse_postfix()
}

fn Parser::parse_postfix(self : Parser) -> TE {
  let mut at = self.is_punct("[")
  let mut t = self.parse_primary()
  while !self.lx.nl_before {
    if self.is_punct("[") {
      self.lx.next()
      if self.eat("]") {
        t = EArray(t, false)
        at = true
      } else {
        let idx = self.parse_type()
        self.expect("]")
        t = EIndex(t, idx)
        at = false
      }
    } else if self.is_punct("?") {
      // `T?`, unless a type follows (the `?` of a conditional type)
      let s = self.save()
      self.lx.next()
      if self.is_start_of_type() {
        self.restore(s)
        break
      }
      t = ENullable(t, s.start)
      at = false
    } else {
      break
    }
  }
  self.arrtup = at
  t
}

// TypeScript's isStartOfType (for the token after a postfix `?`)
fn Parser::is_start_of_type(self : Parser) -> Bool {
  match self.lx.tok {
    TkStr | TkNum | TkBigInt | TkTplFull | TkTplHead => true
    TkIdent =>
      match self.lx.text {
        "break" | "case" | "catch" | "class" | "const" | "continue" | "debugger"
        | "default" | "delete" | "do" | "else" | "enum" | "export" | "extends"
        | "finally" | "for" | "if" | "in" | "instanceof" | "return" | "super"
        | "switch" | "throw" | "try" | "var" | "while" | "with" => false
        _ => true
      }
    TkPunct =>
      match self.lx.text {
        "{" | "[" | "<" | "|" | "&" | "(" | "*" | "?" | "!" | "..." => true
        "-" => {
          let s = self.save()
          self.lx.next()
          let r = self.lx.tok is TkNum || self.lx.tok is TkBigInt
          self.restore(s)
          r
        }
        _ => false
      }
    TkEOF => false
  }
}

fn Parser::parse_type_args(self : Parser) -> Array[TE] {
  let args : Array[TE] = []
  if self.is_punct("<") && !self.lx.nl_before || self.is_punct("<") {
    self.lx.next()
    while !self.is_punct(">") {
      args.push(self.parse_type())
      if !self.eat(",") {
        break
      }
    }
    self.expect(">")
  }
  args
}

fn Parser::parse_primary(self : Parser) -> TE {
  match self.lx.tok {
    TkStr => {
      let s = self.lx.text
      self.lx.next()
      EStr(s)
    }
    TkNum => {
      let v = self.lx.num
      self.lx.next()
      ENum(v)
    }
    TkBigInt => {
      let v = self.lx.text
      self.lx.next()
      EBig(v)
    }
    TkTplFull => {
      let s = self.lx.text
      self.lx.next()
      EStr(s)
    }
    TkTplHead => {
      let texts = [self.lx.text]
      let spans : Array[TE] = []
      self.lx.next()
      while true {
        spans.push(self.parse_type())
        if !self.is_punct("}") {
          self.lx.fail("expected '}' in template literal type")
        }
        // continue reading the template right after `}`
        self.lx.pos = self.lx.start + 1
        let more = self.lx.read_template_chunk()
        texts.push(self.lx.text)
        self.lx.next()
        if !more {
          break
        }
      }
      ETpl(texts, spans)
    }
    TkPunct =>
      match self.lx.text {
        "(" => {
          self.lx.next()
          let t = self.parse_type()
          self.expect(")")
          t
        }
        "[" => self.parse_tuple()
        "{" => self.parse_object_or_mapped()
        "-" => {
          self.lx.next()
          match self.lx.tok {
            TkNum => {
              let v = self.lx.num
              self.lx.next()
              ENum(-v)
            }
            TkBigInt => {
              let v = self.lx.text
              self.lx.next()
              EBig("-" + v)
            }
            _ => self.lx.fail("expected number after '-'")
          }
        }
        _ => self.lx.fail("unexpected token in type")
      }
    TkIdent => {
      let name = self.lx.text
      let pos = self.lx.start
      match name {
        "any" | "unknown" | "never" | "string" | "number" | "boolean" | "bigint"
        | "symbol" | "object" | "undefined" | "void" => {
          self.lx.next()
          if self.is_punct(".") {
            self.lx.fail("unexpected '.'")
          }
          EKw(name)
        }
        "null" => {
          self.lx.next()
          EKw("null")
        }
        "true" => {
          self.lx.next()
          EBool(true)
        }
        "false" => {
          self.lx.next()
          EBool(false)
        }
        "this" => {
          self.lx.next()
          EThis
        }
        "typeof" => {
          self.lx.next()
          // typeof x.y<...>
          let _ = self.ident()
          while self.eat(".") {
            let _ = self.ident()

          }
          let _ = self.parse_type_args()
          ETypeofUnsupported(pos)
        }
        _ => {
          self.lx.next()
          let quals : Array[String] = []
          while self.is_punct(".") {
            self.lx.next()
            quals.push(self.ident())
          }
          let args = if self.is_punct("<") && !self.lx.nl_before {
            self.parse_type_args()
          } else {
            []
          }
          ERef(name, quals, args, pos)
        }
      }
    }
    TkEOF => self.lx.fail("unexpected end of file")
  }
}

fn Parser::parse_tuple(self : Parser) -> TE {
  self.expect("[")
  let elems : Array[TElem] = []
  while !self.is_punct("]") {
    // a named member: `...`? name `?`? `:` type
    let s = self.save()
    let rest = self.eat("...")
    let mut name = ""
    let mut opt = false
    if self.is_ident() {
      let id = self.ident()
      if self.eat(":") {
        name = id
      } else if self.eat("?") && self.eat(":") {
        name = id
        opt = true
      }
    }
    if name == "" {
      self.restore(s)
      let (t, kind) = self.parse_tuple_element_type()
      elems.push({ ty: t, kind, name: "" })
    } else {
      if rest && opt {
        self.lx.fail_at(s.start, "a tuple member cannot be both optional and rest")
      }
      let tpos = self.lx.start
      let (t, kind) = self.parse_tuple_element_type()
      if kind == K_OPT {
        self.lx.fail_at(
          tpos, "a labeled tuple element is declared as optional with a question mark after the name and before the colon, rather than after the type",
        )
      }
      if kind == K_REST {
        self.lx.fail_at(
          tpos, "a labeled tuple element is declared as rest with a '...' before the name, rather than before the type",
        )
      }
      let kind = if rest { K_REST } else if opt { K_OPT } else { K_REQ }
      elems.push({ ty: t, kind, name })
    }
    if !self.eat(",") {
      break
    }
  }
  self.expect("]")
  ETuple(elems, false)
}

// TypeScript's parseTupleElementType: `...T`, `T?` or T
fn Parser::parse_tuple_element_type(self : Parser) -> (TE, Int) {
  if self.eat("...") {
    return (self.parse_type(), K_REST)
  }
  match self.parse_type() {
    ENullable(t, _) => (t, K_OPT)
    t => (t, K_REQ)
  }
}

// a property name: an identifier, a string or a number (numbers marked by a
// leading U+0001), or a computed name of a literal
fn Parser::prop_name(self : Parser) -> String {
  match self.lx.tok {
    TkIdent | TkStr => {
      let t = self.lx.text
      self.lx.next()
      // a name starting with the marker of numeric names keeps it doubled
      if t.length() > 0 && t.at(0) == '\u{1}' { "\u{1}" + t } else { t }
    }
    TkNum => {
      let v = self.lx.num
      self.lx.next()
      "\u{1}" + js_number_to_string(v)
    }
    TkPunct if self.is_punct("[") => {
      self.lx.next()
      let name = match self.lx.tok {
        TkStr => {
          let t = self.lx.text
          self.lx.next()
          if t.length() > 0 && t.at(0) == '\u{1}' { "\u{1}" + t } else { t }
        }
        TkNum => {
          let v = self.lx.num
          self.lx.next()
          "\u{1}" + js_number_to_string(v)
        }
        TkIdent => self.lx.fail("cannot find name '\{self.lx.text}'")
        _ => self.lx.fail("expected a property name")
      }
      self.expect("]")
      name
    }
    TkBigInt => self.lx.fail("a bigint literal cannot be used as a property name")
    _ => self.lx.fail("expected property name")
  }
}

fn Parser::parse_object_or_mapped(self : Parser) -> TE {
  // detect mapped type: `{ [ro|+ro|-ro] [ K in`
  let s = self.save()
  self.expect("{")
  let mut ro = 0
  if self.is_punct("+") || self.is_punct("-") {
    let sign = if self.lx.text == "+" { 1 } else { -1 }
    self.lx.next()
    if self.at_kw("readonly") {
      self.lx.next()
      ro = sign
    }
  } else if self.at_kw("readonly") {
    let s2 = self.save()
    self.lx.next()
    if self.is_punct("[") {
      ro = 1
    } else {
      self.restore(s2)
    }
  }
  if self.is_punct("[") {
    self.lx.next()
    if self.is_ident() {
      let name = self.ident()
      if self.at_kw("in") {
        self.lx.next()
        let c = self.parse_type()
        let as_clause = if self.eat("as") { Some(self.parse_type()) } else { None }
        self.expect("]")
        let mut opt = 0
        if self.is_punct("+") || self.is_punct("-") {
          opt = if self.lx.text == "+" { 1 } else { -1 }
          self.lx.next()
          self.expect("?")
        } else if self.eat("?") {
          opt = 1
        }
        // (noImplicitAny: a mapped type without a template type is an error)
        if !self.is_punct(":") {
          self.lx.fail("mapped object type implicitly has an 'any' template type")
        }
        self.lx.next()
        let body = Some(self.parse_type())
        let _ = self.eat(";")
        if !self.is_punct("}") {
          self.lx.fail("a mapped type may not declare properties or methods")
        }
        self.lx.next()
        return EMapped({
          param: name,
          constraint: c,
          as_clause,
          body,
          readonly_mod: ro,
          optional_mod: opt,
        })
      }
    }
  }
  self.restore(s)
  EObj(self.parse_members())
}

fn Parser::parse_members(self : Parser) -> Array[Member] {
  self.expect("{")
  let members : Array[Member] = []
  // declarations by name, for duplicates: 1 property, 2 get accessor, 4 set
  // accessor, 8 method, 16 optional method, 32 required method
  let seen : Map[String, Int] = Map::new()
  let keys : Array[String] = []
  // overloads of a method: one property of their call signatures
  let methods : Map[String, Int] = Map::new()
  while !self.is_punct("}") {
    let pos = self.lx.start
    let (m, kind) = self.parse_member()
    match (m, kind) {
      (MProp(name, EFn(tps, params, ret, false), opt, ro), 8) =>
        match methods.get(name) {
          Some(i) =>
            match members[i] {
              MProp(_, EObj(sigs), _, _) => sigs.push(MCall(tps, params, ret, false))
              MProp(_, EFn(t0, p0, r0, false), o0, r0o) =>
                members[i] = MProp(name, EObj([MCall(t0, p0, r0, false), MCall(tps, params, ret, false)]), o0, r0o)
              _ => ()
            }
          None => {
            methods.set(name, members.length())
            members.push(m)
          }
        }
      _ => members.push(m)
    }
    match m {
      MProp(name, _, opt, _) => {
        let had = seen.get(name).unwrap_or(0)
        let conflict = match kind {
          1 => (had & (1 | 2 | 4)) != 0
          2 => (had & (1 | 2 | 8)) != 0
          4 => (had & (1 | 4 | 8)) != 0
          _ => (had & (1 | 2 | 4)) != 0
        }
        if conflict {
          self.lx.fail_at(pos, "duplicate identifier '\{split_numeric_name(name).0}'")
        }
        let mut now = had | kind
        if kind == 8 {
          now = now | (if opt { 16 } else { 32 })
          if (now & 48) == 48 {
            self.lx.fail_at(pos, "overload signatures must all be optional or required")
          }
        }
        seen.set(name, now)
      }
      MIndex(_, kt, _, _) =>
        // the same key type twice (key types written as keywords)
        for k in index_key_names(kt) {
          if keys.contains(k) {
            self.lx.fail_at(pos, "duplicate index signature for type '\{k}'")
          }
          keys.push(k)
        }
      MCall(_, _, _, _) => ()
    }
    // members are separated by `;`, `,` or a line break
    if !(self.eat(";") || self.eat(",")) && !self.is_punct("}") &&
      !self.lx.nl_before {
      self.lx.fail("';' expected")
    }
  }
  self.expect("}")
  members
}

// what is wrong with the key type of an index signature (written types:
// references are checked once resolved)
fn index_key_problem(kt : TE) -> String? {
  match kt {
    EStr(_) | ENum(_) | EBig(_) | EBool(_) | EUniqueSymbol(_) =>
      Some("an index signature parameter type cannot be a literal type or generic type")
    EKw("string" | "number" | "symbol") | ERef(_, _, _, _) | ETpl(_, _) => None
    EUnion(items) => {
      for t in items {
        match index_key_problem(t) {
          Some(m) => return Some(m)
          None => ()
        }
      }
      None
    }
    EKw(_) | ETuple(_, _) | EArray(_, _) | EObj(_) | EFn(_, _, _, _) | EMapped(_) =>
      Some("an index signature parameter type must be 'string', 'number', 'symbol', or a template literal type")
    _ => None
  }
}

// the keyword key types of an index signature
fn index_key_names(kt : TE) -> Array[String] {
  match kt {
    EKw(k) => [k]
    EUnion(items) => {
      let r : Array[String] = []
      for t in items {
        for k in index_key_names(t) {
          r.push(k)
        }
      }
      r
    }
    _ => []
  }
}

// a modifier is one when a property name follows on the same line
fn Parser::next_can_follow_modifier(self : Parser) -> Bool {
  let s = self.save()
  self.lx.next()
  let r = !self.lx.nl_before &&
    (
      match self.lx.tok {
        TkIdent | TkStr | TkNum | TkBigInt => true
        TkPunct => self.is_punct("[") || self.is_punct("{") || self.is_punct("*") || self.is_punct("...")
        _ => false
      }
    )
  self.restore(s)
  r
}

// a member and its kind (1 property, 2 get accessor, 4 set accessor, 8
// method, 0 signatures)
fn Parser::parse_member(self : Parser) -> (Member, Int) {
  // call / construct signatures
  if self.is_punct("(") || self.is_punct("<") {
    let pos = self.lx.start
    let tps = self.parse_type_params()
    let params = self.parse_params()
    if !self.eat(":") {
      self.lx.fail_at(pos, "call signature, which lacks return-type annotation, implicitly has an 'any' return type")
    }
    let ret = self.parse_return_type()
    return (MCall(tps, params, ret, false), 0)
  }
  if self.at_kw("new") {
    let s = self.save()
    self.lx.next()
    if self.is_punct("(") || self.is_punct("<") {
      let tps = self.parse_type_params()
      let params = self.parse_params()
      if !self.eat(":") {
        self.lx.fail_at(s.start, "construct signature, which lacks return-type annotation, implicitly has an 'any' return type")
      }
      let ret = self.parse_return_type()
      return (MCall(tps, params, ret, true), 0)
    }
    self.restore(s)
  }
  let mut ro = false
  while self.is_ident() && self.next_can_follow_modifier() {
    match self.lx.text {
      "readonly" => {
        if ro {
          self.lx.fail("'readonly' modifier already seen")
        }
        ro = true
        self.lx.next()
      }
      "public" | "private" | "protected" | "static" | "abstract" | "declare"
      | "async" | "export" | "default" | "const" | "override" | "accessor"
      | "in" | "out" =>
        self.lx.fail("'\{self.lx.text}' modifier cannot appear on a type member")
      _ => break
    }
  }
  // get/set accessors
  if (self.at_kw("get") || self.at_kw("set")) && self.next_can_follow_modifier() {
    let pos = self.lx.start
    let kw = self.ident()
    let name = self.prop_name()
    let params = self.parse_params()
    if kw == "get" {
      if params.length() > 0 {
        self.lx.fail_at(pos, "a 'get' accessor cannot have parameters")
      }
      if !self.eat(":") {
        self.lx.fail_at(pos, "'\{name}', which lacks return-type annotation, implicitly has an 'any' return type")
      }
      let ret = self.parse_type()
      return (MProp(name, ret, false, ro), 2)
    }
    if params.length() != 1 || params[0].rest || params[0].optional {
      self.lx.fail_at(pos, "a 'set' accessor must have exactly one parameter")
    }
    if self.is_punct(":") {
      self.lx.fail("a 'set' accessor cannot have a return type annotation")
    }
    return (MProp(name, params[0].ty, false, ro), 4)
  }
  // index signature
  if self.is_punct("[") {
    let s = self.save()
    self.lx.next()
    if self.is_ident() {
      let key = self.ident()
      if self.eat(":") {
        let kt = self.parse_type()
        self.expect("]")
        if !self.eat(":") {
          self.lx.fail_at(s.start, "an index signature must have a type annotation")
        }
        let vt = self.parse_type()
        match index_key_problem(kt) {
          Some(msg) => self.lx.fail_at(s.start, msg)
          None => ()
        }
        return (MIndex(key, kt, vt, ro), 0)
      }
    }
    self.restore(s)
  }
  let pos = self.lx.start
  let name = self.prop_name()
  let optional = self.eat("?")
  if self.is_punct("(") || self.is_punct("<") {
    let tps = self.parse_type_params()
    let params = self.parse_params()
    if !self.eat(":") {
      self.lx.fail_at(pos, "'\{split_numeric_name(name).0}', which lacks return-type annotation, implicitly has an 'any' return type")
    }
    let ret = self.parse_return_type()
    return (MProp(name, EFn(tps, params, ret, false), optional, ro), 8)
  }
  // (noImplicitAny: a property without a type is an error)
  if !self.eat(":") {
    self.lx.fail_at(pos, "member '\{split_numeric_name(name).0}' implicitly has an 'any' type")
  }
  let t = self.parse_type()
  if self.is_punct("=") {
    self.lx.fail("a type literal property cannot have an initializer")
  }
  // `unique symbol` may be the type of a readonly property signature
  match t {
    EUniqueSymbol(p) if ro => self.uniq.retain(fn(x) { x != p })
    _ => ()
  }
  (MProp(name, t, optional, ro), 1)
}

fn Parser::parse_module_spec(self : Parser) -> String {
  match self.lx.tok {
    TkStr => {
      let s = self.lx.text
      self.lx.next()
      s
    }
    _ => self.lx.fail("expected module specifier")
  }
}

fn Parser::parse_named_list(self : Parser) -> Array[(String, String)] {
  self.expect("{")
  let res : Array[(String, String)] = []
  while !self.is_punct("}") {
    let _ = self.eat("type")
    // `type` may itself be the name
    let a = match self.lx.tok {
      TkIdent | TkStr => {
        let t = self.lx.text
        self.lx.next()
        t
      }
      _ => self.lx.fail("expected name")
    }
    let b = if self.eat("as") { self.ident() } else { a }
    res.push((a, b))
    if !self.eat(",") {
      break
    }
  }
  self.expect("}")
  res
}

fn Parser::parse_file(self : Parser) -> Array[Decl] {
  let decls : Array[Decl] = []
  while !(self.tok() is TkEOF) {
    if self.eat(";") {
      continue
    }
    let doc = self.lx.doc
    let mut exported = false
    if self.at_kw("import") {
      self.lx.next()
      let _ = self.eat("type")
      if self.is_punct("{") {
        let names = self.parse_named_list()
        self.expect("from")
        let m = self.parse_module_spec()
        decls.push(DImport(names, m))
      } else if self.eat("*") {
        self.expect("as")
        let ns = self.ident()
        self.expect("from")
        let m = self.parse_module_spec()
        decls.push(DImportNs(ns, m))
      } else {
        self.lx.fail("unsupported import form")
      }
      let _ = self.eat(";")
      continue
    }
    if self.at_kw("export") {
      self.lx.next()
      exported = true
      if self.is_punct("{") || (self.at_kw("type") && {
          let s = self.save()
          self.lx.next()
          let r = self.is_punct("{")
          self.restore(s)
          r
        }) {
        let _ = self.eat("type")
        let names = self.parse_named_list()
        let from = if self.eat("from") {
          Some(self.parse_module_spec())
        } else {
          None
        }
        decls.push(DExportNames(names.map(fn(p) { (p.0, p.1) }), from))
        let _ = self.eat(";")
        continue
      }
      if self.eat("*") {
        self.expect("from")
        let m = self.parse_module_spec()
        decls.push(DExportStar(m))
        let _ = self.eat(";")
        continue
      }
    }
    let _ = self.eat("declare")
    if self.at_kw("type") {
      self.lx.next()
      let npos = self.lx.start
      let name = self.ident()
      self.check_decl_name(npos, name)
      let tps = self.parse_type_params_of(0)
      self.expect("=")
      let body = self.parse_type()
      let _ = self.eat(";")
      decls.push(DAlias(name, tps, body, doc, exported))
      continue
    }
    if self.at_kw("interface") {
      self.lx.next()
      let npos = self.lx.start
      let name = self.ident()
      self.check_decl_name(npos, name)
      let tps = self.parse_type_params_of(0)
      let heritage : Array[TE] = []
      if self.eat("extends") {
        while true {
          heritage.push(self.parse_postfix())
          if !self.eat(",") {
            break
          }
        }
      }
      let members = self.parse_members()
      decls.push(DInterface(name, tps, heritage, members, doc, exported))
      continue
    }
    self.lx.fail("unsupported declaration")
  }
  decls
}

fn parse_source(src : String, file : String) -> Array[Decl] {
  let p = { lx: Lexer::new(src, file), in_extends: false, arrtup: false, uniq: [] }
  let decls = p.parse_file()
  if p.uniq.length() > 0 {
    p.lx.fail_at(p.uniq[0], "'unique symbol' types are not allowed here")
  }
  decls
}

// names a type alias or an interface cannot have
fn Parser::check_decl_name(self : Parser, pos : Int, name : String) -> Unit {
  match name {
    "any" | "unknown" | "never" | "number" | "bigint" | "boolean" | "string" |
    "symbol" | "void" | "object" | "undefined" =>
      self.lx.fail_at(pos, "type name cannot be '" + name + "'")
    _ => ()
  }
}
