// Strings (views of code units) and JavaScript number formatting.
#include "tstc.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>

static StrBuf empty_buf = {0, -1, NULL};
static Str empty_str = {K_STRLIT, 0, 0, 0, &empty_buf};
Str *str_empty = &empty_str;

// a string with a buffer of its own (room for cap code units): one object
// (the views of the buffer made later keep it, header and all)
typedef struct {
  Str s;
  StrBuf b;
} StrWithBuf;

static Str *str_with_buf(int32_t cap) {
  StrWithBuf *x = gc_alloc(sizeof(StrWithBuf));
  x->b.cap = cap;
  x->b.d = cap > 0 ? gc_alloc_atomic((size_t)cap * 2) : NULL;
  x->s.tag = K_STRLIT;
  x->s.buf = &x->b;
  return &x->s;
}

Str *str_alloc(int32_t n) {
  Str *s = str_with_buf(n);
  s->buf->used = n;
  s->len = n;
  return s;
}

Str *str_new(const uint16_t *d, int32_t n) {
  if (n == 0) return str_empty;
  Str *s = str_alloc(n);
  memcpy(s->buf->d, d, (size_t)n * 2);
  return s;
}

Str *str_of_bytes(const uint8_t *b, int32_t n) {
  if (n == 0) return str_empty;
  Str *s = str_alloc(n);
  for (int32_t i = 0; i < n; i++) s->buf->d[i] = b[i];
  return s;
}

// UTF-8 text to UTF-16 code units
Str *str_of_cstr(const char *c) {
  // ASCII: directly
  size_t n = 0;
  while (c[n] && (uint8_t)c[n] < 0x80) n++;
  if (!c[n]) {
    if (n == 0) return str_empty;
    Str *s = str_alloc((int32_t)n);
    for (size_t i = 0; i < n; i++) s->buf->d[i] = (uint8_t)c[i];
    return s;
  }
  SB b = {0};
  const uint8_t *p = (const uint8_t *)c;
  while (*p) {
    uint32_t cp;
    if (p[0] < 0x80) {
      cp = *p++;
    } else if ((p[0] & 0xE0) == 0xC0 && p[1]) {
      cp = ((uint32_t)(p[0] & 0x1F) << 6) | (p[1] & 0x3F);
      p += 2;
    } else if ((p[0] & 0xF0) == 0xE0 && p[1] && p[2]) {
      cp = ((uint32_t)(p[0] & 0x0F) << 12) | ((uint32_t)(p[1] & 0x3F) << 6) | (p[2] & 0x3F);
      p += 3;
    } else if ((p[0] & 0xF8) == 0xF0 && p[1] && p[2] && p[3]) {
      cp = ((uint32_t)(p[0] & 0x07) << 18) | ((uint32_t)(p[1] & 0x3F) << 12) |
           ((uint32_t)(p[2] & 0x3F) << 6) | (p[3] & 0x3F);
      p += 4;
    } else {
      cp = 0xFFFD;
      p++;
    }
    if (cp >= 0x10000) {
      cp -= 0x10000;
      sb_put(&b, (uint16_t)(0xD800 + (cp >> 10)));
      sb_put(&b, (uint16_t)(0xDC00 + (cp & 0x3FF)));
    } else {
      sb_put(&b, (uint16_t)cp);
    }
  }
  return sb_finish(&b);
}

V mk_strlit_c(const char *c) { return (V)str_of_cstr(c); }

char *str_to_utf8(Str *s, size_t *len) {
  const uint16_t *d = str_d(s);
  char *out = malloc((size_t)s->len * 3 + 1);
  size_t k = 0;
  for (int32_t i = 0; i < s->len; i++) {
    uint32_t c = d[i];
    if (c >= 0xD800 && c <= 0xDBFF && i + 1 < s->len && d[i + 1] >= 0xDC00 && d[i + 1] <= 0xDFFF) {
      c = 0x10000 + ((c - 0xD800) << 10) + (d[i + 1] - 0xDC00);
      i++;
    }
    if (c < 0x80) {
      out[k++] = (char)c;
    } else if (c < 0x800) {
      out[k++] = (char)(0xC0 | (c >> 6));
      out[k++] = (char)(0x80 | (c & 0x3F));
    } else if (c < 0x10000) {
      out[k++] = (char)(0xE0 | (c >> 12));
      out[k++] = (char)(0x80 | ((c >> 6) & 0x3F));
      out[k++] = (char)(0x80 | (c & 0x3F));
    } else {
      out = realloc(out, (size_t)s->len * 3 + 8 + k);
      out[k++] = (char)(0xF0 | (c >> 18));
      out[k++] = (char)(0x80 | ((c >> 12) & 0x3F));
      out[k++] = (char)(0x80 | ((c >> 6) & 0x3F));
      out[k++] = (char)(0x80 | (c & 0x3F));
    }
  }
  out[k] = 0;
  if (len) *len = k;
  return out;
}

