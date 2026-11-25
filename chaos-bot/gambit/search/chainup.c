// THE OPENER'S CHAIN, BUILT (the owner: the opener has the countdown and the raise to set its chain up -- every move it would hold
// for goes into it): the longest chain one swap sets off on a board, played to its settle on the engine (triggerChainOf), and the
// set-up swap -- one that clears nothing itself -- after which that chain is longest (chainUpSwap), the nearest the cursor first.
// A hill climbed a swap at a time: each swap is judged as any line before it is pressed (decide.c, the opener's second hand).
static LOCAL Ctx *cuCtxA, *cuCtxB;
// the longest chain one swap sets off from the question's board, and that swap in *sw (0: none sets one off)
static int32_t triggerChainOf(const Question *q, int32_t *sw) {
  Ctx *x = cuCtxB = ctxOf(cuCtxB);
  int root = rootOf(x, q);
  if (root < 0) return 0;
  int32_t ms[MAXROWS * W]; int m = swapsOfNode(x, root, ms); int32_t best = 0;
  for (int i = 0; i < m && !clockOut(); i++) {
    int n = step(x, root, MK_SWAP, CR(ms[i]), CC(ms[i]), 0);
    if (!liveNode(x, n)) continue;
    int out = settleOf(x, n);
    if (!liveNode(x, out)) continue;
    Stats s; int32_t c = 0;
    if (statsOf(x, n, &s)) c = chainOfStats(&s);
    if (statsOf(x, out, &s) && chainOfStats(&s) > c) c = chainOfStats(&s);
    if (c > best) { best = c; if (sw) *sw = ms[i]; }
  }
  return best;
}
// the set-up swap after which the board's trigger chain is longest, clearing nothing itself, of those that make it longer than now;
// *now the trigger chain as the board stands, *after the one the swap leaves. 0: none makes it longer
static int chainUpSwap(const Question *q, int32_t *sw, int32_t *now, int32_t *after) {
  int32_t t0 = 0; *now = triggerChainOf(q, &t0); *after = *now;
  Ctx *x = cuCtxA = ctxOf(cuCtxA);
  int root = rootOf(x, q);
  if (root < 0) return 0;
  const Board *b0 = ensureBoard(x, root);
  if (!b0) return 0;
  int32_t ms[MAXROWS * W]; int m = swapsOfNode(x, root, ms);
  // (the nearest the cursor first: a climb cut by the clock has asked the swaps it would press soonest)
  int d[MAXROWS * W];
  for (int i = 0; i < m; i++) d[i] = iabs(CR(ms[i]) - b0->curRow) + iabs(CC(ms[i]) - b0->curCol);
  for (int i = 0; i < m; i++) for (int j = i + 1; j < m; j++) if (d[j] < d[i]) { int t = d[i]; d[i] = d[j]; d[j] = t; int32_t u = ms[i]; ms[i] = ms[j]; ms[j] = u; }
  int found = 0;
  for (int i = 0; i < m && !clockOut(); i++) {
    int n = step(x, root, MK_SWAP, CR(ms[i]), CC(ms[i]), 0);
    if (!liveNode(x, n)) continue;
    int out = settleOf(x, n);
    if (!liveNode(x, out)) continue;
    Stats s;
    if ((statsOf(x, n, &s) && s.cleared > 0) || (statsOf(x, out, &s) && s.cleared > 0)) continue;   // (a set-up clears nothing)
    Board *eb = ensureBoard(x, out);
    if (!eb) continue;
    Question q2 = *q; q2.b = eb; q2.narr = 0; q2.holdLeft = 0; q2.holdStarted = 0;
    int32_t c = triggerChainOf(&q2, 0);
    if (c > *after) { *after = c; *sw = ms[i]; found = 1; }
  }
  return found;
}
