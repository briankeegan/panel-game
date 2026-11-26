// THE OUTCOME OF A LINE (plans/decision.md step 3): the whole line judged once a decision, and every fact the
// decision reads about it taken from that one judging -- no search, filter or rank works one out for itself. And THE SHARED LINE CHECK
// (lineFits): the line every search keeps only when the ranking would take it. Both cached per decision (gb_decision_start).
//
// What the decision knows of the board (Facts) comes from its reading of it.

static double leftMsOf(void);   // (propose.c leftMs: the time the decision's searches have left)
// A BREAK'S TIME AT THIS LEVEL (levelBreak, set each question as rank.c rankSave is: a reaction, then a three popping a row of garbage
// -- flash, face and the pops, read off the board, so every level is its own): the frames below were measured at level 11, where it is
// LEVEL11_BREAK (reaction 12), and scale with it
static int32_t levelBreak = 97;
#define LEVEL11_BREAK 97
#define AT_LEVEL(f) ((int32_t)((int64_t)(f) * levelBreak / LEVEL11_BREAK))
#define HORIZON AT_LEVEL(240)   // a board stands when it is alive this long after now
#define REST AT_LEVEL(120)      // and this long after the line's last swap

typedef struct {
  int32_t land;        // frames until the last block shown lands (NOT_ASKED: none coming) -- JUDGE.lastLanding
  int32_t topped;      // the board is topped out
  int32_t timeLeft;    // the decision's searches still have time (c.left() > 0): readiness is asked only then
  int32_t belowFloor;  // below the rule's material floor: a line that clears panels and breaks nothing is no candidate
  int32_t under;       // garbage on the board, as the decision reads it (decide.c read: R->under) -- the one under-garbage test
  int32_t next;        // frames until the next block shown lands (NOT_ASKED: none coming)
} Facts;
typedef struct {
  int32_t dead, lostAt, lives, fits, ready, late;
  int32_t spent;   // under the material floor (outcomeOf)
  int32_t nextBuild; // a line that breaks: the board it leaves has a break to build, or no garbage left (outcomeOf); -1 not asked
  int32_t panelsLeft; // the panels on the board the line leaves (outcomeOf); -1 not asked
  int32_t lifeLeft;    // the life the board it leaves has by its panels (lifeOf), -1 not asked
  int32_t floorKept;   // the board the line leaves keeps the rule's floor, as the floor is tested (floorOf), the line's breaks aside; -1 not asked
  int32_t matLeft;     // the material the board the line leaves has: its panels under the lowest garbage, the next break's (materialOn); -1 not asked
  int32_t matSettled;  // the same once the board has settled -- its chain landed (settleOf); -1 not asked
  int32_t groups;      // the threes the board the line leaves has the panels for, a chain's links (groupsOn); -1 not asked
  int32_t twinAfter;   // the swaps to a two-column eight on the board the line leaves (propose.c twinCostOn; 99 none), -1 not asked
  int32_t nearAfter;   // under garbage: how near the next break is on the board the line leaves (search/break.c nearOf: its swaps, NEAR_MISS and over none to walk to), -1 not asked
  int32_t putOff;      // the frames the line puts the queue's drop off, beyond the board left alone (holdQueueAt): taken out of lostAt
  Judged j;
} Outcome;

// WHETHER WHAT A LINE MAKES FITS THE LIST: what it makes, the chain it reaches as the game counts it, and
// every clear of its own
static int fitsWithin(const List *L, Made m, const Judged *j);
// (the rule, judge.c: within the list -- an entry, a chain begun toward one, a three that breaks -- and with `last`, a last resort too)
static int fitsList(const List *L, Made m, const Judged *j, int last) {
  return breakingThree(m, j->chainAll) || fitsWithin(L, m, j) || (last && lastResort(m, j->chainAll));
}
static int fitsWithin(const List *L, Made m, const Judged *j) {
  // (a chain shorter than the list asks is begun toward it (judge.c chainBegins): within the list, its own clears held to it as ever;
  // ranked after every line that meets an entry, as it meets none)
  int32_t chain = imax(chainOf(m), j->chainAll);
  int begun = j->chainOpen && chainBegins(L, chain);
  if (!begun && !fits(L, m)) return 0;
  if (!begun && j->chainAll >= 2) { Made c = { 0, j->chainAll, 0, 0 }; if (!fits(L, c)) return 0; }
  for (int i = 0; i < j->nsingles; i++) { Made s = { j->singles[i], 1, 0, 0 }; if (!fits(L, s)) return 0; }
  return 1;
}

