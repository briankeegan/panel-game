// THE RULES: the mode's list -- what a line may make -- read once a decision and handed to every search. A list is its
// entries in priority order; an entry (an aim) tests what a line makes: { combo, chain, send, break }.
//
// What a line makes ({ combo: the largest match, chain: links, broke: garbage cells converted, cells: garbage sent }) is counted by
// the judge (judge.c). A clear is a chain of one link: a match made with no chain running is chain 1 (chainOf).

// THE LONGEST CHAIN EVER: no move in any mode makes a chain longer, whoever chose it (GAMBIT.MAXCHAIN)
#define MAXCHAIN 13
#define MAXAIMS 16

// One test of a number: an operator and its operand ("<=3"); OP_NONE where the aim does not ask it.
enum { OP_NONE, OP_GE, OP_LE, OP_EQ, OP_NE, OP_GT, OP_LT, OP_FILL };   // OP_FILL: a chain the enemy's room asks (decide.c fillList)
// near: written as a string near() reads (">=8", not a plain number or a negative)
typedef struct { int32_t op, n, near; } Test;
// brk: -1 not asked, 0 a line that breaks nothing, 1 a line that breaks
typedef struct { Test combo, chain, send; int32_t brk; } Aim;
typedef struct { Aim aim[MAXAIMS]; int32_t n; } List;
typedef struct { int32_t combo, chain, broke, cells; } Made;

static int test(double v, Test t) {
  switch (t.op) {
    case OP_GE: return v >= t.n;
    case OP_LE: return v <= t.n;
    case OP_EQ: return v == t.n;
    case OP_NE: return v != t.n;
    case OP_GT: return v > t.n;
    case OP_LT: return v < t.n;
  }
  return 1;
}
static int32_t chainOf(Made m) { return imax(m.chain, m.combo > 0 ? 1 : 0); }
// What a line makes against an aim. An aim that names a combo and no chain is a combo of one clear: a chain whose largest match is
// that size does not meet it.
static int meets(const Aim *a, Made m) {
  m.chain = chainOf(m);
  if (a->combo.op && !a->chain.op && m.chain > 1) return 0;
  if (a->combo.op && !test(m.combo, a->combo)) return 0;
  if (a->chain.op && !test(m.chain, a->chain)) return 0;
  if (a->send.op && !test(m.cells, a->send)) return 0;
  if (a->brk == 1 && !(m.broke > 0)) return 0;
  if (a->brk == 0 && m.broke > 0) return 0;
  return 1;
}
// WHAT A MOVE MAY MAKE: it clears nothing, or its clears match an entry of the list (its break aside), or it is a plain three that
// breaks garbage (garbage can always be broken with a three); never a chain past MAXCHAIN.
static int fits(const List *L, Made m) {
  if (m.chain > MAXCHAIN) return 0;
  if (m.combo == 0 && m.chain == 0) return 1;
  if (m.combo <= 3 && m.chain <= 1 && m.broke > 0) return 1;
  for (int i = 0; i < L->n; i++) { Aim plain = L->aim[i]; plain.brk = -1; if (meets(&plain, m)) return 1; }
  return 0;
}
// THE ONE RULE'S THREE (judge.c breakingThree): after whatever entries a list has, under garbage, a three that breaks it -- the searches
// look for it in every mode, and the order puts it after every entry
// A LONG CHAIN UNDER GARBAGE (decide.c read): the searches are led toward a chain of five at most -- a chain the list asks longer is one
// no buried board makes, and leading toward it leads toward none of the clears that dig (each link that touches the garbage breaks it
// again); a combo is led toward as the list asks it (the owner: eight and up is eight and up); the list itself, what fits and what
// meets, stays the mode's
static void guideShort(List *L) {
  for (int i = 0; i < L->n; i++) {
    Test *t = &L->aim[i].chain; if (t->op && t->n + (t->op == OP_GT) > 5 && (t->op == OP_GE || t->op == OP_GT || t->op == OP_EQ)) { t->op = OP_GE; t->n = 5; }
  }
}
static void withRule(List *L) {
  Aim t; memset(&t, 0, sizeof t);
  t.combo.op = OP_LE; t.combo.n = 3; t.chain.op = OP_EQ; t.chain.n = 1; t.brk = 1;
  for (int i = 0; i < L->n; i++) if (!memcmp(&L->aim[i], &t, sizeof t)) return;
  if (L->n < MAXAIMS) L->aim[L->n++] = t;
}
// THE ATTACKS UNDER GARBAGE (decide.c read): after the three that breaks, the mode's own entries again, a break not asked -- an attack
// that leaves the garbage where it is meets the list there, after every break, so a board that lives throws it rather than holding.
// The entries that throw nothing (a three) are not repeated. from: the mode's list as written.
static void withAttacks(List *L, const List *from) {
  for (int i = 0; i < from->n && L->n < MAXAIMS; i++) {
    Aim a = from->aim[i];
    if (a.chain.op == OP_EQ && a.chain.n == 1 && a.combo.op == OP_LE && a.combo.n <= 3) continue;
    a.brk = -1;
    L->aim[L->n++] = a;
  }
}
// A MOVE'S PLACE IN THE LIST: the first entry it meets, its break as the entry asks it (under garbage every entry asks one), as the
// searches ask it (meets); -1 for one that clears nothing or meets none. The rank's one question of the list's order.
static int metOf(const List *L, Made m) {
  if (!(m.combo > 0 || m.chain > 0)) return -1;
  for (int i = 0; i < L->n; i++) if (meets(&L->aim[i], m)) return i;
  return -1;
}
// THE LIST FOR ONE STEP ON THE ENGINE (JUDGE.stepFits): each of its own clears fits as a clear of its own, and the chain it reaches
// fits and is within MAXCHAIN. sizes: the step's clears that are no link of a chain.
static int stepFits(const List *L, const int32_t *sizes, int32_t nsizes, int32_t chain) {
  if (chain > MAXCHAIN) return 0;
  if (chain >= 2) { Made c = { 0, chain, 0, 0 }; if (!fits(L, c)) return 0; }
  for (int i = 0; i < nsizes; i++) { Made s = { sizes[i], 1, 0, 0 }; if (!fits(L, s)) return 0; }
  return 1;
}

