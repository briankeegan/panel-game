// Memory and threads, shared by the engines (engine.c, pa.c): each defines
// Board before including this.
// ------------------------------------------------------------------ memory
// THREADS. engine-mt.wasm is this file on shared memory: every thread is an
// instance of it, with its own stack and its own copy of what is
// _Thread_local here. Memory is taken under a lock; each thread keeps its own
// free boards (a list per thread, so the main thread can hand boards over
// while the others wait).
#if defined(PA_LIB) || defined(PA_HEAP)
// Linked into the bot (bit.c), or a native host (PA_HEAP: gambit/native.c): one heap, the host's.
void *paHeap(unsigned long n);
static unsigned long heapTop;
static void *grab(unsigned long n) { return paHeap(n); }
#else
extern unsigned char __heap_base;
static unsigned long heapTop;
static int32_t heapLock;
static void *grab(unsigned long n) {
  while (__atomic_exchange_n(&heapLock, 1, __ATOMIC_ACQUIRE)) {}
  if (!heapTop) heapTop = ((unsigned long)&__heap_base + 15) & ~15ul;
  n = (n + 15) & ~15ul;
  // 32-bit: a block that would run past 4 GB is refused, not wrapped.
  unsigned long at = heapTop, end = at + n, have = __builtin_wasm_memory_size(0) * 65536ul;
  void *r = (void *)at;
  if (end < at) r = 0;
  else if ((have == 0 || end > have) && __builtin_wasm_memory_grow(0, (end - have + 65535) / 65536) == (unsigned long)-1) r = 0;
  else heapTop = end;
  __atomic_store_n(&heapLock, 0, __ATOMIC_RELEASE);
  return r;
}
#endif
// GIVING MEMORY BACK (a native host, PA_HEAP: gambit/host.c paRelease): a block nothing reads until it is written again -- a spare board
// past SPARE_KEEP, a node array outgrown -- has its pages handed back to the system; the block stays the heap's and reads as zeros when
// next touched, as a block fresh from the heap does. Elsewhere (wasm, the bot) nothing is given back.
#if defined(PA_HEAP)
void paRelease(void *p, unsigned long n);
#else
static void paRelease(void *p, unsigned long n) { (void)p; (void)n; }
#endif
#define MAXTHREADS 16
#if defined(THREADS) || !defined(__wasm__)
#define LOCAL _Thread_local
#else
#define LOCAL
#endif
#if defined(THREADS) || !defined(__wasm__)
static _Thread_local int32_t thId;   // 0 on the thread that runs the search
#else
static int32_t thId;
#endif
// Each thread's spare boards, on a cache line of its own: no thread writes
// another's line on a step.
static struct { Board *free; int32_t count; int32_t pad[14]; } __attribute__((aligned(64))) pool_[MAXTHREADS];
// Counters, per thread (ns_frame_stats sums them): frames per step kind
// 0..7, steps per kind 8..15, frames full, quiet, jumped, countdown 16..19.
static struct { int32_t v[32]; } __attribute__((aligned(64))) stat_[MAXTHREADS];
#define STAT(i) stat_[thId].v[i]
static int32_t statTake(int i) { int32_t v = 0; for (int k = 0; k < MAXTHREADS; k++) { v += stat_[k].v[i]; stat_[k].v[i] = 0; } return v; }
#define freeOf(k) pool_[k].free
#define freeCount(k) pool_[k].count
#define EXPORT(name) __attribute__((export_name(#name)))
// SPARES: boards any thread may take, under a lock, before the heap is
// grown -- a thread that frees more than it takes (the searching thread lets
// the other threads' boards go) hands its surplus round through them
// (search.h runPhase).
static Board *spareOf;
static int32_t spareCount, spareLock;   // (spareCount changed under the lock, read outside it: every access atomic)
static Board *takeSpare(void) {
  while (__atomic_exchange_n(&spareLock, 1, __ATOMIC_ACQUIRE)) {}
  Board *b = spareOf;
  if (b) { spareOf = *(Board **)b; __atomic_fetch_sub(&spareCount, 1, __ATOMIC_RELAXED); }
  __atomic_store_n(&spareLock, 0, __ATOMIC_RELEASE);
  return b;
}
EXPORT(nb_new) Board *nb_new(void) {
  Board *b = freeOf(thId);
  if (b) { freeOf(thId) = *(Board **)b; freeCount(thId)--; }
  else if (!(b = takeSpare())) b = (Board *)grab(sizeof(Board));
  return b;
}
// A thread's own list holds FREE_CAP boards at most; one freed past that goes to SPARES, so a thread that frees what another took
// (Gambit's thread resets the contexts its search between decisions grew) hands it back rather than keeping it while the other grows
// the heap.
#define FREE_CAP 4096
// SPARE_KEEP: the spare boards kept ready; one freed past them keeps its place on the list but not its pages (paRelease) -- a search that
// grew the pool by a hundred thousand boards (Gambit's, 46 KB each) left them all resident, and a run's memory climbed past the machine's
#define SPARE_KEEP 4096
EXPORT(nb_free) void nb_free(Board *b) {
  if (freeCount(thId) >= FREE_CAP) {
#if defined(PA_HEAP)
    // (released before it is on the list: once there another thread may take it and write it)
    if (__atomic_load_n(&spareCount, __ATOMIC_RELAXED) >= SPARE_KEEP) paRelease(b, sizeof(Board));
#endif
    while (__atomic_exchange_n(&spareLock, 1, __ATOMIC_ACQUIRE)) {}
    *(Board **)b = spareOf; spareOf = b; __atomic_fetch_add(&spareCount, 1, __ATOMIC_RELAXED);
    __atomic_store_n(&spareLock, 0, __ATOMIC_RELEASE);
    return;
  }
  *(Board **)b = freeOf(thId); freeOf(thId) = b; freeCount(thId)++;
}
// Spare boards on thread k's list; k = -1: the heap's top, in 64 KiB pages; k = -2: SPARES.
EXPORT(nb_pool_stat) int nb_pool_stat(int k) { return k == -2 ? __atomic_load_n(&spareCount, __ATOMIC_RELAXED) : k < 0 ? (int)(heapTop >> 16) : k < MAXTHREADS ? freeCount(k) : 0; }
#ifdef COPY_BOARD
static void copyBoard(Board *dst, const Board *src) { COPY_BOARD(dst, src); }
#else
static void copyBoard(Board *dst, const Board *src) { memcpy(dst, src, BOARD_BYTES(src)); }
#endif
EXPORT(nb_copy) void nb_copy(Board *dst, Board *src) { copyBoard(dst, src); }

