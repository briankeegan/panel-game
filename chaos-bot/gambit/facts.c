// THE FACTS AND THE RULES: the facts read off both boards each decision, the rule they choose and its list, the floor a
// line's board keeps, how near a line comes to the list, and the pick's tier. The rules file is read by the host and handed over
// whole (gb_rules); its tests name facts by id (FACT_*).

// ---- the facts of a board. A fact the host does not know (the enemy's height, say) is unknown, and a test of it
// is false.
enum { FACT_US_TOPPED, FACT_US_STOP, FACT_US_HEIGHT, FACT_US_MATERIAL, FACT_US_CONTACT, FACT_US_DIES, FACT_US_EVENNESS, FACT_US_COMING,
       FACT_US_HEAVY, FACT_US_NEXTLANDS, FACT_US_BREAKWAITS, FACT_US_QUEUEKILLS, FACT_ENEMY_TOPPED, FACT_ENEMY_HEIGHT, FACT_ENEMY_STOP, FACT_ENEMY_NONE, NFACTS };
typedef struct { int32_t known[NFACTS]; double v[NFACTS]; } FactSet;   // (dies is fractional: the rise timer is)
#define US(F, k) ((F)->v[FACT_US_##k])
static void factSet(FactSet *F, int k, double v) { F->known[k] = 1; F->v[k] = v; }

