// Processes of compiled programs: fork, wait, exit, the clock, output.
//
// A program is one thread: its own concurrency (as tstst's goroutines) is
// scheduled in the program.
#include "lib.h"

#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

void prof_after_fork(void);
void gc_after_fork(void);
void heap_fork_reserve(V h);

static int last_status;
static unsigned child_timeout;  // a forked child's timeout (seconds; 0: none)

// TSTC_FORK_STATS=<file>: the parent appends what its forks and children cost
// (the fork calls' time, the children's CPU and page faults)
static const char *fork_stats;
static double fork_ms;
static int64_t fork_n, child_minflt, child_majflt;
static double child_utime, child_stime;

static void write_fork_stats(void) {
  if (!fork_stats) return;  // (a child)
  FILE *f = fopen(fork_stats, "a");
  if (!f) return;
  fprintf(f, "%d forks %lld, fork calls %.0f ms, children user %.0f ms sys %.0f ms, minor faults %lld, major %lld\n",
          (int)getpid(), (long long)fork_n, fork_ms, child_utime, child_stime, (long long)child_minflt,
          (long long)child_majflt);
  fclose(f);
}

static double tv_ms(struct timeval t) { return t.tv_sec * 1000.0 + t.tv_usec / 1000.0; }

// fork<H, timeout seconds> -> [H, pid]: 0 in the child, which gets SIGALRM
// after the timeout (0: what is left of the parent's)
V n_fork(V h, V timeoutv) {
  if (getenv("TSTC_NO_FORK")) return mk_tuple2(h, mk_int(-1));
  int64_t timeout = gi(timeoutv);
  fflush(stdout);
  fflush(stderr);
  heap_fork_reserve(h);
  unsigned left = alarm(0);
  static bool stats_init;
  if (!stats_init) {
    stats_init = true;
    fork_stats = getenv("TSTC_FORK_STATS");
    if (fork_stats) atexit(write_fork_stats);
  }
  struct timespec t0, t1;
  if (fork_stats) clock_gettime(CLOCK_MONOTONIC, &t0);
  int pid = fork();
  if (pid > 0 && fork_stats) {
    clock_gettime(CLOCK_MONOTONIC, &t1);
    fork_ms += (t1.tv_sec - t0.tv_sec) * 1000.0 + (t1.tv_nsec - t0.tv_nsec) / 1e6;
    fork_n++;
  }
  if (pid == 0) {
    fork_stats = NULL;
    child_timeout = timeout > 0 ? (unsigned)timeout : left;
    alarm(child_timeout);
    gc_after_fork();
    cells_after_fork();
    prof_after_fork();
  }
  else if (left) alarm(left);
  return mk_tuple2(h, mk_int(pid));
}

// wait<H> -> [H, pid, status]: the exit code, or 128 + signal
V n_wait(V h) {
  int st = 0;
  struct rusage ru;
  pid_t p = wait4(-1, &st, 0, &ru);
  if (p > 0 && fork_stats) {
    child_utime += tv_ms(ru.ru_utime);
    child_stime += tv_ms(ru.ru_stime);
    child_minflt += ru.ru_minflt;
    child_majflt += ru.ru_majflt;
  }
  if (p < 0) last_status = -1;
  else last_status = WIFEXITED(st) ? WEXITSTATUS(st) : WIFSIGNALED(st) ? 128 + WTERMSIG(st) : 255;
  return mk_tuple3(h, mk_int(p), mk_int(last_status));
}

V n_exit(V h, V code) {
  (void)h;
  fflush(stdout);
  fflush(stderr);
  exit((int)gi(code));
}

// crash_note<H, Note>: a fatal error from now on writes Note (bytes) and the
// error to the program's output (main.c). In a forked child, the timeout it
// was forked with starts again (the note names what it now runs: tstst's
// baseline driver runs a group of tests a process)
V n_crash_note(V h, V note) {
  if (child_timeout) alarm(child_timeout);
  Str *s = gs(note);
  uint8_t *b = malloc((size_t)s->len + 1);
  const uint16_t *d = str_d(s);
  for (int32_t i = 0; i < s->len; i++) b[i] = (uint8_t)d[i];
  free(crash_note);
  crash_note = b;
  crash_note_len = (size_t)s->len;
  return h;
}

VPair n_clock_ms(V h) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return PAIR(h, mk_int((int64_t)(ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6)));
}

// write_out<H, S>: S (bytes) to the program's output
V n_write_out(V h, V s) {
  Str *str = gs(s);
  uint8_t *b = malloc((size_t)str->len + 1);
  const uint16_t *d = str_d(str);
  for (int32_t i = 0; i < str->len; i++) b[i] = (uint8_t)d[i];
  emit_bytes(b, (size_t)str->len);
  free(b);
  return h;
}
