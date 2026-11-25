// GAMBIT'S SURVIVAL SEARCH: lines of swaps played one after another, a beam of the boards lost latest left alone, of
// those held longest -- the frame the garbage queued could next drop (the line's frames, then the later of stop + pre-stop and the
// shake) -- then the least garbage, the most panels kept, the most room over the stack; each step's clears held to the list. The first line whose
// board, left alone, is still alive at `to` (frames from now) and `rest` past its own end, and passes the shared line check, is the
// answer; else the line whose board is lost latest. And THE FRAMES UNTIL THE BOARD IS LOST IF NOTHING IS DONE (diesIn).

#define OUT_SEQ 16
#define OUT_DEPTH 10   // (the swaps deep the survival beam may grow: its clock stops it first on a busy decision -- a level is begun only
                       // while the time it takes is left -- and a board with time to spare is searched further, not left at six)
typedef struct { int32_t n, nseq, seq[OUT_SEQ], room, h, g, p, lost, acts; } OItem;   // acts: the cursor's actions for its swaps, from the root's cursor
typedef struct { int32_t set, nseq, seq[OUT_SEQ], lostAt, acts; } Outlived;
static LOCAL int outFree;   // (the save pass: steps not held to the list -- outliveSave)
static LOCAL Ctx *outCtx;   // (each thread its own: the survival search runs on a worker beside the decision -- answer.c)
static int32_t heldOf(Ctx *x, int n) { Node *e = NODE(x, n); return e->t + imax(e->stopTime + e->preStopTime, e->shakeTime); }
// (THE RESERVE: with an input allowance said, the line kept is the latest lost of those that leave OUT_RESERVE actions of it -- unless one
// that spends them is lost OUT_LATER frames later still: what a line spends comes back only a window later, and the board's next break is
// pressed out of what is left)
#define OUT_RESERVE 20
#define OUT_LATER 120
// (THE SAVE NEAREST THE CURSOR: of two lines lost at frames finite, the later loss less what its actions cost -- an action comes back a
// window later, OUT_ACT frames each (76 in 600) -- so a save across the board must buy that much more time than one at hand; one that
// lasts beats one that does not)
#define OUT_ACT 8
static int outBetter(int32_t l, int32_t a, int32_t ol, int32_t oa) {
  if (l == FOREVER || ol == FOREVER) return l == FOREVER && (ol != FOREVER || a < oa);
  double v = l - (double)OUT_ACT * a, ov = ol - (double)OUT_ACT * oa;
  return v > ov || (v == ov && a < oa);
}
// THE LINE PLAYED FROM THE ROOT as the beam steps it -- each swap one the board has there, its walk one the window pays for, its step
// held to the list, the first never the swap back: the node it ends on and the actions it walks (*acts), or -1.
static int outPlayed(Ctx *x, int root, BS *still, const int32_t *seq, int nseq, int32_t *acts) {
  int32_t ms1[MAXROWS * W];
  int n = root; *acts = 0;
  for (int i = 0; i < nseq; i++) {
    const Board *pb = ensureBoard(x, n);
    int nm = swapsOfNode(x, n, ms1), has = 0;
    for (int j = 0; j < nm && !has; j++) has = ms1[j] == seq[i];
    if (!pb || !has) return -1;
    int32_t left = pressAllowance >= 0 ? allowLeftAt(NODE(x, n)->t - NODE(x, root)->t, *acts) : HOLDTIGHT + 1;
    int a = actionsFor(pb->curRow, pb->curCol, CR(seq[i]), CC(seq[i]), left);
    if (pressAllowance >= 0 && a > left) return -1;
    int out = step(x, n, MK_SWAP, CR(seq[i]), CC(seq[i]), 0);
    if (!liveNode(x, out) || (!outFree && !stepFitsAt(x, out))) return -1;
    if (i == 0) { Stats st; statsOf(x, out, &st); if (!firstOk(CR(seq[0]), CC(seq[0]), NODE(x, out)->brk > stillAt(still, NODE(x, out)->t) ? 2 : st.cleared > 0)) return -1; }
    *acts += a; n = out;
  }
  return n;
}
// NO SWAP THE BOARD LIVES AS LONG WITHOUT (the owner: no walk far away that does nothing): the answer's swaps left out one at a time,
// the one whose leaving saves the cursor the most actions first -- the line played again without it, and kept so where its board, left
// alone, is lost no sooner and it walks fewer actions; each swap asked once, while the search's time lasts.
static void outLean(Ctx *x, int root, BS *still, Outlived *o, int32_t to, int32_t rest, double until) {
  int32_t asked[OUT_SEQ] = { 0 };
  const Board *rb = ensureBoard(x, root);
  while (rb && o->set && o->nseq > 1 && nowMs() < until) {
    int32_t cut[OUT_SEQ], best = -1, bestActs = 0, n = 0;
    for (int i = 0; i < o->nseq; i++) {
      if (asked[i]) continue;
      int32_t r = rb->curRow, c = rb->curCol, acts = 0;
      for (int k = 0; k < o->nseq; k++) if (k != i) { acts += actionsFor(r, c, CR(o->seq[k]), CC(o->seq[k]), HOLDTIGHT + 1); r = CR(o->seq[k]); c = CC(o->seq[k]); }
      if (best < 0 || acts < bestActs) { best = i; bestActs = acts; }
    }
    if (best < 0) break;
    asked[best] = 1;
    for (int k = 0; k < o->nseq; k++) if (k != best) cut[n++] = o->seq[k];
    int32_t acts, end = outPlayed(x, root, still, cut, n, &acts);
    if (end < 0 || acts >= o->acts) continue;
    int32_t lost = lostAlone(x, end, imax(to, NODE(x, end)->t + rest));
    if (lost == NOT_ASKED || (lost != FOREVER && (o->lostAt == FOREVER || lost < o->lostAt))) continue;
    if (lost == FOREVER && !outFree && !lineFits(cut, n, 0)) continue;
    for (int k = best; k < n; k++) { o->seq[k] = cut[k]; asked[k] = asked[k + 1]; }
    o->nseq = n; o->acts = acts; o->lostAt = lost;
  }
}
static Outlived outliveIn(const Question *q, int32_t to, int32_t rest, double ms, int depth, int width) {
  Outlived best, over; memset(&best, 0, sizeof best); memset(&over, 0, sizeof over);
  double t0 = nowMs(), perStep = 0;
  Ctx *x = outCtx = ctxOf(outCtx);
  int root = rootOf(x, q);
  if (root < 0) return best;
  BS still; memset(&still, 0, sizeof still); still.x = x; still.root = root;
  static OItem level[PLAN_POOL], kids[PLAN_KIDS];
  static int32_t idx[PLAN_KIDS], tmpI[PLAN_KIDS], kh[PLAN_KIDS], kr[PLAN_KIDS], kg[PLAN_KIDS], kl[PLAN_KIDS], ka[PLAN_KIDS], kp[PLAN_KIDS], ms1[MAXROWS * W];
  int nlev = 1;
  memset(&level[0], 0, sizeof level[0]); level[0].n = root;
  int keep = pressAllowance >= 0 ? allowLeftAt(0, 0) - OUT_RESERVE : 1 << 20;
  for (int d = 1; d <= depth && nlev; d++) {
    double tl = nowMs();
    int nsteps = 0;
    for (int i = 0; i < nlev; i++) nsteps += swapsOfNode(x, level[i].n, ms1);
    // (a level is begun only while what the last took a step, over this one's steps, is left)
    if (nowMs() - t0 + perStep * nsteps > ms) break;
    int nk = 0;
    // (the level's swaps stepped on every thread first, then taken in this order: core/nodes.h stepBatch)
    static int32_t bPar[PLAN_KIDS], bMv[PLAN_KIDS], bAt[PLAN_KIDS + 1];
    int nb = 0;
    for (int i = 0; i < nlev; i++) {
      bAt[i] = nb;
      int nm = swapsOfNode(x, level[i].n, ms1);
      // (THE WINDOW HOLDS THE LINE: a swap whose walk is over what the input window leaves at its frame is not there to press -- the judge
      // cuts the line at it and a line cut is dropped whole, so the search never steps one: every swap of the line it keeps is one the
      // window pays for, by the judge's own count (core/nodes.h allowLeftAt, actionsFor))
      const Board *pb = pressAllowance >= 0 ? ensureBoard(x, level[i].n) : 0;
      int32_t left = pb ? allowLeftAt(NODE(x, level[i].n)->t - NODE(x, root)->t, level[i].acts) : -1;
      for (int j = 0; j < nm && nb < PLAN_KIDS; j++) {
        if (pb && actionsFor(pb->curRow, pb->curCol, CR(ms1[j]), CC(ms1[j]), left) > left) continue;
        bPar[nb] = level[i].n; bMv[nb++] = ms1[j];
      }
    }
    bAt[nlev] = nb;
    stepBatch(x, bPar, bMv, MK_SWAP, nb);
    for (int i = 0; i < nlev; i++) {
      for (int b = bAt[i], j = 0; b < bAt[i + 1] && nk < PLAN_KIDS; b++, j++) {
        ms1[j] = bMv[b];
        int out = stepTake(x, b, level[i].n, MK_SWAP, bMv[b]);
        if (!liveNode(x, out) || (!outFree && !stepFitsAt(x, out))) continue;
        if (d == 1) { Stats st; statsOf(x, out, &st); if (!firstOk(CR(ms1[j]), CC(ms1[j]), NODE(x, out)->brk > stillAt(&still, NODE(x, out)->t) ? 2 : st.cleared > 0)) continue; }
        Node *on = NODE(x, out);
        int dup = 0;
        for (int q2 = 0; q2 < nk && !dup; q2++) { Node *kn = NODE(x, kids[q2].n); dup = kn->hash == on->hash && kn->keyn == on->keyn && !memcmp(kn->key, on->key, sizeof(int32_t) * on->keyn); }
        if (dup) continue;
        OItem *k = &kids[nk++]; memset(k, 0, sizeof *k);
        k->n = out; k->nseq = imin(level[i].nseq + 1, OUT_SEQ);
        for (int s2 = 0; s2 < level[i].nseq && s2 < OUT_SEQ; s2++) k->seq[s2] = level[i].seq[s2];
        if (level[i].nseq < OUT_SEQ) k->seq[level[i].nseq] = ms1[j];
        k->room = ensureBoard(x, out)->height - on->top; k->h = heldOf(x, out); k->g = on->garb; k->p = panelsOn(ensureBoard(x, out));
        { const Board *pb = ensureBoard(x, level[i].n); k->acts = level[i].acts + (pb ? actionsFor(pb->curRow, pb->curCol, CR(ms1[j]), CC(ms1[j]), pressAllowance >= 0 ? allowLeftAt(NODE(x, level[i].n)->t - NODE(x, root)->t, level[i].acts) : HOLDTIGHT + 1) : 0); }
      }
    }
    batchDone();
    // the boards held longest, then the least garbage, then the most panels kept (the owner: keep enough to break the garbage -- of two
    // that hold as long, the one that spent fewer threes to do it; room over the stack is bought by clearing panels, so it comes after),
    // then the fewest actions walked (the game allows 76 in 600 frames: run 4228 factory 5, 335, a survive line walked rows 9, 2, 7, 10,
    // 5 and 8 and took the window 64 to 33, held at 2 from 753 to its loss at 847), then the most room; each run on alone to the frame
    // it is lost
    for (int i = 0; i < nk; i++) { idx[i] = i; kh[i] = kids[i].h; kr[i] = kids[i].room; kg[i] = -kids[i].g; kp[i] = kids[i].p; ka[i] = -kids[i].acts; }
    sortByKeyDesc(idx, nk, kr, tmpI); sortByKeyDesc(idx, nk, ka, tmpI); sortByKeyDesc(idx, nk, kp, tmpI); sortByKeyDesc(idx, nk, kg, tmpI); sortByKeyDesc(idx, nk, kh, tmpI);
    int nkeep = imin(nk, 2 * width);
    static OItem top[PLAN_POOL];
    for (int i = 0; i < nkeep; i++) top[i] = kids[idx[i]];
    for (int i = 0; i < nkeep; i++) {
      // (once a line within the reserve lives, only one that walks fewer actions is asked: of the lines that live, the one that walks least)
      if (best.set && best.lostAt == FOREVER && top[i].acts >= best.acts) continue;
      top[i].lost = lostAlone(x, top[i].n, imax(to, NODE(x, top[i].n)->t + rest));
      if (top[i].lost == FOREVER && !outFree && !lineFits(top[i].seq, top[i].nseq, 0)) { top[i].lost = -1; continue; }
      Outlived *o = top[i].acts <= keep ? &best : &over;
      if (!o->set || outBetter(top[i].lost, top[i].acts, o->lostAt, o->acts)) { o->set = 1; o->acts = top[i].acts; o->nseq = top[i].nseq; for (int s2 = 0; s2 < top[i].nseq; s2++) o->seq[s2] = top[i].seq[s2]; o->lostAt = top[i].lost; }
    }
    if (best.set && best.lostAt == FOREVER) { outLean(x, root, &still, &best, to, rest, t0 + ms); return best; }
    for (int i = 0; i < nkeep; i++) { idx[i] = i; kl[i] = top[i].lost; }
    sortByKeyDesc(idx, nkeep, kl, tmpI);
    nlev = imin(nkeep, width);
    for (int i = 0; i < nlev; i++) level[i] = top[idx[i]];
    perStep = nsteps ? (nowMs() - tl) / nsteps : 0;
  }
  if (over.set && (!best.set || (over.lostAt == FOREVER ? best.lostAt != FOREVER : best.lostAt != FOREVER && over.lostAt > best.lostAt + OUT_LATER))) best = over;
  outLean(x, root, &still, &best, to, rest, t0 + ms);
  return best;
}
// (its boards let go once it has answered: every thread that searches has a context of its own, and a tree held is thousands of boards)
static Outlived outlive(const Question *q, int32_t to, int32_t rest, double ms, int depth, int width) { Outlived r = outliveIn(q, to, rest, ms, depth, width); outCtx = ctxLetGo(outCtx); return r; }
// THE SAVE (the owner: death is never an option): where no line held to the list lives, the search again in the time left with its steps
// free of the list -- a plain three is the only move a board topped by its own panels has. Its line is offered only; the decision's no
// wasted three (decide.c) plays it only where every line within the rule is lost and the save, asked, outlasts them
static Outlived outliveSave(const Question *q, int32_t to, int32_t rest, double ms, int depth, int width) {
  double t0 = nowMs();
  Outlived best = outlive(q, to, rest, ms, depth, width);
  if (best.set && best.lostAt == FOREVER) return best;
  double left = ms - (nowMs() - t0);
  if (left < 1) return best;
  outFree = 1;
  Outlived f = outlive(q, to, rest, left, depth, width);
  outFree = 0;
  if (f.set && f.nseq && (!best.set || (f.lostAt == FOREVER ? best.lostAt != FOREVER : best.lostAt != FOREVER && f.lostAt > best.lostAt))) return f;
  return best;
}
static int32_t diesInOn(const Question *q, double horizon) {
  Ctx *x = outCtx = ctxOf(outCtx);
  int root = rootOf(x, q);
  if (root < 0) return 0;
  int32_t h = (int32_t)horizon; if (h < horizon) h++;
  return lostAlone(x, root, imax(1, h));
}
// (its boards let go once it has answered: every thread that searches has a context of its own, and a tree held is thousands of boards)
static int32_t diesIn(const Question *q, double horizon) { int32_t r = diesInOn(q, horizon); outCtx = ctxLetGo(outCtx); return r; }