// ---- the decision's cache: every line judged once
#define CACHEN 4096
typedef struct { uint32_t h; int32_t settled, n, kind; int32_t seq[MAXLINE]; Outcome o; } Cached;
static LOCAL Cached *cache; static LOCAL int32_t ncache;   // (each thread its own: the break search judges on a worker -- answer.c)
static Question decQ; static Facts decF;
static int32_t cdAsk;   // (the question is the countdown's: the board still, the decision's time the countdown's -- native.c, from the question's noRaise)
static uint32_t lineHash(const int32_t *seq, int n, int settled, int kind) {
  uint32_t h = 2166136261u ^ (uint32_t)(settled * 7 + kind * 131);
  for (int i = 0; i < n; i++) h = (h ^ (uint32_t)seq[i]) * 16777619u;
  return h;
}
static int readyFresh;   // (the readiness asked now: an outcome kept without it is judged again, and replaced)
static int endWanted;    // (lineEnd: the line is judged again and the board it ends on kept)
static int endNoKeep;    // (and that judging not kept in the cache: asked once the rank has the line's whole outcome -- rank.c ideasOf)
static Outcome *cached(const int32_t *seq, int n, int settled, int kind) {
  if ((readyFresh && kind == 0) || endWanted) return 0;
  uint32_t h = lineHash(seq, n, settled, kind);
  for (int i = 0; i < ncache; i++) {
    Cached *c = &cache[i];
    if (c->h != h || c->n != n || c->settled != settled || c->kind != kind) continue;
    int same = 1;
    for (int k = 0; k < n && same; k++) same = c->seq[k] == seq[k];
    if (same) return &c->o;
  }
  return 0;
}
static Outcome *keep(const int32_t *seq, int n, int settled, int kind, const Outcome *o) {
  if (!cache) cache = (Cached *)grab(sizeof(Cached) * CACHEN);
  if (!cache || n > MAXLINE) return 0;
  uint32_t h = lineHash(seq, n, settled, kind);
  Cached *c = 0;
  for (int i = 0; i < ncache && !c; i++) {
    Cached *e = &cache[i];
    if (e->h != h || e->n != n || e->settled != settled || e->kind != kind) continue;
    int same = 1;
    for (int k = 0; k < n && same; k++) same = e->seq[k] == seq[k];
    if (same) c = e;
  }
  if (!c) { if (ncache >= CACHEN) return 0; c = &cache[ncache++]; }
  c->h = lineHash(seq, n, settled, kind); c->n = n; c->settled = settled; c->kind = kind;
  for (int k = 0; k < n; k++) c->seq[k] = seq[k];
  c->o = *o;
  return &c->o;
}

