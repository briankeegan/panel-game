// THE BREAK SEARCH (as Gambit asks it: maxDepth 1, no line kept from the default bot's touch line).
// Garbage on the board, a break is a line after which more garbage is broken than the board left alone breaks by the same frame (a
// popping slab goes on converting whatever is pressed). In order, the first that finds one answers:
//   1. a first swap that breaks;
//   2. resting garbage, nothing popping: THE TOUCH BEAM -- lines kept by how near a break they are (breakNear, then how even the stack
//      under the garbage is), grown a swap a level for TOUCH_DEPTH levels, TOUCH_BEAM wide and then TOUCH_WIDER; the lines the last
//      decision was growing (resume) are played again first and carried on;
//   3. a slab popping (wait: the frames of pop left): a first swap after which the pop's end breaks; then the first of a pair; then the
//      aimed lineup (the colours the converting row turns into, met by pairs on top of their columns); then a first swap leaving a
//      break one swap away once the board has settled; then, the cursor being free, the touch beam on the garbage elsewhere.
// Every line is held to the decision's rules as it is grown (stepOk: each step within the list; firstOk: a first swap that is no swap
// back) and a break is taken only through the shared line check (lineFits). Every step is the clock's: past its share the search
// ends with what it has.

#define TOUCH_DEPTH 12
#define DIVE_N 30        // the beam's lines dived from each level (touchBeam): measured on 1729 lost games' boards, 224 breaks taken where 212 were
#define CHEAP_BREAK 6    // the actions a break may walk for before the level after it is searched for a cheaper one
#define TOUCH_BEAM 30
#define TOUCH_WIDE 100     // TOUCH_WIDER, the one wider beam
#define LONGEST (2 * TOUCH_DEPTH)   // a line carried on to the next decision is shorter than this
#define KEEPN 60                    // the lines carried on
#define LINEUP_BUDGET 400
#define TRIM_MS 5        // the ms a found line is trimmed in, past the search's share (trimPath)
// (the touch beam from its wider beam on, its narrower left to another thread searching the same board: answer.c's wide job)
static LOCAL int32_t touchFrom;
#define LINEUP_DEPTH 8
#define LINEUP_BEAM 12
#define PAIR 5
#define NEAR_MISS 20
#define MAXPATH 32
#define LINEUP_AFTER 30
#define LINEPOOL 8192   // lines one level holds: TOUCH_WIDE x the swaps of a board

typedef struct { int32_t key, n, s, h, len, kept, carried; int32_t path[MAXPATH]; } Line;   // carried: grown from a line the last decision carried on
// (cont: the lines are the frontier of a search of this same board, no cell of it changed since; 2 when that search had its line-ups of
// the popping slab -- breakMovesIn)
typedef struct { int32_t n, cont, len[KEEPN]; int32_t path[KEEPN][MAXPATH]; } Paths;
// THE ANSWER (breakMoves' return): depth 1 with the first swaps that break (moves) and how -- the line (path), the line-up pairs
// (lines, one per first swap found), or depth 0 with the line nearest a break (toward) and the lines to choose among (towards)
typedef struct {
  int32_t depth, nmoves, moves[MAXROWS * W];
  int32_t at, touch, carried, wide, lineup, fresh;   // fresh: found from this board's own first swaps, with lines carried on beside them; lineup: 0 none, 1 the pop's end, 2 a pair, 3 aimed, 4 ready
  int32_t built;                                    // the line breakNear builds (the nearest break walked to)
  int32_t pathLen, path[MAXPATH];
  int32_t pairs[MAXROWS * W][2];                    // lines, beside moves (lineup 2 and 4)
  int32_t towardLen, toward[MAXPATH];
  Paths towards;                                    // keepOut's lines, then toward
  Paths keepOut;                                    // what the next decision carries on
} Broke;

static LOCAL Ctx *breakCtx;
// THE LINES' ROOM: a line carries its own path, so a level's lines are let go once the next level is made -- two arenas a level at a time
// (arena 0 and 1, in turn), and one for what lives through the whole search (the carried lines, the first swaps, the line-ups). A line
// that finds no room ends the search where it is, and says so (Broke.full).
#define LINEARENA 8192
static LOCAL Line *arena[3]; static LOCAL int32_t arenaN[3], linesFull;
static Line *lineIn(int a) {
  if (!arena[a]) arena[a] = (Line *)grab(sizeof(Line) * LINEARENA);
  if (!arena[a] || arenaN[a] >= LINEARENA) { linesFull = 1; return 0; }
  return &arena[a][arenaN[a]++];
}
#define KEEPS 2   // the arena of what lives through the search
#define SEARCH_OUT() (clockOut() || linesFull)
static Line *lineNew(void) { return lineIn(KEEPS); }

