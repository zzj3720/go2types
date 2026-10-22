// Natives of primitive values (the definitions of tstst's lib/pure that tstc
// implements natively): integers, floats, strings, tuples, hashes.
// Integers are bigint literals (int64); floats the bigint of their IEEE 754
// bits (any NaN result is math.NaN()); strings hold bytes.
#include "lib.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>

int64_t gi_slow(V t) {
  switch (kind(t)) {
  case K_INT: return int_val(t);
  case K_NUMLIT: return (int64_t)num_val(t);
  case K_TRUE: return 1;
  case K_FALSE: return 0;
  default: die("expected an integer, got %s", ty_to_cstr_short(t));
  }
}

double gf(V t) {
  if (kind(t) != K_INT) die("expected a float, got %s", ty_to_cstr_short(t));
  int64_t b = int_val(t);
  double d;
  memcpy(&d, &b, 8);
  return d;
}

// NaN results are the quiet NaN with no payload, as lib/pure's softfloat
// (Go's runtime/softfloat64.go nan64) makes them
V fl(double d) {
  if (isnan(d)) return mk_int(INT64_C(0x7FF8000000000000));
  int64_t b;
  memcpy(&b, &d, 8);
  return mk_int(b);
}

Str *gs_slow(V t) {
  if (kind(t) != K_STRLIT) die("expected a string, got %s", ty_to_cstr_short(t));
  return as_str(t);
}

bool gb_slow(V t) {
  if (t == V_TRUE) return true;
  if (t == V_FALSE) return false;
  die("expected a boolean, got %s", ty_to_cstr_short(t));
}

// float64 -> int64 as lib/pure's softfloat (Go's f64toint64): truncation;
// NaN, ±Inf and |d| >= 2^64 give 0; 2^63 <= |d| < 2^64 wraps (the magnitude
// as uint64, reinterpreted, then negated for negative d)
static int64_t d2i(double d) {
  if (isnan(d) || isinf(d)) return 0;
  double a = fabs(d);
  if (a < 9223372036854775808.0) return (int64_t)d;
  if (a >= 18446744073709551616.0) return 0;
  uint64_t m = (uint64_t)a;
  return (int64_t)(d < 0 ? 0 - m : m);
}

static int64_t wrap_int(int64_t v, int64_t k) {
  switch (k) {
  case 32: return (int32_t)v;
  case -32: return v & INT64_C(0xFFFFFFFF);
  case 16: return (int16_t)v;
  case -16: return v & 0xFFFF;
  case 8: return (int8_t)v;
  case -8: return v & 0xFF;
  default: return v;
  }
}

static _Noreturn void divzero(void) { rt_error("integer divide by zero"); }

