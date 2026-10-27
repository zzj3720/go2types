// The program: command line, entry points, output.
#include "tstc.h"

#include <execinfo.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>
#include <fcntl.h>

typedef struct { const char *name; V (*fn)(V *args, int64_t n); int64_t nparams; } Entry;
extern const Entry *const tstc_entries;
extern const int64_t tstc_nentries;
extern const int64_t *const tstc_dump;
extern const int64_t tstc_ndump;
#ifdef __APPLE__
#include <mach-o/getsect.h>
#include <mach-o/ldsyms.h>
#endif

void map_gc_init(void);
void cells_gc_init(void);
void cells_gc_stats(FILE *f);

static int g_argc;
static char **g_argv;
const char *emit_path;  // where emitted output goes (NULL: stdout)
uint8_t *crash_note;  // set by the program (crash_note), e.g. in a forked test process
size_t crash_note_len;
static int exit_code;

// --coverage: a byte per alias, set when it runs; TSTC_COVERAGE=<path> writes
// the names of those that ran to <path>.<pid> at exit
uint8_t tstc_cov[1 << 23];
extern const char *const *const tstc_cov_names;
extern const int64_t tstc_cov_n;
static void write_coverage(void) {
  const char *p = getenv("TSTC_COVERAGE");
  if (!p || !tstc_cov_n) return;
  char path[1024];
  snprintf(path, sizeof path, "%s.%d", p, (int)getpid());
  FILE *f = fopen(path, "w");
  if (!f) return;
  for (int64_t i = 0; i < tstc_cov_n && i < (1 << 23); i++)
    if (tstc_cov[i]) fprintf(f, "%s\n", tstc_cov_names[i]);
  fclose(f);
}

void emit_bytes(const uint8_t *b, size_t n) {
  if (!emit_path) {
    fwrite(b, 1, n, stdout);
    fflush(stdout);
    return;
  }
  // one write(2) with O_APPEND, so that records of concurrent processes do
  // not interleave (the descriptor opened once: forked processes share it,
  // appends stay atomic)
  static int fd = -1;
  if (fd < 0) fd = open(emit_path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0644);
  if (fd < 0) return;
  while (n > 0) {
    ssize_t k = write(fd, b, n);
    if (k <= 0) break;
    b += k;
    n -= (size_t)k;
  }
}

// the crash note and a message, in one write (other processes may write the
// same output)
static void crash_record(const char *fmt, const char *arg) {
  char rec[4400];
  size_t k = crash_note_len < 1024 ? crash_note_len : 1024;
  memcpy(rec, crash_note, k);
  int n = snprintf(rec + k, sizeof rec - k, fmt, arg);
  if (n > (int)(sizeof rec - k) - 1) n = (int)(sizeof rec - k) - 1;
  emit_bytes((const uint8_t *)rec, k + (size_t)n);
}

_Noreturn void die(const char *fmt, ...) {
  char buf[4096];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(buf, sizeof buf, fmt, ap);
  va_end(ap);
  fflush(stdout);
  // TSTC_DIE_BT: where the program died (native frames)
  if (getenv("TSTC_DIE_BT")) {
    void *bt[32];
    backtrace_symbols_fd(bt, backtrace(bt, 32), 2);
  }
  fprintf(stderr, "error: %s\n", buf);
  // TSTC_DIE_TRACE=1: the native frames too
  if (getenv("TSTC_DIE_TRACE")) {
    void *frames[64];
    int k = backtrace(frames, 64);
    backtrace_symbols_fd(frames, k, 2);
  }
  if (crash_note) crash_record("error: %s\n", buf);
  fflush(stderr);
  exit(1);
}

static double now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}

static uint8_t *read_all(const char *path, size_t *n) {
  FILE *f = fopen(path, "rb");
  if (!f) die("cannot read %s", path);
  fseek(f, 0, SEEK_END);
  long len = ftell(f);
  fseek(f, 0, SEEK_SET);
  uint8_t *b = malloc((size_t)len + 1);
  if (len > 0 && fread(b, 1, (size_t)len, f) != (size_t)len) die("cannot read %s", path);
  fclose(f);
  b[len] = 0;
  *n = (size_t)len;
  return b;
}

static void usage(void) {
  fprintf(stderr,
          "usage:\n"
          "  %s run [--entry Main] [--arg-file path]... [--arg text]... [--out path] [--bytes] [--stats]\n"
          "  %s dump      print every parameterless type alias of the program\n",
          g_argv[0], g_argv[0]);
  exit(2);
}

