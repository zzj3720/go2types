// Files and processes for the compiler.
#define _XOPEN_SOURCE 700
#define _DARWIN_C_SOURCE
#include <moonbit.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/resource.h>
#include <string.h>
#include <time.h>

static char *cpath(moonbit_bytes_t b) {
  int n = Moonbit_array_length(b);
  char *p = malloc(n + 1);
  memcpy(p, b, n);
  p[n] = 0;
  return p;
}

MOONBIT_EXPORT moonbit_bytes_t tstc_read_file(moonbit_bytes_t path) {
  char *p = cpath(path);
  FILE *f = fopen(p, "rb");
  if (!f) {
    free(p);
    return moonbit_make_bytes(0, 0);
  }
  fseek(f, 0, SEEK_END);
  long len = ftell(f);
  fseek(f, 0, SEEK_SET);
  // (a MoonBit object holds fewer than 2^28 elements: larger files are
  // read as sources, tstc_src_read)
  if (len >= ((long)1 << 28)) {
    fprintf(stderr, "tstc: %s: too large to read at once (%ld bytes)\n", p, len);
    exit(1);
  }
  free(p);
  moonbit_bytes_t b = moonbit_make_bytes((int32_t)len, 0);
  if (len > 0 && fread(b, 1, len, f) != (size_t)len) len = 0;
  fclose(f);
  return b;
}

MOONBIT_EXPORT int tstc_file_exists(moonbit_bytes_t path) {
  char *p = cpath(path);
  FILE *f = fopen(p, "rb");
  free(p);
  if (!f) return 0;
  fclose(f);
  return 1;
}

MOONBIT_EXPORT int tstc_write_file(moonbit_bytes_t path, moonbit_bytes_t data) {
  char *p = cpath(path);
  FILE *f = fopen(p, "wb");
  free(p);
  if (!f) return 0;
  fwrite(data, 1, Moonbit_array_length(data), f);
  fclose(f);
  return 1;
}

MOONBIT_EXPORT void tstc_write_out(int fd, moonbit_bytes_t data) {
  FILE *f = fd == 2 ? stderr : stdout;
  fwrite(data, 1, Moonbit_array_length(data), f);
  fflush(f);
}

MOONBIT_EXPORT int tstc_system(moonbit_bytes_t cmd) {
  char *c = cpath(cmd);
  int rc = system(c);
  free(c);
  return rc;
}

MOONBIT_EXPORT void tstc_exit(int code) {
  fflush(stdout);
  fflush(stderr);
  exit(code);
}

// TSTC_CPU_TIME=1: the phases are timed in CPU time of the process (user +
// system), which a loaded machine does not inflate
MOONBIT_EXPORT double tstc_now_ms(void) {
  static int cpu = -1;
  if (cpu < 0) cpu = getenv("TSTC_CPU_TIME") != NULL;
  if (cpu) {
    struct rusage ru;
    getrusage(RUSAGE_SELF, &ru);
    return (ru.ru_utime.tv_sec + ru.ru_stime.tv_sec) * 1000.0 + (ru.ru_utime.tv_usec + ru.ru_stime.tv_usec) / 1000.0;
  }
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}

// ---------------------------------------------------------------------------
// TSTC_SELF_PROF=<path>: a sampling profile of the compiler itself. Every
// millisecond of CPU time the program counter and the return addresses of up
// to 48 frame records; at exit <path> gets them (hex, one sample per line)
// after a line with the address of main (scripts/selfprof.py symbolizes).

#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <sys/time.h>
#include <sys/ucontext.h>

int main(int argc, char **argv);

#define PROF_DEPTH 48
static uintptr_t *prof_buf;
static size_t prof_n, prof_cap;
static const char *prof_path;
static uintptr_t prof_lo, prof_hi;

static void prof_on(int sig, siginfo_t *si, void *ctx) {
  (void)sig;
  (void)si;
  if (prof_n + PROF_DEPTH + 1 > prof_cap) return;
  ucontext_t *uc = ctx;
#if defined(__aarch64__)
  uintptr_t pc = (uintptr_t)uc->uc_mcontext->__ss.__pc, lr = (uintptr_t)uc->uc_mcontext->__ss.__lr;
  uintptr_t fp = (uintptr_t)uc->uc_mcontext->__ss.__fp;
#else
  uintptr_t pc = (uintptr_t)uc->uc_mcontext->__ss.__rip, lr = 0;
  uintptr_t fp = (uintptr_t)uc->uc_mcontext->__ss.__rbp;
#endif
  size_t start = prof_n++;
  prof_buf[prof_n++] = pc;
  prof_buf[prof_n++] = lr;
  int k = 2;
  while (k < PROF_DEPTH && fp >= prof_lo && fp + 16 <= prof_hi && (fp & 7) == 0) {
    prof_buf[prof_n++] = ((uintptr_t *)fp)[1];
    uintptr_t up = ((uintptr_t *)fp)[0];
    if (up <= fp) break;
    fp = up;
    k++;
  }
  prof_buf[start] = (uintptr_t)k;
}

