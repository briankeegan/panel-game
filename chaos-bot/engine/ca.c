// THE CHAOS v3 ENGINE IN C. The panels' half is Gambit's pa.c (GameCreator eval/native/pa.c, copied): the chaos
// build's Panel.lua is the vanilla one. The stack's half is ported from the chaos build's own Lua, function by function,
// in its frame order (Stack:controls then Stack:simulate). Every Lua function ported names itself in a comment.
// check.c plays recordings of that Lua (lua/record.lua) and compares every field after every frame.
//
// No speed-ups yet (pa.c's quiet frames, countdown frames, skipped rows): correctness first, held by the recordings.
#include "ca.h"
#include "levels.h"
// libm through the compiler's builtins (__builtin_ceil, _floor, _pow): the same calls natively, and no system header inside Gambit

static int32_t imax(int32_t a, int32_t b) { return a > b ? a : b; }
static int32_t imin(int32_t a, int32_t b) { return a < b ? a : b; }
static int32_t bound(int32_t a, int32_t b, int32_t c) { return b < a ? a : b > c ? c : b; }
static const int DIR_ROW[4] = { 1, -1, 0, 0 }, DIR_COL[4] = { 0, 0, -1, 1 };

#define P(b, r, c) (&(b)->p[(r)][(c)])
#define TOP(b) ((b)->nrows - 1)   // Lua #panels

// =============================================================== panels (Panel.lua, as pa.c has it)
static void clearFlags(Panel *p, int clearChaining) {
  int32_t *f = p->f;
  f[STATE] = NORMAL;
  f[COMBOINDEX] = NUL; f[COMBOSIZE] = NUL; f[SWAPFROMLEFT] = NUL; f[DONTSWAP] = NUL; f[QUEUEDHOVER] = NUL;
  if (clearChaining) f[CHAINING] = NUL;
  f[FELL] = NUL;
  f[STATECHANGED] = 0; f[PROPCHAIN] = 0; f[MATCHANYWAY] = 0;
}
static void clearPanel(Panel *p, int clearChaining, int clearColor) {
  int32_t *f = p->f;
  if (clearColor) f[COLOR] = 0;
  f[TIMER] = 0;
  f[INITIALTIME] = NUL; f[POPTIME] = NUL; f[POPINDEX] = NUL;
  f[XOFF] = NUL; f[YOFF] = NUL; f[GWIDTH] = NUL; f[GHEIGHT] = NUL;
  f[METAL] = NUL; f[SHAKETIME] = NUL;
  f[ISGARBAGE] = 0;
  clearFlags(p, clearChaining);
}
static void makePanel(Panel *p, int32_t row, int32_t col, int32_t id) {
  int32_t *f = p->f;
  f[ROW] = row; f[COL] = col; f[ID] = id;
  f[COLOR] = 0; f[CHAINING] = NUL; f[MATCHING] = NUL; f[PROPFALL] = NUL; f[GARBAGEID] = NUL;
  clearPanel(p, 1, 1);
}
static Panel *createPanelAt(Board *b, int row, int col) {
  Panel *p = P(b, row, col);
  makePanel(p, row, col, ++b->panelIdCount);
  return p;
}
static Panel *below(Board *b, const Panel *p) { return P(b, p->f[ROW] - 1, p->f[COL]); }
static int supportedFromBelow(Board *b, Panel *p) {
  int32_t *f = p->f;
  if (f[ROW] <= 1) return 1;
  if (f[ISGARBAGE]) {
    int start = f[COL] - f[XOFF], end = f[COL] - f[XOFF] + f[GWIDTH] - 1;
    for (int col = start; col <= end; col++) {
      Panel *q = P(b, f[ROW] - 1, col);
      if (q->f[COLOR] != 0) {
        if (!q->f[ISGARBAGE]) return 1;
        if (f[GARBAGEID] == q->f[GARBAGEID]) return f[YOFF] != q->f[YOFF];
        return 1;
      }
    }
    return 0;
  }
  return P(b, f[ROW] - 1, f[COL])->f[COLOR] != 0;
}
// a and c trade cells; each keeps its identity. Returns where a now is.
static Panel *switchPanels(Board *b, Panel *a, Panel *c) {
  int ar = a->f[ROW], ac = a->f[COL], cr = c->f[ROW], cc = c->f[COL];
  Panel t = *a;
  *a = *c; *c = t;
  P(b, ar, ac)->f[ROW] = ar; P(b, ar, ac)->f[COL] = ac;
  P(b, cr, cc)->f[ROW] = cr; P(b, cr, cc)->f[COL] = cc;
  return P(b, cr, cc);
}

