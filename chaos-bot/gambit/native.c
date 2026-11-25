// GAMBIT IN THE GAME'S OWN PROCESS (libgambit.so, loaded by lua/GambitNative.lua): the C engine, Gambit (gambit.c) and its frame
// loop (front.c), and Gambit's own thread, which answers the frame loop's questions while the game runs on. The game's thread only loads
// the board, plays the frame loop and returns the keys. What a host gives -- the heap, the clock, a lock and a thread, the log -- is
// host.c's, built beside this with the system's headers (which this file, on the engine's own libc.h, cannot include).
//
//   clang -O3 -march=native -pthread -fPIC -shared -DPA_HEAP native.c host.c -lm -o libgambit.so      (build.sh)

// (the engine's thread pool, search.h, waits on wasm's atomics: natively a futex, host.c -- the workers gn_setup starts)
int hostFutexWait(int *p, int v), hostFutexWake(int *p, int n);
#define __builtin_wasm_memory_atomic_notify(p, n) hostFutexWake((int *)(p), (int)(n))
#define __builtin_wasm_memory_atomic_wait32(p, v, t) hostFutexWait((int *)(p), (int)(v))
#include "gambit.c"

// ---------------------------------------------------------------- host.c
void *paHeap(unsigned long n);
double hostNowMs(void);
void hostThreadStats(double *out); void hostPopulate(void);
void hostLock(void), hostUnlock(void), hostWait(void), hostSignal(void);
int hostThread(void *(*fn)(void *));
int hostWorkers(void *(*fn)(void *), int most);
int hostIdleThread(void *(*fn)(void *), const char *name);
int hostOpenLog(const char *path);
void hostLog(const char *s);
void hostLogFlush(void);
int hostHeapMB(void);
int snprintf(char *s, unsigned long n, const char *fmt, ...);
int strncmp(const char *a, const char *b, unsigned long n);
char *strchr(const char *s, int c);
int atoi(const char *s);
int abs(int v);
void *memmove(void *d, const void *s, unsigned long n);

// ---------------------------------------------------------------- what the engine and Gambit take from a host
static int32_t abortId, curQid;
// 1 once the question being answered is no longer wanted: every question up to abortId is not
int abort_poll(void) { return __atomic_load_n(&abortId, __ATOMIC_SEQ_CST) >= __atomic_load_n(&curQid, __ATOMIC_SEQ_CST) ? 1 : 0; }
double clock_ms(void) { return hostNowMs(); }
static void flog(const char *s) { hostLog(s); }

#include "front.c"

// ---------------------------------------------------------------- Gambit's thread
// One question waits at most: a newer one takes its place. Answers wait in order for the frame loop to take them.
#define ANSN 16
static int workerOn, qHas, qReset, gnQuit;
static FQuestion qSlot;
static Board *qSlotBoard;
static FAnswer answers[ANSN];
static int ansHead, ansN;
static int32_t gnReaction = 12, gnPlanHealth = 1;
static char ruleNames[MAXRULES][48];

