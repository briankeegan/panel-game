// GAMBIT'S TURN (plans/decision.md): a question from the frame loop answered by Gambit alone -- the break search, the
// decision, the move. What carries from one decision to the next lives here: the break search's lines, the boards this dig has stood
// on, the line toward a break begun, the line in progress, the pair the last swap swapped.

#define BREAK_SHARE 0.4    // of the searches' time (propose.c leftMs), for the break search
#define UNDER_SHARE 0.75   // with garbage on the board: there the break is what saves the board
// (the profile's own, in percent, where it gives one: gb_share)
static double breakShare = BREAK_SHARE, underShare = UNDER_SHARE;
#define FILL_UNDER_SHARE 0.9   // in fill, with garbage on the board: fill buries the board in slabs, and only breaks keep it (seed 86: 27 and 27 of 28
                               // at 0.9, 23, 24 and 24 at 0.75; finish them at 0.9 for every mode: 22, at 0.75: 27)
static int32_t fillName = -1;  // the host's index of the fill rule's name (native.c gn_rule_name), -1 none
#define BREAK_MIN_MS 5
#define BREAK_MAX_MS 400
#define ROW_STEPS 16


// ---- the garbage the search digs toward: the id of the lowest block on the board
static int lowestGarbageRowOf(const Board *b) {
  for (int r = 1; r < b->nrows; r++) for (int c = 1; c <= W; c++) if (b->p[r][c].f[ISGARBAGE]) return r;
  return 0;
}
static int32_t digTargetOf(const Board *b) {
  int r = lowestGarbageRowOf(b);
  if (r) for (int k = 1; k <= W; k++) if (b->p[r][k].f[ISGARBAGE]) return b->p[r][k].f[GARBAGEID];
  return NUL;
}

// ---- THE DIG: the boards stood on since the garbage the break search digs toward was first the lowest:
// each row's colours, garbage as G
#define KEYLEN 160
#define DIGMAX 8192
static char digSeen[DIGMAX][KEYLEN]; static int32_t digN, digGid = NUL, digOn;
static int keyOf(const Board *b, char *out) {
  int k = 0;
  for (int r = 1; r < b->nrows && k < KEYLEN - 8; r++) {
    for (int c = 1; c <= W; c++) {
      const int32_t *f = b->p[r][c].f;
      if (f[ISGARBAGE]) out[k++] = 'G';
      else { int32_t v = f[COLOR] == NUL ? 0 : f[COLOR]; char d[12]; int nd = 0; if (!v) d[nd++] = '0'; while (v > 0) { d[nd++] = (char)('0' + v % 10); v /= 10; } while (nd) out[k++] = d[--nd]; }
    }
    out[k++] = '|';
  }
  out[k] = 0;
  return k;
}
static int sameDigKey(const char *a, const char *b) { while (*a && *a == *b) { a++; b++; } return *a == *b; }
static int digHas(const char *key) { for (int i = 0; i < digN; i++) if (sameDigKey(digSeen[i], key)) return 1; return 0; }
static void digAdd(const char *key) { if (digN < DIGMAX && !digHas(key)) { for (int i = 0; i < KEYLEN; i++) { digSeen[digN][i] = key[i]; if (!key[i]) break; } digN++; } }
// (the board a first swap leaves: pressed and six frames run)
static int seenDigHas(const Board *b, int32_t mv) {
  if (!digOn) return 0;
  static Board *t;
  if (!t) t = nb_new();
  cloneBoard(t, b);
  t->curRow = CR(mv); t->curCol = CC(mv);
  if (tryQueueSwap(t, CR(mv), CC(mv))) for (int f = 0; f < 6; f++) { t->input = 0; run(t); }
  char key[KEYLEN];
  keyOf(t, key);
  return digHas(key);
}

// ---- THE BREAK SEARCH CARRIED ON: this beam's lines, on this board, the garbage they dig toward, the move played and the line handed
// on after it, a bottom-row panel none of them touches, and the line toward a break played
// (key: the board the lines were grown on, cell by cell -- keyOf)
typedef struct { int32_t set, gid, anchorRow, anchorCol, anchorId, id, playedHold, played, nhanded, handed[MAXLINE], ntoward, toward[MAXPATH]; Paths paths; char key[KEYLEN]; } Kept;
static Kept theKept;
// (a life not kept: the last decision's verdict under garbage, its next landing frame and queue -- answerTurn's log)
#define LIFEDUMPS 20
static int32_t lifeLived, lifeLand, lifeQk, lifeDumps;
static int32_t towardPlayedN, towardPlayed[MAXPATH];
static int32_t riseSince(const Board *b, int row, int col, int32_t id) {
  for (int r = 1; r < b->nrows; r++) if (b->p[r][col].f[ID] == id) return r - row;
  return NOT_ASKED;
}
static int playedSince(const Kept *K, int32_t lineFrom, int32_t linePressed, int32_t *pre) {
  int n = lineFrom == K->id && K->nhanded ? imin(linePressed, K->nhanded) : 0, k = 0;
  if (!K->playedHold) pre[k++] = K->played;
  for (int i = 0; i < n; i++) pre[k++] = K->handed[i];
  return k;
}
static int startsWith(const int32_t *p, int np, const int32_t *pre, int npre) { if (np <= npre) return 0; for (int i = 0; i < npre; i++) if (p[i] != pre[i]) return 0; return 1; }
static int carriedPaths(const Board *b, int32_t lineFrom, int32_t linePressed, Paths *out) {
  out->n = 0; out->cont = 0;
  Kept *K = &theKept;
  if (!K->set || !K->paths.n || digTargetOf(b) != K->gid) return 0;
  int32_t dr = riseSince(b, K->anchorRow, K->anchorCol, K->anchorId);
  if (dr == NOT_ASKED) return 0;
  int32_t pre[MAXLINE + 1];
  int npre = playedSince(K, lineFrom, linePressed, pre);
  // (THE SAME BOARD, HELD ON: no swap played since and every cell as it was -- a slab popping over a stack that cannot move, garbage at
  // rest -- so the search goes on from its frontier, Paths.cont; a board that differs in any cell is searched from its own first swaps)
  { char key[KEYLEN]; keyOf(b, key); out->cont = !npre && !dr && sameDigKey(K->key, key) ? K->paths.cont : 0; }
  // (THE LINE TOWARD A BREAK BEGUN: the rest of the one played last, the same moves taken off)
  if (K->ntoward && startsWith(K->toward, K->ntoward, pre, npre)) {
    towardRestLen = K->ntoward - npre;
    for (int i = 0; i < towardRestLen; i++) towardRest[i] = (CR(K->toward[npre + i]) + dr) * 8 + CC(K->toward[npre + i]);
  }
  for (int i = 0; i < K->paths.n; i++) {
    if (!startsWith(K->paths.path[i], K->paths.len[i], pre, npre)) continue;
    int t = out->n++;
    out->len[t] = K->paths.len[i] - npre;
    for (int k = 0; k < out->len[t]; k++) out->path[t][k] = (CR(K->paths.path[i][npre + k]) + dr) * 8 + CC(K->paths.path[i][npre + k]);
  }
  return 1;
}
// (a frontier kept: K anchored to a bottom-row panel the move played and the swaps handed on do not touch, with what was played)
static int anchorKept(Kept *K, const Paths *paths, int kind, int32_t move, const int32_t *handed, int nhanded, int32_t qid) {
  const Board *b = decQ.b;
  for (int col = 1; col <= W; col++) {
    int32_t id = b->p[1][col].f[ID];
    if (id == NUL) continue;
    int touched = 0;
    if (kind == 1 && CR(move) == 1 && (CC(move) == col || CC(move) + 1 == col)) touched = 1;
    for (int i = 0; i < nhanded; i++) if (CR(handed[i]) == 1 && (CC(handed[i]) == col || CC(handed[i]) + 1 == col)) touched = 1;
    if (touched) continue;
    K->set = 1; K->paths = *paths; K->gid = digTargetOf(b); K->anchorRow = 1; K->anchorCol = col; K->anchorId = id; K->id = qid;
    K->playedHold = kind == 0; K->played = move; K->nhanded = nhanded; for (int i = 0; i < nhanded; i++) K->handed[i] = handed[i];
    return 1;
  }
  return 0;
}
// THE PLAN KEPT (search/plan.c planOut): the planner's lines, anchored as the break search's are, and re-rooted at the next decision --
// the swaps played since taken off, the rows risen since added (plannedPaths: the next plan's seeds)
static Kept thePlanKept;
static void keepPlan(int kind, int32_t move, const int32_t *handed, int nhanded, int32_t qid) {
  memset(&thePlanKept, 0, sizeof thePlanKept);
  if (!planOut.n || !(kind == 0 || kind == 1)) return;
  anchorKept(&thePlanKept, &planOut, kind, move, handed, nhanded, qid);
}
static int plannedPaths(const Board *b, int32_t lineFrom, int32_t linePressed, Paths *out) {
  out->n = 0;
  Kept *K = &thePlanKept;
  if (!K->set || !K->paths.n) return 0;
  int32_t dr = riseSince(b, K->anchorRow, K->anchorCol, K->anchorId);
  if (dr == NOT_ASKED) return 0;
  int32_t pre[MAXLINE + 1];
  int npre = playedSince(K, lineFrom, linePressed, pre);
  for (int i = 0; i < K->paths.n; i++) {
    if (!startsWith(K->paths.path[i], K->paths.len[i], pre, npre)) continue;
    int t = out->n++;
    out->len[t] = K->paths.len[i] - npre;
    for (int k = 0; k < out->len[t]; k++) out->path[t][k] = (CR(K->paths.path[i][npre + k]) + dr) * 8 + CC(K->paths.path[i][npre + k]);
  }
  return out->n > 0;
}
// THE BREAK SEARCH GOING ON BESIDE THE DECISIONS (plans/gambit-machinery.md): under garbage, from the frontier a decision resumes, a
// thread of its own at the idle class searches the decision's board on through the decision and past its answer, a frame's work a
// frame (onGrant, native.c gn_frame), until the next decision takes it back (onStop). Where the decision found no break, what the thread
// reached is kept in place of the decision's frontier for the next decision to resume -- when it searched longer than the decision did,
// or found one. A break it finds is kept as the frontier's first line, played again first.
#define ON_SLICE_MS (1000.0 / 60)
// (two threads where there are the CPUs for them: the first grows the touch beam, the second its wider beam (touchFrom) from the same
// frontier -- as the decision's break and wide jobs split it -- each into its own; a break either finds is handed on, the first's first)
#define ONN 2
typedef struct { int32_t state, done, slices, found; Broke br; Paths seeds; } OnT;
static OnT onT[ONN];
static int32_t onThreads, onNext;
static int32_t onWanted; static double onDecMs;   // (the decision kept a frontier, and the time its own break search took)
static int32_t decTap;   // (the decision's pressTap, for its jobs' threads and the search between decisions)
static int32_t onActive, onGranted, onLogSlices, onLogFound, onLogDeep, onLogKept;   // (the log's: the slices the first searched and a break found by either, the last let go -- onStop -- and its deepest line, and whether it was handed on)
static void keepFrontier(const Broke *br, int kind, int32_t move, const int32_t *handed, int nhanded, int32_t qid) {
  memset(&theKept, 0, sizeof theKept); onWanted = 0;
  if (!br || !br->keepOut.n || br->depth || !(kind == 0 || kind == 1)) return;
  const Board *b = decQ.b;
  for (int col = 1; col <= W; col++) {
    int32_t id = b->p[1][col].f[ID];
    if (id == NUL) continue;
    int touched = 0;
    if (kind == 1 && CR(move) == 1 && (CC(move) == col || CC(move) + 1 == col)) touched = 1;
    for (int i = 0; i < nhanded; i++) if (CR(handed[i]) == 1 && (CC(handed[i]) == col || CC(handed[i]) + 1 == col)) touched = 1;
    if (touched) continue;
    Kept *K = &theKept;
    K->set = 1; K->paths = br->keepOut; K->gid = digTargetOf(b); K->anchorRow = 1; K->anchorCol = col; K->anchorId = id; K->id = qid;
    K->playedHold = kind == 0; K->played = move; K->nhanded = nhanded; for (int i = 0; i < nhanded; i++) K->handed[i] = handed[i];
    K->ntoward = towardPlayedN; for (int i = 0; i < towardPlayedN; i++) K->toward[i] = towardPlayed[i];
    keyOf(b, K->key);
    // (and grown on between decisions: the frontier the next decision resumes -- onThread)
    onWanted = 1; onDecMs = C2.brMs;
    return;
  }
}
// (their own threads, beside the pool -- the pool may be the readiness's past the decision: native.c onThreadMain at the idle class on the
// workers' CPUs. state: 0 idle, 1 asked to run, 2 running)
static int32_t onThreadOn, onQuit;
static void onThread(int k) {
  OnT *T = &onT[k];
  inJob = 2; touchFrom = k;
  for (;;) {
    int32_t st;
    while ((st = __atomic_load_n(&T->state, __ATOMIC_ACQUIRE)) != 1) __builtin_wasm_memory_atomic_wait32(&T->state, st, -1);
    if (__atomic_load_n(&onQuit, __ATOMIC_ACQUIRE)) { __atomic_store_n(&T->state, 0, __ATOMIC_RELEASE); return; }
    __atomic_store_n(&T->state, 2, __ATOMIC_RELEASE);
    pressTight = decQ.tight; pressTap = decTap; ncache = 0;
    int32_t pop = popLeft(decQ.b);
    for (;;) {
      int32_t g;
      while ((g = __atomic_load_n(&onGranted, __ATOMIC_ACQUIRE)) == __atomic_load_n(&T->done, __ATOMIC_ACQUIRE) && !__atomic_load_n(&onStopReq, __ATOMIC_ACQUIRE))
        __builtin_wasm_memory_atomic_wait32(&onGranted, g, -1);
      if (__atomic_load_n(&onStopReq, __ATOMIC_ACQUIRE)) break;
      if (!T->found) {
        clockWork = 0; clockAborted = 0; clockPoll = 0; clockShare = nowMs() + ON_SLICE_MS;
        listDefault = 1;
        breakMoves(&decQ, pop ? pop + LINEUP_AFTER : 0, &T->seeds, &T->br);
        listDefault = 0;
        clockShare = 0;
        // (a slice the stop cut short is not counted: its frontier is the one before it)
        if (!__atomic_load_n(&onStopReq, __ATOMIC_ACQUIRE)) {
          if (T->br.depth) T->found = 1;
          else if (T->br.keepOut.n) T->seeds = T->br.keepOut;   // (the same board: carried on, Paths.cont)
          T->slices++;
        }
      }
      __atomic_add_fetch(&T->done, 1, __ATOMIC_RELEASE);
      __builtin_wasm_memory_atomic_notify(&T->done, 1);
    }
    __atomic_store_n(&T->state, 0, __ATOMIC_RELEASE);
    __builtin_wasm_memory_atomic_notify(&T->state, 1);
  }
}
// (begun with the decision's break search, from the frontier it resumes, on the decision's thread; let go before the next question is
// answered, on the same thread)
static void onStart(const Paths *seeds) {
  onWanted = 0;
  for (int k = 0; k < ONN; k++) { onT[k].slices = 0; onT[k].found = 0; }
  if (!onThreadOn) return;
  __atomic_store_n(&onStopReq, 0, __ATOMIC_SEQ_CST);
  int32_t g = __atomic_load_n(&onGranted, __ATOMIC_ACQUIRE);
  for (int k = 0; k < onThreads; k++) { OnT *T = &onT[k]; if (seeds) T->seeds = *seeds; else T->seeds.n = 0; __atomic_store_n(&T->done, g, __ATOMIC_RELEASE); }
  __atomic_store_n(&onActive, 1, __ATOMIC_RELEASE);
  for (int k = 0; k < onThreads; k++) { __atomic_store_n(&onT[k].state, 1, __ATOMIC_RELEASE); __builtin_wasm_memory_atomic_notify(&onT[k].state, 1); }
}
// (the threads told to end -- the instance quitting, native.c gn_quit -- once nothing runs on them)
static void onEnd(void) {
  if (!onThreadOn) return;
  __atomic_store_n(&onQuit, 1, __ATOMIC_SEQ_CST);
  for (int k = 0; k < onThreads; k++) { __atomic_store_n(&onT[k].state, 1, __ATOMIC_RELEASE); __builtin_wasm_memory_atomic_notify(&onT[k].state, 1); }
}
// (every frame: a frame's work handed to them)
static void onGrant(int wait) {
  if (!__atomic_load_n(&onActive, __ATOMIC_ACQUIRE)) return;
  int32_t g = __atomic_add_fetch(&onGranted, 1, __ATOMIC_RELEASE);
  __builtin_wasm_memory_atomic_notify(&onGranted, ONN);
  if (wait) for (int k = 0; k < onThreads; k++) { int32_t d; while ((d = __atomic_load_n(&onT[k].done, __ATOMIC_ACQUIRE)) < g && __atomic_load_n(&onActive, __ATOMIC_ACQUIRE)) __builtin_wasm_memory_atomic_wait32(&onT[k].done, d, -1); }
}
static void onStop(void) {
  if (!__atomic_load_n(&onActive, __ATOMIC_ACQUIRE)) return;
  __atomic_store_n(&onStopReq, 1, __ATOMIC_SEQ_CST);
  __builtin_wasm_memory_atomic_notify(&onGranted, ONN);
  for (int k = 0; k < onThreads; k++) { int32_t st; while ((st = __atomic_load_n(&onT[k].state, __ATOMIC_ACQUIRE)) != 0) __builtin_wasm_memory_atomic_wait32(&onT[k].state, st, -1); }
  __atomic_store_n(&onActive, 0, __ATOMIC_RELEASE);
  for (int k = 0; k < onThreads; k++) __builtin_wasm_memory_atomic_notify(&onT[k].done, 1);
  const OnT *A = &onT[0], *F = A->found ? A : onThreads > 1 && onT[1].found ? &onT[1] : 0;
  onLogSlices = A->slices; onLogFound = F != 0;
  onLogDeep = 0; for (int i = 0; i < A->seeds.n; i++) onLogDeep = imax(onLogDeep, A->seeds.len[i]);
  // (handed on only where the decision kept a frontier, found no break, and the first thread searched longer than it did, reached deeper
  // than the frontier it kept, or either found one)
  int keptDeep = 0; for (int i = 0; theKept.set && i < theKept.paths.n; i++) keptDeep = imax(keptDeep, theKept.paths.len[i]);
  onLogKept = 0;
  if (!A->slices || !onWanted || (!F && onLogDeep <= keptDeep && A->slices * ON_SLICE_MS <= onDecMs)) return;
  // (kept as the decision kept it -- its board, its move and the swaps it handed on -- the break found first)
  static Paths kept;
  kept.n = 0; kept.cont = F ? 0 : A->seeds.cont;
  if (F && F->br.pathLen > 0) { kept.len[0] = F->br.pathLen; for (int k = 0; k < F->br.pathLen && k < MAXPATH; k++) kept.path[0][k] = F->br.path[k]; kept.n = 1; }
  const Paths *from = F ? &F->br.keepOut : &A->seeds;
  for (int i = 0; i < from->n && kept.n < KEEPN; i++, kept.n++) { kept.len[kept.n] = from->len[i]; for (int k = 0; k < from->len[i]; k++) kept.path[kept.n][k] = from->path[i][k]; }
  if (kept.n && theKept.set) { theKept.paths = kept; onLogKept = 1; }
}