static void prof_dump(void) {
  struct itimerval off = {{0, 0}, {0, 0}};
  setitimer(ITIMER_PROF, &off, NULL);
  FILE *f = fopen(prof_path, "w");
  if (!f) return;
  fprintf(f, "main %lx\n", (unsigned long)(uintptr_t)&main);
  for (size_t i = 0; i < prof_n;) {
    size_t k = prof_buf[i++];
    for (size_t j = 0; j < k; j++) fprintf(f, j ? " %lx" : "%lx", (unsigned long)prof_buf[i + j]);
    fputc('\n', f);
    i += k;
  }
  fclose(f);
}

__attribute__((constructor)) static void prof_init(void) {
  prof_path = getenv("TSTC_SELF_PROF");
  if (!prof_path) return;
  prof_cap = (size_t)1 << 26;
  prof_buf = malloc(prof_cap * sizeof *prof_buf);
  if (!prof_buf) return;
  pthread_t t = pthread_self();
#ifdef __APPLE__
  prof_hi = (uintptr_t)pthread_get_stackaddr_np(t);
  prof_lo = prof_hi - pthread_get_stacksize_np(t);
#endif
  struct sigaction sa;
  sa.sa_sigaction = prof_on;
  sa.sa_flags = SA_SIGINFO | SA_RESTART;
  sigemptyset(&sa.sa_mask);
  sigaction(SIGPROF, &sa, NULL);
  atexit(prof_dump);
  struct itimerval it = {{0, 1000}, {0, 1000}};
  setitimer(ITIMER_PROF, &it, NULL);
}

// ---------------------------------------------------------------------------
// Text buffers of the code generator (UTF-8, outside the MoonBit heap), their
// content hashes, and the files of the module cache.

#include <sys/stat.h>
#include <sys/time.h>
#include <stdint.h>
#ifdef __APPLE__
#include <CommonCrypto/CommonDigest.h>
#endif

typedef struct { char *d; size_t n, cap; } TBuf;
static TBuf *tbufs;
static int ntbufs, captbufs;
static int *tfree;
static int ntfree, captfree;

MOONBIT_EXPORT int tstc_buf_new(void) {
  if (ntfree > 0) return tfree[--ntfree];
  if (ntbufs == captbufs) {
    captbufs = captbufs ? captbufs * 2 : 1024;
    tbufs = realloc(tbufs, sizeof(TBuf) * captbufs);
  }
  tbufs[ntbufs].d = NULL;
  tbufs[ntbufs].n = tbufs[ntbufs].cap = 0;
  return ntbufs++;
}

static char *tbuf_room(TBuf *b, size_t k) {
  if (b->n + k > b->cap) {
    size_t c = b->cap ? b->cap * 2 : 256;
    while (c < b->n + k) c *= 2;
    b->d = realloc(b->d, c);
    b->cap = c;
  }
  return b->d + b->n;
}

// UTF-16 code units as UTF-8
static void tbuf_utf16(TBuf *b, const uint16_t *s, int32_t n) {
  char *o = tbuf_room(b, (size_t)n * 3);
  char *p = o;
  for (int32_t i = 0; i < n; i++) {
    uint32_t c = s[i];
    if (c < 0x80) {
      *p++ = (char)c;
      continue;
    }
    if (c >= 0xD800 && c <= 0xDBFF && i + 1 < n && s[i + 1] >= 0xDC00 && s[i + 1] <= 0xDFFF) {
      c = 0x10000 + ((c - 0xD800) << 10) + (s[i + 1] - 0xDC00);
      i++;
      // 4 bytes from two units (room: 6)
      *p++ = (char)(0xF0 | (c >> 18));
      *p++ = (char)(0x80 | ((c >> 12) & 0x3F));
      *p++ = (char)(0x80 | ((c >> 6) & 0x3F));
      *p++ = (char)(0x80 | (c & 0x3F));
    } else if (c < 0x800) {
      *p++ = (char)(0xC0 | (c >> 6));
      *p++ = (char)(0x80 | (c & 0x3F));
    } else {
      *p++ = (char)(0xE0 | (c >> 12));
      *p++ = (char)(0x80 | ((c >> 6) & 0x3F));
      *p++ = (char)(0x80 | (c & 0x3F));
    }
  }
  b->n += (size_t)(p - o);
}

