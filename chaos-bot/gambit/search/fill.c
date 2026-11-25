// THE PANEL A MATCH IS ONE SHORT OF (fillWalks): from the board a line plays from and the board it lands on, the cells where one more
// panel of a colour makes a match of a panel that moves -- a pair made three, a three made four -- and the walk along its row that brings
// that panel there on the board it plays from. One question, asked two ways by the proposers (propose.c):
//   - A THREE GROWN (growLines): the land is the board the line's last swap makes, each panel it lets go dropped to rest; the panels that
//     moved are the ones the swap and the drop put somewhere new. Its match of three made four.
//   - THE CONVERTED ROW (convertLines): the land is the board the engine settles to, the line played or the board left alone; the panels
//     that moved are the ones it puts somewhere new -- the row a break converts as it falls, and what falls with it. Converted panels
//     fall chaining (pa.c updateMatched), so the match they make is a link of a chain.
// Only colours the board shows are used: an unseen colour (pa.c UNSEEN_COLOUR, 30..219) is no colour, so a panel not drawn yet is never
// planned on. What a walk proposes is a candidate like any other: the engine judges whether the match is made.

#define FILLMAX 8
typedef struct {
  int32_t top, d;                          // the land's rows (1..top); its row r is row r - d of the board played from
  int32_t c[MAXROWS + 2][W + 2];           // each cell's colour (gridCell: 0 empty, < 0 garbage)
  uint8_t mv[MAXROWS + 2][W + 2];          // a panel the land put somewhere new
} Land;
typedef struct { int32_t n, len[FILLMAX], seq[FILLMAX][MAXPATH]; } Fills;

static int32_t landAt(const Land *L, int r, int c) { return r < 1 || r > L->top || c < 1 || c > W ? 0 : L->c[r][c]; }
// the run of colour k through (r, c) along (dr, dc): its length, and the cells just past each end
static int runOf(const Land *L, int r, int c, int dr, int dc, int32_t k, int *er0, int *ec0, int *er1, int *ec1) {
  int n = 1, r0 = r, c0 = c, r1 = r, c1 = c;
  while (landAt(L, r0 - dr, c0 - dc) == k) { r0 -= dr; c0 -= dc; n++; }
  while (landAt(L, r1 + dr, c1 + dc) == k) { r1 += dr; c1 += dc; n++; }
  *er0 = r0 - dr; *ec0 = c0 - dc; *er1 = r1 + dr; *ec1 = c1 + dc;
  return n;
}
// the walks: for each panel the land moved, of a colour the board shows, in a run of minRun or more, each end of its run along a row
// and a column where one more
// panel makes the match at least three; the panel brought along that row of the board played from (bring), over cells that
// hold it up, from none of the run's own cells. Nearest first; one walk a cell.
static void fillWalks(const Board *B, const Land *L, int minRun, Fills *F) {
  F->n = 0;
  static LOCAL Bits BB;
  bitsOf(B, &BB);
  int top = BB.top;
  static uint8_t done[MAXROWS + 2][W + 2];
  memset(done, 0, sizeof done);
  for (int r = 1; r <= L->top; r++) for (int c = 1; c <= W; c++) {
    int32_t k = L->c[r][c];
    if (!L->mv[r][c] || !seenColour(k)) continue;
    for (int dir = 0; dir < 2; dir++) {
      int dr = dir ? 1 : 0, dc = dir ? 0 : 1, e[2][2];
      int n = runOf(L, r, c, dr, dc, k, &e[0][0], &e[0][1], &e[1][0], &e[1][1]);
      if (n < minRun) continue;
      for (int s = 0; s < 2; s++) {
        int tr = e[s][0], tc = e[s][1];
        if (tr < 1 || tr > L->top || tc < 1 || tc > W || done[tr][tc] || L->mv[tr][tc] || L->c[tr][tc] < 0) continue;
        // (the run beyond the cell joins it: k _ k)
        int br = tr + (s ? dr : -dr), bc = tc + (s ? dc : -dc), beyond = 0;
        while (landAt(L, br, bc) == k) { beyond++; br += s ? dr : -dr; bc += s ? dc : -dc; }
        int made = n + 1 + beyond;
        if (made < 3) continue;
        int q = tr - L->d;
        if (q < 1 || q > top) continue;
        unsigned used = 0; int from = 0;
        if (dir == 0) for (int j = 1; j <= W; j++) if (landAt(L, tr, j) == k && j != tc) used |= 1u << j;
        int dist = bitsBring(&BB, q, tc, k, used, &from);
        if (dist <= 0 || F->n >= FILLMAX) continue;
        done[tr][tc] = 1;
        F->len[F->n] = walkTo(q, from, tc, F->seq[F->n], 0);
        if (F->len[F->n] > 0) F->n++;
      }
    }
  }
  // (nearest first)
  for (int i = 1; i < F->n; i++) for (int j = i; j > 0 && F->len[j] < F->len[j - 1]; j--) {
    int32_t t[MAXPATH], tl = F->len[j];
    for (int k = 0; k < tl; k++) t[k] = F->seq[j][k];
    F->len[j] = F->len[j - 1]; for (int k = 0; k < F->len[j]; k++) F->seq[j][k] = F->seq[j - 1][k];
    F->len[j - 1] = tl; for (int k = 0; k < tl; k++) F->seq[j - 1][k] = t[k];
  }
}

// THE LAND OF A SWAP: the board played from with the swap at (r, c) made and every panel it lets go dropped to rest in its column
// (garbage holds what sits on it); moved: a cell whose colour is not the board's
static void swapLand(const Board *B, int sr, int sc, Land *L) {
  L->top = gridLen(B) - 2; L->d = 0;
  for (int r = 1; r <= L->top; r++) for (int c = 1; c <= W; c++) { L->c[r][c] = cellAt(B, r, c); L->mv[r][c] = 0; }
  int32_t a = L->c[sr][sc], b = L->c[sr][sc + 1];
  if (a < 0 || b < 0) return;
  L->c[sr][sc] = b; L->c[sr][sc + 1] = a;
  for (int c = sc; c <= sc + 1; c++)
    for (int moved = 1; moved;) {
      moved = 0;
      for (int r = 2; r <= L->top; r++) if (L->c[r][c] > 0 && L->c[r - 1][c] == 0) { L->c[r - 1][c] = L->c[r][c]; L->c[r][c] = 0; moved = 1; }
    }
  for (int r = 1; r <= L->top; r++) for (int c = sc; c <= sc + 1; c++) L->mv[r][c] = L->c[r][c] != cellAt(B, r, c);
}
// THE LAND THE ENGINE SETTLES TO: E, the board B goes to; each panel found by its id, the rows E has risen by (d) read off a panel
// of B's bottom row; moved: a panel not where it was, less the rise
static int settledLand(const Board *B, const Board *E, Land *L) {
  L->top = gridLen(E) - 2; L->d = 0;
  int found = 0;
  for (int c = 1; c <= W && !found; c++) {
    int32_t id = B->p[1][c].f[ID];
    if (id == NUL) continue;
    for (int r = 1; r <= L->top && !found; r++) if (E->p[r][c].f[ID] == id) { L->d = r - 1; found = 1; }
  }
  for (int r = 1; r <= L->top; r++) for (int c = 1; c <= W; c++) {
    L->c[r][c] = cellAt(E, r, c);
    int q = r - L->d;
    int32_t id = E->p[r][c].f[ID];
    L->mv[r][c] = L->c[r][c] > 0 && !(q >= 1 && q < B->nrows && B->p[q][c].f[ID] == id && cellAt(B, q, c) == L->c[r][c]);
  }
  return found;
}