// THE LIFE A BOARD HAS WITH `panels` ON IT, in frames (core/material.h: measured on Gambit's own games, made by material.c: ./build.sh material)
#include "core/material.h"
static int32_t lifeOf(int32_t panels) { return LIFE[panels < 0 ? 0 : panels > LIFEMAX ? LIFEMAX : panels]; }
// the panels a board lives longest with (the table's peak): more than that, a panel cleared is life
static int32_t lifePeakOf(void) { static int32_t peak = -1; if (peak < 0) { peak = 0; for (int p = 1; p <= LIFEMAX; p++) if (LIFE[p] > LIFE[peak]) peak = p; } return peak; }
// THE OUTCOME. With garbage on its way, a line that breaks nothing lives only when a break is there once everything has landed --
// ready, however long the stop it stands on lasts; a break, or a board with nothing coming, lives by standing to the horizon and past
// the stop and shake it ends on (lifeStop), or by a break in reach once it is over: a board a stop holds up is ready for the next break
// or it dies when the stop runs out. A line that lives only by being ready lives as its readiness break does, played where the
// readiness found it and judged as any break is (waitTo): a break kept for later is worth no more than the break played.
static Outcome outcomeOf(const int32_t *seq, int n, int settled, int waitAt, int32_t waitTo);
static int breakBuildable(const Board *b);   // (search/break.c: a break the panels touching garbage can be walked into)
static int garbageOn(const Board *b);        // (search/break.c: garbage on the board)
static int32_t panelsOn(const Board *b);     // (search/break.c: the panels on the board)
static int nearOf(const Board *b);           // (search/break.c: the swaps to the nearest break; NEAR_MISS and over, how short of one)
static int32_t perchOf(const Board *b, int *can);   // (search/break.c: how far the garbage is from coming down a row, and whether it can)
static int twinCostOn(Board *b);              // (propose.c: the swaps to a two-column eight, 99 none)
static int32_t twinWanted;                    // (some mode of the rules asks a combo of eight or more: decide.c read)
// (THE BOARD LEFT ALONE, settled as a line is: whether it still has a break to build -- or no garbage to break. Asked once a decision:
// what a line is measured against when it spends the next break's material)
static int32_t rootBuildable = NOT_ASKED;
static int32_t aloneBuildable(void) {
  if (rootBuildable != NOT_ASKED) return rootBuildable;
  JudgeOpts jo = { 0, decQ.tight, NOT_ASKED, 0, 0, -1, 0, 0, 0, 0, 0 };
  Judged a;
  judge(&decQ, 0, 0, &jo, &a);
  const Board *eb = a.dead || a.late ? 0 : ensureBoard(judgeCtx, a.endNode);
  if (!eb) return 0;   // (no answer: nothing measured, nothing spent -- asked again)
  return rootBuildable = !garbageOn(eb) || breakBuildable(eb);
}
// (THE BOARD LEFT ALONE: the frame the engine drops the next block of a queue held off by the board's own motion (judge.c queueWaits),
// NOT_ASKED none held or none dropped within the judge's horizon. Asked once a decision)
#define QUEUE_UNSET (NOT_ASKED - 1)
static int32_t rootQueueAt = QUEUE_UNSET;
static int32_t holdQueueAt(void) {
  if (rootQueueAt == QUEUE_UNSET) rootQueueAt = queueWaits(decQ.b) ? queueDropIn(decQ.b, HORIZON + REST) : NOT_ASKED;
  return rootQueueAt;
}
static Board *endBoard;                      // (lineEnd's board)
static int (*floorOf)(const Board *b);       // (the decision's floor test, decide.c read: 1 kept, 0 not, -1 no floor)
static int32_t materialOn(const Board *b);   // (facts.c: the panels under the lowest garbage, as the facts read the material)
// (THE THREES A BOARD HAS THE PANELS FOR: each colour's panels a three at a time, the row rising under it with them; garbage turned
// to panels before its pop, its colour not shown yet, is any colour, three of them a three; a row not dealt yet is not counted)
static int32_t groupsOn(const Board *b) {
  int32_t n[16] = { 0 }, any = 0;
  for (int r = 0; r < b->nrows; r++) for (int c = 1; c <= W; c++) {
    const int32_t *f = b->p[r][c].f;
    if (f[ISGARBAGE] || f[ID] <= 0 || f[COLOR] <= 0) continue;
    if (f[COLOR] >= 130) any++; else if (f[COLOR] < 8) n[f[COLOR]]++;
  }
  int32_t g = any / 3; for (int k = 1; k < 8; k++) g += n[k] / 3;
  return g;
}
static Outcome outcome(const int32_t *seq, int n, int settled) { return outcomeOf(seq, n, settled, 0, 0); }
// (THE LINE IN PROGRESS JUDGED IN ITS OWN FRAMES: the clock each of its swaps' walks was judged to begin on (decide.c carriedCand, into
// carryNB), the judge pressing none sooner -- asked by rank.c judgeCand for the line in progress only, its own cache entries)
static int32_t carryNB[64], carryNBn, outNBOn;
// (A LINE THAT MAY BREAK GARBAGE -- its finder says so, or garbage is on the board (rank.c judgeCand): its walks wait for the window,
// judge.c winWait)
static int32_t outWinWait;
// (A LINE NAMED ON THE ROOT'S BOARD: each swap's row as the board stands now, pressed where its panels have risen to by its frame -- the
// opener's plans, whose swaps are pressed while the stack rises: their own cache entries)
static int32_t outRooted;
static Outcome outcomeOf(const int32_t *seq, int n, int settled, int waitAt, int32_t waitTo) {
  int ck = outNBOn ? 5 : outRooted ? 6 : 0;
  Outcome *hit = waitTo ? 0 : cached(seq, n, settled, ck);
  if (hit) return *hit;
  // (the board left alone asked first: its judging is the judge's own nodes, which the line's end board is read from below)
  int32_t alone = n > 0 && !waitTo && decF.under ? aloneBuildable() : 0;
  int coming = decF.land != NOT_ASKED;
  int timeLeft = decF.timeLeft >= 0 ? decF.timeLeft : leftMsOf() > 0;
  JudgeOpts jo = { settled, decQ.tight, timeLeft ? (coming ? decF.land : 0) : NOT_ASKED, !coming, 1, HORIZON + REST, REST, !waitTo, waitAt, waitTo, 1 };
  if (outNBOn) { jo.notBefore = carryNB; jo.nNotBefore = imin(carryNBn, n); }
  jo.rooted = outRooted; jo.winWait = outWinWait;
  Outcome o;
  memset(&o, 0, sizeof o);
  judge(&decQ, seq, n, &jo, &o.j);
  o.late = o.j.late;
  o.dead = 1; o.lostAt = o.j.lostAt; o.lives = 0; o.ready = NOT_ASKED;
  // (A LANDING PUT OFF IS NOT A LANDING SURVIVED: garbage queued and none on the board, the engine drops it on the first frame nothing
  // moves, so a clear's frames are frames the same blocks wait -- they land all the same, on the panels the clear left. The frames a line
  // puts that drop off beyond the board left alone are taken out of the frame it is lost on: what is ranked is how long the board lasts
  // once the blocks land. A step that pressed a swap as the block dropped counts from before the press, so the frames taken out are
  // never more than the line put the drop off by; a line still standing at the judge's horizon is not asked)
  if (n > 0 && !o.j.dead && o.j.queueAt != NOT_ASKED && o.lostAt != NOT_ASKED && o.lostAt != FOREVER) {
    int32_t hq = holdQueueAt();
    if (hq != NOT_ASKED && o.j.queueAt > hq) { o.putOff = o.j.queueAt - hq; o.lostAt = imax(1, o.lostAt - o.putOff); }
  }
  if (!o.j.dead) {
    int32_t ready = o.j.ready;
    int breaks = o.j.made.broke > 0, stands = o.j.lostAt == FOREVER;
    o.dead = 0; o.ready = ready;
    o.lives = breaks || !coming ? (stands || ready == 1) : (ready == 1 || (ready == NOT_ASKED && stands));
    o.fits = fitsList(&theList, o.j.made, &o.j, 1) && imax(o.j.made.chain, o.j.chainAll) <= MAXCHAIN;
    // (a break: whether the board it leaves still has a break to build -- the material the next one needs)
    o.nextBuild = -1;
    o.panelsLeft = -1; o.nearAfter = -1; o.twinAfter = -1; o.lifeLeft = -1; o.floorKept = -1; o.matLeft = -1; o.matSettled = -1; o.groups = -1;
    if (!waitTo) {
      const Board *eb = ensureBoard(judgeCtx, o.j.endNode);
      if (eb) { o.panelsLeft = panelsOn(eb); o.lifeLeft = lifeOf(o.panelsLeft); o.floorKept = floorOf ? floorOf(eb) : -1; o.matLeft = materialOn(eb); o.groups = groupsOn(eb); }
      // (and once the board has settled: a chain still falling at the line's end spends panels after it -- the opener's chains, r1412)
      if (eb && eb->chainCounter > 0) { int sn = settleOf(judgeCtx, o.j.endNode); const Board *sb = liveNode(judgeCtx, sn) ? ensureBoard(judgeCtx, sn) : 0; o.matSettled = sb ? materialOn(sb) : o.matLeft; }
      else o.matSettled = o.matLeft;
      if (eb && endWanted == 1) { if (!endBoard) endBoard = nb_new(); if (endBoard) { cloneBoard(endBoard, eb); endWanted = 2; } }
      // (under garbage, how near the next break is on the board it leaves: a garbage-free board has no break to be near)
      if (eb && decF.under) o.nearAfter = garbageOn(eb) ? nearOf(eb) : 0;
      if (eb && twinWanted && !clockOut()) o.twinAfter = twinCostOn((Board *)eb);
      if (breaks) o.nextBuild = eb ? (!garbageOn(eb) || breakBuildable(eb)) : -1;
      // (CHAOS, THE CYCLE GOES ON: the board is always about to die -- no board left alone stands at chaos speed, and every line was
      // judged lost (runs 12-25, v=dies in every decision). A line keeps the board alive when, once it is done, the board still has the
      // margin for the bot's next freeze to begin -- frames to the top left alone (its loss less the line's end) at least the reaction
      // and two swaps' walks (CHAOS_FREEZE_START, the hands' own frames) -- and the fuel for that freeze: a three it has the panels
      // for, or garbage it can break. docs/CHAOS_RULES.md "How chaos is survived")
      if (!o.lives && eb && !waitTo && o.j.lostAt != NOT_ASKED) {
        int32_t margin = o.j.lostAt == FOREVER ? FOREVER : o.j.lostAt - o.j.done;
        int fuel = o.groups > 0 || (garbageOn(eb) && breakBuildable(eb));
        if (fuel && margin >= cfgReaction + 1 + 2 * (cfgSwapGap + 2 * cfgCursor)) o.lives = 1;
      }
    }
    // (THE MATERIAL FLOOR: under garbage, a line that breaks nothing, does not stand and leaves no break to build where the board left
    // alone keeps one has spent what the next break needs -- it is lost the frame it is done)
    if (n > 0 && !breaks && !stands && !waitTo && decF.under) {
      const Board *eb = alone ? ensureBoard(judgeCtx, o.j.endNode) : 0;
      if (eb && !breakBuildable(eb)) { o.lives = 0; o.spent = 1; o.lostAt = o.j.lostAt = imax(1, o.j.done); }
    }
    // (A PROMISED BREAK IS A REAL ONE: a line that lives only by being ready lives only when its readiness break, played where the
    // readiness found it, lives too -- one that cannot be played out (no line kept, too long, the clock) promises nothing)
    if (o.lives && !breaks && ready == 1 && !(stands && !coming) && !waitTo) {
      if (o.j.readyN > 0 && n + o.j.readyN <= MAXLINE) {
        int32_t ext[MAXLINE];
        for (int k = 0; k < n; k++) ext[k] = seq[k];
        for (int k = 0; k < o.j.readyN; k++) ext[n + k] = o.j.readyLine[k];
        Outcome e = outcomeOf(ext, n + o.j.readyN, settled, n, o.j.readyWait);
        if (e.late) o.late = 1;
        if (e.late || !e.lives) o.lives = 0;
      } else o.lives = 0;
    }
  }
  // (a judging the clock stopped is no answer: it is not kept, and the next asking judges it again)
  if (!o.late && !waitTo && !endNoKeep) keep(seq, n, settled, ck, &o);
  return o;
}
// THE BOARD A LINE ENDS ON, as the judge plays it (the land a proposer reads what falls from: search/fill.c), judged as the proposers
// judge it (readiness deferred to the rank); 0 when the judge could not play the line out. Kept until the next asking.
static Board *lineEnd(const int32_t *seq, int n, int settled) {
  int d = readyDefer; readyDefer = 1; endWanted = 1;
  outcome(seq, n, settled);
  int got = endWanted == 2; endWanted = 0; readyDefer = d;
  return got ? endBoard : 0;
}
// THE BOARD LEFT ALONE, as the proposers read it: its readiness, a break search of its own, is the ranking's to ask (decide.c ranked)
static Outcome leftAlone(void) { int d = readyDefer; readyDefer = 1; Outcome o = outcome(0, 0, 0); readyDefer = d; return o; }
// THE BOARD AT REST: a line -- the hold, with n 0 -- pressed as the judge presses it and its board let come to rest: the slab popping
// converted, its panels landed, the garbage let down onto what holds it. How far the garbage is from coming down a row then
// (search/break.c perchOf, lower the nearer; -1 no answer -- the board lost first, or the clock), whether it can (*can), and the
// frame the board is at rest (*at). Asked by the rank where no break is offered (rank.c letsDown), once a line a decision.
#define RESTN 64
typedef struct { uint32_t h; int32_t settled, n, perch, can, at; int32_t seq[MAXLINE]; } Rested;
static LOCAL Rested rested[RESTN]; static LOCAL int32_t nrested;
static int32_t restOf(const int32_t *seq, int n, int settled, int32_t *can, int32_t *at) {
  uint32_t h = lineHash(seq, n, settled, 7);
  for (int i = 0; i < nrested; i++) {
    const Rested *r = &rested[i];
    if (r->h != h || r->n != n || r->settled != settled) continue;
    int same = 1;
    for (int k = 0; k < n && same; k++) same = r->seq[k] == seq[k];
    if (same) { *at = r->at; *can = r->can; return r->perch; }
  }
  *at = -1; *can = 0;
  if (n > MAXLINE || clockOut()) return -1;
  JudgeOpts jo = { settled, decQ.tight, NOT_ASKED, 0, 0, -1, 0, 0, 0, 0, 0 };
  Judged j;
  judge(&decQ, seq, n, &jo, &j);
  int32_t u = -1;
  if (!j.dead && !j.late) {
    int rn = settleOf(judgeCtx, j.endNode);
    const Board *rb = liveNode(judgeCtx, rn) ? ensureBoard(judgeCtx, rn) : 0;
    if (rb) { int c = 0; u = perchOf(rb, &c); *can = c; *at = NODE(judgeCtx, rn)->t; }
  }
  if (clockOut()) { *at = -1; *can = 0; return -1; }   // (a judging the clock stopped is no answer: asked again)
  if (nrested < RESTN) { Rested *r = &rested[nrested++]; r->h = h; r->n = n; r->settled = settled; r->perch = u; r->can = *can; r->at = *at; for (int k = 0; k < n; k++) r->seq[k] = seq[k]; }
  return u;
}
// READY FOR THE NEXT BLOCK: after the line, a break in reach once the next block shown has landed -- what a board that cannot be ready
// for everything (the queue outlasts it) can still be ready for. 1, 0, or NOT_ASKED (nothing coming, or out of time). A line that
// presses something and is ready is worth what its readiness break leads to: the line and the break played on the engine, where the
// readiness found it (extLost: the frame that board is lost, FOREVER, or NOT_ASKED)
static int32_t readyNextOf(const int32_t *seq, int n, int settled, int32_t *extLost) {
  *extLost = NOT_ASKED;
  if (decF.next == NOT_ASKED) return NOT_ASKED;
  Outcome *hit = cached(seq, n, settled, 2);
  if (hit) { *extLost = hit->lostAt; return hit->ready; }
  if (clockOut()) return NOT_ASKED;
  JudgeOpts jo = { settled, decQ.tight, decF.next, 1, 1, -1, 0, 1 };
  Outcome o;
  memset(&o, 0, sizeof o);
  judge(&decQ, seq, n, &jo, &o.j);
  if (o.j.late) return NOT_ASKED;
  o.ready = !o.j.dead && o.j.ready == 1;
  o.lostAt = NOT_ASKED;
  if (o.ready && n > 0 && o.j.readyN > 0 && n + o.j.readyN <= MAXLINE) {
    int32_t ext[MAXLINE];
    for (int k = 0; k < n; k++) ext[k] = seq[k];
    for (int k = 0; k < o.j.readyN; k++) ext[n + k] = o.j.readyLine[k];
    Outcome e = outcomeOf(ext, n + o.j.readyN, settled, n, o.j.readyWait);
    if (!e.late) o.lostAt = e.dead ? (e.j.deadAt > 0 ? e.j.deadAt : NOT_ASKED) : e.lostAt;
  }
  *extLost = o.lostAt;
  keep(seq, n, settled, 2, &o);
  return o.ready;
}
// THE SHARED LINE CHECK: what the line makes and sets off fits the list, the chain is within MAXCHAIN, and below the rule's material
// floor it does not clear panels and break nothing. A check not begun by the decision's deadline keeps no line.
static int lineFits(const int32_t *seq, int n, int settled) {
  Outcome *hit = cached(seq, n, settled, 1);
  if (hit) return hit->fits;
  if (clockOut()) return 0;
  JudgeOpts jo = { settled, decQ.tight, NOT_ASKED, 0, 0, -1, 0, 0 };
  Outcome o;
  memset(&o, 0, sizeof o);
  judge(&decQ, seq, n, &jo, &o.j);
  Made m = o.j.made;
  o.fits = !o.j.dead && fitsList(&theList, m, &o.j, 1) && imax(m.chain, o.j.chainAll) <= MAXCHAIN &&
           !(decF.belowFloor && (m.combo > 0 || m.chain > 0) && !(m.broke > 0));
  // (a list ended by "default": a line outside it is the default's own, kept while the board lives through it)
  if (!listOn) o.fits = !o.j.dead && imax(m.chain, o.j.chainAll) <= MAXCHAIN;   // (the host's own check, a line held to no list)
  if (o.j.late) return 0;
  keep(seq, n, settled, 1, &o);
  return o.fits;
}
// THE LINE THAT TAKES A 2x ON (search/extend.c three -- the owner: at least a 3x over a 2x, whatever the list asks): played on the
// engine, the board not lost on it and its chain within MAXCHAIN; the list and the floor are the rank's to weigh, after survival
static int lineLives(const int32_t *seq, int n, int settled) {
  Outcome *hit = cached(seq, n, settled, 3);
  if (hit) return hit->fits;
  if (clockOut()) return 0;
  JudgeOpts jo = { settled, decQ.tight, NOT_ASKED, 0, 0, -1, 0, 0 };
  Outcome o;
  memset(&o, 0, sizeof o);
  judge(&decQ, seq, n, &jo, &o.j);
  o.fits = !o.j.dead && imax(o.j.made.chain, o.j.chainAll) <= MAXCHAIN;
  if (o.j.late) return 0;
  keep(seq, n, settled, 3, &o);
  return o.fits;
}