// ---- the grid (rows 0..height+1, 0 empty, -2 garbage, else the colour)
static int32_t cellAt(const Board *b, int r, int c) { return r < 0 || r > b->height + 1 || c < 1 || c > W ? 0 : gridCell(b, r, c); }
static int32_t gridLen(const Board *b) { return b->height + 2; }
// the lowest row with garbage, from row 1 (G = grid length when none)
static LOCAL Bits scratchBits;
static int lowestG(const Board *b) { bitsOf(b, &scratchBits); return bitsLowestG(&scratchBits); }
// How uneven the stack under the lowest garbage is: each column's shortfall from the tallest, squared
static int32_t unevenOf(const Bits *B) {
  int G = bitsLowestG(B), hi = 0, tops[W + 1];
  for (int c = 1; c <= W; c++) { int t = 0; for (int r = 1; r < G; r++) if (B->pan[r] >> c & 1) t = r; tops[c] = t; if (t > hi) hi = t; }
  int32_t u = 0;
  for (int c = 1; c <= W; c++) u += (hi - tops[c]) * (hi - tops[c]);
  return u;
}
static int32_t uneven(const Board *b) { bitsOf(b, &scratchBits); return unevenOf(&scratchBits); }
// THE PERCH: the garbage sits on the tallest columns under it (its supports -- hi: their row; n: how many) and comes down a row once
// each support's top panel has gone into a cell two rows or more under the garbage (room: those cells). How far it is from coming
// down, one number, lower the nearer (perchOf): the empty cells under the garbage, a row's worth and one for each, and its supports --
// every support walked off is one fewer, and a row come down is a row of empty cells fewer whatever then holds it. *can: the lower
// columns have the room for every support, so the garbage can come down
typedef struct { int32_t hi, n, room, hollow, top[W + 2], firstG[W + 2]; unsigned held; } Perch;
static void perchRead(const Board *b, Perch *P) {
  static LOCAL BoardShape S;
  bitsOf(b, &scratchBits); bitsShape(&scratchBits, &S);
  P->hi = 0; P->n = 0; P->room = 0; P->held = 0; P->hollow = S.hollow;
  for (int c = 1; c <= W; c++) { P->top[c] = S.peak[c]; P->firstG[c] = S.firstG[c]; if (S.firstG[c] && S.peak[c] > P->hi) P->hi = S.peak[c]; }
  for (int c = 1; c <= W; c++) {
    if (S.firstG[c] && S.peak[c] == P->hi) { P->held |= 1u << c; P->n++; }
    else if (S.peak[c] <= P->hi - 2 && (!S.firstG[c] || S.firstG[c] > P->hi)) P->room += P->hi - 1 - S.peak[c];
  }
}
static int32_t perchOf(const Board *b, int *can) {
  static LOCAL Perch P;
  perchRead(b, &P);
  *can = P.hi >= 2 && P.room >= P.n;
  return P.hollow * (W + 1) + P.n;
}
// the swaps that walk the panel at (q, from) to column k along its row
static int walkTo(int q, int from, int k, int32_t *seq, int n) {
  if (from > k) for (int c = from - 1; c >= k && n < MAXPATH; c--) seq[n++] = q * 8 + c;
  else for (int c = from; c < k && n < MAXPATH; c++) seq[n++] = q * 8 + c;
  return n;
}
// HOW MANY SWAPS AWAY THE NEAREST BREAK IS (breakNear): the fewest swaps that line up a match of three with a panel touching garbage --
// each other panel of the match brought along its own row, over cells that hold it up and are not garbage (bitsBring). NEAR_MISS when
// none. (And the line that makes it: seq, *nseq -- each panel walked in turn; 0 for none.)
static int nearLineOf(const Bits *B, int32_t *seq, int *nseq) {
  int top = B->top, best = 1 << 30;
  if (nseq) *nseq = 0;
  for (int r = 1; r <= top; r++) {
    unsigned starts = bitsStarts(B, r);
    for (int c = 1; c <= W; c++) {
      if (!(starts >> c & 1)) continue;
      int32_t k = B->code[r][c];
      // a column of three through it
      for (int r0 = r - 2; r0 <= r; r0++) {
        if (r0 < 1 || r0 + 2 > top) continue;
        int dv = 0, from, fr[3] = { 0 }, qs[3] = { 0 }, nq = 0;
        for (int q = r0; q <= r0 + 2 && dv < best; q++) { if (q == r) continue; int d = bitsBring(B, q, c, k, 0, &from); if (d >= 0) { dv += d; qs[nq] = q; fr[nq++] = from; } else dv = 1 << 30; }
        if (dv < best) { best = dv; if (seq) { int n = 0; for (int i = 0; i < nq; i++) n = walkTo(qs[i], fr[i], c, seq, n); *nseq = n; } }
      }
      // a row of three through it
      for (int c0 = c - 2; c0 <= c; c0++) {
        if (c0 < 1 || c0 + 2 > W) continue;
        unsigned used = 1u << c;
        int dh = 0, from, fr[3] = { 0 }, ts[3] = { 0 }, nt = 0;
        for (int t = c0; t <= c0 + 2 && dh < best; t++) { if (t == c) continue; int d = bitsBring(B, r, t, k, used, &from); if (d >= 0) { used |= 1u << from; dh += d; ts[nt] = t; fr[nt++] = from; } else dh = 1 << 30; }
        if (dh < best) { best = dh; if (seq) { int n = 0; for (int i = 0; i < nt; i++) n = walkTo(r, fr[i], ts[i], seq, n); *nseq = n; } }
      }
    }
  }
  return best;
}
static int breakNearLine(const Board *b, int32_t *seq, int *nseq) { bitsOf(b, &scratchBits); return nearLineOf(&scratchBits, seq, nseq); }
static int breakNear(const Board *b) { return breakNearLine(b, 0, 0); }
// A PERCHED BLOCK (perchedDrops): a garbage block whose bottom row is held up by panels in some of the columns under it and by nothing in
// the others -- a hollow under it. Its supports walked along their row past the block's nearer edge let it down, and the stack's height
// with it. A block that sits on garbage in any column under it is not perched: there is nothing to walk out. The lines, lowest block
// first: each support's walk, one after another.
#define PERCHMAX 4
typedef struct { int32_t n, len[PERCHMAX], seq[PERCHMAX][MAXPATH]; } Perches;
static void perchedOf(const Bits *B, Perches *P) {
  P->n = 0;
  for (int r = 2; r <= B->top && P->n < PERCHMAX; r++) {
    unsigned g = B->gar[r];
    for (int c = 1; c <= W && P->n < PERCHMAX; c++) {
      if (!(g >> c & 1) || (B->gar[r - 1] >> c & 1)) continue;
      // (the block's bottom row in this row: its cells from c to R, one block)
      int32_t id = B->gid[r][c];
      int L = c, R = c;
      while (R + 1 <= W && (g >> (R + 1) & 1) && B->gid[r][R + 1] == id) R++;
      c = R;
      unsigned span = ((2u << R) - 1u) & ~((1u << L) - 1u), under = r - 1;
      if (B->gar[under] & span) continue;
      unsigned holds = B->pan[under] & span;
      if (!holds || holds == span) continue;
      int n = 0, ok = 1;
      for (int k = L; k <= R && ok; k++) {
        if (!(holds >> k & 1)) continue;
        int toL = L - 1, toR = R + 1, to = toL >= 1 && (k - toL <= toR - k || toR > W) ? toL : toR <= W ? toR : 0;
        // (run 146 walked a full-width block's support under it to the nearest column it falls in: 2/8, 80654 frames -- removed)
        if (!to) { ok = 0; break; }
        int was = n;
        n = walkTo(under, k, to, P->seq[P->n], n);
        if (n - was != (to > k ? to - k : k - to)) ok = 0;
      }
      if (ok && n > 0) { P->len[P->n] = n; P->n++; }
    }
  }
}
static void perchedDrops(const Board *b, Perches *P) { bitsOf(b, &scratchBits); perchedOf(&scratchBits, P); }
// HOW SHORT OF A BREAK A BOARD WITH NONE TO WALK TO IS (shortOf): of every three cells in a line with one beside garbage, and every colour
// the board shows, the one missing the fewest panels -- a cell's panel is there when one of that colour can be walked to it along its
// row (bitsBring) -- and of those the one walked least. A panel missing is one the board holds: as many more of the colour as the three
// is short of, in the rows the cell's column runs through between its garbage (reach) -- a row shut in between two slabs is never fed.
// A three with all its panels is a break, its walk the swaps; one or two short is past every walk (NEAR_MISS), a panel short before two
// (NEAR_SPAN: more than two panels' walk); with none, NEAR_NONE. A panel whose colour is not shown yet (bits.c seenColour) is no panel
// of any colour.
#define NEAR_SPAN (2 * (W - 1) + 1)
#define NEAR_NONE (NEAR_MISS + 2 * NEAR_SPAN)
static int shortOf(const Bits *B) {
  int top = B->top, best = NEAR_NONE;
  unsigned beside[MAXROWS + 2];
  uint8_t lo[MAXROWS + 2][W + 2], hi[MAXROWS + 2][W + 2];   // the rows a cell's column runs through, garbage to garbage
  static LOCAL int32_t upTo[BITCOLOURS][MAXROWS + 2];       // a colour's panels in rows 1..r
  for (int r = 1; r <= top; r++) {
    unsigned g = B->gar[r], up = r + 1 <= top ? B->gar[r + 1] : 0, dn = r - 1 >= 1 ? B->gar[r - 1] : 0;
    beside[r] = ~g & (up | dn | ((g << 1) & ALLCOLS) | (g >> 1)) & ALLCOLS;
    for (int c = 1; c <= W; c++) lo[r][c] = (uint8_t)(r > 1 && !(B->gar[r - 1] >> c & 1) ? lo[r - 1][c] : r);
  }
  for (int r = top; r >= 1; r--) for (int c = 1; c <= W; c++) hi[r][c] = (uint8_t)(r < top && !(B->gar[r + 1] >> c & 1) ? hi[r + 1][c] : r);
  for (int32_t k = 1; k < BITCOLOURS; k++) { upTo[k][0] = 0; for (int r = 1; r <= top; r++) upTo[k][r] = (upTo[k][r - 1] + bitCount(B->col[k][r])); }
  #define SPARE(k, r, c) (upTo[k][hi[r][c]] - upTo[k][lo[r][c] - 1])
  for (int r = 1; r <= top; r++) {
    // a row of three with a cell beside garbage
    for (int c0 = 1; c0 + 2 <= W; c0++) {
      unsigned span = 7u << c0;
      if (!(beside[r] & span) || (B->gar[r] & span)) continue;
      for (int32_t k = 1; k < BITCOLOURS; k++) {
        if (!seenColour(k) || !B->col[k][r]) continue;
        int miss = 0, walk = 0, from, held = 1 << 30; unsigned used = 0;
        for (int t = c0; t <= c0 + 2; t++) { int d = bitsBring(B, r, t, k, used, &from); if (d >= 0) { used |= 1u << from; walk += d; } else { miss++; held = imin(held, SPARE(k, r, t)); } }
        int v = miss ? NEAR_MISS + (miss - 1) * NEAR_SPAN + walk : walk;
        if (miss < 3 && v < best && (!miss || held >= 3)) best = v;
      }
    }
    // a column of three with a cell beside garbage
    if (r + 2 > top) continue;
    for (int c = 1; c <= W; c++) {
      unsigned bit = 1u << c;
      if (!((beside[r] | beside[r + 1] | beside[r + 2]) & bit) || ((B->gar[r] | B->gar[r + 1] | B->gar[r + 2]) & bit)) continue;
      for (int32_t k = 1; k < BITCOLOURS; k++) {
        if (!seenColour(k) || !(B->col[k][r] | B->col[k][r + 1] | B->col[k][r + 2])) continue;
        int miss = 0, walk = 0, from;
        for (int q = r; q <= r + 2; q++) { int d = bitsBring(B, q, c, k, 0, &from); if (d >= 0) walk += d; else miss++; }
        int v = miss ? NEAR_MISS + (miss - 1) * NEAR_SPAN + walk : walk;
        if (miss < 3 && v < best && (!miss || SPARE(k, r, c) >= 3)) best = v;
      }
    }
  }
  #undef SPARE
  return best;
}
// HOW NEAR A BREAK A BOARD IS, one number, lower the nearer (nearOf): the swaps to the nearest break (breakNear); with none to walk to,
// how short of one it is (shortOf: NEAR_MISS and over)
static int nearOf(const Board *b) { int n = breakNear(b); return n < NEAR_MISS ? n : shortOf(&scratchBits); }
static int breakBuildable(const Board *b) { return breakNear(b) < NEAR_MISS; }
static int garbageOn(const Board *b) { bitsOf(b, &scratchBits); return bitsLowestG(&scratchBits) <= scratchBits.rows; }
// the panels on the board, garbage not counted -- the material every break is made from
static int32_t panelsOn(const Board *b) { bitsOf(b, &scratchBits); return bitsPanels(&scratchBits); }
// (the swaps to the nearest break alone, every board with none to walk to alike: NEAR_MISS)
static int walkNear(const Board *b) { return imin(breakNear(b), NEAR_MISS); }
static int32_t nearScore(const Board *b) { return -1000 * walkNear(b) - uneven(b); }
// How far a board is toward lining up with the converting row `want`: per column, its top panel below the lowest garbage of that colour,
// and the one under it too
static int32_t pairsOf(const Board *b, const int32_t *want) {
  int G = lowestG(b);
  int32_t s = 0;
  for (int c = 1; c <= W; c++) {
    if (!want[c]) continue;
    int t = 0;
    for (int r = 1; r < G; r++) if (cellAt(b, r, c) > 0) t = r;
    if (t && cellAt(b, t, c) == want[c]) s += t > 1 && cellAt(b, t - 1, c) == want[c] ? PAIR : 1;
  }
  return s;
}
// The colours the row a popping slab converts has dealt, per column (0 where none), from the board as the game shows it; 0 if none.
static int converting(const Board *b, int32_t *want) {
  for (int r = 1; r < b->nrows; r++) {
    int any = 0;
    for (int c = 1; c <= W; c++) {
      const int32_t *f = b->p[r][c].f;
      if (f[ISGARBAGE] && f[STATE] == MATCHED && f[COLOR] >= 1 && f[COLOR] <= 8) { want[c] = f[COLOR]; any = 1; } else want[c] = 0;
    }
    if (any) return 1;
  }
  return 0;
}