// Stack.onPop
static void onPop(Board *b, Panel *p) {
  if (!p->f[ISGARBAGE]) {
    int32_t cs = p->f[COMBOSIZE];
    b->score += (double)((cs - 2) * (cs - 1)) / 2.0;
    b->panelsCleared++;
    if (b->panelsCleared % b->shockFrequency == 0) b->metalPanelsQueued = imin(b->metalPanelsQueued + 1, b->shockCap);
  }
}
static int32_t shakeFor(Board *b, int32_t width, int32_t height);
// Stack.onLand / Stack.onGarbageLand
static void onLand(Board *b, Panel *p) {
  if (!p->f[ISGARBAGE]) return;
  if (SETN(p->f[SHAKETIME]) && p->f[ROW] <= b->height) {
    int seen = 0;
    for (int i = 0; i < b->nlanded; i++) if (b->landed[i] == p->f[GARBAGEID]) seen = 1;
    if (!seen) {
      b->landedThis = 1;
      b->shakeTimeOnFrame = imax(imax(b->shakeTimeOnFrame, p->f[SHAKETIME]), b->peakShakeTime);
      b->peakShakeTime = imin(b->shakeTimeOnFrame, b->peakShakeTime);
      if (b->nlanded < MAXLANDED) b->landed[b->nlanded++] = p->f[GARBAGEID]; else b->err |= ERR_LANDED;
    }
    // the panel's shake: renewed under the modern and chaos queues (it shakes again if it lands again), spent under classic
    p->f[SHAKETIME] = b->queueType > 1 ? shakeFor(b, p->f[GWIDTH], p->f[GHEIGHT]) : NUL;
  }
}
// HOLLOW (pa.c): the empty cells under a garbage cell as it lands, down to what its column holds
static int hollowUnder(Board *b, const Panel *p) {
  int c = p->f[COL], n = 0;
  for (int r = p->f[ROW] - 1; r >= 1; r--) {
    const Panel *q = P(b, r, c);
    if (q->f[COLOR] != 0) {
      if (q->f[ISGARBAGE] && q->f[GARBAGEID] == p->f[GARBAGEID]) return 0;
      break;
    }
    n++;
  }
  return n;
}
static Panel *fall(Board *b, Panel *p) {
  if (p->f[ISGARBAGE] && p->f[STATE] != FALLING) b->sHollow -= hollowUnder(b, p);
  Panel *q = below(b, p);
  p = switchPanels(b, p, q);
  b->rowActive[p->f[ROW]] = -1;
  Panel *above = P(b, p->f[ROW] + 1, p->f[COL]);
  if (p->f[ISGARBAGE]) { above->f[PROPFALL] = 1; above->f[STATECHANGED] = 1; }
  if (p->f[STATE] != FALLING) {
    if (p->f[ISGARBAGE]) b->sFell++;
    p->f[STATE] = FALLING; p->f[TIMER] = 0; p->f[STATECHANGED] = 1;
  }
  return p;
}
static void land(Board *b, Panel *p) {
  onLand(b, p);
  if (p->f[ISGARBAGE]) { b->sHollow += hollowUnder(b, p); p->f[STATE] = NORMAL; }
  else {
    if (SETN(p->f[FELL])) p->f[FELL] = NUL;
    p->f[STATE] = LANDING;
    p->f[TIMER] = 12;
  }
  p->f[STATECHANGED] = 1;
}
static void decrementTimer(Panel *p) { if (p->f[TIMER] > 0) p->f[TIMER]--; }
static void enterHoverFromNormal(Board *b, Panel *p, Panel *q, int32_t hoverTime) {
  clearFlags(p, 0);
  p->f[STATE] = HOVERING;
  if (q->f[PROPCHAIN]) {
    p->f[PROPCHAIN] = 1;
    p->f[CHAINING] = 1;
    if (q->f[COLOR] == 0 || q->f[MATCHANYWAY]) p->f[MATCHANYWAY] = 1;
    else {
      while (q->f[STATE] == SWAPPING || (q->f[STATECHANGED] && q->f[PROPCHAIN] && !q->f[MATCHANYWAY] && q->f[STATE] == HOVERING)) q = below(b, q);
      if (q->f[PROPCHAIN]) p->f[MATCHANYWAY] = (q->f[COLOR] == 0 || q->f[MATCHANYWAY]) ? 1 : 0;
    }
  }
  p->f[TIMER] = hoverTime;
  p->f[STATECHANGED] = 1;
}
static Panel *updateNormal(Board *b, Panel *p) {
  if (p->f[ISGARBAGE]) { if (!supportedFromBelow(b, p)) p = fall(b, p); return p; }
  if (p->f[COLOR] == 0) return p;
  Panel *q = below(b, p);
  if (!q->f[STATECHANGED]) return p;
  if (q->f[STATE] == HOVERING) enterHoverFromNormal(b, p, q, q->f[TIMER]);
  else if (q->f[COLOR] == 0) {
    if (SETB(q->f[PROPFALL])) p = fall(b, p);
    else if (q->f[STATE] == NORMAL) enterHoverFromNormal(b, p, q, b->fHOVER);
  } else if (q->f[QUEUEDHOVER] == 1 && q->f[PROPCHAIN] && q->f[STATE] == SWAPPING) {
    int32_t hoverTime = q->f[TIMER];
    Panel *hp = below(b, q);
    while (hp->f[STATE] == SWAPPING) { hoverTime += hp->f[TIMER]; hp = below(b, hp); }
    hoverTime += hp->f[STATE] == HOVERING ? hp->f[TIMER] : b->fHOVER;
    enterHoverFromNormal(b, p, q, hoverTime);
  }
  return p;
}
static void finishSwap(Panel *p) { p->f[STATE] = NORMAL; p->f[DONTSWAP] = NUL; p->f[SWAPFROMLEFT] = NUL; p->f[STATECHANGED] = 1; }
static void updateSwapping(Board *b, Panel *p) {
  decrementTimer(p);
  Panel *q = below(b, p);
  if (p->f[TIMER] == 0) {
    if (p->f[COLOR] == 0) finishSwap(p);
    else if (q->f[COLOR] == 0 || q->f[STATE] == HOVERING || SETB(p->f[QUEUEDHOVER])) {
      clearFlags(p, 0);
      p->f[STATE] = HOVERING;
      p->f[PROPCHAIN] = q->f[PROPCHAIN];
      p->f[MATCHANYWAY] = (q->f[COLOR] != 0 && q->f[STATE] == HOVERING) ? q->f[MATCHANYWAY] : 0;
      p->f[TIMER] = b->fHOVER;
      p->f[STATECHANGED] = 1;
    } else finishSwap(p);
  } else if (q->f[STATECHANGED] && q->f[PROPCHAIN]) {
    p->f[QUEUEDHOVER] = p->f[COLOR] != 0;
    p->f[STATECHANGED] = 1;
    p->f[PROPCHAIN] = 1;
  }
}
static void updateMatched(Board *b, Panel *p) {
  if (p->f[ISGARBAGE]) b->popSeen = 1;
  decrementTimer(p);
  if (p->f[ISGARBAGE] && p->f[TIMER] == p->f[POPTIME]) onPop(b, p);
  if (p->f[TIMER] != 0) return;
  if (p->f[ISGARBAGE]) {
    if (p->f[YOFF] == -1) {
      clearPanel(p, 0, 0);
      p->f[CHAINING] = 1; p->f[PROPCHAIN] = 1; p->f[TIMER] = b->fGARBAGE_HOVER; p->f[FELL] = 12;
      p->f[STATE] = HOVERING; p->f[STATECHANGED] = 1;
    } else p->f[STATE] = NORMAL;
  } else {
    p->f[STATE] = POPPING;
    p->f[TIMER] = p->f[COMBOINDEX] * b->fPOP;
    p->f[STATECHANGED] = 1;
  }
}
static void popped(Board *b, Panel *p) {
  (void)b;
  clearPanel(p, 1, 1);
  p->f[PROPCHAIN] = 1;
  p->f[STATECHANGED] = 1;
}
static void updatePopping(Board *b, Panel *p) {
  decrementTimer(p);
  if (p->f[TIMER] != 0) return;
  onPop(b, p);
  if (p->f[COMBOSIZE] == p->f[COMBOINDEX]) popped(b, p);
  else { p->f[STATE] = POPPED; p->f[TIMER] = (p->f[COMBOSIZE] - p->f[COMBOINDEX]) * b->fPOP; p->f[STATECHANGED] = 1; }
}
static void updatePopped(Board *b, Panel *p) { decrementTimer(p); if (p->f[TIMER] == 0) popped(b, p); }
static void updateHovering(Board *b, Panel *p) {
  decrementTimer(p);
  if (p->f[MATCHANYWAY]) p->f[MATCHANYWAY] = 0;
  if (p->f[TIMER] == 0) {
    Panel *q = below(b, p);
    if (p->f[ROW] < 1) { b->err |= ERR_STATE; return; }
    if (q->f[STATE] == HOVERING) p->f[TIMER] = q->f[TIMER];
    else if (q->f[COLOR] != 0) land(b, p);
    else p = fall(b, p);
  }
  if (!p->f[STATECHANGED] && SETN(p->f[FELL])) p->f[FELL]--;
}
static void updateFalling(Board *b, Panel *p) {
  if (p->f[ROW] == 1) land(b, p);
  else if (supportedFromBelow(b, p)) {
    if (p->f[ISGARBAGE]) land(b, p);
    else {
      Panel *q = below(b, p);
      if (q->f[STATE] == HOVERING) {
        clearFlags(p, 0);
        p->f[STATE] = HOVERING; p->f[STATECHANGED] = 1; p->f[PROPCHAIN] = q->f[PROPCHAIN]; p->f[TIMER] = q->f[TIMER];
      } else land(b, p);
    }
  } else p = fall(b, p);
  if (!p->f[STATECHANGED] && SETN(p->f[FELL])) p->f[FELL]--;
}
static void updateLanding(Board *b, Panel *p) {
  p = updateNormal(b, p);
  if (!p->f[STATECHANGED]) {
    decrementTimer(p);
    if (p->f[TIMER] == 0) { p->f[STATE] = NORMAL; p->f[STATECHANGED] = 1; }
  }
}
static void updatePanel(Board *b, Panel *p) {
  int32_t *f = p->f;
  f[STATECHANGED] = 0; f[PROPCHAIN] = 0; f[PROPFALL] = 0; f[MATCHING] = 0;
  switch (f[STATE]) {
    case NORMAL: updateNormal(b, p); break;
    case SWAPPING: updateSwapping(b, p); break;
    case MATCHED: updateMatched(b, p); break;
    case POPPING: updatePopping(b, p); break;
    case POPPED: updatePopped(b, p); break;
    case HOVERING: updateHovering(b, p); break;
    case FALLING: updateFalling(b, p); break;
    case LANDING: updateLanding(b, p); break;
    case DIMMED: if (f[ROW] >= 1) { f[STATE] = NORMAL; f[STATECHANGED] = 1; } break;
    default: break;
  }
}
static int allowsSwap(const Panel *p) {
  if (SETB(p->f[DONTSWAP])) return 0;
  if (p->f[ISGARBAGE]) return 0;
  int32_t st = p->f[STATE];
  return st == NORMAL || st == SWAPPING || st == FALLING || st == LANDING;
}
static void startSwap(Panel *p, int fromLeft) {
  int32_t chaining = p->f[CHAINING];
  clearFlags(p, 0);
  p->f[STATECHANGED] = 1; p->f[STATE] = SWAPPING; p->f[CHAINING] = chaining; p->f[TIMER] = 4; p->f[SWAPFROMLEFT] = fromLeft;
  if (SETN(p->f[FELL])) p->f[FELL] = NUL;
}
static int dangerous(const Panel *p) { return p->f[ISGARBAGE] ? p->f[STATE] != FALLING : p->f[COLOR] != 0; }
static int canMatch(const Panel *p) {
  int32_t col = p->f[COLOR], st = p->f[STATE];
  if (col == 0 || col == 9) return 0;
  return st == NORMAL || st == LANDING || (p->f[MATCHANYWAY] && st == HOVERING);
}