MOONBIT_EXPORT void tstc_buf_str(int h, moonbit_string_t s) {
  tbuf_utf16(&tbufs[h], s, Moonbit_array_length(s));
}

// an instruction: "  " s "\n"
MOONBIT_EXPORT void tstc_buf_line(int h, moonbit_string_t s) {
  TBuf *b = &tbufs[h];
  char *p = tbuf_room(b, 2);
  p[0] = ' ';
  p[1] = ' ';
  b->n += 2;
  tbuf_utf16(b, s, Moonbit_array_length(s));
  *tbuf_room(b, 1) = '\n';
  b->n += 1;
}

MOONBIT_EXPORT void tstc_buf_buf(int dst, int src) {
  TBuf *s = &tbufs[src];
  char *o = tbuf_room(&tbufs[dst], s->n);
  if (s->n) memcpy(o, s->d, s->n);
  tbufs[dst].n += s->n;
}

MOONBIT_EXPORT int64_t tstc_buf_len(int h) { return (int64_t)tbufs[h].n; }

// TSTC_BUF_STATS: the live buffers' count, text and capacity (stderr)
MOONBIT_EXPORT void tstc_buf_stats(void) {
  if (!getenv("TSTC_BUF_STATS")) return;
  size_t live = 0, n = 0, cap = 0, small = 0;
  for (int i = 0; i < ntbufs; i++)
    if (tbufs[i].d) {
      live++;
      n += tbufs[i].n;
      cap += tbufs[i].cap;
      if (tbufs[i].cap <= 4096) small++;
    }
  fprintf(stderr, "tstc: %zu buffers (%zu of at most 4 KB), %zu MB of text in %zu MB\n", live, small, n >> 20, cap >> 20);
}

// the most memory the process had (MB)
#include <sys/resource.h>
MOONBIT_EXPORT int tstc_max_rss_mb(void) {
  struct rusage ru;
  getrusage(RUSAGE_SELF, &ru);
#ifdef __APPLE__
  return (int)(ru.ru_maxrss >> 20);
#else
  return (int)(ru.ru_maxrss >> 10);
#endif
}

MOONBIT_EXPORT void tstc_buf_free(int h) {
  free(tbufs[h].d);
  tbufs[h].d = NULL;
  tbufs[h].n = tbufs[h].cap = 0;
  if (ntfree == captfree) {
    captfree = captfree ? captfree * 2 : 1024;
    tfree = realloc(tfree, sizeof(int) * captfree);
  }
  tfree[ntfree++] = h;
}

// the hex SHA-256 (first 128 bits) of the salt followed by the buffers
MOONBIT_EXPORT moonbit_bytes_t tstc_bufs_hash(int32_t *hs, moonbit_bytes_t salt) {
  unsigned char md[32];
  int32_t nh = Moonbit_array_length(hs);
#ifdef __APPLE__
  CC_SHA256_CTX cx;
  CC_SHA256_Init(&cx);
  CC_SHA256_Update(&cx, salt, (CC_LONG)Moonbit_array_length(salt));
  for (int32_t k = 0; k < nh; k++) {
    TBuf *b = &tbufs[hs[k]];
    size_t off = 0;
    while (off < b->n) {
      size_t m = b->n - off;
      if (m > (1u << 30)) m = 1u << 30;
      CC_SHA256_Update(&cx, b->d + off, (CC_LONG)m);
      off += m;
    }
  }
  CC_SHA256_Final(md, &cx);
#else
  // two FNV-1a lanes (no CommonCrypto)
  uint64_t a = 0xcbf29ce484222325ULL, c = 0x84222325cbf29ce4ULL;
  int32_t sn = Moonbit_array_length(salt);
  for (int32_t i = 0; i < sn; i++) { a = (a ^ salt[i]) * 0x100000001b3ULL; c = (c ^ salt[i]) * 0x100000001b3ULL; c ^= c >> 29; }
  for (int32_t k = 0; k < nh; k++) {
    TBuf *b = &tbufs[hs[k]];
    for (size_t i = 0; i < b->n; i++) { a = (a ^ (unsigned char)b->d[i]) * 0x100000001b3ULL; c = (c ^ (unsigned char)b->d[i]) * 0x100000001b3ULL; c ^= c >> 29; }
  }
  memset(md, 0, 32);
  memcpy(md, &a, 8);
  memcpy(md + 8, &c, 8);
#endif
  moonbit_bytes_t r = moonbit_make_bytes(32, 0);
  const char *hex = "0123456789abcdef";
  for (int i = 0; i < 16; i++) {
    r[2 * i] = hex[md[i] >> 4];
    r[2 * i + 1] = hex[md[i] & 15];
  }
  return r;
}

