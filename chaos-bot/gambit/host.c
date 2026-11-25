// WHAT A NATIVE HOST GIVES GAMBIT (native.c): the heap, the monotonic clock, one lock with its wait, a thread, and the run's log.
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>
#include <time.h>
#include <sched.h>
#include <string.h>
#include <sys/resource.h>

// THE INSTANCE'S MEMORY: every block the heap gives is kept, and all of it freed when the instance quits (hostQuit) -- a match is played
// by an instance of its own (lua/GambitNative.lua), nothing of the last left behind
// THE CAP: past GC_GAMBIT_HEAP_MB (none when it is not set) the instance says so in its log and aborts, so the game ends with its log
// kept rather than taking the runner's memory and the runner with it (a lost runner keeps no log at all).
static void **heapBlocks; static long heapN, heapCap;
static unsigned long heapBytes;
static pthread_mutex_t heapMu = PTHREAD_MUTEX_INITIALIZER;
void hostLog(const char *s);
void hostLogFlush(void);
// The bytes the heap has given this instance, in MB
int hostHeapMB(void) { return (int)(__atomic_load_n(&heapBytes, __ATOMIC_RELAXED) >> 20); }
void *paHeap(unsigned long n) {
  static unsigned long capBytes;
  if (!capBytes) { const char *e = getenv("GC_GAMBIT_HEAP_MB"); long mb = e && *e ? atol(e) : 0; capBytes = mb > 0 ? (unsigned long)mb << 20 : ~0ul; }
  unsigned long sz = (n + 15) & ~15ul;
  if (__atomic_add_fetch(&heapBytes, sz, __ATOMIC_RELAXED) > capBytes) {
    char m[160]; snprintf(m, sizeof m, "GAMBITHEAP over the cap: %lu MB held, %lu MB asked, cap %lu MB", heapBytes >> 20, n >> 20, capBytes >> 20);
    hostLog(m); hostLogFlush(); fprintf(stderr, "%s\n", m); abort();
  }
  void *p = calloc(1, sz);
  if (!p) return 0;
  pthread_mutex_lock(&heapMu);
  if (heapN == heapCap) {
    long c = heapCap ? 2 * heapCap : 4096;
    void **nb = (void **)realloc(heapBlocks, (unsigned long)c * sizeof *nb);
    if (nb) { heapBlocks = nb; heapCap = c; }
  }
  if (heapN < heapCap) heapBlocks[heapN++] = p;
  pthread_mutex_unlock(&heapMu);
  return p;
}
// GIVING PAGES BACK (eval/native/memory.h paRelease): the whole pages inside a block nothing reads until it writes it again, handed back
// to the system -- the block stays this heap's (freed with the rest when the instance quits) and reads as zeros when next touched. Only
// pages wholly inside the block: the allocator's own words before and after it are left alone.
#include <sys/mman.h>
void paRelease(void *p, unsigned long n) {
  unsigned long a = ((unsigned long)p + 4095) & ~4095ul, e = ((unsigned long)p + n) & ~4095ul;
  if (e > a) madvise((void *)a, e - a, MADV_DONTNEED);
}
// The calling thread's own account: its CPU time (ms), the times it was taken off its core and gave it up, its page faults.
void hostThreadStats(double *out) {
  struct timespec t; clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t);
  struct rusage u; getrusage(RUSAGE_THREAD, &u);
  out[0] = (double)t.tv_sec * 1e3 + (double)t.tv_nsec / 1e6; out[1] = (double)u.ru_nivcsw; out[2] = (double)u.ru_nvcsw;
  out[3] = (double)(u.ru_minflt + u.ru_majflt); out[4] = (double)u.ru_majflt;
}
// EVERY PAGE THE PROCESS HAS MAPPED, IN ITS PAGE TABLES BEFORE PLAY (MADV_POPULATE_READ, Linux 5.14): the code and data of the game, the
// interpreter and the libraries, read in once here rather than on the frame that first reaches a page -- one page fault in a frame's load
// cost it 8-17 ms. A mapping over POPULATE_MOST is left as it is (a heap reserved, not used), and one the kernel refuses is skipped.
#ifndef MADV_POPULATE_READ
#define MADV_POPULATE_READ 22
#endif
#define POPULATE_MOST (256ul << 20)
void hostPopulate(void) {
  FILE *f = fopen("/proc/self/maps", "r");
  if (!f) return;
  char line[512];
  while (fgets(line, sizeof line, f)) {
    unsigned long a, e; char perm[8];
    if (sscanf(line, "%lx-%lx %7s", &a, &e, perm) != 3 || perm[0] != 'r' || e - a > POPULATE_MOST) continue;
    if (strstr(line, "[vvar") || strstr(line, "[vsyscall]")) continue;
    madvise((void *)a, e - a, MADV_POPULATE_READ);
  }
  fclose(f);
}
double hostNowMs(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (double)t.tv_sec * 1e3 + (double)t.tv_nsec / 1e6; }