// =============================================================== the stack's questions
#define DT_SPEED_INCREASE (15 * 60)
static int hasActivePanels(Board *b) { return b->nActive > 0 || b->nPrevActive > 0; }
static int swapQueued(Board *b) { return b->queuedSwapCol != 0 && b->queuedSwapRow != 0; }
// Stack.has_falling_garbage (rows 1..height)
static int hasFallingGarbage(Board *b) {
  for (int r = 1; r <= b->height && r < b->nrows; r++)
    for (int c = 1; c <= W; c++) { Panel *p = P(b, r, c); if (p->f[ISGARBAGE] && p->f[STATE] == FALLING) return 1; }
  return 0;
}
// Stack.hasPanelsInTopRow
static int hasPanelsInTopRow(Board *b) {
  for (int c = 1; c <= W; c++) if (dangerous(P(b, b->height, c))) return 1;
  return 0;
}
// Stack.hasChainingPanels (rows 1..#panels)
static int hasChainingPanels(Board *b) {
  for (int r = 1; r < b->nrows; r++)
    for (int c = 1; c <= W; c++) { Panel *p = P(b, r, c); if (SETB(p->f[CHAINING]) && p->f[COLOR] != 0) return 1; }
  return 0;
}
// Stack.hasMatchingPanels (rows 1..height: a coloured panel matched or popping)
static int hasMatchingPanels(Board *b) {
  for (int r = 1; r <= b->height; r++)
    for (int c = 1; c <= W; c++) { Panel *p = P(b, r, c); if (p->f[COLOR] != 0 && (p->f[STATE] == MATCHED || p->f[STATE] == POPPING)) return 1; }
  return 0;
}
// Stack.hasZeroPanels (rows 1..height empty)
static int hasZeroPanels(Board *b) {
  for (int r = 1; r <= b->height; r++)
    for (int c = 1; c <= W; c++) if (P(b, r, c)->f[COLOR] != 0) return 0;
  return 1;
}
// Stack.updateActivePanelCount / getActivePanelCount
static void updateActivePanelCount(Board *b) {
  b->nPrevActive = b->nActive;
  int32_t count = 0, swapping = 0;
  for (int r = 1; r <= b->height; r++)
    for (int c = 1; c <= W; c++) {
      Panel *p = P(b, r, c);
      if (p->f[ISGARBAGE]) { if (p->f[STATE] != NORMAL) count++; }
      else if (p->f[COLOR] != 0 && p->f[STATE] != NORMAL && p->f[STATE] != LANDING) { count++; if (p->f[STATE] == SWAPPING) swapping++; }
    }
  b->nActive = count; b->swappingCount = swapping;
}
// Stack.updateActiveGarbageCount / getActiveGarbageCount
static void updateActiveGarbageCount(Board *b) {
  b->nPrevActiveGarbage = b->nActiveGarbage;
  int32_t count = 0;
  for (int r = 1; r <= b->height; r++)
    for (int c = 1; c <= W; c++) { Panel *p = P(b, r, c); if (p->f[ISGARBAGE] && p->f[STATE] != NORMAL) count++; }
  b->nActiveGarbage = count;
}
// Stack.updateRiseLock (past the countdown)
static void updateRiseLock(Board *b) {
  int prev = b->riseLock;
  b->riseLock = (swapQueued(b) || b->shakeTime > 0 || hasActivePanels(b)) ? 1 : 0;
  if (prev && !b->riseLock) b->preventManualRaise = 0;
}

// Stack:GetShakeMargin / GetMarginTime / GetShakeTime and dropGarbage's clamp
static double shakeMarginFactor(Board *b) {
  if (b->marginTime == MARGIN_CHAOS) return (double)(b->shakeMargin - b->ninc) / (double)b->shakeMargin;
  return 1.0;
}
static double luaMin(double a, double b);
static double luaMax(double a, double b);
static int32_t shakeFor(Board *b, int32_t width, int32_t height) {
  // math.max(18, math.min(82, math.ceil(shake * margin))): the margin is never NaN (shake_margin >= 1)
  return (int32_t)luaMax(18, luaMin(82, __builtin_ceil((double)(18 + width * height * 2) * shakeMarginFactor(b))));
}
static int garbageMarginBase(Board *b) { return b->incChaos ? 30 : 50; }   // GarbageQueue:GarbageMarginBase
static double marginTimeFactor(Board *b) {
  if (b->marginTime == MARGIN_MODOKI) {
    return luaMax(0, (double)(20 - b->marginCounter) / 20.0);
  }
  if (b->marginTime == MARGIN_CHAOS) {
    double gm = __builtin_ceil(garbageMarginBase(b) * ((double)(20 - b->marginCounter) / 20.0));
    return (gm - (double)b->ninc) / gm;
  }
  return 1.0;
}
// LuaJIT's math.min / math.max of two: the first only when it is strictly smaller / larger, so a NaN second wins
// (luajit -e 'print(math.min(300, 0/0), math.min(0/0, 300))' prints nan 300)
static double luaMin(double a, double b) { return a < b ? a : b; }
static double luaMax(double a, double b) { return a > b ? a : b; }

// =============================================================== the incoming queue (GarbageQueue.lua)
// orderGarbage's comparators: true when a has lower priority than b (sorted to a lower index)
static int orderLess(int queueType, const Incoming *a, const Incoming *b) {
  if (queueType == 1) {
    if (a->isChain == b->isChain) {
      if (a->isChain) {
        int af = SETB(a->finalized), bf = SETB(b->finalized);
        if (af == bf) return a->frameEarned > b->frameEarned;
        return !af;
      }
      if (a->width != b->width) return a->width > b->width;
      return a->frameEarned < b->frameEarned;
    }
    return !a->isChain;
  }
  if (queueType == 2) return a->frameEarned > b->frameEarned;
  if (queueType == 3) return a->frameEarned < b->frameEarned;
  return 0;
}
// LuaJIT's table.sort (lib_table.c auxsort, Lua 5.1's): the order of ties is the algorithm's, so it is the algorithm.
static void sortSwap(Incoming *x, int i, int j) { Incoming t = x[i]; x[i] = x[j]; x[j] = t; }
static void auxsort(Board *bd, Incoming *x, int l, int u) {   // 1-based l..u over x[1..n]
  int qt = bd->queueType;
  while (l < u) {
    int i, j;
    if (orderLess(qt, &x[u], &x[l])) sortSwap(x, l, u);
    if (u - l == 1) break;
    i = (l + u) / 2;
    if (orderLess(qt, &x[i], &x[l])) sortSwap(x, i, l);
    else if (orderLess(qt, &x[u], &x[i])) sortSwap(x, i, u);
    if (u - l == 2) break;
    Incoming pv = x[i];
    sortSwap(x, i, u - 1);
    i = l; j = u - 1;
    for (;;) {
      while (orderLess(qt, &x[++i], &pv)) { if (i >= u) { bd->err |= ERR_INC; return; } }
      while (orderLess(qt, &pv, &x[--j])) { if (j <= l) { bd->err |= ERR_INC; return; } }
      if (j < i) break;
      sortSwap(x, i, j);
    }
    sortSwap(x, u - 1, i);
    if (i - l < u - i) { j = l; i = i - 1; l = i + 2; }
    else { j = i + 1; i = u; u = j - 2; }
    auxsort(bd, x, j, i);
  }
}
// GarbageQueue:push (correctChainingFlag, then the whole queue sorted again)
void caReceive(Board *b, int32_t w, int32_t h, int32_t isChain, int32_t isMetal, int32_t frameEarned, int32_t finalized) {
  if (b->ninc >= MAXINC) { b->err |= ERR_INC; return; }
  Incoming g = { w, h, isChain, isMetal, frameEarned, finalized };
  if (!g.isChain && g.height > 1 && b->incIllegal) { g.isChain = 0; g.finalized = 1; }
  b->inc[b->ninc++] = g;
  auxsort(b, b->inc - 1, 1, b->ninc);
}

