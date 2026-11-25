// ================================================================== THE SEARCH
// puyocpu.js's survival search, on these boards: a node is a board at one of
// the bot's decision frames, a step is one decision played frame by frame
// (_engineAdvanceOn / _runFrom / _engineStep, with panel-cpu.js's walk), and
// the level loop is _survivalSearch's. Same order, same budget, same keys, so
// the same moves are proven. native.js puts nodes in front of puyocpu.js;
// native.test.js and GC_ENGINE_CHECK compare every step with the JS one.
// What an engine gives the search, besides Board, run, canSwap, tryQueueSwap,
// cloneBoard, nb_load and nb_save:
//   KEY_COLOR(f)       a panel's colour in the key (garbage: its kind)
//   SWAP_PRESSED       1 where tryQueueSwap only presses swap for the next
//                      frame and that frame decides (the server's engine);
//                      st->swapDenied then says it was not taken
//   pushArrival(b, a)  garbage arriving
//   NODE_BREAKS(b)     garbage rows broken on the board so far (0 where not counted)
#ifndef NODE_BREAKS
#define NODE_BREAKS(b) 0   // an engine that counts breaks says how
#endif
// isMetal: bit 1 metal, bit 2 capped -- an attack engine's garbage, which the
// game holds back while CAPPED_AT are queued, the earliest due of it a frame.
typedef struct { int32_t at, width, height, isChain, isMetal; } Arr;
#define CAPPED_AT 72
#define MAXARR 64   // pa.c / engine.c NBODY leave room for this many after the board
#define KEYMAX (16 * W)
enum { MK_LONG, MK_HOLD, MK_RAISE, MK_SWAP, MK_SETTLE, MK_GO };   // MK_GO: the cursor walked to a cell, nothing swapped
// MK_SETTLE (engines with STEP_STATS): a swap at (mr, mc) -- or, with mr 0, a
// hold -- and then the frames until nothing moves, at most `frames` (or
// SETTLE_CAP when that is 0), as the
// bot's candidate resolve settles them; what the step did is read with
// ns_step_stats.
typedef struct Node {
  Board *st;                   // 0 once freed: replayed from prev when asked for
  int32_t t, holdLeft, holdStarted, fresh, dead, fromPrev;   // fromPrev: a dead end, on its parent's board
  int32_t narr; Arr arr[MAXARR];
  int32_t tag, prev, mk, mr, mc, frames, seed, pins, err, live, kept;
  int32_t held, garb, top, pos0, pos1, brk;   // brk: garbage rows broken so far (NODE_BREAKS)
  int32_t stopTime, preStopTime, shakeTime, displacement, speed;
  double riseTimer;
  uint32_t hash;
  int32_t keyn; int32_t key[KEYMAX];
} Node;
typedef struct { int32_t *a; int32_t n, cap; } Vec;
typedef struct Ctx {
  Node *nodes; int32_t n, cap;
  int32_t reaction, cursorMoveFrames, surviveFrames, surviveRest;
  int32_t swapGap;   // frames the bot waits after a swap before it acts again (ns_ctx_gap; reaction unless set)
  int32_t steps;
  // the level loop's own storage, kept from search to search
  Vec level, next, keep, tmp, moves;
  int32_t *seen; int32_t seenCap;
  int32_t ntags;
  int32_t *verdict, *proofs, *weak, *reach, *reachSet, *far, *per, *brkAt; int32_t tagCap;
  int32_t rootBrk;   // the root's rows broken: a line breaks garbage when a node's brk is past it
  int32_t par;   // threads are making nodes: newNode takes a reserved slot
  Vec later;     // nodes let go while a phase ran, their boards freed at its end (release)
} Ctx;
#define NODE(x, i) (&(x)->nodes[i])

// A new node zeroed but for its garbage on its way, read only up to narr,
// and its key, which readBoard writes.
#define NODE_AT(f) ((unsigned long)&((Node *)0)->f)
static void clearNode(Node *n) {
  memset(n, 0, NODE_AT(arr));
  memset((char *)n + NODE_AT(tag), 0, NODE_AT(key) - NODE_AT(tag));
}
static Node *newNode(Ctx *x) {
  if (x->par) {
    int32_t i = __atomic_fetch_add(&x->n, 1, __ATOMIC_SEQ_CST);
    if (i >= x->cap) return 0;   // reserved before the threads start: never here
    Node *n = &x->nodes[i];
    clearNode(n);
    n->prev = -1; n->tag = -1;
    return n;
  }
  if (x->n == x->cap) {
    int32_t cap = x->cap ? x->cap * 2 : 1024;
    Node *nn = (Node *)grab((unsigned long)cap * sizeof(Node));
    if (!nn) return 0;
    if (x->n) memcpy(nn, x->nodes, (unsigned long)x->n * sizeof(Node));
    if (x->nodes) paRelease(x->nodes, (unsigned long)x->cap * sizeof(Node)); x->nodes = nn; x->cap = cap;   // the old block is left behind (nodes grow rarely), its pages given back: nothing reads it again
  }
  Node *n = &x->nodes[x->n++];
  clearNode(n);
  n->prev = -1; n->tag = -1;
  return n;
}
EXPORT(ns_ctx_new) Ctx *ns_ctx_new(void) { Ctx *x = (Ctx *)grab(sizeof(Ctx)); memset(x, 0, sizeof(Ctx)); return x; }
EXPORT(ns_ctx_set) void ns_ctx_set(Ctx *x, int reaction, int cursorMoveFrames, int surviveFrames, int surviveRest) {
  x->reaction = reaction; x->cursorMoveFrames = cursorMoveFrames; x->surviveFrames = surviveFrames; x->surviveRest = surviveRest;
  x->swapGap = reaction;
}
EXPORT(ns_ctx_cap) int ns_ctx_cap(Ctx *x) { return x->cap; }
// After a swap the bot acts again `gap` frames on; a hold or a wait is still reaction + 1.
EXPORT(ns_ctx_gap) void ns_ctx_gap(Ctx *x, int gap) { x->swapGap = gap; }
// Every node gone and every board back in the pool.
EXPORT(ns_reset) void ns_reset(Ctx *x) {
  for (int i = 0; i < x->n; i++) if (x->nodes[i].st && !x->nodes[i].fromPrev) nb_free(x->nodes[i].st);
  x->n = 0; x->later.n = 0;
}

// ---- what the search reads off a board (puyocpu.js _engineNode, FastStack.grid)
static const char STATE_KEY[10] = { 0, 1, 2, 3, 4, 4, 5, 6, 7, 8 };   // 'popping' and 'popped' share their 'p'
static void readBoard(Node *n, Board *b) {
  int H = b->height, r, c, k = 0, g = 0, top = 0;
  uint32_t h = 2166136261u;
  for (r = 1; r <= H + 1 && r < b->nrows; r++)
    for (c = 1; c <= W; c++) {
      const int32_t *f = b->p[r][c].f;
      if (f[COLOR] != 0) { top = r; if (f[ISGARBAGE]) g++; }
      // The key holds 19 bits of timer: one outside them is clamped, which
      // only lets two boards that differ there share a key.
      int32_t tm = f[TIMER];
      if (tm < 0) tm = 0; else if (tm >= (1 << 19)) tm = (1 << 19) - 1;
      int32_t v = KEY_COLOR(f) | (STATE_KEY[f[STATE]] << 8) | (tm << 12);
      if (k < KEYMAX) n->key[k++] = v;
      h = (h ^ (uint32_t)v) * 16777619u;
    }
  n->keyn = k; n->hash = h; n->garb = g; n->top = top;
  n->pos0 = b->curRow; n->pos1 = b->curCol;
  n->stopTime = b->stopTime; n->preStopTime = b->preStopTime; n->shakeTime = b->shakeTime;
  n->displacement = b->displacement; n->riseTimer = b->riseTimer; n->speed = b->speed;
  n->held = b->stopTime + b->preStopTime + b->shakeTime;
  n->brk = NODE_BREAKS(b);
}
static int legalSwaps(Board *b, int32_t *out) {
  int n = 0;
  for (int r = 1; r <= b->height; r++)
    for (int c = 1; c < W; c++) {
      Panel *a = P(b, r, c), *d = P(b, r, c + 1);
      if (a->f[ISGARBAGE] || d->f[ISGARBAGE]) continue;
      if (a->f[COLOR] == 0 && d->f[COLOR] == 0) continue;
      if (a->f[COLOR] == d->f[COLOR]) continue;
      if (!canSwap(b, r, c)) continue;
      out[n++] = r * 8 + c;
    }
  return n;
}