Str *str_slice(Str *s, int32_t from, int32_t to) {
  if (from == 0 && to == s->len) return s;
  if (to == from) return str_empty;
  Str *r = gc_alloc(sizeof(Str));
  r->tag = K_STRLIT;
  r->buf = s->buf;
  r->start = s->start + from;
  r->len = to - from;
  return r;
}

Str *str_concat(Str *a, Str *b) {
  if (b->len == 0) return a;
  if (a->len == 0) return b;
  int32_t n = a->len + b->len;
  StrBuf *buf = a->buf;
  if (buf->cap >= 0 && a->start + a->len == buf->used) {
    int32_t need = a->start + n;
    if (need > buf->cap) {
      int32_t nc = need * 2;
      buf->d = gc_realloc_atomic(buf->d, (size_t)buf->used * 2, (size_t)nc * 2);
      buf->cap = nc;
    }
    memcpy(buf->d + buf->used, str_d(b), (size_t)b->len * 2);
    buf->used = need;
    Str *r = gc_alloc(sizeof(Str));
    r->tag = K_STRLIT;
    r->buf = buf;
    r->start = a->start;
    r->len = n;
    return r;
  }
  Str *r = str_with_buf(n * 2);
  memcpy(r->buf->d, str_d(a), (size_t)a->len * 2);
  memcpy(r->buf->d + a->len, str_d(b), (size_t)b->len * 2);
  r->buf->used = n;
  r->len = n;
  return r;
}

Str *str_concat_copy(Str *a, Str *b) {
  int32_t n = a->len + b->len;
  if (n == 0) return str_empty;
  Str *r = str_alloc(n);
  memcpy(r->buf->d, str_d(a), (size_t)a->len * 2);
  memcpy(r->buf->d + a->len, str_d(b), (size_t)b->len * 2);
  return r;
}

uint32_t str_hash(Str *s) {
  if (s->hash) return s->hash;
  uint32_t h = 0x811c9dc5u;
  const uint16_t *d = str_d(s);
  for (int32_t i = 0; i < s->len; i++) h = (h ^ d[i]) * 0x01000193u;
  if (h == 0) h = 1;
  s->hash = h;
  return h;
}

bool str_eq(Str *a, Str *b) {
  if (a == b) return true;
  if (a->len != b->len) return false;
  if (a->buf == b->buf && a->start == b->start) return true;
  if (a->hash && b->hash && a->hash != b->hash) return false;
  return memcmp(str_d(a), str_d(b), (size_t)a->len * 2) == 0;
}

bool str_eq_c(Str *a, const char *c) {
  size_t n = strlen(c);
  if ((size_t)a->len != n) return false;
  const uint16_t *d = str_d(a);
  for (size_t i = 0; i < n; i++)
    if (d[i] != (uint8_t)c[i]) return false;
  return true;
}

int str_cmp(Str *a, Str *b) {
  int32_t n = a->len < b->len ? a->len : b->len;
  const uint16_t *x = str_d(a), *y = str_d(b);
  for (int32_t i = 0; i < n; i++)
    if (x[i] != y[i]) return x[i] < y[i] ? -1 : 1;
  return a->len == b->len ? 0 : (a->len < b->len ? -1 : 1);
}

bool str_starts(Str *s, Str *p) {
  return p->len <= s->len && memcmp(str_d(s), str_d(p), (size_t)p->len * 2) == 0;
}

bool str_ends(Str *s, Str *p) {
  return p->len <= s->len &&
         memcmp(str_d(s) + (s->len - p->len), str_d(p), (size_t)p->len * 2) == 0;
}

