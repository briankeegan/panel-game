// THE CHAOS ENGINE AS GAMBIT'S pa.c. Gambit (a frozen copy, see ../COPIED_FROM) was built on the vanilla server's engine,
// eval/native/pa.c; here that engine is replaced by the chaos v3 engine, chaos-bot/engine/ca.c -- the one engine, held frame for
// frame to the chaos Lua (engine/checks.sh) -- and this file keeps only pa.c's half that faces the bot: the work budget and the
// wall-clock guard, the wire (HEAD/BODY), the nb_* calls, and the node store (search.h). Every vanilla rule is gone from here.
#include "libc.h"
#include "../../engine/ca.h"
#include "memory.h"
#include "../../engine/ca.c"

// ---- what pa.c's callers name, on the chaos engine
static int rowsTo(const Board *b) { return b->hi < b->nrows ? b->hi : b->nrows; }
static int settled(const int32_t *f) {
  return f[COLOR] == 0 && !f[ISGARBAGE] && f[STATE] == NORMAL && f[STATECHANGED] == 0 && f[PROPCHAIN] == 0 && f[PROPFALL] == 0 &&
         f[MATCHING] == 0 && !SETB(f[CHAINING]) && !f[MATCHANYWAY] && !SETB(f[QUEUEDHOVER]) && !SETN(f[FELL]);
}
static int isToppedOut(Board *b) { return hasPanelsInTopRow(b); }
static void receiveGarbage(Board *b, const Incoming *g) { caReceive(b, g->width, g->height, g->isChain, g->isMetal, g->frameEarned, g->finalized); }
// the incoming queue's order (GarbageQueue.lua orderGarbage) for the queue type of the board being read
static PATLS int paQueueType = 1;
static int orderBefore(const Incoming *a, const Incoming *b) { return orderLess(paQueueType, a, b); }
// pa.c's countdown frames are off on the chaos engine: no frame is ever skipped
static int countdown(Board *b, int32_t maxk) { (void)b; (void)maxk; return 0; }
#define FRAMEWORK_QUIET 1.65
#define FRAMEWORK_COUNT 1.78
#define FRAMEWORK_ACTIVE 4.79
extern PATLS double paWork;
PATLS double paFrQ, paFrC, paFrA, paFrCells;   // engine frames by kind, and the panels in motion in the active ones, for the log's cost line
// Stack:run, past the countdown. b->input is the frame's keys; pressSwap
// adds swap (tryQueueSwap); swapDenied says a swap pressed was not taken.
// WORK: the search's cost in units of ~0.077 us natively, an engine frame by
// what it does, four on average (runPhysics; a resolve on the masks, bit.c, three); the bot's per-decision budget is counted in it.
PATLS double paWork, paEngFrames;
PATLS double paWorkEnd = 1e300;   // paWorkEnd: where the decision's budget runs out -- the deciding thread's own:
// a worker's batch is bounded before it starts, and never by a counter that is not its own
// THE DECISION'S BUDGET IS WORK, natively as in the browser: the same units,
// the same limit, no switch that lifts it -- so a run repeats exactly and a
// run is the game. paBudget(units) opens a share.
static PATLS int paOut;
#ifndef __wasm__
void paThreadId(int id) { thId = id < MAXTHREADS ? id : MAXTHREADS - 1; }   // a worker's own counters and spare boards (memory.h)
#endif
static double paWorkStart;
// THE WALL CLOCK GUARD: the game times a computer player's thinking on a monotonic clock (ThinkBudget.now), and the
// decision is told how much of its frame is left (paWall); every check of the budget also reads that clock, every
// 400 units of work, and a decision whose time is up is out of budget like one whose work is. Natively only: the
// browser's wasm has no clock, and its budget stays the work.
#ifndef __wasm__
extern int clock_gettime(int, void *);
static double paNowMs(void) { struct { long s, ns; } t; clock_gettime(1, &t); return (double)t.s * 1e3 + (double)t.ns / 1e6; }
#else
static double paNowMs(void) { return 0; }
#endif
static PATLS double paWallEnd, paWallNext, paWallFired;
double paClockMs(void) { return paNowMs(); }
void paWall(double msFromNow) { paWallEnd = msFromNow > 0 ? paNowMs() + msFromNow : 0; paWallNext = paWork; paWallFired = 0; }
// the time since the guard ran the decision out of budget, -1 if it did not
double paWallOver(void) { return paWallFired > 0 ? paNowMs() - paWallFired : -1; }
void paBudget(double units) {
  paOut = 0; paWorkStart = paWork;
  paWorkEnd = units < 1e299 ? paWork + units : 1e300;
}
// the share spent, read now, for the end of a stage
int paBudgetSpent(void) {
  if (paOut || paWork >= paWorkEnd) return 1;
  return 0;
}
// PAST THE CUT: the decision's work past `units` from its start (the engine
// refuses work past paBudget's share before then)
int paCutPast(double units) {
  if (paWorkEnd < 1e299 && paWork - paWorkStart > units) return 1;
  return 0;
}
int paBudgetOut(void) {
  if (paOut) return 1;
  if (paWork >= paWorkEnd) return paOut = 1;
  if (paWallEnd > 0 && paWork >= paWallNext) { paWallNext = paWork + 400; if (paNowMs() >= paWallEnd) { paWallFired = paNowMs(); return paOut = 1; } }
  return 0;
}
static void run(Board *b) {
  paEngFrames++;
  if (caGameEnded(b)) return;
  STAT(16)++; paFrA++; paWork += FRAMEWORK_ACTIVE;
  b->sNCombo = b->sNCombo;   // (counted since the step began: search.h resets them)
  caRun(b);
  paFrCells += b->nActive;
}

