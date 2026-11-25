// THE NODES: the one way any of Gambit's searches plays a line. A node is a board at a frame (engine/search.h); step() makes the next
// node -- a swap pressed as the game presses it (the walk to it, the wait for the board), a settle, a wait -- charged to the clock.
#ifndef GAMBIT_NODES_H
#define GAMBIT_NODES_H
#include "clock.h"
// GAMBIT'S OWN IO: what the host hands Gambit (rules, a list, a line, the lines carried on) and what Gambit answers, apart from the
// engine's io (pa.c ioBody), which the host writes a board into -- natively from another thread while Gambit thinks.
#define GBIO (1 << 16)
static int32_t gbIo[GBIO];
EXPORT(gb_io) int32_t *gb_io(void) { return gbIo; }
// THE PRESS AS THE FRAME LOOP MAKES IT: with the input budget tight (pressTight: the decision's allowance at or under the frame loop's
// HOLDTIGHT) the frame loop walks the cursor held from two cells, which presses a swap later than the search's own tapped walk. The
// frames later, from node pi -- the search's keys for the swap, walked as the frame loop walks them.
#define TAP_GAP 4         // frames between taps (cursorMoveFrames)
#define REPEAT_FIRST 10   // frames from the press to the second cell (curWaitTime 20, counted twice a frame)
#define HOLDTIGHT 40      // the actions short of the input limit at which every walk of two cells or more is held (the search and the frame loop)
static LOCAL int32_t pressTight;
// A BOARD NEAR ITS END (pressTap): lost within TAP_DIES frames left alone (its stop, or its rise to the top, and its health) -- its
// walks tapped, on time, while the allowance keeps TAP_RESERVE actions to spare; held as when tight below that. The decision says so
// (answer.c), the frame loop presses its line so. TAP_DIES -1: never -- every walk held as the walls allow, the window kept.
#define TAP_RESERVE 16
#define TAP_DIES -1
static LOCAL int32_t pressTap;
static int tightAt(int left) { return left <= HOLDTIGHT && !(pressTap && left > TAP_RESERVE); }
#define MIN_LEG 3          // the shortest walk a held key is no later on
// A HELD KEY ENDS AT THE WALL: a direction is held only for a walk the board stops -- to column 1 or W - 1, or down to row 1 -- as a
// player slides to the edge and taps back from it; a walk that ends anywhere else is tapped a cell at a time (the owner: the bot slides
// only to the end, as a player would). (The stack's top moves, so a walk up is tapped.) legMove: where a leg of `cells` from (row, col)
// ends; legHeld: whether a leg ending at (row, col) may be held.
static void legMove(int32_t v, int cells, int *row, int *col) {
  int32_t d = v & 15;
  if (d & IN_RIGHT) *col = *col + cells > W - 1 ? W - 1 : *col + cells;
  else if (d & IN_LEFT) *col = *col - cells < 1 ? 1 : *col - cells;
  else if (d & IN_UP) *row += cells;
  else if (d & IN_DOWN) *row = *row - cells < 1 ? 1 : *row - cells;
}
// NO DAS (the owner: no DAS): no direction is ever held to auto-repeat -- every walk is tapped a cell at a time, by the search, the judge
// and the frame loop alike
#define NO_DAS 1
// THE REACH (the owner: can't move more than five -- keep moves close by): the cursor steps, rows and columns, from the cursor to a swap.
// Closer is preferred within it by the walk's charge (rank.c lostOf); six measured no better (73 of 84 against 75-77 at five).
// Every search grows a line only by swaps within it of where the cursor stands (search/break.c swapsOfNode), and the order keeps no line
// past it (decide.c farForNothing)
#define REACH_STEPS 6   // owner: keep moves close, no more than five -- then: try six, but prefer closer (the walk charge)
static int legHeld(int32_t v, int row, int col) {
  if (NO_DAS) return 0;
  int32_t d = v & 15;
  return (d & IN_RIGHT) ? col >= W - 1 : (d & IN_LEFT) ? col <= 1 : (d & IN_DOWN) ? row <= 1 : 0;
}
// A WALK'S SHAPE when the allowance is tight, a leg of n cells from (row, col): 1 held to the wall it ends at (*w its cells); 2 slid to
// the wall past its end and tapped back *b cells -- as a player slides to the edge and comes back, where that costs fewer actions than
// tapping each cell (1 + *b against n); 0 tapped.
static int legShape(int32_t v, int n, int row, int col, int *w, int *b) {
  if (NO_DAS) return 0;
  int32_t d = v & 15;
  int wall = (d & IN_RIGHT) ? W - 1 - col : (d & IN_LEFT) ? col - 1 : (d & IN_DOWN) ? row - 1 : -1;
  if (n < 2 || wall < 0) return 0;
  if (wall <= n) { *w = n; *b = 0; return 1; }
  *w = wall; *b = wall - n;
  return 1 + *b < n ? 2 : 0;
}
// (a slide and the taps back, as keys: the direction held until the cursor is at the wall -- REPEAT_FIRST - 2 frames past its w-th
// cell, walkLeg -- then the way back tapped TAP_GAP frames apart, the frames after them the leg's own other keys (base); never shorter
// than the leg tapped (len), so its swap comes no sooner than the judge's tapped walk presses it. The keys written)
static int legSlide(int32_t v, int32_t base, int w, int b, int len, int32_t *out, int cap) {
  int32_t d = v & 15, back = (d & IN_RIGHT) ? IN_LEFT : (d & IN_LEFT) ? IN_RIGHT : IN_UP;
  int k = 0;
  for (int g = 0; g < w + REPEAT_FIRST - 1 && k < cap; g++) out[k++] = v;
  for (int t = 0; t < b; t++) for (int g = 0; g < TAP_GAP && k < cap; g++) out[k++] = g ? base : base | back;
  while (k < len && k < cap) out[k++] = base;
  return k;
}
// The cost in actions of a swap at (r, c) from the cursor at (row, col): its walk, across then up or down, each held when it would be
// -- and only where it ends at the wall -- (left: the actions the input budget still allows -- tight at HOLDTIGHT or under). The frame
// loop's and the judge's, the one count.
static int iabs(int v) { return v < 0 ? -v : v; }
// (and, tight, slid to the wall and tapped back where that costs fewer: legShape)
static int legCost(int32_t d, int n, int row, int col, int tight, int inner) {
  int w, b, s = legShape(d, n, row, col, &w, &b);
  if (tight) return s == 1 ? 1 : s == 2 ? 1 + b : n;
  return s == 1 && (n >= MIN_LEG + 1 || (n == MIN_LEG && inner)) ? 1 : n;
}
static int actionsFor(int row, int col, int r, int c, int left) {
  int tight = tightAt(left), cost = 1;
  if (c != col) cost += legCost(c > col ? IN_RIGHT : IN_LEFT, iabs(c - col), row, col, tight, r != row);
  if (r != row) cost += legCost(r > row ? IN_UP : IN_DOWN, iabs(r - row), row, c, tight, 0);
  return cost;
}
// THE ALLOWANCE A JUDGED LINE PRESSES UNDER: the decision's (NOT_ASKED: the host did not say), less what the line's own swaps spend --
// a line long enough walks held from two cells once its own presses bring the budget to HOLDTIGHT, as the frame loop walks it
static int32_t pressAllowance = -1;
// THE INPUT WINDOW THE LINE IS PRESSED IN (a native host's frame loop says it, front.c ask): how many frames before the question's frame
// each action still inside the window went down -- planned ones up to it too -- and the window's length. The actions left at frame t
// from the question's: the limit less those still inside the window then, less what the line has spent. nWinAges -1: not said, the
// decision's allowance less what is spent.
#define WINMAX 512
static int32_t winAges[WINMAX], nWinAges = -1, winLen = 600, hostWin;
// (A SEARCH BEGUN ON THE BOARD A LINE LEAVES reads the window that line leaves it: the frames from the question's to its root, and the
// actions the line was pressed with -- decide.c contLostOf)
static LOCAL int32_t winPast, winGone;
static int allowLeftAt(int32_t t, int spent) {
  if (pressAllowance < 0) return -1;
  t += winPast; spent += winGone;
  if (nWinAges < 0) return pressAllowance - spent;
  int in = 0; for (int i = 0; i < nWinAges; i++) in += winAges[i] + t < winLen;
  return imax(0, pressAllowance + nWinAges - in - spent);
}
// THE WAIT FOR THE WINDOW: the frames from t until the window, less what the line has spent, holds `need` actions again -- its oldest
// presses leaving it. -1: never, or the window not said
static int32_t allowWait(int32_t t, int spent, int need) {
  if (pressAllowance < 0 || nWinAges < 0 || allowLeftAt(t + winLen, spent) < need) return -1;
  int32_t lo = 0, hi = winLen;
  while (hi - lo > 1) { int32_t mid = (lo + hi) / 2; if (allowLeftAt(t + mid, spent) >= need) hi = mid; else lo = mid; }
  return hi;
}
static LOCAL int32_t keyBuf[3 * 4096], walkBuf[2 * 4096];
static int firstSwap(const int32_t *in, int n) { for (int i = 0; i < n; i++) if (in[i] & IN_SWAP) return i; return -1; }
// A WALK'S LEG in a line's keys, from key i: a direction tapped a cell at a time, TAP_GAP frames apart (in[i] the direction with the
// frame's other keys, in[i + 1] those keys alone). 0 when key i begins none; else its cells (*cells), its last tap (*p), the last frame of
// its taps' gap (*end), and the frame a held key reaches its last cell (*last). Every reader of the walks (slowWalks, front.c) asks it.
typedef struct { int32_t v, base; int cells, p, end, last; } Leg;
static int walkLeg(const int32_t *in, int n, int i, Leg *L) {
  int32_t v = in[i], dir = v & 15;
  if (!dir || (dir & (dir - 1)) || i + 1 >= n || (in[i + 1] & 15) || (v & ~15) != in[i + 1]) return 0;
  int32_t base = in[i + 1];
  int cells = 1, p = i;
  while (p + TAP_GAP < n && in[p + TAP_GAP] == v && in[p + 1] == base && in[p + 2] == base && in[p + 3] == base) { p += TAP_GAP; cells++; }
  int end = p;
  while (end + 1 < n && end + 1 <= p + TAP_GAP - 1 && in[end + 1] == base) end++;
  L->v = v; L->base = base; L->cells = cells; L->p = p; L->end = end; L->last = i + cells + REPEAT_FIRST - 2;
  return 1;
}
// slowWalks' keys: every walk of two cells or more that ends at the wall held, and one a slide to the wall and back saves actions on
// slid (legShape), the frames it is late by put in before the next key (the cursor at (row, col) when the keys begin)
static int slowWalks(const int32_t *in, int n, int32_t *out, int cap, int row, int col) {
  int k = 0, i = 0;
  while (i < n && k < cap) {
    Leg L;
    if (!walkLeg(in, n, i, &L)) { out[k++] = in[i]; i++; continue; }
    int32_t v = L.v, base = L.base, cnt = L.cells, last = L.last, end = L.end;
    int w, b, shape = legShape(v, cnt, row, col, &w, &b);
    legMove(v, cnt, &row, &col);
    if (shape == 2) { k += legSlide(v, base, w, b, end - i + 1, out + k, cap - k); i = end + 1; continue; }
    if (shape != 1) { for (int f = i; f <= end && k < cap; f++) out[k++] = in[f]; i = end + 1; continue; }
    for (int g = i; g <= (last > end ? last : end) && k < cap; g++) out[k++] = g <= last ? v : base;
    i = end + 1;
  }
  return k;
}
// (the tapped walk's own step, played to read its keys: pressMade, kept for step() -- with no delay it IS the step, so the swap is not
// played twice)
static LOCAL int pressMade, pressHave;
static int32_t pressDelayOf(Ctx *x, int pi, int mr, int mc) {
  const Board *b0 = ensureBoard(x, pi);
  if (!b0) return 0;
  int row = b0->curRow, col = b0->curCol;
  tape = keyBuf; tapeN = 0; tapeCap = (int32_t)(sizeof keyBuf / sizeof keyBuf[0]) / 3;
  int r = advance(x, pi, MK_SWAP, mr, mc, 0);
  tape = 0;
  pressMade = r; pressHave = 1;
  if (r == STEP_NULL || r == STEP_ERR) return 0;
  int n = tapeN;
  static LOCAL int32_t in[4096];
  for (int i = 0; i < n; i++) in[i] = keyBuf[3 * i];
  int tap = firstSwap(in, n), slow = firstSwap(walkBuf, slowWalks(in, n, walkBuf, (int)(sizeof walkBuf / sizeof walkBuf[0]), row, col));
  return tap >= 0 && slow > tap ? slow - tap : 0;
}
// (the delay is the board's, every time: the same cursor and swap are later by more or less as the board makes the walk wait)
static int32_t pressDelay(Ctx *x, int pi, int mr, int mc) {
  if (!pressTight || !mr) return 0;
  return pressDelayOf(x, pi, mr, mc);
}
// The child of node pi by one step (search.h advance: MK_SWAP, MK_SETTLE, MK_LONG, MK_HOLD), STEP_NULL when the clock is out or the
// step is refused, STEP_DEAD when the board is lost on it (deadAt). A swap is pressed as the frame loop presses it: with the input
// budget tight, the frames its held walk is later by are waited first -- every search and the judge on the one press clock.
// (THE STEPS BY THREAD, the decision's -- answer.c logs them, bat=TAKEN/OWN:SEARCH/BUSY/SMALL/TIGHT/JOBS: steps taken from a batch the
// workers made; steps made on the decision's thread, and of them those made before the judging; of the batches asked, the steps refused
// for the pool busy with jobs, for a batch under 8, and for a press waiting its walk; the steps the jobs made on the workers meanwhile)
static int32_t batTaken, batOwn, batSearch, batBusy, batSmall, batTight, batJobs;
static int step(Ctx *x, int pi, int kind, int mr, int mc, int32_t frames) {
  if (clockOut()) return STEP_NULL;
  if (!inJob) batOwn++; else __atomic_add_fetch(&batJobs, 1, __ATOMIC_RELAXED);
  int32_t t0 = NODE(x, pi)->t;
  if (pressTight && mr && (kind == MK_SWAP || kind == MK_SETTLE)) {
    pressHave = 0;
    int32_t late = pressDelay(x, pi, mr, mc);
    if (late > 0) {
      int w = advance(x, pi, MK_LONG, 0, 0, late);
      if (w < 0 || NODE(x, w)->dead) { clockCharge(late); return w == STEP_DEAD || (w >= 0 && NODE(x, w)->dead) ? STEP_DEAD : w; }
      pi = w;
    }
    // (no delay: the frame loop presses the swap as the tapped walk did, so the step pressDelay played is this step -- the same swap from
    // the same node, with frames 0 -- and is not played again)
    else if (kind == MK_SWAP && frames == 0 && pressHave) {
      int r = pressMade;
      clockCharge(r >= 0 ? NODE(x, r)->t - t0 : r == STEP_DEAD ? deadAt - t0 : 1);
      return r;
    }
  }
  int r = advance(x, pi, kind, mr, mc, frames);
  clockCharge(r >= 0 ? NODE(x, r)->t - t0 : r == STEP_DEAD ? deadAt - t0 : 1);
  return r;
}

