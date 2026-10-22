// Str: an immutable view of UTF-16 code units in a shared, append-only buffer.
//
// Slicing is O(1). Concatenation appends in place when the left operand ends
// at the end of its buffer (nobody else can observe code units past a view's
// end), so accumulator loops like `${Acc}${C}` are amortized O(1) per step.

struct Str {
  data : Array[Int]
  start : Int
  len : Int
  mut h : Int
}

fn Str::empty() -> Str {
  { data: [], start: 0, len: 0, h: 0 }
}

fn Str::of_string(s : String) -> Str {
  let n = s.length()
  let data = Array::new(capacity=n)
  for i in 0..<n {
    data.push(s.at(i))
  }
  { data, start: 0, len: n, h: 0 }
}

fn Str::of_codes(data : Array[Int]) -> Str {
  { data, start: 0, len: data.length(), h: 0 }
}

fn Str::at(self : Str, i : Int) -> Int {
  self.data.unsafe_get(self.start + i)
}

fn Str::slice(self : Str, from : Int, to : Int) -> Str {
  if from == 0 && to == self.len {
    return self
  }
  { data: self.data, start: self.start + from, len: to - from, h: 0 }
}

fn Str::concat(self : Str, other : Str) -> Str {
  if other.len == 0 {
    return self
  }
  if self.len == 0 {
    return other
  }
  if self.start + self.len == self.data.length() {
    let d = self.data
    for i in 0..<other.len {
      d.push(other.data.unsafe_get(other.start + i))
    }
    return { data: d, start: self.start, len: self.len + other.len, h: 0 }
  }
  let d = Array::new(capacity=(self.len + other.len) * 2)
  for i in 0..<self.len {
    d.push(self.data.unsafe_get(self.start + i))
  }
  for i in 0..<other.len {
    d.push(other.data.unsafe_get(other.start + i))
  }
  { data: d, start: 0, len: self.len + other.len, h: 0 }
}

fn Str::equals(self : Str, other : Str) -> Bool {
  if self.len != other.len {
    return false
  }
  if physical_equal(self.data, other.data) && self.start == other.start {
    return true
  }
  if self.h != 0 && other.h != 0 && self.h != other.h {
    return false
  }
  for i in 0..<self.len {
    if self.data.unsafe_get(self.start + i) !=
      other.data.unsafe_get(other.start + i) {
      return false
    }
  }
  true
}

fn Str::equals_string(self : Str, s : String) -> Bool {
  if self.len != s.length() {
    return false
  }
  for i in 0..<self.len {
    if self.at(i) != s.at(i) {
      return false
    }
  }
  true
}

fn Str::hash_code(self : Str) -> Int {
  if self.h != 0 {
    return self.h
  }
  let mut h = 0x811c9dc5
  for i in 0..<self.len {
    h = (h ^ self.data.unsafe_get(self.start + i)) * 0x01000193
  }
  if h == 0 {
    h = 1
  }
  self.h = h
  h
}

impl Eq for Str with equal(self, other) {
  self.equals(other)
}

impl Hash for Str with hash_combine(self, hasher) {
  hasher.combine_int(self.hash_code())
}

impl Hash for Str with hash(self) {
  self.hash_code()
}

fn Str::starts_with(self : Str, p : Str) -> Bool {
  if p.len > self.len {
    return false
  }
  for i in 0..<p.len {
    if self.at(i) != p.at(i) {
      return false
    }
  }
  true
}

fn Str::ends_with(self : Str, p : Str) -> Bool {
  if p.len > self.len {
    return false
  }
  let off = self.len - p.len
  for i in 0..<p.len {
    if self.at(off + i) != p.at(i) {
      return false
    }
  }
  true
}