// ---- the bot's hands (panel-cpu.js beginWalk / driveWalk / nearestSwappable, puyocpu.js raiseStep)
typedef struct { int32_t active, row, col, timer, cooldown, retries, disp, go; } Walk;   // go: the walk ends at the cell, no swap pressed
typedef struct { Walk w; int32_t cooldown, lastSwap, raiseFrames, raiseStarted; } Bot;
static void beginWalk(Bot *bot, int row, int col, int cooldown) {
  Walk w = { 1, row, col, 0, cooldown, 0, UND, 0 };
  bot->w = w;
}
static int nearestSwappable(Board *b, int fromRow, int fromCol, int *out) {
  int found = 0, bestD = 0x7fffffff;
  for (int r = 1; r <= b->topCurRow; r++)
    for (int c = 1; c < W; c++) {
      if (r == fromRow && c == fromCol) continue;
      int d = (r > fromRow ? r - fromRow : fromRow - r) + (c > fromCol ? c - fromCol : fromCol - c);
      if (d >= bestD) continue;
      if (!canSwap(b, r, c)) continue;
      out[0] = r; out[1] = c; bestD = d; found = 1;
    }
  return found;
}
static void driveWalk(Ctx *x, Bot *bot, Board *b, int32_t *input) {
  Walk *w = &bot->w;
  if (w->disp != UND && b->displacement > w->disp) w->row++;
  w->disp = b->displacement;
  int row = imax(1, imin(w->row, b->topCurRow)), col = imax(1, imin(w->col, W - 1));
  if (b->curRow != row || b->curCol != col) {
    if (w->timer > 0) { w->timer--; return; }
    if (b->curCol < col) *input |= IN_RIGHT;
    else if (b->curCol > col) *input |= IN_LEFT;
    else if (b->curRow < row) *input |= IN_UP;
    else *input |= IN_DOWN;
    w->timer = x->cursorMoveFrames - 1;
    return;
  }
  if (w->go) { w->active = 0; return; }
  int ok = tryQueueSwap(b, b->curRow, b->curCol);
  Walk old = *w;
  w->active = 0;
  if (ok) { bot->lastSwap = 1; bot->cooldown = old.cooldown; return; }
  int alt[2];
  if (old.retries < 2 && nearestSwappable(b, b->curRow, b->curCol, alt)) {
    beginWalk(bot, alt[0], alt[1], old.cooldown);
    bot->w.retries = old.retries + 1;
    return;
  }
  bot->cooldown = old.cooldown;
}
// A RAISE HELD: it ends when the engine refuses it (preventManualRaise) or lets go of it after it started. With HOLD_THROUGH (the
// agro profile's holdThrough, ns_hold_through) it goes on through the rows it brings in -- the engine lets go of the button as each
// row comes in, for the frame the row is finished on, and takes it again the frame after -- and only a raise refused before it has
// started ends at once.
static int32_t HOLD_THROUGH = 0;
EXPORT(ns_hold_through) void ns_hold_through(int32_t on) { HOLD_THROUGH = on; }
static void raiseStep(Bot *h, Board *st, int32_t *input) {
  if (h->raiseFrames > 0) {
    if (st->manualRaise) h->raiseStarted = 1;
    if (HOLD_THROUGH ? (st->preventManualRaise && !h->raiseStarted) : (st->preventManualRaise || (h->raiseStarted && !st->manualRaise))) h->raiseFrames = 0;
    else { h->raiseFrames--; *input |= IN_RAISE; }
  }
}

// ---- one step
#define STEP_NULL (-1)
#define STEP_DEAD (-2)
#define STEP_ERR (-3)
static LOCAL int32_t deadAt;   // the frame a STEP_DEAD died on
static int32_t stepErr;   // the engine's err bits of the last step that failed on them (ns_step_err)
EXPORT(ns_step_err) int ns_step_err(void) { int e = stepErr; stepErr = 0; return e; }
#ifndef PUSH_ARRIVAL
static void pushArrival(Board *b, const Arr *a) { nb_push_incoming(b, a->width, a->height, a->isChain, a->isMetal & 1); }
#endif
// THE KEY TAPE: with tape set, advance writes every frame it plays -- the
// keys sent (SENT_KEYS: with the swap an engine presses for itself) and the
// raise held after it -- so a caller can press what the search played.
#ifndef SENT_KEYS
#define SENT_KEYS(st, input) (input)
#endif
static LOCAL int32_t *tape, tapeN, tapeCap;
// When the garbage on its way is next due: due[0] the earliest that lands as
// it comes, due[1] the earliest held back (capped) -- which lands only once
// fewer than CAPPED_AT are queued. Nothing lands before them.
static void dueOf(const Arr *arr, int32_t narr, int32_t *due) {
  due[0] = due[1] = 0x7fffffff;
  for (int i = 0; i < narr; i++) { int k = (arr[i].isMetal & 2) ? 1 : 0; if (arr[i].at < due[k]) due[k] = arr[i].at; }
}
static int runFrame(Board *st, Arr *arr, int32_t *narr, int32_t input, int32_t *f, int32_t *due) {
  st->input = input;
  run(st);
  (*f)++;
  if (*f < due[0] && (*f < due[1] || st->ninc >= CAPPED_AT)) return st->gameOver;
  int k = 0, first = 0x7fffffff;
  for (int i = 0; i < *narr; i++) if ((arr[i].isMetal & 2) && arr[i].at <= *f && arr[i].at < first) first = arr[i].at;
  int open = first != 0x7fffffff && st->ninc < CAPPED_AT;
  for (int i = 0; i < *narr; i++) {
    if (arr[i].at <= *f && (!(arr[i].isMetal & 2) || (open && arr[i].at == first))) pushArrival(st, &arr[i]);
    else arr[k++] = arr[i];
  }
  *narr = k; dueOf(arr, k, due);
  return st->gameOver;
}
static Board *ensureBoard(Ctx *x, int i);
// _engineAdvanceOn + _runFrom. Returns the child's index, STEP_NULL (refused)
// or STEP_DEAD (deadAt set).
// The rest of a step, from the frame its walk (if any) has got to: st, bot,
// the garbage on its way, the keys this frame and the frames played so far.
static int advanceRest(Ctx *x, int pi, int kind, int mr, int mc, int32_t frames, Board *st, Bot *botp, Arr *arr, int32_t narr,
                       int32_t input, int32_t f, int32_t t0, int swapping, int guard0) {
  Bot bot = *botp;
  int32_t due[2];
  dueOf(arr, narr, due);
#define REFUSED (swapping && !bot.w.active && !bot.lastSwap)
#define GIVE(code) do { nb_free(st); return (code); } while (0)
#define FRAME() do { if (tape) { if (tapeN >= tapeCap) GIVE(STEP_ERR); \
                        tape[3 * tapeN] = SENT_KEYS(st, input); tape[3 * tapeN + 1] = bot.raiseFrames; \
                        tape[3 * tapeN + 2] = bot.raiseStarted; tapeN++; } \
                      int over_ = runFrame(st, arr, &narr, input, &f, due); if (st->err) { stepErr = st->err; GIVE(STEP_ERR); } \
                      if (SWAP_PRESSED && swapping && st->swapDenied) GIVE(STEP_NULL); \
                      if (over_) { deadAt = t0 + f; STAT(kind & 7) += f; STAT(8 + (kind & 7))++; GIVE(STEP_DEAD); } } while (0)
  if (REFUSED || (bot.w.active && bot.w.retries)) GIVE(STEP_NULL);
  FRAME();
  for (int guard = guard0; guard < 4000; guard++) {
    if (kind == MK_LONG && f >= frames) break;
    input = 0;
    raiseStep(&bot, st, &input);
#ifdef COUNTDOWN
    // Frames on which only timers run are played at once (countdown), up to
    // the frame before the step ends or garbage on its way lands.
    if (!tape && !input && !bot.w.active) {
      int32_t room = kind == MK_LONG ? frames - f - 1
                   : bot.cooldown > 0 ? bot.cooldown - 1
                   : kind == MK_SETTLE && f >= 3 ? (frames > 0 ? frames : SETTLE_CAP) - f - 1 : 0;
      room = imin(room, imin(due[0], due[1]) - f - 1);
      int32_t k = countdown(st, room);
      if (k > 0) { f += k; if (bot.cooldown > 0) bot.cooldown -= k; }
    }
#endif
    if (bot.w.active) {
      driveWalk(x, &bot, st, &input);
      if (REFUSED || (bot.w.active && bot.w.retries)) GIVE(STEP_NULL);
      FRAME();
      continue;
    }
    if (kind != MK_LONG) {
      if (bot.cooldown > 0) { bot.cooldown--; FRAME(); continue; }
#ifdef STEP_STATS
      if (kind == MK_SETTLE && (f < 3 || !st->quiet) && f < (frames > 0 ? frames : SETTLE_CAP)) { FRAME(); continue; }
#endif
      break;
    }
    FRAME();
  }
#undef FRAME
  if (st->err) GIVE(STEP_ERR);
  STAT(kind & 7) += f; STAT(8 + (kind & 7))++;
  Node *n = newNode(x);
  if (!n) GIVE(STEP_ERR);
  n->st = st; n->t = t0 + f; n->holdLeft = bot.raiseFrames; n->holdStarted = bot.raiseStarted; n->fresh = 0;
  n->narr = narr;
  for (int i = 0; i < narr; i++) { n->arr[i] = arr[i]; n->arr[i].at -= f; }
  n->prev = pi; n->mk = kind; n->mr = mr; n->mc = mc; n->frames = frames;
  readBoard(n, st);
  if (n->err) return STEP_ERR;
  return (int)(n - x->nodes);