// MANY STEPS AT ONCE: a batch of steps (each a parent and a move) played on every thread the host gave the engine's pool (search.h
// runPhase: native.c's workers), then TAKEN one at a time in the batch's order (stepTake): each charged to the clock as step() charges
// it, and none taken once the clock is out -- so a search that takes its batch in order, and stops where it would have stopped, makes
// the same children and spends the same clock as one step at a time. With no workers, a batch too small to share, or a swap whose press
// waits its walk first (pressDelay), the step is made when it is taken.
// A search run as a job on the threads (search/break.c readyJob) is a thread's whole: its steps are its own, never a batch; and while jobs
// hold the pool (search.h poolBusy) the decision's own steps are made one at a time.
#define UNBATCHED (-97)
#define BATCH_CHUNK 256
static Vec batchTasks, batchRes, batchDead;
static LOCAL int batchN;
static void stepBatch(Ctx *x, const int32_t *parents, const int32_t *moves, int kind, int n) {
  batchN = 0;
  if (!inJob && pool.nworkers > 0) { if (__atomic_load_n(&poolBusy, __ATOMIC_ACQUIRE)) batBusy += n; else if (n < 8) batSmall += n; }
  if (inJob || __atomic_load_n(&poolBusy, __ATOMIC_ACQUIRE) || pool.nworkers <= 0 || n < 8 || clockOut() || !vreserve(&batchTasks, 4 * n) || !vreserve(&batchRes, n) || !vreserve(&batchDead, n)) return;
  // (played BATCH_CHUNK steps at a time, the clock asked between: the threads play a phase to its end, and a batch of a wide beam's
  // kids -- up to PLAN_KIDS -- is hundreds of ms the decision's thread does not ask the clock in. A step left unplayed stays UNBATCHED,
  // made when it is taken.)
  for (int j = 0; j < n; j++) batchRes.a[j] = UNBATCHED;
  pool.deadAt = batchDead.a; pool.moves = 0;
  int any = 0;
  for (int j0 = 0; j0 < n && !(any && clockOut()); j0 += BATCH_CHUNK) {
    int j1 = j0 + BATCH_CHUNK < n ? j0 + BATCH_CHUNK : n;
    batchTasks.n = 0;
    for (int j = j0; j < j1; j++) {
      int mr = CR(moves[j]), mc = CC(moves[j]);
      if ((pressTight && mr && pressDelay(x, parents[j], mr, mc) > 0) || !ensureBoard(x, parents[j])) { batTight++; continue; }
      batchTasks.a[batchTasks.n++] = parents[j]; batchTasks.a[batchTasks.n++] = ADVANCE_TASK - ((((mr << 3) | mc) << 3) | kind);
      batchTasks.a[batchTasks.n++] = 0; batchTasks.a[batchTasks.n++] = j;
      batchRes.a[j] = PENDING;
    }
    if (!batchTasks.n) continue;
    if (!runPhase(x, &batchTasks, batchRes.a)) { for (int j = j0; j < j1; j++) if (batchRes.a[j] == PENDING) batchRes.a[j] = UNBATCHED; break; }
    any = 1;
  }
  pool.deadAt = 0;
  if (!any) return;
  batchN = n;
}
// the batch's step j (its parent pi, its move), as step() would make it now
static int stepTake(Ctx *x, int j, int pi, int kind, int32_t mv) {
  if (j >= batchN || batchRes.a[j] == UNBATCHED || batchRes.a[j] == PENDING) return clockOut() ? STEP_NULL : step(x, pi, kind, CR(mv), CC(mv), 0);
  if (clockOut()) return STEP_NULL;
  batTaken++;
  int32_t r = batchRes.a[j], t0 = NODE(x, pi)->t;
  clockCharge(r >= 0 ? NODE(x, r)->t - t0 : r == STEP_DEAD ? batchDead.a[j] - t0 : 1);
  if (r == STEP_DEAD) deadAt = batchDead.a[j];
  return r;
}
// (the batch let go: a search's later steps are made one at a time)
static void batchDone(void) { batchN = 0; }

