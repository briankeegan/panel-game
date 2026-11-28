// THE JUDGE (plans/decision.md step 3): a line played on the engine as the game will press it --
// `settled`, each step once the board has settled from the last (a planned line); else every step at once, one after the other, the
// board then let settle -- each swap pressed when the frame loop presses it (tight: walked held from two cells, pressDelay). What it
// makes is counted over every step and the settle after: the largest match, the longest chain, the garbage broken -- beyond what the
// board left alone makes (a chain already falling is the line's only when the line adds a link to it; a slab already popping converts
// its panels whatever is pressed).
//
// A step not legal ends the judging there, as a board lost does. Every step is the clock's (step(), core/nodes.h): a judging the clock
// stops comes back `late`, and is no answer.

#define MAXLINE 64
#define NOT_ASKED (-1)   // a readiness not asked, or not finished in time
#define FOREVER 0x7fffffff
#define LOST_FIRST 2     // breaksAfterLanding: the board is lost before everything lands   // a board that stands to the horizon: lostAt

typedef struct {
  int32_t settled, tight;
  int32_t readyAt;                   // frames from now the next block lands (NOT_ASKED: no readiness)
  int32_t readyIfLost, readyIfBreak; // readiness only when the board does not stand to lifeTo -- always, or for a line that breaks
  int32_t lifeTo, lifeRest;          // lostAt: whether the board the line ends on stands to lifeTo, and lifeRest past its last swap (-1: not asked)
  int32_t why;                       // keep the line the readiness found (readyLine)
  int32_t waitAt, waitTo;            // (waitTo > 0) before swap waitAt, the board run to frame waitTo and let settle -- a readiness break
                                     // played where the readiness found it
  int32_t lifeStop;                  // lostAt asked past the stop and shake the line ends on too (dropAt + lifeRest): a board held up by a
                                     // stop stands only if it outlives it
  int32_t rooted;                    // each swap's row named on the root's board: pressed in the row its panels have risen to by then
  const int32_t *notBefore;          // (nNotBefore swaps) the clock each swap's walk was judged to begin on, 0 none: it begins no sooner --
  int32_t nNotBefore;                // the line in progress pressed in the frames it was judged in (decide.c carriedCand)
  int32_t winWait;                   // the line may break garbage: a walk over the window waits for it (judge)
} JudgeOpts;
typedef struct {
  Made made;                    // beyond the board left alone: { combo, chain, broke }
  int32_t keepsChain;           // the board's own chain reached by the frame it reaches it left alone (ownChainBy): 1, 0, -1 not asked
  int32_t noopAt;               // the first swap that swaps straight back the pair the swap before it swapped, nothing moved between (-1 none)
  int64_t sames;                // the swaps (bit k) of two panels of one colour: they move nothing (a row walk past a panel like the one walked)
  int64_t noops;                // every such swap, bit k for swap k
  Made whole;                   // what the board ends up making with the line played, the chain already under way included (garbage
                                // broken still counted beyond the board left alone): a line that cuts a chain short makes the shorter one
  int32_t aloneChain;           // the chain the board left alone makes
  int32_t chainAll;             // the chain the line reaches as the game counts it (the chain already falling and every link after it)
  int32_t chainOpen;            // that chain still falling as the line ends: a link the decisions after can add to it
  int32_t brokeLink;            // the garbage broken by a link of a chain, beyond the board left alone: its panels chain, and the chain lives while it pops
  int32_t singles[MAXCOMBOS], nsingles;   // sizes of 4 or more the line clears as a clear of its own, no link of a chain
  int32_t threes;               // WASTED THREES: the line's clears of three that break nothing and begin no chain, beyond the board left alone's
  int32_t blocks;               // THE BLOCKS THE LINE THROWS, every attack its own (rules.c blocksOf): each clear of four or more a combo's
                                // pieces, each chain a slab a link past the first -- a line that fires two ideas throws both -- beyond what
                                // the board left alone throws
  int32_t dropAt;               // the frame garbage can next drop once the line is over
  int32_t queueAt;              // the frame the engine drops the next queued block with the line played (queueWaits, queueDrops):
                                // NOT_ASKED where none waits behind the board's own motion, or it drops none before the line's loss
  int32_t dead, deadAt, done, fire, nats, ats[MAXLINE];
  int32_t risen[MAXLINE];         // the rows the stack has risen, from the root, by the frame each swap is pressed: its row less this is its row on the root's board
  int32_t clearStep;              // the first step of the line after which something clears, -1 none (the log's cstep=)
  int64_t tightBits;             // the swaps pressed tight -- the input window short: their walks held (the log's tb=)
  int32_t lostAt;               // FOREVER, a frame, or NOT_ASKED
  int32_t ready;                // 1, 0, or NOT_ASKED
  int32_t readyLine[MAXLINE], readyN; // the swaps the readiness found (why), as r * 8 + c
  int32_t readyWait;            // the frame from the root the readiness looked from (its waitTo)
  int32_t readyPend;            // the landed board kept for the decision's readiness, its index + 1 (search/break.c readyPendOf); 0 none
  int32_t readyMat;             // the material that board has -- its panels under the lowest garbage once everything shown has landed
                                // (facts.c materialOn), -1 not asked: what the next breaks are made of
  int32_t readyNear;            // the swaps to the nearest break on that board by the shape math (breakNear, NEAR_MISS none; 0 no
                                // garbage), -1 not asked
  int32_t readyRow1[W + 1];     // the panel ids of the bottom row of the board the readiness break was found on (what anchors it)
  int32_t late;                 // the clock stopped it: no answer
  int32_t aliveTo;              // and the frame from the root the board was judged alive to when it did (0: none)
  int32_t cut;                  // the step a swap was not there to press at (the line played no further), -1 none
  int32_t cutWhy;               // why: 1 its walk over the allowance, 2 no swap there to press, 3 a first walk not begun within a reaction
  int32_t base;                 // the garbage the board left alone breaks, which the line's own is counted beyond
  int32_t clearedPanels;        // the panels the line clears beyond those the board left alone clears
  int32_t endNode;              // the node the line ends on, in judgeCtx (until the next judging)
  int32_t spent;                // the actions the line's swaps were pressed with, by the window's own count (actionsFor)
  int32_t cutAt;                // the row and column the cut swap was to be pressed at (row * 8 + column), 0 none
  int32_t preLast;              // the node the line's last swap was pressed from, in judgeCtx (-1 none)
  int32_t pressedAt[MAXLINE];   // each swap pressed: the row and column it was pressed at (row * 8 + column)
  int32_t even;                 // the board it ends on: its tallest column less its lowest, in rows (evenOf; -1 not known)
  int32_t spread;               // and how its colours are spread (spreadOf): the pairs a swap from a match less the pairs touching
  int32_t seams;                // and its crossed seams (seamsOf): the swaps on it that finish two colours at once
  int32_t swapReady, readyBreak; // and the single swaps on it that make a match, and of those the matches touching garbage (readyOf)
  int32_t pEven;                // and its panel columns' evenness: the tallest panel column less the lowest, garbage not counted (panelEvenOf)
  int32_t perch;                // and its lowest garbage's perch (restsFewOf, vanilla 64b8b34c54): rows its one or two supports stand over the lowest column under it (-1 not known)
  int32_t topRow;               // and whether anything rests in its top row or above (topRowOf: no queued garbage drops then)
  int32_t gap;                  // and the empty cells under its garbage, each column's lowest garbage down to what holds it (gapOf; -1 not known)
} Judged;

static LOCAL Ctx *judgeCtx;   // the judge's own nodes: a search can ask it while its own nodes stand