#undef REFUSED
#undef GIVE
}
static int advance(Ctx *x, int pi, int kind, int mr, int mc, int32_t frames) {
  Board *pb = ensureBoard(x, pi);
  if (!pb) return STEP_ERR;
  Node *par = NODE(x, pi);
  Board *st = nb_new();
  if (!st) return STEP_ERR;
  cloneBoard(st, pb);
  Bot bot; memset(&bot, 0, sizeof bot);
  bot.raiseFrames = par->holdLeft; bot.raiseStarted = par->holdStarted;
  Arr arr[MAXARR]; int32_t narr = par->narr;
  for (int i = 0; i < narr; i++) arr[i] = par->arr[i];
  int32_t input = par->fresh ? st->input : 0, f = 0, t0 = par->t;
  if (!par->fresh) raiseStep(&bot, st, &input);
  int swapping = kind == MK_SWAP || (kind == MK_SETTLE && mr > 0);
#define GIVE0(code) do { nb_free(st); return (code); } while (0)
#ifdef STEP_STATS
  st->sNCombo = 0; st->sCleared = 0; st->sBroke = 0; st->sEarned = 0;
#else
  if (kind == MK_SETTLE) GIVE0(STEP_ERR);
#endif
  if (swapping) { beginWalk(&bot, mr, mc, x->swapGap); driveWalk(x, &bot, st, &input); }
  else if (kind == MK_GO) { beginWalk(&bot, mr, mc, 0); bot.w.go = 1; driveWalk(x, &bot, st, &input); }
  else if (kind == MK_RAISE) { bot.raiseFrames = 20; bot.raiseStarted = 0; bot.cooldown = x->reaction; }
  else if (kind == MK_HOLD || kind == MK_SETTLE) bot.cooldown = x->reaction;
  return advanceRest(x, pi, kind, mr, mc, frames, st, &bot, arr, narr, input, f, t0, swapping, 0);
#undef GIVE0
}
#ifdef SHARED_WALK
// SHARED WALKS. A swap's walk presses only cursor keys and nothing but the
// cursor reads them, so every swap from one parent plays the same board until
// its own swap is pressed. advanceSwaps plays that board once, moves each
// swap's cursor along it as the engine does (controls, a new row, then
// applyCursorDirection) and at each press goes on from a copy of it with that
// cursor (advanceRest). out[i] is what advance(x, pi, MK_SWAP, CR(mv[i]),
// CC(mv[i]), 0) returns, dead[i] its deadAt. A walk the engine would turn
// aside (a refused press), a swap already pressed and the key tape are left
// to advance.
#define MAXWALK 128
#define WALKING (-98)   // out[i] while swap i walks
typedef struct { int32_t row, col, dir, timer; } Cur;
static void curControls(Cur *c, const Board *b, int32_t in) {
  int dir = CD_NULL;
  if (in & IN_UP) dir = DIR_UP;
  else if (in & IN_DOWN) dir = DIR_DOWN;
  else if (in & IN_LEFT) dir = DIR_LEFT;
  else if (in & IN_RIGHT) dir = DIR_RIGHT;
  if (dir == c->dir) { if (c->timer != b->curWaitTime) c->timer++; }
  else { c->dir = dir; c->timer = 0; }
}
// After the frame: rows new rows rose (newRow, the top row then b->height), then applyCursorDirection.
static void curAfter(Cur *c, const Board *b, int32_t rows) {
  for (int k = 0; k < rows; k++) if (c->row != 0) c->row = bound(1, c->row + 1, b->height);
  if (c->dir != CD_NULL && (c->timer == 0 || c->timer == b->curWaitTime) && !SETB(b->cursorLock)) {
    c->row = bound(1, c->row + DIR_ROW[c->dir], b->topCurRow);
    c->col = bound(1, c->col + DIR_COL[c->dir], W - 1);
  } else c->row = bound(1, c->row, b->topCurRow);
  if (c->timer != b->curWaitTime) c->timer++;
}
// driveWalk with the cursor at c: 1 when it presses swap, -1 when the press
// would be refused.
static int driveWalkC(Ctx *x, Bot *bot, const Board *b, const Cur *c, int32_t *input) {
  Walk *w = &bot->w;
  if (w->disp != UND && b->displacement > w->disp) w->row++;
  w->disp = b->displacement;
  int row = imax(1, imin(w->row, b->topCurRow)), col = imax(1, imin(w->col, W - 1));
  if (c->row != row || c->col != col) {
    if (w->timer > 0) { w->timer--; return 0; }
    if (c->col < col) *input |= IN_RIGHT;
    else if (c->col > col) *input |= IN_LEFT;
    else if (c->row < row) *input |= IN_UP;
    else *input |= IN_DOWN;
    w->timer = x->cursorMoveFrames - 1;
    return 0;
  }
  if (b->gameOverClock > 0) return -1;   // tryQueueSwap
  w->active = 0; bot->lastSwap = 1; bot->cooldown = w->cooldown;
  return 1;
}
static void advanceSwaps(Ctx *x, int pi, int n, const int32_t *mv, int32_t *out, int32_t *dead) {
  int i;
  Board *pb = ensureBoard(x, pi), *T = 0;
  Node *par = NODE(x, pi);
  int alone = !pb || tape || n > MAXWALK || pb->pressSwap || ((par->fresh ? pb->input : 0) & IN_SWAP) || !(T = nb_new());
  if (alone) {
    for (i = 0; i < n; i++) { out[i] = advance(x, pi, MK_SWAP, CR(mv[i]), CC(mv[i]), 0); dead[i] = out[i] == STEP_DEAD ? deadAt : 0; }
    return;
  }
  cloneBoard(T, pb);
  Bot tb; memset(&tb, 0, sizeof tb);
  tb.raiseFrames = par->holdLeft; tb.raiseStarted = par->holdStarted;
  Arr arr[MAXARR]; int32_t narr = par->narr;
  for (i = 0; i < narr; i++) arr[i] = par->arr[i];
  int32_t input = par->fresh ? T->input : 0, f = 0, t0 = par->t, walking = n, due[2];
  dueOf(arr, narr, due);
  if (!par->fresh) raiseStep(&tb, T, &input);
#ifdef STEP_STATS
  T->sNCombo = 0; T->sCleared = 0; T->sBroke = 0; T->sEarned = 0;
#endif
  Bot mb[MAXWALK]; Cur cu[MAXWALK]; int32_t in[MAXWALK];
  for (i = 0; i < n; i++) {
    memset(&mb[i], 0, sizeof mb[i]);
    beginWalk(&mb[i], CR(mv[i]), CC(mv[i]), x->swapGap);
    Cur c = { T->curRow, T->curCol, T->cursorDirection, T->curTimer };
    cu[i] = c; out[i] = WALKING; dead[i] = 0;
  }
  for (int it = -1; walking > 0; it++) {
    if (it >= 0) { input = 0; raiseStep(&tb, T, &input); }
    for (i = 0; i < n; i++) {
      if (out[i] != WALKING) continue;
      int32_t k = input;
      int r = driveWalkC(x, &mb[i], T, &cu[i], &k);
      if (r < 0) { out[i] = advance(x, pi, MK_SWAP, CR(mv[i]), CC(mv[i]), 0); dead[i] = out[i] == STEP_DEAD ? deadAt : 0; walking--; continue; }
      if (r > 0) {
        Board *st = nb_new();
        walking--;
        if (!st) { out[i] = STEP_ERR; continue; }
        cloneBoard(st, T);
        st->curRow = cu[i].row; st->curCol = cu[i].col; st->cursorDirection = cu[i].dir; st->curTimer = cu[i].timer;
        st->pressSwap = 1;   // tryQueueSwap
        Bot b = mb[i]; b.raiseFrames = tb.raiseFrames; b.raiseStarted = tb.raiseStarted;
        Arr a2[MAXARR];
        for (int q = 0; q < narr; q++) a2[q] = arr[q];
        out[i] = advanceRest(x, pi, MK_SWAP, CR(mv[i]), CC(mv[i]), 0, st, &b, a2, narr, k, f, t0, 1, it < 0 ? 0 : it + 1);
        dead[i] = out[i] == STEP_DEAD ? deadAt : 0;
        continue;
      }
      in[i] = k;
    }
    if (!walking) break;
    int32_t rows = T->unseenRows, over = runFrame(T, arr, &narr, input, &f, due);
    rows = T->unseenRows - rows;
    for (i = 0; i < n; i++) {
      if (out[i] != WALKING) continue;
      if (T->err) { out[i] = STEP_ERR; continue; }
      if (over) { out[i] = STEP_DEAD; dead[i] = t0 + f; STAT(MK_SWAP) += f; STAT(8 + MK_SWAP)++; continue; }
      curControls(&cu[i], T, in[i]); curAfter(&cu[i], T, rows);
    }
    if (T->err || over) break;
  }
  nb_free(T);
}
#endif
// _engineStep: a wait to `until` in whole beats (reaction + 1), a raise, a
// hold or a swap. A wait that dies after the horizon is a dead end on the
// parent's board.
// A wait to `until` from node pi, in whole beats (reaction + 1).
static int32_t longFrames(Ctx *x, int pi, int32_t until) {
  int32_t beat = x->reaction + 1, fr = imax(1, until - NODE(x, pi)->t);
  return ((fr + beat - 1) / beat) * beat;
}
static int lineStep(Ctx *x, int pi, int kind, int mr, int mc, int32_t until) {
  int32_t frames = kind == MK_LONG ? longFrames(x, pi, until) : 0;
  int r = advance(x, pi, kind, mr, mc, frames);
  if (r != STEP_DEAD) return r;
  if (kind == MK_LONG && deadAt >= x->surviveFrames) {
    Node *n = newNode(x);
    if (!n) return STEP_ERR;
    Node *par = NODE(x, pi);
    int32_t keep[KEYMAX]; int32_t keyn = par->keyn;
    for (int i = 0; i < keyn; i++) keep[i] = par->key[i];
    *n = *par;
    for (int i = 0; i < keyn; i++) n->key[i] = keep[i];
    n->fresh = 0;
    n->st = 0; n->fromPrev = 1; n->t = deadAt; n->dead = 1; n->prev = pi; n->mk = kind; n->mr = mr; n->mc = mc;
    n->frames = frames; n->pins = 0; n->tag = -1; n->seed = 0;
    return (int)(n - x->nodes);
  }
  return STEP_NULL;
}
// A node whose board was let go is played again from its parent. The replay
// must land on the same frame, or the port is not deterministic.
static Board *ensureBoard(Ctx *x, int i) {
  Node *n = NODE(x, i);
  if (n->fromPrev) return ensureBoard(x, n->prev);   // never kept: the parent's may be let go
  if (n->st) return n->st;
  if (n->prev < 0) return 0;
  int32_t t = n->t, mk = n->mk, mr = n->mr, mc = n->mc, frames = n->frames, prev = n->prev;
  int r = advance(x, prev, mk, mr, mc, frames);
  if (r < 0) return 0;
  Node *m = NODE(x, r), *o = NODE(x, i);
  Board *b = m->st;
  m->st = 0; x->n--;   // the replay was the last node made
  if (m->t != t) { nb_free(b); return 0; }
  o->st = b;
  return b;
}
// ensureBoard for the threads: the replay's node is left where it was made
// (other threads are making theirs), its board moved to node i.
static int replayBoard(Ctx *x, int i) {
  Node *n = NODE(x, i);
  if (n->fromPrev || n->st) return 1;
  if (n->prev < 0) return 0;
  int32_t t = n->t;
  int r = advance(x, n->prev, n->mk, n->mr, n->mc, n->frames);
  if (r < 0) return 0;
  Node *m = NODE(x, r);
  Board *b = m->st;
  m->st = 0;
  if (m->t != t) { nb_free(b); return 0; }
  NODE(x, i)->st = b;
  return 1;
}
static void dropBoard(Ctx *x, int i) {
  Node *n = NODE(x, i);
  if (n->prev < 0 || n->pins) return;          // the root and pinned nodes keep theirs
  if (n->fromPrev) return;
  if (n->st) { nb_free(n->st); n->st = 0; }
}