// THE GARBAGE A CLEAR SENDS: the cells of its combo garbage (the server's combo garbage table, a row per piece), and a slab the width
// of the board for every link past the first.
static int32_t comboCells(int32_t size) {
  static const int32_t CELLS[16] = { 0, 0, 0, 0, 3, 4, 5, 6, 7, 8, 10, 11, 12, 18, 24, 24 };
  if (size < 16) return CELLS[size];
  return size < 20 ? 24 : size < 27 ? 36 : 48;
}
// THE BLOCKS A LINE THROWS: its combo's pieces of combo garbage (the same table, a piece a row) and a slab for every link past the first
static int32_t blocksOf(int32_t combo, int32_t chain) {
  int32_t pieces = combo < 4 ? 0 : combo < 8 ? 1 : combo < 13 ? 2 : combo < 14 ? 3 : combo < 20 ? 4 : combo < 27 ? 6 : 8;
  return pieces + (chain > 1 ? chain - 1 : 0);
}

// THE LIST FROM THE HOST: n entries, each ten words -- combo, chain and send (each op, n, near) and break -- in the io body (the loader
// writes them from the rules file).
static List theList;
// (the longest chain the mode's list asks: 0 where it asks none)
static int32_t listChainCap(void) {
  int32_t cap = 0;
  for (int i = 0; i < theList.n; i++) { const Test *t = &theList.aim[i].chain; int32_t c = t->op == OP_GE || t->op == OP_EQ || t->op == OP_LE ? t->n : t->op == OP_GT ? t->n + 1 : 0; if (c > cap) cap = c; }
  return cap;
}
// THE BOARD'S OWN CHAIN, KEPT AS THE MODE ASKS (the owner: modes are respected -- a chain going is not kept for its own sake): a chain
// the board makes on its own, n links, is the mode's attack only where the list asks a chain that long or longer -- past the longest it
// asks, or where it asks none (the finish: combos, the pieces that land soonest), cutting it is no waste
static int ownChainAsked(int32_t n) { return n >= 2 && n <= listChainCap(); }
EXPORT(gb_list) int gb_list(int n) {
  if (n < 0 || n > MAXAIMS) return -1;
  const int32_t *w = gbIo;
  for (int i = 0; i < n; i++, w += 10) {
    Aim a = { { w[0], w[1], w[2] }, { w[3], w[4], w[5] }, { w[6], w[7], w[8] }, w[9] };
    theList.aim[i] = a;
  }
  theList.n = n;
  return n;
}
// (for a host's check: what fits and meets say of a made line)
EXPORT(gb_fits) int gb_fits(int combo, int chain, int broke, int cells) { Made m = { combo, chain, broke, cells }; return fits(&theList, m); }
EXPORT(gb_entry_of) int gb_entry_of(int combo, int chain, int broke, int cells) { Made m = { combo, chain, broke, cells }; return metOf(&theList, m); }
EXPORT(gb_meets) int gb_meets(int i, int combo, int chain, int broke, int cells) { Made m = { combo, chain, broke, cells }; return i >= 0 && i < theList.n && meets(&theList.aim[i], m); }