// THE LIST FOR ONE STEP (attacker stepFits): its own clears, each no link of a chain, and the chain it reaches -- held to the list when
// the decision has handed the searches one (listOn)
static int32_t listOn;
// the break search's lines are held to the list unless it ends by "default" (every list under garbage): there a break is the default's own
static LOCAL int32_t listDefault;
#define BREAK_LIST (listOn && !listDefault)
// Whether the list wants a chain longer than `chain`: an entry a longer chain (within MAXCHAIN) meets.
static int listWantsLonger(const List *L, int32_t chain) {
  for (int i = 0; i < L->n; i++) {
    const Aim *a = &L->aim[i];
    if (!a->chain.op) continue;
    for (int32_t c = chain + 1; c <= MAXCHAIN; c++) if (test(c, a->chain)) return 1;
  }
  return 0;
}
// THE ONE RULE, for whatever list a mode passes -- the list is the mode's priorities, in order, and the only thing a mode changes: after
// its entries, A THREE THAT BREAKS GARBAGE (one clear of three, no chain as the game counts it -- chainAll: the chain the board is in);
// and LAST OF ALL, as they cost the board's panels, a clear that makes a chain or a combo the list does not ask for. Nothing else clears.
// The step check (stepFitsAt) and the line's (outcome.c fitsList) ask it; rules.c withRule puts the three in the searches' list and the
// order's, after the entries; a last resort is outside the list (rank.c), ranked after every line within it.
static int breakingThree(Made m, int32_t chainAll) { return m.broke > 0 && m.combo <= 3 && chainOf(m) <= 1 && chainAll <= 1; }
static int lastResort(Made m, int32_t chainAll) { return m.combo >= 4 || imax(chainOf(m), chainAll) >= 2; }
// A CHAIN BEGUN TOWARD THE LIST: a chain the list wants longer than (within MAXCHAIN) is a beginning of one it asks for while it is
// still falling -- the decisions after add its links (extend), so one short of the ask is on its way to it. A step's (stepFitsAt) mid
// line; a whole line's (outcome.c fitsList) only where its chain is still falling as it ends: a chain over is the size it ended at.
static int chainBegins(const List *L, int32_t chain) { return chain >= 2 && chain <= MAXCHAIN && listWantsLonger(L, chain); }
// A STEP WITHIN THE RULE: an entry, a three that breaks, a last resort -- or a plain three on a board still falling, a chain's first
// link; the whole line is held to the rule as it ends (lineFits).
static int stepFitsAt(Ctx *x, int i) {
  if (!listOn) return 1;
  Stats s;
  if (!statsOf(x, i, &s)) return 0;
  int32_t own[MAXCOMBOS], n = 0;
  for (int j = 0; j < s.n; j++) if (!(s.chainAt[j] > 1)) own[n++] = s.size[j];
  int32_t chain = chainOfStats(&s);
  int32_t biggest = 0;
  for (int k = 0; k < n; k++) if (own[k] > biggest) biggest = own[k];
  Made sm = { biggest, chain, s.broke, 0 };
  if (breakingThree(sm, chain) || stepFits(&theList, own, n, chain)) return 1;
  if (chain > MAXCHAIN) return 0;
  if (lastResort(sm, chain)) return 1;
  Board *b = ensureBoard(x, i);
  return b && (b->chainCounter > 0 || hasChainingPanels(b) || hasActivePanels(b));
}
static int settleOf(Ctx *x, int i) { return step(x, i, MK_SETTLE, 0, 0, 0); }
// (the garbage a step broke where one of its clears was a link that touched it: pa.c converts it chaining)
static int32_t linkBrokeOf(const Stats *s) { for (int j = 0; j < s->n; j++) if (s->link[j] && s->touch[j]) return s->broke; return 0; }
// (a step's wasted threes: its clears of three, no link of a chain, in a step that breaks nothing and makes no chain)
// A WASTED THREE -- the one test, the judge's (firstThree) and the press guard's (front.c wastedSwap): g the board on the frame its swap
// is pressed, a the same board with it not pressed, both played on FIRST_LOOK frames side by side -- the first clear g makes that a does
// not (the panels matched on the first frame any are, as the game counts a clear), exactly three -- and then on till both are still
// (THREE_SETTLE at most): g's fall no longer a chain than a's, and no garbage broken that a's left whole. g and a are played on (the
// caller's copies).
#define FIRST_LOOK 30
static int garbageCells(const Board *b) { int n = 0; for (int r = 1; r < b->nrows; r++) for (int c = 1; c <= W; c++) n += !!b->p[r][c].f[ISGARBAGE]; return n; }
#define THREE_SETTLE 400
static int wastedThree(Board *g, Board *a) {
  static LOCAL int32_t was[MAXROWS * W * 2], got[MAXROWS * W * 2];
  int nw = 0, ng = 0, touch = 0, first = -1;
  static const int DR[4] = { 1, -1, 0, 0 }, DC[4] = { 0, 0, 1, -1 };
  for (int f = 0; f < FIRST_LOOK && g->gameOverClock <= 0; f++) {
    run(g); run(a); g->input = a->input = 0; g->pressSwap = a->pressSwap = 0;
    for (int r = 1; r < a->nrows; r++) for (int c = 1; c <= W; c++) {
      const int32_t *p = a->p[r][c].f;
      if (p[STATE] != MATCHED || p[ISGARBAGE]) continue;
      int old = 0; for (int q = 0; q < nw && !old; q++) old = was[q] == p[ID];
      if (!old && nw < MAXROWS * W * 2) was[nw++] = p[ID];
    }
    for (int r = 1; r < g->nrows; r++) for (int c = 1; c <= W; c++) {
      const int32_t *p = g->p[r][c].f;
      if (p[STATE] != MATCHED || p[ISGARBAGE]) continue;
      int old = 0; for (int q = 0; q < nw && !old; q++) old = was[q] == p[ID];
      for (int q = 0; q < ng && !old; q++) old = got[q] == p[ID];
      if (old || ng >= MAXROWS * W * 2 || (first >= 0 && f != first)) continue;
      first = f; got[ng++] = p[ID];
      for (int d = 0; d < 4; d++) { int rr = r + DR[d], cc = c + DC[d]; if (rr >= 1 && rr < g->nrows && cc >= 1 && cc <= W && g->p[rr][cc].f[ISGARBAGE]) touch = 1; }
    }
  }
  // (a panel of the three the board alone matches later is the board's own, not the swap's)
  int n = 0; for (int q = 0; q < ng; q++) { int own = 0; for (int k = 0; k < nw && !own; k++) own = was[k] == got[q]; n += !own; }
  if (n != 3) return 0;
  int32_t gc = g->chainCounter, ac = a->chainCounter;
  for (int k = 0; k < THREE_SETTLE && g->gameOverClock <= 0; k++) {
    run(g); if (a->gameOverClock <= 0) run(a);
    gc = imax(gc, g->chainCounter); ac = imax(ac, a->chainCounter);
    if (g->chainCounter == 0 && !hasActivePanels(g) && a->chainCounter == 0 && !hasActivePanels(a)) break;
  }
  // (beside garbage, a three that breaks it is no waste -- but only one the engine lets break it: a block still falling, landing or
  // off the screen is not broken by a clear beside it (pa.c getConnectedGarbagePanels: its panels at rest and on screen), so the three
  // pressed against it too soon breaks nothing and is wasted like any other)
  if (touch && garbageCells(g) < garbageCells(a)) return 0;
  return !(gc >= 2 && gc > ac);   // (its fall made a link the board's own did not)
}
// THE BOARD'S OWN CHAIN SPOILED (rank.c cutsShort, a line at a time): g the board with the swap pressed and every key after it the line
// presses (keyAt: the bits on the f-th frame after the press), a the same board left alone, both played to rest, the garbage on its way
// landing on each as the game lands it (land) -- a's chain two or more
// and g's shorter, no more garbage broken: the three that began the board's chain made for nothing. g and a are played on.
static int spoilsChain(Board *g, Board *a, int32_t (*keyAt)(int32_t f), void (*land)(Board *g, Board *a)) {
  int32_t gc = g->chainCounter, ac = a->chainCounter;
  for (int f = 0; f < FIRST_LOOK + THREE_SETTLE && g->gameOverClock <= 0; f++) {
    run(g); if (a->gameOverClock <= 0) run(a);
    if (land) land(g, a);
    int32_t k = keyAt ? keyAt(f) : 0;
    g->input = k & ~(IN_SWAP | IN_RAISE); g->pressSwap = !!(k & IN_SWAP); a->input = 0; a->pressSwap = 0;
    gc = imax(gc, g->chainCounter); ac = imax(ac, a->chainCounter);
    if (f >= FIRST_LOOK && g->chainCounter == 0 && !hasActivePanels(g) && a->chainCounter == 0 && !hasActivePanels(a)) break;
  }
  return ac >= 2 && gc < ac && garbageCells(g) >= garbageCells(a) && ownChainAsked(ac);
}
// THE FIRST SWAP'S OWN CLEAR (the line's wasted three, as the game makes it): the board the swap is pressed on beside the board left
// alone as long, by the one test
static int32_t firstThree(Ctx *x, int root, int mr, int mc) {
  int a = step(x, root, MK_SWAP, mr, mc, 0);
  if (!liveNode(x, a)) return 0;
  int al = NODE(x, a)->t > NODE(x, root)->t ? step(x, root, MK_LONG, 0, 0, NODE(x, a)->t - NODE(x, root)->t) : root;
  const Board *ba = ensureBoard(x, a), *bl = liveNode(x, al) ? ensureBoard(x, al) : 0;
  if (!ba || !bl) return 0;
  Board *g = nb_new(), *h = nb_new();
  int w = g && h ? (cloneBoard(g, ba), cloneBoard(h, bl), wastedThree(g, h)) : 0;
  if (g) nb_free(g);
  if (h) nb_free(h);
  return w;
}
// (a step's wasted threes, as the game's own count reads them (front.c countAttacks), a clear at a time: a clear of three that is no link
// of a chain and has no garbage joined to it -- and no chain's link after it in the step, which its fall may have made)
static int32_t threesOf(const Stats *s) {
  int32_t n = 0;
  for (int j = 0; j < s->n; j++) {
    if (s->size[j] != 3 || s->link[j] || s->touch[j]) continue;
    // (the link right after it makes it the first of a chain; a clear between that is no link begins a chain of its own -- a step long
    // enough holds the next chain too, and a three that stood alone is not made a link by one begun after)
    int later = 0; for (int q = j + 1; q < s->n && !later; q++) { if (s->link[q]) later = 1; else break; }
    if (!later) n++;
  }
  return n;
}