// ---- the search
typedef struct {
  Ctx *x; int root, wait;
  Broke *out;
  const Paths *resume;
  int32_t *outside;      // per node: made off the rules (stepOk) -- a break counts only on a line within them from its first swap
  int32_t idleT[256], idleB[256], nIdle;
  int32_t anyFound;
  int32_t towardS, haveToward, towardLen, toward[MAXPATH];
  int32_t tries;
  int32_t again;         // the touch beam asked a second time in one search, from the frontier the first reached
} BS;
static LOCAL int32_t outsideBuf[1 << 20];
// A break is one standing still would not have made by the same frame (still): the root left alone, its breaks at frame t.
static int32_t stillAt(BS *s, int32_t t) {
  for (int i = 0; i < s->nIdle; i++) if (s->idleT[i] == t) return s->idleB[i];
  Ctx *x = s->x;
  int w = t > NODE(x, s->root)->t ? step(x, s->root, MK_LONG, 0, 0, t - NODE(x, s->root)->t) : s->root;
  int32_t b = w >= 0 ? NODE(x, w)->brk : NODE(x, s->root)->brk;
  if (s->nIdle < 256) { s->idleT[s->nIdle] = t; s->idleB[s->nIdle++] = b; }
  return b;
}
// (the actions a line's swaps spend, walked from the root's cursor as the judge walks them: core/nodes.h actionsFor)
static int spentOn(const BS *s, const int32_t *path, int len) {
  const Board *rb = ensureBoard(s->x, s->root);
  if (!rb) return 0;
  int r = rb->curRow, c = rb->curCol, acts = 0;
  for (int k = 0; k < len; k++) { acts += actionsFor(r, c, CR(path[k]), CC(path[k]), pressAllowance - acts); r = CR(path[k]); c = CC(path[k]); }
  return acts;
}
static int within(BS *s, int i) { return !(BREAK_LIST && i >= 0 && i < (1 << 20) && s->outside[i]); }
// (every node a step makes is marked as the rules see it: off them when its parent was, when it is a first swap that is a swap back,
// or when its own clears are outside the list)
static void markStep(BS *s, int par, int kind, int mv, int o) {
  Ctx *x = s->x;
  if (!BREAK_LIST || !liveNode(x, o) || o >= (1 << 20)) return;
  int fromRoot = par == s->root, firstBad = 0;
  if (fromRoot && kind == MK_SWAP) {
    Stats st; statsOf(x, o, &st);
    firstBad = !firstOk(CR(mv), CC(mv), NODE(x, o)->brk > stillAt(s, NODE(x, o)->t) ? 2 : st.cleared > 0);
  }
  s->outside[o] = (par >= 0 && par < (1 << 20) && s->outside[par]) || firstBad || !stepFitsAt(x, o);
}
static int stepMarked(BS *s, int par, int kind, int mv, int32_t frames) {
  int o = step(s->x, par, kind, kind == MK_SWAP || kind == MK_SETTLE ? CR(mv) : 0, kind == MK_SWAP || kind == MK_SETTLE ? CC(mv) : 0, frames);
  markStep(s, par, kind, mv, o);
  return o;
}
// (the same, the swap taken from a batch the search stepped on every thread: core/nodes.h stepBatch)
static int swapTaken(BS *s, int j, int par, int32_t mv) {
  int o = stepTake(s->x, j, par, MK_SWAP, mv);
  markStep(s, par, MK_SWAP, mv, o);
  return o;
}
// THE BREAK: more broken than standing still by then, within the rules, played through its settle within the list,
// and its whole line through the shared line check. Past the clock no check is asked, and nothing breaks.
static int allowedAt(Ctx *x, int o) {
  if (!liveNode(x, o) || !stepFitsAt(x, o)) return 0;
  int z = settleOf(x, o);
  return liveNode(x, z) && stepFitsAt(x, z);
}
static int breaksAt(BS *s, int n, const int32_t *path, int len) {
  Ctx *x = s->x;
  if (!liveNode(x, n) || !within(s, n) || !(NODE(x, n)->brk > stillAt(s, NODE(x, n)->t))) return 0;
  if (clockOut()) return 0;
  return (!BREAK_LIST || allowedAt(x, n)) && (!path || !BREAK_LIST || lineFits(path, len, 0));
}
// (what a break leaves once its board has settled: the garbage rows broken -- a break whose converted panels match again breaks on --
// and the material, the panels under each column's first garbage: a slab broken above another leaves its panels on the lower one,
// out of reach until that breaks)
static int32_t materialOn(const Board *b);   // (facts.c)
// (THE ONE RULE, OF A BREAK: what the swap that breaks clears, its settle with it -- 2 an entry of the mode's list, 1 a three that makes
// no chain, 0 a chain or a combo the list does not ask for, the last resort: judge.c the one rule)
static int breakCat(Ctx *x, int n) {
  Stats a; int32_t combo = 0, chain = 0;
  if (statsOf(x, n, &a)) { combo = biggestOf(&a); chain = chainOfStats(&a); }
  int z = settleOf(x, n);
  if (z != n && liveNode(x, z) && statsOf(x, z, &a)) { combo = imax(combo, biggestOf(&a)); chain = imax(chain, chainOfStats(&a)); }
  Made m = { combo, chain, 1, 0 };
  for (int i = 0; i < theList.n; i++) if (meets(&theList.aim[i], m)) return 2;
  return combo <= 3 && chain <= 1 ? 1 : 0;
}
static int32_t brokeSettled(Ctx *x, int n, int32_t *mat) {
  int z = settleOf(x, n), w = liveNode(x, z) ? z : n;
  Board *b = ensureBoard(x, w);
  *mat = b ? materialOn(b) : 0;
  return NODE(x, w)->brk;
}
// (whether a break keeps the chain the board is making: its board, at the frame the chain's last link comes, has that link -- judge.c
// ownChainOf; 1 when the board makes none)
static int keepsOwnChain(Ctx *x, int n) {
  if (ownChainBy <= 0) return 1;
  int w = NODE(x, n)->t < ownChainBy ? step(x, n, MK_LONG, 0, 0, ownChainBy - NODE(x, n)->t) : n;
  Board *b = liveNode(x, w) ? ensureBoard(x, w) : 0;
  return b && b->chainCounter >= ownChainN;
}
// (NO SWAP STRAIGHT BACK IN A LINE -- the owner: no flip and back: a search never grows a line by the swap the step before it made, its
// two cells still full: it swaps the same pair back; and no swap past the reach)
static int swapsOfNode(Ctx *x, int n, int32_t *ms) {
  Board *b = ensureBoard(x, n);
  if (!b) return 0;
  int m = legalSwaps(b, ms);
  // (and only within the reach of the cursor where the node leaves it: a line past it is one the order takes out -- core/nodes.h)
  { int k = 0; for (int i = 0; i < m; i++) if (iabs(CR(ms[i]) - b->curRow) + iabs(CC(ms[i]) - b->curCol) <= REACH_STEPS) ms[k++] = ms[i]; m = k; }
  const Node *d = NODE(x, n);
  if ((d->mk == MK_SWAP || d->mk == MK_SETTLE) && d->mr >= 0 && d->mr < b->nrows && d->mc >= 1 && d->mc + 1 <= W &&
      b->p[d->mr][d->mc].f[ID] != NUL && b->p[d->mr][d->mc + 1].f[ID] != NUL) {
    int32_t back = d->mr * 8 + d->mc; int k = 0;
    for (int i = 0; i < m; i++) if (ms[i] != back) ms[k++] = ms[i];
    m = k;
  }
  return m;
}
static void keepPaths(Paths *p, Line **ls, int n) {
  p->n = 0;
  for (int i = 0; i < n && p->n < KEEPN; i++) {
    if (ls[i]->len >= LONGEST) continue;
    p->len[p->n] = ls[i]->len;
    for (int k = 0; k < ls[i]->len; k++) p->path[p->n][k] = ls[i]->path[k];
    p->n++;
  }
}
static int foundAlready(Broke *o, int32_t key) { for (int i = 0; i < o->nmoves; i++) if (o->moves[i] == key) return i; return -1; }
static int found(Broke *o, int32_t key) { int i = foundAlready(o, key); if (i >= 0) return i; o->moves[o->nmoves] = key; return o->nmoves++; }
static void setPath(Broke *o, const int32_t *path, int len) { o->pathLen = len; for (int k = 0; k < len; k++) o->path[k] = path[k]; }