MOONBIT_EXPORT int tstc_bufs_write(int32_t *hs, moonbit_bytes_t path) {
  char *p = cpath(path);
  FILE *f = fopen(p, "wb");
  free(p);
  if (!f) return 0;
  int ok = 1;
  for (int32_t k = 0; k < Moonbit_array_length(hs); k++) {
    TBuf *b = &tbufs[hs[k]];
    if (b->n && fwrite(b->d, 1, b->n, f) != b->n) ok = 0;
  }
  if (fclose(f) != 0) ok = 0;
  return ok;
}

// marks a cache file used (its modification time is now)
MOONBIT_EXPORT void tstc_touch(moonbit_bytes_t path) {
  char *p = cpath(path);
  utimes(p, NULL);
  free(p);
}

MOONBIT_EXPORT void tstc_mkdir(moonbit_bytes_t path) {
  char *p = cpath(path);
  mkdir(p, 0755);
  free(p);
}

// ---------------------------------------------------------------------------
// The unit cache's files

MOONBIT_EXPORT int64_t tstc_file_size(moonbit_bytes_t path) {
  char *p = cpath(path);
  struct stat st;
  int r = stat(p, &st);
  free(p);
  return r == 0 ? (int64_t)st.st_size : -1;
}

// len bytes at off of a file, in a new buffer (-1: cannot)
MOONBIT_EXPORT int tstc_blob_read(moonbit_bytes_t path, int64_t off, int64_t len) {
  char *p = cpath(path);
  FILE *f = fopen(p, "rb");
  free(p);
  if (!f) return -1;
  int h = tstc_buf_new();
  TBuf *b = &tbufs[h];
  char *o = tbuf_room(b, (size_t)len);
  int ok = fseeko(f, (off_t)off, SEEK_SET) == 0 && fread(o, 1, (size_t)len, f) == (size_t)len;
  fclose(f);
  if (!ok) {
    tstc_buf_free(h);
    return -1;
  }
  tbufs[h].n = (size_t)len;
  return h;
}

// appends a buffer to a file: where it starts (-1: cannot)
MOONBIT_EXPORT int64_t tstc_blob_append(moonbit_bytes_t path, int h) {
  char *p = cpath(path);
  FILE *f = fopen(p, "ab");
  free(p);
  if (!f) return -1;
  fseeko(f, 0, SEEK_END);
  int64_t at = (int64_t)ftello(f);
  TBuf *b = &tbufs[h];
  int ok = b->n == 0 || fwrite(b->d, 1, b->n, f) == b->n;
  if (fclose(f) != 0) ok = 0;
  return ok ? at : -1;
}

MOONBIT_EXPORT int tstc_rename(moonbit_bytes_t a, moonbit_bytes_t b) {
  char *pa = cpath(a), *pb = cpath(b);
  int r = rename(pa, pb);
  free(pa);
  free(pb);
  return r == 0;
}

