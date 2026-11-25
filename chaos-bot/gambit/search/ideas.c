// THE IDEAS A BOARD HOLDS (plans/gambit-goal.md 5, several ideas at once): on a board at rest, each swap that, played to the settle
// and within the rules, makes a clear meeting an entry of the list -- an attack one swap from being fired. Two that clear a panel in
// common are one idea (either spends the other); the count is of ideas that clear none in common, the most sent first, so each is
// fired on its own and the rest stay ready. The garbage on its way is left out: an idea is the board's own colours.
#define IDEA_CANDS 64
static LOCAL Ctx *ideaCtx;
static int ideasOn(const Board *b, const List *aims) {
  if (!b || !aims || !aims->n || clockOut()) return -1;
  Ctx *x = ideaCtx = ctxOf(ideaCtx);
  Question q; memset(&q, 0, sizeof q); q.b = (Board *)b; q.tight = decQ.tight;
  int root = rootOf(x, &q);
  if (root < 0) return -1;
  const Board *b0 = ensureBoard(x, root);
  if (!b0) return -1;
  // (the panels on the board, by id: what each idea's settle takes off)
  static LOCAL int32_t pid[MAXROWS * W], ms[MAXROWS * W], par[MAXROWS * W], kid[MAXROWS * W], cells[IDEA_CANDS], idx[IDEA_CANDS], tmp[IDEA_CANDS];
  static LOCAL uint8_t gone[IDEA_CANDS][MAXROWS * W];
  int np = 0;
  for (int r = 1; r < b0->nrows; r++) for (int c = 1; c <= W; c++) {
    const int32_t *f = b0->p[r][c].f;
    if (f[COLOR] > 0 && f[COLOR] < 8 && !f[ISGARBAGE] && f[ID] != NUL && np < MAXROWS * W) pid[np++] = f[ID];
  }
  int nm = swapsOfNode(x, root, ms), ni = 0;
  for (int j = 0; j < nm; j++) par[j] = root;
  stepBatch(x, par, ms, MK_SETTLE, nm);
  for (int j = 0; j < nm && ni < IDEA_CANDS; j++) {
    int out = stepTake(x, j, root, MK_SETTLE, ms[j]);
    Stats st;
    if (!liveNode(x, out) || !statsOf(x, out, &st) || st.cleared <= 0 || !stepFitsAt(x, out)) continue;
    Made m = { biggestOf(&st), chainOfStats(&st), st.broke, sentCells(&st) };
    if (metOf(aims, m) < 0) continue;
    const Board *e = ensureBoard(x, out);
    if (!e) continue;
    int nk = 0;
    for (int r = 1; r < e->nrows; r++) for (int c = 1; c <= W; c++) { const int32_t *f = e->p[r][c].f; if (f[ID] != NUL && nk < MAXROWS * W) kid[nk++] = f[ID]; }
    for (int i = 0; i < np; i++) { int here = 0; for (int k = 0; k < nk && !here; k++) here = kid[k] == pid[i]; gone[ni][i] = !here; }
    cells[ni] = m.cells; idx[ni] = ni; ni++;
  }
  batchDone();
  if (clockOut()) return -1;
  // (the most sent first, each kept only when it clears no panel one kept already does)
  sortByKeyDesc(idx, ni, cells, tmp);
  static LOCAL uint8_t used[MAXROWS * W];
  memset(used, 0, sizeof used);
  int n = 0;
  for (int a = 0; a < ni; a++) {
    const uint8_t *g = gone[idx[a]];
    int clash = 0;
    for (int i = 0; i < np && !clash; i++) clash = g[i] && used[i];
    if (clash) continue;
    for (int i = 0; i < np; i++) used[i] |= g[i];
    n++;
  }
  return n;
}