static int32_t cellOfB(const Board *b, int r, int c) { const int32_t *f = b->p[r][c].f; return f[ISGARBAGE] ? -1 : (f[COLOR] == NUL ? 0 : f[COLOR]); }
// the highest row with a panel or landed garbage on it (garbage still falling is not part of the stack)
static int32_t fullTop(const Board *b) {
  int32_t top = 0;
  for (int r = 1; r < b->nrows; r++) for (int c = 1; c <= W; c++) {
    const int32_t *f = b->p[r][c].f;
    int falling = f[ISGARBAGE] && f[STATE] == FALLING;
    if ((f[COLOR] || f[ISGARBAGE]) && !falling && r > top) top = r;
  }
  return top;
}
// the highest row with a panel on it, garbage aside (the floor's raise counts its rows so: decide.c read)
static int32_t panelTop(const Board *b) {
  int32_t top = 0;
  for (int r = 1; r < b->nrows; r++) for (int c = 1; c <= W; c++) {
    const int32_t *f = b->p[r][c].f;
    if (f[COLOR] > 0 && !f[ISGARBAGE] && r > top) top = r;
  }
  return top;
}
// the frames until the stack rises to the top row
static double framesToTop(const Board *b) {
  int32_t h = b->height ? b->height : 12, rows = h - fullTop(b), stop = b->stopTime + b->preStopTime;
  if (rows <= 0) return stop;
  int32_t T = SPEED_TO_RISE_TIME[imin(99, imax(1, b->speed ? b->speed : 1)) - 1], disp = imax(1, b->displacement ? b->displacement : 16);
  // (T is a row's frames: the rise takes T / 16 a pixel, pa.c advancePassiveRaise -- the pixels left of this row, then whole rows)
  return stop + (b->riseTimer > 0 ? b->riseTimer : 0) + (disp - 1) * T / 16.0 + (rows - 1) * (double)T;
}
// THE GARBAGE A BREAK TAKES: the lowest block and every block touching it -- its top row and its cells on screen (top 0: none)
static void lowestGroupTop(const Board *b, int H, int32_t *top, int32_t *onScreen) {
  int32_t low = NUL, h = b->height ? b->height : H;
  static int32_t idAt[MAXROWS][W + 2];
  for (int r = 0; r < MAXROWS; r++) for (int c = 0; c < W + 2; c++) idAt[r][c] = NUL;
  for (int r = 1; r <= H && r < MAXROWS; r++) for (int c = 1; c <= W; c++) { const int32_t *f = b->p[r][c].f; if (f[ISGARBAGE]) { idAt[r][c] = f[GARBAGEID]; if (low == NUL) low = f[GARBAGEID]; } }
  *top = 0; *onScreen = 0;
  if (low == NUL) return;
  int32_t ids[256], nid = 0, todo[256], ntodo = 0;
  ids[nid++] = low; todo[ntodo++] = low;
  static const int DR[4] = { 1, -1, 0, 0 }, DC[4] = { 0, 0, 1, -1 };
  while (ntodo) {
    int32_t id = todo[--ntodo];
    for (int r = 1; r <= H && r < MAXROWS; r++) for (int c = 1; c <= W; c++) {
      if (idAt[r][c] != id) continue;
      if (r > *top) *top = r;
      if (r <= h) (*onScreen)++;
      for (int d = 0; d < 4; d++) {
        int rr = r + DR[d], cc = c + DC[d];
        if (rr < 0 || rr >= MAXROWS || cc < 1 || cc > W) continue;
        int32_t o = idAt[rr][cc], seen = 0;
        if (o == NUL) continue;
        for (int k = 0; k < nid; k++) if (ids[k] == o) seen = 1;
        if (!seen && nid < 256) { ids[nid++] = o; if (ntodo < 256) todo[ntodo++] = o; }
      }
    }
  }
}
// THE MATERIAL: the panels under the lowest garbage (search/bits.c bitsShape), the one reading the facts and a judged board share
static int32_t materialOn(const Board *b) { static LOCAL Bits MB; static LOCAL BoardShape MS; bitsOf(b, &MB); bitsShape(&MB, &MS); return MS.material; }
// THE FACTS OF OUR BOARD: the garbage on its way as the question gives it (arrivals), topped as the game says
static void factsOf(const Board *b, const Arr *arr, int narr, int topped, FactSet *F) {
  // (the board's shape, the one reading of it: search/bits.c bitsShape)
  static LOCAL Bits FB; static LOCAL BoardShape FS;
  bitsOf(b, &FB); bitsShape(&FB, &FS);
  int H = b->nrows - 1, top = FS.top, material = FS.material, contact = FS.contact, garb = FS.garbage, *peaks = FS.peak;
  int32_t stop = b->stopTime + b->preStopTime, coming = 0, next = NUL;
  for (int i = 0; i < narr; i++) { coming += arr[i].height; if (next == NUL || arr[i].at < next) next = arr[i].at; }
  // (a block queued for the board drops once the stop time runs out: its landing is the stop time left)
  if (b->ninc > 0) { coming += b->inc[0].height; if (next == NUL || stop < next) next = stop; }
  double dies = topped ? stop + b->health : framesToTop(b) + b->health;
  int breakWaits = 0;
  if (garb) {
    int32_t gtop, onScreen;
    lowestGroupTop(b, H, &gtop, &onScreen);
    int inAir = hasFallingGarbage((Board *)b);
    int32_t pop = gtop ? b->fFLASH + b->fFACE + b->fPOP * (3 + onScreen) : 0;
    breakWaits = gtop && gtop == top && top < (b->height ? b->height : H) && (inAir || (next != NUL && next <= pop));
  }
  int hi = peaks[1], lo = peaks[1];
  for (int c = 2; c <= W; c++) { if (peaks[c] > hi) hi = peaks[c]; if (peaks[c] < lo) lo = peaks[c]; }
  factSet(F, FACT_US_TOPPED, !!topped); factSet(F, FACT_US_STOP, stop); factSet(F, FACT_US_HEIGHT, top); factSet(F, FACT_US_MATERIAL, material);
  if (garb) factSet(F, FACT_US_CONTACT, contact); else F->known[FACT_US_CONTACT] = 0;
  factSet(F, FACT_US_DIES, dies); factSet(F, FACT_US_EVENNESS, hi - lo); factSet(F, FACT_US_COMING, coming); factSet(F, FACT_US_HEAVY, coming > 8);
  if (next != NUL) factSet(F, FACT_US_NEXTLANDS, next); else F->known[FACT_US_NEXTLANDS] = 0;
  factSet(F, FACT_US_BREAKWAITS, breakWaits); factSet(F, FACT_US_QUEUEKILLS, 0);
}

// ---- THE RULES (the rules file): a rule's `when` (tests of facts), its list (aims, ended by "default" or
// "hold"), its deadline (`by`: frames or a fact), its floor (`keep`: tests of the end board's facts) and the raise
#define MAXRULES 32
#define MAXWHEN 8
enum { KEEP_HEIGHT, KEEP_MATERIAL, KEEP_EVENNESS, NKEEP };
typedef struct { int32_t fact; Test t; } When;
typedef struct { int32_t on; Test t[NKEEP]; } Keep;   // on: a floor at all (a test op of 0: not asked)
typedef struct {
  int32_t table;            // 0 defend, 1 attack
  int32_t nwhen; When when[MAXWHEN];
  List list; int32_t end;   // end: 0 none, 1 "default", 2 "hold"
  int32_t byFact, byFrames; // byFact >= 0: the deadline is that fact; else byFrames (-1: none)
  Keep keep; int32_t raiseTo;
  int32_t name;             // the host's index of its name
} Rule;
// (a rule for nobody across -- its `when` asks enemy.none: time attack -- is no mode a match against someone switches into)
static int asksNoEnemy(const Rule *r) { for (int i = 0; i < r->nwhen; i++) if (r->when[i].fact == FACT_ENEMY_NONE) return 1; return 0; }
typedef struct { int32_t n; Rule r[MAXRULES]; Keep keep; int32_t raiseTo, underIgnore; } Tables;
static Tables theTables;