// THE TOUCH BEAM (touchBeam): the carried lines first, then the first swaps, grown a level at a time
#define BEAM_SWAP_ACTS 3   // (a swap's actions, the walk with it: 3.0 a swap measured over 26,000 swaps of finish them)
static int touchBeam(BS *s, Line **firsts, int nfirsts) {
  Ctx *x = s->x;
  Broke *o = s->out;
  static LOCAL Line *seeds[LINEPOOL], *act[LINEPOOL], *nxt[LINEPOOL], *tl0[LINEPOOL], *tl[LINEPOOL], *tn[LINEPOOL], *kept[LINEPOOL];
  static LOCAL int32_t idx[LINEPOOL], tmp[LINEPOOL], keyS[LINEPOOL], ms[MAXROWS * W];
  // (the search carried on: the lines the last decision's beam was growing, played again swap by swap within the rules)
  // (THE SAME BOARD SEARCHED ON, resume->cont: a search the clock stops before it has grown anything leaves the frontier as it was; and
  // carried on within one search, s->again: the first swaps were grown when the frontier was made, so the frontier alone is grown)
  int nseeds = 0, nact = 0, cont = s->resume && s->resume->cont;
  if (cont) o->keepOut = *s->resume;
  for (int i = 0; s->resume && i < s->resume->n; i++) {
    if (!(s->resume->len[i] > 0 && s->resume->len[i] < LONGEST)) continue;
    Line *a = lineNew(); if (!a) break;
    a->len = s->resume->len[i]; for (int k = 0; k < a->len; k++) a->path[k] = s->resume->path[i][k];
    a->n = s->root; a->kept = 0; a->carried = 1;   // kept: the swaps played so far
    act[nact++] = a;
  }
  while (nact && !SEARCH_OUT()) {
    int nn = 0;
    for (int i = 0; i < nact; i++) {
      Line *a = act[i];
      int mv = a->path[a->kept];
      if (!legalAt(x, a->n, CR(mv), CC(mv))) continue;
      int out = stepMarked(s, a->n, MK_SWAP, mv, 0);
      if (!liveNode(x, out) || !within(s, out)) continue;
      a->n = out; a->kept++;
      if (a->kept == a->len) { a->key = a->path[0]; seeds[nseeds++] = a; } else nxt[nn++] = a;
    }
    for (int i = 0; i < nn; i++) act[i] = nxt[i];
    nact = nn;
  }
  if (nseeds && !(cont && SEARCH_OUT())) keepPaths(&o->keepOut, seeds, nseeds);
  for (int i = 0; i < nseeds; i++)
    if (breaksAt(s, seeds[i]->n, seeds[i]->path, seeds[i]->len)) {
      found(o, seeds[i]->key); o->touch = 1; o->carried = 1; setPath(o, seeds[i]->path, seeds[i]->len); o->at = NODE(x, seeds[i]->n)->t;
      return 1;
    }
  int n0 = 0;
  for (int i = 0; i < nseeds; i++) tl0[n0++] = seeds[i];
  for (int i = 0; i < nfirsts && !(s->again && nseeds); i++) if (liveNode(x, firsts[i]->n) && within(s, firsts[i]->n) && (pressAllowance < 0 || spentOn(s, firsts[i]->path, 1) <= allowLeftAt(0, 0))) tl0[n0++] = firsts[i];
  int tpath = 0;
  for (int tb = touchFrom; tb < 2 && !tpath && !SEARCH_OUT(); tb++) {
    int beam = tb ? TOUCH_WIDE : TOUCH_BEAM, ntl = n0;
    // (A CHEAPER BREAK ONE SWAP ON: a break found that the cursor walks more than CHEAP_BREAK actions for is kept, and the level after
    // searched too -- one more swap near the cursor can cost fewer actions than one far from it; the better of the two by the level's
    // own key, actions before the material)
    int64_t heldB = -1; int foundTd = -1;
    for (int i = 0; i < n0; i++) tl[i] = tl0[i];
    for (int td = 2; td <= TOUCH_DEPTH && ntl && !tpath && !SEARCH_OUT(); td++) {
      // (how near a break each line's board is, read on the board once what the line cleared has fallen -- settled a batch at a
      // time while the clock allows: past it the rest are scored as they stand)
      // (the settles stepped on every thread first, then taken in this order: core/nodes.h stepBatch)
      static LOCAL int32_t sPar[LINEPOOL], sMv[LINEPOOL], sAt[LINEPOOL];
      int nsb = 0;
      for (int i = 0; i < ntl; i++) { Stats st; sAt[i] = -1; if (statsOf(x, tl[i]->n, &st) && st.cleared > 0) { sAt[i] = nsb; sPar[nsb] = tl[i]->n; sMv[nsb++] = 0; } }
      stepBatch(x, sPar, sMv, MK_SETTLE, nsb);
      for (int i = 0; i < ntl; i++) {
        Line *l = tl[i];
        int32_t sc = nearScore(ensureBoard(x, l->n));
        if (sAt[i] >= 0) { int w = stepTake(x, sAt[i], l->n, MK_SETTLE, 0); if (liveNode(x, w)) { int32_t s2 = nearScore(ensureBoard(x, w)); if (s2 > sc) sc = s2; } }
        // (THE WALK SPENT: with an input allowance to keep, a line's place is its estimated actions to a break -- those walked so far
        // and a swap's worth (BEAM_SWAP_ACTS) for each swap still to go -- so of two as near a break the one that walked less leads)
        if (pressAllowance >= 0) sc -= (1000 / BEAM_SWAP_ACTS) * spentOn(s, l->path, l->len);
        l->s = sc; l->h = (int32_t)NODE(x, l->n)->hash;
        idx[i] = i; keyS[i] = sc;
      }
      batchDone();
      sortByKeyDesc(idx, ntl, keyS, tmp);
      for (int i = 0; i < ntl; i++) tn[i] = tl[idx[i]];
      for (int i = 0; i < ntl; i++) tl[i] = tn[i];
      // (the line nearest a break the beam has seen: TOWARD, returned when no break is found)
      if (ntl && (!s->haveToward || tl[0]->s > s->towardS)) { s->haveToward = 1; s->towardS = tl[0]->s; s->towardLen = tl[0]->len; for (int k = 0; k < tl[0]->len; k++) s->toward[k] = tl[0]->path[k]; }
      keepPaths(&o->keepOut, tl, ntl < KEEPN ? ntl : KEEPN);
      // Swaps made in another order often leave the same board: each board is kept once, its best-scoring line.
      // (THE BOARD AS IT IS, ITS SHARE OF THE BEAM: lines grown from the ones the last decision carried on take at most half the beam
      // while lines from this board's own first swaps are left to fill it -- carried lines were ranked on a board the garbage has since
      // changed, and crowd out a break the board has now)
      int nk = 0, nc = 0;
      static LOCAL unsigned char skipped[LINEPOOL];
      for (int pass = 0; pass < 2 && nk < beam; pass++)
        for (int i = 0; i < ntl && nk < beam; i++) {
          Line *l = tl[i];
          if (pass == 0) { skipped[i] = 0; if (l->carried && nc >= beam / 2) { skipped[i] = 1; continue; } }
          else if (!skipped[i]) continue;
          Node *ln = NODE(x, l->n);
          int dup = 0;
          for (int q = 0; q < nk && !dup; q++) {
            Node *kn = NODE(x, kept[q]->n);
            if ((int32_t)kn->hash != l->h || kn->keyn != ln->keyn) continue;
            dup = memcmp(kn->key, ln->key, sizeof(int32_t) * ln->keyn) == 0;
          }
          if (!dup) { kept[nk++] = l; nc += l->carried; }
        }
      ntl = nk;
      for (int i = 0; i < nk; i++) tl[i] = kept[i];
      // (THE DIVE: each of the beam's first lines played on along its own board's nearest break -- breakNear's line, its panels walked to
      // it -- k steps where the level grows every swap of every line)
      int64_t diveB = -1; int32_t diveKey = 0, diveLen = 0, diveAt = 0, diveCarried = 0, divePath[MAXPATH];
      // (run 322: only under a backlog -- fifteen or more waiting: the dive finished training_random at garbage level 10-11 (run 306), queues
      // of 25-48, and cost chaos mode, 6 colours, queues under 16 -- 8/8 and 7/8 without it (runs 320-321), 4/8 with it (run 319): its
      // search time is the beam's)
      for (int i = 0; i < ntl && i < DIVE_N && decQ.b && decQ.b->ninc >= 15 && !SEARCH_OUT(); i++) {
        Line *l = tl[i]; static LOCAL int32_t dl[MAXPATH]; int dn = 0;
        const Board *db = ensureBoard(x, l->n);
        if (!db || breakNearLine(db, dl, &dn) >= NEAR_MISS || dn <= 0 || l->len + dn > MAXPATH) continue;
        int32_t path[MAXPATH]; int len = l->len, node = l->n, ok = 1;
        for (int k = 0; k < len; k++) path[k] = l->path[k];
        for (int k = 0; k < dn && ok; k++) {
          if (pressAllowance >= 0) {
            const Board *nb = ensureBoard(x, node);
            int left = allowLeftAt(NODE(x, node)->t - NODE(x, s->root)->t, spentOn(s, path, len));
            if (!nb || actionsFor(nb->curRow, nb->curCol, CR(dl[k]), CC(dl[k]), left) > left) { ok = 0; break; }
          }
          if (!legalAt(x, node, CR(dl[k]), CC(dl[k]))) { ok = 0; break; }
          node = stepMarked(s, node, MK_SWAP, dl[k], 0); path[len++] = dl[k];
          ok = liveNode(x, node) && within(s, node);
        }
        if (!ok || !breaksAt(s, node, path, len)) continue;
        int32_t mat, br = brokeSettled(x, node, &mat);
        int acts = 0;
        { const Board *rb0 = ensureBoard(x, s->root); if (pressAllowance >= 0 && rb0) { int r = rb0->curRow, c = rb0->curCol; for (int k = 0; k < len; k++) { acts += actionsFor(r, c, CR(path[k]), CC(path[k]), pressAllowance - acts); r = CR(path[k]); c = CC(path[k]); } } }
        int64_t bk = ((int64_t)keepsOwnChain(x, node) << 40) + ((int64_t)breakCat(x, node) << 32) + ((int64_t)(255 - imin(acts, 255)) << 24) + ((int64_t)imin(mat, 4095) << 8) + imin(br, 255);
        if (bk > diveB) { diveB = bk; diveKey = l->key; diveCarried = l->carried; diveLen = len; diveAt = NODE(x, node)->t; for (int k = 0; k < len; k++) divePath[k] = path[k]; }
      }
      int ntn = 0, ar = td & 1;
      arenaN[ar] = 0;   // (the level before last: its lines are let go)
      // (the level's swaps stepped on every thread first, then taken in this order: core/nodes.h stepBatch)
      static LOCAL int32_t bPar[LINEPOOL * MAXROWS * W / 4], bMv[LINEPOOL * MAXROWS * W / 4], bAt[LINEPOOL + 1];
      int nb = 0;
      for (int i = 0; i < ntl; i++) {
        bAt[i] = nb;
        int nm = swapsOfNode(x, tl[i]->n, ms);
        // (THE WINDOW AS THE JUDGE PRESSES IN IT: a swap whose walk is over what the window leaves at its frame is never pressed -- the
        // judge cuts the line there -- so the beam does not grow it: its width goes to lines the window pays for (8b8a9618))
        int left = -1; const Board *lb = 0;
        if (pressAllowance >= 0) { lb = ensureBoard(x, tl[i]->n); left = allowLeftAt(NODE(x, tl[i]->n)->t - NODE(x, s->root)->t, spentOn(s, tl[i]->path, tl[i]->len)); }
        for (int j = 0; j < nm && nb < (int)(sizeof bPar / sizeof bPar[0]); j++) {
          if (lb && actionsFor(lb->curRow, lb->curCol, CR(ms[j]), CC(ms[j]), left) > left) continue;
          bPar[nb] = tl[i]->n; bMv[nb++] = ms[j];
        }
      }
      bAt[ntl] = nb;
      stepBatch(x, bPar, bMv, MK_SWAP, nb);
      // (the level a break is found on is taken whole: of its lines that break, one that keeps the board's own chain first -- a chain cut
      // leaves the three that began it wasted -- then the one that leaves the most material once its board settles, then the one that
      // has broken most: a break whose converted panels match again is rows more of the slab -- and, with an input allowance to keep (a
      // host that says it), the one the cursor walks fewer actions for before the material: the window pays for every cell of it
      // (and before the actions, the one rule (breakCat): a break the mode's list asks, then a three's, then the last resort -- the mode
      // is played under garbage too, and a break is made as the mode asks where the level has one)
      const Board *rb = ensureBoard(x, s->root);
      int starved = pressAllowance >= 0 && rb;
      int64_t bestB = -1; int32_t bestKey = 0, bestLen = 0, bestAt = 0, bestCarried = 0, bestPath[MAXPATH];
      for (int i = 0; i < ntl; i++) {
        for (int b = bAt[i]; b < bAt[i + 1]; b++) {
          int32_t mv = bMv[b];
          int t3 = swapTaken(s, b, tl[i]->n, mv);
          if (!liveNode(x, t3)) continue;
          Line *nl = lineIn(ar); if (!nl) break;
          *nl = *tl[i]; nl->n = t3; if (nl->len < MAXPATH) nl->path[nl->len++] = mv;
          if (breaksAt(s, t3, nl->path, nl->len)) {
            int32_t mat, br = brokeSettled(x, t3, &mat);
            int acts = 0;
            if (starved) { int r = rb->curRow, c = rb->curCol; for (int k = 0; k < nl->len; k++) { acts += actionsFor(r, c, CR(nl->path[k]), CC(nl->path[k]), pressAllowance - acts); r = CR(nl->path[k]); c = CC(nl->path[k]); } }
            int64_t bk = ((int64_t)keepsOwnChain(x, t3) << 40) + ((int64_t)breakCat(x, t3) << 32) + ((int64_t)(255 - imin(acts, 255)) << 24) + ((int64_t)imin(mat, 4095) << 8) + imin(br, 255);
            if (bk > bestB) { bestB = bk; bestKey = tl[i]->key; bestCarried = tl[i]->carried; bestLen = nl->len; bestAt = NODE(x, t3)->t; for (int k = 0; k < nl->len; k++) bestPath[k] = nl->path[k]; }
            continue;
          }
          if (bestB < 0 && within(s, t3)) tn[ntn++] = nl;
        }
      }
      batchDone();
      if (diveB > bestB) { bestB = diveB; bestKey = diveKey; bestCarried = diveCarried; bestLen = diveLen; bestAt = diveAt; for (int k = 0; k < diveLen; k++) bestPath[k] = divePath[k]; }
      if (bestB >= 0 && bestB > heldB) { found(o, bestKey); setPath(o, bestPath, bestLen); o->at = bestAt; heldB = bestB; o->fresh = s->resume && s->resume->n && !bestCarried; }
      if (bestB >= 0 && foundTd < 0) foundTd = td;
      if (foundTd >= 0 && (!starved || td > foundTd || 255 - ((heldB >> 24) & 255) <= CHEAP_BREAK || td == TOUCH_DEPTH)) tpath = 1;
      // (and the level expanded: its boards are its children's now -- the frontier the next decision carries on, in its parents' order)
      if (ntn) keepPaths(&o->keepOut, tn, ntn < KEEPN ? ntn : KEEPN);
      for (int i = 0; i < ntn; i++) tl[i] = tn[i];
      ntl = ntn;
    }
    if (foundTd >= 0) tpath = 1;   // (the break held, the level after it ended short: the clock or no lines)
    if (tpath) { o->touch = 1; o->wide = tb; return 1; }
  }
  return 0;
}