// the hex SHA-256 (128 bits) of this executable (unit cache keys: another
// compiler, other keys)
#ifdef __APPLE__
#include <mach-o/dyld.h>
#endif
MOONBIT_EXPORT moonbit_bytes_t tstc_self_hash(void) {
  char path[4096];
  uint32_t size = sizeof path;
  int h = -1;
#ifdef __APPLE__
  if (_NSGetExecutablePath(path, &size) == 0) {
#else
  ssize_t k = readlink("/proc/self/exe", path, sizeof path - 1);
  if (k > 0) {
    path[k] = 0;
#endif
    FILE *f = fopen(path, "rb");
    if (f) {
      fseeko(f, 0, SEEK_END);
      int64_t n = (int64_t)ftello(f);
      fclose(f);
      moonbit_bytes_t pb = moonbit_make_bytes((int32_t)strlen(path), 0);
      memcpy(pb, path, strlen(path));
      h = tstc_blob_read(pb, 0, n);
    }
  }
  if (h < 0) h = tstc_buf_new();
  int32_t *hs = (int32_t *)moonbit_make_int32_array(1, h);
  moonbit_bytes_t salt = moonbit_make_bytes(0, 0);
  moonbit_bytes_t r = tstc_bufs_hash(hs, salt);
  tstc_buf_free(h);
  return r;
}

// UTF-8 to a MoonBit string (as util.mbt's utf8_decode did: a BOM is
// skipped, a byte starting no sequence is U+FFFD)
static int32_t utf8_step(const uint8_t *b, int32_t n, int32_t i, uint32_t *cp) {
  uint32_t c = b[i];
  if (c < 0x80) {
    *cp = c;
    return 1;
  }
  if (c >= 0xC0 && c < 0xE0 && i + 1 < n) {
    *cp = ((c & 0x1F) << 6) | (b[i + 1] & 0x3F);
    return 2;
  }
  if (c >= 0xE0 && c < 0xF0 && i + 2 < n) {
    *cp = ((c & 0x0F) << 12) | ((uint32_t)(b[i + 1] & 0x3F) << 6) | (b[i + 2] & 0x3F);
    return 3;
  }
  if (c >= 0xF0 && i + 3 < n) {
    *cp = ((c & 0x07) << 18) | ((uint32_t)(b[i + 1] & 0x3F) << 12) | ((uint32_t)(b[i + 2] & 0x3F) << 6) | (b[i + 3] & 0x3F);
    return 4;
  }
  *cp = 0xFFFD;
  return 1;
}

MOONBIT_EXPORT moonbit_string_t tstc_utf8_decode(moonbit_bytes_t bytes) {
  const uint8_t *b = bytes;
  int32_t n = Moonbit_array_length(bytes);
  int32_t i0 = n >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF ? 3 : 0;
  int32_t units = 0;
  for (int32_t i = i0; i < n;) {
    uint32_t cp;
    i += utf8_step(b, n, i, &cp);
    units += cp >= 0x10000 ? 2 : 1;
  }
  moonbit_string_t s = moonbit_make_string_raw(units);
  int32_t k = 0;
  for (int32_t i = i0; i < n;) {
    uint32_t cp;
    i += utf8_step(b, n, i, &cp);
    if (cp >= 0x10000) {
      cp -= 0x10000;
      s[k++] = (uint16_t)(0xD800 + (cp >> 10));
      s[k++] = (uint16_t)(0xDC00 + (cp & 0x3FF));
    } else {
      s[k++] = (uint16_t)cp;
    }
  }
  return s;
}

MOONBIT_EXPORT moonbit_bytes_t tstc_file_hash(moonbit_bytes_t path) {
  int64_t n = tstc_file_size(path);
  int h = n >= 0 ? tstc_blob_read(path, 0, n) : -1;
  if (h < 0) return moonbit_make_bytes(0, 0);
  int32_t *hs = (int32_t *)moonbit_make_int32_array(1, h);
  moonbit_bytes_t r = tstc_bufs_hash(hs, moonbit_make_bytes(0, 0));
  tstc_buf_free(h);
  return r;
}

// The top-level chunks of a large go2types source (incr.mbt): pieces that
// start after a blank line at "/**", "export " or "type " (as
// next_decl_boundary splits large sources), with an FNV-1a hash of each.
// Returns 16 bytes per chunk: start, end (u32, little endian), hash (u64).
static moonbit_bytes_t chunks_of(const uint8_t *b, int64_t n);
MOONBIT_EXPORT moonbit_bytes_t tstc_chunks(moonbit_bytes_t b) {
  return chunks_of(b, Moonbit_array_length(b));
}

static moonbit_bytes_t chunks_of(const uint8_t *b, int64_t n) {
  int64_t cap = 1024, cnt = 0;
  uint32_t *starts = malloc(cap * sizeof(uint32_t));
  starts[cnt++] = 0;
  for (int64_t k = 0; k + 2 < n; k++) {
    if (b[k] == '\n' && b[k + 1] == '\n') {
      uint8_t c = b[k + 2];
      if (c == '/' || c == 'e' || c == 't') {
        if (cnt == cap) {
          cap *= 2;
          starts = realloc(starts, cap * sizeof(uint32_t));
        }
        starts[cnt++] = (uint32_t)(k + 2);
      }
    }
  }
  moonbit_bytes_t r = moonbit_make_bytes((int32_t)(cnt * 16), 0);
  for (int64_t i = 0; i < cnt; i++) {
    uint32_t s = starts[i], e = i + 1 < cnt ? starts[i + 1] : (uint32_t)n;
    uint64_t h = 0xCBF29CE484222325ULL;
    for (uint32_t k = s; k < e; k++) h = (h ^ b[k]) * 0x100000001B3ULL;
    memcpy(r + i * 16, &s, 4);
    memcpy(r + i * 16 + 4, &e, 4);
    memcpy(r + i * 16 + 8, &h, 8);
  }
  free(starts);
  return r;
}

// the text of bytes [s, e) of b (UTF-8)
MOONBIT_EXPORT moonbit_string_t tstc_utf8_slice(moonbit_bytes_t bytes, int32_t s, int32_t e) {
  const uint8_t *b = bytes;
  int32_t ascii = 1;
  for (int32_t i = s; i < e; i++) {
    if (b[i] >= 0x80) {
      ascii = 0;
      break;
    }
  }
  if (ascii) {
    moonbit_string_t r = moonbit_make_string_raw(e - s);
    for (int32_t i = s; i < e; i++) r[i - s] = b[i];
    return r;
  }
  int32_t units = 0;
  for (int32_t i = s; i < e;) {
    uint32_t cp;
    i += utf8_step(b, e, i, &cp);
    units += cp >= 0x10000 ? 2 : 1;
  }
  moonbit_string_t r = moonbit_make_string_raw(units);
  int32_t k = 0;
  for (int32_t i = s; i < e;) {
    uint32_t cp;
    i += utf8_step(b, e, i, &cp);
    if (cp >= 0x10000) {
      cp -= 0x10000;
      r[k++] = (uint16_t)(0xD800 + (cp >> 10));
      r[k++] = (uint16_t)(0xDC00 + (cp & 0x3FF));
    } else {
      r[k++] = (uint16_t)cp;
    }
  }
  return r;
}

// bytes [s, e) of b appended to buffer h
MOONBIT_EXPORT void tstc_buf_bytes(int h, moonbit_bytes_t b, int32_t s, int32_t e) {
  TBuf *t = &tbufs[h];
  memcpy(tbuf_room(t, (size_t)(e - s)), b + s, (size_t)(e - s));
  t->n += (size_t)(e - s);
}

// Sources of any size (a MoonBit Bytes holds fewer than 2^28 bytes): the
// file in a buffer (tstc_blob_read), read in pieces

// the file in a new buffer (-1: cannot)
MOONBIT_EXPORT int tstc_src_read(moonbit_bytes_t path) {
  int64_t n = tstc_file_size(path);
  return n >= 0 ? tstc_blob_read(path, 0, n) : -1;
}

// bytes [s, e) of buffer h
MOONBIT_EXPORT moonbit_bytes_t tstc_src_slice(int h, int64_t s, int64_t e) {
  TBuf *t = &tbufs[h];
  if (s < 0) s = 0;
  if (e > (int64_t)t->n) e = (int64_t)t->n;
  if (e < s) e = s;
  if (e - s >= ((int64_t)1 << 28)) {
    fprintf(stderr, "tstc: a piece of a source too large (%lld bytes)\n", (long long)(e - s));
    exit(1);
  }
  moonbit_bytes_t r = moonbit_make_bytes((int32_t)(e - s), 0);
  memcpy(r, t->d + s, (size_t)(e - s));
  return r;
}

// the first position from i where a top-level declaration starts after a
// blank line ("\n\n" followed by '/', 'e' or 't'), or the end
MOONBIT_EXPORT int64_t tstc_src_boundary(int h, int64_t i) {
  TBuf *t = &tbufs[h];
  const uint8_t *b = (const uint8_t *)t->d;
  int64_t n = (int64_t)t->n;
  for (int64_t k = i; k + 2 < n; k++)
    if (b[k] == '\n' && b[k + 1] == '\n' && (b[k + 2] == '/' || b[k + 2] == 'e' || b[k + 2] == 't')) return k + 2;
  return n;
}

// tstc_chunks of buffer h
MOONBIT_EXPORT moonbit_bytes_t tstc_src_chunks(int h) {
  TBuf *t = &tbufs[h];
  return chunks_of((const uint8_t *)t->d, (int64_t)t->n);
}