// THE BREAK SEARCH, in its share of the decision's time -- or, with workers, on one of them beside the other searches, in all of theirs
static Broke theBr;
static int32_t brCut, brResumed;
static Paths brResume; static int brHave;
// (the search itself, on whichever thread runs it: what it reads is the question, the read and the kept paths, its nodes its thread's)
static void breakRunTo(const Read *R, double by, Broke *into);
static void breakRun(const Read *R, double by) { breakRunTo(R, by, &theBr); }
static void breakRunTo(const Read *R, double by, Broke *into) {
  int32_t pop = popLeft(decQ.b);
  double old = clockShareBegin(by);
  // (a list ended by "default" -- every list under garbage -- plays off it only when no break within it is found: the break off the list
  // is searched first, quick to find, so a break to play is in hand however long the list's own takes; the rest of the share then goes
  // to a break within the list, which is played instead if found)
  listDefault = 0;
  if (R->end == 1) {
    static LOCAL Broke off;
    // (resumed from the frontier kept: the last decision's and the search between decisions', both off the list -- what they reached is
    // this pass's start, not the list's)
    listDefault = 1;
    breakMoves(&decQ, pop ? pop + LINEUP_AFTER : 0, brHave ? &brResume : 0, into);
    listDefault = 0;
    off = *into;
    if (off.depth && !clockOut()) {
      breakMoves(&decQ, pop ? pop + LINEUP_AFTER : 0, brHave ? &brResume : 0, into);
      if (!into->depth) *into = off;
    }
  } else breakMoves(&decQ, pop ? pop + LINEUP_AFTER : 0, brHave ? &brResume : 0, into);
  clockShareEnd(old);
}
static int breakSearch(const Read *R, int32_t lineFrom, int32_t linePressed, double *ms) {
  int fill = fillName >= 0 && R->rule >= 0 && R->rule < theTables.n && theTables.r[R->rule].name == fillName;
  double share = R->under ? (fill ? FILL_UNDER_SHARE : underShare) : breakShare;
  *ms = 0; brCut = 0; brResumed = 0;
  // (no break search on a question due sooner than it could take: the answer would come late -- the searches' time is what it takes
  // first, and short of that, the judging's quarter: a board this near its end has a break one swap away or none (run 447, combo_storm-2
  // at 13038: a one-swap break, found in 3 ms, not searched for))
  double t = nowMs(), room = C2.due ? C2.due - C2.margin - t : 1e9;
  if (C2.due && room < BREAK_MIN_MS) return 0;
  brHave = carriedPaths(decQ.b, lineFrom, linePressed, &brResume);
  // (its share of what the searches have, propose.c leftMs: the other searches the rest, the judging its quarter)
  double by = C2.due ? t + (BREAK_MIN_MS > leftMs() * share ? BREAK_MIN_MS : leftMs() * share) : t + BREAK_MAX_MS;
  breakRun(R, by);
  brCut = nowMs() >= by; brResumed = brHave ? brResume.n : 0;
  *ms = nowMs() - t;
  return 1;
}
// THE BREAK SEARCH ON A WORKER (plans/gambit-infra.md: two plans at once): begun before the other searches, until they end
// (searchesEnd), and taken back after them -- a job no worker began by then is searched here, in what is left. Its judging is its
// thread's own (judge.c judgeCtx, outcome.c cache: LOCAL).
// (and with a second worker, the survival search too (decide.c ranked), in the same time: what it is asked of is the board alone, so it is
// searched before the judging says whether anything lives, and kept for it -- svJob)
// (THE JOBS, in the order the workers take them: the break search; the second half of the planner's list and the chain extended or begun,
// when the decision splits them off (propose.c searchPrep); the survival search -- each with what it needs from the decision, and a
// worker that finishes one takes the next)
// (and under garbage, the break search's wider touch beam on a worker of its own from the start, beside the narrower: the break it finds
// is played when the narrower finds none -- theBrWide)
enum { JOB_BREAK, JOB_PLAN, JOB_EXT, JOB_WIDE, JOB_SURVIVE };
static int32_t jobKinds[5], njobKinds;
static Broke theBrWide; static int32_t wideDone;
// (where the break search ran, for the log: 0 not run, 1 a worker beside the searches, 2 the decision after a worker had not finished it,
// 3 the decision with no worker free; and the ms it was given)
static int32_t brWhere; static double brGiven;
static int32_t hostTaps;   // (a host whose frame loop presses a line's taps as the answer says: the native one, native.c gn_setup)
static Ctx *brCtx; static const Read *brJobR; static Found *brJobS; static int64_t brJobWork; static double brJobT0, brJobBy, brJobMs; static int32_t brJobDone;
static int32_t jobEndMs[5];   // (each job's end, ms from the jobs' start, -1 not run: the log's jobs=)
static void breakJob(int32_t i) {
  // (every job ends halfway into the judging's quarter at the latest (propose.c searchesEnd to the decision's deadline) -- the planner's
  // half and the chain extended keep no share of their own past it: the decision waits on its jobs (breakEnd, jobsDone), and a job let
  // run on to the deadline leaves the lines unjudged and the answer taken after its frame)
  clockWork = brJobWork; clockShare = C2.due ? (C2.due + brJobBy) / 2 : 0; clockAborted = 0; clockPoll = 0;
  inJob = 1; pressTight = decQ.tight; pressTap = decTap; ncache = 0;
  int kind = jobKinds[i];
  if (kind == JOB_BREAK) breakRun(brJobR, brJobBy);
  else if (kind == JOB_PLAN) planJob();
  else if (kind == JOB_EXT) extJob(brJobR, brJobS);
  else if (kind == JOB_WIDE) { touchFrom = 1; breakRunTo(brJobR, brJobBy, &theBrWide); touchFrom = 0; __atomic_store_n(&wideDone, 1, __ATOMIC_RELEASE); }
  else {
    double old = clockShareBegin(brJobBy);
    svJob = outliveSave(&decQ, HORIZON + REST, REST, brJobBy - nowMs(), OUT_DEPTH, 30);
    clockShareEnd(old);
    __atomic_store_n(&svJobDone, 1, __ATOMIC_RELEASE);
  }
  inJob = 0;
  if (kind >= 0 && kind < 5) jobEndMs[kind] = (int32_t)(nowMs() - brJobT0);
  if (kind == JOB_BREAK) { brJobMs = nowMs() - brJobT0; __atomic_store_n(&brJobDone, 1, __ATOMIC_RELEASE); }
}
static int breakBegin(const Read *R, Found *S, int32_t lineFrom, int32_t linePressed) {
  brCut = 0; brResumed = 0; __atomic_store_n(&brJobDone, 0, __ATOMIC_SEQ_CST); __atomic_store_n(&svJobDone, 0, __ATOMIC_SEQ_CST);
  for (int k = 0; k < 5; k++) jobEndMs[k] = -1;
  if (pool.nworkers <= 0 || poolBusy || !C2.due || leftMs() < BREAK_MIN_MS) return 0;
  brHave = carriedPaths(decQ.b, lineFrom, linePressed, &brResume);
  brJobR = R; brJobS = S; brJobWork = clockWork; brJobT0 = nowMs(); brJobBy = searchesEnd();
  if (!brCtx) brCtx = ctxOf(0);
  __atomic_store_n(&jobStop, 0, __ATOMIC_SEQ_CST);
  // (in the order a thread takes them, and a job no thread has begun when the searches end is not begun at all (jobsDone): the survival
  // search second, the backup where nothing lives, begun every decision with a thread to spare)
  njobKinds = 0; jobKinds[njobKinds++] = JOB_BREAK;
  if (pool.nworkers >= 2) jobKinds[njobKinds++] = JOB_SURVIVE;
  if (planSplit) jobKinds[njobKinds++] = JOB_PLAN;
  if (extBeside) jobKinds[njobKinds++] = JOB_EXT;
  __atomic_store_n(&wideDone, 0, __ATOMIC_SEQ_CST);
  if (R->under && pool.nworkers >= 4) jobKinds[njobKinds++] = JOB_WIDE;
  return startJobs(brCtx, breakJob, njobKinds);
}
// (taken back when its time is up, searchesEnd: cut short when the other searches end early, the break search missed breaks -- 18 of
// 120 boards searched again, run 415, where 1 to 3 had been)
// (a decision the host let go takes its jobs back at once: a job keeps its own share and never reads the host's abort, so the decision
// would wait out the share -- and the question asked after it with it, answered past its frame. One whose frame came keeps them: its
// answer is pressed, and what they found is in it)
static int breakEnd(const Read *R, int32_t lineFrom, int32_t linePressed, double *ms) {
  if (clockAborted || abort_poll() == 1) __atomic_store_n(&jobStop, 1, __ATOMIC_SEQ_CST);
  jobsDone(brCtx);
  if (!__atomic_load_n(&brJobDone, __ATOMIC_ACQUIRE)) { brWhere = 2; brGiven = leftMs(); return breakSearch(R, lineFrom, linePressed, ms); }
  brWhere = 1; brGiven = brJobBy - brJobT0;
  if (__atomic_load_n(&wideDone, __ATOMIC_ACQUIRE) && !theBr.depth && theBrWide.depth) { theBr = theBrWide; theBr.wide = theBr.wide ? theBr.wide : 1; }
  *ms = brJobMs; brCut = brJobT0 + brJobMs >= brJobBy; brResumed = brHave ? brResume.n : 0;
  return 1;
}

// ---- THE LOG LINE: one a decision, what Gambit chose, what was played and why
static char logBuf[8192]; static int logN;
static void L_s(const char *s) { while (*s && logN < (int)sizeof logBuf - 1) logBuf[logN++] = *s++; logBuf[logN] = 0; }
static void L_i(int64_t v) { char d[24]; int n = 0, neg = v < 0; if (neg) v = -v; if (!v) d[n++] = '0'; while (v > 0) { d[n++] = (char)('0' + v % 10); v /= 10; } if (neg) L_s("-"); while (n) { char c[2] = { d[--n], 0 }; L_s(c); } }
static void L_d(double v) {
  if (v == (double)(int64_t)v) { L_i((int64_t)v); return; }
  if (v < 0) { L_s("-"); v = -v; }
  L_i((int64_t)v); L_s(".");
  double f = v - (double)(int64_t)v;
  char d[8]; int n = 0;
  for (int i = 0; i < 6; i++) { f *= 10; int k = (int)f; d[n++] = (char)('0' + k); f -= k; }
  while (n > 1 && d[n - 1] == '0') n--;
  for (int i = 0; i < n; i++) { char c[2] = { d[i], 0 }; L_s(c); }
}
static void L_mv(int32_t mv) { L_i(CR(mv)); L_s(","); L_i(CC(mv)); }
static void L_play(int p) { const char *s = p == -2 ? "raise" : PLAY_NAME[p]; for (; *s; s++) { char c[2] = { *s == ' ' ? '_' : *s, 0 }; L_s(c); } }
static const char DROP_CHAR[NDROPS] = { 'b', 'o', 't', 'f', 'r', 'u', 'c', 'w', 'j', '2' };