// THE BOT'S HANDS, as the host has them (gb_config): the frames it waits after a decision, after a swap, and a cursor step. Every
// context a search makes is set so (surviveFrames and surviveRest 0).
static int32_t cfgReaction = 12, cfgSwapGap = 12, cfgCursor = 4;
EXPORT(gb_config) void gb_config(int reaction, int swapGap, int cursorMoveFrames) { cfgReaction = reaction; cfgSwapGap = swapGap; cfgCursor = cursorMoveFrames; }
// A CONTEXT LET GO OFF THE SEARCH'S THREAD (native.c's reaper, where the host has one): its boards are freed there, and a context it
// has emptied comes back for the next search (0: none ready, a new one is made; `least`: the fewest nodes it holds room for). Freeing tens of thousands of boards is 120-220 ms
// with no clock check; on the thread that searched it would land in the decision's last moments. With no reaper, or its queue full,
// the context is emptied here.
static int (*reapHand)(Ctx *x); static Ctx *(*reapTake)(int32_t least); static void (*reapReturn)(Ctx *x);
static Ctx *ctxLetGo(Ctx *x) {
  if (!x) return 0;
  if (reapHand && reapHand(x)) return reapTake(0);
  ns_reset(x);
  return x;
}
static Ctx *ctxOf(Ctx *x) {
  if (!x) x = ns_ctx_new();
  ns_ctx_set(x, cfgReaction, cfgCursor, 0, 0); ns_ctx_gap(x, cfgSwapGap);
  return x;
}
// THE QUESTION: the board a decision is made on, the raise in hand and the garbage on its way -- what every search roots its lines at.
typedef struct { Board *b; int32_t holdLeft, holdStarted, narr; Arr arr[MAXARR]; int32_t tight; } Question;
// THE LAST SEARCH'S TREE LET GO AT A ROOT (rootResetOf): a tree of REAP_AT nodes or more is swapped for an emptied one of the reaper's and
// handed to it whole -- the context the search keeps stays its own, only its nodes change -- else emptied here. The one swapped in holds
// half the nodes this one does at least (a smaller one is grown, every node copied at each growth, with no clock asked either); with none
// ready, a new one is made with room for as many (its pages untouched until written), and the reaper hands this one back for the next
#define REAP_AT 4096
static void rootResetOf(Ctx *x) {
  if (reapHand && x->n >= REAP_AT && !x->par) {
    Ctx *f = reapTake(x->cap / 2);
    if (!f && (f = ns_ctx_new())) {
      f->nodes = (Node *)grab((unsigned long)x->cap * sizeof(Node));
      if (f->nodes) f->cap = x->cap; else { reapReturn(f); f = 0; }
    }
    if (f) {
      Node *nn = f->nodes; int32_t ncap = f->cap;
      f->nodes = x->nodes; f->n = x->n; f->cap = x->cap; f->later.n = 0;
      x->nodes = nn; x->n = 0; x->cap = ncap; x->later.n = 0;
      if (reapHand(f)) return;
      // (the reaper's queue full: the two put back, the tree emptied here, the empty one returned)
      nn = x->nodes; ncap = x->cap;
      x->nodes = f->nodes; x->n = f->n; x->cap = f->cap;
      f->nodes = nn; f->n = 0; f->cap = ncap;
      reapReturn(f);
    }
  }
  ns_reset(x);
}
// A search's root, made from the question: every node before it is let go.
static int rootOf(Ctx *x, const Question *q) {
  rootResetOf(x);
  Board *b = nb_new();
  if (!b) return STEP_ERR;
  cloneBoard(b, q->b);
  Node *n = newNode(x);
  if (!n) { nb_free(b); return STEP_ERR; }
  n->st = b; n->t = 0; n->holdLeft = q->holdLeft; n->holdStarted = q->holdStarted; n->fresh = 0; n->narr = q->narr;
  for (int i = 0; i < q->narr; i++) n->arr[i] = q->arr[i];
  readBoard(n, b);
  x->rootBrk = n->brk;
  for (int i = 0; i < x->tagCap; i++) x->brkAt[i] = -1;
  return n->err ? STEP_ERR : (int)(n - x->nodes);
}
// A node made and not lost (a step can come back refused, lost, or out of the clock).
static int liveNode(Ctx *x, int i) { return i >= 0 && !NODE(x, i)->dead; }
// Whether the swap at (r, c) is one of node i's legal swaps.
static int legalAt(Ctx *x, int i, int r, int c) {
  static LOCAL int32_t ms[MAXROWS * W];
  Board *b = ensureBoard(x, i);
  if (!b) return 0;
  int n = legalSwaps(b, ms);
  for (int k = 0; k < n; k++) if (ms[k] == r * 8 + c) return 1;
  return 0;
}
// A SWAP PRESSED AS THE FRAME LOOP PRESSES IT (front.c keysOf and the judge, the one way): the walk to it begun and the swap pressed when
// the cursor gets there. A press refused there while the board still moves -- its pair swapping or falling -- is walked to again from
// the frame after, until one is taken or the board stands still: the swap goes in the first frame the walk can put it in, never a walk
// later. walk: the step that walks (the frame loop's advance writing its keys; the judge's, unheld). Returns the walk taken (a node,
// STEP_NULL none, STEP_DEAD lost on it, STEP_ERR) and in *from the node it began on -- -1 when the board was lost while it waited.
#define PRESS_WAIT 20    // the frames a swap is waited for at most: a swap whose pair stays locked longer is not there -- the line is cut, and
                         // lines that work with what can be swapped now are played (the owner: play normally, never wait on panels that cannot move)