static int holds(const FactSet *F, const Rule *r) {
  for (int i = 0; i < r->nwhen; i++) { int k = r->when[i].fact; if (k < 0 || k >= NFACTS || !F->known[k] || !test(F->v[k], r->when[i].t)) return 0; }
  return 1;
}
// The rule that applies: the first defend rule whose `when` holds, else the first attack rule (choose); or one by its name, whatever its
// `when` (named: the profile's mode, played the whole game). -1 for none.
static int chooseRule(const FactSet *F) {
  for (int t = 0; t < 2; t++) for (int i = 0; i < theTables.n; i++) if (theTables.r[i].table == t && holds(F, &theTables.r[i])) return i;
  return -1;
}
static int namedRule(int32_t name) { for (int t = 0; t < 3; t++) for (int i = 0; i < theTables.n; i++) if (theTables.r[i].table == t && theTables.r[i].name == name) return i; return -1; }
// A deadline: frames, or a fact; an unknown one is no deadline (NOT_ASKED)
static int32_t deadlineOf(const FactSet *F, const Rule *r) {
  if (r->byFact >= 0) return r->byFact < NFACTS && F->known[r->byFact] ? F->v[r->byFact] : NOT_ASKED;
  return r->byFrames >= 0 ? r->byFrames : NOT_ASKED;
}

// ---- THE FLOOR (keeps, gridFacts): a line's board keeps it -- unless the line breaks garbage; its height, material and evenness the
// board's shape (search/bits.c bitsShape), as the facts read them
static void endFacts(const Board *b, int32_t *height, int32_t *material, int32_t *evenness) {
  static LOCAL Bits EB; static LOCAL BoardShape ES;   // (each thread's: every search asks the floor)
  bitsOf(b, &EB); bitsShape(&EB, &ES);
  *height = ES.top; *material = ES.material; *evenness = ES.even;
}
static int keepsFloor(const Keep *k, const Board *b, int32_t broke) {
  if (!k || !k->on) return 1;
  if (broke > 0) return 1;
  int32_t f[NKEEP];
  endFacts(b, &f[KEEP_HEIGHT], &f[KEEP_MATERIAL], &f[KEEP_EVENNESS]);
  for (int i = 0; i < NKEEP; i++) if (k->t[i].op && !test(f[i], k->t[i])) return 0;
  return 1;
}

// ---- HOW NEAR a line comes to an aim, 0..1: a chain is measured from one link, a combo from three panels
static double nearKey(int32_t v, Test t, int32_t from) {
  if (!t.near) return test(v, t) ? 1 : 0;
  int32_t n = t.n + (t.op == OP_GT ? 1 : 0);
  if (t.op == OP_LT || t.op == OP_LE) return test(v, t) ? 1 : 0;
  if (n <= from) return v == n || (t.op != OP_EQ && v > n) ? 1 : 0;
  double up = (double)(v - from) / (double)(n - from);
  if (up < 0) up = 0; if (up > 1) up = 1;
  if (t.op == OP_EQ && v > n) { double d = 1 - (double)(v - n) / (double)(n - from + 1); return d > 0 ? d : 0; }
  return up;
}
static double nearAim(const Aim *a, Made m) {
  if (meets(a, m)) return 1;
  if (a->brk == 1 && !(m.broke > 0)) return 0;
  if (a->brk == 0 && m.broke > 0) return 0;
  if (a->combo.op && !a->chain.op && m.chain > 1) return 0;
  double s = 0; int ks = 0;
  if (a->chain.op) { s += nearKey(m.chain, a->chain, 1); ks++; }
  if (a->combo.op) { s += nearKey(m.combo, a->combo, 3); ks++; }
  return ks ? s / ks : 0;
}
// How near a line comes to a priority list: the first entry first, a later one only between lines as near the ones before it
static double nearList(const List *L, Made m) {
  double s = 0, w = 1;
  for (int i = 0; i < L->n; i++) { double nv = nearAim(&L->aim[i], m) * 100; s += (double)(int64_t)(nv + 0.5) * w; w /= 101; }   // (Math.round of 0..100)
  return s;
}
// What leads the search: the list, and any line that breaks a little nearer than one that does not
static double leadOf(const List *L, Made m, int under) { return nearList(L, m) + (under && m.broke > 0 ? 0.5 : 0); }

