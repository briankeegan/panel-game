// A CHAIN GOING IS CONTINUED (as Gambit asks it: a list of aims): from a board mid-cascade (stop time running) or a slab
// popping, the swaps made while it falls that make it longer. A beam over swaps played as the cascade runs, each board ranked by what
// the cascade sends once it settles -- in time attack by its chain first; per entry of the list the cascade that meets it sending the
// most (in time attack, with the longest chain), and beside them the one nearest
// the list (near). A line is kept for an aim only when its board keeps the floor and its line passes the shared line check, its last
// swap in time (by).

static int ruleNoEnemy;   // (time attack's rule in force: decide.c read)
#define CB_TOP 13   // the owner: a chain is taken to 13 -- the score table's last step -- and no further; the panels past it are the next chain's
typedef struct {
  int32_t set, nseq, seq[MAXLINE];
  int32_t cells, chain, combo, broke, done, fire, floor, base, aimIndex;
  double near;
} XLine;
typedef struct { int32_t width, depth; const List *aims; int32_t by; const Keep *keep; double ms; int32_t longest; } ExtOpts;   // longest: the chain made longest offered, as in time attack (the opener's falling chain); 2 unjudged -- a board
                                                                                                            // played forward, not the decision's (decide.c opExtendAll)
#define EXT_LONG_K 12  // (the opener's falling chain: the longest lines kept, each judged in turn -- the search's count of a line's chain is
                       // its own, and the judge, which plays it as the frame loop will, has the last word)
typedef struct { XLine best, nearest, three, longest, longK[EXT_LONG_K]; int32_t nlongK; double ms; int32_t baseChain, seen, kept, top, topKept, late, floorLost, longCut; } Ext;   // seen..floorLost: the log's xs= -- boards settled, kept, the longest chain of any and of a kept one, put down for firing past `by`, for losing the floor   // baseChain: the cascade's chain left alone   // three: the chain taken to three or more, breaking the most;
                                                                       // longest: the chain made longest, in the fewest swaps