// What a bot calls: press swap on the next frame with the cursor at (r, c).
static int tryQueueSwap(Board *b, int r, int c) {
  if (b->gameOverClock > 0) return 0;
  if (r != b->curRow || c != b->curCol) return 0;
  b->pressSwap = 1;
  return 1;
}
static int canSwap(Board *b, int row, int col) {
  int32_t cost;
  if (row < 1 || row > b->height || col < 1 || col >= W) return 0;
  return canSwapPanels(b, P(b, row, col), P(b, row, col + 1), &cost);
}


// ------------------------------------------------------------------ the wire
// HEAD (float64) holds the stack's scalars under pa-engine.js's own names --
// "levelData.x", "frames.X" and "behaviours.x" for the constants -- with NaN
// for Lua nil; BODY (int32) every panel's fields for rows 0..nrows-1, then
// incoming (6 each), the stall log (5 each), garbage landed this frame and
// dropColumnIndex[1..6]. native.js reads the names from pa_head_name.
#define HEAD(X) \
  X(nrows, nrows) X(maxHealth, levelData.maxHealth) X(shockFrequency, levelData.shockFrequency) X(shockCap, levelData.shockCap) \
  X(fHOVER, frames.HOVER) X(fGARBAGE_HOVER, frames.GARBAGE_HOVER) X(fFLASH, frames.FLASH) X(fFACE, frames.FACE) X(fPOP, frames.POP) \
  X(fGARBAGE_POP, frames.GARBAGE_POP) X(stopBase, levelData.stop.BaseConstant) \
  X(gameMode, game_mode) X(marginTime, margin_time) X(chaosMode, chaos_mode) X(queueType, incoming.GarbageQueueType) \
  X(incChaos, incoming.ChaosMode) X(incIllegal, incoming.illegalStuffIsAllowed) \
  X(passiveRaise, behaviours.passiveRaise) X(allowManualRaise, behaviours.allowManualRaise) \
  X(swapStallingMode, behaviours.swapStallingMode) X(swapStallingPunish, behaviours.swapStallingPunish) \
  X(startTimersWithSwapCount, behaviours.startTimersWithSwapCount) X(height, height) \
  X(panelIdCount, panelsCreatedCount) X(speed, speed) X(nextSpeedIncreaseClock, nextSpeedIncreaseClock) X(clock, clock) \
  X(stopWatch, game_stopwatch) X(displacement, displacement) X(riseLock, rise_lock) X(hasRisen, has_risen) \
  X(manualRaise, manual_raise) X(manualRaiseYet, manual_raise_yet) X(preventManualRaise, prevent_manual_raise) \
  X(swapThisFrame, swapThisFrame) X(stopTime, stop_time) X(preStopTime, pre_stop_time) X(shakeTime, shake_time) \
  X(prevShakeTime, prev_shake_time) X(shakeTimeOnFrame, shake_time_on_frame) X(peakShakeTime, peak_shake_time) X(health, health) \
  X(topRow, panels_in_top_row) X(chainCounter, chain_counter) X(clearCounter, clear_counter) X(hasAllClear, has_all_clear) \
  X(nActive, n_active_panels) X(nPrevActive, n_prev_active_panels) X(nActiveGarbage, n_active_garbage) \
  X(nPrevActiveGarbage, n_prev_active_garbage) X(landedThis, garbage_landed_this_frame) X(landedLast, garbage_landed_last_frame) \
  X(matchedThis, garbage_matched_this_frame) X(swappingCount, swappingPanelCount) X(panelsCleared, panels_cleared) \
  X(metalPanelsQueued, metalPanelsQueued) X(garbagePanelsCleared, garbage_panels_cleared) X(curRow, cur_row) X(curCol, cur_col) \
  X(topCurRow, top_cur_row) X(queuedSwapRow, queuedSwapRow) X(queuedSwapCol, queuedSwapColumn) X(swapCount, swapCount) \
  X(curTimer, cur_timer) X(curWaitTime, cur_wait_time) X(cursorDirection, cursorDirection) \
  X(garbageCreatedCount, garbageCreatedCount) X(highestGarbageIdMatched, highestGarbageIdMatched) X(gameOverClock, game_over_clock) \
  X(marginCounter, margin_time_counter) X(shakeMargin, shake_margin) X(colorCount, color_count) \
  X(input, nextInput) X(pressSwap, pressSwap) X(swapDenied, swapDeniedThisFrame) \
  X(unseenRows, unseenRows) X(unseenBreaks, unseenBreaks) X(err, err) X(ninc, ninc) X(nstall, nstall) X(nlanded, nlanded)