V n_iadd(V a, V b) { return mk_int((int64_t)((uint64_t)gi(a) + (uint64_t)gi(b))); }
V n_isub(V a, V b) { return mk_int((int64_t)((uint64_t)gi(a) - (uint64_t)gi(b))); }
V n_imul(V a, V b) { return mk_int((int64_t)((uint64_t)gi(a) * (uint64_t)gi(b))); }
V n_idiv(V a, V b) {
  int64_t x = gi(a), y = gi(b);
  if (y == 0) divzero();
  if (y == -1) return mk_int((int64_t)(0 - (uint64_t)x));
  return mk_int(x / y);
}
V n_irem(V a, V b) {
  int64_t x = gi(a), y = gi(b);
  if (y == 0) divzero();
  if (y == -1) return mk_int(0);
  return mk_int(x % y);
}
V n_iand(V a, V b) { return mk_int(gi(a) & gi(b)); }
V n_ior(V a, V b) { return mk_int(gi(a) | gi(b)); }
V n_ixor(V a, V b) { return mk_int(gi(a) ^ gi(b)); }
V n_iandnot(V a, V b) { return mk_int(gi(a) & ~gi(b)); }
V n_ishl(V a, V b) {
  int64_t s = gi(b);
  if (s < 0 || s >= 64) return mk_int(0);
  return mk_int((int64_t)((uint64_t)gi(a) << s));
}
V n_ishr(V a, V b) {
  int64_t s = gi(b), x = gi(a);
  if (s < 0 || s >= 64) return mk_int(x < 0 ? -1 : 0);
  return mk_int(x >> s);
}
V n_iushr(V a, V b) {
  int64_t s = gi(b);
  if (s < 0 || s >= 64) return mk_int(0);
  return mk_int((int64_t)((uint64_t)gi(a) >> s));
}
V n_ineg(V a) { return mk_int((int64_t)(0 - (uint64_t)gi(a))); }
V n_inot(V a) { return mk_int(~gi(a)); }
V n_ieq(V a, V b) { return mk_bool(gi(a) == gi(b)); }
V n_ine(V a, V b) { return mk_bool(gi(a) != gi(b)); }
V n_ilt(V a, V b) { return mk_bool(gi(a) < gi(b)); }
V n_ile(V a, V b) { return mk_bool(gi(a) <= gi(b)); }
V n_igt(V a, V b) { return mk_bool(gi(a) > gi(b)); }
V n_ige(V a, V b) { return mk_bool(gi(a) >= gi(b)); }
V n_iult(V a, V b) { return mk_bool((uint64_t)gi(a) < (uint64_t)gi(b)); }
V n_iule(V a, V b) { return mk_bool((uint64_t)gi(a) <= (uint64_t)gi(b)); }
V n_iugt(V a, V b) { return mk_bool((uint64_t)gi(a) > (uint64_t)gi(b)); }
V n_iuge(V a, V b) { return mk_bool((uint64_t)gi(a) >= (uint64_t)gi(b)); }
V n_iwrap(V a, V k) { return mk_int(wrap_int(gi(a), gi(k))); }
V n_udiv(V a, V b) {
  uint64_t y = (uint64_t)gi(b);
  if (y == 0) divzero();
  return mk_int((int64_t)((uint64_t)gi(a) / y));
}
V n_urem(V a, V b) {
  uint64_t y = (uint64_t)gi(b);
  if (y == 0) divzero();
  return mk_int((int64_t)((uint64_t)gi(a) % y));
}
V n_itoa(V a) { return (V)str_of_int(gi(a)); }
V n_uitoa(V a) { return (V)str_of_uint((uint64_t)gi(a)); }

// floats
V n_i2f(V a) { return fl((double)gi(a)); }
V n_u2f(V a) { return fl((double)(uint64_t)gi(a)); }
V n_f2i(V a) { return mk_int(d2i(gf(a))); }
// as softfloat's f64touint64: below 2^63 (NaN is not) the int64
// conversion, else that of d - 2^63 with the top bit set
V n_f2u(V a) {
  double d = gf(a);
  if (d < 9223372036854775808.0) return mk_int(d2i(d));
  return mk_int((int64_t)((uint64_t)d2i(d - 9223372036854775808.0) | (UINT64_C(1) << 63)));
}
V n_fadd(V a, V b) { return fl(gf(a) + gf(b)); }
V n_fsub(V a, V b) { return fl(gf(a) - gf(b)); }
V n_fmul(V a, V b) { return fl(gf(a) * gf(b)); }
V n_fdiv(V a, V b) { return fl(gf(a) / gf(b)); }
V n_feq(V a, V b) { return mk_bool(gf(a) == gf(b)); }
V n_flt(V a, V b) { return mk_bool(gf(a) < gf(b)); }
V n_fle(V a, V b) { return mk_bool(gf(a) <= gf(b)); }
V n_fne(V a, V b) { return mk_bool(gf(a) != gf(b)); }
V n_fneg(V a) { return mk_int(gi(a) ^ INT64_MIN); }
V n_f2bits(V a) { return a; }
V n_bits2f(V a) { return a; }
V n_fround32(V a) { return fl((double)(float)gf(a)); }
V n_f32bits(V a) {
  if (isnan(gf(a))) return mk_int(0x7FC00000);  // softfloat's nan32
  float f = (float)gf(a);
  uint32_t u;
  memcpy(&u, &f, 4);
  return mk_int((int64_t)u);
}
V n_bits2f32(V a) {
  uint32_t u = (uint32_t)gi(a);
  float f;
  memcpy(&f, &u, 4);
  return fl((double)f);
}
V n_ffloor(V a) { return fl(floor(gf(a))); }
V n_fsqrt(V a) { return fl(sqrt(gf(a))); }
V n_isnan(V a) { return mk_bool(isnan(gf(a))); }
V n_ftoa(V a) { return (V)str_of_number(gf(a)); }