static void write_text(const char *path, const char *s) {
  if (!path) {
    fputs(s, stdout);
    fflush(stdout);
    return;
  }
  FILE *f = fopen(path, "wb");
  if (!f) die("cannot write %s", path);
  fputs(s, f);
  fclose(f);
}

static void str_emit(Str *s) {
  uint8_t *b = malloc((size_t)s->len + 1);
  const uint16_t *d = str_d(s);
  for (int32_t i = 0; i < s->len; i++) b[i] = (uint8_t)d[i];
  emit_bytes(b, (size_t)s->len);
  free(b);
}

// a string, or a tuple of strings (pieces of a text too long to join),
// written; false when r is neither
static bool emit_pieces(V r) {
  if (kind(r) == K_STRLIT) {
    str_emit(as_str(r));
    return true;
  }
  if (kind(r) != K_TUPLE || !tup_nokinds(as_tup(r))) return false;
  TupT *t = as_tup(r);
  for (uint32_t i = 0; i < t->len; i++)
    if (kind(t->e[i]) != K_STRLIT) return false;
  for (uint32_t i = 0; i < t->len; i++) str_emit(as_str(t->e[i]));
  return true;
}

static void run(void) {
  if (g_argc < 2) usage();
  const char *cmd = g_argv[1];
  const char *entry = "Main", *out_path = NULL;
  bool stats = false, bytes_mode = false;
  // arguments: 0 marks a file to read once the mode is known
  V inputs[64];
  const char *files[64];
  int ninputs = 0;
  for (int i = 2; i < g_argc; i++) {
    const char *a = g_argv[i];
    if (!strcmp(a, "--entry") && i + 1 < g_argc) entry = g_argv[++i];
    else if (!strcmp(a, "--arg-file") && i + 1 < g_argc && ninputs < 64) {
      files[ninputs] = g_argv[++i];
      inputs[ninputs++] = 0;
    } else if (!strcmp(a, "--arg") && i + 1 < g_argc && ninputs < 64) {
      files[ninputs] = NULL;
      inputs[ninputs++] = (V)str_of_cstr(g_argv[++i]);
    } else if (!strcmp(a, "--out") && i + 1 < g_argc) out_path = g_argv[++i];
    else if (!strcmp(a, "--stats")) stats = true;
    else if (!strcmp(a, "--bytes")) bytes_mode = true;
    else usage();
  }
  for (int k = 0; k < ninputs; k++) {
    if (inputs[k]) continue;
    size_t n;
    uint8_t *b = read_all(files[k], &n);
    inputs[k] = bytes_mode ? (V)str_of_bytes(b, (int32_t)n) : (V)str_of_cstr((char *)b);
    free(b);
  }
  double t0 = now_ms();
  if (!strcmp(cmd, "dump")) {
    for (int64_t k = 0; k < tstc_ndump; k++) {
      const Entry *e = &tstc_entries[tstc_dump[k]];
      // (as TypeScript's Equal sees it: eq_strip)
      V v = eq_strip(e->fn(NULL, 0));
      char *s = ty_to_cstr(v);
      printf("%s = %s\n", e->name, s);
      free(s);
    }
    fflush(stdout);
  } else if (!strcmp(cmd, "check")) {
    // the relations the compiler left to the program (tstc check.mbt): 1
    // holds, 0 does not
    for (int64_t k = 0; k < tstc_nentries; k++) {
      const Entry *e = &tstc_entries[k];
      if (strncmp(e->name, "tstc$check$", 11) || e->nparams) continue;
      V v = e->fn(NULL, 0);
      char *s = ty_to_cstr(v);
      printf("%s = %s\n", e->name, s);
      fflush(stdout);
      free(s);
    }
  } else if (!strcmp(cmd, "run")) {
    const Entry *e = NULL;
    for (int64_t k = 0; k < tstc_nentries; k++)
      if (!strcmp(tstc_entries[k].name, entry)) e = &tstc_entries[k];
    if (!e) die("entry type '%s' not found", entry);
    if (out_path && bytes_mode) {
      FILE *f = fopen(out_path, "wb");
      if (f) fclose(f);
      emit_path = out_path;
    }
    int64_t np = e->nparams;
    V *args = gc_alloc((size_t)(np > ninputs ? np : ninputs) * 8 + 8);
    for (int64_t k = 0; k < np; k++) args[k] = k < ninputs ? inputs[k] : V_UNKNOWN;
    V r = e->fn(args, ninputs < np ? ninputs : np);
    if (bytes_mode && emit_pieces(r)) {
      // (written as they are: the text, or a tuple of its pieces)
    } else {
      char *s;
      if (kind(r) == K_STRLIT) {
        s = str_to_utf8(as_str(r), NULL);
      } else {
        char *t = ty_to_cstr(r);
        size_t n = strlen(t);
        s = malloc(n + 2);
        memcpy(s, t, n);
        s[n] = '\n';
        s[n + 1] = 0;
        free(t);
      }
      write_text(out_path, s);
      free(s);
    }
  } else {
    usage();
  }
  if (stats)
    fprintf(stderr, "run %.1f ms, %zu collections (%.0f ms), %zu MB live\n", now_ms() - t0, gc_collections, gc_ms,
            gc_bytes_live >> 20);
  if (stats) cells_gc_stats(stderr);
}