#define COUNT1(f, n) + 1
#define NHEAD (1 HEAD(COUNT1))
#define NBODY (MAXROWS * W * NF + MAXINC * 6 + MAXSTALL * 5 + MAXLANDED + 6 + 64 * 5)   // and the arrivals after the board (search.h MAXARR)
static double ioHead[NHEAD];
static int32_t ioBody[NBODY];
EXPORT(nb_io_head) double *nb_io_head(void) { return ioHead; }
EXPORT(nb_io_body) int32_t *nb_io_body(void) { return ioBody; }
EXPORT(nb_nhead) int nb_nhead(void) { return NHEAD; }
#define NAME1(f, n) #n,
static const char *headNames[] = { "riseTimer", HEAD(NAME1) };
EXPORT(nb_head_name) const char *nb_head_name(int i) { return i >= 0 && i < NHEAD ? headNames[i] : 0; }
static int32_t fromD(double v) { return v != v ? NUL : (int32_t)v; }
static double toD(int32_t v) { return v == NUL ? __builtin_nan("") : (double)v; }
EXPORT(nb_load) int nb_load(Board *b) {
  int k = 0, i, r, c, f;
  const int32_t *x = ioBody;
  b->nRowFeed = b->rowFeedAt = b->nBrkFeed = b->brkFeedAt = 0;
  b->riseTimer = ioHead[k++];
#define LOAD1(fl, n) b->fl = fromD(ioHead[k++]);
  HEAD(LOAD1)
  int err = 0;
  if (b->nrows < 13 || b->nrows > MAXROWS) err |= ERR_ROWS;
  if (b->ninc < 0 || b->ninc > MAXINC) err |= ERR_INC;
  if (b->nstall < 0 || b->nstall > MAXSTALL) err |= ERR_STALL;
  if (b->nlanded < 0 || b->nlanded > MAXLANDED) err |= ERR_LANDED;
  if (err) return err;
  for (r = 0; r < b->nrows; r++) for (c = 1; c <= W; c++) for (f = 0; f < NF; f++) b->p[r][c].f[f] = *x++;
  for (i = 0; i < b->ninc; i++) {
    Incoming *g = &b->inc[i];
    g->width = *x++; g->height = *x++; g->isChain = *x++; g->isMetal = *x++; g->frameEarned = *x++; g->finalized = *x++;
  }
  for (i = 0; i < b->nstall; i++) {
    Stall *s = &b->stall[i];
    s->leftId = *x++; s->rightId = *x++; s->row = *x++; s->col = *x++; s->clock = *x++;
  }
  for (i = 0; i < b->nlanded; i++) b->landed[i] = *x++;
  b->dropColumnIndex[0] = 0;
  for (i = 1; i <= 6; i++) b->dropColumnIndex[i] = *x++;
  b->quiet = 0; b->noQuiet = 0; b->hi = MAXROWS; b->cdLeft = 0;
  b->colors = b->colorCount; b->stopWatchIsRunning = 1; b->cursorLock = NUL; b->gameOver = b->gameOverClock > 0;
  b->wasToppedOut = b->topRow; paQueueType = b->queueType;
  return b->err;
}
EXPORT(nb_save) int nb_save(Board *b) {
  int k = 0, i, r, c, f;
  int32_t *x = ioBody;
  ioHead[k++] = b->riseTimer;
#define SAVE1(fl, n) ioHead[k++] = toD(b->fl);
  HEAD(SAVE1)
  for (r = 0; r < b->nrows; r++) for (c = 1; c <= W; c++) for (f = 0; f < NF; f++) *x++ = b->p[r][c].f[f];
  for (i = 0; i < b->ninc; i++) {
    Incoming *g = &b->inc[i];
    *x++ = g->width; *x++ = g->height; *x++ = g->isChain; *x++ = g->isMetal; *x++ = g->frameEarned; *x++ = g->finalized;
  }
  for (i = 0; i < b->nstall; i++) { Stall *s = &b->stall[i]; *x++ = s->leftId; *x++ = s->rightId; *x++ = s->row; *x++ = s->col; *x++ = s->clock; }
  for (i = 0; i < b->nlanded; i++) *x++ = b->landed[i];
  for (i = 1; i <= 6; i++) *x++ = b->dropColumnIndex[i];
  return (int)(x - ioBody);
}