// ---------------------------------------------------------------------------
// Strings (of bytes)

void utf8_put(SB *b, int64_t r) {
  uint32_t c = (r < 0 || r > 0x10FFFF || (r >= 0xD800 && r <= 0xDFFF)) ? 0xFFFD : (uint32_t)r;
  if (c < 0x80) {
    sb_put(b, (uint16_t)c);
  } else if (c < 0x800) {
    sb_put(b, (uint16_t)(0xC0 | (c >> 6)));
    sb_put(b, (uint16_t)(0x80 | (c & 0x3F)));
  } else if (c < 0x10000) {
    sb_put(b, (uint16_t)(0xE0 | (c >> 12)));
    sb_put(b, (uint16_t)(0x80 | ((c >> 6) & 0x3F)));
    sb_put(b, (uint16_t)(0x80 | (c & 0x3F)));
  } else {
    sb_put(b, (uint16_t)(0xF0 | (c >> 18)));
    sb_put(b, (uint16_t)(0x80 | ((c >> 12) & 0x3F)));
    sb_put(b, (uint16_t)(0x80 | ((c >> 6) & 0x3F)));
    sb_put(b, (uint16_t)(0x80 | (c & 0x3F)));
  }
}

// Go's utf8.DecodeRuneInString at i: the rune, *size its length
int64_t utf8_decode_at(Str *s, int32_t i, int32_t *size) {
  int32_t n = s->len - i;
  const uint16_t *d = str_d(s);
  if (n <= 0) {
    *size = 0;
    return 0xFFFD;
  }
  uint32_t c0 = d[i];
  if (c0 < 0x80) {
    *size = 1;
    return c0;
  }
#define CONT(k) (i + (k) < s->len && (d[i + (k)] & 0xC0) == 0x80 ? (int)(d[i + (k)] & 0x3F) : -1)
  *size = 1;
  if (c0 >= 0xC2 && c0 < 0xE0) {
    int c1 = CONT(1);
    if (c1 < 0) return 0xFFFD;
    *size = 2;
    return ((c0 & 0x1F) << 6) | (uint32_t)c1;
  }
  if (c0 >= 0xE0 && c0 < 0xF0) {
    int c1 = CONT(1), c2 = CONT(2);
    if (c1 < 0 || c2 < 0) return 0xFFFD;
    uint32_t r = ((c0 & 0x0F) << 12) | ((uint32_t)c1 << 6) | (uint32_t)c2;
    if (r < 0x800 || (r >= 0xD800 && r <= 0xDFFF)) return 0xFFFD;
    *size = 3;
    return r;
  }
  if (c0 >= 0xF0 && c0 < 0xF5) {
    int c1 = CONT(1), c2 = CONT(2), c3 = CONT(3);
    if (c1 < 0 || c2 < 0 || c3 < 0) return 0xFFFD;
    uint32_t r = ((c0 & 0x07) << 18) | ((uint32_t)c1 << 12) | ((uint32_t)c2 << 6) | (uint32_t)c3;
    if (r < 0x10000 || r > 0x10FFFF) return 0xFFFD;
    *size = 4;
    return r;
  }
#undef CONT
  return 0xFFFD;
}

