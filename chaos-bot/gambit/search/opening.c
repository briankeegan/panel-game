// THE OPENING, PLANNED (plans/gambit-opener.md -- the owner: the opener has the whole board and the most time it will ever have; it plans
// something amazing, with every piece): one beam over set-up sequences, kept from decision to decision through the opening. Each board in
// it is scored by the chain its best trigger sets off (triggerSendOf), then the garbage it sends and the panels it clears; each set-up
// clears nothing. Half the beam is the boards whose trigger's chain is longest, the other half the boards with the most promise (opPot) --
// a chain is built for swaps before any trigger is there. Every decision grows it a level at a time in the time it has (the countdown's is
// the longest), re-rooted under the swap pressed: a path that begins with the swap pressed goes on without it, any other is let go. The
// plan is the path with a trigger the mode's list ranks first, clearing fewest panels among those (opPacier), and its trigger.
#define OPENER_SUM 8     // (the opener's chains add up to this: decide.c)
#define OPENER_LEAST 3   // (the shortest chain that counts toward it)
#define OP_BEAM 48       // the boards a level keeps
#define OP_KIDS 24       // the set-ups tried from each, the nearest the cursor first
#define OP_KIDS_CD 64    // in the countdown, every set-up: the board is still and the time is the countdown's
#define OP_DEPTH 20      // the set-ups a plan may hold
typedef struct { int len; int32_t path[OP_DEPTH]; int32_t sent, cleared, trig, ch, pot, blind, ch2, chx, design; } OpPath;   // design: the designer's, its rows named on the board as it stands   // chx: the chain its fall reaches extended (decide.c opExtendAll)   // blind: the rows dealt, unseen, by its trigger (OP_BLIND)
static OpPath opBeam[OP_BEAM], opNext[OP_BEAM], opBest;
static int opN, opHave;            // the beam's paths, and whether a plan is held
static int32_t opLevels, opGrowMs, opOnPool;   // (the levels the last decision grew, the ms it had, the levels scored on the workers: the log's)
static int32_t opGrewLen, opGrewCh, opGrewN, opGrewBlind, opGrewCh2;   // (the best plan as the growing left it -- its set-ups, -1 none, and chain -- and the paths kept: the log's, whatever is pressed after)
static int32_t opPressed;          // the plan's set-up the last decision played (0: none) -- the beam is re-rooted under it
static LOCAL Ctx *opCtx;
// (A SWAP THAT CAN SET SOMETHING OFF, read off the cells before it is played: a panel swapped into an empty cell falls and may match
// where it lands, so it is played; else one of the two cells must finish a run of three, across or up and down -- the rest set nothing off
// and are not played)
static int opRun(const Board *b, int r, int c, int32_t col, int skipC) {
  if (col <= 0) return 0;
  int n = 1;
  for (int k = c - 1; k >= 1 && k != skipC && cellAt(b, r, k) == col; k--) n++;
  for (int k = c + 1; k <= W && k != skipC && cellAt(b, r, k) == col; k++) n++;
  if (n >= 3) return 1;
  n = 1;
  for (int q = r - 1; q >= 1 && cellAt(b, q, c) == col; q--) n++;
  for (int q = r + 1; q <= b->height && cellAt(b, q, c) == col; q++) n++;
  return n >= 3;
}
static int opMaySet(const Board *b, int r, int c) {
  int32_t a = cellAt(b, r, c), d = cellAt(b, r, c + 1);
  if (a == 0 || d == 0) return 1;
  if (a < 0 || d < 0 || a == d) return 0;
  return opRun(b, r, c + 1, a, c) || opRun(b, r, c, d, c + 1);
}
// the longest chain one swap sets off from the question's board, of two as long the one sending more -- its chain's slabs and every
// clear's combo garbage (plan.c sentCells): what it sends returned, the swap in *sw, its chain in *chain (0: none sends any)
// A SWAP PRESSED AS THE FRAME LOOP PRESSES IT (judge.c's way, core/nodes.h pressWalk): walked to while the board still settles from the
// last, pressed the first frame the pair can be taken -- waited for a frame at a time while it moves, PRESS_WAIT at most -- and run on
// through what it sets off. A plan timed any other way is a plan the game does not play.
static int opPress(Ctx *x, int n, int32_t sw) {
  for (int k = 0;; k++) {
    int r = step(x, n, MK_SETTLE, CR(sw), CC(sw), 0);
    if (r != STEP_NULL) return r;
    Board *b = ensureBoard(x, n);
    if (k >= PRESS_WAIT || !b || !(hasActivePanels(b) || b->swappingCount > 0)) return STEP_NULL;
    int w = step(x, n, MK_LONG, 0, 0, 1);
    if (w < 0) return w;
    if (NODE(x, w)->dead) return STEP_DEAD;
    n = w;
  }
}
static int32_t triggerSendOf(const Question *q, int32_t *sw, int32_t *chain) {
  Ctx *x = cuCtxB = ctxOf(cuCtxB);
  int root = rootOf(x, q);
  if (root < 0) return 0;
  int32_t ms[MAXROWS * W]; int m = swapsOfNode(x, root, ms); int32_t best = 0, bestCh = 0;
  const Board *b0 = ensureBoard(x, root);
  for (int i = 0; i < m && !clockOut(); i++) {
    if (b0 && !opMaySet(b0, CR(ms[i]), CC(ms[i]))) continue;
    int out = opPress(x, root, ms[i]);
    if (!liveNode(x, out)) continue;
    Stats s; int32_t c = 0, ch = 0;
    if (statsOf(x, out, &s)) { c = sentCells(&s); ch = chainOfStats(&s); }
    if (c > 0 && (ch > bestCh || (ch == bestCh && c > best))) { best = c; bestCh = ch; if (sw) *sw = ms[i]; if (chain) *chain = ch; }
  }
  return best;
}
// (A HALF-BUILT CHAIN'S PROMISE: the pairs of one colour side by side or one on the other -- the set-ups a chain is made of before any of
// its links can go off. A path whose board has no trigger yet is kept by it.)
static int32_t opPot(const Board *b) {
  int32_t n = 0;
  for (int r = 1; r <= b->height; r++) for (int c = 1; c <= W; c++) {
    int32_t a = cellAt(b, r, c);
    if (a <= 0) continue;
    if (c < W && cellAt(b, r, c + 1) == a) n++;
    if (r < b->height && cellAt(b, r + 1, c) == a) n++;
  }
  return n;
}
static uint32_t opHash(const Board *b) {
  uint32_t h = 2166136261u;
  for (int r = 1; r <= b->height; r++) for (int c = 1; c <= W; c++) { h ^= (uint32_t)(cellAt(b, r, c) + 16); h *= 16777619u; }
  return h;
}
// (A PLAN'S WORTH -- the owner: don't die, send what I ask: the entry of the mode's list its chain meets; of two meeting the same, the one
// clearing fewer panels, then the longer chain; of two as long, the garbage it sends for the frames it takes -- its swaps walked to from
// the cursor and pressed, then a chain's beginning, OP_FIRE frames; tied, the one sending more)
#define OP_FIRE 120
static int32_t opCurR, opCurC;   // (the cursor on the board the beam is grown on)
static int32_t opFrames(const OpPath *p) {
  int32_t f = OP_FIRE, r = opCurR, c = opCurC;
  for (int k = 0; k <= p->len; k++) {
    int32_t sw = k < p->len ? p->path[k] : p->trig;
    f += (iabs(CR(sw) - r) + iabs(CC(sw) - c)) * cfgCursor + cfgSwapGap; r = CR(sw); c = CC(sw);
  }
  return f;
}
// (the entry of the mode's list a chain meets -- its first; past the list where it meets none)
static int opEntryOf(int32_t ch) {
  for (int i = 0; i < theList.n; i++) if (theList.aim[i].chain.op && test(ch, theList.aim[i].chain)) return i;
  return theList.n;
}
// (A PLAN ON ROWS NOT YET DEALT: the second row the stack rises by is the first unseen one in play -- the first stays dimmed below -- and
// what its panels are is not known when the plan is made; a trigger pressed once it is up fires a chain the panels it brings may spoil)
#define OP_BLIND 2
#define OP_TWO_FROM 4   // (the first chain a second is looked for after: the owner's two 4-chains)
static int opMakesEight(const OpPath *p) { return imax(p->ch, p->chx) >= OPENER_SUM || (p->ch >= OPENER_LEAST && p->ch2 >= OPENER_LEAST && p->ch + p->ch2 >= OPENER_SUM); }
static int opNearEight(const OpPath *p) { return p->ch >= OPENER_LEAST && p->ch2 >= OPENER_LEAST && imax(p->ch, p->chx) + p->ch2 >= OPENER_SUM - 1; }
static int opPacier(const OpPath *a, const OpPath *o) {
  // (a plan whose trigger is pressed on rows that are known first)
  if ((a->blind >= OP_BLIND) != (o->blind >= OP_BLIND)) return a->blind < OP_BLIND;
  // (then a plan that makes the eight: its chain OPENER_SUM alone, or with the chain designed on the board it leaves -- each OPENER_LEAST
  // or more, the two adding up to OPENER_SUM: the owner's 5 and 3, two 4s alike; decide.c opPairAll)
  { int ta = opMakesEight(a), to = opMakesEight(o); if (ta != to) return ta; }
  // (then a plan a link short of it with a chain that counts behind it: the chain falling is extended a link as it falls, the eight
  // made with the next -- before a plan that leaves nothing to follow it, the eight left to the garbage's luck)
  { int ta = opNearEight(a), to = opNearEight(o); if (ta != to) return ta; }
  // (then the chain the fall reaches extended, where the countdown measured it: the owner's eight, one chain grown while it falls)
  { int32_t xa = imax(a->ch, a->chx), xo = imax(o->ch, o->chx); if (xa != xo && (a->chx || o->chx)) return xa > xo; }
  // (the list's entry first -- what the mode asks; of two meeting the same, the longer chain, then the one pressed sooner -- a chain
  // falling is a board that cannot top out, so the sooner it fires the sooner the board is safe -- then the one that clears fewer
  // panels, the board's own to dig with when the garbage comes)
  int ea = opEntryOf(a->ch), eo = opEntryOf(o->ch);
  if (ea != eo) return ea < eo;
  if (a->ch != o->ch) return a->ch > o->ch;
  { int32_t fa = opFrames(a), fo = opFrames(o); if (fa != fo) return fa < fo; }
  if (a->cleared != o->cleared && a->cleared > 0 && o->cleared > 0) return a->cleared < o->cleared;
  int64_t x = (int64_t)a->sent * opFrames(o), y = (int64_t)o->sent * opFrames(a);
  if (x != y) return x > y;
  if (a->sent != o->sent) return a->sent > o->sent;
  return a->len < o->len;
}
static int32_t opClearedOf(const Question *q, int32_t sw) {
  Ctx *x = cuCtxB = ctxOf(cuCtxB);
  int root = rootOf(x, q);
  if (root < 0 || !sw) return 0;
  int out = opPress(x, root, sw);
  Stats s; return liveNode(x, out) && statsOf(x, out, &s) ? s.cleared : 0;
}
// a path played from the question's board, its set-ups each clearing nothing: the node it ends on, -1 where one is not there to press
static int opReplay(Ctx *x, int root, const OpPath *p) {
  int at = root;
  for (int k = 0; k < p->len && !clockOut(); k++) {
    int out = opPress(x, at, p->path[k]);
    if (!liveNode(x, out)) return -1;
    Stats st; if (statsOf(x, out, &st) && st.cleared > 0) return -1;
    at = out;
  }
  return clockOut() ? -1 : at;
}
// a board's trigger, scored into p (sent, cleared, trig): the question q's board replaced by the node's
static void opScore(const Question *q, Ctx *x, int node, OpPath *p) {
  Board *eb = ensureBoard(x, node);
  p->sent = 0; p->cleared = 0; p->trig = 0; p->ch = 0; p->pot = 0; p->blind = 0; p->ch2 = 0;
  if (!eb) return;
  p->blind = eb->unseenRows - (decQ.b ? decQ.b->unseenRows : q->b->unseenRows);
  p->pot = opPot(eb);
  Question q2 = *q; q2.b = eb; q2.narr = 0; q2.holdLeft = 0; q2.holdStarted = 0;
  int32_t t = 0, ch = 0, c = triggerSendOf(&q2, &t, &ch);
  if (c > 0 && t) {
    p->sent = c; p->trig = t; p->ch = ch; p->cleared = opClearedOf(&q2, t);
  }
}
// (a chain the mode's list asks for: the opener throws nothing smaller -- a short chain only feeds the enemy)
static int opAsked(int32_t ch) {
  for (int i = 0; i < theList.n; i++) if (theList.aim[i].chain.op && test(ch, theList.aim[i].chain)) return 1;
  return 0;
}
// A new game: nothing held
static int32_t opAnchorCol, opAnchorRow, opAnchorId = -1;   // (a panel of the board the beam was grown on that is also on the board as it is: the rows risen since read off it)
static OpPath opByLen[OP_DEPTH + 1]; static uint8_t opByLenHave[OP_DEPTH + 1];
static void openingReset(void) { opN = 0; opHave = 0; opPressed = 0; opAnchorId = -1; memset(opByLenHave, 0, sizeof opByLenHave); }
// (THE BEAM KEPT THROUGH A RISE: the rows the stack has risen since the beam was grown, read off the anchor panel -- NOT_ASKED where it
// is gone -- added to every swap of every path, so a plan made a row lower is pressed where its panels now are)
static int32_t opRisen(const Board *b) {
  if (opAnchorId < 0) return NOT_ASKED;
  for (int r = 1; r < b->nrows; r++) if (b->p[r][opAnchorCol].f[ID] == opAnchorId) return r - opAnchorRow;
  return NOT_ASKED;
}
// (the lowest panel of the board grown on that the board as it is, `now`, also holds in that column: a board grown on rows not yet
// risen -- the opening's raise -- is anchored above them, on a panel the next decision's board has)
static int opHolds(const Board *b, int32_t c, int32_t id) {
  for (int r = 1; r < b->nrows; r++) if (b->p[r][c].f[ID] == id) return 1;
  return 0;
}
static void opAnchor(const Board *b, const Board *now) {
  opAnchorId = -1;
  for (int r = 1; r < b->nrows; r++) for (int c = 1; c <= W; c++) {
    int32_t id = b->p[r][c].f[ID];
    if (id > 0 && cellAt(b, r, c) != 0 && opHolds(now, c, id)) { opAnchorCol = c; opAnchorRow = r; opAnchorId = id; return; }
  }
}
// ONE PATH'S SET-UPS SCORED (opKids, a job: on whichever thread takes it, on that thread's own nodes): the path's board opJPar[p], each
// of its set-ups opJSw[p] played on it, those setting nothing off scored by their best trigger and their promise into opJRes[p]. Its
// own share, the decision's (opJEnd); the thread's clock as it was after.
typedef struct { int32_t sw, sent, cleared, trig, ch, pot, blind, ch2; uint32_t h; } OpKid;
static Board opJPar[OP_BEAM];   // (copies: a node's board may be let go before a job reads it)
static int32_t opJSw[OP_BEAM][OP_KIDS_CD], opJN[OP_BEAM], opJGot[OP_BEAM];
static OpKid opJRes[OP_BEAM][OP_KIDS_CD];
static Question opJQ;
static double opJEnd;
static LOCAL Ctx *opJCtx;
static Ctx *opJobCtx;   // (the phase's own: the jobs make nodes only on their threads' contexts)
static void opKids(int32_t p) {
  double sShare = clockShare; int sJob = inJob; int32_t sAb = clockAborted; int64_t sPoll = clockPoll;
  clockShare = opJEnd; inJob = 1; clockAborted = 0; clockPoll = 0;
  int got = 0;
  Ctx *x = opJCtx = ctxOf(opJCtx);
  Question q = opJQ; q.b = &opJPar[p];
  int root = rootOf(x, &q);
  for (int i = 0; root >= 0 && i < opJN[p] && !clockOut(); i++) {
    int32_t sw = opJSw[p][i];
    int out = opPress(x, root, sw);
    if (!liveNode(x, out)) continue;
    Stats st; if (statsOf(x, out, &st) && st.cleared > 0) continue;
    OpPath e; e.len = 0; opScore(&opJQ, x, out, &e);
    const Board *ob = ensureBoard(x, out);
    if (!ob) continue;
    opJRes[p][got++] = (OpKid){ sw, e.sent, e.cleared, e.trig, e.ch, e.pot, e.blind, e.ch2, opHash(ob) };
  }
  opJGot[p] = got;
  clockShare = sShare; inJob = sJob; clockAborted = sAb; clockPoll = sPoll;
}
// every path's set-ups scored: on the workers beside this thread where the pool is free, else here one after another
static void opKidsAll(int n) {
  for (int p = 0; p < n; p++) opJGot[p] = 0;
  if (pool.nworkers > 0 && !poolBusy) {
    if (!opJobCtx) opJobCtx = ctxOf(0);
    __atomic_store_n(&jobStop, 0, __ATOMIC_SEQ_CST);
    if (startJobs(opJobCtx, opKids, n)) { opOnPool++; finishPhase(opJobCtx); pool.job = 0; __atomic_store_n(&poolBusy, 0, __ATOMIC_RELEASE); return; }
  }
  for (int p = 0; p < n && !clockOut(); p++) opKids(p);
}
// (the best plan, and the best of each length -- the shorter ones the decision falls back on where the best does not live)
static int32_t opSightCh, opSightLen;   // (the longest chain of a plan pressed on rows known, and its set-ups: the log's opgrew /s)
static void opConsider(const OpPath *e) {
  if (e->blind < OP_BLIND && e->ch > opSightCh) { opSightCh = e->ch; opSightLen = e->len; }
  if (!opHave || opPacier(e, &opBest)) { opBest = *e; opHave = 1; }
  if (!opByLenHave[e->len] || opPacier(e, &opByLen[e->len])) { opByLen[e->len] = *e; opByLenHave[e->len] = 1; }
}
// THE PLAN GROWN in the time the clock gives: the beam re-rooted under the swap the last decision pressed, every path replayed on the board
// as it is (a path whose set-ups are no longer there is let go), then grown a level at a time. The best plan into opBest.
static void openingGrowIn(const Question *q, const Board *now) {
  Ctx *x = opCtx = ctxOf(opCtx);
  int root = rootOf(x, q);
  if (root < 0) return;
  opCurR = q->b->curRow; opCurC = q->b->curCol;
  // (re-rooted: the paths that began with the swap pressed, without it; the others let go)
  if (opPressed) {
    int m = 0;
    for (int i = 0; i < opN; i++) if (opBeam[i].len > 0 && opBeam[i].path[0] == opPressed) {
      OpPath p = opBeam[i]; for (int k = 1; k < p.len; k++) p.path[k - 1] = p.path[k]; p.len--; opBeam[m++] = p; }
    opN = m; opPressed = 0;
  }
  // (a path moved below the bottom row -- grown on a board risen further than this one -- is let go)
  { int32_t dr = opN ? opRisen(q->b) : 0;
    if (dr == NOT_ASKED) opN = 0;
    else if (dr) {
      int m = 0;
      for (int i = 0; i < opN; i++) {
        OpPath p = opBeam[i]; int ok = 1;
        for (int k = 0; k < p.len; k++) { p.path[k] += dr * 8; if (CR(p.path[k]) < 1) ok = 0; }
        if (p.trig) { p.trig += dr * 8; if (CR(p.trig) < 1) ok = 0; }
        if (ok) opBeam[m++] = p;
      }
      opN = m;
    } }
  opAnchor(q->b, now);
  // (the board as it is: the empty path, and every path still there to press)
  int nodes[OP_BEAM]; int m = 0;
  { OpPath e; memset(&e, 0, sizeof e); opScore(q, x, root, &e); opNext[m] = e; nodes[m++] = root; }
  for (int i = 0; i < opN && m < OP_BEAM && !clockOut(); i++) {
    int at = opReplay(x, root, &opBeam[i]);
    if (at < 0) continue;
    OpPath p = opBeam[i]; opScore(q, x, at, &p);
    opNext[m] = p; nodes[m++] = at;
  }
  if (clockOut()) return;
  opN = m; for (int i = 0; i < m; i++) opBeam[i] = opNext[i];
  opHave = 0; opSightCh = 0; opSightLen = 0; memset(opByLenHave, 0, sizeof opByLenHave);
  for (int i = 0; i < opN; i++) if (opBeam[i].trig) opConsider(&opBeam[i]);
  // (grown a level at a time: every path's set-ups one swap on, the nearest its last swap first, each scored on whichever thread takes
  // its path (opKids); the OP_BEAM best kept and played again here, where the next level grows from them)
  opLevels = 0; opOnPool = 0;
  while (!clockOut()) {
    int np = 0, from[OP_BEAM];
    for (int bi = 0; bi < opN && np < OP_BEAM; bi++) {
      if (opBeam[bi].len >= OP_DEPTH) continue;
      const Board *b0 = ensureBoard(x, nodes[bi]);
      if (!b0) continue;
      int32_t ms[MAXROWS * W]; int mm = swapsOfNode(x, nodes[bi], ms), dd[MAXROWS * W];
      int cr = b0->curRow, cc = b0->curCol;
      if (opBeam[bi].len) { cr = CR(opBeam[bi].path[opBeam[bi].len - 1]); cc = CC(opBeam[bi].path[opBeam[bi].len - 1]); }
      for (int i = 0; i < mm; i++) dd[i] = iabs(CR(ms[i]) - cr) + iabs(CC(ms[i]) - cc);
      for (int i = 1; i < mm; i++) for (int j = i; j > 0 && dd[j] < dd[j - 1]; j--) { int t = dd[j]; dd[j] = dd[j - 1]; dd[j - 1] = t; int32_t u = ms[j]; ms[j] = ms[j - 1]; ms[j - 1] = u; }
      int k = 0;
      for (int i = 0; i < mm && k < (cdAsk ? OP_KIDS_CD : OP_KIDS); i++) { if (opBeam[bi].len == 0 && swapBack(CR(ms[i]), CC(ms[i]), 0)) continue; opJSw[np][k++] = ms[i]; }
      copyBoard(&opJPar[np], b0); opJN[np] = k; from[np++] = bi;
    }
    if (!np) break;
    opJQ = *q; opJQ.narr = 0; opJQ.holdLeft = 0; opJQ.holdStarted = 0; opJEnd = clockShare;
    opKidsAll(np);
    if (clockOut()) break;
    // (the kept: half the beam the kids whose trigger sends the most, the rest those with the most promise -- each board once)
    static int32_t cp[OP_BEAM * OP_KIDS_CD], ci[OP_BEAM * OP_KIDS_CD]; static uint8_t taken[OP_BEAM * OP_KIDS_CD];
    int nc = 0;
    for (int p = 0; p < np; p++) for (int i = 0; i < opJGot[p]; i++) {
      const OpKid *c = &opJRes[p][i]; const OpPath *par = &opBeam[from[p]];
      if (c->trig) {
        OpPath e = *par; e.path[e.len++] = c->sw; e.sent = c->sent; e.cleared = c->cleared; e.trig = c->trig; e.ch = c->ch; e.pot = c->pot; e.blind = c->blind; e.ch2 = c->ch2;
        opConsider(&e); }
      int dup = 0; for (int j = 0; j < nc && !dup; j++) dup = opJRes[cp[j]][ci[j]].h == c->h;
      if (!dup) { cp[nc] = p; ci[nc] = i; taken[nc++] = 0; }
    }
    int nn = 0, kp[OP_BEAM], kk[OP_BEAM];
    for (int half = 0; half < 2; half++) {
      int want = half ? OP_BEAM : OP_BEAM / 2;
      while (nn < want) {
        int w = -1;
        for (int j = 0; j < nc; j++) {
          if (taken[j]) continue;
          const OpKid *c = &opJRes[cp[j]][ci[j]];
          if (!half && !c->trig) continue;
          if (w < 0) { w = j; continue; }
          const OpKid *d = &opJRes[cp[w]][ci[w]];
          if (!half ? ((c->blind < OP_BLIND) != (d->blind < OP_BLIND) ? c->blind < OP_BLIND : c->ch != d->ch ? c->ch > d->ch : c->sent != d->sent ? c->sent > d->sent : c->cleared > d->cleared) : (c->pot != d->pot ? c->pot > d->pot : c->sent > d->sent)) w = j;
        }
        if (w < 0) break;
        taken[w] = 1;
        const OpKid *c = &opJRes[cp[w]][ci[w]];
        opNext[nn] = opBeam[from[cp[w]]]; opNext[nn].path[opNext[nn].len++] = c->sw; opNext[nn].sent = c->sent; opNext[nn].cleared = c->cleared;
        opNext[nn].trig = c->trig; opNext[nn].ch = c->ch; opNext[nn].pot = c->pot; opNext[nn].blind = c->blind; opNext[nn].ch2 = c->ch2; kp[nn] = from[cp[w]]; kk[nn] = c->sw; nn++;
      }
    }
    if (!nn) break;
    // (the kept played again here, from their paths' nodes)
    int m = 0, nodesNext[OP_BEAM];
    for (int i = 0; i < nn && !clockOut(); i++) {
      int out = opPress(x, nodes[kp[i]], kk[i]);
      if (!liveNode(x, out)) continue;
      opNext[m] = opNext[i]; nodesNext[m++] = out;
    }
    if (clockOut() || !m) break;
    opN = m; for (int i = 0; i < m; i++) { opBeam[i] = opNext[i]; nodes[i] = nodesNext[i]; }
    opLevels++;
  }
}
// THE SECOND CHAIN A PLAN LEAVES (the owner: two 4-chains): the plan played and its chain landed, then every set-up swap there and the
// chain its board's best trigger fires -- the best into ch2. Asked of the plans kept once the grow is done, those of OP_TWO_FROM or more.
static int32_t opSecondOf(const Question *q, OpPath *p) {
  static Ctx *sx; Ctx *x = sx = ctxOf(sx);
  int root = rootOf(x, q); if (root < 0) return 0;
  int at = opReplay(x, root, p); if (at < 0) return 0;
  int landed = opPress(x, at, p->trig); if (!liveNode(x, landed)) return 0;
  const Board *lb = ensureBoard(x, landed); if (!lb) return 0;
  Question q2 = *q; q2.b = (Board *)lb; q2.narr = 0; q2.holdLeft = 0; q2.holdStarted = 0;
  int32_t best = 0, t = 0, ch = 0;
  if (triggerSendOf(&q2, &t, &ch) > 0 && t) best = ch;
  int32_t ms[MAXROWS * W]; int mm = swapsOfNode(x, landed, ms);
  for (int i = 0; i < mm && !clockOut(); i++) {
    int o = opPress(x, landed, ms[i]);
    if (!liveNode(x, o)) continue;
    Stats st; if (statsOf(x, o, &st) && st.cleared > 0) continue;
    const Board *ob = ensureBoard(x, o); if (!ob) continue;
    Question q3 = q2; q3.b = (Board *)ob; int32_t t3 = 0, c3 = 0;
    if (triggerSendOf(&q3, &t3, &c3) > 0 && t3 && c3 > best) best = c3;
  }
  return best;
}
static int32_t opSecondBest, opSecondN;   // (the longest second chain the scored plans leave, and how many were scored: the log's)
static void opSecondAll(const Question *q) {
  opSecondBest = -1; opSecondN = 0;
  if (opHave && opBest.ch >= OP_TWO_FROM) { opBest.ch2 = opSecondOf(q, &opBest); opSecondN++; if (opBest.ch2 > opSecondBest) opSecondBest = opBest.ch2; }
  for (int ln = 1; ln <= OP_DEPTH && !clockOut(); ln++) if (opByLenHave[ln] && opByLen[ln].ch >= OP_TWO_FROM) {
    opByLen[ln].ch2 = opSecondOf(q, &opByLen[ln]); opSecondN++; if (opByLen[ln].ch2 > opSecondBest) opSecondBest = opByLen[ln].ch2; }
  // (the best ranked again, the second chain known)
  for (int ln = 1; ln <= OP_DEPTH; ln++) if (opByLenHave[ln] && (!opHave || opPacier(&opByLen[ln], &opBest))) { opBest = opByLen[ln]; opHave = 1; }
  opGrewCh2 = opHave ? opBest.ch2 : 0; opGrewLen = opHave ? opBest.len : -1; opGrewCh = opHave ? opBest.ch : 0;
}
static void openingGrow(const Question *q, const Board *now) {
  openingGrowIn(q, now);
  opGrewLen = opHave ? opBest.len : -1; opGrewCh = opHave ? opBest.ch : 0; opGrewN = opN; opGrewBlind = opHave ? opBest.blind : 0; opGrewCh2 = opHave ? opBest.ch2 : 0;
}