// ---- a slab popping: the line-ups (wait > 0)
// whether each node breaks once the pop is over (end: the frame it ends, from the root)
static void linedAll(BS *s, const int *ns, int n, int32_t end, int *out) {
  for (int q = 0; q < n; q++) {
    out[q] = 0;
    if (!liveNode(s->x, ns[q])) continue;
    int w = stepMarked(s, ns[q], MK_LONG, 0, imax(1, end - NODE(s->x, ns[q])->t));
    out[q] = breaksAt(s, w, 0, 0);
  }
}
// Each parent's swaps in turn, as many as `cap` tries leave, till one of them hits: a hit marks the parent's first move and its pair,
// and the next parent goes on (inTurn). hits: 0 the pop's end breaks after the second swap, 1 the second swap itself breaks.
typedef struct { int32_t key, n, m; } Parent;
static void inTurn(BS *s, const Parent *ps, int np, int cap, int hits, int32_t end) {
  Ctx *x = s->x;
  Broke *o = s->out;
  static LOCAL int32_t ms[MAXROWS * W];
  for (int k = 0; k < np && s->tries < cap && !SEARCH_OUT(); k++) {
    int nm = swapsOfNode(x, ps[k].n, ms);
    for (int j = 0; j < nm && s->tries < cap; j++) {
      s->tries++;
      int n2 = step(x, ps[k].n, MK_SWAP, CR(ms[j]), CC(ms[j]), 0), hit;
      markStep(s, ps[k].n, MK_SWAP, ms[j], n2);
      if (hits == 0) { int one = liveNode(x, n2) && NODE(x, n2)->t < end ? n2 : -1; linedAll(s, &one, 1, end, &hit); }
      else hit = breaksAt(s, n2, 0, 0);
      if (hit) { int f = found(o, ps[k].key); o->pairs[f][0] = ps[k].m; o->pairs[f][1] = ms[j]; s->anyFound = 1; break; }
    }
  }
}
static int lineups(BS *s, Line **firsts, int nfirsts) {
  Ctx *x = s->x;
  Broke *o = s->out;
  int32_t end = NODE(x, s->root)->t + s->wait;
  static LOCAL int ns[MAXROWS * W], hit[MAXROWS * W];
  static LOCAL Parent ps[MAXROWS * W];
  for (int q = 0; q < nfirsts; q++) ns[q] = firsts[q]->n;
  linedAll(s, ns, nfirsts, end, hit);
  for (int q = 0; q < nfirsts; q++) if (hit[q]) found(o, firsts[q]->key);
  if (o->nmoves) { o->lineup = 1; return 1; }
  // a pop is long enough for two swaps: the first of a pair that lines up
  int np = 0;
  for (int q = 0; q < nfirsts; q++) if (liveNode(x, firsts[q]->n) && NODE(x, firsts[q]->n)->t < end) { Parent p = { firsts[q]->key, firsts[q]->n, firsts[q]->path[0] }; ps[np++] = p; }
  inTurn(s, ps, np, LINEUP_BUDGET, 0, end);
  if (o->nmoves) { o->lineup = 2; return 1; }
  // further, aimed: the colours the row turns into, met by pairs on top of their columns
  int32_t want[W + 1];
  if (converting(ensureBoard(x, s->root), want)) {
    static LOCAL Line *level[LINEPOOL], *next[LINEPOOL];
    static LOCAL int32_t idx[LINEPOOL], tmp[LINEPOOL], keyS[LINEPOOL], ms[MAXROWS * W], n3s[LINEPOOL], scs[LINEPOOL], l3[LINEPOOL], m3[LINEPOOL], from[LINEPOOL];
    int nl = 0, found3 = 0;
    for (int q = 0; q < nfirsts; q++) if (liveNode(x, firsts[q]->n) && NODE(x, firsts[q]->n)->t < end) level[nl++] = firsts[q];
    for (int dpt = 2; dpt <= LINEUP_DEPTH && nl && !found3 && !SEARCH_OUT(); dpt++) {
      for (int i = 0; i < nl; i++) { Board *b = ensureBoard(x, level[i]->n); level[i]->s = 10 * pairsOf(b, want) - uneven(b); idx[i] = i; keyS[i] = level[i]->s; }
      sortByKeyDesc(idx, nl, keyS, tmp);
      for (int i = 0; i < nl; i++) next[i] = level[idx[i]];
      if (nl > LINEUP_BEAM) nl = LINEUP_BEAM;
      for (int i = 0; i < nl; i++) level[i] = next[i];
      // the level's swaps, and the boards that stand up a pair waited to the pop's end
      int n3 = 0;
      for (int i = 0; i < nl; i++) {
        int nm = swapsOfNode(x, level[i]->n, ms);
        for (int j = 0; j < nm && n3 < LINEPOOL; j++) {
          int t3 = stepMarked(s, level[i]->n, MK_SWAP, ms[j], 0);
          n3s[n3] = t3; m3[n3] = ms[j]; from[n3] = i;
          scs[n3] = !liveNode(x, t3) || NODE(x, t3)->t >= end ? -1 : pairsOf(ensureBoard(x, t3), want);
          n3++;
        }
      }
      for (int q = 0; q < n3; q++) { int one = scs[q] >= PAIR ? n3s[q] : -1; linedAll(s, &one, 1, end, &l3[q]); }
      int nn = 0, ar = dpt & 1;
      arenaN[ar] = 0;
      for (int q = 0; q < n3 && !found3; q++) {
        if (scs[q] < 0) continue;
        Line *l = lineIn(ar); if (!l) break;
        *l = *level[from[q]]; l->n = n3s[q]; l->s = scs[q]; if (l->len < MAXPATH) l->path[l->len++] = m3[q];
        if (l3[q]) { found(o, level[from[q]]->key); setPath(o, l->path, l->len); found3 = 1; break; }
        next[nn++] = l;
      }
      for (int i = 0; i < nn; i++) level[i] = next[i];
      nl = nn;
    }
    if (o->nmoves) { o->lineup = 3; return 1; }
  }
  // failing that, a first swap leaving a break one swap away once the board has settled from it (the pop over, its panels down)
  if (s->tries < 2 * LINEUP_BUDGET) {
    np = 0;
    for (int q = 0; q < nfirsts; q++) {
      if (!liveNode(x, firsts[q]->n)) continue;
      int w = stepMarked(s, firsts[q]->n, MK_SETTLE, 0, 0);
      if (liveNode(x, w)) { Parent p = { firsts[q]->key, w, firsts[q]->path[0] }; ps[np++] = p; }
    }
    inTurn(s, ps, np, 2 * LINEUP_BUDGET, 1, end);
  }
  if (o->nmoves) { o->lineup = 4; return 1; }
  return 0;
}