// ---- THE PICK'S TIERS, lower first, and the order within one
#define MAXSUB 9
// (nlist: the leading sub-keys that are the list's order -- what a line spends is weighed after them, never before: rank.c)
typedef struct { int32_t tier, nsub, nlist; double sub[MAXSUB]; } Tier;
enum { PLAY_ENTRY, PLAY_NEAREST, PLAY_BREAKLINE, PLAY_CARRY, PLAY_CARRYWAIT, PLAY_CLEAR, PLAY_EXTEND, PLAY_LINEUP, PLAY_BREAKSEARCH,
       PLAY_LINEUPBREAK, PLAY_TOWARD, PLAY_READY, PLAY_LEVEL, PLAY_SETUP, PLAY_SURVIVE, PLAY_CONVERT, PLAY_HOLD, PLAY_ZIP, PLAY_CUT, NPLAYS };
static const char *PLAY_NAME[NPLAYS] = { "entry", "nearest", "break line", "carry", "carry wait", "clear", "extend", "lineup", "break search",
                                         "lineup break", "toward", "ready", "level", "setup", "survive", "convert", "hold", "zip", "cut" };
// the plays judged settle by settle; the set-ups (SETUPS)
static int settledPlay(int p) { return p == PLAY_ENTRY || p == PLAY_NEAREST || p == PLAY_BREAKLINE || p == PLAY_CARRY || p == PLAY_CARRYWAIT || p == PLAY_CLEAR; }
static int setupPlay(int p) { return p == PLAY_SETUP || p == PLAY_LEVEL || p == PLAY_READY || p == PLAY_TOWARD || p == PLAY_ZIP; }
typedef struct { int32_t combo, chain, broke, cells, earned, done, near100, dropAt, floor; double near; } Xs;   // floor: -1 not said, 0, 1
static Tier tierOf(int play, const Xs *x, int aim, int under, int enemyOut, int topped, int waits) {
  Tier t; memset(&t, 0, sizeof t);
  int32_t combo = x->combo, chain = x->chain, broke = x->broke, cells = x->cells, stop = x->earned;
  int clears = combo >= 3 || chain >= 2 || broke > 0 || cells > 0 || play == PLAY_CLEAR, buys = combo >= 4 || chain >= 2;
  double rate = (double)broke / (double)imax(1, x->done ? x->done : 1);
  #define SUB(...) do { double s_[] = { __VA_ARGS__ }; t.nsub = (int)(sizeof s_ / sizeof s_[0]); for (int q_ = 0; q_ < t.nsub; q_++) t.sub[q_] = s_[q_]; } while (0)
  if (under && waits) {
    if (aim >= 0 && !(broke > 0)) { t.tier = 2; SUB(aim, x->done); t.nlist = 1; return t; }
    if (broke > 0) { t.tier = 6; SUB(-1e300, x->floor == 0 ? 1 : 0, aim >= 0 ? aim : 99, -rate, buys ? 0 : 1, -broke); t.nlist = 3; return t; }
  }
  if (broke > 0) { t.tier = 1; SUB(x->floor == 0 ? 1 : 0, aim >= 0 ? aim : 99, -x->dropAt, -rate, buys ? 0 : 1, -broke); t.nlist = 2; return t; }
  if (play == PLAY_CLEAR) { t.tier = 6; SUB(-stop); return t; }
  if (aim >= 0 && !under) { t.tier = 2; SUB(aim, -x->dropAt, x->done); t.nlist = 1; return t; }
  if (clears && (buys || cells > 0) && (!under || (topped && buys))) { t.tier = 3; SUB(-cells, enemyOut ? -combo : -chain, enemyOut ? -chain : -combo, -stop, -x->near); return t; }
  if (!clears) { t.tier = 4; SUB(play == PLAY_READY ? 0 : play == PLAY_TOWARD ? 1 : play == PLAY_SETUP ? 2 : play == PLAY_LEVEL ? 4 : 3); return t; }   // (levelling last)
  t.tier = 6; SUB(-stop);
  return t;
  #undef SUB
}