static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t cv = PTHREAD_COND_INITIALIZER;
void hostLock(void) { pthread_mutex_lock(&mu); }
void hostUnlock(void) { pthread_mutex_unlock(&mu); }
void hostWait(void) { pthread_cond_wait(&cv, &mu); }
void hostSignal(void) { pthread_cond_signal(&cv); }
// GAMBIT'S THREAD: the room the main thread has for its stack (the searches keep their scratch there), and the cores GC_GAMBIT_CPUS
// names ("1-3", "2,3"), so it thinks beside the game rather than on the game's own core; the workers on GC_GAMBIT_WORKER_CPUS's
// (else Gambit's), so they take a core of their own rather than Gambit's.
static void *(*threadFn)(void *);
static void pinnedTo(const char *cpus) {
  if (cpus && *cpus) {
    cpu_set_t set; CPU_ZERO(&set);
    for (const char *p = cpus; *p;) {
      int a = atoi(p), b = a;
      while (*p >= '0' && *p <= '9') p++;
      if (*p == '-') { p++; b = atoi(p); while (*p >= '0' && *p <= '9') p++; }
      for (int c = a; c <= b && c < CPU_SETSIZE; c++) CPU_SET(c, &set);
      if (*p == ',') p++; else if (*p) break;
    }
    if (CPU_COUNT(&set)) pthread_setaffinity_np(pthread_self(), sizeof set, &set);
  }
}
static void pinned(void) { pinnedTo(getenv("GC_GAMBIT_CPUS")); }
// (every thread the instance starts, by kind -- 0 Gambit's, 1 the search between decisions, 2 the pool's workers -- joined when it quits)
#define MAXHOSTTHREADS 64
static pthread_t hostThreads[MAXHOSTTHREADS]; static int hostThreadKind[MAXHOSTTHREADS], nHostThreads;
static void keepThread(pthread_t t, int kind) { if (nHostThreads < MAXHOSTTHREADS) { hostThreads[nHostThreads] = t; hostThreadKind[nHostThreads++] = kind; } }
void hostJoin(int kind) {
  for (int i = 0; i < nHostThreads; i++) if (hostThreadKind[i] == kind) { pthread_join(hostThreads[i], 0); hostThreadKind[i] = -1; }
}
static void *threadStart(void *arg) { pinned(); pthread_setname_np(pthread_self(), "gambit"); return threadFn(arg); }
int hostThread(void *(*fn)(void *)) {
  pthread_t t; pthread_attr_t at;
  threadFn = fn;
  pthread_attr_init(&at); pthread_attr_setstacksize(&at, 64ul << 20);
  int r = pthread_create(&t, &at, threadStart, 0);
  pthread_attr_destroy(&at);
  if (!r) keepThread(t, 0);
  return r;
}