static void postQuestion(FQuestion *q) {
  hostLock();
  if (!qSlotBoard) qSlotBoard = nb_new();
  qSlot = *q; copyBoard(qSlotBoard, q->b); qSlot.b = qSlotBoard;
  qHas = 1;
  hostSignal();
  hostUnlock();
}
static int takeAnswer(FAnswer *a) {
  hostLock();
  int got = ansN > 0;
  if (got) { *a = answers[ansHead]; ansHead = (ansHead + 1) % ANSN; ansN--; }
  hostUnlock();
  return got;
}
static int answerWaiting(int32_t id) {
  hostLock();
  int has = 0;
  for (int i = 0; i < ansN && !has; i++) has = answers[(ansHead + i) % ANSN].id == id;
  hostUnlock();
  return has;
}
static void abortTo(int32_t id) {
  int32_t old = __atomic_load_n(&abortId, __ATOMIC_SEQ_CST);
  while (id > old && !__atomic_compare_exchange_n(&abortId, &old, id, 0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST)) {}
  hostLock();
  if (qHas && qSlot.id <= id) qHas = 0;
  hostUnlock();
}
// Whether the stack would take a raise now: the engine acts on one only while nothing holds the floor.
static int canRaiseOn(Board *b) {
  return !b->preventManualRaise && !b->manualRaise && !isToppedOut(b) && !hasFallingGarbage(b) && !b->riseLock && !hasActivePanels(b) && !(b->shakeTime > 0);
}
// (and the raise the frame loop would press there: the engine step its keys are made from -- front.c keysOf -- asked on the question's
// board, so a raise is offered only where it can be pressed)
static Ctx *raiseCtx;
static int raisePresses(const FQuestion *q, Board *b) {
  raiseCtx = ctxOf(raiseCtx);
  Question qq; memset(&qq, 0, sizeof qq);
  qq.b = b; qq.holdLeft = q->holdLeft; qq.holdStarted = q->holdStarted; qq.narr = arrivalsFrom(b, q->arr, q->narr, qq.arr);
  int root = rootOf(raiseCtx, &qq);
  if (root < 0) return 0;
  int r = advance(raiseCtx, root, MK_RAISE, 0, 0, 0);
  ns_reset(raiseCtx);
  return r != STEP_NULL && r != STEP_ERR;
}
// (THE LAST BOARDS, ringKeep below)
#define RINGN 128
static Board *ring[RINGN]; static int32_t ringAt[RINGN], ringNarr[RINGN], ringAllow[RINGN]; static Arr ringArr[RINGN][MAXARR]; static int ringHead, ringCount;
// The board as base64 of its bytes (the head, the queue, the rows), for the reach report (GAMBITB)
static int b64(const unsigned char *p, int n, char *out) {
  static const char A[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  int k = 0;
  for (int i = 0; i < n; i += 3) {
    unsigned v = (unsigned)p[i] << 16 | (i + 1 < n ? (unsigned)p[i + 1] << 8 : 0) | (i + 2 < n ? p[i + 2] : 0);
    out[k++] = A[v >> 18 & 63]; out[k++] = A[v >> 12 & 63]; out[k++] = i + 1 < n ? A[v >> 6 & 63] : '='; out[k++] = i + 2 < n ? A[v & 63] : '=';
  }
  out[k] = 0;
  return k;
}
#define SAMPLEQ 32   // (a board is about 20 KB of log: one in 32 decisions keeps a game's log under a megabyte of them)
static void dumpBoard(const char *tag, int32_t at, const Board *b, const Arr *arr, int narr, int32_t allow) {
  static unsigned char bytes[sizeof(Board)];
  static char line[sizeof(Board) * 2];
  unsigned long n = BOARD_HEAD;
  memcpy(bytes, b, BOARD_HEAD);
  memcpy(bytes + n, b->inc, (unsigned long)b->ninc * sizeof(Incoming)); n += (unsigned long)b->ninc * sizeof(Incoming);
  memcpy(bytes + n, b->p, (unsigned long)b->nrows * sizeof(Panel) * (W + 1)); n += (unsigned long)b->nrows * sizeof(Panel) * (W + 1);
  int k = snprintf(line, sizeof line, "%s %d C%d:", tag, at, (int)sizeof(Board));
  k += b64(bytes, (int)n, line + k);
  k += snprintf(line + k, sizeof line - (unsigned long)k, " [");
  for (int i = 0; i < narr; i++) k += snprintf(line + k, sizeof line - (unsigned long)k, "%s[%d,%d,%d]", i ? "," : "", arr[i].at, arr[i].width, arr[i].height);
  k += snprintf(line + k, sizeof line - (unsigned long)k, "]");
  // (the input window's allowance the decision was asked under, so a replay searches inside it)
  if (allow >= 0) snprintf(line + k, sizeof line - (unsigned long)k, " a%d", allow);
  flog(line);
}
// A question answered: the board judged at level 10's health. It stops in time for its move, on
// the game's own frame, which the frame loop publishes (the frame played, when it began, the ms a frame takes): out once the frame
// before its move has begun, or sooner when what it still has to do once out (its closing work, the slowest of the last CLOSEN
// decisions') would not be done before its move's frame begins. Its searches share the time until then.
#define CLOSEN 32
static int32_t gameFrame, dueFrame;
static double gameFrameMs, gameMsPerFrame = 1000.0 / 60, closeMs[CLOSEN];
static int32_t nclose; static uint32_t frameCounter;
static double closeWorst(void) { double w = 0; for (int i = 0; i < nclose; i++) if (closeMs[i] > w) w = closeMs[i]; return w; }
// (read without a lock: the frame loop's thread must never wait on Gambit's, which reads these on every step)
static double moveStartMs(int32_t at) {
  double began, per;
  __atomic_load(&gameFrameMs, &began, __ATOMIC_SEQ_CST); __atomic_load(&gameMsPerFrame, &per, __ATOMIC_SEQ_CST);
  int32_t f = __atomic_load_n(&gameFrame, __ATOMIC_SEQ_CST);
  return began + (at - f) * per;
}
// (the client runs frames back to back to catch up: the longest such run seen, which a decision's frame comes that much sooner by --
// and never under MARGIN_FRAMES: the frame loop takes an answer at the start of its frame, and a decision stopped on the last
// millisecond before it is late by its own closing work, which a rescue's is not counted in (closeWorst). 1-4 frames late in endless,
// run 4577, once the game's frames stopped stalling and its bursts went to 0)
#define MARGIN_FRAMES 2
static int32_t gameBurst;
static int32_t burstOf(void) { int32_t b = __atomic_load_n(&gameBurst, __ATOMIC_SEQ_CST); return b > MARGIN_FRAMES ? b : MARGIN_FRAMES; }
// (A RESCUE'S HARD STOP, RESCUE_FRAMES sooner: a decision that judged nothing in time judges every line again up to the hard stop
// (decide.c rescue), and the ranking and the answer after it are 25-56 ms its closing work does not count -- run 4596, every late move
// a rescue, 1-4 frames late; at 3, runs 4600-4607 still 0-6 late, every one a rescue; and kept for the rest of the decision -- run 4612,
// 7 late in endless, the line in progress and the hold judged after the rescue to the plain stop)
#define RESCUE_FRAMES 6
static int frameOut(void) {
  int32_t more = rescueOn ? RESCUE_FRAMES : 0;
  if (__atomic_load_n(&gameFrame, __ATOMIC_SEQ_CST) >= dueFrame - burstOf() - more) return 1;
  return clock_ms() + closeWorst() >= moveStartMs(dueFrame + 1 - burstOf() - more);
}
static void ringKeep(int32_t at, int32_t allow);
static void answerOne(FQuestion *q, Board *b, FAnswer *out) {
  double t0 = clock_ms();
  if (gnPlanHealth) { b->health = imin(b->health, gnPlanHealth); b->maxHealth = imin(b->maxHealth, gnPlanHealth); }
  dueFrame = q->at - 1; clockFrameOut = frameOut; rescueOn = 0;
  // (the searches' deadline is the frame loop's own: the start of the frame the decision is cut at -- the one before its move, sooner by
  // the burst -- less its closing work)
  double due = moveStartMs(dueFrame - burstOf()) - closeWorst();
  if (!hostBoard) hostBoard = nb_new();
  cloneBoard(hostBoard, b);
  memset(&hostQ, 0, sizeof hostQ);
  hostQ.b = hostBoard; hostQ.holdLeft = q->holdLeft; hostQ.holdStarted = q->holdStarted; hostQ.tight = 0;
  hostQ.narr = arrivalsFrom(hostBoard, q->arr, q->narr, hostQ.arr);
  gb_refused(q->refA, q->refB); gb_pressed(q->swapA, q->swapB);
  hostWin = 1; winLen = q->window; nWinAges = imin(q->nages, WINMAX); for (int i = 0; i < nWinAges; i++) winAges[i] = q->ages[i];
  int32_t rescued0 = rescues;
  cdAsk = q->noRaise;
  hostMoveOff = q->moveOff;
  answerQuestion(q->id, q->at, q->topped, q->oppHas, q->oppOut, q->oppHas, q->oppTop, q->oppHas, q->oppStop, 1, q->allowance, q->lineFrom, q->linePressed,
                 !q->noRaise && canRaiseOn(hostBoard) && raisePresses(q, hostBoard), due, t0, 0);
  // (the closing work: from the moment it ran out of time to its answer -- not a decision whose lines were all judged again past the
  // clock up to the move's own frame (decide.c rescue): that is the frame's time used on purpose, and counted as closing work it took
  // every decision of the next CLOSEN its whole time -- set 89 endless 4: one rescue of 236 ms, 97 decisions starved, the board lost)
  if (clockWentOut && rescues == rescued0) { closeMs[nclose < CLOSEN ? nclose++ : (int)(frameCounter++ % CLOSEN)] = clock_ms() - clockWentOut; }
  Answer *A = &theAnswer;
  memset(out, 0, sizeof *out);
  out->id = q->id; out->epoch = q->epoch; out->at = q->at; out->kind = A->d.kind; out->move = A->d.move;
  out->tap = A->tap; out->raiseNow = A->raiseNow; out->raiseAfter = A->raiseAfter; out->raiseWait = A->raiseWait; out->nhand = A->nhand;
  for (int i = 0; i < A->nhand; i++) { out->hand[i] = A->hand[i]; out->handAt[i] = A->handAt[i]; }
  out->wastes = A->wastes; out->play = A->play; out->ended = A->ended;
  out->lineKept = A->lineKept; out->holdLives = A->holdLives; out->brk = A->brk; out->urgent = A->urgent; out->idleMs = A->idleMs;
  out->aim = A->aim;
  out->empty = A->empty; out->nalt = A->nalt; for (int i = 0; i < A->nalt; i++) out->alt[i] = A->alt[i];
  out->ms = clock_ms() - t0; out->closeMs = clockWentOut ? clock_ms() - clockWentOut : 0;
  // the log line, its rule named and its wall time added
  static char line[sizeof logBuf + 128];
  const char *s = logBuf;
  int k = 0;
  if (!strncmp(s, "GAMBITD ", 8)) {
    const char *at = strchr(s + 8, ' ');
    if (at && at[1] == '@') {
      int r = atoi(at + 2);
      k = snprintf(line, sizeof line, "%.*s %s", (int)(at - s), s, A->d.kind >= 0 && r >= 0 && r < MAXRULES ? ruleNames[r] : "");
      s = at + 2; while (*s >= '0' && *s <= '9') s++;
    }
  }
  snprintf(line + k, sizeof line - (unsigned long)k, "%s wallMs=%d out=%d heapMB=%d", s, (int)(clock_ms() - t0), clockWentOut ? (int)(clock_ms() - clockWentOut) + 1 : 0, hostHeapMB());
  flog(line);
  hostLogFlush();   // (the log written on Gambit's thread, between decisions: the game's frame never waits on the disk)
  // (a life not kept: the last decision's board, then this one -- GAMBITK)
  if (A->dumpBoard == 3) { hostLock(); int last = (ringHead - 1 + RINGN) % RINGN; if (ringCount && ring[last]) dumpBoard("GAMBITK", ringAt[last], ring[last], ringArr[last], ringNarr[last], ringAllow[last]); hostUnlock(); }
  if (A->dumpBoard) dumpBoard(A->dumpBoard == 2 ? "GAMBITT" : A->dumpBoard == 3 ? "GAMBITK" : A->dumpBoard == 4 ? "GAMBITO" : "GAMBITB", q->at, hostBoard, hostQ.arr, hostQ.narr, q->allowance);
  // (A SAMPLE OF EVERY DECISION: one question in SAMPLEQ, whatever it is, its board -- GAMBITQ, what test/decisions.txt.gz is drawn from,
  // so the replay holds the decisions a game makes and not only the ones some search came up empty on)
  static uint32_t asked;
  if (++asked % SAMPLEQ == 0) dumpBoard("GAMBITQ", q->at, hostBoard, hostQ.arr, hostQ.narr, q->allowance);
  // (a line the break search said breaks and the judge says does not: its board, rate-limited, for replaying both on it -- GAMBITU)
  static int32_t lastU = NUL;
  if (unbroken.set && (lastU == NUL || q->at - lastU >= 120 || q->at < lastU)) { lastU = q->at; dumpBoard("GAMBITU", q->at, hostBoard, hostQ.arr, hostQ.narr, q->allowance); }
  // (a line played lost a break's time sooner than one offered: its board, rate-limited, for the checks' questions -- GAMBITS; test/main.c
  // fails any such answer)
  static int32_t lastS = NUL;
  if (A->sooner && (lastS == NUL || q->at - lastS >= 60 || q->at < lastS)) { lastS = q->at; dumpBoard("GAMBITS", q->at, hostBoard, hostQ.arr, hostQ.narr, q->allowance); }
  ringKeep(q->at, q->allowance);
}
// THE LAST BOARDS: every question's board and garbage on its way, the last RINGN decisions kept, written out when the match ends (GAMBITL lines,
// oldest first) -- what a loss is replayed from.
static void ringKeep(int32_t at, int32_t allow) {
  hostLock();
  // (a question asked again for a frame no later than ones kept takes their place: the plans made past it were dropped -- the ring holds
  // one board a frame, in order, the last RINGN decisions forward)
  while (ringCount && ringAt[(ringHead - 1 + RINGN) % RINGN] >= at) { ringHead = (ringHead - 1 + RINGN) % RINGN; ringCount--; }
  int k = ringHead;
  if (!ring[k]) ring[k] = nb_new();
  if (ring[k]) {
    cloneBoard(ring[k], hostBoard); ringAt[k] = at; ringNarr[k] = hostQ.narr; ringAllow[k] = allow;
    for (int i = 0; i < hostQ.narr; i++) ringArr[k][i] = hostQ.arr[i];
    ringHead = (ringHead + 1) % RINGN; if (ringCount < RINGN) ringCount++;
  }
  hostUnlock();
}
static void ringOut(void) {
  hostLock();
  for (int i = 0; i < ringCount; i++) { int k = (ringHead - ringCount + i + RINGN) % RINGN; dumpBoard("GAMBITL", ringAt[k], ring[k], ringArr[k], ringNarr[k], ringAllow[k]); }
  ringCount = 0;
  hostUnlock();
}
static void *workerMain(void *arg) {
  (void)arg;
  paThreadId(0);   // (the engine's thread 0, the searching one: the phases hand boards out of its pool, the workers are 1..n)
  static FQuestion q;
  Board *b = nb_new();
  for (;;) {
    hostLock();
    while (!qHas && !qReset && !gnQuit) hostWait();
    if (gnQuit) { hostUnlock(); return 0; }
    if (qReset) { qReset = 0; ringCount = 0; hostUnlock(); onStop(); gb_new_game(); continue; }
    q = qSlot; copyBoard(b, qSlotBoard); q.b = b; qHas = 0;
    __atomic_store_n(&curQid, q.id, __ATOMIC_SEQ_CST);
    hostUnlock();
    FAnswer a;
    // (the break search going on since the last answer let go first: what it grew is the frontier this decision resumes)
    onStop();
    if (abort_poll() == 1) continue;
    answerOne(&q, b, &a);
    if (abort_poll() == 1) continue;
    hostLock();
    if (ansN == ANSN) { ansHead = (ansHead + 1) % ANSN; ansN--; }
    answers[(ansHead + ansN) % ANSN] = a; ansN++;
    hostUnlock();
  }
  return 0;
}

// ---------------------------------------------------------------- the host's calls (lua/GambitNative.lua)
static int32_t gnAhead = 90, gnGap = 20, gnJitter = 16, gnFrames;
static int32_t ages[512];
// The bot's hands and pacing, level 10's health, and the run's log.
// THE WORKERS: GC_GAMBIT_WORKERS of them (host.c hostWorkers; none unset), each the
// engine's pool's (search.h workerLoop) -- every batch of steps a search hands the pool (core/nodes.h stepMany) is played on them all.
static void *gnWorker(void *arg) { paThreadId((int)(long)arg); workerLoop(); return 0; }
static void *onThreadMain(void *arg) { (void)arg; int k = __atomic_fetch_add(&onNext, 1, __ATOMIC_SEQ_CST); paThreadId(MAXTHREADS - 2 - k); onThread(k); return 0; }
// THE REAPER (core/nodes.h ctxLetGo): a thread at the idle class beside the workers, with a board pool of its own, that empties the
// contexts handed to it and hands them back. REAPN waiting at most; past them the searching thread empties its own.
#define REAPN 4
static Ctx *reapWaiting[REAPN], *reapReady[16 * REAPN];
static int32_t reapNWaiting, reapNReady, reapLock, reapWord, reapQuit, reapInline;
static void reapIn(void) { while (__atomic_exchange_n(&reapLock, 1, __ATOMIC_ACQUIRE)) {} }
static void reapOut(void) { __atomic_store_n(&reapLock, 0, __ATOMIC_RELEASE); }
static int reapHandOn(Ctx *x) {
  reapIn();
  int ok = reapNWaiting < REAPN;
  if (ok) reapWaiting[reapNWaiting++] = x;
  reapOut();
  if (!ok) { __atomic_fetch_add(&reapInline, 1, __ATOMIC_RELAXED); return 0; }
  __atomic_fetch_add(&reapWord, 1, __ATOMIC_SEQ_CST); hostFutexWake(&reapWord, 1);
  return 1;
}
static Ctx *reapTakeOn(int32_t least) {
  reapIn();
  Ctx *x = 0;
  for (int i = reapNReady - 1; i >= 0 && !x; i--) if (reapReady[i]->cap >= least) { x = reapReady[i]; reapReady[i] = reapReady[--reapNReady]; }
  reapOut();
  return x;
}
static void reapReturnOn(Ctx *x) {
  reapIn();
  if (reapNReady < 16 * REAPN) reapReady[reapNReady++] = x;
  reapOut();
}
static void *reapMain(void *arg) {
  (void)arg;
  paThreadId(MAXTHREADS - 2 - ONN);
  for (;;) {
    int32_t w = __atomic_load_n(&reapWord, __ATOMIC_SEQ_CST);
    reapIn();
    Ctx *x = reapNWaiting ? reapWaiting[--reapNWaiting] : 0;
    reapOut();
    if (x) {
      ns_reset(x);
      reapIn();
      // (the ready list never fills: a context is made only when it is empty, so there are never more than the searches each thread
      // keeps one for -- the planner's, the extension's, the survival search's -- and the ones waiting)
      if (reapNReady < 16 * REAPN) reapReady[reapNReady++] = x;
      reapOut();
      continue;
    }
    if (__atomic_load_n(&reapQuit, __ATOMIC_SEQ_CST)) return 0;
    hostFutexWait(&reapWord, w);
  }
}
static void reapEnd(void) { __atomic_store_n(&reapQuit, 1, __ATOMIC_SEQ_CST); __atomic_fetch_add(&reapWord, 1, __ATOMIC_SEQ_CST); hostFutexWake(&reapWord, -1); }
int gn_setup(int reaction, int swapGap, int cursor, int ahead, int gap, int jitter, int planHealth, const char *logPath) {
  hostTaps = 1;
  // (the io the host writes every frame, every page of it written once here, before play: a page the kernel maps on its first write cost
  // the frame that first reached it 9-17 ms -- a stack or a queue grown past any before)
  memset(ioBody, 0, sizeof ioBody); memset(ioHead, 0, sizeof ioHead);
  hostPopulate();
  // (THE GAME'S THREAD, which calls this and plays the frame loop -- its keys are engine steps (front.c keyCtx) -- is the engine's last
  // thread, its own board pool: thread 0 is Gambit's, the one the workers' phases hand boards out of)
  paThreadId(MAXTHREADS - 1);
  gnReaction = reaction; gnAhead = ahead; gnGap = gap; gnJitter = jitter; gnPlanHealth = planHealth;
  gb_config(reaction, swapGap, cursor);
  if (logPath && *logPath) hostOpenLog(logPath);
  static int started;
  if (!started) {
    started = 1;
    int n = hostWorkers(gnWorker, MAXTHREADS - 3 - ONN);
    while (__atomic_load_n(&pool.nworkers, __ATOMIC_SEQ_CST) < n) {}
    // (and the break search between decisions, threads of their own beside the pool, where there are workers' CPUs for them: the wider
    // beam's on a second where there are four)
    int want = n >= 4 ? 2 : n > 0 ? 1 : 0;
    // (one begun at a time: each reads what it is to run from the host as it starts -- host.c idleFn)
    for (int k = 0; k < want; k++) if (hostIdleThread(onThreadMain, "gbetween") == 0) { onThreads++; while (__atomic_load_n(&onNext, __ATOMIC_SEQ_CST) < onThreads) {} }
    if (onThreads > 0) onThreadOn = 1;
    // (the reaper where there are workers' CPUs for it)
    if (n > 0 && hostIdleThread(reapMain, "greap") == 0) { reapHand = reapHandOn; reapTake = reapTakeOn; reapReturn = reapReturnOn; }
    static char line[64]; snprintf(line, sizeof line, "GAMBIT workers %d", n); flog(line);
  }
  return 0;
}
// The rules, as the loader encodes them (gambit.js rulesWords), in gn_io; set before the first question.
int32_t *gn_io(void) { return gbIo; }
int gn_rules(int n) { return gb_rules(n); }
void gn_rule_name(int i, const char *name) {
  if (i >= 0 && i < MAXRULES) snprintf(ruleNames[i], sizeof ruleNames[i], "%s", name);
  // (the fill rule's name found: its break search's share, answer.c FILL_UNDER_SHARE)
  if (name && name[0] == 'f' && name[1] == 'i' && name[2] == 'l' && name[3] == 'l' && name[4] == 0) fillName = i;
}
void gn_profile(int mode, int ms, int extendMs, int width, int depth, int pool, int extendDepth, int extendOff) {
  gb_profile(mode, ms, extendMs, width, depth, pool, extendDepth, extendOff, cfgReaction, cfgSwapGap, cfgCursor);
}
// Switching (answer.c gb_switch): the profile's stretch between switches, in frames; each match draws its own (gn_match)
void gn_switch(int min, int max) { gb_switch(min, max); }
// The break search's share in percent, under garbage and otherwise (answer.c gb_share; 0 the default)
void gn_share(int under, int otherwise) { gb_share(under, otherwise); }
// The mode a named opener gives way to at the top-out (answer.c gb_then; -1 none)
void gn_then(int rule) { gb_then(rule); }
void gn_thread_stats(double *out) { hostThreadStats(out); }
int32_t *gn_tele(void) { return tele; }
int32_t *gn_ages(void) { return ages; }
static void statsOut(void) { static char line[4096]; if (!F.st.frames) return; statsLine(line, sizeof line); flog(line); }
// (the last frame a game was asked on: a clock behind it is a game begun again)
static int32_t lastClock = NUL;
// A match begins: nothing of the last is carried on.
void gn_match(void) {
  statsOut();
  lastClock = NUL;
  frontNew(gnReaction, gnAhead, gnGap, gnJitter);
  gb_switch_game((uint32_t)clock_ms());
  // (the frame clock and the closing times are this game's: the last game's slowest closings would cut this one's decisions short)
  nclose = 0; frameCounter = 0;
  __atomic_store_n(&gameFrame, 0, __ATOMIC_SEQ_CST); __atomic_store_n(&gameBurst, 0, __ATOMIC_SEQ_CST); dueFrame = 0;
  { double z = 0; __atomic_store(&gameFrameMs, &z, __ATOMIC_SEQ_CST); }
  gnFrames = 0;
  hostLock();
  qHas = 0; qReset = 1; ansN = 0;
  hostSignal();
  hostUnlock();
  if (!workerOn) { workerOn = 1; hostThread(workerMain); }
}
// THE FRAME PUBLISHED (the one a decision's guard reads, frameOut): the frame played, when it began, the ms a frame takes, the longest
// burst -- every frame the game plays, the countdown's too
static void framePublish(int32_t clock) {
  double t = clock_ms(), per = F.msPerFrame, last;
  static int32_t run;
  __atomic_load(&gameFrameMs, &last, __ATOMIC_SEQ_CST);
  run = last && t - last < per / 2 ? run + 1 : 0;
  // (the longest burst within the input window just past, not the longest ever: a hiccup long gone takes no frames from a decision)
  static int32_t burstAt[64], burstRun[64], nb, lastAt = NUL;
  // (a game's frames start again at its countdown: the last game's bursts are not this one's -- kept, they read as just past forever,
  // and each game of a session left its decisions less time than the last)
  if (lastAt != NUL && clock < lastAt) nb = 0;
  lastAt = clock;
  if (run > 0) { int k = nb < 64 ? nb++ : 0; if (k == 0 && nb == 64) { for (int i = 1; i < 64; i++) { burstAt[i - 1] = burstAt[i]; burstRun[i - 1] = burstRun[i]; } k = 63; } burstAt[k] = clock; burstRun[k] = run; }
  int32_t worst = 0, win = F.window > 0 ? F.window : 600;
  for (int i = 0; i < nb; i++) if (burstAt[i] <= clock && clock - burstAt[i] <= win && burstRun[i] > worst) worst = burstRun[i];
  __atomic_store_n(&gameBurst, worst, __ATOMIC_SEQ_CST);
  __atomic_store(&gameFrameMs, &t, __ATOMIC_SEQ_CST); __atomic_store(&gameMsPerFrame, &per, __ATOMIC_SEQ_CST); __atomic_store_n(&gameFrame, clock, __ATOMIC_SEQ_CST);
}
// THE COUNTDOWN (lua/GambitNative.lua, the frames before play): the opening asked on the layers shown (front.c frontCountdown), the
// opponent as the host has it -- a fight's opening is the opener's, planned through the countdown
int gn_countdown(int left, int limit, int window, int oppHas, int oppOut, int oppTop, int oppStop) {
  if (nb_load(F.truth)) return -1;
  int32_t clock = F.truth->clock;
  if (lastClock != NUL && clock < lastClock) gn_match();
  lastClock = clock;
  // (the opponent set once the game is begun: gn_match clears the frame loop's state, and an opponent set before it is lost -- the
  // opening asked as if nobody were across)
  F.oppHas = oppHas; F.oppOut = oppOut; F.oppTop = oppTop; F.oppStop = oppStop;
  if (limit > 0) F.limit = limit;
  if (window > 0) F.window = window;
  framePublish(clock);
  if (!workerOn) return 0;
  return frontCountdown(left);
}
// A frame in play: the board in the engine's io (the host wrote it, nb_io_head / nb_io_body), the telegraphs in gn_tele, the input
// budget's limit and window and the frames ago each key inside it went down (gn_ages), and the opponent. The keys to press, or -1.
// (a clock behind the last frame's is a game begun again without gn_match: begun so. A question asked for a frame sooner than the
// last one asked is the same game -- the frame loop asks again after it drops its plans.)
int gn_frame(int limit, int window, int nages, int oppHas, int oppOut, int oppTop, int oppStop) {
  if (nb_load(F.truth)) return -1;
  int32_t clock = F.truth->clock;
  if (lastClock != NUL && clock < lastClock) gn_match();
  lastClock = clock;
  // (the game over, once: what is logged after it is the frame loop asking on a board that no longer plays)
  if (F.truth->gameOver && !F.overLogged) { char l[64]; snprintf(l, sizeof l, "GAMEOVER clock %d", clock); flog(l); F.overLogged = 1; }
  framePublish(clock);
  if (limit > 0) F.limit = limit;
  if (window > 0) F.window = window;
  F.npress = 0;
  for (int i = 0; i < nages && i < 512; i++) F.pressFrames[F.npress++] = clock - ages[i];
  F.oppHas = oppHas; F.oppOut = oppOut; F.oppTop = oppTop; F.oppStop = oppStop;
  double t0 = clock_ms();
  arrivalsOf(F.truth);
  double t1 = clock_ms();
  int32_t bits = frontFrame();
  double t2 = clock_ms();
  afterFrame(bits);
  // (every frame: the break search going on beside the decisions has the frame's work)
  onGrant(0);
  double t3 = clock_ms();
  // (a frame loop over a frame's time: where it went)
  if (t3 - t0 > 8) { char l[200]; snprintf(l, sizeof l, "SLOWLOOP clock %d: %.1f ms (arrivals %.1f, frame %.1f, after %.1f)", clock, t3 - t0, t1 - t0, t2 - t1, t3 - t2); flog(l); }
  // (the stats now and then, and when the game is lost: a client may be stopped at any frame)
  if (++gnFrames % 600 == 0 || F.truth->gameOverClock > 0) statsOut();
  if (F.truth->gameOverClock > 0) hostLogFlush();   // (the game over: the stats written now, whatever ends the process next)
  return bits;
}
void gn_end(void) { statsOut(); frontTraceOut(); ringOut(); hostLogFlush(); }
// THE INSTANCE ENDS (lua/GambitNative.lua, a match's own instance let go): Gambit's thread told to stop and joined, the search between
// decisions and the pool's workers likewise, then every block of its memory freed and its log closed -- the library can be unloaded
void hostJoin(int kind); void hostQuit(void);
void gn_quit(void) {
  abortTo(0x7ffffff0);
  __atomic_store_n(&jobStop, 1, __ATOMIC_SEQ_CST);
  hostLock(); gnQuit = 1; qHas = 0; hostSignal(); hostUnlock();
  hostJoin(0);
  reapHand = 0; onStop(); onEnd(); reapEnd(); hostJoin(1);
  poolEnd(); hostJoin(2);
  { static char line[64]; snprintf(line, sizeof line, "GAMBIT reaped here %d", reapInline); flog(line); }
  hostQuit();
}
// A line from the host into the run's log (a slow frame's parts, say)
void gn_log(const char *s) { flog(s); }
// (the C checks, built by ./build.sh test)
#ifdef GB_TEST
#include "test/cells_ref.c"
#include "test/bits_check.c"
#include "test/decide_check.c"
#endif