// =============================================================== rows and garbage
#define UNSEEN_COLOUR(base, k, c) ((base) + ((W * (k) + (c) - 1) % 90))
// Stack:new_row with GeneratorSource:createNewRow (shock taken from the queue the same way)
static void newRow(Board *b) {
  if (b->curRow != 0) b->curRow = bound(1, b->curRow + 1, b->topCurRow);
  if (b->queuedSwapRow > 0) b->queuedSwapRow++;
  int top = TOP(b) + 1, r, c;
  if (top >= MAXROWS) { b->err |= ERR_ROWS; return; }
  int metal = 0;
  if (b->metalPanelsQueued > 3) { b->metalPanelsQueued -= 2; metal = 2; }
  else if (b->metalPanelsQueued > 0) { b->metalPanelsQueued -= 1; metal = 1; }
  if (b->nRowFeed > 0) {
    // a fed row: plain colours as dealt (8 is shock), or 100+/200+ colour for a cell that is shock with one/two queued
    int32_t *f = b->rowFeed[b->rowFeedAt];
    b->rowFeedAt = (b->rowFeedAt + 1) % FEED; b->nRowFeed--;
    for (c = 1; c <= W; c++) {
      int32_t v = f[c - 1], colour = v < 100 ? v : v < 200 ? (metal > 0 ? 8 : v - 100) : (metal > 1 ? 8 : v - 200);
      Panel *p = createPanelAt(b, top, c); p->f[COLOR] = colour; p->f[STATE] = DIMMED;
    }
  } else {
    int32_t k = ++b->unseenRows;
    for (c = 1; c <= W; c++) { Panel *p = createPanelAt(b, top, c); p->f[COLOR] = UNSEEN_COLOUR(30, k, c); p->f[STATE] = DIMMED; }
  }
  b->nrows = top + 1;
  for (r = top; r >= 1; r--)
    for (c = W; c >= 1; c--) switchPanels(b, P(b, r, c), P(b, r - 1, c));
  for (c = 1; c <= W; c++) { P(b, 1, c)->f[STATE] = NORMAL; P(b, 1, c)->f[STATECHANGED] = 1; }
  b->displacement = 16;
}
// Stack.remove_extra_rows
static void removeExtraRows(Board *b) {
  for (int r = TOP(b); r >= b->height + 1; r--) {
    for (int c = 1; c <= W; c++) if (P(b, r, c)->f[COLOR] != 0) return;
    b->nrows = r;
  }
}
// Stack.getGarbageSpawnColumn: chaos mode's map lets a piece w wide fall in any column 1..7-w, in turn
static int32_t spawnColumn(Board *b, int32_t width) {
  static const int MAP[7][6] = { { 0 }, { 1, 2, 3, 4, 5, 6 }, { 1, 3, 5 }, { 1, 4 }, { 1, 2, 3 }, { 1, 2 }, { 1 } };
  static const int LEN[7] = { 0, 6, 3, 2, 3, 2, 1 };
  int32_t index = b->dropColumnIndex[width], len = b->chaosMode ? 7 - width : LEN[width];
  int32_t col = b->chaosMode ? index : MAP[width][index - 1];   // (caSpawnColumn reads the same without turning it)
  b->dropColumnIndex[width] = index + 1 > len ? 1 : index + 1;   // wrap(1, index + 1, #columns)
  return col;
}
// Stack.dropGarbage
static void dropGarbage(Board *b, int32_t width, int32_t height, int32_t isMetal) {
  int32_t originRow = b->height + 1;
  if (width < 1 || width > 6) { b->err |= ERR_WIDTH; return; }
  int32_t originCol = spawnColumn(b, width);
  b->garbageCreatedCount++;
  int32_t shake = shakeFor(b, width, height);
  for (int r = originRow; r <= originRow + height - 1; r++) {
    if (r < b->nrows) continue;
    if (r != b->nrows || r >= MAXROWS) { b->err |= ERR_ROWS; return; }
    b->nrows = r + 1;
    for (int c = 1; c <= W; c++) {
      Panel *p = createPanelAt(b, r, c);
      if (c >= originCol && c < originCol + width) {
        int32_t *f = p->f;
        f[GARBAGEID] = b->garbageCreatedCount; f[ISGARBAGE] = 1; f[COLOR] = 9; f[GWIDTH] = width; f[GHEIGHT] = height;
        f[YOFF] = r - originRow; f[XOFF] = c - originCol; f[SHAKETIME] = shake; f[STATE] = FALLING;
        if (isMetal) f[METAL] = 1;
      }
    }
  }
}
// Stack:shouldDropGarbage
static int shouldDropGarbage(Board *b) {
  if (!b->ninc) return 0;
  Incoming *g = &b->inc[b->ninc - 1];
  if (b->topRow) return 0;
  if (b->queueType == 1) {
    if (g->isChain && g->height > 1) return 1;
    return !hasActivePanels(b);
  }
  if (b->queueType == 2) {
    if (b->landedLast && !b->matchedThis) return 1;
    return !hasChainingPanels(b) && !hasMatchingPanels(b);
  }
  if (b->queueType == 3) {
    if (g->isChain && g->height > 1) return 1;
    if (b->marginCounter >= 20 && !hasChainingPanels(b) && !hasMatchingPanels(b)) return 1;
    return !hasActivePanels(b);
  }
  return 0;
}
// Stack:tryDropGarbage
static void tryDropGarbage(Board *b) {
  for (int r = b->height + 1; r <= TOP(b); r++)
    for (int c = 1; c <= W; c++) if (P(b, r, c)->f[COLOR] != 0) return;
  Incoming g = b->inc[--b->ninc];
  if (b->queueType >= 1 && b->queueType <= 3) b->ev[EV_DROPQ1 + b->queueType - 1]++;
  dropGarbage(b, g.width, g.height, g.isMetal);
}

// =============================================================== what is sent (Stack:pushGarbage)
static void sendPiece(Board *b, int32_t w, int32_t h, int32_t metal, int32_t allClear) {
  if (b->nsent >= MAXSENT) { b->err |= ERR_SENT; return; }
  CaSent s = { (signed char)w, (signed char)h, (signed char)metal, (signed char)allClear, b->clock };
  b->sent[b->nsent++] = s;
  if (metal && !allClear) b->ev[EV_SHOCKSENT]++;
  if (h > 1) b->ev[EV_TALLSENT]++;
}
void caSentReset(Board *b) { b->nsent = 0; b->outLinks = 0; b->outChains = 0; b->outChainRows = 0; }
static void pushGarbage(Board *b, int isChain, int32_t comboSize, int32_t metalCount) {
  for (int i = 3; i <= metalCount; i++) sendPiece(b, 6, 1, 1, 0);
  if (b->hasAllClear && (comboSize || isChain)) {   // (comboSize is a number: always true)
    for (int i = 1; i <= 5; i++) sendPiece(b, imin(6, 2 + i), 1, i == 5, 1);
    b->ev[EV_ALLCLEARSENT]++;
    b->hasAllClear = 0;
  }
  int pieces = comboSize >= 4 ? 1 : 0;   // ChaosPieces
  int32_t width = (comboSize - 1) % 3 + 3, tall = (comboSize - 3 + 2) / 3;   // math.ceil((comboSize - 3) / 3) for comboSize >= 3
  if (((b->chainCounter < 3 || !isChain) || b->chainCounter == 0) && b->chaosMode) {
    for (int i = 0; i < pieces; i++) sendPiece(b, width, tall, 0, 0);
  } else {
    for (int i = 0; i < pieces * tall; i++) sendPiece(b, width, 1, 0, 0);
  }
  if (isChain) {   // GarbageQueue:addChainLink
    b->outChain = b->outChain == 0 ? 1 : imin(12, b->outChain + 1);
    b->outLinks++;
  }
}

