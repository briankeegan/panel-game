// THE PLANNER (as Gambit asks it: a list of aims): a beam over swaps, each step played to the
// board's settle, ranked by how near the list the lines one swap on come (o.near: GAMBIT.lead) and then by how connected the board is.
// It keeps, of the lines in time (their last swap begun by `by`) whose board keeps the floor:
//   perAim    for each entry of the list, the line that meets it sending the most garbage (the fewer swaps between equals)
//   nearest   the line nearest the list
//   quick     the line that breaks the most garbage (the sooner between equals) -- and with breakAtSwap, a line the engine settles
//             dead, played again only to its swap, that breaks by then
//   lowest    of the lines done before the board dies (dies), the one that leaves the lowest stack
//   setup     the first swap of the board nearest the list, else the most connected one, reached so far -- and setupLine, the whole
//             way there: the set-up is played as a line, so the board it was building toward is carried on, not forgotten
//   pair      the line that fires two ideas (search/ideas.c), each an entry of the list -- the most sent by both, the fewer swaps
//             between equals: several ideas at once, fired one after the other
// A board of the beam is weighed by how near the list it comes, then by its IDEAS -- how many of its swaps fire an entry of the list --
// then by how connected it is: of two boards as near, the one with more attacks ready is built on.
// A line is kept as an answer only when its end is within the rules through its settle and passes the shared line check. With
// readyAt (a block on its way), an entry's line and the nearest are kept only if the board they leave breaks that block once landed.

#define PLAN_POOL 4096
#define PLAN_KIDS 65536
#define PLAN_WIDE_MAX 640   // (the widest beam planned again with time over: its kids within PLAN_KIDS, 60 swaps a line at most -- propose.c searchAll)
// A LINE IS A PATH IN A TREE: each step of a beam keeps its parent's step and its own swap, so a line of any length costs one step,
// and how deep a line goes is bounded by the clock, never by its storage. A line's swaps are read back from its last step (pathRead).
typedef struct { int32_t up, m, at; } PStep;   // up: the step before, -1 none; m: the swap, r * 8 + c; at: the frame it is pressed from
#define PATH_STEPS (PLAN_POOL * MAXLINE + KEEPN * MAXPATH)
typedef struct { int32_t n; PStep s[PATH_STEPS]; } PathTree;
static void pathReset(PathTree *T) { T->n = 0; }
// (a step added under `up`: -2 when the tree is full -- the line then grows no further)
static int32_t pathAdd(PathTree *T, int32_t up, int32_t m, int32_t at) {
  if (up == -2 || T->n >= PATH_STEPS) return -2;
  T->s[T->n].up = up; T->s[T->n].m = m; T->s[T->n].at = at;
  return T->n++;
}
// (a line's n swaps and their frames, from its last step p; ats may be 0)
static void pathRead(const PathTree *T, int32_t p, int n, int32_t *seq, int32_t *ats) {
  for (int k = n - 1; k >= 0 && p >= 0; k--, p = T->s[p].up) { seq[k] = T->s[p].m; if (ats) ats[k] = T->s[p].at; }
}
// (a board of the beam, or a kid of one; path: its line's last step, -1 none; a kid's line is its parent's path, up, and one swap more,
// km pressed from kat -- made a step of the tree only when the kid is kept; ideas: its swaps that fire an entry; fired, firedCells,
// firedAim: the entries its line fired on the way, what they sent, the first's entry)
typedef struct { int32_t n, nseq, path, up, km, kat, h, set; double reach; int32_t kid0, nkids, ideas, fired, firedCells, firedAim, acts, xcc, xchain, xcombo, xbroke; } PItem;   // acts: the cursor's actions for its swaps; x*: what its steps made (search/extend.c)
typedef struct {
  int32_t set, n, nseq, seq[MAXLINE], ats[MAXLINE];
  int32_t brk, cells, chain, combo, broke, earned, done, fire, floor, aimIndex, top;
  int32_t kc;   // (quick: the break keeps the board's own chain -- search/break.c keepsOwnChain)
  int32_t cat;  // (quick: what the break makes, as a list asking no chain ranks it -- search/break.c breakCat; 0 where the list asks a chain)
  int32_t acts; // the cursor's actions for its swaps, from the root's cursor (core/nodes.h actionsFor)
  double near;
} PLine;
// (the cursor's actions for swap m from the board of item it, the allowance what is left of the decision's after its line)
static int32_t actOf(Ctx *x, const PItem *it, int32_t m) {
  const Board *b = ensureBoard(x, it->n);
  return b ? actionsFor(b->curRow, b->curCol, CR(m), CC(m), pressAllowance >= 0 ? pressAllowance - it->acts : HOLDTIGHT + 1) : 0;
}
// (THE QUICK BREAK: one that keeps the board's own chain before one that cuts it, then the more broken, then the sooner)
// -- and where the list asks no chain (finish them, the fill with no room), the break the mode asks before a plain three before a chain:
// a chain there is an attack the mode does not ask)
static int quickBefore(const PLine *q, int kc, int cat, int32_t broke, int32_t done) {
  if (!q->set) return 1;
  if (kc != q->kc) return kc > q->kc;
  if (cat != q->cat) return cat > q->cat;
  return broke > q->broke || (broke == q->broke && done < q->done);
}
typedef struct {
  int32_t width, depth, pool;
  const List *aims;          // the list the search plays for (R.guides)
  int32_t by;                // NOT_ASKED: none
  const Keep *keep;          // the floor (R.keepF)
  int32_t readyAt;           // NOT_ASKED: none
  int32_t under;             // garbage on the board: the lead counts a break
  double dies;               // 0: none
  int32_t breakAtSwap;
  double ms;                 // the planner's share, ms
  const Paths *seeds;        // the lines the last decision's plan ended with, the swaps played since taken off (answer.c plannedPaths)
} PlanOpts;
typedef struct { PLine perAim[MAXAIMS], nearest, quick, lowest, stopBest, pair; int32_t setup, nsetupLine, setupLine[MAXLINE]; double ms; int32_t base; } Plan;