// (the garbage the board left alone has broken by frame t, from the board landed: cached per frame)
static int32_t still_(Ctx *x, int land, int32_t t, int32_t *idleT, int32_t *idleB, int32_t *nIdle) {
  for (int i = 0; i < *nIdle; i++) if (idleT[i] == t) return idleB[i];
  int w = t > NODE(x, land)->t ? step(x, land, MK_LONG, 0, 0, t - NODE(x, land)->t) : land;
  int32_t b = liveNode(x, w) ? NODE(x, w)->brk : NODE(x, land)->brk;
  if (*nIdle < 64) { idleT[*nIdle] = t; idleB[*nIdle] = b; (*nIdle)++; }
  return b;
}
// (and the board it breaks on lives through the break's settle, its clears within the list)
static int settles(Ctx *x, int o) { int z = settleOf(x, o); return liveNode(x, z) && stepFitsAt(x, z); }
// READY ONCE EVERYTHING LANDS (attacker breaksAfterLanding): the board the line ends on run to `wait` frames after the root and let
// settle, then a break on it -- the break search's own answer (search/break.c readyBreak), bounded by its share of the time and by no
// count of swaps. 1, 0, LOST_FIRST when the board is lost before it lands, or NOT_ASKED when the clock stops it. why: the break's line.
// readyDefer: the break is not asked (NOT_ASKED), only whether the board lives to the landing -- the decision ranks first and asks it
// of the best-ranked in the time left (decide.c ranked).
static int32_t (*readyBreak)(Ctx *x, int n, int32_t *why, int32_t *whyN);
static int32_t readyPendOf(Ctx *x, int n);
static int readyDefer;
// readyCollect: and while it is deferred, the landed board kept -- searched once a decision, by whichever thread begins it
// (readyPendLast: which) -- and how near a break it is by the shape math (readyNearLast), what the decision asks it in the order of
static int32_t readyCollect; static LOCAL int32_t readyPendLast, readyNearLast, readyMatLast;
static int32_t materialOn(const Board *b);   // (facts.c)
static int nearOf(const Board *b); static int garbageOn(const Board *b);   // (search/break.c)
static LOCAL int32_t readyRow1Buf[W + 1];
// A LINE'S ANCHOR: a bottom-row cell's id, where the cell is a coloured panel at rest -- an empty cell keeps its id too, and goes up
// the stack as each panel above it falls into its place (pa.c switchPanels), so a line anchored to one is found rows above where it was
static int32_t anchorIdAt(const Board *b, int c) {
  if (!b || b->nrows < 2) return NUL;
  const int32_t *f = b->p[1][c].f;
  return f[COLOR] && !f[ISGARBAGE] && f[STATE] == NORMAL ? f[ID] : NUL;
}
static int32_t breaksAfterLanding(Ctx *x, int n, int32_t wait, int32_t *why, int32_t *whyN) {
  readyPendLast = 0; readyNearLast = -1; readyMatLast = -1;
  // (a line that ends past the landing is ready from where it ends -- never a frame on: the same trajectory, asked from any root,
  // lands on the same board, so a break found on it once is found again by its key)
  int dt = wait - NODE(x, n)->t;
  int land = dt > 0 ? step(x, n, MK_LONG, 0, 0, dt) : n;
  if (!liveNode(x, land)) return clockOut() ? NOT_ASKED : LOST_FIRST;
  if (readyDefer && !readyCollect) return NOT_ASKED;
  int calm = settleOf(x, land);
  if (liveNode(x, calm)) land = calm;
  if (readyDefer) {
    Board *lb = ensureBoard(x, land);
    readyNearLast = lb ? (garbageOn(lb) ? nearOf(lb) : 0) : -1;
    readyMatLast = lb ? materialOn(lb) : -1;
    readyPendLast = readyPendOf(x, land);
    return NOT_ASKED;
  }
  { Board *lb = ensureBoard(x, land); for (int c = 1; c <= W; c++) readyRow1Buf[c] = anchorIdAt(lb, c);
    readyMatLast = lb ? materialOn(lb) : -1; }
  if (clockOut()) return NOT_ASKED;
  return readyBreak(x, land, why, whyN);
}

