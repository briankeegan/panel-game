// THE BITS HELD TO THE CELLS (test/bits_test.c asks it, built with GB_TEST): on the question's board and on every board one swap and two
// swaps from it, each reader on the bits and its cell-by-cell reference (test/cells_ref.c) asked alike; the boards checked and the
// disagreements, counted.
static int32_t bitsBoards, bitsWrong;
static double bitsMs, cellsMs;   // the nearest break asked 50 times a board, on the bits (reading them included) and on the cells
static int bitsAgreeOn(const Board *b) {
  static Bits B;
  bitsOf(b, &B);
  int wrong = 0, top = gridLen(b) - 2;
  if (bitsLowestG(&B) != refLowestG(b)) wrong++;
  if (unevenOf(&B) != refUneven(b)) wrong++;
  if (bitsPanels(&B) != refPanelsOn(b)) wrong++;
  if ((bitsLowestG(&B) <= B.rows) != refGarbageOn(b)) wrong++;
  int32_t s1[MAXPATH], s2[MAXPATH]; int n1 = 0, n2 = 0;
  int d1 = nearLineOf(&B, s1, &n1), d2 = refBreakNearLine(b, s2, &n2);
  if (d1 != d2 || n1 != n2) wrong++;
  else for (int i = 0; i < n1; i++) if (s1[i] != s2[i]) { wrong++; break; }
  for (int q = 1; q <= top; q++) for (int k = 1; k <= W; k++) for (int32_t want = 1; want <= 8; want++)
    for (unsigned used = 0; used < (1u << W); used += 7) {
      int ref[W + 2] = { 0 };
      for (int c = 1; c <= W; c++) ref[c] = used >> (c - 1) & 1;
      int f1 = -9, f2 = -9, a = bitsBring(&B, q, k, want, (used << 1) & ALLCOLS, &f1), z = refBring(b, top, q, k, want, ref, &f2);
      if (a != z || (a >= 0 && f1 != f2)) wrong++;
    }
  { double t0 = nowMs(); volatile int z = 0;
    for (int i = 0; i < 50; i++) { static Bits T; bitsOf(b, &T); z += nearLineOf(&T, 0, 0); }
    double t1 = nowMs();
    for (int i = 0; i < 50; i++) z += refBreakNearLine(b, 0, 0);
    bitsMs += t1 - t0; cellsMs += nowMs() - t1; (void)z; }
  bitsBoards++; bitsWrong += wrong;
  return wrong;
}
// A PERCHED BLOCK LET DOWN, on the engine: each line perchedDrops offers, played and settled; how many let their block's bottom row
// down a row or more (by its garbage id)
static int32_t perchOffered, perchDropped;
static int lowestOf(const Board *b, int32_t id) {
  for (int r = 1; r <= b->height + 1 && r < b->nrows; r++) for (int c = 1; c <= W; c++) if (gridCell(b, r, c) < 0 && b->p[r][c].f[GARBAGEID] == id) return r;
  return 0;
}
static void perchOn(Ctx *x, int root) {
  const Board *b = ensureBoard(x, root);
  if (!b) return;
  static Perches P; perchedDrops(b, &P);
  for (int i = 0; i < P.n; i++) {
    int r = CR(P.seq[i][0]) + 1, c0 = CC(P.seq[i][0]), id = 0;
    for (int c = 1; c <= W && !id; c++) if (gridCell(b, r, c) < 0 && (c == c0 || c == c0 + 1)) id = b->p[r][c].f[GARBAGEID];
    if (!id) for (int c = 1; c <= W && !id; c++) if (gridCell(b, r, c) < 0) id = b->p[r][c].f[GARBAGEID];
    int before = lowestOf(b, id), n = root;
    for (int k = 0; k < P.len[i] && liveNode(x, n); k++) n = step(x, n, MK_SWAP, CR(P.seq[i][k]), CC(P.seq[i][k]), 0);
    if (liveNode(x, n)) n = step(x, n, MK_SETTLE, 0, 0, 0);
    perchOffered++;
    const Board *e = liveNode(x, n) ? ensureBoard(x, n) : 0;
    if (e && before && lowestOf(e, id) && lowestOf(e, id) < before) perchDropped++;
  }
}
EXPORT(gb_perch_counts) int gb_perch_counts(int which) { return which ? perchDropped : perchOffered; }
// THE GARBAGE LET DOWN, on the engine: the line letDownLine offers (propose.c), played and settled; how many leave the garbage nearer
// coming down a row (search/break.c perchOf) than the board left alone to settle
static int32_t letOffered, letDowns;
static void letOn(Ctx *x, int root) {
  const Board *b = ensureBoard(x, root);
  if (!b || !garbageOn(b)) return;
  static int32_t line[MAXPATH]; int len = letDownLine(b, line);
  if (!len) return;
  int alone = step(x, root, MK_SETTLE, 0, 0, 0), n = root;
  for (int k = 0; k < len && liveNode(x, n); k++) n = step(x, n, MK_SWAP, CR(line[k]), CC(line[k]), 0);
  if (liveNode(x, n)) n = step(x, n, MK_SETTLE, 0, 0, 0);
  letOffered++;
  const Board *e = liveNode(x, n) ? ensureBoard(x, n) : 0, *a = liveNode(x, alone) ? ensureBoard(x, alone) : 0;
  int ce, ca;
  if (e && a && perchOf(e, &ce) < perchOf(a, &ca)) letDowns++;
}
EXPORT(gb_let_counts) int gb_let_counts(int which) { return which ? letDowns : letOffered; }
static Ctx *bitsCtx;
EXPORT(gb_bits_agree) int gb_bits_agree(void) {
  if (!hostBoard) return -1;
  curQid = abortId + 1; clockAborted = 0;   // (a question being answered: the searches' steps are not cut)
  bitsAgreeOn(hostBoard);
  Ctx *x = bitsCtx = ctxOf(bitsCtx);
  int root = rootOf(x, &hostQ);
  if (root < 0) return bitsWrong;
  perchOn(x, root); letOn(x, root);
  static int32_t ms[MAXROWS * W], ms2[MAXROWS * W];
  int nm = swapsOfNode(x, root, ms);
  for (int i = 0; i < nm; i++) {
    int o = step(x, root, MK_SETTLE, CR(ms[i]), CC(ms[i]), 0);
    if (!liveNode(x, o)) continue;
    const Board *b = ensureBoard(x, o);
    if (b) bitsAgreeOn(b);
    perchOn(x, o); letOn(x, o);
    if (i % 8) continue;
    int nm2 = swapsOfNode(x, o, ms2);
    for (int j = 0; j < nm2; j += 3) {
      int o2 = step(x, o, MK_SETTLE, CR(ms2[j]), CC(ms2[j]), 0);
      if (liveNode(x, o2)) { const Board *b2 = ensureBoard(x, o2); if (b2) bitsAgreeOn(b2); }
    }
  }
  return bitsWrong;
}
EXPORT(gb_bits_boards) int gb_bits_boards(void) { return bitsBoards; }
EXPORT(gb_bits_ms) double gb_bits_ms(int cells) { return cells ? cellsMs : bitsMs; }