// THE MOVE: the one order's choice -- the raise the opening called for, a line's first swap, or the hold
typedef struct { int32_t kind, move; } Move;   // kind: 0 hold, 1 swap, 2 raise
// THE ANSWER, read by the host (gb_answer): the move, the raise held, the line handed on, and what the log and the audit read
typedef struct {
  Move d; int32_t raiseNow, raiseAfter, raiseWait, nhand, hand[MAXLINE], handAt[MAXLINE], handSettled, tap;
  int32_t verdict;    // 0 none, 1 lives, 2 dies, 3 raise
  int32_t holdLives, brk, urgent, offered, lineup, touch, took, clears, dumpBoard;
  int32_t lineKept;   // the line handed on breaks garbage, lives, or outlives the hold by a break's time (front.c follow: carried across a switch of the mode)
  int32_t sooner;   // the line played is lost sooner than one offered, and not alike (rank.c lostAlike): survival was not first
  int32_t ended;   // what ended the line in progress (front.c lineEnds): 1 carried on, 2 held over it, 3 none carried, 4-6 the carry
                    // dropped it (carryDrop 1-3), or the line number of the order's key that put it down (rank.c cmpKey)
  int32_t wastes;   // 1: the line played makes a three for nothing as the judge saw it, and the survival search found the board needed it (decide.c
                    // saveOk); 2: it makes one on its way to the garbage it breaks (rank.c wastesThree) -- the press guard lets either through
  int32_t empty;                 // a hold the clock left no time to judge anything for (the frame loop plays the move in hand)
  int32_t nalt, alt[MAXLINE];    // the move in hand: the best line that lives and is no hold, a ready one first
  int32_t aim;                   // a hold's: the first swap of the best line that is no hold -- the frame loop walks the cursor there (0: none)
  int32_t play, combo, chain, chainAll, broke, cleared, done, fire, nseq, seq[MAXLINE], rule, nlive, ncands;
  int32_t whole;   // the chain the board ends up making with the line played (-1: held)
  double idleMs, brMs;
} Answer;
static Answer theAnswer;
static int32_t lastA, lastB, pairRuns, blockA, blockB, blockUntil, emptyAt = NUL;