static int pressWalk(Ctx *x, int n, int kind, int mr, int mc, int (*walk)(Ctx *, int, int, int, int, int32_t), int *from) {
  for (int k = 0;; k++) {
    int32_t mark = tapeN;
    int r = walk(x, n, kind, mr, mc, 0);
    *from = n;
    if (r != STEP_NULL) return r;
    tapeN = mark;
    Board *b = ensureBoard(x, n);
    if (k >= PRESS_WAIT || !b || !(hasActivePanels(b) || b->swappingCount > 0)) return STEP_NULL;
    int w = walk(x, n, MK_LONG, 0, 0, 1);
    if (w == STEP_NULL || w == STEP_ERR) return w;
    if (w == STEP_DEAD || NODE(x, w)->dead) { if (w >= 0) deadAt = NODE(x, w)->t; *from = -1; return STEP_DEAD; }
    n = w;
  }
}
// WHAT A STEP DID (pa.c ns_step_stats), read off the board it made: each clear's size and the chain counter it reached, panels
// cleared, garbage cells converted, the most stop one clear paid.
typedef struct { int32_t n, size[MAXCOMBOS], chainAt[MAXCOMBOS], link[MAXCOMBOS], touch[MAXCOMBOS], cleared, broke, earned; } Stats;
static int statsOf(Ctx *x, int i, Stats *s) {
  Board *b = ensureBoard(x, i);
  if (!b) return 0;
  s->n = b->sNCombo; s->cleared = b->sCleared; s->broke = b->sBroke; s->earned = b->sEarned;
  for (int j = 0; j < b->sNCombo; j++) { s->size[j] = b->sCombo[j]; s->chainAt[j] = b->sChainAt[j]; s->link[j] = b->sLink[j]; s->touch[j] = b->sTouch[j]; }
  return 1;
}
// The chain a step's clears reach (attacker sent().chain): the highest chain counter of any of them.
static int32_t chainOfStats(const Stats *s) { int32_t c = 0; for (int j = 0; j < s->n; j++) if (s->chainAt[j] > c) c = s->chainAt[j]; return c; }
static int32_t biggestOf(const Stats *s) { int32_t z = 0; for (int j = 0; j < s->n; j++) if (s->size[j] > z) z = s->size[j]; return z; }
#endif