static LOCAL Ctx *planCtx;
static LOCAL PathTree planTree;   // (each thread its own, as every buffer here: two plans search at once -- answer.c searchJob)
// THE PLAN KEPT (plans/gambit-infra.md F, as tree reuse keeps the subtree under the move played): the lines a plan ends with -- each
// entry's best, the nearest, the quickest break, the lowest, the longest stop, and the beam's last boards -- kept (planOut) for the next
// decision, which begins its beam from them as well as from its root (the seeds): what was searched is searched on, deeper, not again.
// Each seed is played again on the new board, every step within the rules, so new information repairs it or lets it go.
static LOCAL Paths planOut;
static LOCAL int32_t planSeeded;   // (the seeds the plan began from, this decision -- the log's)
static int32_t planSeedsHave; static Paths planSeeds;   // (this decision's seeds: answer.c plannedPaths)
static void planKeep(const int32_t *seq, int n) {
  if (planOut.n >= KEEPN || n <= 0 || n > MAXPATH) return;
  for (int i = 0; i < planOut.n; i++) if (planOut.len[i] == n && !memcmp(planOut.path[i], seq, sizeof seq[0] * (unsigned long)n)) return;
  planOut.len[planOut.n] = n; for (int k = 0; k < n; k++) planOut.path[planOut.n][k] = seq[k];
  planOut.n++;
}
// how connected a board is: like colours side by side, and (twice) one above the other
static int32_t connectedOf(const Board *b) {
  int R = gridLen(b), n = 0;
  for (int r = 1; r < R - 1; r++) for (int c = 1; c <= W; c++) {
    int32_t k = cellAt(b, r, c);
    if (!(k > 0 && k < 8)) continue;
    if (c < W && cellAt(b, r, c + 1) == k) n += 1;
    if (r + 1 < R && cellAt(b, r + 1, c) == k) n += 2;
  }
  return n;
}
// THE SHAPE of a settled board: its top row, evenness, hollow (empty cells under garbage) -- the board's shape as the facts read it
// (search/bits.c bitsShape)
typedef struct { int32_t top, even, hollow; } Shape;
static Shape shapeOf(const Board *b) {
  static LOCAL Bits PB; static LOCAL BoardShape PS;
  bitsOf(b, &PB); bitsShape(&PB, &PS);
  Shape s = { PS.top, PS.even, PS.hollow };
  return s;
}
// the garbage a step's clears send: each clear's combo garbage and a slab for every link past the first (attacker sent)
static int32_t sentCells(const Stats *s) {
  int32_t n = 0, chain = chainOfStats(s);
  for (int j = 0; j < s->n; j++) n += comboCells(s->size[j]);
  if (chain > 1) n += W * (chain - 1);
  return n;
}
static void lineFrom(PLine *l, const PItem *it, int32_t mv, int32_t node, int32_t fire) {
  l->set = 1; l->n = node; l->nseq = imin(it->nseq + 1, MAXLINE);
  pathRead(&planTree, it->path, l->nseq - 1, l->seq, l->ats);
  l->seq[l->nseq - 1] = mv; l->ats[l->nseq - 1] = fire;
  l->fire = fire;
}
// READY (readyAfter): the board the line leaves, run to readyAt and settled, breaks the block with one swap
static int readyAfter(Ctx *x, int n, int32_t readyAt) {
  int land = step(x, n, MK_LONG, 0, 0, imax(1, readyAt + 2 - NODE(x, n)->t));
  if (liveNode(x, land)) { int s0 = settleOf(x, land); if (s0 != STEP_NULL && s0 != STEP_ERR) land = s0; }
  if (!liveNode(x, land)) return 0;
  int32_t base = NODE(x, land)->brk, ms[MAXROWS * W];
  int nm = swapsOfNode(x, land, ms), any = 0;
  for (int q = 0; q < nm; q++) { int o = step(x, land, MK_SWAP, CR(ms[q]), CC(ms[q]), 0); if (liveNode(x, o) && NODE(x, o)->brk > base) any = 1; }
  return any;
}