// SWITCHING (plans/gambit-goal.md 5): the profile's `switch` -- the mode changed mid-game as a rule's `when` changes it, after a random
// stretch of `min` to `max` frames each time. A game's switches walk a circuit through every ordered pair of the attack rules (each
// rule to each other rule, once a lap), its start, its labels and its stretches drawn from the game's seed (gb_switch_game); every reader
// asks modeAt (the frame loop drops a line handed it under another mode, front.c). Off: the mode stays the profile's.
#define MAXSWITCH 256
static int32_t switchMin, switchMax, nswitch, switchAt[MAXSWITCH], switchMode[MAXSWITCH], switchedNow;
static double readMs;   // (the board's reading, for the log)
// (A LINE THAT OUTLIVES THE HOLD, its walk charged as every alternative to a line with no named reason is: kept where nothing after
// it has a reason -- the frames it buys are its reason -- answer.c, no move without its reason)
static int outlivesHold(const Judge *L, const Judge *H) {
  if (!H || H->o.dead) return 1;
  return !H->o.lives && (L->o.lives || lostOf(L) > lostOf(H));
}
static void answerTurn(int32_t qid, int32_t at, int32_t allowanceKnown, int32_t allowance, int32_t lineFrom, int32_t linePressed) {
  Answer *A = &theAnswer;
  memset(A, 0, sizeof *A);
  logN = 0; logBuf[0] = 0;
  double tStart = nowMs();
  // (the input budget tight: the frame loop walks held from two cells, so every line is judged pressed as it walks)
  { const Board *b = decQ.b; double dies = (hostTopped ? b->stopTime + b->preStopTime : framesToTop(b)) + b->health;
    pressTap = decTap = hostTaps && allowanceKnown && dies <= TAP_DIES; }
  decQ.tight = allowanceKnown && tightAt(allowance);
  A->tap = pressTap;
  pressTight = decQ.tight;
  pressAllowance = allowanceKnown ? allowance : -1;
  if (!hostWin) nWinAges = -1;   // (the window: a native host's, said with the question -- native.c answerOne)
  hostWin = 0;
  towardRestLen = 0;
  // (the readiness the last decision left searching on the workers taken back first: the pool is this decision's searches' -- breakBegin)
  readyStop();
  carryFrom = lineFrom; carryPressed = linePressed;
  carryMoveOff = hostMoveOff; hostMoveOff = 0;   // (the answer's own swap never pressed: a native host's, said with the question)
  // (the line the board was last foreseen by: this answer's line in progress, its swaps pressed as the frame loop says; past it -- a
  // hold, a wait -- the swaps it had pressed when last asked)
  { static int32_t lastSkip; pvKind = 0; if (pvSet) { if (pvNew) { lastSkip = 0; pvNew = 0; } if (pvId == lineFrom) lastSkip = linePressed; pvCheck(lastSkip); } }
  planSeedsHave = plannedPaths(decQ.b, lineFrom, linePressed, &planSeeds); planOut.n = 0; planSeeded = 0;
  // (THE DIG: the boards stood on since the garbage the break search digs toward was first the lowest)
  int32_t gid = digTargetOf(decQ.b);
  if (gid == NUL) { digOn = 0; digN = 0; digGid = NUL; }
  else { if (!digOn || digGid != gid) { digOn = 1; digGid = gid; digN = 0; } char key[KEYLEN]; keyOf(decQ.b, key); digAdd(key); }
  // (the rules read first -- the list, the floor -- so the break search finds only breaks the judge will take)
  Read R;
  backBoard = decQ.b;
  theBack.at = at;
  aloneChain = 0;   // (this decision's, found by the hold's judging -- rank.c holdCand -- or none)
  readyAsked = readyHit = 0; readyStop(); readyPendClear();
  if (!readBoard_(&R)) { A->d.kind = -1; return; }
  readMs = nowMs() - tStart;
  batTaken = batOwn = batBusy = batSmall = batTight = 0;
  double brMs;
  // (THE SEARCHES' SHARE: the decision's time but the judging's quarter -- propose.c searchesEnd -- every search within it)
  double searchShare = clockShareBegin(searchesEnd());
  static Found S;
  searchPrep(&R, &S);
  extLogged = 0; extSkip = 0; extCutN = 0;   // (the extension's log is this decision's: cleared before any search begins, the ones beside this thread too)
  int beside = breakBegin(&R, &S, lineFrom, linePressed);
  if (!beside) searchUnsplit();
  searchBeside = beside;
  brWhere = 0; brGiven = 0;
  if (!beside) { brWhere = 3; brGiven = leftMs(); }
  int ran = beside ? 0 : breakSearch(&R, lineFrom, linePressed, &brMs);
  if (R.under) onStart(brHave ? &brResume : 0);   // (the search beside the decision, from the frontier this one resumes)
  double ts = nowMs();
  searchAll(&R, &S);
  if (beside) ran = breakEnd(&R, lineFrom, linePressed, &brMs);
  searchMerge(&R, &S);
  S.searchMs = nowMs() - ts;
  batSearch = batOwn;
  C2.br = ran ? &theBr : 0; C2.brMs = (int32_t)brMs;
  clockShareEnd(searchShare);
  int starved = clockOut();   // (out of time before anything was judged)
  int n = ranked(&R, &S);
  // (the floor's raise gives way to nothing: a low stack is raised, and the break it holds ready is made once it has risen (the owner)
  // -- the rows raised are the ones that leave a break once everything lands, decide.c read)
  // (and the opening's to a break, where nothing lives: a raise is no answer to garbage landing on a board that dies)
  // -- or to a line that outlasts the hold by a break's time (rankSave): where nothing lives, a raise only brings the loss sooner
  if (R.up && !raiseRefill && n && !order[0]->o.lives) {
    const Judge *H = 0; for (int i = 0; i < n && !H; i++) if (order[i]->hold) H = order[i];
    if (order[0]->apBroke > 0 || (H && !order[0]->hold && lostOf(order[0]) >= lostOf(H) + rankSave)) R.up = R.low = 0;
  }
  Played P = playOf(&R, n);
  if (opFlatPlayed) R.up = R.low = 0;   // (the opener's flattening before its raise: decide.c opTarget)
  if (opLineOn && P.line && P.line->carried) R.up = R.low = 0;   // (the opener's line in progress pressed through: no raise in its middle)
  // (NO MOVE WITHOUT ITS REASON -- the owner: a move made for nothing is a bug. The line chosen that makes nothing, shapes nothing and leaves
  // nothing one swap on gives way to the best after it in the order that has a reason and is lost no sooner -- of the next WHY_TRIES --
  // else to the hold, where the hold is lost no sooner: a swap for nothing spends the window the next break is pressed from; the log's
  // noreason=3 is a line kept that outlives the hold)
  noReason = 0; whyPlayed = (Why){ WHY_NONE, 0, 0 };
  if (!R.up && P.line && !P.line->hold && !P.line->carried) whyPlayed = moveWhy(P.line);
  if (!R.up && P.line && !P.line->hold && !P.line->carried && whyPlayed.kind == WHY_NONE) {
    const Judge *alt = 0, *H = 0;
    for (int i = 0; i < n && !H; i++) if (order[i]->hold) H = order[i];
    for (int i = 0, tries = 0; i < n && !alt && tries < WHY_TRIES; i++) {
      const Judge *J = order[i];
      if (J == P.line || J->hold || J->wait || J->o.dead) continue;
      if (!(J->o.lives || (!P.line->o.lives && diesAt(J) >= diesAt(P.line)))) continue;
      // (and later than the hold with its walk charged: a line no better than the hold left alone is a walk for nothing)
      if (H && !H->o.dead && !H->o.lives && !J->o.lives && !(lostOf(J) > lostOf(H))) continue;
      tries++;
      Why wj = moveWhy(J);
      if (wj.kind != WHY_NONE) { alt = J; whyPlayed = wj; }
    }
    noReason = alt ? 1 : 2;
    // (the key that ranked the line given up first, before the best lost later -- the log's nrKey=kKEY:lost/lost)
    nrKey = 0; nrLost[0] = nrLost[1] = 0;
    for (int i = 0; i < n; i++) { const Judge *J = order[i];
      if (J == P.line || J->hold || J->o.dead || P.line->o.lives || !(J->o.lives || diesAt(J) > diesAt(P.line))) continue;
      int32_t k = cmpKey; compareJudged(P.line, J); nrKey = cmpKey; cmpKey = k;
      nrLost[0] = (int32_t)diesAt(P.line); nrLost[1] = J->o.lives ? -1 : (int32_t)diesAt(J); break; }
    // (and the hold only where the line is lost no later than it, its walk charged, as each alternative is held to: a line whose board
    // outlives the hold's is the frames it buys, and a hold in its place is the board given up for want of a named reason)
    if (alt || !outlivesHold(P.line, H)) { P.line = alt; P.top = alt ? alt : H; } else noReason = 3;
  }
  if (R.F.known[FACT_US_CONTACT] || R.topped) gambitHit = 1;
  { int lv = 0; for (int i = 0; i < n; i++) if (!order[i]->hold && !order[i]->carried && order[i]->o.lives) lv = 1; livedPrev = lv; }
  // (the frame the board is lost under the line played, for the eights' time next decision: propose.c twinLines)
  twinRoomAt = P.line && !P.line->hold && !P.line->o.dead && P.line->o.lostAt != NOT_ASKED ? (P.line->o.lives || P.line->o.lostAt == FOREVER ? decQ.b->clock + FOREVER / 2 : decQ.b->clock + P.line->o.lostAt) : -1;
  // THE MOVE (a line whose first swap was judged pressed later than now -- its pair still moving -- is a hold, the line handed on whole)
  int timed = !R.up && P.line && P.line->apNats > 0 && P.line->apAts[0] > 0;
  Move d = R.up ? (Move){ 2, 0 } : P.line && !timed ? (Move){ 1, P.line->k.seq[0] } : (Move){ 0, 0 };
  // (the swap pressed now, for the next decision's no flip and back: the two panels as they stand once it is pressed)
  if (d.kind == 1) { int r = CR(d.move), c = CC(d.move); __atomic_store_n(&undoFresh, 0, __ATOMIC_RELEASE); if (r >= 0 && r < decQ.b->nrows && c >= 1 && c + 1 <= W) { __atomic_store_n(&undoIdL, decQ.b->p[r][c + 1].f[ID], __ATOMIC_RELAXED); __atomic_store_n(&undoIdR, decQ.b->p[r][c].f[ID], __ATOMIC_RELAXED); __atomic_store_n(&undoFresh, 1, __ATOMIC_RELEASE); } }
  else __atomic_store_n(&undoFresh, 0, __ATOMIC_RELEASE);   // (only the decision straight after a swap can take it back for nothing: a hold or a raise between, and the board has moved on)
  A->d = d;
  // (and a hold where the line in progress was let go only for the clock -- its judging stopped before it pressed a swap: the frame
  // loop presses on the line in hand, never a break worth a life dropped for want of time: fight 813, match 20)
  A->empty = (starved || carryLate) && d.kind == 0;
  // (THE MOVE IN HAND: of the lines that live and are no hold -- a ready one first -- the best ranked, kept by the frame loop for a
  // decision the clock leaves no time)
  A->nalt = 0;
  for (int pass = 0; pass < 2 && !A->nalt; pass++)
    for (int i = 0; i < n && !A->nalt; i++) {
      const Judge *J = order[i];
      if (J->hold || J->wait || !J->o.lives || J->k.nseq < 1 || (pass == 0 && J->o.ready != 1)) continue;
      A->nalt = imin(J->k.nseq, MAXLINE); for (int q = 0; q < A->nalt; q++) A->alt[q] = J->k.seq[q];
    }
  // (THE CURSOR NOT LEFT IDLE -- the owner: a person moves toward the next move while waiting: a hold names where the best line that is no
  // hold begins, and the frame loop walks the cursor there; a cursor walked changes nothing on the board)
  A->aim = 0;
  if (d.kind == 0) for (int i = 0; i < n && !A->aim; i++) if (!order[i]->hold && order[i]->k.nseq > 0) A->aim = order[i]->k.seq[0];
  const Judge *top = R.up ? 0 : P.top;
  A->verdict = R.up ? 3 : top ? (top->o.lives ? 1 : 2) : 0;
  // (CALM, FOR THE FRAME LOOP'S PACE (front.c calmGap: the next line waits the profile's gap and a jitter, a player's pause): the hold
  // lives -- or, the owner's slower play, the line played lives, with no garbage on the board or on its way, nothing falling and the input
  // window at PACE_WINDOW or more: nothing then can need an answer inside the pause)
  #define PACE_WINDOW 60
  A->holdLives = (d.kind == 0 && top && top->o.lives)
                 || (d.kind == 1 && P.line && P.line->o.lives && !decF.under && decQ.narr == 0 && decQ.b && !hasActivePanels(decQ.b)
                     && pressAllowance >= PACE_WINDOW);
  A->ended = carryDrop >= 1 && carryDrop <= 3 ? 3 + carryDrop : !carriedJ ? (carryNone ? carryNone : 3) : P.line && (P.line == carriedJ || P.line->carried) ? 1
           : top && top != carriedJ && compareJudged(top, carriedJ) < 0 && cmpKey >= 10 ? cmpKey : 2;
  A->wastes = !P.line || R.up ? 0 : wastesThree(P.line) && saveOk ? 1 : P.line->o.j.threes > 0 && P.line->apBroke > 0 ? 2 : 0;   // (a three the survival search found the board needed not to die, or one on the way to a break)
  // (THE LINE PRESSED ON: the line played is handed to the frame loop whole, each swap from the frame the judge pressed it from -- a
  // settled line's after the board settles -- so the frame loop presses the line that was judged)
  A->nhand = 0; A->handSettled = P.line && P.line->settled; A->lineKept = P.line && !P.line->hold && (P.line->apBroke > 0 || P.line->o.lives || (rankHoldClock == decQ.b->clock && rankHoldOwn >= 0 && diesAt(P.line) - rankHoldOwn >= rankSave));
  if (P.line && !R.up) {
    int first = timed ? 0 : 1;
    for (int i = first; i < P.line->k.nseq; i++, A->nhand++) {
      A->hand[A->nhand] = P.line->k.seq[i]; A->handAt[A->nhand] = i < P.line->apNats ? at + P.line->apAts[i] : 0;
    }
  }
  towardPlayedN = 0;
  if (d.kind == 1 && P.line && P.line->k.play == PLAY_TOWARD) { towardPlayedN = P.line->k.nseq; for (int i = 0; i < P.line->k.nseq; i++) towardPlayed[i] = P.line->k.seq[i]; }
  // (the break search's work carried on to the next decision, past the move and as much of the line handed on as gets pressed)
  keepFrontier(ran ? &theBr : 0, d.kind, d.move, A->hand, A->nhand, qid);
  keepPlan(d.kind, d.move, A->hand, A->nhand, qid);   // (and the planner's: search/plan.c planOut)
  carrySkip = -1;
  // (an empty answer -- the clock left no time to judge -- is no answer: the frame loop presses on the line in hand, so the line in
  // progress stays as it was, for the next decision to find again by the line the frame loop says it is on)
  if (!A->empty) {
    if (!(d.kind == 0 && P.top && P.top->wait && !P.line)) carryOf(&R, P.line, qid, timed ? 0 : 1);
    carryNextOf(P.line);
  }
  keptPlayed = P.line && P.line->k.kept; routePlayed = P.line && P.line->k.route; wayPlayed = P.line && P.line->k.way;
  keepIntents(P.ncands, P.line);   // (the best lines that make something, kept for the next decision: decide.c keepIntents)
  if (A->empty) ;
  else if (d.kind == 0 && P.top && P.top->hold) carryReady(P.top, qid);
  else if (d.kind == 1 && P.line && P.line->k.nseq == 1 && !theCarry.set) carryReady(P.line, qid);
  // (no swap back: the pair the last swap swapped is kept out for a second when it is swapped three times running)
  int32_t pa = NUL, pb = NUL;
  if (d.kind == 1) { pa = decQ.b->p[CR(d.move)][CC(d.move)].f[ID]; pb = decQ.b->p[CR(d.move)][CC(d.move) + 1].f[ID]; }
  int pairKnown = d.kind == 1 ? (pa != NUL && pb != NUL) : !!lastA;
  int32_t na = d.kind == 1 ? pa : lastA, nb = d.kind == 1 ? pb : lastB;
  int same = pairKnown && lastA && samePair(na, nb, lastA, lastB);
  pairRuns = same ? pairRuns + 1 : 0;
  if (pairRuns >= 2) { blockA = na; blockB = nb; blockUntil = at + 60; }
  if (pairKnown) { lastA = na; lastB = nb; } else { lastA = lastB = 0; }
  gb_back(lastA, lastB, pairRuns, blockA, blockB, blockUntil, at);
  C2.idle = d.kind == 0 || (!R.up && !P.wait && !n);   // (held, or nothing was wanted)
  // what the answer and the audit read
  if (P.line) {
    const Judge *l = P.line;
    A->play = l->k.play; A->combo = l->apCombo; A->chain = l->apChain; A->chainAll = l->apChainAll; A->broke = l->apBroke; A->cleared = l->hold || !l->apPlayed ? 0 : l->o.j.clearedPanels; A->whole = l->hold || !l->apPlayed ? -1 : l->apWhole;
    A->done = l->apDone; A->fire = l->apFire; A->nseq = l->k.nseq; for (int i = 0; i < l->k.nseq; i++) A->seq[i] = l->k.seq[i];
  } else { A->play = P.name; A->whole = -1; }
  A->clears = d.kind == 1 && (A->combo > 0 || A->broke > 0);
  brNoneLast = R.under && !(ran && theBr.depth);
  A->brk = ran && theBr.depth; A->offered = ran ? theBr.depth : 0; A->lineup = ran && theBr.lineup; A->touch = ran && theBr.touch;
  if (ran && theBr.depth && d.kind == 1) for (int i = 0; i < theBr.nmoves; i++) if (theBr.moves[i] == d.move) A->took = 1;
  A->idleMs = S.idleMs; A->brMs = brMs;
  A->rule = theTables.r[R.rule].name; A->nlive = P.nlive; A->ncands = P.ncands;

  // (urgent: a cascade or a pop, an extension, or the line done within a pace gap of its deadline -- the frame loop's pace)
  // (and a hold that lives only by the break it waits for: that break has its frame, so the frame loop asks again at its own pace, never
  // the calm board's)
  A->urgent = (P.line && P.line->k.extend) || popLeft(decQ.b) > 0 || cascadeLive(decQ.b) ||
              (d.kind == 0 && top && top->hold && top->o.lives && top->o.lostAt != FOREVER);
  // THE LOG LINE
  const Rule *rule = &theTables.r[R.rule];
  L_s("GAMBITD "); L_i(at); L_s(" @"); L_i(rule->name); L_s(" play="); L_play(P.name);
  if (noReason) { L_s(" noreason="); L_i(noReason); if (nrKey) { L_s(" nrKey=k"); L_i(nrKey); L_s(":"); L_i(nrLost[0]); L_s("/"); L_i(nrLost[1]); } }
  // (THE GOAL, EVERY DECISION -- the owner: not only why, the intention -- the log's aim=: the line played, for the goal it was begun or chosen
  // for; with none played: raise (the raise pressed or waited for), the line in progress that waits for the board -- its own goal --, the
  // line chosen and held for its timing -- its goal --, fall (our chain falling: let it land), settle (panels falling or a slab popping),
  // keep (the hold ranked first: the board as it is -- won= says by which key))
  { Why wy = { WHY_NONE, 0, 0 }; const char *as = 0;
    if (R.up || P.wait) as = "raise";
    else if (P.line && !P.line->hold) {
      wy = P.line->carried ? (theCarry.why.kind != WHY_NONE ? theCarry.why : moveWhy(P.line)) : whyPlayed;
      if (!P.line->carried && theCarry.set) theCarry.why = wy;
      if (!P.line->carried && theCarryOff.set) theCarryOff.why = wy;
    }
    else if (theCarry.set && theCarry.why.kind != WHY_NONE) wy = theCarry.why;
    else if (P.deferred && P.top && !P.top->hold) wy = moveWhy(P.top);
    else if (decQ.b && decQ.b->chainCounter > 0) as = "fall";
    else if (decQ.b && (cascadeLive(decQ.b) || popLeft(decQ.b) > 0)) as = "settle";
    else as = "keep";
    L_s(" aim=");
    if (as) L_s(as);
    else switch (wy.kind) {
      case WHY_CHAIN: L_s("x"); L_i(wy.a); break;
      case WHY_COMBO: L_s("c"); L_i(wy.a); break;
      case WHY_BREAK: L_s("b"); L_i(wy.a); break;
      case WHY_TWIN: L_s("eight"); break;
      case WHY_FLAT: L_s("flat"); L_i(wy.a); L_s(">"); L_i(wy.b); break;
      case WHY_ZIP: L_s("zip"); L_i(wy.a); L_s(">"); L_i(wy.b); break;
      case WHY_DROP: L_s("drop"); break;
      case WHY_LIVE: if (wy.b == 1) L_s("live"); else if (wy.b == 2) L_s("survive"); else { L_s("live+"); L_i(wy.a); } break;
      case WHY_READY: L_s("ready-"); L_i(wy.a); break;
      default: L_s("none"); break;   // (a move with no goal: a bug to find)
    }
  }
  if (!openerOver) { L_s(" osum="); L_i(openerSum); L_s("/"); L_i(openerThrown); }
  L_s(" want="); if (R.up) L_s("raise"); else if (P.wait) L_s("hold"); else if (!n) L_s("-"); else if (order[0]->hold || order[0]->wait) L_s("hold"); else L_mv(order[0]->k.seq[0]);
  L_s(" got="); if (d.kind == 1) L_mv(d.move); else L_s(d.kind == 2 ? "raise" : "hold");
  L_s(" src=gambit v="); L_s(A->verdict == 1 ? "lives" : A->verdict == 2 ? "dies" : A->verdict == 3 ? "raise" : "none");
  L_s(" under="); L_i(R.under); L_s(" mat="); L_d(R.F.v[FACT_US_MATERIAL]); L_s(" pan="); L_i(panelsOn(decQ.b)); L_s(" chain="); L_i(A->chain); L_s(" combo="); L_i(A->combo); L_s(" broke="); L_i(A->broke); L_s(" clr="); L_i(A->cleared);
  // (the chain the board makes left alone, and the one it makes with the line played: own=4/2 is a chain cut short -- a line the judge
  // could not play out, or the hold, shows the board's own)
  if (lastPressedN && opTryN) { L_s(" opPressed="); for (int i = 0; i < lastPressedN; i++) { if (i) L_s(";"); L_i(lastPA[i] / 8); L_s(","); L_i(lastPA[i] % 8); L_s("@"); L_i(lastPT[i]); L_s("+"); L_i(lastPR[i]); } lastPressedN = 0; }
  if (lastCutRows[0] && opTryN) { L_s(" opCut="); L_i(lastCutClock); L_s(":"); L_i(lastCutCell / 8); L_s(","); L_i(lastCutCell % 8); L_s(":"); L_i(lastCutStates); L_s(":"); L_s(lastCutRows); lastCutRows[0] = 0; }
  if (opLinkCands) { L_s(" linkCands="); L_i(opLinkCands); L_s("/"); L_i(opLinkBest); }
  if (opNeed) { L_s(" need="); L_i(opNeed); L_s("/"); L_i(needKept); L_s("/"); L_i(needLost); }
  if (aloneChain > 1 && P.line) { L_s(" own="); L_i(aloneChain); L_s("/"); L_i(A->whole >= 0 ? A->whole : aloneChain);
    // (and the lines that live and keep it, the hold among them: a cut with one of them there is the plan's to count)
    int keeps = 0; for (int i = 0; i < n; i++) keeps += order[i]->o.lives && !cutsShort(order[i]);
    L_s(" ownKept="); L_i(keeps); }
  L_s(" tier="); L_i(P.line ? P.line->t.tier : d.kind == 0 ? HOLD_TIER : 0);
  // (the part of the one rule the line played is (judge.c): e an entry of the list, t the three that breaks, l a last resort, - none)
  // (rule=: e the line meets an entry of the mode's list, t a later one, l it is outside the list (the default's move), c a line in
  // progress carried on that meets none -- aim= its reason --, n a line that meets none played for its own reason -- aim= --, - none played)
  L_s(" rule="); L_s(!P.line ? "-" : P.line->met >= 0 ? (P.line->met < R.list.n ? "e" : "t") : P.line->outside ? "l" : P.line->carried ? "c" : "n");
  L_s(" by="); if (R.by != NOT_ASKED && R.by) L_i(R.by); else L_s("-");
  L_s(" done="); if (P.line && A->done >= 0) L_i(A->done); else L_s("-");
  L_s(" fire="); if (P.line && A->fire >= 0) L_i(A->fire); else L_s("-");
  if (P.line && P.line->carried && carryBeganAt >= 0 && carryBeganPlay >= 0 && carryBeganPlay < NPLAYS) { L_s(" from="); L_i(carryBeganAt); L_s(":"); L_play(carryBeganPlay); }   // (the line in progress: the frame it was begun and as what)
  // (and what it is for: what it was judged to make when it was begun -- the combo, the chain, the garbage cells broken -- and what it
  // is judged to make now, the swaps left of it: for=combo/chain/broke makes=combo/chain/broke)
  if (P.line && P.line->carried && theCarry.set) {
    L_s(" for="); L_i(theCarry.made.combo); L_s("/"); L_i(theCarry.made.chain); L_s("/"); L_i(theCarry.made.broke);
    L_s(" makes="); L_i(imax(0, P.line->apCombo)); L_s("/"); L_i(imax(0, P.line->apChain)); L_s("/"); L_i(imax(0, P.line->apBroke));
  }
  L_s(" ats="); if (P.line && P.line->apNats) { for (int i = 0; i < P.line->apNats; i++) { if (i) L_s("/"); L_i(P.line->apAts[i]); } } else L_s("-");
  if (P.line && P.line->apPlayed && P.line->apNats) { L_s(" rz="); for (int i = 0; i < P.line->apNats && i < MAXLINE; i++) { if (i) L_s("/"); L_i(P.line->o.j.risen[i]); } L_s(" cstep="); L_i(P.line->o.j.clearStep); L_s(" tb="); L_i(P.line->o.j.tightBits); L_s(" allow0="); L_i(pressAllowance); }
  L_s(" swaps="); L_i(P.line ? P.line->k.nseq : 0);
  if (P.line && P.line->k.nseq > 0) { L_s(" seq="); for (int q = 0; q < P.line->k.nseq; q++) { if (q) L_s(";"); L_mv(P.line->k.seq[q]); } }   // (the line played, every swap: whether the next decision carries it on)
  // (SEVERAL IDEAS AT ONCE: the blocks the line played throws, every attack its own; the ideas the board it leaves holds, where a key
  // asked them; the lines firing two ideas the planner offered, and whether one -- or a route pressed at once -- was played)
  L_s(" thrown="); L_i(P.line ? thrownOf(P.line) : 0);
  L_s(" w3="); L_i(P.line ? P.line->o.j.threes : -1); if (P.line && wastesThree(P.line)) L_s("/w");   // (the line played: its wasted threes as the judge saw them)
  if (P.line && P.line->ideasAsked && P.line->ideas >= 0) { L_s(" ideas="); L_i(P.line->ideas); }
  if (pairOffered || (P.line && P.line->k.pair)) { L_s(" pair="); L_i(pairOffered); if (P.line && P.line->k.pair) L_s("/played"); }
  if (twinLo > -2) { L_s(" twinLo="); L_i(twinLo); L_s("/"); L_i(twinRows); }
  if (twinTouchOffered) { L_s(" twinT="); L_i(twinTouchOffered); }
  if (twinNo[1] + twinNo[2] + twinNo[3] + twinNo[4] + twinNo[5]) { L_s(" twinNo="); for (int i = 1; i <= 5; i++) { if (i > 1) L_s("/"); L_i(twinNo[i]); } }
  if (twinNo[3]) { L_s(" twinBad="); for (int i = 1; i <= 5; i++) { if (i > 1) L_s("/"); L_i(twinBad[i]); } }   // (the threes the refused sorts met: row, column, trigger row, its column, unsortable)
  if (twinWaste[1] + twinWaste[2] + twinWaste[3] + twinWaste[4]) { L_s(" twinW="); for (int i = 1; i <= 4; i++) { if (i > 1) L_s("/"); L_i(twinWaste[i]); } if (twinWaste[2]) { L_s(":made"); L_i(twinWasteC); L_s("x"); L_i(twinWasteN); L_s("/sized"); L_i(twinWasteX); } }
  if (twinOffered || (P.line && (P.line->k.twin == 1 || P.line->k.twin == 2))) { L_s(" twin="); L_i(twinOffered); if (P.line && (P.line->k.twin == 1 || P.line->k.twin == 2)) L_s(P.line->k.twin == 2 ? "/setup" : "/played"); }
  if (sixOffered || (P.line && P.line->k.twin == 3)) { L_s(" six="); L_i(sixOffered); if (P.line && P.line->k.twin == 3) L_s("/played"); }
  // (the first six in the order: its place, its loss (L lives, D dead), its combo, and the key that put the line played first over it)
  if (sixOffered && n && order[0] && order[0]->k.twin != 3) for (int i = 1; i < n; i++) if (order[i]->k.twin == 3) {
    int32_t keep = cmpKey; compareJudged(order[0], order[i]);
    L_s(" sixAt="); L_i(i); L_s(":"); if (order[i]->o.dead) L_s("D"); else if (order[i]->o.lives) L_s("L"); else L_i((int32_t)diesAt(order[i]));
    L_s(":c"); L_i(order[i]->apCombo); L_s(":x"); L_i(order[i]->apChainAll); L_s(":k"); L_i(cmpKey); cmpKey = keep; break; }
  L_s(" land="); if (R.F.known[FACT_US_NEXTLANDS]) L_d(R.F.v[FACT_US_NEXTLANDS]); else L_s("-");
  L_s(" dies="); L_d(R.F.v[FACT_US_DIES]); if (R.F.v[FACT_US_QUEUEKILLS]) L_s(" qk=1"); if (R.aloneOut) { L_s(" alone="); L_i(R.aloneChain); }
  if (needlessTrimmed) { L_s(" needless="); L_i(needlessTrimmed); }
  if (chainUp) { L_s(" chainUp="); L_i(chainUp); L_s("/"); L_i(chainNow); L_s("/"); L_i(chainAfter); if (opTried > 1) { L_s(" opTried="); L_i(opTried); }
    // (the opening's line as the judge played it: its chain and the cells it throws -- beside chainAfter, the cells the plan said)
    if (chainUp >= 2 && P.line) { L_s(" opJudged="); L_i(P.line->apChain); L_s("/"); L_i(thrownOf(P.line)); } }
  if (opGrew) { L_s(" opgrew="); L_i(opLevels); L_s("/"); L_i(opGrewLen); L_s("/"); L_i(opGrowMs); L_s("/"); L_i(opOnPool); L_s("/"); L_i(opGrewCh); L_s("/"); L_i(opGrewN); L_s("/b"); L_i(opGrewBlind); L_s("/t"); L_i(opGrewCh2); if (opDesigned) { L_s("/d"); L_i(opDesigned); } if (opDesignedQuick) { L_s("/q"); L_i(opDesignedQuick); } if (opProveTried) { L_s("/p"); L_i(opProved); L_s(":"); L_i(opProveTried); L_s(":"); L_i(opProvedBest); } if (cdAsk) { L_s("/x"); L_i(opExtBest); } if (opPairN) { L_s("/r"); L_i(opPairN); L_s(":"); L_i(opPairBest); } L_s("/s"); L_i(opSightCh); L_s("x"); L_i(opSightLen); if (opGrew == 2) L_s("/raise"); }
  if (opGrew == 2) { L_s(" opflat="); L_i(opFlatN); if (opFlatPlayed) L_s("/played"); }
  if (taxMs >= 0) { L_s(" tx="); L_i(taxBase); L_s("/"); L_i(taxLong); L_s("/"); L_i(taxN); L_s("/"); L_i(taxMs); }
  if (taLog || taHave) { L_s(" ta="); L_i(taLog); L_s("/"); L_i(taLinks); L_s("/"); L_i(taSwaps); L_s("/"); L_i((int32_t)taMs); L_s("/"); L_i(taOn); }
  if (contAsked) { L_s(" cont="); L_i(contAsked); }
  if (comboTimed) { L_s(" timed="); L_i(comboTimed); }
  if (freeSetup) { L_s(" free8="); L_i(freeSetup); if (twinKeptSet) { L_s("/"); L_i(twinKept.cost); } }
  if (windowCut) { L_s(" windowCut="); L_i(windowCut); }   // (lines taken out: the window not back before their board is lost)
  // (the queue held off by the board's own motion: the frame it drops left alone, the frames the line played puts that off -- taken out of
  // its loss -- and the clears taken out of the order for it)
  if (rootQueueAt != QUEUE_UNSET && rootQueueAt != NOT_ASKED) { L_s(" queue="); L_i(rootQueueAt); L_s("/"); L_i(top && !top->hold ? top->o.putOff : 0); L_s("/"); L_i(putOffCut); }
  if (samesTrimmed) L_s(" samesTrimmed=1");   // (the line played had its swaps of one colour taken out)
  if (reachCut) { L_s(" reach="); L_i(reachCut); }
  if (stallCut) { L_s(" stall="); L_i(stallCut); }
  if (overCut) { L_s(" over="); L_i(overCut); }
  if (enPlayed) { L_s(" enRoute="); L_i(enPlayed); }
  if (undoCut) { L_s(" undo="); L_i(undoCut); }
  if (twoDropped) { L_s(" twoDropped="); L_i(twoDropped); L_s(" twoWhy="); L_i(twoWhy); L_s("/"); L_i(twoLostLog >= 1e299 ? -2 : (int64_t)twoLostLog); L_s("/"); L_i((int64_t)twoKeptLog); }
  if (twoRemade) { L_s(" twoRemade="); L_i(twoRemade); }
  if (noopWaits) { L_s(" noopWaits="); L_i(noopWaits); }
  // (a 2x the line played leaves at 2x, going or made: the key it was ranked first by, before the best that takes a chain to three -- or,
  // a 2x it makes, before the best that makes none -- and the two's losses)
  if (n && P.line && P.line == order[0] && chainReach(P.line) == 2 && (aloneChain >= 2 || shortChain(P.line))) {
    int32_t keep = cmpKey;
    for (int i = 1; i < n; i++) if (!order[i]->hold && chainReach(order[i]) >= 3) {
      compareJudged(order[0], order[i]); L_s(" c3Key=k"); L_i(cmpKey); L_s(":"); L_i((int32_t)lostOf(order[0])); L_s("/"); L_i((int32_t)lostOf(order[i])); break; }
    if (shortChain(P.line)) for (int i = 1; i < n; i++) if (!shortChain(order[i]) && !(aloneChain >= 2)) {
      compareJudged(order[0], order[i]); L_s(" no2Key=k"); L_i(cmpKey); L_s(":"); L_i((int32_t)lostOf(order[0])); L_s("/"); L_i((int32_t)lostOf(order[i])); L_s(order[i]->hold ? ":h" : ":l"); break; }
    cmpKey = keep;
  }
  // (A HOLD OVER A LATER LOSS: the hold played where a line that is no hold is lost a break's time later or lives -- the key the hold was
  // ranked first by, the two's losses and the line's play)
  if (n && order[0] && order[0]->hold) {
    int bi = -1;
    for (int i = 1; i < n; i++) if (!order[i]->hold && order[i]->k.nseq && (order[i]->o.lives || lostOf(order[i]) >= lostOf(order[0]) + rankSave) && (bi < 0 || lostOf(order[i]) > lostOf(order[bi]))) bi = i;
    if (bi > 0) {
      int32_t keep = cmpKey; compareJudged(order[0], order[bi]);
      L_s(" holdKey=k"); L_i(cmpKey); L_s(":"); L_i((int32_t)lostOf(order[0])); L_s("/"); L_i(order[bi]->o.lives ? -1 : (int32_t)lostOf(order[bi])); L_s(":"); L_s(PLAY_NAME[order[bi]->k.play]);
      cmpKey = keep;
    }
  }
  // (THE HOLD OVER A LINE: the hold played where a line was offered -- the key that put it first, and that line's play: holdOver=kKEY:play)
  if (n > 1 && order[0] && order[0]->hold) {
    for (int i = 1; i < n; i++) if (!order[i]->hold && order[i]->k.nseq) {
      int32_t keep = cmpKey; compareJudged(order[0], order[i]);
      L_s(" holdOver=k"); L_i(cmpKey); L_s(":"); L_s(PLAY_NAME[order[i]->k.play]); cmpKey = keep; break; }
    // (and over the line offered whose board is lost latest, the frame it is lost on, no walk charged, later than the hold's: holdLate=kKEY:play:lost/lost)
    int li = -1;
    for (int i = 1; i < n; i++) if (!order[i]->hold && order[i]->k.nseq && (order[i]->o.lives || diesAt(order[i]) > diesAt(order[0])) &&
                                    (li < 0 || order[i]->o.lives || (!order[li]->o.lives && diesAt(order[i]) > diesAt(order[li])))) li = i;
    if (li > 0) { int32_t keep = cmpKey; compareJudged(order[0], order[li]);
      L_s(" holdLate=k"); L_i(cmpKey); L_s(":"); L_s(PLAY_NAME[order[li]->k.play]); L_s(":"); L_i((int32_t)diesAt(order[0])); L_s("/"); L_i(order[li]->o.lives ? -1 : (int32_t)diesAt(order[li]));
      cmpKey = keep; }
    // (and over the set-up -- a set-up, lineup, line toward a break or nearest the list, level or zip -- whose board is lost latest, lost
    // no sooner than the hold's, no walk charged: holdSet=kKEY:play:lost/lost:walk)
    int si = -1;
    for (int i = 1; i < n; i++) if (setupKind(order[i]) && order[i]->k.nseq && (order[i]->o.lives || diesAt(order[i]) >= diesAt(order[0])) &&
                                    (si < 0 || order[i]->o.lives || (!order[si]->o.lives && diesAt(order[i]) > diesAt(order[si])))) si = i;
    if (si > 0) { int32_t keep = cmpKey; compareJudged(order[0], order[si]);
      L_s(" holdSet=k"); L_i(cmpKey); L_s(":"); L_s(PLAY_NAME[order[si]->k.play]); L_s(":"); L_i((int32_t)diesAt(order[0])); L_s("/"); L_i(order[si]->o.lives ? -1 : (int32_t)diesAt(order[si]));
      L_s(":"); L_i(lineWalk(order[si])); cmpKey = keep; }
  }
  // (THE MODE PASSED OVER: the line played does not meet the mode's first entry, and a line offered that does lives as it does, or is
  // lost no sooner -- the key that put the line played first, the line's play and the two's losses: goalMiss=kKEY:play:lost/lost.
  // Only survival may pass the mode over (the owner))
  if (n && order[0] && !(order[0]->met == 0 || order[0]->modeFirst)) {
    const Judge *g = 0;
    for (int i = 1; i < n && !g; i++) { const Judge *j = order[i]; if (!j->hold && (j->met == 0 || j->modeFirst) && (j->o.lives || (!order[0]->o.lives && diesAt(j) >= diesAt(order[0])))) g = j; }
    if (g) { int32_t keep = cmpKey; compareJudged(order[0], g);
      L_s(" goalMiss=k"); L_i(cmpKey); L_s(":"); L_s(PLAY_NAME[order[0]->k.play]); L_s(":"); L_i(order[0]->o.lives ? -1 : (int32_t)diesAt(order[0])); L_s("/"); L_i(g->o.lives ? -1 : (int32_t)diesAt(g));
      cmpKey = keep; }
  }
  // (THE DIG THE MODE ASKS, OFFERED: under garbage, the lines offered that break and meet the mode's list with a combo of four or more --
  // the dig that is the mode's attack -- and whether the line played is one: comboDig=N[/played])
  if (decF.under && n) { int k = 0; for (int i = 0; i < n; i++) { const Judge *j = order[i]; if (!j->hold && !j->outside && j->apBroke > 0 && j->apCombo >= 4) k++; }
    if (k) { L_s(" comboDig="); L_i(k); if (order[0] && !order[0]->hold && !order[0]->outside && order[0]->apBroke > 0 && order[0]->apCombo >= 4) L_s("/played"); } }
  // (AN ATTACK THE MODE DOES NOT ASK, PLAYED OVER ONE IT DOES: the line played breaks outside the list, and a line offered breaks within
  // it and is lost no more than a break's time sooner -- the key that put the line played first, the two plays and losses:
  // outKey=kKEY:play:in-play:lost/lost)
  if (n && order[0] && !order[0]->hold && order[0]->outside && order[0]->apBroke > 0) {
    const Judge *g = 0;
    for (int i = 1; i < n && !g; i++) { const Judge *j = order[i]; if (!j->hold && !j->outside && j->apBroke > 0 && (j->o.lives || (!order[0]->o.lives && diesAt(j) >= diesAt(order[0]) - rankSave))) g = j; }
    if (g) { int32_t keep = cmpKey; compareJudged(order[0], g);
      L_s(" outKey=k"); L_i(cmpKey); L_s(":"); L_s(PLAY_NAME[order[0]->k.play]); L_s(":"); L_s(PLAY_NAME[g->k.play]); L_s(":"); L_i(order[0]->o.lives ? -1 : (int32_t)diesAt(order[0])); L_s("/"); L_i(g->o.lives ? -1 : (int32_t)diesAt(g));
      cmpKey = keep; }
  }
  // (a two-column eight offered and not played: the key the line played was ranked first by, before the best of them, and the two's losses)
  if (n && order[0] && !order[0]->k.twin) for (int i = 1; i < n; i++) if (order[i]->k.twin == 1) {
    int32_t keep = cmpKey; int lost8 = compareJudged(order[0], order[i]) < 0;
    // (+: the eight won that comparison and still ranked below -- the order is not transitive)
    L_s(" twinKey=k"); L_i(cmpKey); L_s(lost8 ? "" : "+"); L_s(":"); L_i(order[0]->o.lives ? -1 : (int32_t)lostOf(order[0])); L_s("/"); L_i(order[i]->o.lives ? -1 : (int32_t)lostOf(order[i])); L_s(":"); L_i(order[i]->o.dead ? 1 : 0);
    cmpKey = keep; break;
  }
  // (a line played whose first swap swaps back the last swap's pair: the key it was ranked first by, before the best that does not, and
  // the two's losses)
  if (n && order[0] && order[0]->back && !order[0]->hold) for (int i = 1; i < n; i++) if (!order[i]->back && !order[i]->hold) {
    int32_t keep = cmpKey; compareJudged(order[0], order[i]);
    L_s(" backKey=k"); L_i(cmpKey); L_s(":"); L_i((int32_t)lostOf(order[0])); L_s("/"); L_i((int32_t)lostOf(order[i])); L_s(":"); L_i(order[i]->k.play);
    cmpKey = keep; break;
  }
  L_s(" casc="); L_i(cascadeLive(decQ.b)); L_s(" pop="); L_i(popLeft(decQ.b)); L_s(" hp="); L_i(decQ.b->health); L_s(" stop="); L_d(R.F.v[FACT_US_STOP]);
  if (readyAsked) { L_s(" rdy="); L_i(readyHit); L_s("/"); L_i(readyAsked); }
  if (!readyBuilt && readyBuildWhy) { L_s(" rb=0:"); L_i(readyBuildWhy); }
  if (readyBuilt) { L_s(" rb="); L_i(readyBuilt); if (P.line && P.line->k.readyGain > 0) { L_s("/played:"); L_i(P.line->k.readyGain); } }
  if (keptOffered) { L_s(" kept="); L_i(keptOffered); if (keptPlayed) L_s("/played"); }
  if (routeOffered) { L_s(" route="); L_i(routeOffered); if (routePlayed) L_s("/played"); }
  if (planSeeded) { L_s(" seed="); L_i(planSeeded); }
  if (readyPre) { L_s(" pre="); L_i(readyPre); L_s("/"); L_i(readyPendN); }
  if (wayOffered) { L_s(" way="); L_i(wayOffered); if (wayPlayed) L_s("/played"); }
  if (cutOffered) { L_s(" cut="); L_i(cutOffered); if (P.line && P.line->k.play == PLAY_CUT) L_s("/played"); }
  if (zipOffered) { L_s(" zip="); L_i(zipOffered); if (P.line && P.line->k.play == PLAY_ZIP) L_s("/played"); }
  // (the floor's raise: the rows asked, how many leave a break once everything lands, how many the board lives through -- or, asked
  // while the board is busy, -1 a cascade, -2 the game's raise not allowed)
  L_s(" sv="); L_i(__atomic_load_n(&svJobDone, __ATOMIC_ACQUIRE) ? 1 : 0); if (surviveAsked) L_s("/asked");   // (the survival job finished this decision; the backup asked of it)
  if (saveAsked) { L_s(" saveAsk="); L_i(saveNot); L_s("/"); L_i(saveAsked); L_s(":"); L_i((int64_t)saveCw); L_s("/"); L_i((int64_t)saveCk); if (saveOk) L_s("/needed"); } if (saveBlind) L_s(" saveBlind=1");   // (the threes the survival search found not needed, of those asked)
  if (refillAsked) { L_s(" refill="); L_i(refillAsked); L_s("/"); L_i(refillReady); L_s("/"); L_i(refillAlive); if (raiseWait) { L_s("/w"); L_i(raiseWait); } else if (refillAsked == -1) { L_s("/s"); L_i(raiseShut); } }
  L_s(" waits="); L_i(R.breakWaits); L_s(" tight="); L_i(decQ.tight); L_s(" allow="); L_i(pressAllowance); if (decQ.b) { L_s(" cur="); L_i(decQ.b->curRow); L_s(","); L_i(decQ.b->curCol); } if (decTap) L_s(" tap=1"); if (onLogSlices) { L_s(" on="); L_i(onLogSlices); L_s("/"); L_i(onLogFound); L_s(" onDeep="); L_i(onLogDeep); if (onLogKept) L_s("/kept"); }
  L_s(" br=");
  if (ran) { L_i(theBr.depth); L_s("/"); if (theBr.pathLen) L_i(theBr.pathLen); else if (theBr.towardLen) { L_s("t"); L_i(theBr.towardLen); } else L_s("0");
             if (brCut) L_s("/cut"); if (brResumed) { L_s("/r"); L_i(brResumed); } if (theBr.wide) { L_s("/w"); L_i(theBr.wide); } if (theBr.carried) L_s("/carried"); if (theBr.built) L_s("/built"); if (theBr.fresh) L_s("/fresh"); }
  else L_s("none");
  // (the deepest line the frontier carries to the next decision: how far the touch beam has grown across decisions)
  if (ran) { int deep = 0; for (int i = 0; i < theBr.keepOut.n; i++) deep = imax(deep, theBr.keepOut.len[i]); L_s(" brDeep="); L_i(deep); }
  L_s(" bat="); L_i(batTaken); L_s("/"); L_i(batOwn); L_s(":"); L_i(batSearch); L_s("/"); L_i(batBusy); L_s("/"); L_i(batSmall); L_s("/"); L_i(batTight); L_s("/"); L_i(__atomic_exchange_n(&batJobs, 0, __ATOMIC_RELAXED));
  L_s(" brMs="); L_i((int64_t)brMs); L_s(" brAt="); L_i(brWhere); L_s("/"); L_i((int64_t)brGiven);
  // (the jobs beside the decision, each one's end in ms from their start -- break, plan, ext, wide, survive; - not run -- and their stop)
  if (brWhere == 1 || brWhere == 2) { L_s(" jobs="); for (int k = 0; k < 5; k++) { if (k) L_s("/"); if (jobEndMs[k] < 0) L_s("-"); else L_i(jobEndMs[k]); } L_s(":"); L_i((int64_t)(brJobBy - brJobT0)); L_s(":"); L_i((int64_t)(C2.due ? (C2.due + brJobBy) / 2 - brJobT0 : 0)); }
  L_s(" plan="); L_i((int64_t)S.planShare); L_s("/"); L_i((int64_t)S.planFirst); L_s("/"); L_i(S.wide); L_s("/"); L_i((int64_t)S.ap.ms); L_s("/d"); L_i(S.planDepth); L_s("/l"); L_i(S.planLong);
  // (the planner and the list's first entry: a line that meets it found, and how near its nearest line comes, the first entry's percent)
  if (S.haveAp) { L_s(" p0="); L_i(S.ap.perAim[0].set ? 1 : 0); L_s("/"); L_i(S.ap.nearest.set ? (int64_t)S.ap.nearest.near : -1); }
  L_s(" cof="); L_i(carrySkip);
  if (A->ended == 16) { L_s(" c16="); L_i(carryClr); }
  L_s(" ms="); L_i((int64_t)brMs); L_s("/"); L_i((int64_t)S.searchMs); L_s("/"); L_i(phaseMs[0]); L_s("/"); L_i(phaseMs[1]); L_s("/"); L_i(phaseMs[2]);
  L_s(" cands=");
  int any = 0;
  for (int p = 0; p < NPLAYS; p++) {
    if (!offered[p] && !(p == PLAY_SURVIVE && surviveAsked)) continue;
    if (any) L_s(","); any = 1;
    L_play(p); L_s(":"); L_i(offered[p]);
    int dn = 0; for (int w = 0; w < NDROPS; w++) dn += dropped[p][w];
    if (dn) { L_s("-"); for (int w = 0; w < NDROPS; w++) if (dropped[p][w]) { char c[2] = { DROP_CHAR[w], 0 }; L_s(c); L_i(dropped[p][w]); } }
  }
  if (!any) L_s("-");
  L_s(" live="); L_i(P.nlive); L_s("/"); L_i(P.ncands);
  if (cutWhy[1] + cutWhy[2] + cutWhy[3]) { L_s(" cutWhy="); for (int w = 1; w <= 3; w++) { if (w > 1) L_s("/"); L_i(cutWhy[w]); } L_s(":"); for (int w = 1; w <= 3; w++) { if (w > 1) L_s("/"); L_i(cutWhyBreak[w]); } }
  if (unbroken.set) { L_s(" unbroken="); L_play(unbroken.play); L_s(":"); for (int i = 0; i < unbroken.nseq; i++) { if (i) L_s(";"); L_mv(unbroken.seq[i]); } L_s(":"); L_i(unbroken.said); L_s("/"); L_i(unbroken.judged); L_s("/"); L_i(unbroken.alone); }
  // (the one order, its first eight: the play -- * the line in progress -- whether it lives or the frame its board is lost, the garbage it breaks)
  // (the line in progress offered and put down for another: the line played and the order's key that put it first, rank.c cmpKey)
  if (carriedJ && top && top != carriedJ && !top->carried && compareJudged(top, carriedJ) < 0) { L_s(" putDown="); L_play(top->hold ? PLAY_HOLD : top->k.play); L_s(":k"); L_i(cmpKey); }
  // (the extension searched: its boards settled/kept, the chain left alone, the longest of any and of a kept one, put down late/for the floor, its ms)
  if (extLogged) { L_s(" xs="); L_i(extLog.seen); L_s("/"); L_i(extLog.kept); L_s("/"); L_i(extLog.baseChain); L_s("/"); L_i(extLog.top); L_s("/"); L_i(extLog.topKept);
    L_s("/"); L_i(extLog.late); L_s("/"); L_i(extLog.floorLost); L_s("/"); L_i((int32_t)extLog.ms); L_s("/L"); L_i(extLog.longest.set ? extLog.longest.chain : 0); L_s(":"); L_i(extLog.longCut); }
  else if (extSkip) { L_s(" xs=-"); L_i(extSkip); }
  if (openerPaused) L_s(" opPause=1");
  if (opKeepHeld) { L_s(" keep="); L_i(opKeepHeld); }   // (the opener paused, the board about to be lost: the mode after it plays, the opener's chains still counted)
  if (opKept) L_s(" opKept=1");
  // (each extension the judge cut: swap k of s, why w (judge.c cutWhy), the frame f its last pressed swap's walk began, the search's chain x)
  if (extCutN) { L_s(" extCut="); for (int i = 0; i < extCutN; i++) { if (i) L_s(","); L_s("k"); L_i(extCutLog[i][0]); L_s("s"); L_i(extCutLog[i][1]); L_s("w"); L_i(extCutLog[i][2]); L_s("f"); L_i(extCutLog[i][3]); L_s("x"); L_i(extCutLog[i][4]); } }
  if (opLandedRows[0]) { L_s(" landed="); L_s(opLandedRows); }
  // (each opener plan judged: pass p, swaps s, planned chain c, judged chain j, fires f frames on, verdict v (0 played, decide.c chainUp codes))
  if (opTryN) { L_s(" opTries="); for (int i = 0; i < opTryN; i++) { if (i) L_s(","); L_s("p"); L_i(opTryLog[i][0]); L_s("s"); L_i(opTryLog[i][1]); L_s("c"); L_i(opTryLog[i][2]);
    L_s("j"); L_i(opTryLog[i][3]); L_s("f"); L_i(opTryLog[i][4]); L_s("v"); L_i(opTryLog[i][5]); L_s("k"); L_i(opTryLog[i][6]); if (opTryLog[i][7]) L_s("D"); }
    // (the first three plans' swaps, row,col each, the trigger last)
    L_s(" opTrySeq="); for (int i = 0; i < opTryN && i < 3; i++) { if (i) L_s("|"); for (int s = 0; s < opTrySeqN[i]; s++) { if (s) L_s(";"); L_i(CR(opTrySeq[i][s])); L_s(","); L_i(CC(opTrySeq[i][s])); } } }
  if (opNextDesign) { L_s(" nd="); L_i(opNextDesign); if (opNextDesign != -1) { L_s("/c"); L_i(opNextCh); L_s("s"); L_i(opNextLen); if (opNextDesign == -3) { L_s("/d"); L_i(opNextDrop); L_s(" ndcut="); L_i(opNextCut); L_s("@"); L_i(opNextCutCell / 8); L_s(","); L_i(opNextCutCell % 8); L_s(":"); for (int i = 0; i < opNextSeqN; i++) { if (i) L_s(";"); L_i(opNextSeq[i] / 8); L_s(","); L_i(opNextSeq[i] % 8); } L_s(":"); L_s(opNextRows); } } else { L_s("/w"); L_i(opDesignWhy); L_s("/l"); L_i(opDesignLinks); L_s("/q"); L_i(opSeqLinks); L_s("/ms"); L_i(opNextMs); } }
  if (opCdRows[0]) { L_s(" cdboard="); L_s(opCdRows); }
  if (cdAsk && opExtN) { L_s(" opExt="); L_i(opExtMs); L_s("ms"); for (int i = 0; i < opExtN; i++) { L_s(i ? "," : ":"); L_s("s"); L_i(opExtCh[i][0]); L_s("c"); L_i(opExtCh[i][1]); L_s("x"); L_i(opExtCh[i][2]); } }
  // (each extension under the fall: swaps s, pressed by the judge p, chain as judged j, its search's x, lost d)
  if (opFallHeld && opFallLineN) { L_s(" fallLines="); for (int i = 0; i < opFallLineN; i++) { if (i) L_s(","); L_s("s"); L_i(opFallLine[i][0]); L_s("p"); L_i(opFallLine[i][1]); L_s("j"); L_i(opFallLine[i][2]); L_s("x"); L_i(opFallLine[i][4]); if (opFallLine[i][3]) L_s("d"); if (opFallLine[i][5] >= 0) { L_s("l"); L_i(opFallLine[i][5]); } } }
  if (opFallHeld) { L_s(" fallWay="); L_i(opFallWay); L_s(" fallBar="); L_i(opFallBar); L_s("/"); L_i(opFallExt); L_s(" fallExt="); L_i(opFallSeen); L_s("/"); L_i(opFallTop); L_s("/"); L_i(opFallDead); if (opFallLink) { L_s(" fallLink="); L_i(opFallLink); L_s("/"); L_i(opFallLinkCh); } if (opSpent) { L_s(" spent="); L_i(opSpent); L_s("/"); L_i(opSpentMat); L_s("/"); L_i(opSpentHeld); } }
  if (opFallHeld) { L_s(" fallHeld=1"); if (opSecondWhy) { L_s(" second="); L_i(opSecondWhy); L_s(":"); L_i(opSecondCh); if (opSecondWhy >= 4 && opSecondWhy != 8) { L_s(":"); L_i(opSecondMs); L_s("ms:n"); L_i(opSecondN); L_s(":d"); L_i(opDesignWhy); L_s("/"); L_i(opDesignLinks); } } }
  if (pvKind) { L_s(" pv="); L_i(pvKind); if (pvKind >= 3) { L_s(":"); L_i(pvV[0]); } if (pvKind >= 5) { L_s("/"); L_i(pvV[1]); } if (pvKind == 9) { L_s(":f"); L_i(pvV[2]); L_s(":"); L_i(pvV[3]); L_s("/"); L_i(pvV[4]); } if (pvKind == 10) { L_s(":"); L_i(pvV[2]); } }
  if (carryShort) { L_s(" carryShort="); L_i(carryShort); }
  if (carryDrop) {
    L_s(" carryDrop="); L_i(carryDrop);
    if (carryDrop == 2) { L_s(":d"); L_i(carryDropDead); L_s(":c"); L_i(carryDropCut); if (carryDropWhy) L_s(carryDropWhy == 1 ? "a" : carryDropWhy == 2 ? "n" : "w"); L_s(":n"); L_i(carryDropNats); }
    if (carryDrop >= 2) { L_s(" carryRest="); for (int i = 0; i < carryDropN; i++) { if (i) L_s(";"); L_mv(carryDropRest[i]); } }
    if (carryDrop >= 2) { L_s(" cj="); L_i(carryJ.made.chain); L_s("/"); L_i(carryJ.chainAll); L_s("/w"); L_i(carryJ.whole.chain); L_s("/d"); L_i(carryJ.done); L_s("/s"); L_i(theCarry.settled); L_s("/t"); L_i(carryJ.tightBits); L_s("/c"); L_i(carryJ.clearStep); L_s("/f"); L_i(carryJ.fire); L_s("/ats");
      for (int i = 0; i < carryJ.nats; i++) { L_s(i ? "," : ":"); L_i(carryJ.ats[i]); L_s("r"); L_i(carryJ.risen[i]); } }
  }
  // (the line in progress the last answer carried, not offered on this board: carriedCand's carryNone -- 17 asked on another line, 18 every
  // swap pressed, 19 the judging dropped it (the drop's letter, rank.c DROP_CODE), 20 a wasted three, 25 the window, 28 past the reach,
  // 29 a flip back -- none carried, or
  // the list asking nothing, is not said)
  if (!carriedJ && !carryDrop && carryNone && carryNone != 16 && carryNone != 21) {
    L_s(" carryNone="); L_i(carryNone);
    if (carryNone == 20) { L_s(" waste="); for (int i = 0; i < 5; i++) { if (i) L_s("/"); L_i(carryWaste[i]); } }
    if (carryNone == 19 && carryJudgeDrop >= 0 && carryJudgeDrop < NDROPS) { char c[3] = { ':', "botfrucwj2"[carryJudgeDrop], 0 }; L_s(c); }
  }
  // (A LATER LOSS PASSED OVER: where nothing lives, the line offered that is lost latest, where that is a break's time (rankSave) or more
  // after the line played -- its play, the frames to its loss, the garbage cells it breaks, and the order's key that put the line played
  // before it)
  if (top && !top->o.lives) {
    const Judge *pb = 0;
    for (int i = 0; i < P.ncands; i++) { const Judge *J = order[i]; if (J == top || J->o.dead || J->o.lives) continue; if (!pb || diesAt(J) > diesAt(pb)) pb = J; }
    if (pb && diesAt(pb) < 1e299 && diesAt(top) >= 0 && diesAt(pb) - diesAt(top) >= rankSave) {
      int32_t keepKey = cmpKey;
      compareJudged(top, pb);
      L_s(" passed="); L_play(pb->hold ? PLAY_HOLD : pb->k.play); L_s(":"); L_i((int64_t)diesAt(pb)); L_s(":"); L_i(pb->apBroke); L_s(":k"); L_i(cmpKey);
      cmpKey = keepKey;
    }
  }
  // (WHY THIS LINE: the order's key that put the line played before the best line it passed over, and what that line was -- rank.c's
  // line number, named by eval/rank_keys.js; none where nothing else was offered)
  if (top && P.ncands > 1) { const Judge *ru = order[0] == top ? order[1] : order[0]; int32_t keepKey = cmpKey;
    if (ru && ru != top && compareJudged(top, ru) < 0) { L_s(" won=k"); L_i(cmpKey); L_s(":"); L_play(ru->hold ? PLAY_HOLD : ru->k.play);
      // (both sides as the order read them: the frame each board is lost on, then that less the walk charged -- inf a board that lives)
      const Judge *s2[2] = { top, ru };
      L_s(" wonBy=");
      for (int q = 0; q < 2; q++) { if (q) L_s(":"); if (s2[q]->o.lives) L_s("inf"); else { L_i((int64_t)diesAt(s2[q])); L_s("/"); L_i((int64_t)lostOf(s2[q])); } L_s("/w"); L_i(s2[q]->hold ? 0 : lineWalk(s2[q])); } }
    cmpKey = keepKey; }
  L_s(" opts=");
  for (int i = 0; i < P.ncands && i < 8; i++) {
    const Judge *j = order[i];
    if (i) L_s(",");
    L_play(j->hold ? PLAY_HOLD : j->k.play); if (j == carriedJ) L_s("*"); if (j->outside) L_s("~");
    L_s(":"); if (j->o.lives) L_s("L"); else if (j->o.lostAt == FOREVER) L_s("inf"); else L_i(j->o.lostAt);
    L_s(":"); L_i(j->apBroke); if (j->readyNext == 1) L_s(":n");
    { int32_t b = j->hold ? 0 : blocksOf(j->apCombo, j->apChain); if (b) { L_s(":b"); L_i(b); } }   // (the blocks it throws)
    if (!j->hold && j->extLost != NOT_ASKED && !j->o.lives) { L_s(":then"); if (j->extLost == FOREVER) L_s("inf"); else L_i(j->extLost); }   // (lost with the next moves played: readiness's break or the survival search after it)
    if (!j->hold && j->apCombo >= 3) { L_s(":c"); L_i(j->apCombo); }   // (the biggest clear it makes)
    if (j->apChainAll >= 2) { L_s(":x"); L_i(j->apChainAll); }   // (the whole chain it ends in, the board's own falling chain with it)
  }
  // (WHAT EACH SWAP OF THE LINE PLAYED DOES: the line judged again without it -- n nothing lost without it (it does nothing), else what
  // is lost: Lf the board lost f frames sooner, bN N garbage cells fewer broken, cN a chain N links shorter, kN a combo N panels smaller,
  // rN the next break N swaps farther once the line is played, d the board dies; ? the clock
  // left no time to ask. Read off the judge alone: nothing here changes the move)
  if (top && !top->hold && top->k.nseq >= 2 && top->k.nseq <= MAXLINE) {
    static Judge pj; int32_t keepKey = cmpKey, keepDrop = lastDrop;
    L_s(" purpose=");
    for (int i = 0; i < top->k.nseq; i++) {
      if (i) L_s(",");
      if (clockOut()) { L_s("?"); continue; }
      Cand c = top->k; c.nseq = top->k.nseq - 1; c.xNats = 0;
      for (int q = i; q < c.nseq; q++) c.seq[q] = top->k.seq[q + 1];
      if (!judgeCand(&R, &c, &pj)) { L_s("x"); continue; }
      int any = 0;
      if (pj.o.dead && !top->o.dead) { L_s("d"); any = 1; }
      else if (!pj.o.lives && (top->o.lives || diesAt(&pj) < diesAt(top))) { L_s("L"); L_i(top->o.lives ? -1 : (int64_t)(diesAt(top) - diesAt(&pj))); any = 1; }
      if (imax(0, pj.apBroke) < imax(0, top->apBroke)) { L_s("b"); L_i(imax(0, top->apBroke) - imax(0, pj.apBroke)); any = 1; }
      if (pj.apChain < top->apChain) { L_s("c"); L_i(top->apChain - pj.apChain); any = 1; }
      if (pj.apCombo < top->apCombo) { L_s("k"); L_i(top->apCombo - pj.apCombo); any = 1; }
      if (top->o.nearAfter >= 0 && pj.o.nearAfter > top->o.nearAfter) { L_s("r"); L_i(pj.o.nearAfter - top->o.nearAfter); any = 1; }
      if (!any) L_s("n");
    }
    cmpKey = keepKey; lastDrop = keepDrop;
  }
  L_s(" lost="); if (top) { if (top->o.lostAt == FOREVER) L_s("inf"); else L_i(top->o.lostAt); } else L_s("-");
  // (THE MODE'S LIST, for the report: the entry the line played meets, whether it is a fallback -- an entry after the first that breaks
  // no garbage -- its loss, and of the lines offered that are no fallback the latest lost, L one that lives, - none; then a break's time,
  // rankSave: mode=entry/fallback/lost/other/save[/kKEY][/c])
  if (top && !top->hold && top->met >= 0) {
    const Judge *alt = 0;
    for (int i = 0; i < P.ncands; i++) {
      const Judge *j = order[i];
      if (j == top || (!j->hold && j->met > 0 && !(j->apBroke > 0))) continue;
      if (!alt || (j->o.lives && !alt->o.lives) || (j->o.lives == alt->o.lives && lostOf(j) > lostOf(alt))) alt = j;
    }
    L_s(" mode="); L_i(top->met); L_s("/"); L_i(top->met > 0 && !(top->apBroke > 0)); L_s("/");
    if (top->o.lives) L_s("L"); else if (lostOf(top) > 1e9) L_s("inf"); else L_i((int64_t)lostOf(top)); L_s("/");
    if (!alt) L_s("-"); else if (alt->o.lives) L_s("L"); else if (lostOf(alt) > 1e9) L_s("inf"); else L_i((int64_t)lostOf(alt));
    L_s("/"); L_i(rankSave);
    // (and the order's key that put the line played before that other: rank.c cmpKey, /kLINE)
    if (alt && top->met > 0 && !(top->apBroke > 0) && compareJudged(top, alt) < 0) { L_s("/k"); L_i(cmpKey); }
    // (and /c where the board is chaining, or about to: a chain going is carried on -- the fallback the chain reaches is the mode's rule)
    if (decQ.b && (decQ.b->chainCounter >= 2 || aloneChain >= 2)) L_s("/c");
  }
  // (THE LINE PLAYED OVER ONE LOST LATER: of the lines offered, the one lost latest when the line played does not live and it is lost
  // later -- its play, its loss and the order's key that put the played line first, rank.c cmpKey: sooner=play:lost:kLINE)
  A->sooner = 0;
  if (top && !top->o.lives) {
    const Judge *late = 0;
    for (int i = 0; i < P.ncands; i++) { const Judge *j = order[i]; if (j != top && (j->o.lives || lostOf(j) > lostOf(top)) && (!late || (j->o.lives && !late->o.lives) || (j->o.lives == late->o.lives && lostOf(j) > lostOf(late)))) late = j; }
    A->sooner = late && !late->o.lives && !lostAlike(top, late) && !(walkTurns(top, late) && diesAt(top) > diesAt(late));
    if (late && compareJudged(top, late) < 0) {
      L_s(" sooner="); L_play(late->hold ? PLAY_HOLD : late->k.play); L_s(":"); if (late->o.lives) L_s("L"); else L_i(late->o.lostAt); L_s(":k"); L_i(cmpKey);
      // (the survival credit each had beside the other: 1 counted as living -- rank.c creditPair)
      { int a, b; int32_t k = cmpKey; creditPair(top, late, &a, &b); L_s(" cr="); L_i(a); L_s("/"); L_i(b); cmpKey = k; }
    }
  }
  // (A BIGGER COMBO PASSED OVER at the finish: the first line in the order that makes a bigger combo with at most a 2x, lost no sooner,
  // and the key that put it after the line played -- rank.c finishBigger)
  if (top && !top->hold && finishAsked()) {
    for (int i = 0; i < P.ncands; i++) { const Judge *j = order[i]; if (j == top || !finishBigger(j, top)) continue;
      int32_t k = cmpKey; int r = compareJudged(top, j);
      L_s(" bigger="); L_play(j->k.play); L_s(":c"); L_i(j->apCombo); L_s(":"); if (j->o.lives) L_s("L"); else L_i((int32_t)diesAt(j)); L_s(":k"); L_i(cmpKey); if (r > 0) L_s("+");
      cmpKey = k; break; }
  }
  L_s(" ms_c="); L_i((int64_t)(nowMs() - tStart)); L_s(" ms_r="); L_i((int64_t)readMs);
  L_s(" why="); if (top) L_play(top->k.play); else L_s(d.kind == 2 ? "raise" : "hold");
  // (A RAISE, AND WHY: asked as the opening's (o) or the floor's refill (r), the rows to raise to and the rows short of them, and whether the
  // engine could raise now (1) or a cascade held it (0) -- on every decision a raise was asked)
  if (amidDropped) { L_s(" amid="); L_i(amidDropped); L_s("/"); L_i((int32_t)amidBest); }
  if (opRaiseLog[4]) { L_s(" opRaise="); L_i(opRaiseLog[0]); L_s("/"); L_i(opRaiseLog[1]); L_s("/"); L_i(opRaiseLog[2]); L_s("/"); L_i(opRaiseLog[3]); }
  if (R.low) { L_s(" raiseFor="); L_s(raiseOpening ? "o" : raiseRefill ? "r" : "-"); L_s(":"); L_i(raiseTo); L_s(":"); L_i(raiseRows); L_s(":"); L_i(R.up ? 1 : 0); }
  if (P.deferred) L_s(" deferred=1");
  // (WHY A HOLD HOLDS, named: raise -- waiting for the raise to open; timing -- its next swap does as well pressed later; nothing -- no
  // line but the hold was offered; rank -- the order put the hold first, won= names the rule)
  if (!P.line && !R.up) { L_s(" held="); L_s(P.wait ? "raise" : P.deferred ? "timing" : orderN <= 1 ? "nothing" : "rank"); }
  { static int32_t comboSeen; if (combosDropped != comboSeen) { L_s(" noFour=1"); comboSeen = combosDropped; } }
  { static int32_t rescueSeen; if (rescues != rescueSeen) { L_s(" rescued=1"); rescueSeen = rescues; } }
  if (R.saving) L_s(" saving=1");
  // (the panels the measured life peaks at, beside the owner's saving band, for the owner to read: core/material.h)
  // (THE STACK AS IT IS: its bumpiness -- the steps between columns, garbage counted -- the tallest less the shortest, and how zipped
  // its colours are (judge.c spreadOf): the owner's flatten and zip, read off every decision)
  if (decQ.b) { const Board *sb = decQ.b; int hg[W + 1] = { 0 }, bump = 0;
    for (int c = 1; c <= W; c++) for (int r = 1; r < sb->nrows; r++) if (sb->p[r][c].f[COLOR] > 0 || sb->p[r][c].f[ISGARBAGE]) hg[c] = r;
    for (int c = 1; c < W; c++) bump += iabs(hg[c] - hg[c + 1]);
    L_s(" stack="); L_i(bump); L_s("/"); L_i(evenOf(sb)); L_s("/"); L_i(spreadOf(sb)); }
  L_s(" lifePeak="); L_i(lifePeakOf()); L_s(" letDrop="); L_i(chaosLetDrop);
  if (R.full) L_s(" full=1");
  if (switchedNow) L_s(" switched=1");
  // (the enemy as the rules read it: its height, topped out, the frames of its stop -- what picked the rule)
  if (fillN != NOT_ASKED) { L_s(" fill="); L_i(fillN); }
  if (theOpp.has) { L_s(" enemy="); L_i(theOpp.top); L_s("/"); L_i(theOpp.out); L_s("/"); L_i(theOpp.stopKnown ? theOpp.stop : -1); }
  if (P.line && P.line->k.grown) L_s(" grown=1");
  if (P.line && P.line->k.drop) L_s(" drop=1");
  if (cappedN) { L_s(" capped="); L_i(cappedN); }
  // (THE BOARD THE BREAK SEARCH CAME UP EMPTY ON, under garbage, for the reach report: at most one every 30 frames)
  if (R.under && !(ran && theBr.depth) && (emptyAt == NUL || at - emptyAt >= 30 || at < emptyAt)) { emptyAt = at; A->dumpBoard = 1; }
  // (THE BOARD TOPPED WITH NO GARBAGE ON IT, for reading the stalls: at most one every 30 frames)
  else if (R.topped && !R.under && (emptyAt == NUL || at - emptyAt >= 30 || at < emptyAt)) { emptyAt = at; A->dumpBoard = 2; }
  // (THE OPENING'S PLAN PLAYED, for replaying the plan and the judge on the board it was made on -- GAMBITO, at most OPDUMPS a game)
  { static int32_t opDumps, opDumpGame = -1; if (decQ.b && decQ.b->clock < opDumpGame) opDumps = 0; if (decQ.b) opDumpGame = decQ.b->clock;
    if (chainUp >= 2 && opDumps < 3) { A->dumpBoard = 4; opDumps++; } }
  // (A LIFE NOT KEPT: the last decision's line lived under garbage, nothing new was told since -- the next block lands on the same frame,
  // as many queued -- and no line lives now. The engine predicts every frame, so this is a fault: this board and the last are logged,
  // GAMBITK, to be replayed side by side. At most LIFEDUMPS a game.)
  { int32_t landAbs = R.F.known[FACT_US_NEXTLANDS] ? at + (int32_t)R.F.v[FACT_US_NEXTLANDS] : NUL, qk = R.F.v[FACT_US_QUEUEKILLS] ? 1 : 0;
    if (lifeLived && landAbs != NUL && landAbs == lifeLand && qk == lifeQk && !P.nlive && lifeDumps < LIFEDUMPS) { A->dumpBoard = 3; lifeDumps++; }
    lifeLived = A->verdict == 1 && R.under; lifeLand = landAbs; lifeQk = qk; }
  // THE RAISE HELD DOWN: the steps the row has left, and the rows on to the rule's `to`
  // (a raise put off to the frame the stack takes one is held from then, on the board it will be: decide.c raiseWait)
  A->raiseWait = d.kind == 2 ? raiseWait : 0;
  if (d.kind == 2) { const Board *rb = A->raiseWait ? raiseWaitBoard : decQ.b;
                     A->raiseNow = imax(1, (rb->displacement ? rb->displacement : ROW_STEPS) - 1); A->raiseAfter = imax(0, R.to - fullTop(rb) - 1) * ROW_STEPS; }
}