// index of `p` in self[from..limit), or -1
fn Str::index_of(self : Str, p : Str, from : Int, limit : Int) -> Int {
  if p.len == 0 {
    return if from <= limit { from } else { -1 }
  }
  let first = p.at(0)
  let mut i = from
  while i + p.len <= limit {
    if self.at(i) == first {
      let mut ok = true
      for j in 1..<p.len {
        if self.at(i + j) != p.at(j) {
          ok = false
          break
        }
      }
      if ok {
        return i
      }
    }
    i += 1
  }
  -1
}

fn Str::compare(self : Str, other : Str) -> Int {
  let n = if self.len < other.len { self.len } else { other.len }
  for i in 0..<n {
    let a = self.at(i)
    let b = other.at(i)
    if a != b {
      return if a < b { -1 } else { 1 }
    }
  }
  if self.len == other.len {
    0
  } else if self.len < other.len {
    -1
  } else {
    1
  }
}

fn Str::to_string(self : Str) -> String {
  let sb = StringBuilder::new(size_hint=self.len)
  let mut i = 0
  while i < self.len {
    let c = self.at(i)
    if c >= 0xD800 && c <= 0xDBFF && i + 1 < self.len {
      let d = self.at(i + 1)
      if d >= 0xDC00 && d <= 0xDFFF {
        sb.write_char(
          Int::unsafe_to_char(0x10000 + ((c - 0xD800) << 10) + (d - 0xDC00)),
        )
        i += 2
        continue
      }
    }
    sb.write_char(Int::unsafe_to_char(c))
    i += 1
  }
  sb.to_string()
}

impl Show for Str with output(self, logger) {
  logger.write_string(self.to_string())
}

// ---------------------------------------------------------------------------
// JS number formatting (Number.prototype.toString for the common cases)

fn js_number_to_string(d : Double) -> String {
  if d.is_nan() {
    return "NaN"
  }
  if d.is_pos_inf() {
    return "Infinity"
  }
  if d.is_neg_inf() {
    return "-Infinity"
  }
  if d == 0.0 {
    return "0"
  }
  if d == d.floor() && d.abs() < 1.0e21 {
    if d.abs() < 2147483647.0 {
      return d.to_int().to_string()
    }
    return d.to_int64().to_string()
  }
  let s = d.to_string()
  s
}

fn str_of_number(d : Double) -> Str {
  Str::of_string(js_number_to_string(d))
}

// Parse a string as a JS numeric literal the way TS does for `${infer N extends number}`:
// the text must round-trip through Number -> String.
fn parse_canonical_number(s : Str) -> Double? {
  if s.len == 0 {
    return None
  }
  let text = s.to_string()
  let d = parse_js_number(text)
  match d {
    Some(v) => if js_number_to_string(v) == text { Some(v) } else { None }
    None => None
  }
}

fn parse_js_number(text : String) -> Double? {
  let n = text.length()
  if n == 0 {
    return None
  }
  // integer fast path
  let mut neg = false
  let mut i = 0
  if text.at(0) == '-' {
    neg = true
    i = 1
  }
  if i >= n {
    return None
  }
  let mut all_digits = true
  for j in i..<n {
    let c = text.at(j)
    if c < '0' || c > '9' {
      all_digits = false
      break
    }
  }
  if all_digits && n - i < 16 {
    let mut v = 0.0
    for j in i..<n {
      v = v * 10.0 + (text.at(j) - '0').to_double()
    }
    return Some(if neg { -v } else { v })
  }
  for j in 0..<n {
    let c = text.at(j)
    if !((c >= '0' && c <= '9') || c == '.' || c == 'e' || c == 'E' || c == '-' ||
      c == '+') {
      return None
    }
  }
  let r = try? @strconv.parse_double(text)
  match r {
    Ok(v) => Some(v)
    Err(_) => None
  }
}

// concatenation that never mutates the left operand's buffer
fn Str::concat_copy(self : Str, other : Str) -> Str {
  let d = Array::new(capacity=self.len + other.len)
  for i in 0..<self.len {
    d.push(self.at(i))
  }
  for i in 0..<other.len {
    d.push(other.at(i))
  }
  { data: d, start: 0, len: self.len + other.len, h: 0 }
}