// ---- a decision begun: the question (from a node of a host search, until the decision reads its own) and the facts; every line is
// judged again
EXPORT(gb_decision_on) int gb_decision_on(int land, int topped, int timeLeft, int belowFloor);
EXPORT(gb_decision_start) int gb_decision_start(Ctx *hx, int i, int tight, int land, int topped, int timeLeft, int belowFloor) {
  if (gb_question(hx, i, tight) < 0) return -1;
  return gb_decision_on(land, topped, timeLeft, belowFloor);
}
// the same, on the question already set (gb_question_bytes)
EXPORT(gb_decision_on) int gb_decision_on(int land, int topped, int timeLeft, int belowFloor) {
  decQ = hostQ; decQ.b = hostBoard; backBoard = hostBoard;
  Facts f = { land, topped, timeLeft, belowFloor };
  decF = f;
  ncache = 0; nrested = 0; rootBuildable = NOT_ASKED; rootQueueAt = QUEUE_UNSET;
  return 0;
}
// The line in the io body (nseq words); back: dead, lostAt, lives, fits, ready, late, then the judge's answer as gb_judge writes it.
EXPORT(gb_outcome) int gb_outcome(int nseq, int settled) {
  static int32_t seq[MAXLINE];
  if (nseq < 0 || nseq > MAXLINE) return -1;
  for (int i = 0; i < nseq; i++) seq[i] = gbIo[i];
  Outcome o = outcome(seq, nseq, settled);
  int32_t *w = gbIo, k = 0;
  w[k++] = o.dead; w[k++] = o.lostAt; w[k++] = o.lives; w[k++] = o.fits; w[k++] = o.ready; w[k++] = o.late;
  w[k++] = o.j.made.combo; w[k++] = o.j.made.chain; w[k++] = o.j.made.broke; w[k++] = o.j.chainAll; w[k++] = o.j.dropAt; w[k++] = o.j.done; w[k++] = o.j.fire;
  w[k++] = o.j.nats; for (int q = 0; q < o.j.nats; q++) w[k++] = o.j.ats[q];
  return k;
}
EXPORT(gb_line_fits) int gb_line_fits(int nseq, int settled) {
  static int32_t seq[MAXLINE];
  if (nseq < 0 || nseq > MAXLINE) return -1;
  for (int i = 0; i < nseq; i++) seq[i] = gbIo[i];
  return lineFits(seq, nseq, settled);
}