int32_t str_index(Str *s, Str *p, int32_t from, int32_t limit) {
  if (p->len == 0) return from <= limit ? from : -1;
  const uint16_t *d = str_d(s), *q = str_d(p);
  for (int32_t i = from; i + p->len <= limit; i++)
    if (d[i] == q[0] && memcmp(d + i, q, (size_t)p->len * 2) == 0) return i;
  return -1;
}

// ---------------------------------------------------------------------------

void sb_put(SB *b, uint16_t c) {
  if (b->n == b->cap) {
    b->cap = b->cap ? b->cap * 2 : 32;
    b->d = realloc(b->d, (size_t)b->cap * 2);
  }
  b->d[b->n++] = c;
}

void sb_puts(SB *b, const char *c) {
  while (*c) sb_put(b, (uint8_t)*c++);
}

void sb_str(SB *b, Str *s) {
  const uint16_t *d = str_d(s);
  for (int32_t i = 0; i < s->len; i++) sb_put(b, d[i]);
}

Str *sb_finish(SB *b) {
  Str *s = str_new(b->d, b->n);
  free(b->d);
  b->d = NULL;
  b->n = b->cap = 0;
  return s;
}

// ---------------------------------------------------------------------------
// Number.prototype.toString()

void js_number_to_sb(double d, SB *b) {
  if (isnan(d)) {
    sb_puts(b, "NaN");
    return;
  }
  if (d == 0) {
    sb_put(b, '0');
    return;
  }
  if (isinf(d)) {
    sb_puts(b, d > 0 ? "Infinity" : "-Infinity");
    return;
  }
  if (d < 0) {
    sb_put(b, '-');
    d = -d;
  }
  // shortest digits that round-trip
  char buf[40], digits[24];
  int k = 0, e = 0;
  for (int p = 0; p < 17; p++) {
    snprintf(buf, sizeof buf, "%.*e", p, d);
    if (strtod(buf, NULL) == d || p == 16) {
      // buf: d[.ddd]e[+-]xx
      char *q = buf;
      k = 0;
      while (*q && *q != 'e') {
        if (*q != '.') digits[k++] = *q;
        q++;
      }
      e = atoi(q + 1);
      break;
    }
  }
  while (k > 1 && digits[k - 1] == '0') k--;
  digits[k] = 0;
  int n = e + 1;
  if (k <= n && n <= 21) {
    for (int i = 0; i < k; i++) sb_put(b, digits[i]);
    for (int i = k; i < n; i++) sb_put(b, '0');
  } else if (0 < n && n <= 21) {
    for (int i = 0; i < n; i++) sb_put(b, digits[i]);
    sb_put(b, '.');
    for (int i = n; i < k; i++) sb_put(b, digits[i]);
  } else if (-6 < n && n <= 0) {
    sb_puts(b, "0.");
    for (int i = 0; i < -n; i++) sb_put(b, '0');
    for (int i = 0; i < k; i++) sb_put(b, digits[i]);
  } else {
    sb_put(b, digits[0]);
    if (k > 1) {
      sb_put(b, '.');
      for (int i = 1; i < k; i++) sb_put(b, digits[i]);
    }
    char ex[16];
    snprintf(ex, sizeof ex, "e%c%d", n - 1 >= 0 ? '+' : '-', abs(n - 1));
    sb_puts(b, ex);
  }
}

Str *str_of_number(double d) {
  SB b = {0};
  js_number_to_sb(d, &b);
  return sb_finish(&b);
}

Str *str_of_int(int64_t v) {
  char buf[24];
  int i = 23;
  buf[i] = 0;
  uint64_t u = v < 0 ? (uint64_t)0 - (uint64_t)v : (uint64_t)v;
  do {
    buf[--i] = (char)('0' + u % 10);
    u /= 10;
  } while (u);
  if (v < 0) buf[--i] = '-';
  return str_of_cstr(buf + i);
}

Str *str_of_uint(uint64_t v) {
  char buf[32];
  snprintf(buf, sizeof buf, "%llu", (unsigned long long)v);
  return str_of_cstr(buf);
}

