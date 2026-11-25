// THE BOARD READ CELL BY CELL: the readers search/bits.c replaced, kept only as the reference test/bits_test.c holds the bits to.
// the lowest row with garbage, from row 1 (G = grid length when none)
static int refLowestG(const Board *b) {
  int R = gridLen(b);
  for (int r = 1; r < R; r++) for (int c = 1; c <= W; c++) if (cellAt(b, r, c) < 0) return r;
  return R;
}
// How uneven the stack under the lowest garbage is: each column's shortfall from the tallest, squared
static int32_t refUneven(const Board *b) {
  int G = refLowestG(b), hi = 0, tops[W + 1];
  for (int c = 1; c <= W; c++) { int t = 0; for (int r = 1; r < G; r++) if (cellAt(b, r, c) > 0) t = r; tops[c] = t; if (t > hi) hi = t; }
  int32_t u = 0;
  for (int c = 1; c <= W; c++) u += (hi - tops[c]) * (hi - tops[c]);
  return u;
}
// HOW MANY SWAPS AWAY THE NEAREST BREAK IS (breakNear): the fewest swaps that line up a match of three with a panel touching garbage --
// each other panel of the match brought along its own row, over cells that hold it up and are not garbage. NEAR_MISS when none.
static int refHeldAt(const Board *b, int top, int q, int k) {
  int32_t v = q >= 1 && q <= top ? cellAt(b, q, k) : 0, under = q - 1 >= 1 && q - 1 <= top ? cellAt(b, q - 1, k) : 0;
  return v >= 0 && (q == 1 || under != 0);
}
static int32_t refCellIn(const Board *b, int top, int q, int k) { return q >= 1 && q <= top ? cellAt(b, q, k) : 0; }
// the swaps that bring a panel of colour want in row q to column k, not taking a column in used: { d, from }, d < 0 for none
static int refBring(const Board *b, int top, int q, int k, int32_t want, const int *used, int *from) {
  if (refCellIn(b, top, q, k) == want && !used[k]) { *from = k; return 0; }
  int best = -1;
  for (int dir = -1; dir <= 1; dir += 2) {
    int ok = refHeldAt(b, top, q, k);
    for (int j = k + dir; j >= 1 && j <= W && ok; j += dir) {
      if (refCellIn(b, top, q, j) == want && !used[j]) { int d = j > k ? j - k : k - j; if (best < 0 || d < best) { best = d; *from = j; } break; }
      if (!refHeldAt(b, top, q, j)) ok = 0;
    }
  }
  return best;
}
// (and the line that makes it: seq, *nseq -- each panel walked in turn; 0 for none)
static int refBreakNearLine(const Board *b, int32_t *seq, int *nseq) {
  int top = gridLen(b) - 2, best = 1 << 30;
  if (nseq) *nseq = 0;
  for (int r = 1; r <= top; r++) for (int c = 1; c <= W; c++) {
    int32_t k = refCellIn(b, top, r, c);
    if (!(k > 0) || !(refCellIn(b, top, r + 1, c) < 0 || refCellIn(b, top, r - 1, c) < 0 || (c > 1 && refCellIn(b, top, r, c - 1) < 0) || (c < W && refCellIn(b, top, r, c + 1) < 0))) continue;
    // a column of three through it
    for (int r0 = r - 2; r0 <= r; r0++) {
      if (r0 < 1 || r0 + 2 > top) continue;
      int dv = 0, none[W + 2] = { 0 }, from, fr[3] = { 0 }, qs[3] = { 0 }, nq = 0;
      for (int q = r0; q <= r0 + 2 && dv < best; q++) { if (q == r) continue; int d = refBring(b, top, q, c, k, none, &from); if (d >= 0) { dv += d; qs[nq] = q; fr[nq++] = from; } else dv = 1 << 30; }
      if (dv < best) { best = dv; if (seq) { int n = 0; for (int i = 0; i < nq; i++) n = walkTo(qs[i], fr[i], c, seq, n); *nseq = n; } }
    }
    // a row of three through it
    for (int c0 = c - 2; c0 <= c; c0++) {
      if (c0 < 1 || c0 + 2 > W) continue;
      int used[W + 2] = { 0 }, dh = 0, from, fr[3] = { 0 }, ts[3] = { 0 }, nt = 0;
      used[c] = 1;
      for (int t = c0; t <= c0 + 2 && dh < best; t++) { if (t == c) continue; int d = refBring(b, top, r, t, k, used, &from); if (d >= 0) { used[from] = 1; dh += d; ts[nt] = t; fr[nt++] = from; } else dh = 1 << 30; }
      if (dh < best) { best = dh; if (seq) { int n = 0; for (int i = 0; i < nt; i++) n = walkTo(r, fr[i], ts[i], seq, n); *nseq = n; } }
    }
  }
  return best;
}
static int refBreakNear(const Board *b) { return refBreakNearLine(b, 0, 0); }
static int refNearOf(const Board *b) { return imin(refBreakNear(b), NEAR_MISS); }
static int refBreakBuildable(const Board *b) { return refBreakNear(b) < NEAR_MISS; }
static int refGarbageOn(const Board *b) { return refLowestG(b) < gridLen(b); }
// the panels on the board, garbage not counted -- the material every break is made from
static int32_t refPanelsOn(const Board *b) { int32_t n = 0, R = gridLen(b); for (int r = 1; r < R; r++) for (int c = 1; c <= W; c++) if (cellAt(b, r, c) > 0) n++; return n; }