// =============================================================== matches (checkMatches.lua)
typedef struct { int32_t n; int32_t at[MAXMATCH]; } Cells;
#define CR(x) ((x) >> 3)
#define CC(x) ((x) & 7)
static void cellsPush(Board *b, Cells *l, int r, int c) { if (l->n < MAXMATCH) l->at[l->n++] = r * 8 + c; else b->err |= ERR_MATCH; }
// Stack:getMatchingPanels
static void getMatchingPanels(Board *b, Cells *out) {
  int32_t cand[W * MAXROWS], nc = 0, vert[MAXROWS], horiz[8], nv, nh, r, c, i, j;
  out->n = 0;
  for (r = 1, nv = imin(b->height, TOP(b)); r <= nv; r++)
    for (c = 1; c <= W; c++) { Panel *p = P(b, r, c); if (p->f[STATECHANGED] && canMatch(p)) cand[nc++] = r * 8 + c; }
  for (i = 0; i < nc; i++) {
    int cr = CR(cand[i]), cc = CC(cand[i]);
    Panel *cp = P(b, cr, cc);
    int32_t colour = cp->f[COLOR];
    nv = 0; nh = 0;
    for (r = cr - 1; r >= 1; r--) { Panel *p = P(b, r, cc); if (p->f[COLOR] == colour && canMatch(p)) vert[nv++] = r * 8 + cc; else break; }
    for (r = cr + 1; r <= b->height; r++) { Panel *p = P(b, r, cc); if (p->f[COLOR] == colour && canMatch(p)) vert[nv++] = r * 8 + cc; else break; }
    for (c = cc - 1; c >= 1; c--) { Panel *p = P(b, cr, c); if (p->f[COLOR] == colour && canMatch(p)) horiz[nh++] = cr * 8 + c; else break; }
    for (c = cc + 1; c <= W; c++) { Panel *p = P(b, cr, c); if (p->f[COLOR] == colour && canMatch(p)) horiz[nh++] = cr * 8 + c; else break; }
    if ((nv >= 2 || nh >= 2) && !SETB(cp->f[MATCHING])) { cellsPush(b, out, cr, cc); cp->f[MATCHING] = 1; }
    if (nv >= 2) for (j = 0; j < nv; j++) { Panel *p = P(b, CR(vert[j]), CC(vert[j])); if (!SETB(p->f[MATCHING])) { p->f[MATCHING] = 1; cellsPush(b, out, CR(vert[j]), CC(vert[j])); } }
    if (nh >= 2) for (j = 0; j < nh; j++) { Panel *p = P(b, CR(horiz[j]), CC(horiz[j])); if (!SETB(p->f[MATCHING])) { p->f[MATCHING] = 1; cellsPush(b, out, CR(horiz[j]), CC(horiz[j])); } }
  }
  for (i = 0; i < out->n; i++) { Panel *p = P(b, CR(out->at[i]), CC(out->at[i])); if (p->f[STATE] == HOVERING) p->f[CHAINING] = NUL; }
}
static int popBefore(int32_t a, int32_t b, int garbage) {
  int ar = CR(a), ac = CC(a), br = CR(b), bc = CC(b);
  if (ar == br) return garbage ? ac > bc : ac < bc;
  return garbage ? ar < br : ar > br;
}
static void sortByPopOrder(Cells *l, int garbage) {
  for (int i = 1; i < l->n; i++) {
    int32_t x = l->at[i]; int j = i - 1;
    while (j >= 0 && popBefore(x, l->at[j], garbage)) { l->at[j + 1] = l->at[j]; j--; }
    l->at[j + 1] = x;
  }
}
typedef struct { int32_t left, right, top, bottom, metal; } Box;
static int matchOnContact(const Box *a, const Box *b) {
  if (a->metal != b->metal) return 0;
  if (a->top == b->bottom - 1 || a->bottom == b->top + 1)
    return (a->left <= b->right && b->left <= a->left) || (b->left <= a->right && a->left <= b->left);
  if (a->right == b->left - 1 || a->left == b->right + 1)
    return (b->top >= a->bottom && b->top <= a->top) || (a->top >= b->bottom && a->top <= b->top);
  return 0;
}
// Stack:getConnectedGarbagePanels2. Returns 0 when no garbage is hit.
static int getConnectedGarbagePanels(Board *b, Cells *matching, Cells *out) {
  int32_t ids[MAXIDS], nid = 0, matched[MAXIDS], i, j, r, c;
  Box box[MAXIDS];
  out->n = 0;
  for (r = 1; r <= TOP(b); r++)
    for (c = 1; c <= W; c++) {
      Panel *p = P(b, r, c);
      int32_t *f = p->f;
      if (!(f[ISGARBAGE] && f[STATE] == NORMAL)) continue;
      int seen = 0;
      for (i = 0; i < nid; i++) if (ids[i] == f[GARBAGEID]) { seen = 1; break; }
      if (seen) continue;
      if (!((f[ROW] - f[YOFF]) <= b->height || f[GARBAGEID] <= b->highestGarbageIdMatched)) continue;
      if (nid >= MAXIDS) { b->err |= ERR_MATCH; return 0; }
      ids[nid] = f[GARBAGEID];
      box[nid].left = f[COL] - f[XOFF]; box[nid].right = f[COL] - f[XOFF] + f[GWIDTH] - 1;
      box[nid].top = f[ROW] - f[YOFF] + f[GHEIGHT] - 1; box[nid].bottom = f[ROW] - f[YOFF];
      box[nid].metal = SETB(f[METAL]);
      matched[nid] = 0;
      nid++;
    }
  if (!nid) return 0;
  int any = 0;
  for (i = 0; i < nid; i++) {
    Box *g = &box[i];
    for (j = 0; j < matching->n; j++) {
      int mr = CR(matching->at[j]), mc = CC(matching->at[j]);
      if (mr == g->bottom - 1 || mr == g->top + 1) { if (mc >= g->left && mc <= g->right) { matched[i] = 1; any = 1; } }
      else if (mc == g->left - 1 || mc == g->right + 1) { if (mr >= g->bottom && mr <= g->top) { matched[i] = 1; any = 1; } }
    }
  }
  if (!any) return 0;
  int changed = 1;
  while (changed) {
    changed = 0;
    for (i = 0; i < nid; i++) {
      if (!matched[i]) continue;
      for (j = 0; j < nid; j++) if (!matched[j] && i != j && matchOnContact(&box[i], &box[j])) { matched[j] = 1; changed = 1; }
    }
  }
  int32_t hi = 0;
  for (i = 0; i < nid; i++) {
    if (!matched[i]) continue;
    if (ids[i] > hi) hi = ids[i];
    for (r = box[i].bottom; r <= box[i].top; r++) for (c = box[i].left; c <= box[i].right; c++) cellsPush(b, out, r, c);
  }
  if (hi > b->highestGarbageIdMatched) b->highestGarbageIdMatched = hi;
  return 1;
}
// Stack:convertGarbagePanels
static void convertGarbagePanels(Board *b, int isChain) {
  int32_t cleared = 0;
  for (int r = 1; r <= TOP(b); r++) {
    int32_t k = 0, *fed = 0;
    for (int c = 1; c <= W; c++) {
      Panel *p = P(b, r, c);
      if (p->f[YOFF] == -1 && p->f[COLOR] == 9) {
        if (!k) {
          k = ++b->unseenBreaks;
          if (b->nBrkFeed > 0) { fed = b->brkFeed[b->brkFeedAt]; b->brkFeedAt = (b->brkFeedAt + 1) % FEED; b->nBrkFeed--; }
          else fed = 0;
        }
        p->f[COLOR] = fed ? fed[c - 1] : UNSEEN_COLOUR(130, k, c);
        cleared++;
        if (isChain) p->f[CHAINING] = 1;
      }
    }
  }
  b->garbagePanelsCleared = cleared;
}
// Stack:matchGarbagePanels
static void matchGarbagePanels(Board *b, Cells *g, int32_t matchTime, int isChain, int32_t onScreen) {
  sortByPopOrder(g, 1);
  b->ev[EV_GARBAGEBROKEN]++;
  for (int i = 0; i < g->n; i++) {
    Panel *p = P(b, CR(g->at[i]), CC(g->at[i]));
    p->f[YOFF] -= 1; p->f[GHEIGHT] -= 1; p->f[STATE] = MATCHED;
    p->f[TIMER] = matchTime + 1; p->f[INITIALTIME] = matchTime;
    p->f[POPTIME] = b->fGARBAGE_POP * (onScreen - (i + 1)); p->f[POPINDEX] = imin(i + 1, 72);
    if (p->f[YOFF] == -1) b->sBroke++;
  }
  convertGarbagePanels(b, isChain);
}
// Stack:calculateStopTime
// (a double: at the chaos margin's last step, garbage_margin is 0 and the stop time NaN or -inf, as in the Lua)
static double calculateStopTime(Board *b, int32_t comboSize, int toppedOut, int isChain, int32_t chainCounter, int32_t metalCount) {
  double t = 0;
  int32_t chainSize = chainCounter - 2;   // chain_counter is never nil here
  int state = toppedOut && isChain ? 3 : toppedOut ? 2 : isChain ? 1 : 0;
  if (comboSize == 3 && metalCount == 3) t = 20 * metalCount;
  else if (comboSize > 3 || isChain) {
    double v = __builtin_ceil(b->stopBase * __builtin_pow(1.05, comboSize - 4 > 0 ? comboSize - 4 : 0) * __builtin_pow(1.1, chainSize) * __builtin_pow(1.25, state) * marginTimeFactor(b)) + 20 * metalCount;
    t = luaMax(0, luaMin(300, v));
  }
  return t;
}
// Stack:awardStopTime
static void awardStopTime(Board *b, int isChain, int32_t comboSize, int32_t metalCount) {
  double t = calculateStopTime(b, comboSize, b->topRow, isChain, b->chainCounter, metalCount);
  double m = marginTimeFactor(b);
  if (t > 0 && m < 1) b->ev[EV_STOPFADED]++;
  if (b->gameMode >= 3) b->stopTime = 0;
  else if (t > b->stopTime) b->stopTime = (int32_t)t;   // NaN is never greater: the stop time stays
  if (t > b->sEarned) b->sEarned = (int32_t)t;
}
// Stack:updateScoreWithBonus (combo, then chain)
static double scoreModeModifier(Board *b) { return __builtin_pow(2, 4 - imax(1, b->gameMode - 1)); }
static void updateScoreWithBonus(Board *b, int32_t comboSize, int isChainLink) {
  int32_t chainBonus = b->chainCounter;   // updateScoreWithChain
  if (chainBonus != 0 && isChainLink) b->score += ((((double)(chainBonus - 1) * chainBonus) / scoreModeModifier(b)) * 100);
  double cb = imax(1, b->chainCounter - 1);   // updateScoreWithCombo
  if (comboSize > 3) b->score += ((((double)(comboSize - 3) * (comboSize - 2)) / scoreModeModifier(b)) * 100) * cb;
}
// Stack:clearChainingFlags
static void clearChainingFlags(Board *b) {
  int top = imin(TOP(b), b->height + 2);
  for (int r = 1; r <= top; r++)
    for (int c = 1; c <= W; c++) {
      Panel *p = P(b, r, c);
      if (SETB(p->f[CHAINING]) && !SETB(p->f[MATCHING]) && !p->f[MATCHANYWAY] && (canMatch(p) || p->f[COLOR] == 9)) {
        if (r > 1) { if (P(b, r - 1, c)->f[STATE] != SWAPPING) p->f[CHAINING] = NUL; }
        else p->f[CHAINING] = NUL;
      }
    }
}
// Stack:checkMatches
static void checkMatches(Board *b) {
  Cells matching, garbage;
  getMatchingPanels(b, &matching);
  int32_t comboSize = matching.n;
  if (comboSize > 0) {
    int isChainLink = 0, i;
    int32_t metalCount = 0;
    for (i = 0; i < matching.n; i++) {
      Panel *p = P(b, CR(matching.at[i]), CC(matching.at[i]));
      if (p->f[COLOR] == 8) metalCount++;
      if (SETB(p->f[CHAINING])) isChainLink = 1;
    }
    b->clearCounter = isChainLink ? b->clearCounter + 1 : 1;   // incrementClearCounter
    if (isChainLink) b->chainCounter = b->chainCounter != 0 ? b->chainCounter + 1 : 2;
    if (isChainLink) { b->ev[EV_LINK]++; if (b->chainCounter >= 6) b->ev[EV_BIGCHAIN]++; if (b->chainCounter >= 13) b->ev[EV_CHAINCAP]++; }
    else if (comboSize == 3) b->ev[EV_CLEAR3]++;
    if (comboSize > 3) b->ev[EV_COMBO]++;
    b->manualRaise = 0;
    sortByPopOrder(&matching, 0);   // applyMatchToPanels
    for (i = 0; i < comboSize; i++) {
      Panel *p = P(b, CR(matching.at[i]), CC(matching.at[i]));
      p->f[STATE] = MATCHED; p->f[TIMER] = b->fFLASH + b->fFACE + 1;
      if (isChainLink) p->f[CHAINING] = 1;
      if (SETN(p->f[FELL])) p->f[FELL] = NUL;
      p->f[COMBOINDEX] = i + 1; p->f[COMBOSIZE] = comboSize;
    }
    int32_t onScreen = 0, hit = 0;
    if (getConnectedGarbagePanels(b, &matching, &garbage)) {
      hit = 1;
      b->matchedThis = 1;
      for (i = 0; i < garbage.n; i++) if (CR(garbage.at[i]) <= b->height) onScreen++;
      matchGarbagePanels(b, &garbage, b->fFLASH + b->fFACE + b->fPOP * comboSize + b->fGARBAGE_POP * onScreen, isChainLink, onScreen);
    }
    int32_t preStop = b->fFLASH + b->fFACE + b->fPOP * comboSize + b->fGARBAGE_POP * onScreen + (hit ? b->fGARBAGE_HOVER : 0);
    b->preStopTime = imax(b->preStopTime, preStop);
    awardStopTime(b, isChainLink, comboSize, metalCount);
    if (isChainLink || comboSize > 3 || metalCount > 0) pushGarbage(b, isChainLink, comboSize, metalCount);
    if (b->sNCombo < MAXCOMBOS) { b->sCombo[b->sNCombo] = comboSize; b->sChainAt[b->sNCombo] = b->chainCounter; b->sLink[b->sNCombo] = isChainLink; b->sTouch[b->sNCombo] = hit; b->sNCombo++; }
    b->sCleared += comboSize;
    updateScoreWithBonus(b, comboSize, isChainLink);
  }
  clearChainingFlags(b);
}