// THE LINE TRIMMED (trimPath): the touch beam's line played again with each swap left out in turn, and kept without it whenever it still
// breaks as much, keeps the board's own chain as it did, and spends fewer of the cursor's actions -- a line grown a swap a level, and
// carried on from decision to decision, walks panels it need not (run 1875, factory-1 at 5094: 12 swaps where 10 break the same). Each
// trial is the line's steps once more, within the search's clock; a trial the clock cuts changes nothing.
static void trimPath(BS *s) {
  Ctx *x = s->x; Broke *o = s->out;
  if (o->pathLen < 3) return;
  int32_t path[MAXPATH], len = o->pathLen; for (int k = 0; k < len; k++) path[k] = o->path[k];
  int32_t mat0, br0; int node = s->root, keep0;
  for (int k = 0; k < len && liveNode(x, node); k++) node = stepMarked(s, node, MK_SWAP, path[k], 0);
  if (!liveNode(x, node)) return;
  br0 = brokeSettled(x, node, &mat0); keep0 = keepsOwnChain(x, node);
  int acts0 = spentOn(s, path, len);
  // (in TRIM_MS of its own past the search's share, the clock allowing it that much: a trial is the line's steps once more)
  double share = clockShare, by = nowMs() + TRIM_MS; if (!clockDue || by < clockDue) clockShare = by;
  for (int i = 0; i < len && len > 1 && !SEARCH_OUT(); ) {
    int32_t q[MAXPATH]; int m = 0;
    for (int k = 0; k < len; k++) if (k != i) q[m++] = path[k];
    // (pressed as the judge presses a line, core/nodes.h pressWalk: a swap whose pair still moves is walked to again from the frame after,
    // so a swap left out does not refuse the one after it for the frames it changes)
    int n = s->root;
    for (int k = 0; k < m && liveNode(x, n); k++) { int from, o2 = pressWalk(x, n, MK_SWAP, CR(q[k]), CC(q[k]), step, &from); if (o2 >= 0) markStep(s, n, MK_SWAP, q[k], o2); n = o2; }
    // (judged once its board has settled: a break the fall after the last swap makes is the line's)
    if (liveNode(x, n)) { int z = settleOf(x, n); if (liveNode(x, z)) n = z; }
    int32_t mat, br = liveNode(x, n) ? brokeSettled(x, n, &mat) : 0, acts = spentOn(s, q, m);
    if (liveNode(x, n) && !SEARCH_OUT() && acts < acts0 && breaksAt(s, n, q, m) && br >= br0 && keepsOwnChain(x, n) >= keep0) {
      for (int k = 0; k < m; k++) path[k] = q[k];
      len = m; acts0 = acts; o->at = NODE(x, n)->t;
      setPath(o, path, len); o->moves[0] = path[0];
    } else i++;
  }
  clockShare = share;
}
// THE BREAK SEARCH from the decision's question: wait, the frames a popping slab has left (0: none); resume, the lines the last
// decision's beam was growing, on this board. Answers into out.
static void breakMovesIn(const Question *q, int32_t wait, const Paths *resume, Broke *out);
// (the marks of the last search's nodes are let go before the next: every node of a search starts within the rules)
static LOCAL int breakBusy;
static void breakMoves(const Question *q, int32_t wait, const Paths *resume, Broke *out) {
  static LOCAL int32_t high;
  memset(outsideBuf, 0, sizeof(int32_t) * (unsigned long)high);
  breakBusy = 1;
  breakMovesIn(q, wait, resume, out);
  breakBusy = 0;
  high = breakCtx && breakCtx->n < (1 << 20) ? breakCtx->n : (1 << 20);
}
static void breakMovesIn(const Question *q, int32_t wait, const Paths *resume, Broke *out) {
  memset(out, 0, sizeof *out);
  Ctx *x = breakCtx = ctxOf(breakCtx);
  arenaN[0] = arenaN[1] = arenaN[KEEPS] = 0; linesFull = 0;
  if (lowestG(q->b) >= gridLen(q->b)) return;   // (no garbage: no break)
  BS s;
  memset(&s, 0, sizeof s);
  s.x = x; s.out = out; s.wait = wait; s.resume = resume; s.outside = outsideBuf;
  s.root = rootOf(x, q);
  if (s.root < 0) return;
  static LOCAL int32_t ms[MAXROWS * W];
  static LOCAL Line *firsts[MAXROWS * W];
  int nf = swapsOfNode(x, s.root, ms), nfirsts = 0, at1 = -1;
  for (int i = 0; i < nf; i++) {
    Line *l = lineNew(); if (!l) break;
    l->key = ms[i]; l->len = 1; l->path[0] = ms[i]; l->kept = 0; l->carried = 0;
    l->n = stepMarked(&s, s.root, MK_SWAP, ms[i], 0);
    firsts[nfirsts++] = l;
  }
  for (int i = 0; i < nfirsts; i++)
    if (breaksAt(&s, firsts[i]->n, firsts[i]->path, 1)) { found(out, firsts[i]->key); int32_t t = NODE(x, firsts[i]->n)->t; if (at1 < 0 || t < at1) at1 = t; }
  if (out->nmoves) { out->depth = 1; out->at = at1; return; }
  // (THE BREAK BUILT: the nearest break's panels walked to it along their rows -- breakNear's own line -- played on the engine; a slab
  // popping too: the line is pressed on the engine through the pop, and taken only where it breaks more than the pop alone)
  {
    static LOCAL int32_t nl[MAXPATH]; int nn = 0;
    if (breakNearLine(q->b, nl, &nn) < NEAR_MISS && nn > 0) {
      int node = s.root;
      for (int i = 0; i < nn && liveNode(x, node); i++) node = stepMarked(&s, node, MK_SWAP, nl[i], 0);
      if (liveNode(x, node) && breaksAt(&s, node, nl, nn)) { found(out, nl[0]); setPath(out, nl, nn); out->depth = 1; out->at = NODE(x, node)->t; out->built = 1; return; }
    }
  }
  if (!(wait > 0) && touchBeam(&s, firsts, nfirsts)) { out->depth = 1; trimPath(&s); return; }
  if (wait > 0) {
    // (a slab popping: the touch beam on the garbage elsewhere first, in half what is left -- a line-up's tries can take the whole of
    // it, and the touch beam had none (run 487, factory-1: a break of 7 swaps under a pop of 99 frames, found in 95 ms of 257 searched
    // again, missed)
    // (THE SAME BOARD, ITS LINE-UPS HAD, resume->cont 2: a line-up is the board's alone -- the same tries in the same order, with the
    // same ends -- so they are not tried again while no cell changes, and the touch beam has the whole share)
    int lined = resume && resume->cont == 2;
    if (clockShare > 0) {
      double half = lined ? clockShare : nowMs() + (clockShare - nowMs()) / 2, old = clockShareBegin(half);
      int hit = touchBeam(&s, firsts, nfirsts);
      if (hit) trimPath(&s);
      clockShareEnd(old);
      if (hit) { out->depth = 1; return; }
    }
    if (!lined) {
      lined = !SEARCH_OUT();   // (had: begun with time on the clock)
      int w0 = step(x, s.root, MK_LONG, 0, 0, wait);
      if (w0 >= 0 && w0 < (1 << 20)) outsideBuf[w0] = 0;   // (made from the root: within the rules so far)
      if (!breaksAt(&s, w0, 0, 0) && lineups(&s, firsts, nfirsts)) { out->depth = 1; return; }
      // (no line-up of the popping slab breaks again: a break of the garbage elsewhere while it pops, the cursor being free -- the touch
      // beam carried on from the frontier it reached before the line-ups, in what they left)
      static LOCAL Paths reached;
      if (clockShare > 0 && out->keepOut.n) { reached = out->keepOut; reached.cont = 1; s.resume = &reached; s.again = 1; }
      if (touchBeam(&s, firsts, nfirsts)) { out->depth = 1; trimPath(&s); return; }
    }
    out->keepOut.cont = lined ? 2 : 1;
  } else out->keepOut.cont = 1;
  // none found: the line nearest a break, and the lines to choose among -- the frontier the beam has grown furthest, then that line
  out->depth = 0;
  if (s.haveToward) { out->towardLen = s.towardLen; for (int k = 0; k < s.towardLen; k++) out->toward[k] = s.toward[k]; }
  out->towards = out->keepOut;
  if (s.haveToward && out->towards.n < KEEPN) { int t = out->towards.n++; out->towards.len[t] = s.towardLen; for (int k = 0; k < s.towardLen; k++) out->towards.path[t][k] = s.toward[k]; }
}

