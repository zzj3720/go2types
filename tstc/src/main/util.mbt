// Files, processes and errors of the compiler.

#borrow(path)
extern "c" fn c_read_file(path : Bytes) -> Bytes = "tstc_read_file"

#borrow(path)
extern "c" fn c_file_exists(path : Bytes) -> Int = "tstc_file_exists"

#borrow(path, data)
extern "c" fn c_write_file(path : Bytes, data : Bytes) -> Int = "tstc_write_file"

#borrow(data)
extern "c" fn c_write_out(fd : Int, data : Bytes) = "tstc_write_out"

#borrow(cmd)
extern "c" fn c_system(cmd : Bytes) -> Int = "tstc_system"

extern "c" fn c_exit(code : Int) = "tstc_exit"

extern "c" fn c_now_ms() -> Double = "tstc_now_ms"

fn now_ms() -> Double {
  c_now_ms()
}

fn path_bytes(p : String) -> Bytes {
  utf8_encode(p)
}

fn read_file(path : String) -> String? {
  if c_file_exists(path_bytes(path)) == 0 {
    return None
  }
  Some(utf8_decode(c_read_file(path_bytes(path))))
}

fn write_file(path : String, data : String) -> Bool {
  c_write_file(path_bytes(path), utf8_encode(data)) != 0
}

fn out(s : String) -> Unit {
  c_write_out(1, utf8_encode(s))
}

fn err(s : String) -> Unit {
  c_write_out(2, utf8_encode(s))
}

fn[T] die(msg : String) -> T {
  err("tstc: " + msg + "\n")
  c_exit(1)
  panic()
}

fn system(cmd : String) -> Int {
  c_system(utf8_encode(cmd))
}
fn utf8_encode(s : String) -> Bytes {
  let buf = @buffer.new(size_hint=s.length() + 16)
  let n = s.length()
  let mut i = 0
  while i < n {
    let mut c = s.at(i)
    if c >= 0xD800 && c <= 0xDBFF && i + 1 < n {
      let d = s.at(i + 1)
      if d >= 0xDC00 && d <= 0xDFFF {
        c = 0x10000 + ((c - 0xD800) << 10) + (d - 0xDC00)
        i += 1
      }
    }
    if c < 0x80 {
      buf.write_byte(c.to_byte())
    } else if c < 0x800 {
      buf.write_byte((0xC0 | (c >> 6)).to_byte())
      buf.write_byte((0x80 | (c & 0x3F)).to_byte())
    } else if c < 0x10000 {
      buf.write_byte((0xE0 | (c >> 12)).to_byte())
      buf.write_byte((0x80 | ((c >> 6) & 0x3F)).to_byte())
      buf.write_byte((0x80 | (c & 0x3F)).to_byte())
    } else {
      buf.write_byte((0xF0 | (c >> 18)).to_byte())
      buf.write_byte((0x80 | ((c >> 12) & 0x3F)).to_byte())
      buf.write_byte((0x80 | ((c >> 6) & 0x3F)).to_byte())
      buf.write_byte((0x80 | (c & 0x3F)).to_byte())
    }
    i += 1
  }
  buf.to_bytes()
}
// (stub.c)
#borrow(b)
extern "c" fn utf8_decode(b : Bytes) -> String = "tstc_utf8_decode"

// ---------------------------------------------------------------------------
// Reading text files of the cache in place (bytes, not strings)

#borrow(b)
extern "c" fn c_utf8_slice(b : Bytes, s : Int, e : Int) -> String = "tstc_utf8_slice"

#borrow(b)
extern "c" fn c_buf_bytes(h : Int, b : Bytes, s : Int, e : Int) = "tstc_buf_bytes"

fn read_bytes(path : String) -> Bytes? {
  if c_file_exists(path_bytes(path)) == 0 {
    return None
  }
  Some(c_read_file(path_bytes(path)))
}

// the end of the line of b starting at s (its '\n', or the end of b)
fn line_end(b : Bytes, s : Int) -> Int {
  let n = b.length()
  let mut i = s
  while i < n && b[i] != b'\n' {
    i += 1
  }
  i
}

// the fields of [s, e) of b separated by sep: start and end of each
fn fields_at(b : Bytes, s : Int, e : Int, sep : Byte, out : Array[Int]) -> Unit {
  out.clear()
  out.push(s)
  for i in s..<e {
    if b[i] == sep {
      out.push(i)
      out.push(i + 1)
    }
  }
  out.push(e)
}

// the decimal number at [s, e) of b (-1: none)
fn int_at(b : Bytes, s : Int, e : Int) -> Int {
  int64_at(b, s, e).to_int()
}

fn int64_at(b : Bytes, s : Int, e : Int) -> Int64 {
  if s >= e {
    return -1L
  }
  let neg = b[s] == b'-'
  let s0 = if neg { s + 1 } else { s }
  if s0 >= e {
    return -1L
  }
  let mut v = 0L
  for i in s0..<e {
    let c = b[i].to_int()
    if c < 48 || c > 57 {
      return -1L
    }
    v = v * 10L + (c - 48).to_int64()
  }
  if neg {
    -v
  } else {
    v
  }
}