// =============================================================== swaps (Stack:tryQueueSwap / canSwap / swap, WigglePay)
static int wiggleActive(Board *b) {
  if (b->swapStallingMode == 0 || b->swapStallingPunish == 0) return 0;
  if (!b->topRow || b->preStopTime != 0 || b->stopTime != 0 || b->shakeTime != 0) return 0;
  return (b->nActive - b->swappingCount) == 0;
}
static int wiggleCanSwap(Board *b, Panel *p1, Panel *p2, int32_t *cost) {
  *cost = 0;
  if (!wiggleActive(b)) return 1;
  for (int i = 0; i < b->nstall; i++) {
    Stall *o = &b->stall[i];
    if (o->clock >= b->clock) return 1;
    if (o->leftId == p1->f[ID] && o->rightId == p2->f[ID] && o->row == b->curRow && o->col == b->curCol) {
      if (b->health > b->swapStallingPunish) { *cost = b->swapStallingPunish; return 1; }
      return 0;
    }
  }
  return 1;
}
static void wiggleRegister(Board *b, Panel *p1, Panel *p2, int32_t cost) {
  if (wiggleActive(b)) {
    if (cost == 0) {
      if (b->nstall + 2 > MAXSTALL) { b->err |= ERR_STALL; return; }
      Stall a = { p2->f[ID], p1->f[ID], b->curRow, b->curCol, b->clock }, c = { p1->f[ID], p2->f[ID], b->curRow, b->curCol, b->clock };
      b->stall[b->nstall++] = a; b->stall[b->nstall++] = c;
    } else b->health -= cost;
  } else if (b->nstall > 0) b->nstall = 0;
}
static int canSwapPanels(Board *b, Panel *p1, Panel *p2, int32_t *cost) {
  *cost = 0;
  int d = p1->f[COL] - p2->f[COL];
  if ((d != 1 && d != -1) || p1->f[ROW] != p2->f[ROW]) return 0;
  if (b->clock <= 1) return 0;
  if (p1->f[COLOR] == 0 && p2->f[COLOR] == 0) return 0;
  if (!allowsSwap(p1) || !allowsSwap(p2)) return 0;
  int row = p1->f[ROW];
  Panel *a1 = 0, *a2 = 0;
  if (row < b->height) {
    a1 = P(b, row + 1, p1->f[COL]); a2 = P(b, row + 1, p2->f[COL]);
    if (a1->f[STATE] == HOVERING || a2->f[STATE] == HOVERING) return 0;
  }
  if (p1->f[COLOR] == 0 || p2->f[COLOR] == 0) {
    if (a1 && a2 && a1->f[STATE] == SWAPPING && a2->f[STATE] == SWAPPING &&
        (a1->f[COLOR] == 0 || a2->f[COLOR] == 0) && (a1->f[COLOR] != 0 || a2->f[COLOR] != 0)) return 0;
    if (row > 1) {
      Panel *b1 = P(b, row - 1, p1->f[COL]), *b2 = P(b, row - 1, p2->f[COL]);
      if (b1->f[STATE] == SWAPPING && b2->f[STATE] == SWAPPING &&
          (b1->f[COLOR] == 0 || b2->f[COLOR] == 0) && (b1->f[COLOR] != 0 || b2->f[COLOR] != 0)) return 0;
    }
  }
  if (b->swapStallingMode == 1) return wiggleCanSwap(b, p1, p2, cost);
  return 1;
}
static int tryQueueSwapPanels(Board *b, Panel *p1, Panel *p2) {
  int32_t cost;
  if (canSwapPanels(b, p1, p2, &cost)) {
    wiggleRegister(b, p1, p2, cost);
    b->swapCount++;
    b->queuedSwapCol = imin(p1->f[COL], p2->f[COL]);
    b->queuedSwapRow = p1->f[ROW];
    return 1;
  }
  return 0;
}
static void doSwap(Board *b, int row, int col) {
  b->ev[EV_SWAP]++;
  startSwap(P(b, row, col), 1);
  startSwap(P(b, row, col + 1), 0);
  switchPanels(b, P(b, row, col), P(b, row, col + 1));
  Panel *left = P(b, row, col), *right = P(b, row, col + 1);
  if (row != 1) {
    Panel *bl = P(b, row - 1, col), *br = P(b, row - 1, col + 1);
    if (left->f[COLOR] != 0 && (bl->f[COLOR] == 0 || bl->f[STATE] == FALLING)) left->f[DONTSWAP] = 1;
    if (right->f[COLOR] != 0 && (br->f[COLOR] == 0 || br->f[STATE] == FALLING)) right->f[DONTSWAP] = 1;
  }
  if (row != b->height) {
    if (left->f[COLOR] == 0 && P(b, row + 1, col)->f[COLOR] != 0) left->f[DONTSWAP] = 1;
    if (right->f[COLOR] == 0 && P(b, row + 1, col + 1)->f[COLOR] != 0) right->f[DONTSWAP] = 1;
  }
}