static void planIn(const Question *q, const PlanOpts *o, Plan *P) {
  memset(P, 0, sizeof *P);
  double t0 = nowMs(), shareOld = clockShareBegin(t0 + o->ms);
  Ctx *x = planCtx = ctxOf(planCtx);
  int root = rootOf(x, q);
  if (root < 0) { clockShareEnd(shareOld); return; }
  // a cascade already running sends what it sends whatever is swapped: only what a swap adds to it counts
  int baseOut = settleOf(x, root);
  int32_t base = 0;
  Stats bs;
  if (liveNode(x, baseOut) && statsOf(x, baseOut, &bs) && bs.cleared > 0) base = sentCells(&bs);
  // (a step that converts garbage breaks what the line has broken by its settle beyond the board left alone by then -- the break
  // search's and the judge's measure: a slab already popping, or a cascade of the board's own, converts whatever is pressed)
  #define BROKE_OF(it, st) ((st).broke > 0 ? imax(0, NODE(x, out)->brk - stillAt(&still, NODE(x, out)->t)) : 0)
  P->base = base;
  int32_t rootH = connectedOf(ensureBoard(x, root));
  int32_t setH = rootH, haveSetup = 0, setIdeas = 0; double setReachD = 0;
  // (garbage broken by frame t standing still: a slab already popping goes on converting whatever is pressed)
  BS still; memset(&still, 0, sizeof still); still.x = x; still.root = root;
  static LOCAL PItem poolA[PLAN_POOL], poolB[PLAN_POOL];
  static LOCAL PItem kids[PLAN_KIDS];
  static LOCAL int32_t idx[PLAN_KIDS], tmpI[PLAN_KIDS], keyB[PLAN_KIDS], ms[MAXROWS * W];
  PItem *pool = poolA, *next = poolB;
  int npool = 1;
  memset(&pool[0], 0, sizeof pool[0]); pool[0].n = root; pool[0].h = rootH; pool[0].path = -1;
  pathReset(&planTree);
  // (THE SEEDS: the kept plan's lines played again from the root, each step to its settle and within the rules, its first no swap back;
  // a line the new board no longer allows is let go)
  planSeeded = 0;
  for (int i = 0; o->seeds && i < o->seeds->n && npool < PLAN_POOL && !clockOut(); i++) {
    int len = o->seeds->len[i], nd = root, ok = 1;
    if (len < 1 || len >= MAXLINE) continue;
    PItem it; memset(&it, 0, sizeof it); it.path = -1;
    for (int k = 0; k < len && ok; k++) {
      int32_t m = o->seeds->path[i][k], at = NODE(x, nd)->t;
      int out = step(x, nd, MK_SETTLE, CR(m), CC(m), 0);
      if (!liveNode(x, out) || !stepFitsAt(x, out)) { ok = 0; break; }
      if (!k) { Stats st; statsOf(x, out, &st); if (!firstOk(CR(m), CC(m), NODE(x, out)->brk > stillAt(&still, NODE(x, out)->t) ? 2 : st.cleared > 0)) { ok = 0; break; } }
      it.path = pathAdd(&planTree, it.path, m, at); nd = out;
    }
    if (!ok || it.path == -2) continue;
    it.n = nd; it.nseq = len; it.h = connectedOf(ensureBoard(x, nd));
    pool[npool++] = it; planSeeded++;
  }
  int na = o->aims ? o->aims->n : 0;
  for (int d = 1; d <= o->depth && npool && !clockOut(); d++) {
    int nk = 0, nj = 0;
    static LOCAL int32_t jobP[PLAN_KIDS], jobM[PLAN_KIDS], jobOut[PLAN_KIDS];
    for (int pi = 0; pi < npool; pi++) { pool[pi].reach = 0; pool[pi].nkids = 0; pool[pi].ideas = 0; }
    // the level's jobs: every legal swap of every board in the pool, played to the board's settle
    for (int pi = 0; pi < npool; pi++) { int nm = swapsOfNode(x, pool[pi].n, ms); for (int j = 0; j < nm && nj < PLAN_KIDS; j++) { jobP[nj] = pi; jobM[nj++] = ms[j]; } }
    { static LOCAL int32_t jobN[PLAN_KIDS]; for (int j = 0; j < nj; j++) jobN[j] = pool[jobP[j]].n;
      stepBatch(x, jobN, jobM, MK_SETTLE, nj);   // (every thread: core/nodes.h stepBatch)
      for (int j = 0; j < nj; j++) jobOut[j] = stepTake(x, j, jobN[j], MK_SETTLE, jobM[j]);
      batchDone(); }
    // (A BREAK JUDGED AT ITS BREAK: a line the engine settles dead -- the next slab lands while the board settles -- is played again
    // only to its swap; if the board then breaks garbage that standing still would not have by the same frame, it is a break, kept as
    // the quick break and grown no further)
    if (o->breakAtSwap && !clockOut())
      for (int j = 0; j < nj; j++) {
        if (jobOut[j] != STEP_DEAD) continue;
        PItem *it = &pool[jobP[j]];
        int32_t m = jobM[j];
        int sw = step(x, it->n, MK_SWAP, CR(m), CC(m), 0);
        if (!liveNode(x, sw) || !stepFitsAt(x, sw)) continue;
        int32_t bk = NODE(x, sw)->brk - stillAt(&still, NODE(x, sw)->t);
        if (o->by != NOT_ASKED && NODE(x, it->n)->t > o->by) bk = 0;
        int kc = bk > 0 ? keepsOwnChain(x, sw) : 0, cat = bk > 0 && listChainCap() == 0 ? breakCat(x, sw) : 0;
        if (bk > 0 && quickBefore(&P->quick, kc, cat, bk, NODE(x, sw)->t)) {
          PLine *l = &P->quick; memset(l, 0, sizeof *l);
          lineFrom(l, it, m, sw, NODE(x, it->n)->t);
          l->brk = 1; l->broke = bk; l->done = NODE(x, sw)->t; l->aimIndex = -1; l->floor = -1; l->kc = kc; l->cat = cat;
        }
      }
    // the level read in the order it was made: every board within the rules is a kid of its parent; one that clears is weighed
    for (int pi = 0; pi < npool; pi++) pool[pi].kid0 = -1;
    for (int j = 0; j < nj; j++) {
      if ((j & 31) == 31 && clockOut()) break;
      PItem *it = &pool[jobP[j]];
      int32_t m = jobM[j];
      int out = jobOut[j];
      if (!liveNode(x, out)) continue;
      Stats st; statsOf(x, out, &st);
      // (HOW NEAR A BOARD IS, it is of the board: a swap outside the list -- never played -- still says how near its parent comes, so it
      // counts toward the parent's reach; it is kept as no line and grows no kid)
      if (!stepFitsAt(x, out)) {
        if (st.cleared > 0 && !(o->by != NOT_ASKED && NODE(x, it->n)->t > o->by)) {
          Made mo = { biggestOf(&st), chainOfStats(&st), BROKE_OF(it, st), imax(0, sentCells(&st) - base) };
          double nr = leadOf(o->aims, mo, o->under);
          if (nr > it->reach) it->reach = nr;
        }
        continue;
      }
      if (!it->nseq && !firstOk(CR(m), CC(m), NODE(x, out)->brk > stillAt(&still, NODE(x, out)->t) ? 2 : st.cleared > 0)) continue;
      int32_t firesAim = -1, firesCells = 0;   // (the entry this step fires, -1 none: an idea of its parent's; and what it sends)
      if (st.cleared > 0) {
        int32_t fire = NODE(x, it->n)->t, chain = chainOfStats(&st), bigC = biggestOf(&st), done = NODE(x, out)->t;
        int32_t seqTmp[MAXLINE], ns = imin(it->nseq + 1, MAXLINE);
        pathRead(&planTree, it->path, ns - 1, seqTmp, 0);
        seqTmp[ns - 1] = m;
        int endOk = -1;
        int32_t acts = it->acts + actOf(x, it, m);
        // (of two lines alike, the one the cursor walks fewer actions for, then the fewer swaps: the input window pays for each)
        #define LESS(L) (acts < (L).acts || (acts == (L).acts && ns < (L).nseq))
        #define OKE() (endOk < 0 ? (endOk = allowedAt(x, out) && lineFits(seqTmp, ns, 1)) : endOk)
        Made made = { bigC, chain, BROKE_OF(it, st), imax(0, sentCells(&st) - base) };
        Board *ob = ensureBoard(x, out);
        int inTime = !(o->by != NOT_ASKED && fire > o->by), kept = keepsFloor(o->keep, ob, made.broke), floor = keepsFloor(o->keep, ob, 0);
        #define FILL(L, ai) do { memset(&(L), 0, sizeof (L)); lineFrom(&(L), it, m, out, fire); (L).cells = made.cells; (L).chain = chain; (L).combo = bigC; \
                                 (L).broke = made.broke; (L).earned = st.earned; (L).done = done; (L).floor = floor; (L).aimIndex = (ai); (L).brk = made.broke > 0; (L).acts = acts; } while (0)
        if (!(o->dies > 0 && done > o->dies)) {
          Shape shp = shapeOf(ob);
          if ((!P->lowest.set || shp.top < P->lowest.top || (shp.top == P->lowest.top && LESS(P->lowest))) && OKE()) { FILL(P->lowest, -1); P->lowest.top = shp.top; }
          if (st.earned > 0 && (!P->stopBest.set || st.earned > P->stopBest.earned || (st.earned == P->stopBest.earned && LESS(P->stopBest))) && OKE()) FILL(P->stopBest, -1);
        }
        if (inTime && kept && made.broke > 0) {
          // (the chain kept as the swap leaves it, before the settle the step runs on: by then the chain has run its course)
          int kc = 1;
          if (ownChainBy > 0) { int sw = step(x, it->n, MK_SWAP, CR(m), CC(m), 0); kc = liveNode(x, sw) && keepsOwnChain(x, sw); }
          int cat = listChainCap() == 0 ? breakCat(x, out) : 0;
          if (quickBefore(&P->quick, kc, cat, made.broke, done) && OKE()) { FILL(P->quick, -1); P->quick.brk = 1; P->quick.kc = kc; P->quick.cat = cat; }
        }
        if (inTime && kept) {
          double nr = leadOf(o->aims, made, o->under);
          if (nr > it->reach) it->reach = nr;
          firesAim = o->aims ? metOf(o->aims, made) : -1;
          if (firesAim >= 0) { it->ideas++; firesCells = made.cells; }
          // (A PAIR: the line had fired an idea on its way, and fires another here -- both sent)
          if (firesAim >= 0 && it->fired > 0) {
            int32_t both = it->firedCells + made.cells;
            if ((!P->pair.set || both > P->pair.cells || (both == P->pair.cells && LESS(P->pair))) && OKE()) { FILL(P->pair, imin(firesAim, it->firedAim)); P->pair.cells = both; }
          }
          if (nr > 0 && (!P->nearest.set || nr > P->nearest.near || (nr == P->nearest.near && LESS(P->nearest))) && OKE()) { FILL(P->nearest, -1); P->nearest.near = nr; }
          for (int ai = 0; ai < na; ai++) {
            if (!meets(&o->aims->aim[ai], made)) continue;
            PLine *pa = &P->perAim[ai];
            if ((!pa->set || made.cells > pa->cells || (made.cells == pa->cells && LESS(*pa))) && OKE()) FILL(*pa, ai);
          }
        }
        #undef FILL
        #undef OKE
        #undef LESS
      }
      if (nk < PLAN_KIDS && it->nseq < MAXLINE) {
        PItem *k = &kids[nk]; memset(k, 0, sizeof *k); k->n = out; k->nseq = it->nseq + 1;
        k->path = -1; k->up = it->path; k->km = m; k->kat = NODE(x, it->n)->t;
        k->fired = it->fired; k->firedCells = it->firedCells; k->firedAim = it->firedAim; k->acts = it->acts + actOf(x, it, m);
        if (firesAim >= 0) { k->firedCells += firesCells; k->firedAim = k->fired ? imin(k->firedAim, firesAim) : firesAim; k->fired++; }
        if (!it->nkids) it->kid0 = nk;   // (a parent's kids are made one after another: its swaps are one run of jobs)
        nk++; it->nkids++;
      }
    }
    // the pool ranked by how near the list its lines one swap on come, then by its ideas, then how connected; their kids, each board
    // once, ranked by how connected, make the next pool
    static LOCAL double reachK[PLAN_POOL];
    static LOCAL int32_t ideaK[PLAN_POOL];
    for (int pi = 0; pi < npool; pi++) { idx[pi] = pi; keyB[pi] = pool[pi].h; reachK[pi] = pool[pi].reach; ideaK[pi] = pool[pi].ideas; }
    // (reach, ideas, then how connected, all descending: sorted by the last first, then stably by each before it)
    sortByKeyDesc(idx, npool, keyB, tmpI);
    sortByKeyDesc(idx, npool, ideaK, tmpI);
    sortByDoubleDesc(idx, npool, reachK, tmpI);
    int nn = 0;
    for (int r = 0; r < npool && r < o->width; r++) {
      int pr = idx[r];
      if (clockOut() && nn) break;
      for (int kk = pool[pr].kid0; kk < pool[pr].kid0 + pool[pr].nkids && nn < PLAN_POOL; kk++) {
        PItem *k = &kids[kk];
        Node *kn = NODE(x, k->n);
        int dup = 0;
        for (int q2 = 0; q2 < nn && !dup; q2++) { Node *on = NODE(x, next[q2].n); dup = on->hash == kn->hash && on->keyn == kn->keyn && !memcmp(on->key, kn->key, sizeof(int32_t) * kn->keyn); }
        if (dup) continue;
        int32_t p = pathAdd(&planTree, k->up, k->km, k->kat);
        if (p == -2) continue;
        next[nn] = *k; next[nn].path = p; next[nn].h = connectedOf(ensureBoard(x, k->n)); nn++;
      }
    }
    // the most connected board reached so far, if better than the one now: its first swap is a setup -- a board nearer the list one
    // swap on comes first (its reach), then one as near with more ideas ready, so the setup is played toward the same list
    for (int r = 0; r < npool; r++) {
      PItem *it = &pool[idx[r]];
      if (it->nseq && (it->reach > (haveSetup ? setReachD : 0) || (haveSetup && setReachD > 0 && it->reach == setReachD && it->ideas > setIdeas) ||
                       (!(haveSetup && setReachD) && !it->reach && it->h > (haveSetup ? setH : rootH)))) {
        haveSetup = 1; setReachD = it->reach; setH = it->h; setIdeas = it->ideas;
        P->nsetupLine = imin(it->nseq, MAXLINE); pathRead(&planTree, it->path, P->nsetupLine, P->setupLine, 0);
        P->setup = P->setupLine[0];
      }
    }
    static LOCAL int32_t nidx[PLAN_POOL];
    for (int q2 = 0; q2 < nn; q2++) { nidx[q2] = q2; keyB[q2] = next[q2].h; }
    sortByKeyDesc(nidx, nn, keyB, tmpI);
    int keepN = imin(nn, o->pool);
    PItem *old = pool; pool = next; next = old;
    static LOCAL PItem sorted[PLAN_POOL];
    for (int q2 = 0; q2 < keepN; q2++) sorted[q2] = pool[nidx[q2]];
    for (int q2 = 0; q2 < keepN; q2++) pool[q2] = sorted[q2];
    npool = keepN;
  }
  // READY: an entry's line and the nearest kept only if the board it leaves breaks the block on its way once it has landed -- not in
  // finish them (a list of combos up to eight and up, no chain): there every combo is the attack, offered to the rank, which judges its
  // life and its readiness beside every other line (the owner: break the garbage with combos)
  int finishList = 0;
  { int chain = 0, big = 0; for (int i = 0; i < theList.n; i++) { if (theList.aim[i].chain.op) chain = 1; if (theList.aim[i].combo.op && theList.aim[i].combo.n + (theList.aim[i].combo.op == OP_GT) >= 8) big = 1; }
    finishList = big && !chain; }
  if (o->readyAt != NOT_ASKED && !finishList) {
    clockShareEnd(shareOld); shareOld = clockShareBegin(t0 + 2 * o->ms);
    for (int ai = 0; ai < na; ai++) if (P->perAim[ai].set && !clockOut() && !readyAfter(x, P->perAim[ai].n, o->readyAt)) P->perAim[ai].set = 0;
    if (P->nearest.set && !readyAfter(x, P->nearest.n, o->readyAt)) P->nearest.set = 0;
  }
  if (!haveSetup) { P->setup = 0; P->nsetupLine = 0; }
  // (the plan kept for the next decision: the lines it found, then the beam's last boards, most connected first)
  planOut.n = 0;
  for (int ai = 0; ai < na; ai++) if (P->perAim[ai].set) planKeep(P->perAim[ai].seq, P->perAim[ai].nseq);
  { const PLine *ls[] = { &P->nearest, &P->quick, &P->lowest, &P->stopBest, &P->pair }; for (int q2 = 0; q2 < 5; q2++) if (ls[q2]->set) planKeep(ls[q2]->seq, ls[q2]->nseq); }
  for (int q2 = 0; q2 < npool; q2++) if (pool[q2].nseq <= MAXPATH) { int32_t sq[MAXPATH]; pathRead(&planTree, pool[q2].path, pool[q2].nseq, sq, 0); planKeep(sq, pool[q2].nseq); }
  P->ms = nowMs() - t0;
  clockShareEnd(shareOld);
  #undef BROKE_OF
}
// (its boards let go once it has answered: every thread that searches has a context of its own, and a tree held is thousands of boards)
static void plan(const Question *q, const PlanOpts *o, Plan *P) { planIn(q, o, P); planCtx = ctxLetGo(planCtx); }

// ---- for a host's check: the planner on the question set (gb_question), the list set (gb_list), its numbers given; back into the io:
// per entry of the list whether a line meets it, its swaps and chain, then the nearest line's near and chain, and the planner's ms
EXPORT(gb_plan) int gb_plan(int width, int depth, int pool, int by, double ms) {
  static Plan P;
  clockStart(0);
  decQ = hostQ; decQ.b = hostBoard;
  PlanOpts o = { width, depth, pool, &theList, by > 0 ? by : NOT_ASKED, 0, NOT_ASKED, 0, 0, 0, ms };
  plan(&decQ, &o, &P);
  int32_t *w = gbIo, k = 0;
  w[k++] = theList.n;
  for (int i = 0; i < theList.n; i++) { w[k++] = P.perAim[i].set; w[k++] = P.perAim[i].nseq; w[k++] = P.perAim[i].chain; }
  w[k++] = (int32_t)(P.nearest.near * 1000); w[k++] = P.nearest.chain; w[k++] = (int32_t)P.ms;
  return k;
}