bool parse_js_number(Str *s, double *out) {
  int32_t n = s->len;
  if (n == 0) return false;
  const uint16_t *d = str_d(s);
  int32_t i = 0;
  bool neg = false;
  if (d[0] == '-') {
    neg = true;
    i = 1;
  }
  if (i >= n) return false;
  bool all_digits = true;
  for (int32_t j = i; j < n; j++)
    if (d[j] < '0' || d[j] > '9') {
      all_digits = false;
      break;
    }
  if (all_digits && n - i < 16) {
    double v = 0;
    for (int32_t j = i; j < n; j++) v = v * 10 + (d[j] - '0');
    *out = neg ? -v : v;
    return true;
  }
  if (n > 64) return false;
  char buf[72];
  for (int32_t j = 0; j < n; j++) {
    uint16_t c = d[j];
    if (!((c >= '0' && c <= '9') || c == '.' || c == 'e' || c == 'E' || c == '-' || c == '+'))
      return false;
    buf[j] = (char)c;
  }
  buf[n] = 0;
  char *end;
  double v = strtod(buf, &end);
  if (end != buf + n) return false;
  *out = v;
  return true;
}

bool parse_canonical_number(Str *s, double *out) {
  double v;
  if (!parse_js_number(s, &v)) return false;
  Str *t = str_of_number(v);
  if (!str_eq(t, s)) return false;
  *out = v;
  return true;
}

// JavaScript's Number(text) (StringToNumber): NaN when it is no number
static bool js_space(uint16_t c) {
  return c == 9 || c == 10 || c == 11 || c == 12 || c == 13 || c == 32 || c == 0xA0 || c == 0x1680 ||
         (c >= 0x2000 && c <= 0x200A) || c == 0x2028 || c == 0x2029 || c == 0x202F || c == 0x205F ||
         c == 0x3000 || c == 0xFEFF;
}

double js_to_number(Str *s) {
  const uint16_t *d = str_d(s);
  int32_t a = 0, b = s->len;
  while (a < b && js_space(d[a])) a++;
  while (b > a && js_space(d[b - 1])) b--;
  if (a == b) return 0;
  int32_t n = b - a;
  const uint16_t *p = d + a;
  if (n > 2 && p[0] == '0') {
    int base = (p[1] | 0x20) == 'x' ? 16 : (p[1] | 0x20) == 'o' ? 8 : (p[1] | 0x20) == 'b' ? 2 : 0;
    if (base) {
      double v = 0;
      for (int32_t i = 2; i < n; i++) {
        uint16_t c = p[i];
        int dv = c >= '0' && c <= '9' ? c - '0' : ((c | 0x20) >= 'a' && (c | 0x20) <= 'f') ? (c | 0x20) - 'a' + 10 : 99;
        if (dv >= base) return NAN;
        v = v * base + dv;
      }
      return v;
    }
  }
  char buf[400];
  if (n >= (int32_t)sizeof buf) return NAN;
  int32_t i = 0;
  bool neg = false;
  if (p[0] == '+' || p[0] == '-') {
    neg = p[0] == '-';
    i = 1;
  }
  int32_t m = n - i;
  if (m == 8) {
    static const char inf[] = "Infinity";
    bool is_inf = true;
    for (int32_t j = 0; j < 8 && is_inf; j++) is_inf = p[i + j] == (uint16_t)inf[j];
    if (is_inf) return neg ? -INFINITY : INFINITY;
  }
  // digits [. digits] [e [sign] digits], at least one digit in the mantissa
  int32_t j = i, k = 0, digits = 0;
  while (j < n && p[j] >= '0' && p[j] <= '9') { buf[k++] = (char)p[j++]; digits++; }
  if (j < n && p[j] == '.') {
    buf[k++] = '.';
    j++;
    while (j < n && p[j] >= '0' && p[j] <= '9') { buf[k++] = (char)p[j++]; digits++; }
  }
  if (!digits) return NAN;
  if (j < n && (p[j] == 'e' || p[j] == 'E')) {
    buf[k++] = 'e';
    j++;
    if (j < n && (p[j] == '+' || p[j] == '-')) buf[k++] = (char)p[j++];
    int32_t ed = 0;
    while (j < n && p[j] >= '0' && p[j] <= '9') { buf[k++] = (char)p[j++]; ed++; }
    if (!ed) return NAN;
  }
  if (j != n) return NAN;
  buf[k] = 0;
  double v = strtod(buf, NULL);
  return neg ? -v : v;
}