// THE ENGINE'S WAITS (search.h's pool, natively): a futex on the word.
#include <linux/futex.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <limits.h>
int hostFutexWait(int *p, int v) { return (int)syscall(SYS_futex, p, FUTEX_WAIT_PRIVATE, v, NULL, NULL, 0); }
int hostFutexWake(int *p, int n) { return (int)syscall(SYS_futex, p, FUTEX_WAKE_PRIVATE, n < 0 ? INT_MAX : n, NULL, NULL, 0); }
// THE WORKERS: GC_GAMBIT_WORKERS of them (at most `most`; none when it is not set), each started with its id (1, 2, ...), pinned where
// Gambit is (GC_GAMBIT_CPUS) and named gworkerN, as Gambit's own thread is named gambit (eval/cpu_watch.sh counts them by name). The
// number started.
static void *(*workerFn)(void *);
// (each at the idle class, SCHED_IDLE: it runs only on a CPU nothing else wants, so it never takes a cycle from Gambit's own thread
// or the game's -- on a runner whose four threads are two cores' worth, a worker at the normal class took them and lost games)
static void *workerStart(void *arg) {
  const char *w = getenv("GC_GAMBIT_WORKER_CPUS");
  if (w && *w) pinnedTo(w); else pinned();
  char name[16]; snprintf(name, sizeof name, "gworker%ld", (long)arg); pthread_setname_np(pthread_self(), name);
  struct sched_param sp = { 0 }; pthread_setschedparam(pthread_self(), SCHED_IDLE, &sp);
  return workerFn(arg);
}
// A THREAD AT THE IDLE CLASS beside the workers, on their CPUs, named `name`: 0 started
static void *(*idleFn)(void *); static const char *idleName;
static void *idleStart(void *arg) {
  const char *w = getenv("GC_GAMBIT_WORKER_CPUS");
  if (w && *w) pinnedTo(w); else pinned();
  pthread_setname_np(pthread_self(), idleName);
  struct sched_param sp = { 0 }; pthread_setschedparam(pthread_self(), SCHED_IDLE, &sp);
  return idleFn(arg);
}
int hostIdleThread(void *(*fn)(void *), const char *name) {
  pthread_t t; pthread_attr_t at;
  idleFn = fn; idleName = name;
  pthread_attr_init(&at); pthread_attr_setstacksize(&at, 64ul << 20);
  int r = pthread_create(&t, &at, idleStart, 0);
  pthread_attr_destroy(&at);
  if (!r) keepThread(t, 1);
  return r;
}
int hostWorkers(void *(*fn)(void *), int most) {
  const char *e = getenv("GC_GAMBIT_WORKERS");
  int n = e && *e ? atoi(e) : 0;
  if (n > most) n = most;
  if (n < 0) n = 0;
  workerFn = fn;
  for (int i = 0; i < n; i++) {
    pthread_t t; pthread_attr_t at;
    pthread_attr_init(&at); pthread_attr_setstacksize(&at, 64ul << 20);
    int r = pthread_create(&t, &at, workerStart, (void *)(long)(i + 1));
    pthread_attr_destroy(&at);
    if (r) return i;
    keepThread(t, 2);
  }
  return n;
}
// THE RUN'S LOG: a line is copied into memory under the lock and written to the file by hostLogFlush, outside it -- Gambit's thread
// flushes after each decision, the game's thread only when the game is over -- so the game's frame never waits on the disk. Two
// buffers: the one written out is swapped for the other under the lock, and lines go on into that one meanwhile.
static FILE *logFile;
static pthread_mutex_t logMu = PTHREAD_MUTEX_INITIALIZER, logFlushMu = PTHREAD_MUTEX_INITIALIZER;
#define LOGBUF (1 << 20)
static char *logBuf[2]; static size_t logLen[2]; static int logCur;
int hostOpenLog(const char *path) {
  if (!logFile) logFile = fopen(path, "a");
  if (logFile && !logBuf[0]) { logBuf[0] = malloc(LOGBUF); logBuf[1] = malloc(LOGBUF); if (!logBuf[0] || !logBuf[1]) { free(logBuf[0]); free(logBuf[1]); logBuf[0] = logBuf[1] = 0; } }
  return logFile ? 0 : -1;
}
static void logWriteOut(void) {   // (logFlushMu held)
  pthread_mutex_lock(&logMu); int k = logCur; logCur ^= 1; pthread_mutex_unlock(&logMu);
  if (logLen[k]) { fwrite(logBuf[k], 1, logLen[k], logFile); fflush(logFile); logLen[k] = 0; }
}
void hostLogFlush(void) {
  if (!logFile || !logBuf[0]) return;
  pthread_mutex_lock(&logFlushMu); logWriteOut(); pthread_mutex_unlock(&logFlushMu);
}
// THE INSTANCE ENDED (native.c gn_quit, its threads joined): its memory freed and its log closed
void hostQuit(void) {
  pthread_mutex_lock(&heapMu);
  for (long i = 0; i < heapN; i++) free(heapBlocks[i]);
  free(heapBlocks); heapBlocks = 0; heapN = heapCap = 0; heapBytes = 0;
  pthread_mutex_unlock(&heapMu);
  hostLogFlush();
  pthread_mutex_lock(&logMu);
  if (logFile) { fclose(logFile); logFile = 0; }
  free(logBuf[0]); free(logBuf[1]); logBuf[0] = logBuf[1] = 0; logLen[0] = logLen[1] = 0;
  pthread_mutex_unlock(&logMu);
}
void hostLog(const char *s) {
  if (!logFile) return;
  size_t n = strlen(s);
  if (logBuf[0]) {
    pthread_mutex_lock(&logMu);
    if (logLen[logCur] + n + 1 <= LOGBUF) { memcpy(logBuf[logCur] + logLen[logCur], s, n); logLen[logCur] += n; logBuf[logCur][logLen[logCur]++] = '\n'; pthread_mutex_unlock(&logMu); return; }
    pthread_mutex_unlock(&logMu);
  }
  // (the buffer full, or none: what it holds written out first, then the line, in order)
  pthread_mutex_lock(&logFlushMu);
  if (logBuf[0]) logWriteOut();
  pthread_mutex_lock(&logMu); fputs(s, logFile); fputc('\n', logFile); fflush(logFile); pthread_mutex_unlock(&logMu);
  pthread_mutex_unlock(&logFlushMu);
}