// ---- THE HOST'S SIDE: the rules, the profile, a question, the log
// The rules (the loader encodes the rules file): rule count, then per rule -- table, name, nwhen, when (fact, op, n, near each), naims,
// aims (ten words each), end, byFact, byFrames, keep (on, then height, material, evenness tests: op, n, near each), raiseTo -- then the
// file's keep (as a rule's), raiseTo and underIgnore.
static int readTest(const int32_t **w, Test *t) { t->op = (*w)[0]; t->n = (*w)[1]; t->near = (*w)[2]; *w += 3; return 1; }
EXPORT(gb_rules) int gb_rules(int n) {
  if (n < 0 || n > MAXRULES) return -1;
  const int32_t *w = gbIo;
  memset(&theTables, 0, sizeof theTables);
  for (int i = 0; i < n; i++) {
    Rule *r = &theTables.r[i];
    r->table = *w++; r->name = *w++; r->nwhen = *w++;
    if (r->nwhen > MAXWHEN) return -1;
    for (int k = 0; k < r->nwhen; k++) { r->when[k].fact = *w++; readTest(&w, &r->when[k].t); }
    r->list.n = *w++;
    if (r->list.n > MAXAIMS) return -1;
    for (int k = 0; k < r->list.n; k++) { Aim *a = &r->list.aim[k]; readTest(&w, &a->combo); readTest(&w, &a->chain); readTest(&w, &a->send); a->brk = *w++; }
    r->end = *w++; r->byFact = *w++; r->byFrames = *w++;
    r->keep.on = *w++; for (int k = 0; k < NKEEP; k++) readTest(&w, &r->keep.t[k]);
    r->raiseTo = *w++;
  }
  theTables.n = n;
  theTables.keep.on = *w++; for (int k = 0; k < NKEEP; k++) readTest(&w, &theTables.keep.t[k]);
  theTables.raiseTo = *w++; theTables.underIgnore = *w++;
  return n;
}
// The profile: the mode played the whole game (the rule's name, -1: chosen by the facts each decision), the gambit's numbers, the
// bot's hands.
// THE BREAK SEARCH'S SHARE of the searches' time, in percent, under garbage and otherwise (the profile's `share`); 0 keeps the default
EXPORT(gb_share) void gb_share(int under, int otherwise) {
  underShare = under > 0 && under <= 100 ? under / 100.0 : UNDER_SHARE;
  breakShare = otherwise > 0 && otherwise <= 100 ? otherwise / 100.0 : BREAK_SHARE;
}
EXPORT(gb_profile) void gb_profile(int mode, int ms, int extendMs, int width, int depth, int pool, int extendDepth, int extendOff, int reaction, int swapGap, int cursor) {
  modeRule = mode;
  // (the opening raise is held through every row it is asked for -- search.h HOLD_THROUGH -- not let go at each row's end and asked
  // again a decision later)
  HOLD_THROUGH = 1;
  Profile p = { mode, ms, extendMs, width, depth, pool, extendDepth, extendOff };
  C2.GP = p; C2.reaction = reaction;
  gb_config(reaction, swapGap, cursor);
}
// WHAT A MODE CARRIES from one decision to the next, let go when the mode changes: the break search's lines, the line in progress (begun
// for the old mode's list), the dig, the line toward a break.
static void modeLeft(void) {
  lifeLived = 0;
  memset(&theKept, 0, sizeof theKept); memset(&theCarry, 0, sizeof theCarry); memset(&theCarryNext, 0, sizeof theCarryNext); memset(&theCarryOff, 0, sizeof theCarryOff); carryClr = 7;
  digOn = 0; digN = 0; digGid = NUL; towardPlayedN = 0; towardRestLen = 0; carriedSunk = -1;
}
// A new game: nothing of the last one is carried on.
EXPORT(gb_new_game) void gb_new_game(void) {
  modeLeft(); taReset(); undoFresh = 0; lifeDumps = 0; livedPrev = 0; openerOver = 0; openerPaused = 0; opKeepOn = 0; opKeepHeld = 0; openerChained = 0; openerThrown = 0; openerSum = 0; openerAt = 0; openingReset(); opLineOn = 0; opFalling = 0; opFiredAt = -1;
  if (thenRule >= 0) modeRule = C2.GP.mode;   // (the opener named again: the mode it gave way to was this game's)
  lastA = lastB = pairRuns = blockA = blockB = blockUntil = 0; emptyAt = NUL; gambitHit = 0; garbageSeen = 0; savingPanels = 0;
  C2.idle = 1;   // (the board left alone until play begins: the opening is idle time, planned with the whole of the searches' share)
  readyStop(); readyKeptClear();   // (a new game's boards are its own)
  memset(theIntents, 0, sizeof theIntents);
  memset(&thePlanKept, 0, sizeof thePlanKept);
  gb_back(0, 0, 0, 0, 0, 0, 0);
}
// THE MODE AFTER THE OPENER (the profile's `then`; -1 none): a game whose named mode is the opener plays it to the top-out, then this
EXPORT(gb_then) void gb_then(int rule) { thenRule = rule; }
EXPORT(gb_switch) void gb_switch(int min, int max) { switchMin = min > 0 ? min : 0; switchMax = max > switchMin ? max : switchMin; nswitch = 0; }
// (the circuit: Hierholzer's walk of the complete directed graph on n rules -- n(n-1) steps, each ordered pair once)
static int lapOf(int n, int32_t *lap) {
  static int32_t used[MAXRULES][MAXRULES], stack[MAXRULES * MAXRULES + 1];
  for (int a = 0; a < n; a++) for (int b = 0; b < n; b++) used[a][b] = a == b;
  int sp = 0, k = 0; stack[sp++] = 0;
  while (sp) {
    int v = stack[sp - 1], w = -1;
    for (int b = 0; b < n && w < 0; b++) if (!used[v][b]) w = b;
    if (w >= 0) { used[v][w] = 1; stack[sp++] = w; } else lap[k++] = stack[--sp];
  }
  for (int i = 0; i < k / 2; i++) { int32_t t = lap[i]; lap[i] = lap[k - 1 - i]; lap[k - 1 - i] = t; }
  return k - 1;   // (the walk ends where it began)
}
EXPORT(gb_switch_game) void gb_switch_game(uint32_t seed) {
  nswitch = 0; modeRule = C2.GP.mode;
  int32_t rules[MAXRULES], nr = 0;
  // (the modes live play can reach: a rule that is the first whose `when` holds at some enemy height -- one that tests anything else is
  // counted reachable; one every height of which an earlier rule takes is left out: the fill rule leaves big chain, pressure and build so)
  for (int i = 0; i < theTables.n && nr < MAXRULES; i++) {
    const Rule *r = &theTables.r[i];
    if (r->table != 1 || asksNoEnemy(r)) continue;
    int other = 0;
    for (int w = 0; w < r->nwhen; w++) if (r->when[w].fact != FACT_ENEMY_HEIGHT) other = 1;
    int reach = other;
    for (int h = 0; h <= 12 && !reach; h++) {
      int first = -1;
      for (int j = 0; j < theTables.n && first < 0; j++) {
        const Rule *q = &theTables.r[j];
        if (q->table != 1 || asksNoEnemy(q)) continue;
        int holds = 1;
        for (int w = 0; w < q->nwhen; w++) if (q->when[w].fact == FACT_ENEMY_HEIGHT && !test(h, q->when[w].t)) holds = 0; else if (q->when[w].fact != FACT_ENEMY_HEIGHT) holds = 0;
        if (holds) first = j;
      }
      if (first == i) reach = 1;
    }
    if (reach) rules[nr++] = r->name;
  }
  if (!switchMin || nr < 2) return;
  static int32_t lap[MAXRULES * MAXRULES + 1];
  int nl = lapOf(nr, lap);
  uint32_t s = seed * 2654435761u + 1;
#define NEXT() (s = s * 1664525u + 1013904223u, s >> 8)
  for (int i = nr - 1; i > 0; i--) { int j = (int)(NEXT() % (uint32_t)(i + 1)); int32_t t = rules[i]; rules[i] = rules[j]; rules[j] = t; }
  int at0 = (int)(NEXT() % (uint32_t)nl);
  int32_t t = 0;
  for (int k = 0; nswitch < MAXSWITCH; k++) {
    switchAt[nswitch] = t; switchMode[nswitch++] = rules[lap[(at0 + k) % nl]];
    t += switchMin + (int32_t)(NEXT() % (uint32_t)(switchMax - switchMin + 1));
  }
#undef NEXT
}
// The mode the game plays at frame `at`: the profile's, or the switch in force then
static int32_t modeAt(int32_t at) {
  if (!nswitch) return C2.GP.mode;
  int k = 0;
  while (k + 1 < nswitch && switchAt[k + 1] <= at) k++;
  return switchMode[k];
}
// A QUESTION ON THE BOARD IN hostQ (hostBoard, its hold and garbage on its way): the answer into theAnswer, the log line at logBuf
static void answerQuestion(int qid, int at, int topped, int oppHas, int oppOut, int oppTopKnown, int oppTop, int oppStopKnown, int oppStop,
                           int allowanceKnown, int allowance, int lineFrom, int linePressed, int canRaise, double due, double t0, double margin) {
  decQ = hostQ; decQ.b = hostBoard;
  levelBreak = C2.reaction + 1 + decQ.b->fFLASH + decQ.b->fFACE + decQ.b->fPOP * (3 + W);   // (outcome.c: the level's break, as rankSave)
  if (levelBreak <= 0) levelBreak = LEVEL11_BREAK;
  ncache = 0; nrested = 0; rootBuildable = NOT_ASKED; rootQueueAt = QUEUE_UNSET;
  // (switching: the mode in force at the question's frame; a change lets go of what the old mode carried)
  // (the opener plays from the countdown to its end -- the top-out, or nobody across its chain thrown -- and the schedule runs from there)
  switchedNow = 0;
  // (A SWITCH OF MODE clears nothing: the board is the same board, and every line kept is ranked again by the new mode's keys, which
  // say whether it fits)
  if (nswitch && openerOver) { int32_t m = modeAt(at - openerAt); if (m != modeRule) { if (modeRule >= 0) switchedNow = 1;  modeRule = m; } }
  hostTopped = topped;
  Opp o = { oppHas, oppOut, oppTopKnown, oppTop, oppStopKnown, oppStop }; theOpp = o;
  canRaiseNow = canRaise;
  C2.due = due; C2.t0 = t0; C2.margin = margin;
  clockStart(due ? due - margin : 0);
  decF.timeLeft = -1;   // (readiness is asked while the searches have time left, as each outcome finds it)
  answerTurn(qid, at, allowanceKnown, allowance, lineFrom, linePressed);
}
// A QUESTION: its board, hold and garbage on its way are node i of the host's search (the root it made); then its own facts. The answer
// into the io body (gb_answer's words below); the log line at gb_log.
EXPORT(gb_answer) int gb_answer(Ctx *hx, int i, int qid, int at, int topped, int oppHas, int oppOut, int oppTopKnown, int oppTop, int oppStopKnown, int oppStop,
                                int allowanceKnown, int allowance, int lineFrom, int linePressed, int canRaise, double due, double t0, double margin) {
  if (gb_question(hx, i, 0) < 0) return -1;
  answerQuestion(qid, at, topped, oppHas, oppOut, oppTopKnown, oppTop, oppStopKnown, oppStop, allowanceKnown, allowance, lineFrom, linePressed,
                 canRaise, due, t0, margin);
  Answer *A = &theAnswer;
  int32_t *w = gbIo, k = 0;
  w[k++] = A->d.kind; w[k++] = A->d.move ? CR(A->d.move) : 0; w[k++] = A->d.move ? CC(A->d.move) : 0;
  w[k++] = A->raiseNow; w[k++] = A->raiseAfter; w[k++] = A->verdict; w[k++] = A->holdLives; w[k++] = A->brk; w[k++] = A->urgent;
  w[k++] = A->offered; w[k++] = A->lineup; w[k++] = A->touch; w[k++] = A->took; w[k++] = A->clears; w[k++] = A->dumpBoard;
  w[k++] = A->play; w[k++] = A->combo; w[k++] = A->chain; w[k++] = A->chainAll; w[k++] = A->broke; w[k++] = A->done; w[k++] = A->fire;
  w[k++] = (int32_t)A->idleMs; w[k++] = (int32_t)A->brMs;
  w[k++] = A->nhand; for (int q = 0; q < A->nhand; q++) w[k++] = A->hand[q];
  w[k++] = A->nseq; for (int q = 0; q < A->nseq; q++) w[k++] = A->seq[q];
  w[k++] = A->d.kind < 0 ? -1 : A->rule; w[k++] = A->nlive; w[k++] = A->ncands;
  w[k++] = A->handSettled; for (int q = 0; q < A->nhand; q++) w[k++] = A->handAt[q];
  return k;
}
EXPORT(gb_log) const char *gb_log(void) { return logBuf; }
EXPORT(gb_log_len) int gb_log_len(void) { return logN; }
EXPORT(gb_play_name) const char *gb_play_name(int p) { return p == -2 ? "raise" : p >= 0 && p < NPLAYS ? PLAY_NAME[p] : ""; }