V n_slen(V s) { return mk_int(gs(s)->len); }
V n_sat(V sv, V iv) {
  Str *s = gs(sv);
  int64_t i = gi(iv);
  if (i < 0 || i >= s->len) rt_error("index out of range [%lld] with length %d", (long long)i, s->len);
  return mk_int(str_d(s)[i]);
}
V n_sslice(V sv, V lov, V hiv) {
  Str *s = gs(sv);
  int64_t lo = gi(lov), hi = gi(hiv);
  if (lo < 0 || hi > s->len || lo > hi)
    rt_error("slice bounds out of range [%lld:%lld] with length %d", (long long)lo, (long long)hi, s->len);
  return (V)str_slice(s, (int32_t)lo, (int32_t)hi);
}
V n_scat(V a, V b) { return (V)str_concat(gs(a), gs(b)); }
V n_seq(V a, V b) { return mk_bool(str_eq(gs(a), gs(b))); }
V n_scmp(V a, V b) { return mk_int(str_cmp(gs(a), gs(b))); }
V n_slt(V a, V b) { return mk_bool(str_cmp(gs(a), gs(b)) < 0); }
V n_runestr(V r) {
  SB b = {0};
  utf8_put(&b, gi(r));
  return (V)sb_finish(&b);
}
VPair n_decoderune(V sv, V iv) {
  int32_t n;
  int64_t r = utf8_decode_at(gs(sv), (int32_t)gi(iv), &n);
  return PAIR(mk_int(r), mk_int(n));
}
V n_sindexbyte(V sv, V cv) {
  Str *s = gs(sv);
  uint16_t c = (uint16_t)(gi(cv) & 0xFF);
  const uint16_t *d = str_d(s);
  for (int32_t i = 0; i < s->len; i++)
    if (d[i] == c) return mk_int(i);
  return mk_int(-1);
}
V n_sindex(V sv, V sub) {
  Str *s = gs(sv);
  return mk_int(str_index(s, gs(sub), 0, s->len));
}
V n_scountbyte(V sv, V cv) {
  Str *s = gs(sv);
  uint16_t c = (uint16_t)(gi(cv) & 0xFF);
  const uint16_t *d = str_d(s);
  int64_t n = 0;
  for (int32_t i = 0; i < s->len; i++) n += d[i] == c;
  return mk_int(n);
}
// the strings of one byte are shared: static (never appended to in place)
static uint16_t byte_units[256];
static StrBuf byte_bufs[256];
static Str byte_strs[256];

V n_bytestr(V cv) {
  uint16_t c = (uint16_t)(gi(cv) & 0xFF);
  Str *s = &byte_strs[c];
  if (!s->buf) {
    byte_units[c] = c;
    byte_bufs[c] = (StrBuf){1, -1, &byte_units[c]};
    *s = (Str){K_STRLIT, 0, 0, 1, &byte_bufs[c]};
  }
  return (V)s;
}

// ---------------------------------------------------------------------------
// Tuples, equality, interfaces, hashes

static __attribute__((noinline)) V tget_slow(V t, V iv) {
  if (kind(t) != K_TUPLE) die("tget: expected a tuple, got %s", ty_to_cstr_short(t));
  TupT *tp = as_tup(t);
  int64_t i = gi(iv);
  if (i < 0 || i >= tp->len) die("tget: index %lld out of range", (long long)i);
  return tp->e[i];
}

V n_tget(V t, V iv) {
  // the common case first: a tuple, an immediate index in range
  if ((t & 3) == 0 && ((Hdr *)t)->tag == K_TUPLE && (iv & 1)) {
    uint64_t i = (uint64_t)int_val(iv);
    if (i < ((TupT *)t)->len) return ((TupT *)t)->e[i];
  }
  return tget_slow(t, iv);
}

V n_tset(V t, V iv, V x) {
  if (kind(t) != K_TUPLE) die("tset: expected a tuple, got %s", ty_to_cstr_short(t));
  TupT *tp = as_tup(t);
  int64_t i = gi(iv);
  TupT *r = tup_alloc(tp->len);
  for (uint32_t j = 0; j < tp->len; j++) r->e[j] = (int64_t)j == i ? x : tp->e[j];
  return (V)r;
}