// ------------------------------------------------------------------ one call at a time
EXPORT(nb_set_input) void nb_set_input(Board *b, int32_t bits) { b->input = bits; }
EXPORT(nb_run) int nb_run(Board *b) { run(b); return b->err; }
EXPORT(nb_countdown) int nb_countdown(Board *b, int maxk) { return countdown(b, maxk); }
EXPORT(nb_try_queue_swap) int nb_try_queue_swap(Board *b, int r, int c) { return tryQueueSwap(b, r, c); }
EXPORT(nb_can_swap) int nb_can_swap(Board *b, int r, int c) { return canSwap(b, r, c); }
EXPORT(nb_push_incoming) void nb_push_incoming(Board *b, int32_t w, int32_t h, int32_t isChain, int32_t isMetal) {
  Incoming g = { w, h, isChain, isMetal, b->stopWatch, NUL };
  receiveGarbage(b, &g);
}
// A piece as the Lua has it: when it was earned and whether it is final.
EXPORT(nb_receive) void nb_receive(Board *b, int32_t w, int32_t h, int32_t isChain, int32_t isMetal, int32_t frameEarned, int32_t finalized) {
  Incoming g = { w, h, isChain, isMetal, frameEarned, finalized };
  receiveGarbage(b, &g);
}
EXPORT(nb_game_over) int nb_game_over(Board *b) { return b->gameOver; }
EXPORT(nb_no_quiet) void nb_no_quiet(Board *b, int off) { b->noQuiet = off; if (off) b->quiet = 0; }
EXPORT(nb_quiet) int nb_quiet(Board *b) { return b->quiet; }
EXPORT(nb_clock) int nb_clock(Board *b) { return b->clock; }
// What survivor.js predict needs of a board it plays on: swap pressed as the
// frame loop presses it, the garbage queued, the frame it ends and its stopwatch.
EXPORT(nb_press_swap) void nb_press_swap(Board *b) { b->pressSwap = 1; }
EXPORT(nb_ninc) int nb_ninc(Board *b) { return b->ninc; }
EXPORT(nb_over_clock) int nb_over_clock(Board *b) { return b->gameOverClock; }
EXPORT(nb_stopwatch) int nb_stopwatch(Board *b) { return b->stopWatch; }
// The raise as search.h raiseStep reads it: 1 manualRaise, 2 preventManualRaise.
EXPORT(nb_raise_state) int nb_raise_state(Board *b) { return (b->manualRaise ? 1 : 0) | (b->preventManualRaise ? 2 : 0); }
static void cloneBoard(Board *dst, const Board *src) { copyBoard(dst, src); }
EXPORT(nb_clone) void nb_clone(Board *dst, Board *src) { cloneBoard(dst, src); }
// FED ROWS (see Board): the next row dealt, and the next break's colours.
EXPORT(nb_feed_row) int nb_feed_row(Board *b, int32_t c1, int32_t c2, int32_t c3, int32_t c4, int32_t c5, int32_t c6) {
  if (b->nRowFeed >= FEED) return 0;
  int32_t *f = b->rowFeed[(b->rowFeedAt + b->nRowFeed) % FEED];
  f[0] = c1; f[1] = c2; f[2] = c3; f[3] = c4; f[4] = c5; f[5] = c6; b->nRowFeed++;
  return 1;
}
EXPORT(nb_feed_break) int nb_feed_break(Board *b, int32_t c1, int32_t c2, int32_t c3, int32_t c4, int32_t c5, int32_t c6) {
  if (b->nBrkFeed >= FEED) return 0;
  int32_t *f = b->brkFeed[(b->brkFeedAt + b->nBrkFeed) % FEED];
  f[0] = c1; f[1] = c2; f[2] = c3; f[3] = c4; f[4] = c5; f[5] = c6; b->nBrkFeed++;
  return 1;
}
EXPORT(nb_fed) int nb_fed(Board *b) { return b->nRowFeed * 100 + b->nBrkFeed; }
// What the bot's front end asks of the board it plays (front.c).
EXPORT(nb_pressed) int nb_pressed(Board *b) { return b->pressSwap; }   // the swap the front pressed this frame
EXPORT(nb_topped) int nb_topped(Board *b) { return isToppedOut(b); }
EXPORT(nb_falling_garbage) int nb_falling_garbage(Board *b) { return hasFallingGarbage(b); }
EXPORT(nb_active) int nb_active(Board *b) { return hasActivePanels(b); }
// The column the next slab `width` wide drops at (dropGarbage).
EXPORT(nb_spawn_col) int nb_spawn_col(Board *b, int width) {
  if (width < 1 || width > 6) return 0;
  return caSpawnColumn(b, width);
}
// Frames a row takes to rise one pixel at `speed` (the table is in sixteenths).
// THE DRAIN, FROM THE ENGINE: the frames until the board, left alone, first
// loses health (the frame it does), up to `most`. Topped, this is the time the
// lock and the stop leave; it counts every panel still in the air.
static Board *DRB;
EXPORT(nb_drain_in) int nb_drain_in(Board *b, int most) {
  if (!DRB) DRB = nb_new();
  copyBoard(DRB, b);
  DRB->noQuiet = 1; DRB->quiet = 0;
  int32_t h = DRB->health;
  for (int k = 1; k <= most; k++) {
    DRB->input = 0; DRB->pressSwap = 0;
    run(DRB);
    if (DRB->err) return most;
    if (DRB->health < h || DRB->gameOverClock > 0) return k;
  }
  return most;
}
// The shake a slab of `count` cells lands with (dropGarbage).
// the shake a slab of `count` cells lands with, the chaos margin left out (Stack:GetShakeTime clamped as dropGarbage clamps it)
EXPORT(nb_shake_frames) int nb_shake_frames(int count) { int s = 18 + 2 * count; return count <= 0 ? 0 : s > 82 ? 82 : s; }
// frames a row takes to rise one of its sixteen steps at `speed` (the chaos table is in frames a step)
EXPORT(nb_rise_time) double nb_rise_time(int speed) { return (double)SPEED_TO_RISE_TIME[bound(1, speed, 99) - 1]; }