// =============================================================== the frame
// Stack:checkGameOver (the training rules: HEALTH 0, GARBAGE_LIMIT 50)
static int checkGameOver(Board *b) {
  if (b->gameOverClock > 0) return 1;
  if (b->health <= 0 && b->shakeTime <= 0) return 1;
  if (b->marginTime == MARGIN_OFF && b->ninc >= GARBAGE_LIMIT) return 1;
  return 0;
}
static void setGameOver(Board *b) { if (b->gameOverClock > 0) return; b->gameOverClock = b->clock; b->gameOver = 1; }
int caGameEnded(const Board *b) { return b->gameOverClock > 0 && b->clock >= b->gameOverClock; }

// Stack:controls (controller input)
static void controls(Board *b) {
  int32_t in = b->input;
  int dir = CD_NULL;
  b->swapThisFrame = (in & IN_SWAP) ? 1 : 0;
  if (in & IN_UP) dir = DIR_UP;
  else if (in & IN_DOWN) dir = DIR_DOWN;
  else if (in & IN_LEFT) dir = DIR_LEFT;
  else if (in & IN_RIGHT) dir = DIR_RIGHT;
  if (dir == b->cursorDirection) { if (b->curTimer != b->curWaitTime) b->curTimer++; }
  else { b->cursorDirection = dir; b->curTimer = 0; }
  if (b->swapThisFrame) tryQueueSwapPanels(b, P(b, b->curRow, b->curCol), P(b, b->curRow, b->curCol + 1));
  if (in & IN_RAISE) {
    if (b->topRow) b->manualRaise = 0;
    else if (!b->preventManualRaise) { b->manualRaise = 1; b->manualRaiseYet = 0; }
  }
}
// Stack:updateSpeed
static void updateSpeed(Board *b) {
  if (b->stopWatch != b->nextSpeedIncreaseClock) return;
  b->speed = imin(b->speed + 1, 99);
  b->nextSpeedIncreaseClock += DT_SPEED_INCREASE;
  if (b->marginTime > 1) b->health = imax(1, (int32_t)__builtin_floor(b->health * 0.9));
  if (b->marginTime == MARGIN_COLORS) {
    b->marginCounter++;
    if (b->marginCounter > 0 && b->marginCounter % 10 == 0) { b->colorCount = imin(8, b->colorCount + 1); b->colors = b->colorCount; }
  } else if (b->marginTime == MARGIN_MODOKI) b->marginCounter = imin(20, b->marginCounter + 1);
  else if (b->marginTime == MARGIN_CHAOS) {
    b->marginCounter = imin(20, b->marginCounter + 1);
    b->shakeMargin = imax(1, (int32_t)__builtin_floor(b->shakeMargin * 0.95));
  }
}
// Stack:advancePassiveRaise
static void advancePassiveRaise(Board *b) {
  if (b->manualRaise) {
    if (b->displacement == 0 && b->hasRisen) { b->topCurRow = b->height; newRow(b); }
    return;
  }
  if (b->stopTime == 0 && !b->riseLock) {
    if (b->topRow) { b->health--; b->ev[EV_HEALTHLOST]++; }
    else {
      b->riseTimer--;
      if (b->riseTimer <= 0) {
        b->displacement--;
        if (b->displacement == 0) { b->preventManualRaise = 0; b->topCurRow = b->height; newRow(b); }
        b->riseTimer += SPEED_TO_RISE_TIME[b->speed - 1];
      }
    }
  }
}
static void applyCursorDirection(Board *b) {
  int d = b->cursorDirection;
  if (d != CD_NULL && (b->curTimer == 0 || b->curTimer == b->curWaitTime)) {
    b->curRow = bound(1, b->curRow + DIR_ROW[d], b->topCurRow);
    b->curCol = bound(1, b->curCol + DIR_COL[d], W - 1);
  } else b->curRow = bound(1, b->curRow, b->topCurRow);
  if (b->curTimer != b->curWaitTime) b->curTimer++;
}
static void updatePanels(Board *b) {
  b->shakeTimeOnFrame = 0;
  for (int r = 1; r < b->nrows; r++)   // (row 0 is dimmed; updatePanel leaves it as it is until it is row 1)
    for (int c = 1; c <= W; c++) updatePanel(b, P(b, r, c));
}
// Stack.run: controls, then Stack:simulate (past the countdown)
void caRun(Board *b) {
  if (caGameEnded(b)) return;
  // a swap the bot pressed for this frame is the frame's swap key
  int pressed = b->pressSwap || (b->input & IN_SWAP);
  int32_t queuedBefore = b->swapCount;
  b->input |= b->pressSwap ? IN_SWAP : 0;
  b->inputBits = b->input;
  b->pressSwap = 0;
  b->swapDenied = 0;
  controls(b);
  if (pressed && b->swapCount == queuedBefore) b->swapDenied = 1;
  // ---- simulate
  b->nlanded = 0;
  b->matchedThis = 0;
  b->landedLast = b->landedThis; b->landedThis = 0;   // updateGarbageLanded
  b->topRow = hasPanelsInTopRow(b);
  b->wasToppedOut = b->topRow;
  if (b->swapCount >= b->startTimersWithSwapCount) {
    b->prevShakeTime = b->shakeTime;
    b->shakeTime = imax(b->shakeTime - 1, b->shakeTimeOnFrame);
    if (b->shakeTime == 0) b->peakShakeTime = 0;
    if (b->preStopTime != 0) b->preStopTime--;
    else if (b->stopTime != 0) b->stopTime--;
    updateRiseLock(b);
    updateSpeed(b);
    if (b->passiveRaise) {
      advancePassiveRaise(b);
      if (checkGameOver(b)) setGameOver(b);
    }
    if (b->displacement % 16 != 0) b->topCurRow = b->height - 1;
  }
  if (swapQueued(b)) { doSwap(b, b->queuedSwapRow, b->queuedSwapCol); b->queuedSwapCol = 0; b->queuedSwapRow = 0; }
  checkMatches(b);
  updatePanels(b);
  updateActivePanelCount(b);
  updateActiveGarbageCount(b);
  applyCursorDirection(b);
  if (b->allowManualRaise && b->manualRaise) {
    if (!b->riseLock) {
      b->stopTime = 0;
      if (b->topRow) { if (checkGameOver(b)) setGameOver(b); }
      else {
        b->hasRisen = 1;
        b->displacement--;
        if (b->displacement == 1) {
          b->manualRaise = 0; b->riseTimer = 1;
          if (!b->preventManualRaise) b->score += 1;
          b->preventManualRaise = 1;
        }
        b->manualRaiseYet = 1;
      }
    } else if (!b->manualRaiseYet) b->manualRaise = 0;
    else if (hasFallingGarbage(b)) b->manualRaise = 0;
  }
  // the all-clear: a clear that leaves rows 1..height empty
  if (b->clearCounter != 0 && !hasMatchingPanels(b) && !hasChainingPanels(b)) {
    if (hasZeroPanels(b)) {
      b->hasAllClear = 1;
      b->ev[EV_ALLCLEAR]++;
      b->score += 2500 * __builtin_pow(2, b->colorCount - 4) * b->clearCounter;
    }
    b->clearCounter = 0;
  }
  if (b->chainCounter != 0 && !hasChainingPanels(b)) {
    b->chainCounter = 0;
    if (b->outChain) { b->outChains++; b->outChainRows += b->outChain; b->outChain = 0; }   // finalizeCurrentChain
  }
  if (b->score > 999999) b->score = 999999;
  if (checkGameOver(b)) setGameOver(b);
  removeExtraRows(b);
  b->topRow = hasPanelsInTopRow(b);
  for (int r = b->height + 1; r <= TOP(b) && !b->topRow; r++)
    for (int c = 1; c <= W; c++) if (P(b, r, c)->f[COLOR] != 0) { b->topRow = 1; break; }
  if (shouldDropGarbage(b)) tryDropGarbage(b);
  b->clock++;
  b->stopWatch = (b->stopWatch == NUL ? -1 : b->stopWatch) + 1;
  b->input = 0;
}