// ---- for a host's check: the decision's question, the lines carried on in the io body (n lines, each
// its length then its swaps), and the answer back into it
static Broke theBroke;
static Paths hostResume;
static void putPaths(int32_t *w, int *k, const Paths *p) { w[(*k)++] = p->n; for (int i = 0; i < p->n; i++) { w[(*k)++] = p->len[i]; for (int j = 0; j < p->len[i]; j++) w[(*k)++] = p->path[i][j]; } }
EXPORT(gb_break) int gb_break(int wait, int nresume) {
  int k = 0;
  hostResume.n = 0;
  for (int i = 0; i < nresume && i < KEEPN; i++) { int len = gbIo[k++]; hostResume.len[i] = len; for (int j = 0; j < len; j++) hostResume.path[i][j] = gbIo[k++]; hostResume.n++; }
  breakMoves(&decQ, wait, &hostResume, &theBroke);
  Broke *o = &theBroke;
  int32_t *w = gbIo;
  k = 0;
  w[k++] = o->depth; w[k++] = o->at; w[k++] = o->touch; w[k++] = o->carried; w[k++] = o->wide; w[k++] = o->lineup; w[k++] = linesFull;
  w[k++] = o->nmoves; for (int i = 0; i < o->nmoves; i++) { w[k++] = o->moves[i]; w[k++] = o->pairs[i][0]; w[k++] = o->pairs[i][1]; }
  w[k++] = o->pathLen; for (int i = 0; i < o->pathLen; i++) w[k++] = o->path[i];
  w[k++] = o->towardLen; for (int i = 0; i < o->towardLen; i++) w[k++] = o->toward[i];
  putPaths(w, &k, &o->towards);
  putPaths(w, &k, &o->keepOut);
  return k;
}