// ---- what the search needs from this engine (search.h)
// ---- what the search needs from this engine (search.h)
#define KEY_COLOR(f) ((f)[ISGARBAGE] ? (SETB((f)[METAL]) ? 254 : 255) : ((f)[COLOR] & 255))
#define SWAP_PRESSED 1
#define SENT_KEYS(st, input) ((input) | ((st)->pressSwap ? IN_SWAP : 0))
#define NODE_BREAKS(b) ((b)->unseenBreaks)
#define STEP_STATS 1
#define COUNTDOWN 1
#define SHARED_WALK 1
#define TOUCH_SCORE 1
#define SETTLE_CAP 900   // frames a settle runs at most, as the bot's resolve (engineboard.js settle)
#include "search.h"
// What node i's step did (MK_SETTLE), into the io body: clears, panels
// cleared, garbage cells converted, the most stop time one clear paid, then
// each clear's size and chain counter. Returns the words written, or -1.
EXPORT(ns_step_stats) int ns_step_stats(Ctx *x, int i) {
  Board *b = ensureBoard(x, i);
  if (!b) return -1;
  int32_t *o = ioBody, k = 0;
  o[k++] = b->sNCombo; o[k++] = b->sCleared; o[k++] = b->sBroke; o[k++] = b->sEarned;
  for (int j = 0; j < b->sNCombo; j++) { o[k++] = b->sCombo[j]; o[k++] = b->sChainAt[j]; }
  return k;
}
// Garbage rows broken on node i's board since the game began (convertGarbagePanels).
EXPORT(ns_breaks) int ns_breaks(Ctx *x, int i) { Board *b = ensureBoard(x, i); return b ? b->unseenBreaks : -1; }