// A board lost left alone (attacker lostAlone): the first frame from the root the board at node n, left alone, is lost before `to` --
// FOREVER when it is alive at `to`.
static int32_t lostAlone(Ctx *x, int n, int32_t to) {
  int w = step(x, n, MK_LONG, 0, 0, imax(1, to - NODE(x, n)->t));
  if (w == STEP_DEAD) return deadAt;
  if (w < 0) return NOT_ASKED;   // (the clock stopped it, or the step was refused: no answer -- never a loss at 0)
  return NODE(x, w)->dead ? NODE(x, w)->t : FOREVER;
}
// (a step with the walk tapped, as the frame loop's keys are made before it holds them: where a press is taken -- pressWalk)
static int stepTapped(Ctx *x, int pi, int kind, int mr, int mc, int32_t frames) {
  int32_t t = pressTight; pressTight = 0;
  int r = step(x, pi, kind, mr, mc, frames);
  pressTight = t;
  return r;
}
// THE BOARD'S OWN CHAIN (ownChainOf, each decision a chain falls): the frame the board left alone makes its last link, and that link --
// a line keeps the chain only where its board has reached that link by that frame (keepsChain). The links of a chain the line begins
// count from 2 as the board's do (pa.c chainCounter), so what a line's clears make cannot tell them apart; the frame can.
static int32_t ownChainBy, ownChainN;
static LOCAL Ctx *chainCtx;
static void ownChainOf(const Question *q) {
  ownChainBy = ownChainN = 0;
  Ctx *x = chainCtx = ctxOf(chainCtx);
  int n = rootOf(x, q);
  if (n < 0) return;
  int32_t most = 0, at = 0;
  for (int f = 0; f < SETTLE_CAP; f++) {
    int w = step(x, n, MK_LONG, 0, 0, 1);
    if (!liveNode(x, w)) break;
    Board *b = ensureBoard(x, w);
    if (!b) break;
    if (b->chainCounter > most) { most = b->chainCounter; at = NODE(x, w)->t; }
    if ((most > 0 && b->chainCounter == 0) || (f > 3 && b->quiet && !b->chainCounter)) break;
    n = w;
  }
  if (most >= 2) { ownChainBy = at; ownChainN = most; }
}
// THE JUDGE: the line seq (n swaps, r * 8 + c) from the question, as the options say.
// HOW FLAT A BOARD IS: its tallest column less its lowest, in rows -- panels and garbage alike, the stack as it stands
// (CHAOS, THE GARBAGE HELD UP: the empty cells between each column's lowest garbage cell and the first thing under it -- the canyon a
// piece is perched over, out of reach of any break until the panels under it are built back up. Run 92 insane s16 17400-18158: the middle
// cleared under garbage resting on the edge towers, more landing on top, lost at 18633)
static int32_t gapOf(const Board *b) {
  int32_t gap = 0;
  for (int c = 1; c <= W; c++) {
    int g = 0;
    for (int r = 1; r < b->nrows; r++) if (b->p[r][c].f[ISGARBAGE]) { g = r; break; }
    if (!g) continue;
    for (int r = g - 1; r >= 1 && b->p[r][c].f[COLOR] <= 0 && !b->p[r][c].f[ISGARBAGE]; r--) gap++;
  }
  return gap;
}
// (CHAOS, THE TOP ROW TAKEN: a panel or garbage in the top row or above -- Stack:shouldDropGarbage drops nothing waiting then)
static int32_t topRowOf(const Board *b) {
  int h = b->height ? b->height : 12;
  for (int r = h; r < b->nrows; r++) for (int c = 1; c <= W; c++) if (b->p[r][c].f[COLOR] > 0 || b->p[r][c].f[ISGARBAGE]) return 1;
  return 0;
}
// (CHAOS, THE COLOURS LINED UP: the single swaps on a board -- two panels side by side, both at rest -- that make a match where they
// land, and of those the ones whose match touches garbage: the breaks a swap away. At 8 colours a match seldom arrives by itself; the
// board kept with matches a swap away is the one the next garbage is broken on (the owner: be more purposeful with colours))
static int gridMatchAt(int g[][W + 2], int nr, int r, int cc, int *touch) {
#define GG(r, c) ((r) >= 1 && (r) < nr && (c) >= 1 && (c) <= W ? g[r][c] : 0)
  int v = g[r][cc]; if (v <= 0) return 0;
  int lo = cc, hi = cc, dn = r, up = r;
  while (GG(r, lo - 1) == v) lo--; while (GG(r, hi + 1) == v) hi++;
  while (GG(dn - 1, cc) == v) dn--; while (GG(up + 1, cc) == v) up++;
  int h = hi - lo + 1 >= 3, vv = up - dn + 1 >= 3;
  if (!h && !vv) return 0;
  if (h) for (int q = lo; q <= hi; q++) if (GG(r + 1, q) == -1 || GG(r - 1, q) == -1 || GG(r, q - 1) == -1 || GG(r, q + 1) == -1) *touch = 1;
  if (vv) for (int q = dn; q <= up; q++) if (GG(q + 1, cc) == -1 || GG(q - 1, cc) == -1 || GG(q, cc - 1) == -1 || GG(q, cc + 1) == -1) *touch = 1;
#undef GG
  return 1;
}
// (the single swaps on a grid of colours -- -1 garbage, -2 a panel not at rest, 0 empty -- that make a match, and those touching garbage)
static void gridReady(int g[][W + 2], int nr, int32_t *ready, int32_t *readyBreak) {
  int32_t n = 0, nb = 0;
  for (int r = 1; r < nr; r++) for (int c = 1; c < W; c++) {
    int a = g[r][c], bb = g[r][c + 1];
    if (a <= 0 || bb <= 0 || a == bb) continue;
    g[r][c] = bb; g[r][c + 1] = a;
    int touch = 0, made = gridMatchAt(g, nr, r, c, &touch) | gridMatchAt(g, nr, r, c + 1, &touch);
    g[r][c] = a; g[r][c + 1] = bb;
    n += made; nb += made && touch;
  }
  *ready = n; *readyBreak = nb;
}
static int gridOf(const Board *b, int g[][W + 2]) {
  int nr = b->nrows < 64 ? b->nrows : 64;
  for (int r = 0; r < nr; r++) for (int c = 0; c <= W + 1; c++) {
    if (r < 1 || c < 1 || c > W) { g[r][c] = 0; continue; }
    const int32_t *f = b->p[r][c].f;
    g[r][c] = f[ISGARBAGE] ? -1 : (f[COLOR] > 0 && f[STATE] == NORMAL) ? f[COLOR] : (f[COLOR] > 0 ? -2 : 0);
  }
  return nr;
}
static void readyOf(const Board *b, int32_t *ready, int32_t *readyBreak) {
  static LOCAL int g[64][W + 2];
  int nr = gridOf(b, g);
  gridReady(g, nr, ready, readyBreak);
}
// (run 116, CHAOS, TWO SWAPS THAT LINE COLOURS UP: the best pair of swaps -- the first making no match, the second any swap after it
// making none -- by the breaks a swap away they leave (4 each) then the matches a swap away, where the pair beats every single swap: at
// 8 colours the row under the garbage seldom needs one move to be stocked (run 115 thicc s6: one panel under a 2-row slab, no break in
// reach, held until the stop ran out). Moves as row * 8 + column into out[0..1]; 1 found, 0 none)
static int lineUpPair(const Board *b, int32_t *out) {
  static LOCAL int g[64][W + 2];
  int nr = gridOf(b, g);
  int32_t r0, b0; gridReady(g, nr, &r0, &b0);
  int32_t base = 4 * b0 + r0, best1 = base, best2 = base; int32_t m1 = -1, m2 = -1;
  for (int r = 1; r < nr; r++) for (int c = 1; c < W; c++) {
    int a = g[r][c], bb = g[r][c + 1];
    if (a <= 0 || bb <= 0 || a == bb) continue;
    g[r][c] = bb; g[r][c + 1] = a;
    int t = 0;
    if (!(gridMatchAt(g, nr, r, c, &t) | gridMatchAt(g, nr, r, c + 1, &t))) {
      int32_t rr, rb; gridReady(g, nr, &rr, &rb); if (4 * rb + rr > best1) best1 = 4 * rb + rr;
      for (int r2 = (r > 2 ? r - 2 : 1); r2 < nr && r2 <= r + 2; r2++) for (int c2 = 1; c2 < W; c2++) {
        if (r2 == r && c2 == c) continue;
        int a2 = g[r2][c2], b2 = g[r2][c2 + 1];
        if (a2 <= 0 || b2 <= 0 || a2 == b2) continue;
        g[r2][c2] = b2; g[r2][c2 + 1] = a2;
        int t2 = 0;
        if (!(gridMatchAt(g, nr, r2, c2, &t2) | gridMatchAt(g, nr, r2, c2 + 1, &t2))) {
          int32_t r3, b3; gridReady(g, nr, &r3, &b3);
          if (4 * b3 + r3 > best2) { best2 = 4 * b3 + r3; m1 = r * 8 + c; m2 = r2 * 8 + c2; }
        }
        g[r2][c2] = a2; g[r2][c2 + 1] = b2;
      }
    }
    g[r][c] = a; g[r][c + 1] = bb;
  }
  if (m1 < 0 || best2 <= best1) return 0;
  out[0] = m1; out[1] = m2; return 1;
}
// (run 113, CHAOS, THE SWAPS THAT LINE COLOURS UP: of the single swaps on the board -- two resting panels side by side, making no match
// themselves -- the best `max` by the breaks a swap away they leave (4 each), then the matches a swap away, and only those better than
// the board as it stands; at 8 colours the board's waiting time is spent on these, not the hold (run 110 chain s4: 284 frames of stop
// held, three lines offered, none a set-up). Moves as row * 8 + column. Returns how many)
static int lineUpSwaps(const Board *b, int32_t *out, int max) {
  static LOCAL int g[64][W + 2];
  int nr = gridOf(b, g), n = 0;
  int32_t r0, b0; gridReady(g, nr, &r0, &b0);
  int32_t base = 4 * b0 + r0, best[8] = { 0 }; int32_t mv[8];
  if (max > 8) max = 8;
  for (int r = 1; r < nr; r++) for (int c = 1; c < W; c++) {
    int a = g[r][c], bb = g[r][c + 1];
    if (a <= 0 || bb <= 0 || a == bb) continue;
    g[r][c] = bb; g[r][c + 1] = a;
    int t = 0, made = gridMatchAt(g, nr, r, c, &t) | gridMatchAt(g, nr, r, c + 1, &t);
    int32_t rr = 0, rb = 0; if (!made) gridReady(g, nr, &rr, &rb);
    g[r][c] = a; g[r][c + 1] = bb;
    int32_t sc = 4 * rb + rr;
    if (made || sc <= base) continue;
    int k = n < max ? n++ : max - 1;
    if (k == max - 1 && n == max && sc <= best[k]) continue;
    best[k] = sc; mv[k] = r * 8 + c;
    while (k > 0 && best[k] > best[k - 1]) { int32_t t1 = best[k]; best[k] = best[k - 1]; best[k - 1] = t1; t1 = mv[k]; mv[k] = mv[k - 1]; mv[k - 1] = t1; k--; }
  }
  for (int i = 0; i < n; i++) out[i] = mv[i];
  return n;
}
// (CHAOS, THE PANELS' OWN SHAPE: the tallest column of panels less the lowest, garbage never counted -- a canyon under garbage resting on
// towers reads flat to evenOf, whose tops are the garbage's)
static int32_t panelEvenOf(const Board *b) {
  int hi = 0, lo = 1 << 20;
  for (int c = 1; c <= W; c++) {
    int h = 0;
    for (int r = 1; r < b->nrows; r++) { if (b->p[r][c].f[ISGARBAGE]) break; if (b->p[r][c].f[COLOR] > 0) h = r; }
    if (h > hi) hi = h; if (h < lo) lo = h;
  }
  return hi - lo;
}
// HOW PERCHED ITS LOWEST GARBAGE IS (vanilla GameCreator 64b8b34c54/14e8ee600c, ported run 304): where the lowest row holding garbage holds
// it three columns wide or more and one or two columns under it touch it, the rows they stand over the lowest column under the garbage (0
// otherwise, or no garbage) -- a block resting on one column, or bridged over two, is touched by the panels of those columns alone, and the
// clears beside them lower the rest and leave it hanging
static int32_t restsFewOf(const Board *b) {
  int low = 0;
  for (int r = 1; r < b->nrows && !low; r++) for (int c = 1; c <= W; c++) if (gridCell(b, r, c) < 0) { low = r; break; }
  if (!low) return 0;
  int span = 0, sup = 0, lo = 1 << 20;
  for (int c = 1; c <= W; c++) {
    if (gridCell(b, low, c) >= 0) continue;
    int top = 0; for (int r = 1; r < low; r++) if (gridCell(b, r, c) > 0) top = r;
    span++; if (top == low - 1) sup++; if (top < lo) lo = top;
  }
  return span >= 3 && sup >= 1 && sup <= 2 ? low - 1 - lo : 0;
}
static int32_t evenOf(const Board *b) {
  int hi = 0, lo = 1 << 20;
  for (int c = 1; c <= W; c++) {
    int h = 0;
    for (int r = 1; r < b->nrows; r++) if (b->p[r][c].f[COLOR] > 0 || b->p[r][c].f[ISGARBAGE]) h = r;
    if (h > hi) hi = h; if (h < lo) lo = h;
  }
  return hi - lo;
}
// HOW A BOARD'S COLOURS ARE SPREAD (plans/gambit-combos.md, the players' stacks): of its panels at rest, the pairs of a colour a swap
// from a match -- one cell apart in a column or a row with another colour between, or on a diagonal -- less the pairs of a colour
// touching. The players who make the big combos keep few of a colour touching and many a swap apart
static int32_t spreadOf(const Board *b) {
  int32_t staged = 0, touching = 0;
#define SC(r, c) ((r) >= 1 && (r) < b->nrows && (c) >= 1 && (c) <= W && !b->p[r][c].f[ISGARBAGE] && b->p[r][c].f[STATE] == NORMAL ? b->p[r][c].f[COLOR] : 0)
  for (int r = 1; r < b->nrows; r++) for (int c = 1; c <= W; c++) {
    int32_t v = SC(r, c);
    if (v <= 0) continue;
    if (SC(r + 1, c) == v) touching++;
    if (SC(r, c + 1) == v) touching++;
    if (SC(r + 2, c) == v && SC(r + 1, c) > 0 && SC(r + 1, c) != v) staged++;
    if (SC(r, c + 2) == v && SC(r, c + 1) > 0 && SC(r, c + 1) != v) staged++;
    if (SC(r + 1, c - 1) == v) staged++;
    if (SC(r + 1, c + 1) == v) staged++;
  }
#undef SC
  return staged - touching;
}
// A BOARD'S CROSSED SEAMS (plans/gambit-combos.md, the players' 8+ combos): of its panels at rest, the side-by-side pairs of two
// colours whose swap finishes a match of each -- the panel that moves right completes a line of three or more of its colour there, in
// its new column or its row onward, and the one that moves left the same on its side. Every 8+ combo the players made is one of these
static int32_t seamsOf(const Board *b) {
  int32_t n = 0;
#define SC(r, c) ((r) >= 1 && (r) < b->nrows && (c) >= 1 && (c) <= W && !b->p[r][c].f[ISGARBAGE] && b->p[r][c].f[STATE] == NORMAL ? b->p[r][c].f[COLOR] : 0)
  for (int r = 1; r < b->nrows; r++) for (int c = 1; c < W; c++) {
    int32_t a = SC(r, c), z = SC(r, c + 1);
    if (a <= 0 || z <= 0 || a == z || a >= 8 || z >= 8) continue;
    // (a lands at c+1: its column there, and its row on past c+1; z lands at c: its column there, and its row on before c)
    int up = 0, dn = 0, run = 0;
    for (int k = r + 1; SC(k, c + 1) == a; k++) up++;
    for (int k = r - 1; SC(k, c + 1) == a; k--) dn++;
    for (int k = c + 2; SC(r, k) == a; k++) run++;
    int fa = up + dn >= 2 || run >= 2;
    up = dn = run = 0;
    for (int k = r + 1; SC(k, c) == z; k++) up++;
    for (int k = r - 1; SC(k, c) == z; k--) dn++;
    for (int k = c - 1; SC(r, k) == z; k--) run++;
    if (fa && (up + dn >= 2 || run >= 2)) n++;
  }
#undef SC
  return n;
}
// (the rows a node's board has risen since the root's: the rows newRow made since (pa.c) -- each a fed row taken, or one dealt unseen;
// nothing is fed while a line is judged, so the root's count of each against the node's. A count, not a panel: a panel's row moves with
// every clear under it, and a cleared panel's id rises with its empty cell)
static LOCAL int32_t rootFeed, rootUnseen;
static int risenTo(Ctx *x, int node, int32_t any) {
  const Board *b = any == NUL ? 0 : ensureBoard(x, node);
  if (!b) return 0;
  int r = (rootFeed - b->nRowFeed) + (b->unseenRows - rootUnseen);
  return r > 0 ? r : 0;
}
// A QUEUE HELD OFF BY THE BOARD'S OWN MOTION: garbage queued and none on the board. The engine drops a queued one-row block on the
// first frame no panel moves (pa.c shouldDropGarbage), and a falling block locks the rise (updateRiseLock), so no raise goes in between.
// A clear made meanwhile only moves that frame: the same blocks land, on a board with the clear's panels gone -- the frames it puts the
// drop off are no part of how long its board lasts (outcome.c putOff).
static int queueWaits(const Board *b) {
  if (!b || b->ninc <= 0) return 0;
  for (int r = 1; r < b->nrows; r++) for (int c = 1; c <= W; c++) if (b->p[r][c].f[ISGARBAGE]) return 0;
  return 1;
}
// (the frames until the engine next drops a queued block on board b left alone, `most` at most; NOT_ASKED when it drops none by then)
static LOCAL Board *queueBoard;
static int32_t queueDropIn(const Board *b, int32_t most) {
  if (!queueBoard) queueBoard = nb_new();
  if (!queueBoard || !b || most <= 0) return NOT_ASKED;
  cloneBoard(queueBoard, b);
  int32_t made = b->garbageCreatedCount, f = 0;
  while (f < most && queueBoard->gameOverClock <= 0 && queueBoard->garbageCreatedCount == made) { queueBoard->input = 0; run(queueBoard); f++; }
  clockCharge(f);
  return queueBoard->garbageCreatedCount != made ? f : NOT_ASKED;
}
// (and with a line played to node `end` of x from `root`, by frame `by` from the root at the latest: the first of the line's steps whose
// board has taken a block from the queue, played again a frame at a time from the last key it pressed)
static int32_t queueDrops(Ctx *x, int root, int end, int32_t by) {
  int path[4 * MAXLINE + 8], np = 0;
  for (int m = end; m >= 0 && np < 4 * MAXLINE + 8; m = NODE(x, m)->prev) { path[np++] = m; if (m == root) break; }
  if (!np || path[np - 1] != root) return NOT_ASKED;
  const Board *rb = ensureBoard(x, root);
  if (!rb) return NOT_ASKED;
  int32_t made = rb->garbageCreatedCount, t0 = NODE(x, root)->t;
  for (int i = np - 2; i >= 0; i--) {
    int m = path[i], p = path[i + 1];
    const Board *mb = ensureBoard(x, m);
    if (!mb) return NOT_ASKED;
    if (mb->garbageCreatedCount == made) continue;
    // (the step it dropped in: one that presses nothing is the board before it left alone; one that presses a swap, the swap pressed
    // alone and the board left alone from there -- a block dropped by the press came no later than the board left alone drops it)
    int from = p;
    if (NODE(x, m)->mr > 0 && (NODE(x, m)->mk == MK_SWAP || NODE(x, m)->mk == MK_SETTLE)) {
      if (clockOut()) return NOT_ASKED;
      from = advance(x, p, MK_SWAP, NODE(x, m)->mr, NODE(x, m)->mc, 0);
      if (!liveNode(x, from)) return NOT_ASKED;
      clockCharge(NODE(x, from)->t - NODE(x, p)->t);
      const Board *fb = ensureBoard(x, from);
      if (!fb) return NOT_ASKED;
      if (fb->garbageCreatedCount != made) return NODE(x, p)->t - t0;
    }
    int32_t f = queueDropIn(ensureBoard(x, from), NODE(x, m)->t - NODE(x, from)->t);
    return (f == NOT_ASKED ? NODE(x, m)->t : NODE(x, from)->t + f) - t0;
  }
  // (none by the line's end: the board it ends on left alone)
  int32_t f = queueDropIn(ensureBoard(x, end), by - (NODE(x, end)->t - t0));
  return f == NOT_ASKED ? NOT_ASKED : NODE(x, end)->t - t0 + f;
}
// (winWaitOff: a swap whose walk is over the window is cut, never waited for; winWaitAgain: the line waited for the window and broke
// no garbage -- judge)
static LOCAL int32_t winWaitOff, winWaitAgain;
static void judgeOnce(const Question *q, const int32_t *seq, int nseq, const JudgeOpts *o, Judged *j) {
  memset(j, 0, sizeof *j);
  winWaitAgain = 0;
  j->lostAt = NOT_ASKED; j->queueAt = NOT_ASKED; j->ready = NOT_ASKED; j->threes = 0; j->fire = -1; j->cut = -1; j->cutWhy = 0; j->readyNear = -1; j->readyMat = -1; j->noopAt = -1; j->clearStep = -1; j->preLast = -1; j->noops = 0; j->sames = 0;
  Ctx *x = judgeCtx = ctxOf(judgeCtx);
  int root = rootOf(x, q), n = root;
  if (root < 0) { j->dead = 1; return; }
  // (the root's row counts, read again on each board a swap is pressed from: the rows risen by then -- risenTo)
  int32_t rid = NUL; { const Board *rb = ensureBoard(x, root); if (rb) { rootFeed = rb->nRowFeed; rootUnseen = rb->unseenRows; rid = 1; } }
  int base = settleOf(x, root);
  int32_t baseChain = 0, baseCombo = 0, baseBroke = 0;
  Stats bs;
  int32_t baseThrees = 0, threes = 0;
  int32_t baseCleared = 0, clearedAll = 0;
  int32_t baseLink = 0, brokeLink = 0;
  if (liveNode(x, base) && statsOf(x, base, &bs)) { baseLink = linkBrokeOf(&bs); baseBroke = bs.broke; baseCleared = bs.cleared; baseThrees = threesOf(&bs); if (bs.cleared > 0) { baseChain = chainOfStats(&bs); baseCombo = biggestOf(&bs); } }
  j->base = baseBroke;
  int32_t combo = 0, chain = 0, broke = 0, lastAt = 0, single[MAXCOMBOS + 64] = { 0 }, pieces = 0, links = 0;
  int32_t spent = 0, tight0 = pressTight;   // (the actions the line's swaps spend, and the decision's tightness, put back at the end)
  int winWaited = -1;   // (the first swap whose walk waited for the window)
  int kb = root;   // (the line's last node by ownChainBy)
  int32_t prevA = NUL, prevB = NUL;   // (the pair the swap before swapped, its ids as it was pressed: a swap back of it is a no-op)
#define KB(m) do { if (ownChainBy > 0 && liveNode(x, (m)) && NODE(x, (m))->t <= ownChainBy) kb = (m); } while (0)
  for (int k = 0; k <= nseq; k++) {
    int last = k == nseq, mr = last ? 0 : CR(seq[k]), mc = last ? 0 : CC(seq[k]);
    if (k == nseq - 1) j->preLast = n;
    if (last && o->settled) break;   // (each step settled already)
    if (o->waitTo > 0 && k == o->waitAt) {
      int w = step(x, n, MK_LONG, 0, 0, imax(1, o->waitTo - NODE(x, n)->t));
      if (w == STEP_NULL && clockOut()) { j->late = 1; break; }
      if (!liveNode(x, w)) { j->dead = 1; j->deadAt = w == STEP_DEAD ? deadAt : NODE(x, n)->t; break; }
      int calm = settleOf(x, w);
      n = liveNode(x, calm) ? calm : w;
      KB(n);
      // (what the board makes while the line waits is counted as the line's steps are: the board left alone (base) is taken off below,
      // and it makes the same clears in the same frames -- uncounted here, a break the board makes on its own came off the rest's)
      Stats sc;
      if (liveNode(x, calm) && statsOf(x, calm, &sc)) {
        for (int i = 0; i < sc.n; i++) if (sc.size[i] > combo) combo = sc.size[i];
        if (chainOfStats(&sc) > chain) chain = chainOfStats(&sc);
        broke += sc.broke; brokeLink += linkBrokeOf(&sc); clearedAll += sc.cleared;
      }
    }
    // (A LINE IN PROGRESS PRESSED WHEN IT WAS JUDGED: its swap's walk begun no sooner than the clock it was judged to begin on -- a link of
    // a falling chain pressed frames early is no link; set 86 combo_storm 8, a 5 judged at 284 judged afresh at 306, its swap pressed as
    // soon as it could be, and a 4)
    if (!last && o->notBefore && k < o->nNotBefore && o->notBefore[k] > 0) {
      int32_t want = o->notBefore[k] - q->b->clock;
      if (want > NODE(x, n)->t) {
        int w = step(x, n, MK_LONG, 0, 0, want - NODE(x, n)->t);
        if (w == STEP_NULL && clockOut()) { j->late = 1; break; }
        if (!liveNode(x, w)) { j->dead = 1; j->deadAt = w == STEP_DEAD ? deadAt : NODE(x, n)->t; break; }
        // (what the board makes while the line waits is counted as the line's steps are)
        Stats sw;
        if (statsOf(x, w, &sw)) {
          for (int i = 0; i < sw.n; i++) if (sw.size[i] > combo) combo = sw.size[i];
          if (chainOfStats(&sw) > chain) chain = chainOfStats(&sw);
          broke += sw.broke; brokeLink += linkBrokeOf(&sw); clearedAll += sw.cleared;
        }
        n = w; KB(n);
      }
    }
    // (a rooted line's swap pressed where its panels are now: its row on the root's board, and the rows risen since)
    if (!last && o->rooted) mr = CR(seq[k]) + risenTo(x, n, rid);
    // (the allowance this swap is pressed under: the input window at the frame its walk begins, less what the line's swaps before it
    // spent -- core/nodes.h allowLeftAt, actionsFor)
    if (!last && pressAllowance >= 0) {
      Board *bn = ensureBoard(x, n);
      int left = allowLeftAt(NODE(x, n)->t - NODE(x, root)->t, spent);
      pressTight = tightAt(left);
      int acts = bn ? actionsFor(bn->curRow, bn->curCol, mr, mc, left) : 0;
      // (a swap whose walk is over what the window leaves at its frame is not there to press: the frame loop refuses a first swap's keys
      // -- front.c keysFit, GUARDED -- and drops a line at a later one -- front.c follow -- so the line is cut there)
      // (THE BREAK THE WINDOW PAYS FOR LATER: the walk waits for the window to hold it -- its oldest presses leaving -- and the swap is
      // pressed from that frame, handed on with it (ats), so a line that breaks garbage is judged, and ranked, on the frames the window
      // lets it be pressed in. Only one that may break (winWait), and that does: any other is cut, one that waited and broke
      // nothing judged again so (judge) -- the window it would wait for is the next break's -- and one whose board is lost while it
      // waits is cut there)
      if (acts > left) {
        int32_t at = NODE(x, n)->t - NODE(x, root)->t, d = winWaitOff || !o->winWait ? -1 : allowWait(at, spent, acts);
        if (d <= 0) { j->cut = k; j->cutWhy = 1; break; }
        int w = step(x, n, MK_LONG, 0, 0, d);
        if (w == STEP_NULL && clockOut()) { j->late = 1; break; }
        if (!liveNode(x, w)) { j->cut = k; j->cutWhy = 1; break; }
        Stats sw;
        if (statsOf(x, w, &sw)) {
          for (int i = 0; i < sw.n; i++) if (sw.size[i] > combo) combo = sw.size[i];
          if (chainOfStats(&sw) > chain) chain = chainOfStats(&sw);
          broke += sw.broke; brokeLink += linkBrokeOf(&sw); clearedAll += sw.cleared;
        }
        n = w; KB(n);
        if (o->rooted) mr = CR(seq[k]) + risenTo(x, n, rid);
        bn = ensureBoard(x, n);
        left = allowLeftAt(NODE(x, n)->t - NODE(x, root)->t, spent);
        pressTight = tightAt(left);
        acts = bn ? actionsFor(bn->curRow, bn->curCol, mr, mc, left) : 0;
        if (acts > left) { j->cut = k; j->cutWhy = 1; break; }
        if (winWaited < 0) winWaited = k;
      }
      spent += acts; j->spent = spent;
    }
    int kind = last || o->settled ? MK_SETTLE : MK_SWAP, out;
    if (last && k < MAXLINE) j->risen[k] = risenTo(x, n, rid);
    if (last) out = step(x, n, kind, mr, mc, 0);
    else {
      // (pressed as the frame loop presses it, core/nodes.h pressWalk: a swap whose pair still moves is walked to from the first frame its
      // walk is taken on, found with the walk tapped as the frame loop's keys are, then pressed as the frame loop walks it -- held, when
      // tight; one refused on a still board is not there to press)
      int from;
      out = pressWalk(x, n, kind, mr, mc, stepTapped, &from);
      if (out == STEP_NULL && clockOut()) { j->late = 1; break; }
      if (out == STEP_NULL) { j->cut = k; j->cutWhy = 2; j->cutAt = mr * 8 + mc; break; }
      if (from < 0) { j->dead = 1; j->deadAt = deadAt; break; }
      // (a line's first swap whose walk cannot begin within a reaction is one the frame loop does not press -- front.c keysOf refuses it:
      // not there; a later one is pressed from the frame its walk begins (ats), handed on with that frame, its keys made on the board
      // where the walk begins)
      if (k == 0 && NODE(x, from)->t - NODE(x, n)->t > cfgReaction) { j->cut = k; j->cutWhy = 3; break; }
      if (pressTight && liveNode(x, out)) out = step(x, from, kind, mr, mc, 0);
      n = from; KB(n);
      { const Board *bf = ensureBoard(x, n);
        if (bf && mr >= 0 && mr < bf->nrows && mc >= 1 && mc + 1 <= W) {
          int32_t a = bf->p[mr][mc].f[ID], b = bf->p[mr][mc + 1].f[ID];
          if (k > 0 && seq[k] == seq[k - 1] && a != NUL && b != NUL && a == prevB && b == prevA) { if (j->noopAt < 0) j->noopAt = k; if (k < 64) j->noops |= (int64_t)1 << k; }
          { const int32_t *fa = bf->p[mr][mc].f, *fb = bf->p[mr][mc + 1].f;
            if (k < 64 && fa[COLOR] > 0 && fa[COLOR] == fb[COLOR] && !fa[ISGARBAGE] && !fb[ISGARBAGE]) j->sames |= (int64_t)1 << k; }
          prevA = a; prevB = b;
        } else prevA = prevB = NUL; }
      if (pressTight && j->nats < 64) j->tightBits |= (int64_t)1 << j->nats;
      if (j->nats < MAXLINE) { j->risen[j->nats] = risenTo(x, n, rid); j->pressedAt[j->nats] = mr * 8 + mc; j->ats[j->nats++] = NODE(x, n)->t; }
    }
    // (a step the clock stopped is no answer: the judging is late, the line not lost)
    if (out == STEP_NULL && clockOut()) { j->late = 1; break; }
    if (!last && out == STEP_NULL) { j->cut = k; j->cutWhy = 2; j->cutAt = mr * 8 + mc; break; }
    if (!liveNode(x, out)) {
      j->dead = 1; j->deadAt = out == STEP_DEAD ? deadAt : NODE(x, n)->t;
      // (a step the board is lost in -- a swap's settle or the last: what it made up to the frame before. The board's own chain is made
      // before it is lost, and a hold judged dead must still say so (rank.c aloneChain); a break made and the board lost in the settle
      // after it is a break made -- the line in progress is read on this count once it has waited out, decide.c carriedCand)
      // (tight, the swap is pressed its held walk's delay later (core/nodes.h pressDelay): the frames to the loss are counted from there)
      if (out == STEP_DEAD && j->deadAt - 1 > NODE(x, n)->t) {
        int32_t late = pressTight && mr ? pressDelay(x, n, mr, mc) : 0, fr = j->deadAt - 1 - NODE(x, n)->t - late;
        int w = fr > 0 ? step(x, n, MK_SETTLE, mr, mc, fr) : STEP_NULL;
        Stats sd;
        if (liveNode(x, w) && statsOf(x, w, &sd)) {
          for (int i = 0; i < sd.n; i++) if (sd.size[i] > combo) combo = sd.size[i];
          if (chainOfStats(&sd) > chain) chain = chainOfStats(&sd);
          broke += sd.broke; brokeLink += linkBrokeOf(&sd); clearedAll += sd.cleared;
        }
      }
      break;
    }
    Stats st;
    statsOf(x, out, &st);
    if (st.cleared > 0 && j->clearStep < 0) j->clearStep = k;
    for (int i = 0; i < st.n; i++) { if (st.size[i] > combo) combo = st.size[i]; if (!(st.chainAt[i] > 1) && st.size[i] >= 4 && st.size[i] < MAXCOMBOS + 64) single[st.size[i]] = 1; }
    for (int i = 0; i < st.n; i++) if (!(st.chainAt[i] > 1)) pieces += blocksOf(st.size[i], 0);
    // (a settled step's chain ends in it, so each is an attack of its own; steps pressed at once are one chain, counted at its longest)
    if (o->settled || last) links += imax(0, chainOfStats(&st) - 1);
    if (chainOfStats(&st) > chain) chain = chainOfStats(&st);
    broke += st.broke; brokeLink += linkBrokeOf(&st); clearedAll += st.cleared; threes += threesOf(&st);
    // (A SWAP THAT SPOILS THE BOARD'S OWN CHAIN, a swap at a time: the board it is pressed on left alone to rest makes a chain of two or
    // more, and with the swap pressed and let rest a shorter one, no more garbage broken -- the three that began that chain made for
    // nothing, whatever the line's later swaps make; the press guard's test, front.c wastedSwap)
    if (!last) {
      int al = settleOf(x, n), sw = step(x, n, MK_SETTLE, mr, mc, 0);
      Stats sa, ss;
      if (liveNode(x, al) && liveNode(x, sw) && statsOf(x, al, &sa) && statsOf(x, sw, &ss)) {
        int32_t ca = sa.cleared > 0 ? chainOfStats(&sa) : 0, cs = ss.cleared > 0 ? chainOfStats(&ss) : 0;
        if (ca >= 2 && cs < ca && ss.broke <= sa.broke) threes++;
      }
    }
    j->done = NODE(x, out)->t;
    if (!last) lastAt = j->done;
    n = out; KB(n);
  }
  pressTight = tight0;
  // (the board's own chain, kept: the line's board by the frame the chain's last link comes, the chain counter there. A settled line
  // presses its first swap at once and settles after it: that swap alone, run on to the frame; one that waits for the board first keeps
  // the chain by waiting)
  j->keepsChain = -1;
  if (ownChainBy > 0 && !j->late && nseq > 0) {
    if (o->settled && o->waitTo > 0 && o->waitAt == 0) j->keepsChain = 1;
    else {
      int at = kb;
      if (o->settled) { int from; at = pressWalk(x, root, MK_SWAP, CR(seq[0]), CC(seq[0]), stepTapped, &from); }
      int w = liveNode(x, at) && NODE(x, at)->t < ownChainBy ? step(x, at, MK_LONG, 0, 0, ownChainBy - NODE(x, at)->t) : at;
      Board *wb = liveNode(x, w) ? ensureBoard(x, w) : 0;
      j->keepsChain = wb && wb->chainCounter >= ownChainN ? 1 : 0;
    }
  }
#undef KB
  j->late = j->late || clockOut();
  // (the garbage the line breaks is what it breaks beyond the board left alone: a slab popping converts its panels whatever is pressed)
  j->clearedPanels = imax(0, clearedAll - baseCleared);
  j->made.combo = combo > baseCombo ? combo : 0; j->made.chain = chain > baseChain ? chain : 0; j->made.broke = imax(0, broke - baseBroke);
  if (winWaited >= 0 && !(j->made.broke > 0)) { winWaitAgain = 1; return; }
  j->brokeLink = imax(0, brokeLink - baseLink);
  j->whole = (Made){ combo, chain, j->made.broke, 0 }; j->aloneChain = baseChain;
  j->chainAll = imax(chain, q->b->chainCounter);
  { Board *eb = liveNode(x, n) ? ensureBoard(x, n) : 0; j->chainOpen = eb && eb->chainCounter > 0; }
  if (!o->settled) links = imax(links, imax(0, chain - 1));
  j->blocks = imax(0, pieces + links - blocksOf(baseCombo, baseChain));
  j->threes = imax(0, threes - baseThrees);
  // (and the first swap settled alone: a three it makes for nothing is wasted whatever the line does after -- a line pressed straight
  // through takes its first clear into a step its later chain is counted in, where the step's count does not see it)
  if (nseq > 0 && !j->threes) j->threes = firstThree(x, root, CR(seq[0]), CC(seq[0]));
  for (int z = 4; z < MAXCOMBOS + 64; z++) if (single[z] && j->nsingles < MAXCOMBOS) j->singles[j->nsingles++] = z;
  Node *e = NODE(x, n);
  j->endNode = n;
  { const Board *eb = ensureBoard(x, n); j->even = eb ? evenOf(eb) : -1; j->gap = eb ? gapOf(eb) : -1;
    // (run 125: off -- run 124 with it 3/8)
    // (run 124, above six colours: the gap read off the board once it has settled -- a chain still falling at the line's end has not
    // dug its canyon yet: run 123 chain s5, a 3x clearing 15 panels breaking nothing emptied columns 2-5 under garbage on the left tower)
    if (0 && eb && eb->colors > 6) { int ls = settleOf(x, n); if (liveNode(x, ls)) { const Board *sb = ensureBoard(x, ls); if (sb) j->gap = gapOf(sb); } } j->topRow = eb ? topRowOf(eb) : 0; j->pEven = eb ? panelEvenOf(eb) : -1; j->perch = eb ? restsFewOf(eb) : -1; j->swapReady = j->readyBreak = 0; if (eb) readyOf(eb, &j->swapReady, &j->readyBreak); j->spread = eb ? spreadOf(eb) : 0; j->seams = eb ? seamsOf(eb) : 0; }
  j->dropAt = j->dead ? 0 : e->t + imax(e->stopTime + e->preStopTime, e->shakeTime);
  j->fire = j->nats ? j->ats[j->nats - 1] : -1;
  if (o->lifeTo >= 0) j->lostAt = j->dead ? j->deadAt : lostAlone(x, n, imax(o->lifeTo, imax(lastAt, o->lifeStop ? j->dropAt : 0) + o->lifeRest));
  // (a line whose board is lost: the frame the queue held off by the board's motion drops with it played -- asked before the loss only)
  if (!j->dead && !j->late && j->lostAt != NOT_ASKED && j->lostAt != FOREVER && queueWaits(q->b)) j->queueAt = queueDrops(x, root, n, j->lostAt);
  // (readiness, the dearer check, only when the board left alone does not stand to lifeTo -- always, or for a line that breaks)
  int standsOut = j->lostAt == FOREVER && (o->readyIfLost || (o->readyIfBreak && j->made.broke > 0));
  if (o->readyAt != NOT_ASKED && !j->dead && !standsOut) {
    // (ready from the frame the line's next decision can act: a line's own end, the hold's a reaction on -- a hold presses nothing
    // until the next decision)
    int32_t from = nseq ? 0 : cfgReaction;
    j->readyWait = imax(1, imax(o->readyAt, from) + 2);
    // (and the break it finds is one the input window pays for at that frame: a break the cursor cannot walk to on what is left is not in
    // reach -- core/nodes.h allowLeftAt, actionsFor)
    static LOCAL int32_t rl[MAXLINE]; int32_t rn = 0, *wl = o->why ? j->readyLine : (pressAllowance >= 0 ? rl : 0), *wn = o->why ? &j->readyN : &rn;
    j->ready = breaksAfterLanding(x, n, j->readyWait, wl, wn);
    if (j->ready == 1 && pressAllowance >= 0 && wl && *wn > 0) {
      const Board *eb = ensureBoard(x, n);
      int left = allowLeftAt(j->readyWait, spent), r = eb ? eb->curRow : 0, c = eb ? eb->curCol : 0, acts = 0;
      for (int k = 0; k < *wn && eb; k++) { acts += actionsFor(r, c, CR(wl[k]), CC(wl[k]), left - acts); r = CR(wl[k]); c = CC(wl[k]); }
      if (eb && acts > left) j->ready = 0;
    }
    j->readyPend = readyPendLast; j->readyNear = readyNearLast; j->readyMat = readyMatLast;
    memcpy(j->readyRow1, readyRow1Buf, sizeof j->readyRow1);
    if (j->ready == LOST_FIRST) j->ready = 0;   // (lost first: not ready)
  }
  j->late = j->late || clockOut();
  if (j->late && !j->dead) j->aliveTo = liveNode(x, n) ? NODE(x, n)->t - NODE(x, root)->t : 0;
}
// A LINE JUDGED: pressed as the game presses it, a walk the window does not hold waited for; a line that waited and broke no garbage
// is judged again with no wait -- cut at the swap the window does not hold, as the frame loop drops it
static void judge(const Question *q, const int32_t *seq, int nseq, const JudgeOpts *o, Judged *j) {
  judgeOnce(q, seq, nseq, o, j);
  if (!winWaitAgain) return;
  winWaitOff = 1; judgeOnce(q, seq, nseq, o, j); winWaitOff = 0;
}