uint32_t key_hash(V t) {
  switch (kind(t)) {
  case K_INT: {
    uint64_t u = (uint64_t)int_val(t) * UINT64_C(0x9E3779B97F4A7C15);
    return (uint32_t)(u >> 32);
  }
  case K_STRLIT: return str_hash(as_str(t));
  case K_NUMLIT: {
    double d = num_val(t);
    uint64_t u;
    memcpy(&u, &d, 8);
    return (uint32_t)(u ^ (u >> 32));
  }
  case K_TRUE: return 1;
  case K_FALSE: return 2;
  case K_NULL: return 3;
  case K_UNDEFINED: return 4;
  case K_TUPLE: {
    TupT *tp = as_tup(t);
    uint32_t h = 17 + tp->len;
    for (uint32_t i = 0; i < tp->len; i++) h = h * 31 + key_hash(tp->e[i]);
    return h;
  }
  default: return 5;
  }
}

bool key_eq(V a, V b) {
  if (a == b) return true;
  int ka = kind(a), kb = kind(b);
  if (ka == K_INT && kb == K_INT) return int_val(a) == int_val(b);
  if (ka == K_STRLIT && kb == K_STRLIT) return str_eq(as_str(a), as_str(b));
  if (ka == K_TUPLE && kb == K_TUPLE) {
    TupT *x = as_tup(a), *y = as_tup(b);
    if (x->len != y->len) return false;
    for (uint32_t i = 0; i < x->len; i++)
      if (!key_eq(x->e[i], y->e[i])) return false;
    return true;
  }
  return ty_eq(a, b);
}

// (two integers, or an integer and nil, compare as words)
V n_geq(V a, V b) {
  if (a == b) return V_TRUE;
  if ((a & b & 1) || ((a & 1) && b == V_NULL) || ((b & 1) && a == V_NULL)) return V_FALSE;
  return mk_bool(key_eq(a, b));
}
V n_gne(V a, V b) {
  if (a == b) return V_FALSE;
  if ((a & b & 1) || ((a & 1) && b == V_NULL) || ((b & 1) && a == V_NULL)) return V_TRUE;
  return mk_bool(!key_eq(a, b));
}
V n_bnot(V b) { return mk_bool(!gb(b)); }

// a Go runtime error (lib/pure rterr.ts): a failure with the message as Go's,
// without "runtime error: " (the program's handler adds it, @catch)
V n_rterr(V msg) {
  char *m = kind(msg) == K_STRLIT ? str_to_utf8(as_str(msg), NULL) : ty_to_cstr(msg);
  rt_error("%s", m);
}

// natively a failing operation does not return, so every result is one
// (gen.mbt makes calls of it the constant)
V n_rtok(V x) {
  (void)x;
  return V_TRUE;
}

V n_nilchk(V p) {
  if (p == V_NULL) rt_error("panic: invalid memory address or nil pointer dereference");
  return p;
}

V n_ta1(V x, V id) {
  if ((x & 3) == 0 && x && ((Hdr *)x)->tag == K_TUPLE && ((TupT *)x)->len >= 2 && (id & 1) && ((TupT *)x)->e[0] == id)
    return ((TupT *)x)->e[1];
  if (x == V_NULL) rt_error("panic: interface conversion: interface is nil");
  if (kind(x) == K_TUPLE && as_tup(x)->len >= 2 && gi(as_tup(x)->e[0]) == gi(id)) return as_tup(x)->e[1];
  rt_error("panic: interface conversion: wrong type");
}

VPair n_ta2(V x, V id, V z) {
  if (kind(x) == K_TUPLE && as_tup(x)->len >= 2 && gi(as_tup(x)->e[0]) == gi(id))
    return PAIR(as_tup(x)->e[1], V_TRUE);
  return PAIR(z, V_FALSE);
}