// The boards of the n nodes in the io body let go: a node read again is
// played again from its parent. Returns n, or -1.
EXPORT(ns_drop) int ns_drop(Ctx *x, int n) {
  if (n < 0 || n > NBODY) return -1;
  for (int i = 0; i < n; i++) { int k = ioBody[i]; if (k < 0 || k >= x->n) return -1; dropBoard(x, k); }
  return n;
}
// ---- nodes from JS
// The root: the board in the io buffers (nb_load's wire), a raise in hand,
// garbage on its way (io body after the board: at, width, height, isChain).
// rootWhy: why the last root was refused -- 1000 + the board's err flags
// (nb_load), 2 no node, 3 too many arrivals, 4 a panel the key cannot hold.
static int32_t rootWhy;
EXPORT(ns_root_why) int ns_root_why(void) { return rootWhy; }
EXPORT(ns_root) int ns_root(Ctx *x, int holdLeft, int holdStarted, int narr, int fresh) {
  Board *b = nb_new();
  int le = b ? nb_load(b) : -1;
  if (!b || le) { if (b) nb_free(b); rootWhy = 1000 + le; return STEP_ERR; }
  Node *n = newNode(x);
  if (!n) { rootWhy = 2; return STEP_ERR; }
  int32_t used = nb_save(b);   // the body's length, to find the arrivals after it
  if (narr > MAXARR) { rootWhy = 3; return STEP_ERR; }
  n->st = b; n->t = 0; n->holdLeft = holdLeft; n->holdStarted = holdStarted; n->fresh = fresh; n->narr = narr;
  for (int i = 0; i < narr; i++) {
    const int32_t *a = ioBody + used + 5 * i;
    n->arr[i].at = a[0]; n->arr[i].width = a[1]; n->arr[i].height = a[2]; n->arr[i].isChain = a[3]; n->arr[i].isMetal = a[4];
  }
  readBoard(n, b);
  // A new search: no line of it has broken garbage yet.
  x->rootBrk = n->brk;
  for (int i = 0; i < x->tagCap; i++) x->brkAt[i] = -1;
  if (n->err) rootWhy = 4;
  return n->err ? STEP_ERR : (int)(n - x->nodes);
}
EXPORT(ns_step) int ns_step(Ctx *x, int pi, int kind, int mr, int mc, int until) { x->steps++; return lineStep(x, pi, kind, mr, mc, until); }
EXPORT(ns_advance) int ns_advance(Ctx *x, int pi, int kind, int mr, int mc, int frames) { return advance(x, pi, kind, mr, mc, frames); }
EXPORT(ns_dead_at) int ns_dead_at(void) { return deadAt; }
// Frames played (steps 0) or steps made per step kind 0..4, on every thread;
// kinds 5..8 the frames played full, quiet, jumped and as countdown frames.
// Reading a count resets it.
EXPORT(ns_frame_stats) int ns_frame_stats(int kind, int steps) { return statTake(kind >= 5 ? 16 + ((kind - 5) & 3) : (steps ? 8 : 0) + (kind & 7)); }
// One decision from node pi as keys: the io body gets [keys, raise held,
// raise started] per frame. Returns the frames written, or advance's refusal
// (STEP_NULL, STEP_ERR); a line that dies still gives the keys up to it.
EXPORT(ns_keys) int ns_keys(Ctx *x, int pi, int kind, int mr, int mc, int frames) {
  // a wait given as frames < 0 waits to -frames, as the search's line step does
  if (kind == MK_LONG && frames < 0) frames = longFrames(x, pi, -frames);
  tape = ioBody; tapeN = 0; tapeCap = (int32_t)(sizeof ioBody / sizeof ioBody[0]) / 3;
  int r = advance(x, pi, kind, mr, mc, frames);
  tape = 0;
  if (r == STEP_NULL || r == STEP_ERR) return r;
  return tapeN;
}
EXPORT(ns_node) Node *ns_node(Ctx *x, int i) { return NODE(x, i); }
EXPORT(ns_board) Board *ns_board(Ctx *x, int i) { return ensureBoard(x, i); }
EXPORT(ns_legal) int ns_legal(Ctx *x, int i) { Board *b = ensureBoard(x, i); return b ? legalSwaps(b, ioBody) : -1; }
EXPORT(ns_steps) int ns_steps(Ctx *x) { int s = x->steps; x->steps = 0; return s; }
EXPORT(ns_pin) void ns_pin(Ctx *x, int i, int d) { NODE(x, i)->pins += d; }
// Where each field of a Node is, for native.js to read them in place.
#define NODE_FIELDS(X) X(t) X(holdLeft) X(holdStarted) X(fresh) X(dead) X(fromPrev) X(narr) X(tag) X(prev) X(mk) X(mr) X(mc) \
  X(seed) X(pins) X(held) X(garb) X(top) X(pos0) X(pos1) X(stopTime) X(preStopTime) X(shakeTime) X(displacement) X(speed) X(keyn)
#define NOFF1(f) (int)(unsigned long)&((Node *)0)->f,
#define NNAME1(f) #f,
static const int nodeOffs[] = { NODE_FIELDS(NOFF1) (int)(unsigned long)&((Node *)0)->riseTimer, (int)(unsigned long)&((Node *)0)->arr, (int)(unsigned long)&((Node *)0)->key, (int)sizeof(Node) };
static const char *nodeNames[] = { NODE_FIELDS(NNAME1) "riseTimer", "arr", "key", "size", 0 };
EXPORT(ns_field_off) int ns_field_off(int i) { return nodeOffs[i]; }
EXPORT(ns_field_name) const char *ns_field_name(int i) { return nodeNames[i]; }
// The node's grid (puyocpu.js engineGrid): rows 0..height+1, columns 0..6,
// 0 empty, -2 garbage, else the colour; into the io body.
#ifdef TOUCH_SCORE
// survivor_shared.js touchScore on node boards, from ns_grid's cells: the io
// body holds n node indices; out, per node, its score and its key's hash.
// Returns n, or -1 for a board lost.
static int32_t gridCell(const Board *b, int r, int c) {
  if (r >= b->nrows) return 0;
  const int32_t *f = b->p[r][c].f;
  return f[COLOR] == 0 ? 0 : f[ISGARBAGE] ? -2 : f[COLOR];
}
static int vreserve(Vec *v, int32_t n);
EXPORT(ns_touch) int ns_touch(Ctx *x, int n) {
  static Vec ids;
  if (n < 0 || 2 * n > NBODY || !vreserve(&ids, n)) return -1;
  for (int i = 0; i < n; i++) ids.a[i] = ioBody[i];
  for (int i = 0; i < n; i++) {
    int k = ids.a[i];
    if (k < 0 || k >= x->n) return -1;
    Board *b = ensureBoard(x, k);
    if (!b) return -1;
    int R = b->height + 2, G = 0, r, c, top[W + 2], hi = 0;
    int32_t s = 0;
    for (r = 1; r < R && !G; r++) for (c = 1; c <= W; c++) if (gridCell(b, r, c) < 0) { G = r; break; }
    if (G) {
      for (c = 1; c <= W; c++) { int t = 0; for (r = 1; r < G; r++) if (gridCell(b, r, c) > 0) t = r; top[c] = t; if (t > hi) hi = t; }
      for (c = 1; c <= W; c++) s -= (hi - top[c]) * (hi - top[c]);
      int u = G - 1;
      for (c = 1; c <= W; c++) {
        if (top[c] != u) continue;
        if (u > 1 && gridCell(b, u - 1, c) == gridCell(b, u, c)) s += 4;
        if (c < W && top[c + 1] == u && gridCell(b, u, c + 1) == gridCell(b, u, c)) s += 3;
      }
    }
    ioBody[2 * i] = s; ioBody[2 * i + 1] = (int32_t)NODE(x, k)->hash;
  }
  return n;
}
#endif
EXPORT(ns_grid) int ns_grid(Ctx *x, int i) {
  Board *b = ensureBoard(x, i);
  if (!b) return -1;
  int k = 0;
  for (int r = 0; r <= b->height + 1; r++)
    for (int c = 0; c <= W; c++) {
      int32_t v = 0;
      if (c && r < b->nrows) { const int32_t *f = b->p[r][c].f; v = f[COLOR] == 0 ? 0 : f[ISGARBAGE] ? -2 : f[COLOR]; }
      ioBody[k++] = v;
    }
  return b->height;
}

