// TSTC_PROF=<prefix>: a sampling profile of each process, forked ones too.
// Every millisecond of CPU time the program counter and the return address
// are recorded; at exit <prefix>.<pid> gets them (hex, a pair per line, and
// the name of a library function) after a line with the address of main,
// which gives the slide for symbolizing with nm (scripts/prof.py).
#define _XOPEN_SOURCE 700
#define _DARWIN_C_SOURCE
#include <dlfcn.h>
#include <libproc.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/time.h>
#include <ucontext.h>
#include <unistd.h>

int main(int argc, char **argv);

static uintptr_t *buf;
static size_t n, cap;
static const char *prefix;

static void on_prof(int sig, siginfo_t *si, void *ctx) {
  (void)sig;
  (void)si;
  ucontext_t *uc = ctx;
#if defined(__aarch64__)
  uintptr_t pc = (uintptr_t)uc->uc_mcontext->__ss.__pc, lr = (uintptr_t)uc->uc_mcontext->__ss.__lr;
  uintptr_t fp = (uintptr_t)uc->uc_mcontext->__ss.__fp;
#else
  uintptr_t pc = (uintptr_t)uc->uc_mcontext->__ss.__rip, lr = 0, fp = 0;
#endif
  // the return address of the frame record fp points to, when it is on
  // this thread's stack (a leaf function has none of its own: then it is
  // the caller's caller)
  uintptr_t ra2 = 0, ra3 = 0;
  pthread_t t = pthread_self();
  uintptr_t hi = (uintptr_t)pthread_get_stackaddr_np(t), lo = hi - pthread_get_stacksize_np(t);
  if (fp >= lo && fp + 16 <= hi && (fp & 7) == 0) {
    ra2 = ((uintptr_t *)fp)[1];
    uintptr_t fp2 = ((uintptr_t *)fp)[0];
    if (fp2 > fp && fp2 + 16 <= hi && (fp2 & 7) == 0) ra3 = ((uintptr_t *)fp2)[1];
  }
  if (n + 4 <= cap) {
    buf[n++] = pc;
    buf[n++] = lr;
    buf[n++] = ra2;
    buf[n++] = ra3;
  }
}

static void arm(void) {
  struct itimerval it = {{0, 1000}, {0, 1000}};
  setitimer(ITIMER_PROF, &it, NULL);
}

static void dump(void) {
  if (!prefix || n == 0) return;
  // (not sampling itself)
  struct itimerval off = {{0, 0}, {0, 0}};
  setitimer(ITIMER_PROF, &off, NULL);
  char path[4096];
  snprintf(path, sizeof path, "%s.%d", prefix, (int)getpid());
  FILE *f = fopen(path, "w");
  if (!f) return;
  fprintf(f, "main %lx\n", (unsigned long)(uintptr_t)&main);
  Dl_info self_info, info;
  dladdr((void *)&main, &self_info);
  for (size_t i = 0; i + 3 < n; i += 4) {
    // outside the executable: the library function's name
    const char *sym = "";
    if (dladdr((void *)buf[i], &info) && info.dli_fbase != self_info.dli_fbase && info.dli_sname) sym = info.dli_sname;
    fprintf(f, "%lx %lx %lx %lx %s\n", (unsigned long)buf[i], (unsigned long)buf[i + 1], (unsigned long)buf[i + 2],
            (unsigned long)buf[i + 3], sym);
  }
  fclose(f);
}

// a timeout (SIGALRM) ends the process without exit: the profile is written
// first
static void on_alarm(int sig) {
  dump();
  signal(sig, SIG_DFL);
  raise(sig);
}

// TSTC_INSN=<prefix>: each process writes the instructions and cycles it
// retired to <prefix>.<pid> at exit (a measure of work that does not depend on
// the core it ran on or the machine's load)
static const char *insn_prefix;

static void write_insn(void) {
  struct rusage_info_v4 ri;
  if (proc_pid_rusage(getpid(), RUSAGE_INFO_V4, (rusage_info_t *)&ri) != 0) return;
  char path[4096];
  snprintf(path, sizeof path, "%s.%d", insn_prefix, (int)getpid());
  FILE *f = fopen(path, "w");
  if (!f) return;
  fprintf(f, "%llu instructions %llu cycles %llu user_ns\n", (unsigned long long)ri.ri_instructions,
          (unsigned long long)ri.ri_cycles, (unsigned long long)ri.ri_user_time);
  fclose(f);
}

void prof_start(void) {
  insn_prefix = getenv("TSTC_INSN");
  if (insn_prefix) atexit(write_insn);
  prefix = getenv("TSTC_PROF");
  if (!prefix) return;
  cap = (size_t)4 << 22;
  buf = malloc(cap * sizeof *buf);
  if (!buf) return;
  struct sigaction sa;
  sa.sa_sigaction = on_prof;
  sa.sa_flags = SA_SIGINFO | SA_RESTART;
  sigemptyset(&sa.sa_mask);
  sigaction(SIGPROF, &sa, NULL);
  signal(SIGALRM, on_alarm);
  atexit(dump);
  arm();
}

// a forked child profiles itself (timers are not inherited)
void prof_after_fork(void) {
  if (!buf) return;
  n = 0;
  arm();
}