V n_panic(V msg) {
  char *m = kind(msg) == K_STRLIT ? str_to_utf8(as_str(msg), NULL) : ty_to_cstr(msg);
  rt_error("panic: %s", m);
}

// XXH3-128 (seed 0, the default secret), the hash of github.com/zeebo/xxh3's
// HashString128, which lib/pure's shash128 implements: Hash128 results show up
// in output (the file versions of .tsbuildinfo)
static const uint8_t xxh3_key[192] = {
  0xb8, 0xfe, 0x6c, 0x39, 0x23, 0xa4, 0x4b, 0xbe, 0x7c, 0x01, 0x81, 0x2c, 0xf7, 0x21, 0xad, 0x1c,
  0xde, 0xd4, 0x6d, 0xe9, 0x83, 0x90, 0x97, 0xdb, 0x72, 0x40, 0xa4, 0xa4, 0xb7, 0xb3, 0x67, 0x1f,
  0xcb, 0x79, 0xe6, 0x4e, 0xcc, 0xc0, 0xe5, 0x78, 0x82, 0x5a, 0xd0, 0x7d, 0xcc, 0xff, 0x72, 0x21,
  0xb8, 0x08, 0x46, 0x74, 0xf7, 0x43, 0x24, 0x8e, 0xe0, 0x35, 0x90, 0xe6, 0x81, 0x3a, 0x26, 0x4c,
  0x3c, 0x28, 0x52, 0xbb, 0x91, 0xc3, 0x00, 0xcb, 0x88, 0xd0, 0x65, 0x8b, 0x1b, 0x53, 0x2e, 0xa3,
  0x71, 0x64, 0x48, 0x97, 0xa2, 0x0d, 0xf9, 0x4e, 0x38, 0x19, 0xef, 0x46, 0xa9, 0xde, 0xac, 0xd8,
  0xa8, 0xfa, 0x76, 0x3f, 0xe3, 0x9c, 0x34, 0x3f, 0xf9, 0xdc, 0xbb, 0xc7, 0xc7, 0x0b, 0x4f, 0x1d,
  0x8a, 0x51, 0xe0, 0x4b, 0xcd, 0xb4, 0x59, 0x31, 0xc8, 0x9f, 0x7e, 0xc9, 0xd9, 0x78, 0x73, 0x64,
  0xea, 0xc5, 0xac, 0x83, 0x34, 0xd3, 0xeb, 0xc3, 0xc5, 0x81, 0xa0, 0xff, 0xfa, 0x13, 0x63, 0xeb,
  0x17, 0x0d, 0xdd, 0x51, 0xb7, 0xf0, 0xda, 0x49, 0xd3, 0x16, 0x55, 0x26, 0x29, 0xd4, 0x68, 0x9e,
  0x2b, 0x16, 0xbe, 0x58, 0x7d, 0x47, 0xa1, 0xfc, 0x8f, 0xf8, 0xb8, 0xd1, 0x7a, 0xd0, 0x31, 0xce,
  0x45, 0xcb, 0x3a, 0x8f, 0x95, 0x16, 0x04, 0x28, 0xaf, 0xd7, 0xfb, 0xca, 0xbb, 0x4b, 0x40, 0x7e,
};
#define XP32_1 UINT64_C(2654435761)
#define XP32_2 UINT64_C(2246822519)
#define XP32_3 UINT64_C(3266489917)
#define XP64_1 UINT64_C(11400714785074694791)
#define XP64_2 UINT64_C(14029467366897019727)
#define XP64_3 UINT64_C(1609587929392839161)
#define XP64_4 UINT64_C(9650029242287828579)
#define XP64_5 UINT64_C(2870177450012600261)

