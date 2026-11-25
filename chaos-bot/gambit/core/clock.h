// THE CLOCK: one deadline for a decision, in the host's milliseconds (clock_ms, the one import beside abort_poll), and a share of it
// for each search. Every step a search plays goes through step() (core/nodes.h); past the share in force, or the decision's deadline,
// or the host's abort, every step comes back "not there" (STEP_NULL), so every search stops at the same moment and none keeps a clock
// of its own. Work (the engine's frames) is counted beside it, for the log.
#ifndef GAMBIT_CLOCK_H
#define GAMBIT_CLOCK_H
#ifndef GAMBIT_SYSTEM_INTS
typedef long long int64_t;   // (the engine's libc.h has the 32-bit ones; a native host has the system's)
#endif
double clock_ms(void) __attribute__((import_module("env"), import_name("clock_ms")));
// (the deadline is the decision's, on every thread; the share in force, the work counted and the abort seen are each thread's own: a
// thread's job keeps its own share -- decide.c readyJob)
static double clockDue = 0; static LOCAL double clockShare = 0;   // the decision's deadline and the share in force (ms since the epoch; 0: none)
static LOCAL int64_t clockWork;
static LOCAL int32_t clockAborted;
// (the time a decision reads: the host's, or a replay's, which runs on the work done -- test/decide_check.c)
static double (*clockNowOf)(void);
static double nowMs(void) { return clockNowOf ? clockNowOf() : clock_ms(); }
// A decision begun: its deadline (0: none).
static LOCAL double clockWentOut;   // when the decision first ran out of time (0: not yet), for the host to time its closing work
static void clockStart(double due) { clockDue = due; clockShare = 0; clockWork = 0; clockAborted = 0; clockWentOut = 0; }
// A SEARCH'S SHARE: within the decision's deadline, a search may stop sooner -- at `by`. Shares nest, a share never past the one it is
// taken in (0: none); the old one comes back after.
static double clockShareBegin(double by) { double old = clockShare; clockShare = old && (!by || old < by) ? old : by; return old; }
static void clockShareEnd(double old) { clockShare = old; }
static LOCAL int64_t clockPoll;
// A host that knows the game's frame (native.c) stops a decision on it: out once the frame before its move has begun.
static int (*clockFrameOut)(void);
// A JOB BESIDE THE DECISION (decide.c readySpread): no deadline of the decision's -- its searches end in their own share, or when the
// next decision takes the pool back (jobStop)
static LOCAL int inJob;
static int32_t jobStop;
// (THE SEARCH BETWEEN DECISIONS, answer.c onThread: inJob 2 -- its slice and its own stop, never the decision's jobs' stop)
static int32_t onStopReq;
static int32_t clockIgnore;   // (a fixed piece of work run whatever the clock says: decide.c moveWhy, its few steps measured once)
static int clockOut(void) {
  if (!inJob && __atomic_load_n(&clockIgnore, __ATOMIC_RELAXED)) return 0;
  if (inJob == 2) return __atomic_load_n(&onStopReq, __ATOMIC_RELAXED) || (clockShare && nowMs() >= clockShare);
  if (inJob) return __atomic_load_n(&jobStop, __ATOMIC_RELAXED) || (clockShare && nowMs() >= clockShare);
  if (clockAborted) return 1;
#ifdef __wasm__
  if (clockWork >= clockPoll) { clockPoll = clockWork + 400; if (abort_poll() == 1) { clockAborted = 1; return 1; } }
#else
  // (natively the host's abort is an atomic load, asked every step: a question the frame loop dropped stops at once, and the one asked
  // after it waits behind nothing)
  if (abort_poll() == 1) { clockAborted = 1; return 1; }
#endif
  if (clockFrameOut && clockFrameOut()) { if (!clockWentOut) clockWentOut = nowMs(); return 1; }
  if (!clockDue && !clockShare) return 0;
  double t = nowMs();
  if (clockDue && t >= clockDue && !clockWentOut) clockWentOut = t;
  return (clockShare && t >= clockShare) || (clockDue && t >= clockDue);
}
static void clockCharge(int64_t units) { clockWork += units > 0 ? units : 1; }
EXPORT(gb_clock_start) void gb_clock_start(double due) { clockStart(due); }
EXPORT(gb_clock_work) int gb_clock_work(void) { return (int)clockWork; }
#endif