// a crash prints the innermost native frames (on an alternate signal stack,
// since the usual cause is running out of stack)
static void crash_handler(int sig, siginfo_t *info, void *ctx) {
  (void)ctx;
  char msg[200];
  int n = snprintf(msg, sizeof msg, "fatal signal %d at address %p; innermost frames:\n", sig, info->si_addr);
  write(2, msg, (size_t)n);
  void *frames[48];
  int k = backtrace(frames, 48);
  backtrace_symbols_fd(frames, k, 2);
  if (crash_note) {
    char m[40];
    snprintf(m, sizeof m, "%d", sig);
    crash_record("fatal signal %s\n", m);
  }
  _exit(128 + sig);
}

void install_crash_handler(void) {
  stack_t ss;
  ss.ss_size = 1 << 16;
  ss.ss_sp = malloc(ss.ss_size);
  ss.ss_flags = 0;
  sigaltstack(&ss, NULL);
  struct sigaction sa;
  memset(&sa, 0, sizeof sa);
  sa.sa_sigaction = crash_handler;
  sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
  sigaction(SIGSEGV, &sa, NULL);
  sigaction(SIGBUS, &sa, NULL);
  sigaction(SIGABRT, &sa, NULL);
}

// the name of a parameterless alias whose value v is (the one that made v
// as a placeholder first), NULL when none (rt_knot_open)
const char *knot_name(V v) {
#ifdef __APPLE__
  static V *cache;
  static unsigned long csize;
  if (!cache) cache = (V *)getsectiondata(&_mh_execute_header, "__DATA", "__tstc_cache", &csize);
  if (!cache) return NULL;
  unsigned long n = csize / (4 * sizeof(V));
  for (unsigned long i = 0; i < n; i++)
    if (cache[4 * i + 2] == v) return (const char *)cache[4 * i + 3];
  for (unsigned long i = 0; i < n; i++)
    if (cache[4 * i] == v) return (const char *)cache[4 * i + 3];
#else
  (void)v;
#endif
  return NULL;
}

static void *main_thread(void *arg) {
  (void)arg;
  char base;
  install_crash_handler();
  atexit(write_coverage);
  gc_init(&base + 256);
  map_gc_init();
  cells_gc_init();
  // the values of parameterless aliases (with their flags) are in a section
#ifdef __APPLE__
  unsigned long csize = 0;
  uint8_t *cache = getsectiondata(&_mh_execute_header, "__DATA", "__tstc_cache", &csize);
  if (cache && csize) gc_add_root(cache, (size_t)csize);
  // the objects of object type sites (memo.c: rt_ident_get)
  unsigned long isize = 0;
  uint8_t *ident = getsectiondata(&_mh_execute_header, "__DATA", "__tstc_ident", &isize);
  if (ident && isize) gc_add_root(ident, (size_t)isize);
#endif
  gc_set_env_stack(env_stack_new());
  run();
  fflush(stdout);
  exit(exit_code);
  return NULL;
}

void prof_start(void);

int main(int argc, char **argv) {
  prof_start();
  g_argc = argc;
  g_argv = argv;
  // deep (non-tail) recursion needs a big stack
  pthread_attr_t at;
  pthread_attr_init(&at);
  pthread_attr_setstacksize(&at, (size_t)4 << 30);
  pthread_t t;
  if (pthread_create(&t, &at, main_thread, NULL) != 0) {
    pthread_attr_setstacksize(&at, (size_t)512 << 20);
    if (pthread_create(&t, &at, main_thread, NULL) != 0) {
      fprintf(stderr, "cannot start the main thread\n");
      return 1;
    }
  }
  pthread_join(t, NULL);
  return exit_code;
}