// bytes of a Go string (one per code unit)
static uint64_t xr64(const uint16_t *d, int64_t o) {
  uint64_t v = 0;
  for (int i = 7; i >= 0; i--) v = v << 8 | (uint8_t)d[o + i];
  return v;
}
static uint64_t xr32(const uint16_t *d, int64_t o) {
  uint64_t v = 0;
  for (int i = 3; i >= 0; i--) v = v << 8 | (uint8_t)d[o + i];
  return v;
}
static uint64_t xk64(int o) {
  uint64_t v = 0;
  for (int i = 7; i >= 0; i--) v = v << 8 | xxh3_key[o + i];
  return v;
}
static uint64_t xmulfold(uint64_t x, uint64_t y) {
  unsigned __int128 p = (unsigned __int128)x * y;
  return (uint64_t)(p >> 64) ^ (uint64_t)p;
}
static uint64_t xaval(uint64_t x) {
  x ^= x >> 37;
  x *= UINT64_C(0x165667919e3779f9);
  return x ^ (x >> 32);
}
static uint64_t xaval_small(uint64_t x) {
  x *= XP64_2;
  x ^= x >> 29;
  x *= XP64_3;
  return x ^ (x >> 32);
}
// one 16-byte step of the 17-240 byte paths: input at i, secret at k
static void xmix32(uint64_t *hi, uint64_t *lo, const uint16_t *d, int64_t a, int64_t b, int ka, int kb) {
  uint64_t a0 = xr64(d, a), a1 = xr64(d, a + 8), b0 = xr64(d, b), b1 = xr64(d, b + 8);
  *lo += xmulfold(a0 ^ xk64(ka), a1 ^ xk64(ka + 8));
  *lo ^= b0 + b1;
  *hi += xmulfold(b0 ^ xk64(kb), b1 ^ xk64(kb + 8));
  *hi ^= a0 + a1;
}
static void xstripe(uint64_t *acc, const uint16_t *d, int64_t p, int k) {
  for (int i = 0; i < 8; i++) {
    uint64_t v = xr64(d, p + 8 * i), dk = v ^ xk64(k + 8 * i);
    acc[i ^ 1] += v;
    acc[i] += (dk & 0xFFFFFFFF) * (dk >> 32);
  }
}