// READY (judge.c breaksAfterLanding): a break on node n's board -- the break search asked of it, off the list (readiness counts any break,
// as a list ended by "default" does), in its share of the time: a caller asking it of many lines gives each an equal part of the time
// left (readyShare: the time over the askings still to come), and otherwise half the time the decision has left; never past the share
// of the search that asks. Asked inside a break search (its line check judging), it
// answers NOT_ASKED: the search's own context is in use.
static int32_t popLeft(const Board *b);   // (propose.c: the frames a popping slab has left)
static double readyShareMs = -1;
static void readyShare(int asks) { readyShareMs = asks > 0 ? leftMsOf() / (2.0 * asks) : -1; }
// THE BREAKS ALREADY FOUND, kept across decisions (the kept plan's first piece, plans/gambit-infra.md F): a board a line lands on is
// the same board the next decision's line lands on whenever nothing new was told -- the engine predicts every frame -- so the break
// found on it is found again. Keyed by the whole board as it plays on (its state, the garbage queued, the rows it is fed: the step's
// counts and the caches that are no part of it left out), the blocks still on their way, the hold and the press: a board that differs
// anywhere is a board searched afresh -- new information repairs the table by itself. Only a break found is kept -- "none" is the time
// the search had, not the board. Shared by every thread (the jobs beside the decision write it), under one lock.
#define READYN 512
#define READYKEYMAX (sizeof(Board) + sizeof(int32_t) * (4 + 5 * MAXARR))
typedef struct { uint32_t h; int32_t nbytes, whyN, at; int32_t why[MAXLINE]; unsigned char *bytes; } ReadyKept;
static ReadyKept readyKept[READYN];
static int32_t readyLock;
static unsigned char *readyKeyBuf;
static int32_t readyClock, readyAsked, readyHit;   // (the log's: asked and found kept, this decision)
static void readyLockOn(void) { while (__atomic_exchange_n(&readyLock, 1, __ATOMIC_ACQUIRE)) {} }
static void readyLockOff(void) { __atomic_store_n(&readyLock, 0, __ATOMIC_RELEASE); }
static int readyKey(const Board *b, const Node *nd, int32_t tight, uint32_t *h) {
  static LOCAL Board canon;
  unsigned long head = BOARD_HEAD, inc = (unsigned long)b->ninc * sizeof(Incoming), rows = (unsigned long)b->nrows * sizeof(Panel) * (W + 1);
  unsigned long extra = sizeof(int32_t) * (4 + 5 * MAXARR), need = head + inc + rows + extra;
  if (!readyKeyBuf) readyKeyBuf = (unsigned char *)grab(READYKEYMAX);
  if (!readyKeyBuf || need > READYKEYMAX) return 0;
  memcpy(&canon, b, head);
  canon.quiet = canon.noQuiet = canon.hi = canon.cdLeft = canon.popSeen = 0; memset(canon.rowActive, 0, sizeof canon.rowActive);
  memset(canon.sCombo, 0, sizeof canon.sCombo); memset(canon.sChainAt, 0, sizeof canon.sChainAt);
  canon.sNCombo = canon.sCleared = canon.sBroke = canon.sEarned = canon.sFell = canon.sHollow = 0; canon.score = 0;
  unsigned char *k = readyKeyBuf;
  memcpy(k, &canon, head); k += head;
  memcpy(k, b->inc, inc); k += inc;
  memcpy(k, b->p, rows); k += rows;
  int32_t q[4 + 5 * MAXARR], nq = 0;
  q[nq++] = nd->holdLeft; q[nq++] = nd->holdStarted; q[nq++] = tight; q[nq++] = nd->narr;
  for (int i = 0; i < nd->narr; i++) { q[nq++] = nd->arr[i].at; q[nq++] = nd->arr[i].width; q[nq++] = nd->arr[i].height; q[nq++] = nd->arr[i].isChain; q[nq++] = nd->arr[i].isMetal; }
  memcpy(k, q, sizeof(int32_t) * (unsigned long)nq); k += sizeof(int32_t) * (unsigned long)nq;
  int32_t nb = (int32_t)(k - readyKeyBuf);
  uint32_t hh = 2166136261u;
  for (int32_t i = 0; i < nb; i++) hh = (hh ^ readyKeyBuf[i]) * 16777619u;
  *h = hh;
  return nb;
}
// (the break kept for the key `key` (nb bytes, hash h): 1 and its line in why, else 0)
static int readyFind(uint32_t h, const unsigned char *key, int32_t nb, int32_t *why, int32_t *whyN) {
  readyLockOn();
  ReadyKept *e = &readyKept[h % READYN];
  int hit = e->bytes && e->h == h && e->nbytes == nb && !memcmp(e->bytes, key, (unsigned long)nb);
  if (hit && why) { for (int i = 0; i < e->whyN; i++) why[i] = e->why[i]; *whyN = e->whyN; }
  readyLockOff();
  return hit;
}
static void readyKeep(uint32_t h, const unsigned char *key, int32_t nb, const int32_t *why, int32_t whyN) {
  unsigned char *fresh = 0;
  if (!readyKept[h % READYN].bytes) fresh = (unsigned char *)grab(READYKEYMAX);
  readyLockOn();
  ReadyKept *e = &readyKept[h % READYN];
  if (!e->bytes) e->bytes = fresh;
  if (e->bytes) {
    memcpy(e->bytes, key, (unsigned long)nb); e->h = h; e->nbytes = nb; e->whyN = whyN;
    for (int i = 0; i < whyN && i < MAXLINE; i++) e->why[i] = why[i];
  }
  readyLockOff();
}
static void readyKeptClear(void) { readyLockOn(); for (int i = 0; i < READYN; i++) readyKept[i].h = 0, readyKept[i].nbytes = 0; readyLockOff(); }
// THE BREAK SEARCH ASKED FOR READINESS, on question q until `by`: 1 a break (its line in line, *k), 0 none in the time, NOT_ASKED the
// decision's time out. Every thread's: what it reads is the question and its own nodes.
static int32_t readySearch(const Question *q, double by, int32_t *line, int32_t *k) {
  int32_t pop = popLeft(q->b), saved = listDefault;
  static LOCAL Broke rb;
  if (clockShare && clockShare < by) by = clockShare;   // (never past the share of the search that asks)
  double old = clockShareBegin(by);
  listDefault = 1;
  breakMoves(q, pop ? pop + LINEUP_AFTER : 0, 0, &rb);
  listDefault = saved;
  clockShareEnd(old);
  *k = 0;
  if (!rb.depth) return clockOut() ? NOT_ASKED : 0;
  if (rb.pathLen) for (; *k < rb.pathLen && *k < MAXLINE; (*k)++) line[*k] = rb.path[*k];
  else if (rb.nmoves) line[(*k)++] = rb.moves[0];
  return 1;
}
// THE READINESS SEARCHED BESIDE THE DECISION (plans/gambit-infra.md E, lazy SMP): while a decision first judges its options (readyDefer),
// each landed board a readiness check will be asked of is kept here (readyPendOf), keyed as the breaks already found are. The workers
// then search them beside the decision (decide.c readySpread: worst-ranked first, each the time the searches have left), while the
// decision asks them best-ranked first in its own shares, exactly as with no workers: whichever thread begins a board first searches
// it (its state claimed), and the other reads the answer -- a break found, or none in the time it had. A worker's break is kept across
// decisions as any is. Only with workers.
#define READYPEND 48
typedef struct { int32_t gen, h, nb, tight, state, whyN, why[MAXLINE]; Node nd; Question q; unsigned char *key; } ReadyPend;
#define PEND_WAITING 0
#define PEND_FOUND 1
#define PEND_NONE 2
#define PEND_OUT 3
#define PEND_BUSY 4   // (being searched)
static ReadyPend readyPend[READYPEND];
static int32_t readyPendN, readyPendGen, readyPre;   // (readyPre: the checks answered here, this decision -- the log's)
static void readyPendClear(void) { readyPendN = 0; readyPendGen++; readyPre = 0; }
static ReadyPend *readyPendFind(uint32_t h, int32_t nb) {
  for (int i = 0; i < readyPendN; i++) {
    ReadyPend *p = &readyPend[i];
    if (p->h == (int32_t)h && p->nb == nb && !memcmp(p->key, readyKeyBuf, (unsigned long)nb)) return p;
  }
  return 0;
}
// (node n's board kept to be searched beside the decision: its index + 1, 0 when it is not -- no room, a break already found, no key)
static int32_t readyPendOf(Ctx *x, int n) {
  Board *b = ensureBoard(x, n);
  if (!b) return 0;
  uint32_t kh = 0;
  int32_t kn = readyKey(b, NODE(x, n), decQ.tight, &kh);
  if (!kn || readyFind(kh, readyKeyBuf, kn, 0, 0)) return 0;
  ReadyPend *p = readyPendFind(kh, kn);
  if (p) return (int32_t)(p - readyPend) + 1;
  if (readyPendN >= READYPEND) return 0;
  p = &readyPend[readyPendN];
  if (!p->key) p->key = (unsigned char *)grab(READYKEYMAX);
  if (!p->q.b) p->q.b = (Board *)grab(sizeof(Board));
  if (!p->key || !p->q.b) return 0;
  memcpy(p->key, readyKeyBuf, (unsigned long)kn); p->h = (int32_t)kh; p->nb = kn;
  cloneBoard(p->q.b, b);
  p->nd = *NODE(x, n);
  p->q.holdLeft = p->nd.holdLeft; p->q.holdStarted = p->nd.holdStarted; p->q.tight = decQ.tight;
  p->q.narr = p->nd.narr; for (int i = 0; i < p->q.narr; i++) p->q.arr[i] = p->nd.arr[i];
  p->tight = pressTight; p->state = PEND_WAITING; p->whyN = 0; p->gen = readyPendGen;
  readyPendN++;
  return readyPendN;
}
static int32_t readyKnownOnly;   // (a check answered only from what is known -- the kept breaks, the workers' -- never searched here)
static int pendClaim(ReadyPend *p) { int32_t w = PEND_WAITING; return __atomic_compare_exchange_n(&p->state, &w, PEND_BUSY, 0, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE); }
static int32_t readyBreakOf(Ctx *x, int n, int32_t *why, int32_t *whyN) {
  if (breakBusy) return NOT_ASKED;
  Board *b = ensureBoard(x, n);
  if (!b) return NOT_ASKED;
  uint32_t kh = 0;
  int32_t kn = readyKey(b, NODE(x, n), decQ.tight, &kh);
  readyAsked++;
  if (kn && readyFind(kh, readyKeyBuf, kn, why, whyN)) { readyHit++; return 1; }
  ReadyPend *p = kn && readyPendN ? readyPendFind(kh, kn) : 0;
  if (p) {
    int32_t st = __atomic_load_n(&p->state, __ATOMIC_ACQUIRE);
    if (st == PEND_NONE) { readyPre++; return 0; }
    if (st == PEND_FOUND) { readyPre++; if (why) { for (int i = 0; i < p->whyN; i++) why[i] = p->why[i]; *whyN = p->whyN; } return 1; }
    if (readyKnownOnly) return NOT_ASKED;
    if (!(st == PEND_WAITING && pendClaim(p))) p = 0;   // (begun beside the decision: searched here too, as it would be alone)
  }
  if (readyKnownOnly) return NOT_ASKED;
  static Question q;
  memset(&q, 0, sizeof q);
  q.b = b; q.holdLeft = NODE(x, n)->holdLeft; q.holdStarted = NODE(x, n)->holdStarted; q.tight = decQ.tight;
  q.narr = NODE(x, n)->narr; for (int i = 0; i < q.narr; i++) q.arr[i] = NODE(x, n)->arr[i];
  int32_t line[MAXLINE], k = 0;
  int32_t r = readySearch(&q, nowMs() + (readyShareMs >= 0 ? readyShareMs : leftMsOf() / 2), line, &k);
  if (p) { if (r == 1) { for (int i = 0; i < k; i++) p->why[i] = line[i]; p->whyN = k; } __atomic_store_n(&p->state, r == 1 ? PEND_FOUND : r == 0 ? PEND_NONE : PEND_OUT, __ATOMIC_RELEASE); }
  if (r != 1) return r;
  if (why) { for (int i = 0; i < k; i++) why[i] = line[i]; *whyN = k; }
  // (the board as keyed before the search: the break search plays it, so it is keyed again from the node)
  if (kn && readyKey(ensureBoard(x, n), NODE(x, n), decQ.tight, &kh) == kn) readyKeep(kh, readyKeyBuf, kn, line, k);
  return 1;
}
// THE JOBS: readySpread's boards in the order it hands them (readyJobs), each searched on whichever worker takes it, if no thread has
// begun it, until its search is done -- or until the next decision takes the pool back (jobStop). A worker's clock begins at the work
// the decision had done (the replay's clock runs on it).
static int32_t readyJobs[READYPEND];
static int64_t readyJobWork;
static double readyJobEnd;
static void readyJob(int32_t i) {
  ReadyPend *p = &readyPend[readyJobs[i]];
  if (!pendClaim(p)) return;
  clockWork = readyJobWork; clockShare = 0; clockAborted = 0; clockPoll = 0;
  inJob = 1; pressTight = p->tight;
  int32_t line[MAXLINE], k = 0;
  int32_t r = readySearch(&p->q, readyJobEnd, line, &k);
  inJob = 0;
  if (r == 1) { for (int q = 0; q < k; q++) p->why[q] = line[q]; p->whyN = k; readyKeep((uint32_t)p->h, p->key, p->nb, line, k); }
  __atomic_store_n(&p->state, r == 1 ? PEND_FOUND : r == 0 ? PEND_NONE : PEND_OUT, __ATOMIC_RELEASE);
}
static int32_t (*readyBreak)(Ctx *x, int n, int32_t *why, int32_t *whyN) = readyBreakOf;
// for a tool that reads a logged board: the fewest swaps to the nearest break on the question's board (NEAR_MISS or more: none)
EXPORT(gb_break_near) int gb_break_near(void) { return hostBoard ? breakNear(hostBoard) : -1; }