// =============================================================== setup and questions
void caInit(Board *b, int level, int gameMode, int marginTime, int chaosMode, int queueType) {
  memset(b, 0, sizeof *b);
  const int *L = LEVELS[level < 1 ? 1 : level > 11 ? 11 : level];
  b->speed = L[0]; b->shockFrequency = L[1]; b->shockCap = L[2]; b->maxHealth = L[3]; b->stopBase = L[4];
  b->fHOVER = L[5]; b->fGARBAGE_HOVER = L[6]; b->fFLASH = L[7]; b->fFACE = L[8]; b->fPOP = L[9]; b->fGARBAGE_POP = L[10];
  b->gameMode = gameMode; b->marginTime = marginTime; b->chaosMode = chaosMode; b->queueType = queueType;
  b->passiveRaise = 1; b->allowManualRaise = 1; b->swapStallingMode = 1; b->swapStallingPunish = 4; b->startTimersWithSwapCount = 0;
  b->height = 12;
  b->nextSpeedIncreaseClock = DT_SPEED_INCREASE;
  b->shakeMargin = 200;
  b->health = (gameMode % 2 == 0 || gameMode == 5) ? 1 : b->maxHealth;
  b->displacement = 16;
  b->riseTimer = SPEED_TO_RISE_TIME[b->speed - 1];
  b->curWaitTime = 20; b->cursorDirection = CD_NULL; b->curRow = 7; b->curCol = 3; b->topCurRow = 12;
  b->stopWatch = NUL;
  b->colorCount = b->colors = 6; b->stopWatchIsRunning = 1; b->cursorLock = NUL; b->hi = MAXROWS;
  for (int i = 1; i <= 6; i++) b->dropColumnIndex[i] = 1;
  b->nrows = 13;
  for (int r = 0; r <= 12; r++) for (int c = 1; c <= W; c++) createPanelAt(b, r, c);
}
int caFeedRow(Board *b, const int32_t *c) {
  if (b->nRowFeed >= FEED) return 0;
  memcpy(b->rowFeed[(b->rowFeedAt + b->nRowFeed) % FEED], c, sizeof(int32_t) * W); b->nRowFeed++;
  return 1;
}
int caFeedBreak(Board *b, const int32_t *c) {
  if (b->nBrkFeed >= FEED) return 0;
  memcpy(b->brkFeed[(b->brkFeedAt + b->nBrkFeed) % FEED], c, sizeof(int32_t) * W); b->nBrkFeed++;
  return 1;
}
int caToppedOut(Board *b) { return hasPanelsInTopRow(b); }
int caCanSwap(Board *b, int row, int col) {
  int32_t cost;
  if (row < 1 || row > b->height || col < 1 || col >= W) return 0;
  return canSwapPanels(b, P(b, row, col), P(b, row, col + 1), &cost);
}
int caRiseFrames(int speed) { return SPEED_TO_RISE_TIME[bound(1, speed, 99) - 1]; }

// the column the next piece `width` wide drops at, without turning the index (Stack.getGarbageSpawnColumn's answer)
int caSpawnColumn(const Board *b, int width) {
  static const int MAP[7][6] = { { 0 }, { 1, 2, 3, 4, 5, 6 }, { 1, 3, 5 }, { 1, 4 }, { 1, 2, 3 }, { 1, 2 }, { 1 } };
  if (width < 1 || width > 6) return 0;
  return b->chaosMode ? b->dropColumnIndex[width] : MAP[width][b->dropColumnIndex[width] - 1];
}
// the shake a piece of `width` x `height` lands with now (dropGarbage, the chaos margin included)
int caShake(Board *b, int width, int height) { return shakeFor(b, width, height); }