VPair n_shash128(V sv) {
  Str *s = gs(sv);
  const uint16_t *d = str_d(s);
  int64_t l = s->len;
  uint64_t hi = 0, lo = 0, ul = (uint64_t)l;
  if (l <= 16) {
    if (l > 8) {
      uint64_t ilo = xr64(d, 0), ihi = xr64(d, l - 8);
      unsigned __int128 m = (unsigned __int128)(ilo ^ ihi ^ xk64(32) ^ xk64(40)) * XP64_1;
      uint64_t mh = (uint64_t)(m >> 64), ml = (uint64_t)m;
      ml += (ul - 1) << 54;
      ihi ^= xk64(48) ^ xk64(56);
      mh += ihi + (ihi & 0xFFFFFFFF) * (XP32_2 - 1);
      ml ^= __builtin_bswap64(mh);
      unsigned __int128 r = (unsigned __int128)ml * XP64_2;
      hi = (uint64_t)(r >> 64) + mh * XP64_2;
      lo = (uint64_t)r;
      return PAIR(mk_int((int64_t)xaval(hi)), mk_int((int64_t)xaval(lo)));
    }
    if (l > 3) {
      uint64_t in = xr32(d, 0) + (xr32(d, l - 4) << 32);
      unsigned __int128 r = (unsigned __int128)(in ^ xk64(16) ^ xk64(24)) * (XP64_1 + (ul << 2));
      hi = (uint64_t)(r >> 64);
      lo = (uint64_t)r;
      hi += lo << 1;
      lo ^= hi >> 3;
      lo ^= lo >> 35;
      lo *= UINT64_C(0x9fb21c651e98df25);
      lo ^= lo >> 28;
      return PAIR(mk_int((int64_t)xaval(hi)), mk_int((int64_t)lo));
    }
    if (l == 0) return PAIR(mk_int((int64_t)UINT64_C(0x99aa06d3014798d8)), mk_int((int64_t)UINT64_C(0x6001c324468d497f)));
    uint64_t c1 = (uint8_t)d[0], c2 = (uint8_t)d[l >> 1], c3 = (uint8_t)d[l - 1];
    // (c1 << 16) | (c2 << 24) | c3 | (len << 8), as zeebo/xxh3 computes it
    lo = (c1 << 16) | (c2 << 24) | c3 | (ul << 8);
    uint32_t w = __builtin_bswap32((uint32_t)lo);
    hi = (uint64_t)((w << 13) | (w >> 19));
    lo ^= (uint64_t)(UINT32_C(0xbe4ba423) ^ UINT32_C(0x396cfeb8));
    hi ^= (uint64_t)(UINT32_C(0x1cad21f7) ^ UINT32_C(0x2c81017c));
    return PAIR(mk_int((int64_t)xaval_small(hi)), mk_int((int64_t)xaval_small(lo)));
  }
  if (l <= 128) {
    lo = ul * XP64_1;
    int64_t n = (l - 1) / 32;  // pairs of 16-byte steps from both ends
    for (int64_t i = n; i >= 0; i--)
      xmix32(&hi, &lo, d, 16 * i, l - 16 * (i + 1), 32 * (int)i, 32 * (int)i + 16);
    uint64_t h = lo * XP64_1 + hi * XP64_4 + ul * XP64_2, g = hi + lo;
    return PAIR(mk_int((int64_t)(0 - xaval(h))), mk_int((int64_t)xaval(g)));
  }
  if (l <= 240) {
    lo = ul * XP64_1;
    for (int i = 0; i < 4; i++) xmix32(&hi, &lo, d, 32 * i, 32 * i + 16, 32 * i, 32 * i + 16);
    hi = xaval(hi);
    lo = xaval(lo);
    for (int64_t i = 128; i < (l & ~(int64_t)31); i += 32)
      xmix32(&hi, &lo, d, i, i + 16, (int)i - 125, (int)i - 109);
    // the last 32 bytes, read from the end
    xmix32(&hi, &lo, d, l - 16, l - 32, 103, 119);
    uint64_t h = lo * XP64_1 + hi * XP64_4 + ul * XP64_2, g = hi + lo;
    return PAIR(mk_int((int64_t)(0 - xaval(h))), mk_int((int64_t)xaval(g)));
  }
  uint64_t acc[8] = {XP32_3, XP64_1, XP64_2, XP64_3, XP64_4, XP32_2, XP64_5, XP32_1};
  int64_t nb = (l - 1) / 1024, p = 0;
  for (int64_t b = 0; b < nb; b++, p += 1024) {
    for (int i = 0; i < 16; i++) xstripe(acc, d, p + 64 * i, 8 * i);
    for (int i = 0; i < 8; i++) {
      acc[i] ^= acc[i] >> 47;
      acc[i] ^= xk64(128 + 8 * i);
      acc[i] *= XP32_1;
    }
  }
  int64_t ns = (l - 1 - p) / 64;
  for (int64_t i = 0; i < ns; i++) xstripe(acc, d, p + 64 * i, 8 * (int)i);
  xstripe(acc, d, l - 64, 121);
  lo = ul * XP64_1;
  hi = ~(ul * XP64_2);
  for (int i = 0; i < 4; i++) {
    lo += xmulfold(acc[2 * i] ^ xk64(11 + 16 * i), acc[2 * i + 1] ^ xk64(19 + 16 * i));
    hi += xmulfold(acc[2 * i] ^ xk64(117 + 16 * i), acc[2 * i + 1] ^ xk64(125 + 16 * i));
  }
  return PAIR(mk_int((int64_t)xaval(hi)), mk_int((int64_t)xaval(lo)));
}

V n_shash64(V sv) {
  Str *s = gs(sv);
  const uint16_t *d = str_d(s);
  uint64_t a = UINT64_C(0xCBF29CE484222325);
  for (int32_t i = 0; i < s->len; i++) a = (a ^ d[i]) * UINT64_C(0x100000001B3);
  a = a ^ (a >> 33);
  return mk_int((int64_t)(a * UINT64_C(0xFF51AFD7ED558CCD)));
}