// ---- the level loop (puyocpu.js _survivalSearch, breadth first)
// 1: stop, the question is no longer wanted (LOOP_ABORTED); 2: out of time,
// end as if the budget ran out.
extern int abort_poll(void) __attribute__((import_module("env"), import_name("abort_poll")));
static int vreserve(Vec *v, int32_t n) {
  if (n <= v->cap) return 1;
  int32_t cap = v->cap ? v->cap : 256;
  while (cap < n) cap *= 2;
  int32_t *a = (int32_t *)grab((unsigned long)cap * 4);
  if (!a) return 0;
  if (v->n) memcpy(a, v->a, (unsigned long)v->n * 4);
  v->a = a; v->cap = cap;
  return 1;
}
static int vpush(Vec *v, int32_t x) { if (!vreserve(v, v->n + 1)) return 0; v->a[v->n++] = x; return 1; }
EXPORT(ns_tags) int32_t *ns_tags(Ctx *x, int ntags) {
  if (ntags > x->tagCap) {
    int32_t cap = ntags < 64 ? 64 : ntags * 2;
    int32_t *m = (int32_t *)grab((unsigned long)cap * 4 * 8);
    if (!m) return 0;
    x->verdict = m; x->proofs = m + cap; x->weak = m + 2 * cap; x->reach = m + 3 * cap; x->reachSet = m + 4 * cap;
    x->far = m + 5 * cap; x->per = m + 6 * cap; x->brkAt = m + 7 * cap; x->tagCap = cap;
    for (int i = 0; i < cap; i++) x->brkAt[i] = -1;
  }
  x->ntags = ntags;
  return x->verdict;
}
EXPORT(ns_tag_stride) int ns_tag_stride(Ctx *x) { return x->tagCap; }
// The first frame a live line of the move tagged `tag` breaks garbage, -1 for none.
EXPORT(ns_break_at) int ns_break_at(Ctx *x, int tag) { return tag >= 0 && tag < x->tagCap ? x->brkAt[tag] : -1; }
EXPORT(ns_level) int32_t *ns_level(Ctx *x, int n) { if (!vreserve(&x->level, n)) return 0; x->level.n = n; return x->level.a; }
EXPORT(ns_level_n) int ns_level_n(Ctx *x) { return x->level.n; }
EXPORT(ns_set_tag) void ns_set_tag(Ctx *x, int i, int tag, int seed) { NODE(x, i)->tag = tag; NODE(x, i)->seed = seed; }
// A node's board is let go when nothing holds it: not in the level being
// expanded or the one being built, not the proof, the fallback or the
// furthest line of its move.
// While a phase runs a worker may be playing from the board, so it is freed
// at the phase's end (finishPhase); with no room to note it, it is kept.
static void release(Ctx *x, int i) {
  Node *n = NODE(x, i);
  if (n->pins || n->live) return;
  if (x->par) { vpush(&x->later, i); return; }
  dropBoard(x, i);
}
static void pin(Ctx *x, int32_t *slot, int i) {
  int old = *slot;
  *slot = i;
  if (i >= 0) NODE(x, i)->pins++;
  if (old >= 0) { NODE(x, old)->pins--; release(x, old); }
}
static int better(Ctx *x, int32_t a, int32_t b) {
  Node *p = NODE(x, a), *q = NODE(x, b);
  int32_t d = (q->t + q->held) - (p->t + p->held);
  if (d) return d;
  if (p->garb != q->garb) return p->garb - q->garb;
  return p->top - q->top;
}
// Stable, as Array.prototype.sort is: better's order, packed with each
// node's place into one key -- t + held falling, then garb, then top, then
// place, rising -- so the sort reads no node. Past what a key holds, better.
static int sortBetter(Ctx *x, int32_t *a, int32_t n) {
  if (n < 2) return 1;
  static LOCAL unsigned long long *k64, *t64; static LOCAL int32_t cap64;
  static LOCAL int32_t *orig;
  int packed = n < (1 << 20);
  if (packed && n > cap64) {
    int32_t c = n * 2;
    k64 = (unsigned long long *)grab((unsigned long)c * 8); t64 = (unsigned long long *)grab((unsigned long)c * 8); orig = (int32_t *)grab((unsigned long)c * 4);
    if (!k64 || !t64 || !orig) return 0;
    cap64 = c;
  }
  for (int32_t i = 0; packed && i < n; i++) {
    Node *p = NODE(x, a[i]);
    int32_t th = p->t + p->held;
    if (th < 0 || th >= (1 << 20) || p->garb < 0 || p->garb >= 1024 || p->top < 0 || p->top >= 64) { packed = 0; break; }
    k64[i] = ((unsigned long long)((1 << 20) - 1 - th) << 36) | ((unsigned long long)p->garb << 26) | ((unsigned long long)p->top << 20) | (unsigned long long)i;
    orig[i] = a[i];
  }
  if (packed) {
    for (int32_t w = 1; w < n; w *= 2) {
      for (int32_t lo = 0; lo < n; lo += 2 * w) {
        int32_t mid = lo + w < n ? lo + w : n, hi = lo + 2 * w < n ? lo + 2 * w : n, i = lo, j = mid, k = lo;
        while (i < mid && j < hi) t64[k++] = k64[j] < k64[i] ? k64[j++] : k64[i++];
        while (i < mid) t64[k++] = k64[i++];
        while (j < hi) t64[k++] = k64[j++];
      }
      unsigned long long *sw = k64; k64 = t64; t64 = sw;
    }
    for (int32_t i = 0; i < n; i++) a[i] = orig[k64[i] & ((1 << 20) - 1)];
    return 1;
  }
  if (!vreserve(&x->tmp, n)) return 0;
  int32_t *t = x->tmp.a;
  for (int32_t w = 1; w < n; w *= 2) {
    for (int32_t lo = 0; lo < n; lo += 2 * w) {
      int32_t mid = lo + w < n ? lo + w : n, hi = lo + 2 * w < n ? lo + 2 * w : n, i = lo, j = mid, k = lo;
      while (i < mid && j < hi) t[k++] = better(x, a[j], a[i]) < 0 ? a[j++] : a[i++];
      while (i < mid) t[k++] = a[i++];
      while (j < hi) t[k++] = a[j++];
    }
    for (int32_t i = 0; i < n; i++) a[i] = t[i];
  }
  return 1;
}
static int sameKey(Node *a, Node *b) {
  if (a->hash != b->hash || a->tag != b->tag || a->held != b->held || a->pos0 != b->pos0 || a->pos1 != b->pos1 || a->keyn != b->keyn) return 0;
  for (int i = 0; i < a->keyn; i++) if (a->key[i] != b->key[i]) return 0;
  return 1;
}
static uint32_t seenHash(Node *n) {
  uint32_t h = n->hash;
  h = (h ^ (uint32_t)n->tag) * 16777619u; h = (h ^ (uint32_t)n->held) * 16777619u;
  h = (h ^ (uint32_t)n->pos0) * 16777619u; h = (h ^ (uint32_t)n->pos1) * 16777619u;
  return h ^ (h >> 15);
}
// Returns 1 if an equal node was seen this level, else records i.
static int seenBefore(Ctx *x, int i, int32_t *count) {
  if (2 * (*count + 1) > x->seenCap) {
    int32_t cap = x->seenCap ? x->seenCap * 2 : 4096;
    int32_t *t = (int32_t *)grab((unsigned long)cap * 4);
    if (!t) return -1;
    for (int32_t k = 0; k < cap; k++) t[k] = -1;
    for (int32_t k = 0; k < x->seenCap; k++) {
      int32_t v = x->seen[k];
      if (v < 0) continue;
      uint32_t s = seenHash(NODE(x, v)) & (uint32_t)(cap - 1);
      while (t[s] >= 0) s = (s + 1) & (uint32_t)(cap - 1);
      t[s] = v;
    }
    x->seen = t; x->seenCap = cap;
  }
  Node *n = NODE(x, i);
  uint32_t s = seenHash(n) & (uint32_t)(x->seenCap - 1);
  while (x->seen[s] >= 0) {
    if (sameKey(NODE(x, x->seen[s]), n)) return 1;
    s = (s + 1) & (uint32_t)(x->seenCap - 1);
  }
  x->seen[s] = i; (*count)++;
  return 0;
}
static void clearSeen(Ctx *x) { for (int32_t k = 0; k < x->seenCap; k++) x->seen[k] = -1; }
#define LOOP_ABORTED (-10)
// Where the last level loop failed: its source line, and the step's code
// when a step failed (ns_loop_why: line, ns_loop_c: code).
static int32_t loopWhy, loopC;
#define LOOP_FAIL (loopWhy = __LINE__, LOOP_ERR)
EXPORT(ns_loop_why) int ns_loop_why(void) { return loopWhy; }
EXPORT(ns_loop_c) int ns_loop_c(void) { return loopC; }
#define LOOP_ERR (-11)
#define NOTRUN (-99)
// ---- the other threads. A phase is a list of steps (parent, move), each
// written to its own slot; the threads take them in any order, and the level
// loop reads them in its own. What a step makes does not depend on which
// thread made it or when.
static struct {
  int32_t gen, next, ntasks, ack, nworkers;
  Ctx *ctx; int32_t *tasks, *res, *deadAt;   // deadAt: per step, the frame a death was (settles only)
  const int32_t *moves;   // SWAPS_TASK's moves, by slot
  void (*job)(int32_t);   // JOB_TASK's: a whole piece of work, by its index (a host's own, on its own nodes)
} pool;
#ifndef SPIN
#define SPIN 200000
#endif
#define JOB_TASK (-5)      // a task's move: pool.job(t[0]), a whole piece of work on the thread that takes it (startJobs)
#define REPLAY_TASK (-3)   // a task's move: play node t[0]'s board again from its parent (replayBoard)
#define SWAPS_TASK (-4)    // a task's move: node t[0]'s t[2] swaps, moves and slots from t[3] (advanceSwaps)
// The most swaps one SWAPS_TASK takes, of a phase of n steps: few enough that
// the phase is four tasks a thread, so a phase of one parent's swaps still
// goes to every thread.
#define SWAPS_CAP(n) imin(MAXWALK, imax(4, (n) / (4 * (pool.nworkers + 1))))
#define ADVANCE_TASK (-1000)   // a task's move at or below: ns_advance_many's, ((row << 3 | col) << 3 | kind) = ADVANCE_TASK - mv
// One task of the phase; each result is published (release) once its node is done.
#define PUT(slot, v) __atomic_store_n(&pool.res[slot], (v), __ATOMIC_RELEASE)
static void runTask(int32_t i) {
  Ctx *x = pool.ctx;
  const int32_t *t = pool.tasks + 4 * i;
  int32_t mv = t[1];
  if (mv == REPLAY_TASK) { PUT(t[3], replayBoard(x, t[0]) ? 0 : -1); return; }
  if (mv == JOB_TASK) { pool.job(t[0]); PUT(t[3], 0); return; }
#ifdef SHARED_WALK
  if (mv == SWAPS_TASK) {
    int32_t outs[MAXWALK], deads[MAXWALK], o = t[3];
    advanceSwaps(x, t[0], t[2], pool.moves + o, outs, deads);
    for (int q = 0; q < t[2]; q++) {
      int32_t r = outs[q];
      if (pool.deadAt) { pool.deadAt[o + q] = r == STEP_DEAD ? deads[q] : 0; PUT(o + q, r); continue; }   // ns_advance_many: kept
      if (r == STEP_DEAD) r = STEP_NULL;   // lineStep: a swap that dies is no move
      if (r >= 0) dropBoard(x, r);
      PUT(o + q, r);
    }
    return;
  }
#endif
  if (mv <= ADVANCE_TASK) {
    // ns_advance_many: the step's board is read straight after, so kept.
    int32_t m = ADVANCE_TASK - mv, r = advance(x, t[0], m & 7, CR(m >> 3), CC(m >> 3), t[2]);
    if (pool.deadAt) pool.deadAt[t[3]] = r == STEP_DEAD ? deadAt : 0;
    PUT(t[3], r);
    return;
  }
  int32_t r = mv == -1 ? lineStep(x, t[0], MK_LONG, 0, 0, t[2])
            : mv == -2 ? lineStep(x, t[0], MK_HOLD, 0, 0, 0)
            : lineStep(x, t[0], MK_SWAP, CR(mv), CC(mv), 0);
  // A step's board is not read till its node is expanded: replayed then.
  if (r >= 0) dropBoard(x, r);
  PUT(t[3], r);
}
// OUT OF TIME (abort_poll 2) in a level loop's first phase (cutOK): the
// searching thread takes no more of its tasks, nor does any other, and the
// loop ends as if its budget ran out (cutHit). A task not run leaves its
// slot as it was.
static int cutOK, cutHit;
static void runTasks(void) {
  for (int32_t n = pool.ntasks, polled = 0;;) {
    if (cutOK && thId == 0 && ++polled >= 16) {
      polled = 0;
      if (abort_poll() == 2) { cutHit = 1; __atomic_store_n(&pool.next, n, __ATOMIC_SEQ_CST); break; }
    }
    int32_t i = __atomic_fetch_add(&pool.next, 1, __ATOMIC_SEQ_CST);
    if (i >= n) break;
    runTask(i);
  }
}
// A worker's life: wait for a phase, take steps until there are none, say so. The wait and the wake are wasm's atomics, or a native
// host's own (gambit/native.c: a futex).
// (the pool told to end -- a native host's instance quitting, gambit/native.c gn_quit: each worker leaves its loop)
static int32_t poolQuit;
static void poolEnd(void) {
  __atomic_store_n(&poolQuit, 1, __ATOMIC_SEQ_CST);
  __atomic_add_fetch(&pool.gen, 1, __ATOMIC_SEQ_CST);
  __builtin_wasm_memory_atomic_notify(&pool.gen, -1);
}
// THE SIDE BATCH: steps a search batches while jobs hold the pool (startJobs), taken by the searching thread and by every worker whose
// jobs are done, until the jobs' phase ends (finishPhase closes it). A task is claimed off one word, the batch's number and the next
// task, by compare-and-swap: a worker late from one batch never takes a task of the next.
static struct { Ctx *ctx; const int32_t *tasks; int32_t *res, *dead; int32_t n, done, gen, open; long long word; } side;
static void sideTask(int32_t i) {
  const int32_t *t = side.tasks + 4 * i;
  int32_t m = ADVANCE_TASK - t[1], r = advance(side.ctx, t[0], m & 7, CR(m >> 3), CC(m >> 3), t[2]);
  if (side.dead) side.dead[t[3]] = r == STEP_DEAD ? deadAt : 0;
  __atomic_store_n(&side.res[t[3]], r, __ATOMIC_RELEASE);
  __atomic_add_fetch(&side.done, 1, __ATOMIC_ACQ_REL);
}
static int32_t sideTake(int32_t g) {
  long long w = __atomic_load_n(&side.word, __ATOMIC_ACQUIRE);
  for (;;) {
    if ((int32_t)(w >> 32) != g || (int32_t)(w & 0xffffffff) >= __atomic_load_n(&side.n, __ATOMIC_ACQUIRE)) return -1;
    if (__atomic_compare_exchange_n(&side.word, &w, w + 1, 0, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)) return (int32_t)(w & 0xffffffff);
  }
}
#define SIDE_SPIN 2000
static void sideHelp(void) {
  for (;;) {
    int32_t g = __atomic_load_n(&side.gen, __ATOMIC_ACQUIRE);
    if (!__atomic_load_n(&side.open, __ATOMIC_ACQUIRE)) return;
    if (g & 1) { int32_t i; while ((i = sideTake(g)) >= 0) sideTask(i); }
    for (int spin = 0; spin < SIDE_SPIN && __atomic_load_n(&side.gen, __ATOMIC_ACQUIRE) == g; spin++) {}
    while (__atomic_load_n(&side.gen, __ATOMIC_ACQUIRE) == g) __builtin_wasm_memory_atomic_wait32(&side.gen, g, -1);
  }
}
static void sideClose(void) {
  if (!__atomic_load_n(&side.open, __ATOMIC_ACQUIRE)) return;
  __atomic_store_n(&side.open, 0, __ATOMIC_RELEASE);
  __atomic_add_fetch(&side.gen, 2, __ATOMIC_ACQ_REL);
  __builtin_wasm_memory_atomic_notify(&side.gen, (unsigned)-1);
}
static void workerLoop(void) {
  int32_t last = __atomic_load_n(&pool.gen, __ATOMIC_SEQ_CST);
  __atomic_add_fetch(&pool.nworkers, 1, __ATOMIC_SEQ_CST);
  __builtin_wasm_memory_atomic_notify(&pool.nworkers, 1);
  for (;;) {
    // A phase follows a phase closely: look for it a while before sleeping.
    for (int spin = 0; spin < SPIN && __atomic_load_n(&pool.gen, __ATOMIC_SEQ_CST) == last; spin++) {}
    while (__atomic_load_n(&pool.gen, __ATOMIC_SEQ_CST) == last) __builtin_wasm_memory_atomic_wait32(&pool.gen, last, -1);
    last = __atomic_load_n(&pool.gen, __ATOMIC_SEQ_CST);
    if (__atomic_load_n(&poolQuit, __ATOMIC_SEQ_CST)) return;
    runTasks();
    if (__atomic_load_n(&side.open, __ATOMIC_ACQUIRE)) sideHelp();
    __atomic_add_fetch(&pool.ack, 1, __ATOMIC_SEQ_CST);
    __builtin_wasm_memory_atomic_notify(&pool.ack, 1);
  }
}
#ifdef THREADS
extern void __wasm_init_tls(void *);
// Every instance, the searching one included, before anything else.
EXPORT(ns_thread_init) void ns_thread_init(int id) {
  void *tls = grab(__builtin_wasm_tls_size() + __builtin_wasm_tls_align());
  unsigned long a = __builtin_wasm_tls_align();
  __wasm_init_tls((void *)(((unsigned long)tls + a - 1) & ~(a - 1)));
  thId = id;
}
EXPORT(ns_grab) void *ns_grab(int n) { return grab((unsigned long)n); }
EXPORT(ns_worker_loop) void ns_worker_loop(void) { workerLoop(); }
EXPORT(ns_workers) int ns_workers(void) { return __atomic_load_n(&pool.nworkers, __ATOMIC_SEQ_CST); }
#endif
static int reserveNodes(Ctx *x, int32_t more) {
  if (x->n + more <= x->cap) return 1;
  int32_t cap = x->cap ? x->cap : 1024;
  while (cap < x->n + more) cap *= 2;
  Node *nn = (Node *)grab((unsigned long)cap * sizeof(Node));
  if (!nn) return 0;
  if (x->n) memcpy(nn, x->nodes, (unsigned long)x->n * sizeof(Node));
  if (x->nodes) paRelease(x->nodes, (unsigned long)x->cap * sizeof(Node)); x->nodes = nn; x->cap = cap;   // (the old block's pages given back: nothing reads it again)
  return 1;
}
#define TASK_COST(c_, k_) ((k_)[1] == -1 ? (k_)[2] - NODE(c_, (k_)[0])->t : (k_)[1] == REPLAY_TASK ? NODE(c_, (k_)[0])->t - NODE(c_, NODE(c_, (k_)[0])->prev)->t : (k_)[1] == SWAPS_TASK ? 12 * (k_)[2] : 0)
// A phase's tasks, longest first, so no thread is left with a long one at the
// end: a wait runs to `until`, a replay as long as its step did. Results go to
// each task's own slot, so the order changes nothing else.
static void longestFirst(Ctx *x, Vec *tasks) {
  int32_t n = tasks->n / 4, *a = tasks->a;
  for (int32_t i = 1; i < n; i++) {
    int32_t t[4] = { a[4 * i], a[4 * i + 1], a[4 * i + 2], a[4 * i + 3] }, c = TASK_COST(x, t), j = i;
    while (j > 0) { int32_t *p = a + 4 * (j - 1); if (TASK_COST(x, p) >= c) break; for (int q = 0; q < 4; q++) p[4 + q] = p[q]; j--; }
    for (int q = 0; q < 4; q++) a[4 * j + q] = t[q];
  }
}
// A phase: its steps handed to every thread (startPhase), this thread
// joining in and back when all are done (finishPhase). `extra`: nodes past
// the phase's own that this thread may make meanwhile.
static int startPhase(Ctx *x, Vec *tasks, int32_t *res, int32_t extra) {
  int32_t n = tasks->n / 4, w = pool.nworkers, need = 0;
  if (!n) return 1;
  for (int32_t i = 0; i < n; i++) need += tasks->a[4 * i + 1] == SWAPS_TASK ? tasks->a[4 * i + 2] : 1;   // a node a move
  if (!reserveNodes(x, need + extra)) return 0;
  // Boards for the workers, from this thread's spares, so memory goes round.
  int32_t each = need / (w + 1) + 4;
  for (int k = 1; k <= w && k < MAXTHREADS; k++)
    while (freeCount(k) < each && freeOf(0)) {
      Board *b = freeOf(0); freeOf(0) = *(Board **)b; freeCount(0)--;
      *(Board **)b = freeOf(k); freeOf(k) = b; freeCount(k)++;
    }
  // the rest past this thread's share are SPARES, for whichever thread runs short
  // (under the spares' lock: a thread outside the pool may be taking one)
  while (__atomic_exchange_n(&spareLock, 1, __ATOMIC_ACQUIRE)) {}
  while (freeCount(0) > each) {
    Board *b = freeOf(0); freeOf(0) = *(Board **)b; freeCount(0)--;
    *(Board **)b = spareOf; spareOf = b; __atomic_fetch_add(&spareCount, 1, __ATOMIC_RELAXED);
  }
  __atomic_store_n(&spareLock, 0, __ATOMIC_RELEASE);
  pool.ctx = x; pool.tasks = tasks->a; pool.res = res; pool.ntasks = n; pool.ack = 0;
  x->par = 1;
  __atomic_store_n(&pool.next, 0, __ATOMIC_SEQ_CST);
  __atomic_add_fetch(&pool.gen, 1, __ATOMIC_SEQ_CST);
  __builtin_wasm_memory_atomic_notify(&pool.gen, (unsigned)-1);
  return 1;
}
static void finishPhase(Ctx *x) {
  int32_t a, w = pool.nworkers;
  runTasks();
  sideClose();
  for (int spin = 0; spin < SPIN && __atomic_load_n(&pool.ack, __ATOMIC_SEQ_CST) < w; spin++) {}
  while ((a = __atomic_load_n(&pool.ack, __ATOMIC_SEQ_CST)) < w) __builtin_wasm_memory_atomic_wait32(&pool.ack, a, -1);
  x->par = 0;
  for (int32_t q = 0; q < x->later.n; q++) release(x, x->later.a[q]);
  x->later.n = 0;
  // (under the spares' lock: a thread outside the pool -- Gambit's search between decisions -- may be taking one now)
  while (__atomic_exchange_n(&spareLock, 1, __ATOMIC_ACQUIRE)) {}
  while (spareOf && freeCount(0) < FREE_CAP) { Board *b = spareOf; spareOf = *(Board **)b; __atomic_fetch_sub(&spareCount, 1, __ATOMIC_RELAXED); *(Board **)b = freeOf(0); freeOf(0) = b; freeCount(0)++; }
  __atomic_store_n(&spareLock, 0, __ATOMIC_RELEASE);
  if (x->n > x->cap) x->n = x->cap;
}
static int runPhase(Ctx *x, Vec *tasks, int32_t *res) {
  if (!tasks->n) return 1;
  if (!startPhase(x, tasks, res, 0)) return 0;
  finishPhase(x);
  return 1;
}
// A slot of a phase still running: this thread takes tasks till it is filled.
#define PENDING (-98)
static int32_t awaitSlot(int32_t *slot) {
  int32_t v;
  while ((v = __atomic_load_n(slot, __ATOMIC_ACQUIRE)) == PENDING) {
    int32_t i = __atomic_fetch_add(&pool.next, 1, __ATOMIC_SEQ_CST);
    if (i < pool.ntasks) runTask(i);
  }
  return v;
}
// JOBS BESIDE THIS THREAD: n whole pieces of work, job(0) .. job(n - 1), handed to the other threads in that order while this one goes on
// with its own (startJobs); jobsDone takes back every job not begun and waits for those begun. Each job works on its own thread's
// nodes (none of x's). While they run the pool is theirs: poolBusy, and no phase is started on it (core/nodes.h stepBatch).
static int32_t poolBusy;
static Vec jobTasks, jobRes;
static int startJobs(Ctx *x, void (*job)(int32_t), int32_t n) {
  if (n <= 0 || pool.nworkers <= 0 || poolBusy) return 0;
  if (!vreserve(&jobTasks, 4 * n) || !vreserve(&jobRes, n)) return 0;
  jobTasks.n = 0;
  for (int32_t i = 0; i < n; i++) { jobTasks.a[jobTasks.n++] = i; jobTasks.a[jobTasks.n++] = JOB_TASK; jobTasks.a[jobTasks.n++] = 0; jobTasks.a[jobTasks.n++] = i; jobRes.a[i] = PENDING; }
  pool.job = job;
  __atomic_store_n(&side.open, 1, __ATOMIC_RELEASE);
  if (!startPhase(x, &jobTasks, jobRes.a, 0)) { pool.job = 0; sideClose(); return 0; }
  __atomic_store_n(&poolBusy, 1, __ATOMIC_RELEASE);
  return 1;
}
// A batch while jobs hold the pool: published to the side, taken here and by the workers done with their jobs, back when all are made.
static int sideBatch(Ctx *x, Vec *tasks, int32_t *res, int32_t *dead) {
  int32_t n = tasks->n / 4;
  if (!n) return 1;
  if (!__atomic_load_n(&side.open, __ATOMIC_ACQUIRE) || !reserveNodes(x, n)) return 0;
  x->par = 1;
  side.ctx = x; side.tasks = tasks->a; side.res = res; side.dead = dead; side.done = 0;
  __atomic_store_n(&side.n, n, __ATOMIC_RELEASE);
  int32_t g = __atomic_load_n(&side.gen, __ATOMIC_ACQUIRE) + 1;
  __atomic_store_n(&side.word, (long long)g << 32, __ATOMIC_RELEASE);
  __atomic_store_n(&side.gen, g, __ATOMIC_RELEASE);
  __builtin_wasm_memory_atomic_notify(&side.gen, (unsigned)-1);
  int32_t i;
  while ((i = sideTake(g)) >= 0) sideTask(i);
  while (__atomic_load_n(&side.done, __ATOMIC_ACQUIRE) < n) {}
  __atomic_store_n(&side.gen, g + 1, __ATOMIC_RELEASE);
  x->par = 0;
  for (int32_t q = 0; q < x->later.n; q++) release(x, x->later.a[q]);
  x->later.n = 0;
  if (x->n > x->cap) x->n = x->cap;
  return 1;
}
static void jobsDone(Ctx *x) {
  if (!poolBusy) return;
  __atomic_store_n(&pool.next, pool.ntasks, __ATOMIC_SEQ_CST);   // (the jobs not begun: begun by no thread)
  finishPhase(x);
  pool.job = 0; __atomic_store_n(&poolBusy, 0, __ATOMIC_RELEASE);
}
// Steps on every thread: the io body holds n records (parent, kind, row,
// col, frames), each the step ns_advance would make from them. Out, in the io
// body, per step: the node, or -1 refused, or -2; the frame it died on; the
// node's frame; its garbage rows broken. Returns n, or -3 for no room.
EXPORT(ns_advance_many) int ns_advance_many(Ctx *x, int n) {
  static Vec tasks, res, dead, mvs;
  if (n < 0 || 5 * n > NBODY || !vreserve(&tasks, 4 * n) || !vreserve(&res, n) || !vreserve(&dead, n) || !vreserve(&mvs, n)) return -3;
  tasks.n = 0;
#ifdef SHARED_WALK
  int32_t cap = SWAPS_CAP(n);
#endif
  for (int i = 0; i < n; i++) {
    const int32_t *a = ioBody + 5 * i;
    // Parents first, here: two threads must not replay one board.
    if (a[0] < 0 || a[0] >= x->n || a[1] < 0 || a[1] > MK_SETTLE || a[2] < 0 || a[2] > 255 || a[3] < 0 || a[3] > 7 || !ensureBoard(x, a[0])) return -3;
    mvs.a[i] = (a[2] << 3) | a[3];
#ifdef SHARED_WALK
    // a parent's swaps in a row, one task (advanceSwaps)
    int32_t *g = tasks.n ? tasks.a + tasks.n - 4 : 0;
    if (a[1] == MK_SWAP && a[4] == 0 && i > 0 && ioBody[5 * (i - 1) + 4] == 0 && ioBody[5 * (i - 1)] == a[0] && ioBody[5 * (i - 1) + 1] == MK_SWAP && g && g[0] == a[0] && g[3] + (g[1] == SWAPS_TASK ? g[2] : 1) == i
        && (g[1] == SWAPS_TASK ? g[2] < cap : 1)) {
      if (g[1] != SWAPS_TASK) { g[1] = SWAPS_TASK; g[2] = 1; }
      g[2]++;
      continue;
    }
#endif
    tasks.a[tasks.n++] = a[0]; tasks.a[tasks.n++] = ADVANCE_TASK - ((((a[2] << 3) | a[3]) << 3) | a[1]);
    tasks.a[tasks.n++] = a[4]; tasks.a[tasks.n++] = i;
  }
  pool.deadAt = dead.a; pool.moves = mvs.a;
  int ok = runPhase(x, &tasks, res.a);
  pool.deadAt = 0;
  if (!ok) return -3;
  for (int i = 0; i < n; i++) {
    int32_t r = res.a[i];
    ioBody[4 * i] = r; ioBody[4 * i + 1] = dead.a[i];
    ioBody[4 * i + 2] = r >= 0 ? NODE(x, r)->t : 0; ioBody[4 * i + 3] = r >= 0 ? NODE(x, r)->brk : 0;
  }
  return n;
}
#define CHUNK 384   // parents a chunk: a level of the beam is one, so its phases are few
// The level loop. In: the level (ns_level), each level node's tag and seed
// (ns_set_tag), and per move (ns_tags): verdict (1 proven), proofs, weak,
// reach/reachSet and far, nodes as indices, -1 for none. Out: the same, and
// the level still open. Returns the budget left.
//
// It reads the level a chunk of parents at a time. With threads, a chunk's
// waits are played first, then the other moves of every parent whose wait
// did not prove its move; then the chunk is read in order, exactly as the
// single-threaded loop reads it, a step not played yet being played then.
// Steps played but not read are dropped.
EXPORT(ns_loop) int ns_loop(Ctx *x, int budget, int until, int full, int beam, int quota, int seedsMax) {
  int32_t *verdict = x->verdict, *proofs = x->proofs, *weak = x->weak, *reach = x->reach, *reachSet = x->reachSet, *far = x->far;
  int polled = 0, i, j;
  static Vec poff, res, tasks, proven, parents;
  for (i = 0; i < x->ntags; i++) {
    if (proofs[i] >= 0) NODE(x, proofs[i])->pins++;
    if (weak[i] >= 0) NODE(x, weak[i])->pins++;
    if (far[i] >= 0) NODE(x, far[i])->pins++;
  }
  for (i = 0; i < x->level.n; i++) NODE(x, x->level.a[i])->live = 1;
  if (!vreserve(&proven, x->ntags)) return LOOP_FAIL;
  while (x->level.n && budget > 0) {
    int32_t seenN = 0;
    x->next.n = 0; parents.n = 0;
    clearSeen(x);
    int32_t at = 0;
    while (at < x->level.n && budget > 0) {
      // the chunk: parents at..e, their moves at poff[k]..poff[k+1]
      int32_t e = at, est = 0;
      x->moves.n = 0; poff.n = 0;
      while (e < x->level.n && e - at < CHUNK && (e == at || est < budget)) {
        int ni = x->level.a[e];
        if (!vpush(&poff, x->moves.n)) return LOOP_FAIL;
        if (!verdict[NODE(x, ni)->tag]) {
          Board *nb = ensureBoard(x, ni);
          if (!nb || !vreserve(&x->moves, x->moves.n + 2 + 6 * MAXROWS)) return LOOP_FAIL;
          int32_t *m = x->moves.a + x->moves.n;
          int nm = 2 + legalSwaps(nb, m + 2);
          m[0] = -1; m[1] = -2;
          x->moves.n += nm; est += nm;
        }
        e++;
      }
      if (!vpush(&poff, x->moves.n) || !vreserve(&res, x->moves.n)) return LOOP_FAIL;
      for (j = 0; j < x->moves.n; j++) res.a[j] = NOTRUN;
      int async = 0;   // phase 2 still playing while the chunk is read
#define LEAVE(code) do { if (async) finishPhase(x); return (code); } while (0)
      if (pool.nworkers) {
        tasks.n = 0;
        for (int k = 0; k < e - at; k++) {
          if (poff.a[k + 1] == poff.a[k]) continue;
          int32_t t[4] = { x->level.a[at + k], -1, until, poff.a[k] };
          for (j = 0; j < 4; j++) if (!vpush(&tasks, t[j])) return LOOP_FAIL;
        }
        longestFirst(x, &tasks);
        cutOK = 1; cutHit = 0;
        int ran = runPhase(x, &tasks, res.a);
        cutOK = 0;
        if (!ran) return LOOP_FAIL;
        if (cutHit) budget = 0;
        tasks.n = 0;
        for (i = 0; i < x->ntags; i++) proven.a[i] = verdict[i];
        int32_t cum = 0;
        for (int k = 0; k < e - at && cum < budget; k++) {
          int32_t o = poff.a[k], nm = poff.a[k + 1] - o, tag = NODE(x, x->level.a[at + k])->tag;
          if (!nm || proven.a[tag]) continue;
          cum++;
          int32_t r = res.a[o];
          if (r >= 0 && NODE(x, r)->t >= full && !NODE(x, r)->dead) { proven.a[tag] = 1; continue; }
          for (j = 1; j < nm; j++) {
#ifdef SHARED_WALK
            // the parent's swaps, one task (advanceSwaps)
            if (j == 2) {
              for (int32_t g = 2, cap = SWAPS_CAP(x->moves.n); g < nm; g += cap) {
                int32_t t[4] = { x->level.a[at + k], SWAPS_TASK, imin(cap, nm - g), o + g };
                for (int q = 0; q < 4; q++) if (!vpush(&tasks, t[q])) return LOOP_FAIL;
              }
              break;
            }
#endif
            int32_t t[4] = { x->level.a[at + k], x->moves.a[o + j], 0, o + j };
            for (int q = 0; q < 4; q++) if (!vpush(&tasks, t[q])) return LOOP_FAIL;
          }
          cum += nm - 1;
        }
        // Read while it plays: its tasks in the order they are read, each
        // slot pending till its step is done (awaitSlot).
        pool.moves = x->moves.a;
        for (int32_t q = 0; q < tasks.n; q += 4) {
          int32_t *t = tasks.a + q, cnt = t[1] == SWAPS_TASK ? t[2] : 1;
          for (int32_t z = 0; z < cnt; z++) res.a[t[3] + z] = PENDING;
        }
        if (tasks.n) {
          if (!startPhase(x, &tasks, res.a, x->moves.n)) return LOOP_FAIL;
          async = 1;
        }
      }
      int k;
      for (k = 0; k < e - at && budget > 0; k++) {
        int ni = x->level.a[at + k];
        int32_t tag = NODE(x, ni)->tag, o = poff.a[k], nm = poff.a[k + 1] - o;
        if (verdict[tag]) { NODE(x, ni)->live = 0; release(x, ni); continue; }
        for (j = 0; j < nm && budget > 0; j++) {
          budget--;
          if (++polled >= 64) { polled = 0; int ap = abort_poll(); if (ap == 1) LEAVE(LOOP_ABORTED); if (ap == 2) { budget = 0; if (async) __atomic_store_n(&pool.next, pool.ntasks, __ATOMIC_SEQ_CST); break; } }
          int32_t mv = x->moves.a[o + j];
          int c = async ? awaitSlot(&res.a[o + j]) : res.a[o + j];
          if (c == NOTRUN)
            c = mv == -1 ? lineStep(x, ni, MK_LONG, 0, 0, until)
              : mv == -2 ? lineStep(x, ni, MK_HOLD, 0, 0, 0)
              : lineStep(x, ni, MK_SWAP, CR(mv), CC(mv), 0);
          res.a[o + j] = NOTRUN;   // read: nothing to drop
          if (c == STEP_NULL) continue;
          if (c < 0) { loopC = c; LEAVE(LOOP_FAIL); }
          Node *cn = NODE(x, c), *pn = NODE(x, ni);
          cn->tag = tag; cn->seed = pn->seed;
          if (!reachSet[tag] || cn->t > reach[tag]) { reach[tag] = cn->t; reachSet[tag] = 1; pin(x, &far[tag], c); }
          if (cn->t >= full && !cn->dead) { verdict[tag] = 1; pin(x, &proofs[tag], c); break; }
          if (cn->t >= x->surviveFrames && weak[tag] < 0) pin(x, &weak[tag], c);
          // THE EARLIEST BREAK: of the move's live lines, the first frame one breaks garbage.
          if (!cn->dead && cn->brk > x->rootBrk && (x->brkAt[tag] < 0 || cn->t < x->brkAt[tag])) x->brkAt[tag] = cn->t;
          // A child's board is not read till the level is cut to the beam: a
          // child kept is replayed from its parent then.
          dropBoard(x, c);
          if (cn->dead) continue;
          int sb = seenBefore(x, c, &seenN);
          if (sb < 0) LEAVE(LOOP_FAIL);
          if (sb) { release(x, c); continue; }
          if (!vpush(&x->next, c)) LEAVE(LOOP_FAIL);
          cn = NODE(x, c); cn->live = 1;
        }
        NODE(x, ni)->live = 0;
        if (!vpush(&parents, ni)) LEAVE(LOOP_FAIL);
      }
      if (async) { finishPhase(x); async = 0; }
#undef LEAVE
      for (j = 0; j < x->moves.n; j++) if (res.a[j] >= 0) dropBoard(x, res.a[j]);
      // the chunk's parents the budget did not reach
      for (; k < e - at; k++) { NODE(x, x->level.a[at + k])->live = 0; release(x, x->level.a[at + k]); }
      at = e;
    }
    // Parents the budget did not reach are let go too.
    for (; at < x->level.n; at++) { NODE(x, x->level.a[at])->live = 0; release(x, x->level.a[at]); }
    // the level left unexpanded when the budget ran out stays open
    int32_t k = 0;
    for (j = 0; j < x->next.n; j++) {
      int c = x->next.a[j];
      if (verdict[NODE(x, c)->tag]) { NODE(x, c)->live = 0; release(x, c); }
      else x->next.a[k++] = c;
    }
    x->next.n = k;
    if (!sortBetter(x, x->next.a, x->next.n)) return LOOP_FAIL;
    if (!vreserve(&x->keep, x->next.n)) return LOOP_FAIL;
    int32_t *keep = x->keep.a, nk = 0, seeds = 0;
    for (i = 0; i < x->ntags; i++) x->per[i] = 0;
    for (j = 0; j < x->next.n; j++) NODE(x, x->next.a[j])->kept = 0;
    for (j = 0; j < x->next.n && seeds < seedsMax; j++) {
      Node *cn = NODE(x, x->next.a[j]);
      if (cn->seed) { keep[nk++] = x->next.a[j]; cn->kept = 1; seeds++; }
    }
    for (j = 0; j < x->next.n; j++) {
      Node *cn = NODE(x, x->next.a[j]);
      if (cn->kept) continue;
      if (x->per[cn->tag] < quota) { x->per[cn->tag]++; keep[nk++] = x->next.a[j]; cn->kept = 1; }
    }
    for (j = 0; j < x->next.n && nk < beam; j++) {
      Node *cn = NODE(x, x->next.a[j]);
      if (!cn->kept && weak[cn->tag] < 0) { keep[nk++] = x->next.a[j]; cn->kept = 1; }
    }
    for (j = 0; j < x->next.n; j++) {
      Node *cn = NODE(x, x->next.a[j]);
      if (!cn->kept) { cn->live = 0; release(x, x->next.a[j]); }
    }
    if (!sortBetter(x, keep + seeds, nk - seeds)) return LOOP_FAIL;
    // The kept nodes' boards, played again from their parents on every thread.
    if (pool.nworkers && nk > 1) {
      tasks.n = 0;
      for (j = 0; j < nk; j++) {
        Node *kn = NODE(x, keep[j]);
        if (kn->st || kn->fromPrev) continue;
        int32_t t[4] = { keep[j], REPLAY_TASK, 0, j };
        for (int q = 0; q < 4; q++) if (!vpush(&tasks, t[q])) return LOOP_ERR;
      }
      longestFirst(x, &tasks);
      if (!vreserve(&res, nk) || !runPhase(x, &tasks, res.a)) return LOOP_ERR;
      keep = x->keep.a;
    }
    for (j = 0; j < nk; j++) if (!ensureBoard(x, keep[j])) return LOOP_ERR;
    for (j = 0; j < parents.n; j++) release(x, parents.a[j]);
    if (!vreserve(&x->level, nk)) return LOOP_ERR;
    for (j = 0; j < nk; j++) x->level.a[j] = keep[j];
    x->level.n = nk;
  }
  for (i = 0; i < x->level.n; i++) NODE(x, x->level.a[i])->live = 0;
  for (i = 0; i < x->ntags; i++) {
    if (proofs[i] >= 0) NODE(x, proofs[i])->pins--;
    if (weak[i] >= 0) NODE(x, weak[i])->pins--;
    if (far[i] >= 0) NODE(x, far[i])->pins--;
  }
  return budget;
}

