// Failures caught (`@catch H` on an alias, see catch.mbt in the compiler).
//
// A failure is what a native does where its TypeScript definition is
// Panic<M> (never): rt_error. Inside an alias with a handler (run under
// tstc_try) it jumps back there, and the alias's value is H<M, S>: M the
// message, S the current version of the store (the cells are updated in
// place, so that is the only one; given when H takes two parameters).
// Without an enclosing tstc_try a failure ends the program, as die does.
// Errors of the runtime itself (die) are never caught.
#include "tstc.h"
#include "desc.h"
#include "lib.h"

#include <execinfo.h>
#include <setjmp.h>
#include <stdlib.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

typedef struct TryFrame {
  jmp_buf jb;
  struct TryFrame *prev;
  V *top;
} TryFrame;

static __thread TryFrame *try_top;
static __thread char try_msg[1024];

_Noreturn void rt_error(const char *fmt, ...) {
  char buf[1024];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(buf, sizeof buf, fmt, ap);
  va_end(ap);
  // TSTC_ERROR_BT: the native frames where a failure was raised (a caught one
  // too: a Go panic goes up to the scheduler as a value, without them)
  static int bt = -1;
  if (bt < 0) bt = getenv("TSTC_ERROR_BT") != NULL;
  if (bt) {
    void *frames[48];
    fprintf(stderr, "failure: %s\n", buf);
    backtrace_symbols_fd(frames, backtrace(frames, 48), 2);
  }
  if (try_top) {
    // the message as Panic<M> has it (natives format Go's panics as "panic: M")
    const char *m = buf;
    if (!strncmp(m, "panic: ", 7)) m += 7;
    snprintf(try_msg, sizeof try_msg, "%s", m);
    _longjmp(try_top->jb, 1);
  }
  die("%s", buf);
}

// a frame function's register arguments: reg_args in src/main/gen.mbt
typedef VPair (*FrameFn)(V *, int64_t, int64_t, int64_t, int64_t, int64_t);
typedef V (*EntryFn)(V *args, int64_t n);

VPair tstc_try(FrameFn f, EntryFn handler, int64_t nh, V *env, int64_t a0, int64_t a1, int64_t a2, int64_t a3,
               int64_t a4) {
  TryFrame tf;
  tf.prev = try_top;
  tf.top = tstc_top;
  try_top = &tf;
  if (_setjmp(tf.jb) == 0) {
    VPair r = f(env, a0, a1, a2, a3, a4);
    try_top = tf.prev;
    return r;
  }
  try_top = tf.prev;
  tstc_top = tf.top;
  V args[2] = {(V)str_of_cstr(try_msg), heap_latest ? heap_v(heap_latest) : V_UNDEFINED};
  return PAIR(handler(args, nh), 0);
}
