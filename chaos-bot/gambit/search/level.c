// LEVEL: of the swaps that clear nothing and are settled by `by` (the next block lands), the one that leaves the least
// hollow under the garbage, then the flattest stack -- only one better than the board left alone, through the shared line check.
// The swap, or 0 for none.
static Ctx *levelCtx;
static int32_t level(const Question *q, int32_t by) {
  Ctx *x = levelCtx = ctxOf(levelCtx);
  int root = rootOf(x, q);
  if (root < 0) return 0;
  int r0 = settleOf(x, root);
  if (!liveNode(x, r0)) return 0;
  Shape before = shapeOf(ensureBoard(x, r0)), bestS;
  int32_t best = 0, ms[MAXROWS * W];
  int nm = swapsOfNode(x, root, ms);
  static int outs[MAXROWS * W];
  for (int i = 0; i < nm; i++) outs[i] = step(x, root, MK_SETTLE, CR(ms[i]), CC(ms[i]), 0);
  for (int i = 0; i < nm; i++) {
    int out = outs[i];
    if (!liveNode(x, out)) continue;
    Stats st; statsOf(x, out, &st);
    if (st.cleared > 0 || (by != NOT_ASKED && by && NODE(x, out)->t > by) || !firstOk(CR(ms[i]), CC(ms[i]), 0)) continue;
    Shape sh = shapeOf(ensureBoard(x, out));
    if (sh.hollow > before.hollow || (sh.hollow == before.hollow && sh.even >= before.even)) continue;
    if ((!best || sh.hollow < bestS.hollow || (sh.hollow == bestS.hollow && sh.even < bestS.even)) && lineFits(&ms[i], 1, 1)) { best = ms[i]; bestS = sh; }
  }
  return best;
}