// a node's cascade once it settles: what it sends, its chain and largest match, the garbage it converted, and whether its board keeps
// the floor (kept: with what it broke, floor: as if it broke nothing)
typedef struct { int32_t ok, cells, chain, combo, broke, kept, floor, done; } Sent;
static LOCAL Ctx *extCtx;
static LOCAL PathTree extTree;   // (its lines, as the planner's: search/plan.c PathTree)
// (WHAT A LINE'S STEPS MADE, every one from the root -- its walks, the frames it waited for a pair, its presses: a step's stats are its
// own frames' (search.h advance), so a link or a break made while a swap is walked to is the line's as much as one made in its settle,
// as the judge counts them)
static void madeAdd(PItem *k, const Stats *s) {
  for (int j = 0; j < s->n; j++) { k->xcc += comboCells(s->size[j]); if (s->size[j] > k->xcombo) k->xcombo = s->size[j]; }
  if (chainOfStats(s) > k->xchain) k->xchain = chainOfStats(s);
  k->xbroke += s->broke;
}
// (the steps from node `from` back to `to`, `to`'s own not counted)
static void madeAlong(Ctx *x, int from, int to, PItem *k) {
  for (int i = from; i >= 0 && i != to; i = NODE(x, i)->prev) { Stats s; if (statsOf(x, i, &s)) madeAdd(k, &s); }
}
// node n's cascade once it settles, with what the line's steps to n made (k)
static Sent sendsOf(Ctx *x, int n, const Keep *keep, const PItem *k) {
  Sent g; memset(&g, 0, sizeof g);
  int out = settleOf(x, n);
  // (a board lost before its cascade settles: what the cascade made up to the frame before -- the links that come before the loss are
  // the chain's, as the judge counts them (judge.c), and a chain going on through garbage popping is one the board can be lost under)
  if (out == STEP_DEAD && deadAt - 1 > NODE(x, n)->t) out = step(x, n, MK_SETTLE, 0, 0, deadAt - 1 - NODE(x, n)->t);
  if (!liveNode(x, out)) return g;
  PItem a = *k; Stats st;
  if (statsOf(x, out, &st)) madeAdd(&a, &st);
  Board *b = ensureBoard(x, out);
  g.ok = 1; g.cells = a.xcc + (a.xchain > 1 ? W * (a.xchain - 1) : 0); g.chain = a.xchain; g.combo = a.xcombo; g.broke = a.xbroke;
  g.kept = keepsFloor(keep, b, a.xbroke); g.floor = keepsFloor(keep, b, 0); g.done = NODE(x, out)->t;
  return g;
}
// THE SWAPS A LINE CAN PRESS FROM NODE n, as the frame loop presses them (core/nodes.h pressWalk): those legal now, and while the board
// moves, those that open within a press's wait (PRESS_WAIT) -- a pair under a panel hovering is refused (pa.c canSwapPanels) until it
// falls, and the frame loop waits for it: the cell a link pops out of, filled as the column above comes down
static int extSwaps(Ctx *x, int n, int32_t *ms) {
  int m = swapsOfNode(x, n, ms);
  Board *b = ensureBoard(x, n);
  if (!b || !(hasActivePanels(b) || b->swappingCount > 0)) return m;
  const Node *d = NODE(x, n);
  int32_t back = d->mk == MK_SWAP || d->mk == MK_SETTLE ? d->mr * 8 + d->mc : -1;
  static LOCAL int32_t more[MAXROWS * W];
  int at = n;
  for (int f = 0; f < 2 && !clockOut(); f++) {
    int w = step(x, at, MK_LONG, 0, 0, PRESS_WAIT / 2);
    if (!liveNode(x, w)) break;
    Board *wb = ensureBoard(x, w);
    if (!wb) break;
    int k = legalSwaps(wb, more);
    for (int i = 0; i < k && m < MAXROWS * W; i++) {
      int have = more[i] == back;
      for (int j = 0; j < m && !have; j++) have = ms[j] == more[i];
      if (!have) ms[m++] = more[i];
    }
    at = w;
  }
  return m;
}
static void extendIn(const Question *q, const ExtOpts *o, Ext *E) {
  memset(E, 0, sizeof *E);
  double t0 = nowMs(), shareOld = clockShareBegin(t0 + o->ms);
  Ctx *x = extCtx = ctxOf(extCtx);
  Question q0 = *q; q0.narr = 0;   // (the cascade on its own: nothing lands while it is extended)
  int root = rootOf(x, &q0);
  if (root < 0) { clockShareEnd(shareOld); return; }
  PItem none; memset(&none, 0, sizeof none);
  Sent base = sendsOf(x, root, o->keep, &none);
  E->best.cells = base.ok ? base.cells : 0; E->best.chain = base.ok ? base.chain : 0; E->best.base = E->best.cells; E->best.aimIndex = -1;
  int32_t baseCells = E->best.cells; E->baseChain = base.ok ? base.chain : 0;
  int na = o->aims ? o->aims->n : 0;
  XLine per[MAXAIMS]; memset(per, 0, sizeof per);
  static LOCAL PItem poolA[PLAN_POOL], poolB[PLAN_POOL];
  static LOCAL int32_t idx[PLAN_POOL], tmpI[PLAN_POOL], keyH[PLAN_POOL], keyS[PLAN_POOL], ms[MAXROWS * W];
  PItem *pool = poolA, *next = poolB;
  int npool = 1;
  memset(&pool[0], 0, sizeof pool[0]); pool[0].n = root; pool[0].path = -1;
  pathReset(&extTree);
  for (int d = 1; d <= o->depth && npool && !clockOut(); d++) {
    int nn = 0;
    for (int pi = 0; pi < npool && !clockOut(); pi++) {
      int nm = extSwaps(x, pool[pi].n, ms);
      // (THE WINDOW AS THE JUDGE PRESSES IN IT -- judge.c: a swap whose walk is over what the window leaves at its frame is never pressed,
      // and one pressed with the window low is pressed held, as late as its walk waits -- so the extension presses as the judge will)
      int left = -1; const Board *lb = 0;
      if (pressAllowance >= 0) { lb = ensureBoard(x, pool[pi].n); left = allowLeftAt(NODE(x, pool[pi].n)->t - NODE(x, root)->t, pool[pi].acts); }
      for (int j = 0; j < nm && nn < PLAN_POOL && pool[pi].nseq < MAXLINE; j++) {
        int acts = lb ? actionsFor(lb->curRow, lb->curCol, CR(ms[j]), CC(ms[j]), left) : 0;
        if (lb && acts > left) continue;
        // (pressed as the judge presses it: the walk begun at once, waited on while its pair still moves, a first walk begun within a
        // reaction)
        int32_t tight0 = pressTight;
        if (lb) pressTight = tightAt(left);
        int from, out = pressWalk(x, pool[pi].n, MK_SWAP, CR(ms[j]), CC(ms[j]), stepTapped, &from);
        if (liveNode(x, out) && from >= 0 && d == 1 && NODE(x, from)->t - NODE(x, pool[pi].n)->t > cfgReaction) out = STEP_NULL;
        if (liveNode(x, out) && from >= 0 && pressTight) out = step(x, from, MK_SWAP, CR(ms[j]), CC(ms[j]), 0);
        pressTight = tight0;
        if (!liveNode(x, out) || !stepFitsAt(x, out)) continue;
        int32_t path = pathAdd(&extTree, pool[pi].path, ms[j], NODE(x, pool[pi].n)->t);
        if (path == -2) continue;
        PItem *k = &next[nn]; memset(k, 0, sizeof *k);
        k->n = out; k->nseq = pool[pi].nseq + 1; k->path = path; k->acts = pool[pi].acts + acts;
        k->xcc = pool[pi].xcc; k->xchain = pool[pi].xchain; k->xcombo = pool[pi].xcombo; k->xbroke = pool[pi].xbroke;
        madeAlong(x, out, pool[pi].n, k);
        nn++;
      }
    }
    int nk = 0;
    for (int i = 0; i < nn; i++) {
      PItem *k = &next[i];
      Sent g = clockOut() ? (Sent){ 0 } : sendsOf(x, k->n, o->keep, k);
      if (!g.ok) continue;
      // (the garbage it breaks beyond the board left alone -- as the judge counts it: a slab popping breaks what it breaks whatever the
      // line does, and a line-up that only watches it is no break)
      g.broke = imax(0, g.broke - (base.ok ? base.broke : 0));
      // (a link added to a falling chain is in time when its swap is: pressed before the link it joins lands, and by the deadline)
      int32_t fire = NODE(x, k->n)->t;
      E->seen++; if (g.chain > E->top) E->top = g.chain;
      if (!g.kept) E->floorLost++;
      if (g.kept && o->by != NOT_ASKED && fire > o->by) { g.kept = 0; E->late++; }
      if (g.kept) { E->kept++; if (g.chain > E->topKept) E->topKept = g.chain; }
      Made made = { g.combo, g.chain, g.broke, g.cells - baseCells };
      int32_t kseq[MAXLINE]; pathRead(&extTree, k->path, k->nseq, kseq, 0);
      #define XFILL(L, ai) do { memset(&(L), 0, sizeof (L)); (L).set = 1; (L).nseq = k->nseq; for (int s_ = 0; s_ < k->nseq; s_++) (L).seq[s_] = kseq[s_]; \
        (L).cells = g.cells; (L).chain = g.chain; (L).combo = g.combo; (L).broke = g.broke; (L).done = g.done; (L).fire = fire; (L).floor = g.floor; \
        (L).base = baseCells; (L).aimIndex = (ai); } while (0)
      if (g.kept) {
        double xn = nearList(o->aims, made);
        if (xn > 0 && (!E->nearest.set || xn > E->nearest.near || (xn == E->nearest.near && g.cells > E->nearest.cells)) && lineFits(kseq, k->nseq, 0)) { XFILL(E->nearest, -1); E->nearest.near = xn; }
        for (int ai = 0; ai < na; ai++)
          if (meets(&o->aims->aim[ai], made) && (!per[ai].set || (ruleNoEnemy && g.chain != per[ai].chain ? g.chain > per[ai].chain : g.cells > per[ai].cells)) && lineFits(kseq, k->nseq, 0)) XFILL(per[ai], ai);
        // (A 2x GOING TAKEN TO THREE -- the owner: at least a 3x over a 2x: the line that makes the chain three or more and breaks the most
        // garbage, whatever the list asks)
        if (g.chain >= 3 && (!E->three.set || g.broke > E->three.broke || (g.broke == E->three.broke && g.cells > E->three.cells)) && lineLives(kseq, k->nseq, 0)) XFILL(E->three, -1);
        // (THE CHAIN MADE LONGEST, a link at a time -- the owner: in time attack a chain is all there is; whatever the list asks, the
        // longest the cascade is taken to, up to 13 (CB_TOP), in the fewest swaps)
        // (and the opener's chain falling: the longest it is taken to, a line that lives -- the list and the floor are the chain's own then)
        if ((ruleNoEnemy || o->longest) && base.ok && base.chain < CB_TOP && g.chain > base.chain && (!E->longest.set || imin(g.chain, CB_TOP) > imin(E->longest.chain, CB_TOP) ||
            (imin(g.chain, CB_TOP) == imin(E->longest.chain, CB_TOP) && k->nseq < E->longest.nseq))) {
          if (o->longest == 2 || (o->longest ? lineLives(kseq, k->nseq, 0) : lineFits(kseq, k->nseq, 0))) XFILL(E->longest, -1); else E->longCut++;
        }
        // (the K longest, any line making the chain longer than left alone: kept by chain, then the garbage broken -- a link that breaks a
        // slab keeps the chain going through its pop -- then fewer swaps, one per first swap)
        if (o->longest && base.ok && g.chain > base.chain) {
          int at = -1, dup = -1;
          for (int q = 0; q < E->nlongK; q++) if (E->longK[q].seq[0] == kseq[0]) dup = q;
          #define XBETTER(L) (g.chain > (L).chain || (g.chain == (L).chain && (g.broke > (L).broke || (g.broke == (L).broke && k->nseq < (L).nseq))))
          if (dup >= 0) { if (XBETTER(E->longK[dup])) at = dup; }
          else if (E->nlongK < EXT_LONG_K) at = E->nlongK++;
          else { int w = 0; for (int q = 1; q < E->nlongK; q++) { const XLine *a = &E->longK[q], *b = &E->longK[w]; if (a->chain < b->chain || (a->chain == b->chain && (a->broke < b->broke || (a->broke == b->broke && a->nseq > b->nseq)))) w = q; } if (XBETTER(E->longK[w])) at = w; }
          #undef XBETTER
          if (at >= 0) XFILL(E->longK[at], -1);
        }
      }
      #undef XFILL
      k->h = connectedOf(ensureBoard(x, k->n)); k->set = ruleNoEnemy ? g.chain * 1000 + g.cells : g.cells;   // (set: its score -- what it sends; in time attack its chain first)
      next[nk++] = *k;
    }
    // each board once, its best line: ranked by what it sends (in time attack its chain first), then how connected
    int nd = 0;
    for (int i = 0; i < nk; i++) {
      Node *kn = NODE(x, next[i].n);
      int dup = 0;
      for (int q2 = 0; q2 < nd && !dup; q2++) { Node *on = NODE(x, next[q2].n); dup = on->hash == kn->hash && on->keyn == kn->keyn && !memcmp(on->key, kn->key, sizeof(int32_t) * kn->keyn); }
      if (!dup) next[nd++] = next[i];
    }
    for (int i = 0; i < nd; i++) { idx[i] = i; keyH[i] = next[i].h; keyS[i] = next[i].set; }
    sortByKeyDesc(idx, nd, keyH, tmpI);
    sortByKeyDesc(idx, nd, keyS, tmpI);
    int keepN = imin(nd, o->width);
    for (int i = 0; i < keepN; i++) pool[i] = next[idx[i]];
    npool = keepN;
  }
  for (int ai = 0; ai < na; ai++) if (per[ai].set) { E->best = per[ai]; break; }
  E->ms = nowMs() - t0;
  clockShareEnd(shareOld);
}
// (its boards let go once it has answered: every thread that searches has a context of its own, and a tree held is thousands of boards)
static void extend(const Question *q, const ExtOpts *o, Ext *E) { extendIn(q, o, E); extCtx = ctxLetGo(extCtx); }