// ---- for a host's check: the question from a node of a search the host made, and a line judged
static Board *hostBoard;
static Question hostQ;
EXPORT(gb_question) int gb_question(Ctx *hx, int i, int tight) {
  Board *b = ensureBoard(hx, i);
  if (!b) return -1;
  if (!hostBoard) hostBoard = nb_new();
  cloneBoard(hostBoard, b);
  Node *n = NODE(hx, i);
  hostQ.b = hostBoard; hostQ.holdLeft = n->holdLeft; hostQ.holdStarted = n->holdStarted; hostQ.narr = n->narr; hostQ.tight = tight;
  for (int k = 0; k < n->narr; k++) hostQ.arr[k] = n->arr[k];
  return 0;
}
// The question from a board's bytes as a native host logs them (GAMBITB: the head, the queue and the rows, packed), in the io from its
// first word, then narr arrivals (at, width, height) -- for the reach report.
static void onStop(void);   // (answer.c: the search beside the decisions)
EXPORT(gb_question_bytes) int gb_question_bytes(int nbytes, int narr) {
  onStop();   // (the search beside the last decision let go before the question's board is written over the one it reads)
  if (!hostBoard) hostBoard = nb_new();
  const unsigned char *p = (const unsigned char *)gbIo;
  memcpy(hostBoard, p, BOARD_HEAD);
  if (hostBoard->ninc < 0 || hostBoard->ninc > MAXINC || hostBoard->nrows < 13 || hostBoard->nrows > MAXROWS || narr > MAXARR) return -1;
  unsigned long qn = (unsigned long)hostBoard->ninc * sizeof(Incoming), rn = (unsigned long)hostBoard->nrows * sizeof(Panel) * (W + 1);
  if (BOARD_HEAD + qn + rn != (unsigned long)nbytes) return -1;
  memcpy(hostBoard->inc, p + BOARD_HEAD, qn);
  memcpy(hostBoard->p, p + BOARD_HEAD + qn, rn);
  const int32_t *a = gbIo + (nbytes + 3) / 4;
  memset(&hostQ, 0, sizeof hostQ);
  hostQ.b = hostBoard; hostQ.narr = narr;
  for (int k = 0; k < narr; k++) hostQ.arr[k] = (Arr){ a[3 * k], a[3 * k + 1], a[3 * k + 2], 0, 0 };
  return 0;
}
// THE QUESTION'S CELLS, for a tool that reads a logged board: rows, stop, shake, then per row from the bottom each column's colour
// (0 none), garbage, state
EXPORT(gb_cells) int gb_cells(void) {
  const Board *b = hostBoard;
  if (!b) return 0;
  int k = 0;
  gbIo[k++] = b->nrows; gbIo[k++] = b->stopTime + b->preStopTime; gbIo[k++] = b->shakeTime;
  for (int r = 0; r < b->nrows; r++) for (int c = 1; c <= W; c++) {
    const int32_t *f = b->p[r][c].f;
    gbIo[k++] = f[COLOR] == NUL ? 0 : f[COLOR]; gbIo[k++] = f[ISGARBAGE]; gbIo[k++] = f[STATE];
  }
  return k;
}
EXPORT(gb_list_on) void gb_list_on(int on) { listOn = on; }
// the input window's allowance a search is held to (-1: none), as a decision is asked under it
EXPORT(gb_press_allowance) void gb_press_allowance(int allow) { pressAllowance = allow; }
// The line in the io body (nseq words, r * 8 + c); the answer back into it: dead, deadAt, combo, chain, broke, chainAll, dropAt, done,
// fire, lostAt, ready, late, nats, ats..., nsingles, singles..., readyN, readyLine...
EXPORT(gb_judge) int gb_judge(int nseq, int settled, int tight, int readyAt, int readyIfLost, int readyIfBreak, int lifeTo, int lifeRest, int why) {
  static int32_t seq[MAXLINE];
  if (nseq < 0 || nseq > MAXLINE) return -1;
  for (int i = 0; i < nseq; i++) seq[i] = gbIo[i];
  JudgeOpts o = { settled, tight, readyAt, readyIfLost, readyIfBreak, lifeTo, lifeRest, why };
  pressTight = tight;
  Judged j;
  judge(&hostQ, seq, nseq, &o, &j);
  int32_t *w = gbIo, k = 0;
  w[k++] = j.dead; w[k++] = j.deadAt; w[k++] = j.made.combo; w[k++] = j.made.chain; w[k++] = j.made.broke; w[k++] = j.chainAll;
  w[k++] = j.dropAt; w[k++] = j.done; w[k++] = j.fire; w[k++] = j.lostAt; w[k++] = j.ready; w[k++] = j.late;
  w[k++] = j.nats; for (int i = 0; i < j.nats; i++) w[k++] = j.ats[i];
  w[k++] = j.nsingles; for (int i = 0; i < j.nsingles; i++) w[k++] = j.singles[i];
  w[k++] = j.readyN; for (int i = 0; i < j.readyN; i++) w[k++] = j.readyLine[i];
  w[k++] = j.cut; w[k++] = j.base;
  return k;
}

// THE FIRST CLEAR OF A LINE THAT IS TO CLEAR NOTHING: each step played to the board's settle, in turn, pressed when
// the frame loop presses it; the index of the first that clears panels and breaks no garbage, -1 if none does. own: only a clear of
// the step's own -- more panels than the board it is pressed on clears left alone to rest: a clear popping in the pile clears them
// whatever is pressed, and a swap that lets the garbage down beside it (propose.c letDownCand) clears nothing
static int firstClear(const Question *q, const int32_t *seq, int nseq, int own) {
  Ctx *x = judgeCtx = ctxOf(judgeCtx);
  int n = rootOf(x, q);
  if (n < 0) return -1;
  for (int k = 0; k < nseq; k++) {
    int out = step(x, n, MK_SETTLE, CR(seq[k]), CC(seq[k]), 0);
    if (!liveNode(x, out)) break;
    Stats st, sa; statsOf(x, out, &st);
    int al = own && st.cleared > 0 ? settleOf(x, n) : STEP_NULL;
    int32_t alone = liveNode(x, al) && statsOf(x, al, &sa) ? sa.cleared : 0;
    if (st.cleared > alone && !(st.broke > 0)) return k;
    n = out;
  }
  return -1;
}