// A SWAP BACK: the same two panels the last swap swapped, which puts the board back as it was -- no play,
// unless the line clears or breaks on this board; and even then not after the same pair twice running; and never a pair blocked
// until a frame. What the last decisions swapped is the host's (gb_back), the panels' ids on the board the decision is made on.
typedef struct { int32_t lastA, lastB, runs, blockA, blockB, blockUntil, at; } Back;
static Back theBack;   // ids 0: none
static const Board *backBoard;
static int samePair(int32_t a, int32_t b, int32_t x, int32_t y) { return (a == x && b == y) || (a == y && b == x); }
// clears: 0 nothing, 1 a clear, 2 a break -- a swap that breaks garbage is the board's defence, never refused as a swap back
// (and a pair the press guard refused as a wasted three, kept out until a frame whatever the line makes: front.c wastedSwap)
static int32_t refusedA, refusedB;
EXPORT(gb_refused) void gb_refused(int a, int b) { refusedA = a; refusedB = b; }
static int swapBack(int r, int c, int clears) {
  if (!backBoard || r < 0 || r >= backBoard->nrows || c < 1 || c + 1 > W) return 0;
  int32_t a = backBoard->p[r][c].f[ID], b = backBoard->p[r][c + 1].f[ID];
  if (a == NUL || b == NUL) return 0;
  if (refusedA && samePair(a, b, refusedA, refusedB)) return 1;
  if (clears == 2) return 0;
  if (theBack.blockA && samePair(a, b, theBack.blockA, theBack.blockB) && theBack.at < theBack.blockUntil) return 1;
  return theBack.lastA && samePair(a, b, theBack.lastA, theBack.lastB) && (!clears || theBack.runs >= 2);
}
// (the swap back, whatever the line makes: the pair the last swap pressed swapped -- rank.c 1'u)
static int swappedBack(int r, int c) {
  if (!backBoard || r < 0 || r >= backBoard->nrows || c < 1 || c + 1 > W || !theBack.lastA) return 0;
  int32_t a = backBoard->p[r][c].f[ID], b = backBoard->p[r][c + 1].f[ID];
  return a != NUL && b != NUL && samePair(a, b, theBack.lastA, theBack.lastB);
}
// a line's first swap: not the swap back the judge refuses
static int firstOk(int r, int c, int clears) { return !swapBack(r, c, clears); }
// (THE SWAP PRESSED LAST, the host's: a line hands on several swaps and the frame loop presses them all, so the pair the next decision
// must not swap back is the last one pressed, not the last decision's first)
EXPORT(gb_pressed) void gb_pressed(int a, int b) {
  if (a && b && a != NUL && b != NUL && !samePair(a, b, theBack.lastA, theBack.lastB)) { theBack.lastA = a; theBack.lastB = b; theBack.runs = 0; }
}
EXPORT(gb_back) void gb_back(int lastA, int lastB, int runs, int blockA, int blockB, int blockUntil, int at) {
  Back k = { lastA, lastB, runs, blockA, blockB, blockUntil, at };
  theBack = k;
}
