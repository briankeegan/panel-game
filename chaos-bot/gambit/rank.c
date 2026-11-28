// THE RANK (hold, compare, digWaits; plans/decision.md step 4): every candidate a proposer offers, judged by its
// outcome and filtered -- a swap back, outside the list, below the floor, too late -- then given its place: one order for every
// candidate, a line that lives before one that does not; of two that live, the tier and its sub-keys; of two that do not, the one
// whose board is lost later.

// A CANDIDATE: the play, its swaps, what the search that found it says it makes (x), the entry it was found
// for (aim, -1 none), whether it extends a cascade, how it is judged (settled: -1 as its play is)
typedef struct {
  int32_t set, play, nseq, seq[MAXLINE], aim, extend, settled;
  int32_t grown;   // a line another proposed, one more panel walked into its match (propose.c growLines)
  int32_t drop;    // a perched block let down (search/break.c perchedDrops)
  int32_t letDown; // the garbage let down off its tallest column (propose.c letDownCand): a set-up read on its own clears (judge.c firstClear)
  int32_t kept;    // an intention the last decision kept, found again (decide.c keptJudged)
  int32_t way;     // a line another proposed, with a swap that does something made first on the cursor's way to it (propose.c wayLines)
  int32_t route;   // two lines on columns apart made one, in walking order (decide.c routeJudged)
  int32_t pair;    // a line that fires two ideas, one after the other (search/plan.c pair; decide.c routeJudged)
  int32_t twin;    // two columns sorted row by row, then one swap that clears both (propose.c twinLines): 1 the line, 2 the set-up alone
  int32_t readyGain;   // a swap that brings the break nearer on the board the garbage on its way lands on: the swaps it saves (propose.c readyBuild)
  int32_t aimC, aimLeft;   // a set-up's combo when it is fired, and the swaps from the line's end to it (propose.c twinLines: the log's aim)
  Xs x; int32_t xFire, xDone, xNats, xAts[MAXLINE];   // xFire/xDone: -1 not said
} Cand;
// A JUDGED CANDIDATE: its place (tier, sub), its outcome, and what the move played reads (ap)
typedef struct {
  Cand k;
  int32_t settled, aim, wait, hold, back;   // back: its first swap swaps back the pair the last swap pressed swapped (rules.c swappedBack)
  Tier t;
  Outcome o;
  int32_t apDone, apFire, apNats, apAts[MAXLINE], apChain, apChainAll, apCombo, apBroke, apPlayed;
  int32_t apWhole;     // the chain the board ends up making with the line played (Judged.whole)
  int32_t readyNext;   // a break in reach once the next block lands (readyNextOf), asked when none lives; NOT_ASKED: not asked
  int32_t extLost;     // and where that break leads: the line and the break played, lost then (readyNextOf); NOT_ASKED: not asked
  int32_t outside;     // outside the list, taken as the default's own move (a list ended by "default")
  int32_t spends;      // outside it for clearing panels below the floor without breaking (decide.c read: belowFloor)
  int32_t met;         // the entry of the list as the board asks it the judged line meets, -1 none (rules.c metOf)
  int32_t modeFirst;   // it meets the mode's own first entry, its break or not (under garbage R->asked holds each entry twice: rules.c withAttacks)
  int32_t first;       // the line in progress, its next step due now: first of its tier (decide.c ranked)
  int32_t carried;     // the line in progress, carried on from the last decision (decide.c carriedCand)
  int32_t idle;        // a line that clears nothing and does no better than the hold (markIdle): ranked after the hold
  double idleLost;     // and, of two that do not live, lost as the hold is and a half frame sooner (an unknown is not shown better)
  int32_t waitMax;     // a line waiting, ranked with the hold at the hold's tier or its own when lower (the line in progress)
  int32_t saving;      // a break under garbage while the board saves panels up (decide.c read): its panels weighed before the list
  int32_t material;    // a break under garbage: 0 leaves a break to build and keeps the floor, 1 keeps one of them, 2 neither; -1 none
  int32_t ideas, ideasAsked;   // the ideas the board the line leaves holds (search/ideas.c; -1 the clock left none), asked when a key needs it
  int32_t rest, restCan, restAt, restAsked;   // how far the garbage is from coming down a row once the line's board is at rest, whether it can, and the frame it is (outcome.c restOf; -1 no answer), asked when a key needs it
  int32_t lengthens;            // time attack: the line makes the board's chain longer than it makes alone, below 13 (in the mode)
} Judge;
#define EXT_CUT_LOG 6
static int32_t extCutLog[EXT_CUT_LOG][5], extCutN;   // (extensions the judge cut, this decision: swap cut, swaps, why, the last swap's walk frame, the search's chain)
static int32_t aloneChain; static int ruleNoEnemy;   // (below: the chain the board makes alone, and time attack's rule)
// why a candidate was dropped, counted per decision for the log (DROP_CODE: b back, o list, t late, f floor, r ready, u unbroken, c a swap
// the judge could not press, w a wasted three, j the clock stopped its judging, 2 a 2x not taken to three)
static int32_t lastCut = -1, lastCutWhy, lastCutRisen, lastCutClock, lastCutCell, lastCutStates;
static char lastCutRows[200];
static int32_t lastPA[16], lastPT[16], lastPR[16], lastPressedN;   // (each swap of the last opening plan that made no chain: where and when the judge pressed it, the rows risen -- the log's opPressed=)   // (the board the cut swap was to be pressed on, rows bottom up: the log's opCut=)
static void boardRows(const Board *b, char *out, int cap);   // (the swap the judge cut the last line dropped at, why, and the rows risen by the swap before it: decide.c's opTries log)
enum { DROP_BACK, DROP_LIST, DROP_LATE, DROP_FLOOR, DROP_READY, DROP_UNBROKEN, DROP_CUT, DROP_WASTE, DROP_UNJUDGED, DROP_TWO, NDROPS };
static int finishAsked(void);   // (below: the list asks a combo of eight or more and no chain -- finish them)
static int32_t dropped[NPLAYS][NDROPS], offered[NPLAYS];
static int32_t lastDrop = -1;   // (the last drop's why: the opening plan's log)
static void dropAs(int play, int why) { dropped[play][why]++; lastDrop = why; }
// (the lines cut, by why the judge cut them: judge.c cutWhy -- 1 a first walk over the allowance, 2 no swap there, 3 a walk not begun
// within a reaction -- and how many of them the break search found)
static int32_t cutWhy[4], cutWhyBreak[4];
// THE FIRST LINE OF A DECISION THE BREAK SEARCH SAID BREAKS AND THE JUDGE SAYS DOES NOT: its play, swaps and both counts, for the log
// and the board's dump (two measures of one fact)
static struct { int32_t set, play, nseq, seq[MAXLINE], said, judged, alone; } unbroken;   // (alone: what the board left alone breaks in the line's time)

// the decision's reading of the board, which every candidate is judged by (decide.c read)
typedef struct {
  FactSet F; int32_t enemyTopped;
  List list, asked, guides; int32_t end;
  // (list: the rule's, its priorities; guides: the list as the board asks it -- every entry a break under garbage, then the one rule's
  // three that breaks -- the searches', a proposal's aim indexes it; asked: the same, the rank's)
  int32_t by;                      // NOT_ASKED: none
  int32_t under, topped, breakWaits, belowFloor;
  int32_t dying;                   // the board is on its way to its loss: under garbage, or lost left alone -- the rise's countdown as
                                   // much as a block's -- within the horizon and a rest (decide.c read)
  int32_t taDying;                 // time attack: under garbage, or lost left alone inside TA_DANGER frames (decide.c read)
  int32_t saving;                  // saving panels up: breaks that leave the most come before the list (decide.c read)
  int32_t full;                    // more panels than the board lives longest with (outcome.c lifePeakOf): every line's life by them before the list
  Keep keep; int32_t keepOn;
  int32_t readyAt;                 // NOT_ASKED: none
  int32_t pop, to, low, up;
  int32_t aloneChain, aloneOut;
  int32_t rule;
} Read;

// a sub-key put in at `pos`, the keys from there on after it (one that does not fit is dropped from the end)
static void tierInsert(Tier *t, int pos, double v) {
  if (pos > t->nsub) pos = t->nsub;
  for (int q = imin(t->nsub, MAXSUB - 1); q > pos; q--) t->sub[q] = t->sub[q - 1];
  if (pos < MAXSUB) t->sub[pos] = v;
  t->nsub = imin(t->nsub + 1, MAXSUB);
  if (pos <= t->nlist) t->nlist++;
}
static int judgeCand(const Read *R, const Cand *k0, Judge *J) {
  memset(J, 0, sizeof *J);
  J->readyNext = NOT_ASKED; J->extLost = NOT_ASKED;
  J->k = *k0;
  Cand *k = &J->k;
  int play = k->play, aim = k->aim;
  int st = k->settled >= 0 ? k->settled : settledPlay(play);
  // (STEADY, NOT IN BURSTS -- the owner: while a slab pops, a line that would wait for the board to stop before each swap is judged pressed
  // straight through, each swap as soon as its pair is free: its swaps spread over the pop, not saved for its end -- unless it is found to
  // break garbage, whose break is timed on the board settled)
  if (k->settled < 0 && st && popLeft(decQ.b) > 0 && !(k->x.broke > 0) && (play == PLAY_ENTRY || play == PLAY_NEAREST || play == PLAY_BREAKLINE || play == PLAY_CLEAR)) st = 0;
  // (what it makes is the whole line on the engine, as the judge counts it -- not what the search that found it counted; a line the
  // judge could not play out is judged on the search's word)
  // (the line in progress waiting for the board to settle: judged on the board settled, as carriedCand found it)
  outNBOn = play == PLAY_CARRY || play == PLAY_CARRYWAIT;
  outWinWait = k->x.broke > 0 || decF.under;   // (under garbage any line may be the break: judged again cut where it breaks none)
  Outcome oc = play == PLAY_CARRYWAIT ? outcomeOf(k->seq, k->nseq, st, 0, 1) : outcome(k->seq, k->nseq, st);
  outNBOn = 0; outWinWait = 0;
  // (A LINE THE JUDGE COULD NOT PLAY OUT IS NO LINE: a swap not there to press, however long the board is let settle, and the line
  // stops -- its board is not the one the line makes, so it is not ranked as if it were)
  // (an extension cut: which swap, why, at what frame of its walk, and the search's chain for it -- the log's extCut=)
  if (!oc.dead && oc.j.cut >= 0 && (play == PLAY_EXTEND || play == PLAY_LINEUP) && extCutN < EXT_CUT_LOG) {
    int32_t *t = extCutLog[extCutN++]; t[0] = oc.j.cut; t[1] = k->nseq; t[2] = oc.j.cutWhy; t[3] = oc.j.nats > 0 ? oc.j.ats[oc.j.nats - 1] : -1; t[4] = k->x.chain; }
  // (an opening plan the judge played through to no chain: the board it ended on, for the log's opCut=)
  if (!oc.dead && oc.j.cut < 0 && outRooted && oc.j.chainAll < 2 && k->nseq >= 4) {
    lastPressedN = 0; for (int i = 0; i < oc.j.nats && i < k->nseq && i < 16; i++) { lastPA[i] = oc.j.pressedAt[i]; lastPT[i] = oc.j.ats[i]; lastPR[i] = oc.j.risen[i]; lastPressedN++; } const Board *cb = oc.j.preLast >= 0 ? ensureBoard(judgeCtx, oc.j.preLast) : 0; lastCutClock = cb ? cb->clock : -1; lastCutCell = k->seq[k->nseq - 1] + (oc.j.nats >= k->nseq ? oc.j.risen[k->nseq - 1] * 8 : 0); lastCutStates = -2; if (cb) boardRows(cb, lastCutRows, sizeof lastCutRows); else lastCutRows[0] = 0; }
  if (!oc.dead && oc.j.cut >= 0 && outRooted) { const Board *cb = ensureBoard(judgeCtx, oc.j.endNode); lastCutClock = cb ? cb->clock : -1; if (cb) boardRows(cb, lastCutRows, sizeof lastCutRows); else lastCutRows[0] = 0;
    { int r = oc.j.cutAt / 8, c = oc.j.cutAt % 8; lastCutCell = oc.j.cutAt; lastCutStates = cb && r >= 0 && r < cb->nrows && c >= 1 && c < W ? cb->p[r][c].f[STATE] * 10 + cb->p[r][c + 1].f[STATE] : -1; } }
  if (!oc.dead && oc.j.cut >= 0) { lastCut = oc.j.cut; lastCutWhy = oc.j.cutWhy; lastCutRisen = oc.j.nats > 0 ? oc.j.risen[oc.j.nats - 1] : 0; dropAs(play, DROP_CUT); int w = oc.j.cutWhy >= 1 && oc.j.cutWhy <= 3 ? oc.j.cutWhy : 0; cutWhy[w]++; if (play == PLAY_BREAKSEARCH || play == PLAY_LINEUPBREAK) cutWhyBreak[w]++; return 0; }
  // (ONE THE CLOCK STOPPED THE JUDGE ON: its board past that frame unknown -- ranked as a line lost on the frame it was judged alive to,
  // what it makes on the search's word: never a board that lasts, and never dropped for a hold that dies sooner)
  if (oc.late) {
    if (oc.j.aliveTo <= 0) { dropAs(play, DROP_UNJUDGED); return 0; }
    oc.late = 0; oc.dead = 1; oc.lives = 0; oc.lostAt = oc.j.aliveTo; oc.ready = NOT_ASKED;
  }
  const Judged *j = oc.dead ? 0 : &oc.j;
  Made m = j ? (Made){ j->made.combo, j->made.chain, j->made.broke, k->x.cells } : (Made){ k->x.combo, k->x.chain, k->x.broke, k->x.cells };
  if (j && k->x.broke > 0 && !(j->made.broke > 0)) {
    dropAs(play, DROP_UNBROKEN);
    if (!unbroken.set) { unbroken.set = 1; unbroken.play = play; unbroken.nseq = k->nseq; for (int i = 0; i < k->nseq; i++) unbroken.seq[i] = k->seq[i]; unbroken.said = k->x.broke; unbroken.judged = j->made.broke; unbroken.alone = j->base; }
  }
  if (k->nseq && swapBack(CR(k->seq[0]), CC(k->seq[0]), m.broke > 0 ? 2 : m.combo > 0 || m.chain > 0)) { dropAs(play, DROP_BACK); return 0; }
  // (it fits the list -- the chain as the game counts it -- or it is outside it: ranked after every line within it that lives, and kept,
  // so a list never chooses a death. Below the rule's material floor a line that clears panels and breaks no garbage spends what the
  // board needs: outside too)
  if (m.chain > MAXCHAIN) { dropAs(play, DROP_LIST); return 0; }
  // (TIME ATTACK: a line that makes the board's chain longer than it makes alone is within the list, whatever length the list asks --
  // a chain is taken there a link at a time, up to 13)
  int lengthens = ruleNoEnemy && j && aloneChain < CB_TOP && j->whole.chain > imax(1, aloneChain);
  J->lengthens = lengthens;
  // (IN FINISH THEM A COMBO IS A COMBO -- the owner: any combo, a 2x allowed: a combo of four or more that comes with a chain of two at most
  // meets the list by its combo)
  int finishCombo = 0;
  if (finishAsked() && m.combo >= 4 && m.chain <= 2) { Made mc = m; mc.chain = 0; finishCombo = fits(&R->list, mc); }
  if (!lengthens && !finishCombo && !(j ? fitsList(&R->list, m, j, 0) : fits(&R->list, m))) J->outside = 1;
  // (the opener's chain is never a spend -- the owner: no scenario is worth not throwing large chains at the start: a chain of three or
  // more, the opener in force, is what the panels are for)
  int openerChain = R->rule >= 0 && theTables.r[R->rule].table == 2 && m.chain >= 3;
  // (nor finish them's eight and up -- the owner: the eights are what the panels are for once the enemy is topped out)
  int finishEight = finishAsked() && m.combo >= 4 && m.chain <= 2;   // (in finish them every combo is the attack: none is a spend -- the owner: any combo before a three)
  if (R->belowFloor && (m.combo > 0 || m.chain > 0) && !(m.broke > 0) && !openerChain && !finishEight) J->outside = J->spends = 1;
  // (THE ENTRY A LINE MEETS, the one the list's key and the tier's keys read: of the list as the board asks it (R->asked) -- its
  // entries, then the one rule's three that breaks)
  // (read off what the board ends up making, the chain already under way included: a swap that cuts it short meets what is left of it,
  // and leaving it alone -- the hold -- meets what it makes)
  int entry = metOf(&R->asked, j ? (Made){ j->whole.combo, j->whole.chain, j->whole.broke, m.cells } : m);
  J->met = j ? entry : -1;
  if (J->lengthens && J->met < 0) J->met = 0;   // (time attack: lengthening the chain is the mode's first entry, for every key)
  { int nl = R->list.n; J->modeFirst = J->met == 0 || (R->topped && nl > 0 && J->met == nl + 1); }   // (the one rule's three that breaks is the mode's first only topped out -- the owner: a three is for survival)
  J->saving = R->saving && R->under && m.broke > 0;
  // (the next break's material, as the engine leaves the board: a break to build, the floor kept -- outcome.c nextBuild, floorKept)
  J->material = R->under && m.broke > 0 ? (oc.nextBuild == 0) + (oc.floorKept == 0) : -1;
  // (the entry a line is ranked for is the one the judged line meets; the search's word only where the judge could not play it out)
  if (j) aim = entry; else if (entry >= 0 && (aim < 0 || entry < aim)) aim = entry;
  // (in time: the line's last swap begun by the deadline -- the frame the judge pressed it; the search's own word only when the judge
  // could not play the line out)
  int32_t fire = j && j->fire >= 0 ? j->fire : (k->xFire >= 0 ? k->xFire : k->xDone);
  // (never the line in progress: late is a frame that moves with what the board does next -- it is put down only when it can no longer be
  // pressed or no longer makes what it was begun for, and ranked by survival as any line is)
  if (R->by != NOT_ASKED && R->by && fire >= 0 && fire > R->by && play != PLAY_CARRY && play != PLAY_CARRYWAIT) { dropAs(play, DROP_LATE); return 0; }
  // (a set-up is to clear nothing: it ends before its first step that clears panels and breaks nothing; when that is its first, the
  // play is a clear)
  Xs x = k->x;
  if (setupPlay(play)) {
    int fc = firstClear(&decQ, k->seq, k->nseq, k->letDown);
    if (fc == 0) { play = PLAY_CLEAR; memset(&x, 0, sizeof x); x.combo = 3; x.chain = 1; x.floor = -1; m.combo = 3; m.chain = 1; m.broke = 0; m.cells = 0; }
    else if (fc > 0) k->nseq = fc;
  }
  k->play = play;
  // (ranked on the judge's count and time)
  Xs tx = x;
  tx.floor = oc.floorKept >= 0 ? oc.floorKept : tx.floor;   // (the floor the judged board keeps, the claim only where it was not asked)
  tx.combo = m.combo; tx.chain = m.chain; tx.broke = m.broke; tx.done = j ? j->done : (k->xDone >= 0 ? k->xDone : 0); tx.dropAt = j ? j->dropAt : 0;
  J->t = tierOf(play, &tx, aim, R->under, R->enemyTopped, R->topped, R->breakWaits);
  // (topped out, the stop time and the shake are the board's life: a line that keeps it held past what is left now comes first -- under
  // garbage one that breaks before one that does not: a break turns garbage into the panels the next one needs)
  const Board *b = decQ.b;
  int32_t stopNow = imax(b->stopTime + b->preStopTime, b->shakeTime);
  if (R->topped && j && j->dropAt > stopNow) {
    int brk = R->under && m.broke > 0;
    J->t.tier = 0; J->t.nsub = 3; J->t.nlist = 2; J->t.sub[0] = R->under ? (brk ? 0 : 1) : 0; J->t.sub[1] = aim >= 0 ? aim : 99; J->t.sub[2] = -j->dropAt;
  }
  // (THE LIFE ITS PANELS LEAVE (outcome.c lifeOf, measured), then THE NEAREST BREAK AFTER IT: of two in one tier, the one whose board has
  // more life by the panels left on it, then the one nearer its next break -- right after the list's own keys)
  // -- under garbage the nearer break first: the next break is the board's life there, and the panels kept by doing nothing never make it
  if (oc.panelsLeft >= 0) {
    if (R->under && oc.nearAfter >= 0) { tierInsert(&J->t, J->t.nlist, oc.nearAfter); tierInsert(&J->t, J->t.nlist + 1, -(double)oc.lifeLeft); }
    else {
      tierInsert(&J->t, J->t.nlist, -(double)oc.lifeLeft);
      if (oc.nearAfter >= 0) tierInsert(&J->t, J->t.nlist + 1, oc.nearAfter);
    }
  }
  J->settled = st; J->aim = aim; J->o = oc; J->back = k->nseq > 0 && swappedBack(CR(k->seq[0]), CC(k->seq[0]));
  J->apDone = j ? j->done : k->xDone; J->apFire = fire;
  if (j) { J->apNats = j->nats; for (int i = 0; i < j->nats; i++) J->apAts[i] = j->ats[i]; }
  else { J->apNats = k->xNats; for (int i = 0; i < k->xNats; i++) J->apAts[i] = k->xAts[i]; }
  J->apChain = m.chain; J->apChainAll = j ? j->chainAll : 0; J->apCombo = m.combo; J->apBroke = m.broke; J->apPlayed = !!j;
  J->apWhole = j ? j->whole.chain : 0;
  return 1;
}
// THE HOLD, a candidate like any other: nothing pressed, its outcome the board's own -- below every play that fits, above a clear
#define HOLD_TIER 5
static int32_t aloneChain;   // the chain the board left alone makes, as the hold's judging found it
static void holdCand(const Read *R, int wait, Judge *J) {
  memset(J, 0, sizeof *J);
  J->readyNext = NOT_ASKED; J->extLost = NOT_ASKED;
  // (the hold presses nothing: it meets the entry the board makes left alone, if any, and is no break -- never a break's best material)
  J->o = outcome(0, 0, 0);
  J->material = -1;
  J->met = J->o.dead ? -1 : metOf(&R->asked, (Made){ J->o.j.whole.combo, J->o.j.whole.chain, 0, 0 });
  { int nl = R->list.n; J->modeFirst = J->met == 0 || (R->topped && nl > 0 && J->met == nl + 1); }   // (the one rule's three that breaks is the mode's first only topped out -- the owner: a three is for survival)
  aloneChain = J->o.j.whole.chain;   // (made before the board is lost too: judge.c, a settle the board is lost in)
  J->k.play = PLAY_HOLD; J->k.aim = -1; J->hold = 1; J->wait = wait; J->aim = -1;
  J->t.tier = HOLD_TIER; J->t.nsub = 1; J->t.sub[0] = wait ? -1 : 0;
  const Judged *j = J->o.dead ? 0 : &J->o.j;
  J->apDone = j ? j->done : -1; J->apFire = -1; J->apChainAll = j ? j->chainAll : 0; J->apPlayed = !!j;
}
// A DIG THAT CAN WAIT: a line toward a break that lives no longer than the hold, and is still done before the hold is lost after one
// more decision (react frames) -- never one that leaves the board nearer a break than the hold does: the frames it waits are frames
// the break is no nearer in
static void readyNextFor(Judge *J) {
  if (J->o.lives || J->readyNext != NOT_ASKED) return;
  J->readyNext = readyNextOf(J->k.seq, J->k.nseq, J->hold ? 0 : J->settled, &J->extLost);
}
static int digWaits(const Judge *k, const Judge *H, int32_t react) {
  return k->k.play == PLAY_TOWARD && !k->o.lives && !H->o.lives && H->o.lostAt != NOT_ASKED && k->o.j.done >= 0 && !k->o.dead &&
         k->o.lostAt <= H->o.lostAt && (double)H->o.lostAt - k->o.j.done > react &&
         !(k->o.nearAfter >= 0 && H->o.nearAfter >= 0 && k->o.nearAfter < H->o.nearAfter);
}
// THE ONE ORDER: a line that lives before one that does not; of two that live, the one within the list before the default's own (a
// list that cannot be made -- nothing within it lives -- falls back to it); of two that do not live, the one whose board is lost later,
// then the one with a break in reach once the next block lands (a death sooner is never taken for readiness); then the tier, then each
// sub-key in turn
// (a line whose judging the clock cut is not known to die: it ranks after every board that stands and before every known loss -- a
// death known is never chosen over a line that may live)
// (a line ready for the next block is lost where its readiness break leads, when that is later; a hold is not credited for the break
// it waits for -- that break is a candidate of its own)
static int32_t rankReact;   // (frames to the next decision: a reaction and a frame, set by the decision -- decide.c ranked)
static int32_t rankSave;    // (and the frames one break takes after it: a full-width slab's row popped -- flash, face, a pop a cell)
static double lostAtOf(int32_t t, int hold) { return t == FOREVER ? 1e300 : t == NOT_ASKED ? (hold ? -1 : 1e299) : t; }
// (THE WALK COUNTED IN THE LOSS: a line's loss less WALK_FRAMES for each action the cursor walks for it -- an action spent comes back a
// window later, as the survival search counts it (search/outlive.c OUT_ACT) -- so a line across the board is the later loss only where
// it buys that much more time than one at hand. At 16 the bot walks too little to live: switching 3/48)
#define WALK_FRAMES 8
#define TWIN_KEY_REACH 12   // (the farthest eight the set-up key 7d reads: an eight within a line's reach)
#define TWIN_STEP 2   // (swaps nearer an eight that decide between two lines otherwise equal: 7d)
static int lineWalk(const Judge *J);
static double lostOf(const Judge *x);
// THE FRAME THE BOARD IS LOST, as the engine has it -- the line's own loss or its readiness's, no walk charged (lostOf charges the walk:
// the order's preference for the nearer, not a loss): what a set-up that must never cost the board's life is held to
// (THE NEXT MOVES' CREDIT, ONLY WHERE THE LINE COSTS THE BOARD NOTHING: a line's life after it (extLost) counts only where its own board,
// left alone, is lost no sooner than the hold's -- the hold is never credited with moves after it, and a line that shortens the board's
// own life on a break it promises after the next block is a line whose promise is never pressed: r1335 3913-4002, four ready swaps lost
// at 91 against the hold's 135, each credited 376-405)
static double rankHoldOwn = -1; static int32_t rankHoldClock = -1;   // (the hold's own loss this decision: markIdle)
static int extCounts(const Judge *x) {
  if (x->hold || x->extLost == NOT_ASKED) return 0;
  if (lostAtOf(x->o.lostAt, 0) < rankSave) return 0;   // (a board lost inside a break's time presses no promise after it)
  if (rankHoldClock != decQ.b->clock || rankHoldOwn < 0) return 1;
  // (and under garbage, a line that breaks none of it earns the promise only where its own board outlives the hold by the time its walk
  // takes -- the owner: no walking far for nothing: r1427, 3750, a cut walked 8 actions among the slabs, lost at 125 as the hold was,
  // credited 249; run 4173, of the walks wasted in garbage games about half were chosen on a promise)
  if (decF.under && !(x->apBroke > 0) && lostAtOf(x->o.lostAt, 0) - rankHoldOwn < (double)WALK_FRAMES * lineWalk(x)) return 0;
  return lostAtOf(x->o.lostAt, 0) >= rankHoldOwn;
}
static double diesAt(const Judge *x) {
  double own = lostAtOf(x->o.lostAt, x->hold);
  if (extCounts(x)) { double ext = lostAtOf(x->extLost, 0); if (ext > own) own = ext; }
  return own;
}
// (THE WALK NEVER TURNS A LIFE INTO A DEATH: two boards lost a break's time apart or more on the frame each is lost, the later of them,
// whatever the walk charges -- the judge pressed each line on its walks already, and the charge is the order's preference for the nearer,
// never a break's time of life: the walked line's board 140 frames alive past the hold's was put after it)
// (and a board lost within a break's time has no frame to give for a walk: there the later loss decides by any margin -- the hold lost at
// 8 is never put before the line lost at 19 for the cursor's walk)
static int spendsReserve(const Judge *J);
static int waitWalks(const Judge *J);
static int waitSpends(const Judge *J);
// THE WAIT'S WINDOW SPENT FOR NO BREAK: in the wait (waitOf), a line l that breaks nothing and walks the window below a break's walk
// by the frame the board is at rest, beside s -- the hold, a line that does no better than holding, or a line that keeps that walk. The
// break the wait is for is pressed out of that window, and frames bought with it are no life where the break cannot then be pressed.
// Only while the hold's own board stands a break's time: a hold lost inside it waits for nothing.
static int waitSpent(const Judge *l, const Judge *s) {
  return rankHoldClock == decQ.b->clock && rankHoldOwn >= rankSave && waitSpends(l) && (s->hold || s->idle || !waitSpends(s));
}
static int windowDead(const Judge *J);
static int walkTurns(const Judge *x, const Judge *y) {
  if (x->o.lives || y->o.lives) return 0;
  double dx = diesAt(x), dy = diesAt(y);
  if (dx >= 1e299 || dy >= 1e299 || dx < 0 || dy < 0 || dx == dy) return 0;
  // (and never behind the hold, a line that breaks garbage and is lost later: the walk it is charged was pressed on the engine when its
  // loss was judged, and the hold breaks nothing)
  { const Judge *l = dx > dy ? x : y, *s = dx > dy ? y : x;
    // (in finish them, a line that takes the chain past 2x and longer than the other's is never put first for its later loss here -- the
    // shorter chain and the walk decide: set 86 combo_storm 1, 1734, a 4x taken to a 6x with a walk of 38 over a line lost 98 frames
    // sooner, the chain then fed through the garbage to a 10x)
    if (finishAsked() && l->apChainAll > 2 && l->apChainAll > s->apChainAll && !s->hold && !s->o.dead && (dx < dy ? dx : dy) >= rankSave) return 0;
    if (s->hold && !l->hold && l->apBroke > 0) return (dx > dy) != (lostOf(x) > lostOf(y));
    // (nor, under garbage, a line that spends no panels and breaks or walks toward a break, behind the hold or a line that spends them:
    // the hold builds nothing and the spend is the next break's material -- r1336 9240-9268, a toward line lost 43 frames later put
    // behind the hold for its walk while a pop ran, the board left to drain its material on chains after)
    // (and only for a walk the gain is worth -- the owner: never far for no good reason: within WALK_EARN actions of the other, or
    // NEAR_GAIN frames later; run 4119, 8442: a toward walked 11 actions for 1 frame past the hold)
    if ((s->hold || s->spends) && !l->hold && !l->spends && decF.under && (l->apBroke > 0 || l->k.play == PLAY_TOWARD) &&
        (lineWalk(l) - lineWalk(s) <= 6 || (dx > dy ? dx - dy : dy - dx) >= 30))   // (WALK_EARN, NEAR_GAIN: defined below)
      return (dx > dy) != (lostOf(x) > lostOf(y));
    // (nor, in finish them, a line that fires an eight or more, beside any line lost sooner: the attack the mode asks, its walk pressed
    // on the engine as well)
    if (finishAsked() && !l->hold && l->apCombo >= 8 && l->apChain < 2 && !(s->apCombo >= 8 && s->apChain < 2)) return (dx > dy) != (lostOf(x) > lostOf(y)); }
  // (nor in the wait, the later one walking the window out for no break -- waitSpent: the walk's charge decides between the two)
  if (waitSpent(dx > dy ? x : y, dx > dy ? y : x)) return 0;
  // (nor a later loss the window leaves no break against, beside a line that leaves the next break its walk within its own life, a
  // break's time or more: the frames the later one buys end its game, the other's are frames a break is pressed in -- the walk's charge
  // decides between the two)
  { const Judge *l = dx > dy ? x : y, *s = dx > dy ? y : x;
    if ((dx < dy ? dx : dy) >= rankSave && windowDead(l) && !windowDead(s)) return 0; }
  // (nor, under garbage, a later loss that breaks nothing and leaves the next break less than its walk, beside a line that keeps it --
  // the owner: efficiency is key: the actions it spends are the next break's, and a board kept on them is one left with none to break
  // with -- the walk's charge decides between the two, however far apart they are lost)
  { const Judge *l = dx > dy ? x : y, *s = dx > dy ? y : x;
    if (decF.under && (dx < dy ? dx : dy) >= rankSave && !(l->apBroke > 0) && spendsReserve(l) && !spendsReserve(s)) return 0; }
  if ((dx > dy ? dx - dy : dy - dx) < rankSave && (dx < dy ? dx : dy) >= rankSave) return 0;
  // (nor where the later one buys less than a break's time with the window the next breaks are pressed from: the actions it spends come
  // back only a window later, and a board kept a few frames on them is a board left with none when it needs them)
  { const Judge *l = dx > dy ? x : y, *s = dx > dy ? y : x;
    if ((dx > dy ? dx - dy : dy - dx) < rankSave && spendsReserve(l) && !spendsReserve(s)) return 0; }
  return (dx > dy) != (lostOf(x) > lostOf(y));
}
// (THE FINISH'S EIGHT: in finish them, a line that fires an eight or more beside one that does not, lost within a break's time of it or
// later -- the attack the mode asks, never put after the other for its walk or for the line in progress)
static int finishEightBy(const Judge *e, const Judge *o) {
  if (!finishAsked() || e->hold || e->o.dead || e->apCombo < 8 || e->apChain >= 2 || (o->apCombo >= 8 && o->apChain < 2)) return 0;
  if (e->o.lives) return 1;
  if (o->o.lives) return 0;
  double de = diesAt(e), d0 = diesAt(o);
  return de >= rankSave && d0 - de < rankSave;
}
static double nextBreakDelay(int walk);
static double lostOf(const Judge *x) {
  if (x->idle) return x->idleLost;   // (a move must beat doing nothing: markIdle)
  double own = lostAtOf(x->o.lostAt, x->hold);
  if (extCounts(x)) { double ext = lostAtOf(x->extLost, 0); if (ext > own) own = ext; }
  if (x->hold || own >= 1e299 || own < 0 || waitWalks(x)) return own;
  int walk = lineWalk(x);
  double charge = (double)WALK_FRAMES * walk, delay = nextBreakDelay(walk);
  return own - (delay > charge ? delay : charge);
}
// A LINE'S TIER AS THE ORDER READS IT: a line that must wait for the board ranks with the hold (at the hold's tier, or its own when that
// is lower for the line in progress, waitMax), before the hold itself; a line that clears nothing and does no better than holding
// (idle) right after the hold; the line in progress whose next step is due now is first of its tier. The only place a line's tier is read otherwise than tierOf made it.
static Tier tierView(const Judge *J) {
  Tier t = J->t;
  if (J->wait && !J->hold) { t.tier = J->waitMax ? imax(t.tier, HOLD_TIER) : HOLD_TIER; t.nsub = 1; t.sub[0] = -1; }
  else if (J->idle) { t.tier = HOLD_TIER; t.nsub = 1; t.sub[0] = 1; }
  else if (J->first) { for (int q = imin(t.nsub, MAXSUB - 1); q > 0; q--) t.sub[q] = t.sub[q - 1]; t.sub[0] = -1e300; t.nsub = imin(t.nsub + 1, MAXSUB); }
  return t;
}
// A MOVE MUST BEAT DOING NOTHING: a line that clears nothing comes before the hold only when the engine says it does better than holding
// -- a later loss, a nearer break, or ready for the next block where the hold is not. (Not more life by its panels: a line that clears
// nothing leaves the panels the hold does, and two such boards read at different frames differ only by what landed between.) Being offered is never a
// reason to be played. (markIdle, before every sort of the order: idle lines rank after the hold, tierView)
static int clears(const Judge *J) { return J->apCombo > 0 || J->apChain > 0 || J->apBroke > 0; }
// THE IDEAS A LINE LEAVES (search/ideas.c, several ideas at once): the board it ends on, the attacks one swap from fired there -- asked
// the first time a key compares them, and kept with the line
// (only with no garbage on the board -- under it the list's entries are breaks, and one a swap away is the break search's to find --
// and IDEAS_ASKS lines a decision at most: each is a judging and a settle of every swap, taken from the decision's own time)
#define IDEAS_ASKS 8
static const List *ideaAims;   // (the list they meet: the rank's, decide.c ranked)
static int32_t ideasAsks;      // (asked this decision)
static int ideasOf(const Judge *J0) {
  Judge *J = (Judge *)J0;
  if (!J->ideasAsked) {
    J->ideasAsked = 1;
    if (decF.under || ideasAsks >= IDEAS_ASKS) { J->ideas = -1; return -1; }
    ideasAsks++;
    endNoKeep = 1;
    const Board *e = clockOut() || J->o.dead ? 0 : J->hold ? lineEnd(0, 0, 0) : lineEnd(J->k.seq, J->k.nseq, J->settled);
    endNoKeep = 0;
    J->ideas = e ? ideasOn(e, ideaAims) : -1;
  }
  return J->ideas;
}
// (more ideas ready, both known)
static int moreIdeas(const Judge *x, const Judge *y) { int a = ideasOf(x), b = ideasOf(y); return a >= 0 && b >= 0 && a > b; }
// THE BLOCKS A LINE THROWS (judge.c blocks: every attack its own)
static int thrownOf(const Judge *J) { return J->hold || J->o.dead ? 0 : J->o.j.blocks; }
static int clearsNothing(const Judge *J) { return !J->hold && !clears(J); }
// (A FALLBACK: a line that meets an entry of the mode's list after its first and breaks no garbage. The mode's goals in order (the
// owner: a mode plays its first entry, builds toward it otherwise): the first entry 0, a set-up toward it or a break 1, the hold and
// any other line that fires no fallback 2, then each fallback, 2 + its entry, and last a clear outside the list that breaks nothing --
// the owner: a combo or chain the list does not ask for is the last resort, after every fallback)
static int fallbackOf(const Judge *J) { return !J->hold && J->met > 0 && !(J->apBroke > 0); }
static int goalKeyOf(const Judge *J) {
  if (J->hold) return 2;
  if (J->met == 0 || J->modeFirst) return 0;   // (the mode's first entry, under garbage too where it breaks nothing: the mode is played there)
  // (in finish them every combo the list asks is the mode's goal, never a fallback after the hold -- the owner: the most combos, any combo
  // before a three: the eights and up first, then the rest)
  if (finishAsked() && !J->outside && J->apCombo >= 4) return J->apCombo >= 8 ? 0 : 1;
  if (fallbackOf(J)) return 2 + J->met;
  if (J->outside && !(J->apBroke > 0) && (J->apCombo > 0 || J->apChain > 0)) return 3 + MAXAIMS;
  return J->apBroke > 0 || setupPlay(J->k.play) ? 1 : 2;
}
// (and under garbage, a set-up that breaks none of it is the mode's goal only where its own board outlives the hold's by the time its
// walk takes, as a promise is earned there (extCounts) -- else it is the hold's goal with a walk on it: the owner, no walking far for
// nothing: run 4332, large_garbage 1, 598-842, toward lines lost on the hold's frame put first for the goal, the window walked 23 to 0)
static int goalKeyUnder(const Judge *J) {
  int g = goalKeyOf(J);
  if (g == 1 && decF.under && !J->hold && !(J->apBroke > 0) && rankHoldClock == decQ.b->clock && rankHoldOwn >= 0 &&
      lostAtOf(J->o.lostAt, 0) - rankHoldOwn < (double)WALK_FRAMES * lineWalk(J)) return 2;
  return g;
}
// A WASTED THREE: a line whose clears break nothing and throw nothing (a combo of three, no chain) -- panels spent for no garbage sent
// and none broken
// (a line that breaks garbage beyond the board left alone (apBroke, the judge's count) made its threes on the way to the break -- a block
// let down, the panels in the break's way cleared -- as the rules let a three break garbage (rules.c fits, judge.c breakingThree): not
// wasted. The board's own chain cut short is, whatever the line breaks)
static int cutsShort(const Judge *J);
// A COMBO THE MODE DOES NOT ASK FOR (the owner: combos only where the enemy is topped out -- finish them -- or the board dies without
// one): four or more panels at once, no chain, outside the mode's list
static int comboOutside(const Judge *J) { return !J->hold && J->outside && J->apCombo >= 4 && J->apChain < 2; }
// (the garbage a line breaks as the judge played it: a line whose board is lost while it plays out is ranked on the search's word -- a
// line in progress on what it was begun for -- and that word is no break the judge saw)
static int32_t brokeSeen(const Judge *J) { return J->o.dead ? J->o.j.made.broke : J->apBroke; }
// (the entry of the mode's list a line meets where it asks a combo, MAXAIMS where it meets none that does)
// (THE FINISH: the list asks a combo of eight or more and no chain -- finish them, the enemy near the top: a slab two rows tall or more is
// up to 76 frames of shake it lives through, the 8's pieces are a few cells each -- the owner: big chains near the top give it time)
#define ZIP_WALK 2   // (the actions more a dig may walk for the zip: rank.c the dig zipped)
static int finishAsked(void) {
  int big = 0;
  for (int i = 0; i < theList.n; i++) { const Test *c = &theList.aim[i].combo, *h = &theList.aim[i].chain;
    if (h->op) return 0;
    if (((c->op == OP_GE || c->op == OP_EQ) && c->n >= 8) || (c->op == OP_GT && c->n + 1 >= 8)) big = 1; }   // (an entry of "==8" and up asks one too)
  return big;
}
static int chainPastTwo(const Judge *J) { return J->apChainAll > 2; }   // (the whole chain the line ends in, the board's own falling chain with it -- a hold that lets it run to a 3 included)
static int comboEntry(const Judge *J) { return J->met >= 0 && J->met < theList.n && theList.aim[J->met].combo.op ? J->met : MAXAIMS; }
// (the lowest garbage row of the decision's board, read once a board: search/break.c lowestG)
#define GARBAGE_AWAY 4
// (READIER, rank 1'r: -1 x, 1 y, 0 neither -- a break in reach once the next block lands, else a swap that brings the nearest nearer)
static int readier(const Judge *x, const Judge *y) {
  if (x->readyNext != NOT_ASKED && y->readyNext != NOT_ASKED && (x->readyNext == 1) != (y->readyNext == 1)) return x->readyNext == 1 ? -1 : 1;
  if (!decF.under) return 0;
  int gx = x->k.readyGain > 0 && !x->o.dead, gy = y->k.readyGain > 0 && !y->o.dead;
  return gx == gy ? 0 : gx ? -1 : 1;
}
static int awayFromGarbage(const Judge *J) {
  static LOCAL const Board *forB; static LOCAL int32_t forClock = -1, lowG = 0;
  if (J->hold || !J->k.nseq || brokeSeen(J) > 0 || !decQ.b) return 0;
  if (forB != decQ.b || forClock != decQ.b->clock) { forB = decQ.b; forClock = decQ.b->clock; lowG = lowestG(decQ.b); }
  return lowG < gridLen(decQ.b) && lowG - CR(J->k.seq[0]) >= GARBAGE_AWAY;
}
// (AMID THE GARBAGE FOR NOTHING -- the owner: going in between the garbage is a wasted move unless the line breaks it and finishes breaking
// it; r1393, 3821-3955: swaps up among the slabs that came to nothing): a line that breaks no garbage and swaps a panel with garbage below
// it in its column -- a panel the slabs hold up
static int amidGarbage(const Judge *J) {
  if (J->hold || !J->k.nseq || brokeSeen(J) > 0 || !decQ.b) return 0;
  const Board *b = decQ.b;
  for (int i = 0; i < J->k.nseq; i++) {
    int r = CR(J->k.seq[i]), c = CC(J->k.seq[i]);
    for (int cc = c; cc <= c + 1 && cc <= W; cc++) for (int rr = 1; rr < r && rr < b->nrows; rr++) if (b->p[rr][cc].f[ISGARBAGE]) return 1;
  }
  return 0;
}
// (A BREAK BY A THREE: a line that breaks garbage with no combo of four or more and no chain of two or more. Not topped out, of two that
// both live it is no break to put first -- the owner: a three is for survival only, topped out; the mode's attacks break the garbage)
static int threeBreakOnly(const Judge *J) { return J->apBroke > 0 && J->apCombo < 4 && J->apChain < 2; }
// (A SET-UP OF ANY KIND: a set-up, a lineup, a line toward the next break or nearest the list, a level -- a move that makes the next
// thing, no hold)
static int setupKind(const Judge *J) {
  int p = J->k.play;
  return !J->hold && (p == PLAY_SETUP || p == PLAY_LINEUP || p == PLAY_TOWARD || p == PLAY_NEAREST || p == PLAY_LEVEL || p == PLAY_ZIP);
}
// (A ZIP AMONG SET-UPS: a set-up toward the list, a lineup, a line toward a break or nearest the list, a level before a
// swap that only zips the stack -- unless the zip walks ZIP_NEAR actions fewer: the owner, go toward the zipper and it sets up on its
// own; a set-up across the board walks the window away for what a zip at hand makes. Of two zips, the nearer, then the stack left more
// zipped -- its colours a swap apart, not touching (judge.c spreadOf). -1 x first, 1 y first, 0 neither)
#define ZIP_NEAR 4
static int zipOver(const Judge *x, const Judge *y) {
  int zx = x->k.play == PLAY_ZIP, zy = y->k.play == PLAY_ZIP;
  if (!zx && !zy) return 0;
  if (zx != zy) { const Judge *z = zx ? x : y, *o = zx ? y : x; int first = lineWalk(o) - lineWalk(z) >= ZIP_NEAR ? z == x : o == x; return first ? -1 : 1; }
  // (of two zips, the nearer by ZIP_NEAR actions or more, then the more zipped)
  { int wx = lineWalk(x), wy = lineWalk(y); if (iabs(wx - wy) >= ZIP_NEAR) return wx < wy ? -1 : 1; }
  if (x->o.j.spread != y->o.j.spread) return x->o.j.spread > y->o.j.spread ? -1 : 1;
  return 0;
}
static int breaksFirst(const Judge *J, int lx) { return J->apBroke > 0 && !(lx && !decF.topped && threeBreakOnly(J)); }
static int32_t wasteWhy;   // (the test that called the last line a wasted three: 1 its threes, 2 a combo outside, 3 a chain cut short, 4 a lone clear)
#define ROOM_ROWS 6     // (run 109: above six colours, a stack this tall makes a three room bought)
static int wastesThree(const Judge *J) {
  if (J->hold) return 0;
  // (a line that makes a chain, longer than the board makes alone -- the hold's judging, aloneChain, judged before this is asked, 0
  // where the chain falling makes no more links -- is links, never a three wasted: lost or not, a line lost is ranked by its loss)
  if (J->o.j.whole.chain >= 2 && J->o.j.whole.chain > aloneChain) return 0;
  // (any clear of three that breaks nothing and begins no chain, whatever the line breaks after it -- the owner: never a three unless
  // it follows through; a line dropped before its later break leaves the three made for nothing. A line lost too)
  // (run 109, CHAOS: above six colours, with the stack six rows or more, a three is room bought, not wasted -- matches are scarce, the
  // stack climbs while it waits for a combo, and the first garbage lands on a full board: run 108 8 colours combo s4, 30 panels to 48
  // by frame 516 with the threes put off, lost at 981; four of the run's six losses opened high, 45+ panels at the first garbage)
  // (run 109: off -- 8 colours s3-4 2/8, 12353 frames on average against 14377; the opening still held ~48 panels at the first
  // garbage: at level 10 the stack rises a row a second, more than threes at 8 colours take off)
  if (0 && decQ.b->colors > 6 && panelTop(decQ.b) >= ROOM_ROWS && !cutsShort(J)) return 0;
  if (J->o.j.threes > 0) { wasteWhy = 1; return 1; }
  if (comboOutside(J) && !(J->apBroke > 0)) { wasteWhy = 2; return 1; }   // (a combo the mode does not ask for that breaks nothing: the owner, only where the board dies without it)
  if (cutsShort(J) && !(J->apBroke > 0)) { wasteWhy = 3; return 1; }   // (the board's own chain cut short: the three that began it made for nothing -- unless the
  // line breaks more garbage than the board left alone, its chain and all: a break is never a three for nothing, the chain key weighs it)
  wasteWhy = 4;
  return (J->apCombo > 0 || J->apChain > 0) && !(J->apBroke > 0) && J->apCombo <= 3 && J->apChain <= 1 && thrownOf(J) == 0;
}
static int beatsHold(const Judge *L, const Judge *H) {
  int32_t l = L->o.lostAt, h = H->o.lostAt;
  // (a known death beats holding only when the hold's is one too, and later: two deaths are two frames)
  if (l != NOT_ASKED && (!L->o.dead || H->o.dead) && (l == FOREVER ? h != FOREVER : h != FOREVER && h != NOT_ASKED && l > h)) return 1;
  if (L->o.nearAfter >= 0 && H->o.nearAfter >= 0 && L->o.nearAfter < H->o.nearAfter) return 1;
  // (a break lost no sooner than the hold: the garbage it converts is the board's next panels -- run 491, large_garbage-4, 7531: two
  // breaks lost at 44 put after a hold lost at 44)
  if (L->apBroke > 0 && l != NOT_ASKED && h != NOT_ASKED && (l == FOREVER || (h != FOREVER && l >= h))) return 1;
  if (L->o.ready == 1 && H->o.ready != 1) return 1;
  if (L->readyNext == 1 && H->readyNext != NOT_ASKED && H->readyNext != 1) return 1;
  // (A SET-UP: with no garbage on the board, a line that lives where the hold does and leaves more ideas ready than the hold -- an attack
  // made ready is something done)
  if (!decF.under && L->o.lives && H->o.lives && moreIdeas(L, H)) return 1;
  return 0;
}
static double lostOf(const Judge *x);
// (FLATTENING WHEN THERE IS NOTHING TO DO: a level line -- the stack walked flatter, nothing cleared -- known to do no worse than
// holding beats holding; it is still the last of the lines that do something, tier 4's last)
static int levelsFree(const Judge *L, const Judge *H) {
  if (L->k.play != PLAY_LEVEL || L->o.dead) return 0;
  if (L->o.lives) return 1;
  return !H->o.lives && L->o.lostAt != NOT_ASKED && H->o.lostAt != NOT_ASKED && lostOf(L) >= lostOf(H);
}
// (TWO COLUMNS LOADED AHEAD: a set-up for an eight is not doing nothing where it lives, or is lost no sooner than the
// hold -- the mode that fires it has no time to build it; propose.c twinLines)
// (the time to build one: not topped, no chain going and no slab popping -- under garbage too, on the rows at rest below it: garbage
// on its way lands on top of the rows sorted, and a break is put before it (1'') -- it is built where the bot would otherwise hold)
static int twinTime(int under, int topped) { (void)under; return !topped && decQ.b->chainCounter < 2 && popLeft(decQ.b) <= 0; }
static int loadsFree(const Judge *L, const Judge *H) {
  if (L->k.twin != 2 || L->o.dead || !twinTime(decF.under, 0)) return 0;
  if (L->o.lives) return 1;
  return !H->o.lives && L->o.lostAt != NOT_ASKED && H->o.lostAt != NOT_ASKED && lostOf(L) >= lostOf(H);
}
static void markIdle(Judge **a, int n) {
  const Judge *H = 0;
  for (int i = 0; i < n && !H; i++) if (a[i]->hold) H = a[i];
  for (int i = 0; i < n; i++) a[i]->idle = 0;
  rankHoldClock = decQ.b->clock; rankHoldOwn = H && !H->o.dead && H->o.lostAt != NOT_ASKED ? lostAtOf(H->o.lostAt, 1) : -1;
  double holdLost = H ? lostOf(H) : 0;
  for (int i = 0; i < n; i++) if (H && clearsNothing(a[i]) && !beatsHold(a[i], H) && !levelsFree(a[i], H) && !loadsFree(a[i], H) && !(a[i]->k.readyGain > 0 && !a[i]->o.dead && diesAt(a[i]) >= diesAt(H))) { a[i]->idle = 1; a[i]->idleLost = holdLost - 0.5; }
}
// THE ONE ORDER, key by key: each key decides only between two lines every key before it leaves equal. Survival first, then the list,
// then the kind of line (plans/gambit-next.md 0).
// A LINE THAT CUTS THE BOARD'S OWN CHAIN SHORT: the board left alone makes a chain (the hold's judging, aloneChain) and with the line
// played it makes a shorter one
static int cutsShort(const Judge *J) {
  if (J->hold || !J->apPlayed) return 0;
  if (ownChainBy > 0 && J->o.j.keepsChain >= 0) return !J->o.j.keepsChain && ownChainAsked(ownChainN);   // (judge.c ownChainOf: by the frame its last link comes)
  return aloneChain > 1 && J->apWhole < aloneChain && ownChainAsked(aloneChain);
}
#define FLAT_ROWS 2
#define CHAOS_QUEUE_LIMIT 50   // (the chaos queue limit, as decide.c names it)
#define QUEUE_LAST 6    // (run 105: pieces short of the queue's limit from which the top row is emptied whatever the lines' losses)
#define QUEUE_ROOM 15   // (run 100: pieces short of the queue's limit from which the top row is kept empty)
#define GAP_CELLS 3   // (1'g: three empty cells under the garbage, a column half dug out, or three columns a row each)
#define BREAK_WALK 20   // the actions a break's line is pressed in, as the allowance keeps them (an estimate: a few swaps and their walks)
static int downtime(void) {
  return !decF.under && (decF.next == NOT_ASKED || decF.next > 2 * rankSave) && decQ.b->chainCounter < 2 &&
         (pressAllowance < 0 || pressAllowance >= 2 * BREAK_WALK);
}
#define FOCUS_NEAR 2
#define FOCUS_FAR 5
static int focusBand(const Judge *J) {
  int d = iabs(CR(J->k.seq[0]) - decQ.b->curRow) + iabs(CC(J->k.seq[0]) - decQ.b->curCol);
  return d <= FOCUS_NEAR ? 0 : d >= FOCUS_FAR ? 2 : 1;
}
static int firstWalk(const Judge *J) { return J->hold || !J->k.nseq ? 0 : actionsFor(decQ.b->curRow, decQ.b->curCol, CR(J->k.seq[0]), CC(J->k.seq[0]), HOLDTIGHT + 1); }
// (the cursor's actions over the whole line, swap after swap in the order it is pressed, from where the cursor is)
#define WALK_EARN 6     // the actions more a far line may walk than a nearer one that also attacks
static int32_t carriedSunk = -1;   // (the actions the line in progress was judged to walk in all when played: decide.c carryOf; -1 not known)
// (NOTHING NEW TOLD: what the board was told when the line in progress was played -- the next block's landing frame and how many are on
// their way -- and the frame its own board was judged lost on then (-2 it lived): decide.c carryOf. The same now, and the line still judged
// lost on that frame, the board is the one the line was planned on, and every other line was there to be found when it was chosen)
static int64_t carriedTold = -1, carriedLostAbs = -1;
static int64_t toldNow(void) { return (decF.next == NOT_ASKED ? -1 : (int64_t)decQ.b->clock + decF.next) * 64 + decQ.narr; }
// (and WHERE SOMETHING NEW WAS TOLD, THE PLAN NO WORSE FOR IT -- the owner: a line begun is pressed to its end unless survival needs
// another: the garbage told since leaves the line in progress living, or lost no sooner than it was judged lost when played -- the
// board it was planned on is not the one now, but the line still stands as it did, and survival still puts it down where another
// outlives it or breaks more)
static int carriedSame(const Judge *c) {
  if (carriedSunk < 0 || carriedTold < 0 || c->o.dead) return 0;
  if (toldNow() != carriedTold) {
    if (c->o.lives) return 1;
    return carriedLostAbs >= 0 && c->o.lostAt != NOT_ASKED && c->o.lostAt != FOREVER && (int64_t)decQ.b->clock + c->o.lostAt >= carriedLostAbs;
  }
  if (c->o.lives) return carriedLostAbs == -2;
  return c->o.lostAt != NOT_ASKED && c->o.lostAt != FOREVER && (int64_t)decQ.b->clock + c->o.lostAt == carriedLostAbs;
}
static int lineWalk(const Judge *J) {
  int n = 0, r = decQ.b->curRow, c = decQ.b->curCol;
  for (int i = 0; !J->hold && i < J->k.nseq; i++) { n += actionsFor(r, c, CR(J->k.seq[i]), CC(J->k.seq[i]), HOLDTIGHT + 1); r = CR(J->k.seq[i]); c = CC(J->k.seq[i]); }
  return n;
}
// (a line that walks the input allowance below a break's walk: the next break is pressed out of what is left -- a break's own walk too,
// the window read as the next block finds it; the window already short, the line that spends less of what is left keeps more of the
// next break)
// (THE RESERVE, AS THE NEXT BREAK FINDS IT: the window left once a line is pressed, read at the soonest frame a break can be needed --
// now with garbage on the board, the next block's landing with one on its way -- shown in the telegraph, or queued on the board and
// held off by its own motion (outcome.c holdQueueAt: the frame the engine drops it, the board left alone) -- else EARLIEST_LANDING: an
// attack the enemy makes now is in the telegraph at once and lands that long after -- the actions that leave the window by then counted back. With nobody across
// (time attack, the rules' enemy.none) no break is ever needed and no reserve is kept)
#define EARLIEST_LANDING 151   // (pa-engine.js: GARBAGE_TRANSIT_TIME + GARBAGE_TELEGRAPH_TIME + 1 staged, GARBAGE_DELAY_LAND_TIME landing)
static int ruleNoEnemy;   // (the rule in force asks enemy.none: decide.c)
// (under garbage a reserve is kept only for a break some line of the decision makes: with none offered, the inputs kept are for a break
// that is not there, and the board that holds them builds none -- decide.c sets it before the order is made)
static int breakOffered = 1;
// (runs 173, 175, 176 had the break rules read garbage on the board not yet resting on the stack (decF.under is FACT_US_CONTACT): all
// game 0/8; until garbage first rests 3/8 (gated on gambitHit, which topping sets: it never ran) and 2/8 (own record: no seed-8 opening
// loss). Run 177 kept the run-167 rule below seven rows' worth of panels: 3/8, 141456 frames. Run 178 capped the run-160 rule's count
// of cleared panels at two rows' worth: 3/8. Removed)
// (run 181 had run 176's first-slab break rule on run 180's bot: 3/8, five lost by 2608 -- the break-first rules put breaks of 6 on the
// unrested slab before building, 541-953 chain s7. Removed)
// (run 187 had the creditPair rule alone read the unrested first slab: 4/8, thicc s8 lost the seed-8 opening at 933 all the same.
// Run 188 had 'A BREAK IN HAND BEFORE A PROMISE' alone read it: 2/8, thicc s8 lost at 609. underCredit kept for decide.c's needless-swap
// hold (run 189))
static int32_t restSeen, restClock = -1;
static int garbOnBoard(void) {
  static const Board *atB; static int32_t atClock = -1, on;
  if (decQ.b != atB || decQ.b->clock != atClock) {
    atB = decQ.b; atClock = decQ.b->clock; on = 0;
    for (int r = 1; r < decQ.b->nrows && !on; r++) for (int c = 1; c <= W; c++) if (decQ.b->p[r][c].f[ISGARBAGE]) { on = 1; break; }
  }
  return on;
}
static int underCredit(void) {
  if (decQ.b->clock < restClock) restSeen = 0;   // (a new game)
  restClock = decQ.b->clock;
  if (decF.under) restSeen = 1;
  return decF.under || (decQ.b->colors > 6 && !restSeen && garbOnBoard());
}
static int32_t waitOf(void);
static int cascadeLive(Board *b);   // (propose.c: the board still moving of its own)
// (the window as the next block finds it: at its landing with one on its way, else EARLIEST_LANDING)
static int allowAtLanding(int walk) {
  int32_t t = EARLIEST_LANDING;
  for (int a = 0; a < decQ.narr; a++) if (decQ.arr[a].at >= 0 && decQ.arr[a].at < t) t = decQ.arr[a].at;
  { int32_t q = holdQueueAt(); if (q != NOT_ASKED && q >= 0 && q < t) t = q; }
  return allowLeftAt(t, walk);
}
static int allowAtNeed(int walk) {
  if (decF.under) return allowLeftAt(waitOf(), walk);
  return allowAtLanding(walk);
}
// (GARBAGE ON ITS WAY: shown in the telegraph, or past it and queued on the board -- a one-row block waits there for the board's
// panels to come to rest, pa.c shouldDropGarbage, and a storm's queue is never empty)
static int garbageComing(void) { return decQ.narr > 0 || (decQ.b && decQ.b->ninc > 0); }
// (how far below a break's walk a line leaves the allowance -- a break too, read at the next block's landing: the garbage it breaks is
// gone, the next block is the next break's, and a break that spends the window that one is pressed from saves the board only until it
// lands)
static int digPaid(const Judge *J);
static int reserveLeft(const Judge *J) { int w = lineWalk(J); return J->apBroke > 0 ? allowAtLanding(w) : allowAtNeed(w); }
// (THE RESERVE A LINE LEAVES: a break, two breaks' walks at the next landing; a line that breaks nothing, three breaks' walks -- the
// owner: don't overspend. Garbage comes every 150-250 frames at level 11, a break walks 15-25 actions and the window holds 76 in 600
// frames: what a line that breaks nothing spends is the next breaks', and one break's walk left is a board one block from having none
// (factory 6, run 4574: a walk and three levels lost on the hold's own frame spent 13 of 45, two breaks the rest, dead at 828). The hold's
// walk to the next work keeps the same, front.c AIM_RESERVE)
static int reserveNeed(const Judge *J) { return J->apBroke > 0 ? 2 * BREAK_WALK : 3 * BREAK_WALK; }
static int reserveShort(const Judge *J) { return pressAllowance < 0 || ruleNoEnemy || digPaid(J) ? 0 : imax(0, reserveNeed(J) - reserveLeft(J)); }
// (with no break offered under garbage, a line that digs toward one -- or lets a perched block down onto the stack, the way to the break
// the perch holds off -- may spend the reserve only where the hold loses the board within a
// break's time and the window keeps half a break's walk at the next landing, or the window holds a break's walk again by the time the
// next block can land -- standing longer, the reserve is that
// block's break, and garbage always comes -- and only while the window it leaves pays for its walk again: the break it digs for is pressed out of what is left, and a dig that spends the last of the window digs for a
// break that cannot be pressed; a chain built there may not -- the window it spends is the break's that comes)
static const Judge *rankHold;   // (the decision's hold, set where no line of the decision breaks or lives: decide.c ranked, once every line's readiness has been asked)
static int digsForBreak(const Judge *J) { int p = J->k.play; return p == PLAY_TOWARD || p == PLAY_READY || p == PLAY_NEAREST || p == PLAY_BREAKSEARCH || p == PLAY_BREAKLINE || p == PLAY_ENTRY || p == PLAY_LINEUPBREAK || J->k.letDown; }
static int digPaid(const Judge *J) { int w = lineWalk(J); return decF.under && !breakOffered && digsForBreak(J) && allowAtNeed(w) >= w &&
                                     (allowAtLanding(w) >= BREAK_WALK || (rankHold && !rankHold->o.dead && !rankHold->o.lives && diesAt(rankHold) < rankSave &&
                                                                          allowAtLanding(w) >= BREAK_WALK / 2)); }
static int spendsReserve(const Judge *J) { return pressAllowance >= 0 && !ruleNoEnemy && !digPaid(J) && reserveLeft(J) < reserveNeed(J); }
// (A FLATTEN BETWEEN MOVES -- the owner: it had time to set things up while it waited and did nothing; flatter, it would not have to move
// so far to get things done: a set-up of any kind -- a level, a zip, a lineup -- that walks no more than WALK_EARN actions, wastes no
// three and leaves the input allowance FLAT_KEEP at the next landing: the next break's walk and half another kept, what is over it
// flattens the board the next break is walked on)
#define FLAT_KEEP (3 * BREAK_WALK / 2)
static int flattenFree(const Judge *J) {
  return setupKind(J) && !J->o.dead && J->k.nseq > 0 && pressAllowance >= 0 && lineWalk(J) <= WALK_EARN &&
         allowAtLanding(lineWalk(J)) >= FLAT_KEEP && !wastesThree(J);
}
// THE GARBAGE LET DOWN (the perch -- the owner: break the garbage, set up the break): under garbage with no break offered, the garbage
// sits on its tallest columns alone, only the panels that touch it make a break, and a row lower it touches more of the stack. Where
// the hold's board at rest has the room for it to come down (outcome.c restOf), a line that clears nothing and leaves it nearer
// coming down than the hold does -- a support walked off, or the garbage a row lower. Only one whose own board is lost no sooner than
// the hold's, no walk charged, that keeps the board's own chain as the hold does, and whose walk the input window pays for twice
// over by the frame its board is at rest: the break it sets up is pressed where it was, out of what is left -- a walk that spends
// the last of the window sets up a break that cannot be pressed.
static int32_t restOn(const Judge *J0) {
  Judge *J = (Judge *)J0;
  if (!J->restAsked) { J->restAsked = 1; J->rest = J->hold ? restOf(0, 0, 0, &J->restCan, &J->restAt) : restOf(J->k.seq, J->k.nseq, J->settled, &J->restCan, &J->restAt); }
  return J->rest;
}
// THE WAIT (the owner: the wait is for setting up the next break, not for holding): under garbage with no break offered, a slab
// popping or the board's own chain falling, no break is pressed before the board left alone is at rest (the hold's restAt). The frames
// to it are the cursor's to walk in: the window is read as the next break finds it there (allowAtNeed), and a walk that leaves it a
// break's walk then is charged nothing (lostOf). 0: no wait.
static int32_t waitOf(void) {
  const Judge *H = rankHold;
  if (!decF.under || breakOffered || !H || H->o.dead || !decQ.b || !(popLeft(decQ.b) > 0 || cascadeLive(decQ.b))) return 0;
  restOn(H);
  return imax(0, H->restAt);
}
// (A LINE THE WINDOW LEAVES NO BREAK: the actions it leaves hold a break's walk again only after its board is lost -- the window's
// oldest presses leave it too late, core/nodes.h allowWait -- so no break can be pressed against the loss it buys)
static int windowDead(const Judge *J) {
  if (pressAllowance < 0 || nWinAges < 0 || ruleNoEnemy || J->hold || J->o.lives) return 0;
  int32_t w = allowWait(0, lineWalk(J), BREAK_WALK);
  return w < 0 || w > diesAt(J);
}
// (THE NEXT BREAK PUT OFF: the frames later the window holds a break's walk again (BREAK_WALK) once the line's actions are spent than it
// would with none spent -- core/nodes.h allowWait. A window near its end makes every action dear: the owner, efficiency is key. 0 where
// the window is not said)
static double nextBreakDelay(int walk) {
  if (pressAllowance < 0 || nWinAges < 0 || ruleNoEnemy || walk <= 0) return 0;
  int32_t d0 = allowWait(0, 0, BREAK_WALK), d1 = allowWait(0, walk, BREAK_WALK);
  if (d0 < 0) d0 = winLen;
  if (d1 < 0) d1 = winLen;
  return d1 > d0 ? d1 - d0 : 0;
}
static int waitWalks(const Judge *J) { return pressAllowance >= 0 && waitOf() > 0 && allowAtNeed(lineWalk(J)) >= BREAK_WALK; }
// (and the walk that does not: a line that breaks nothing and leaves the window under a break's walk at rest)
static int waitSpends(const Judge *J) { return pressAllowance >= 0 && waitOf() > 0 && !J->hold && !(J->apBroke > 0) && allowAtNeed(lineWalk(J)) < BREAK_WALK; }
static int letsDown(const Judge *J) {
  const Judge *H = rankHold;
  if (!decF.under || breakOffered || !H || J->hold || J->o.dead || H->o.dead || clears(J) || J->o.j.clearedPanels > 0) return 0;
  if (lostAtOf(J->o.lostAt, 0) < lostAtOf(H->o.lostAt, 1)) return 0;
  if (cutsShort(J) || J->o.j.chainAll < H->o.j.chainAll) return 0;
  if (restOn(H) < 0 || !H->restCan || restOn(J) < 0 || restOn(J) >= restOn(H)) return 0;
  int walk = lineWalk(J);
  return pressAllowance < 0 || allowLeftAt(imax(0, J->restAt), walk) >= walk;
}
// A SWAP TOWARD AN EIGHT THAT COSTS NOTHING: a leaves the board nearer a two-column eight than b (outcome.c twinAfter, the one distance
// the set-ups are proposed by too: propose.c twinScan to TWIN_REACH), is lost no sooner (or lives), and leaves the window its reserve --
// the set-up built between moves, of what is spare: a swap nearer is a swap nearer
static int nearerEight(const Judge *a, const Judge *b) {
  if (a->o.twinAfter < 0 || b->o.twinAfter < 0 || a->o.twinAfter >= b->o.twinAfter || b->o.twinAfter >= 99 || spendsReserve(a)) return 0;
  return a->o.lives || (!b->o.lives && diesAt(a) >= diesAt(b));
}
// (x presses every swap y does, and more, its more chosen for what it does -- a line with work on its way, whose swap clears, brings the
// break nearer or joins colours, or a route, whose second line makes something: y's swaps all among x's, in their order)
static int holdsLine(const Judge *x, const Judge *y) {
  if (!(x->k.way || x->k.route || x->k.pair) || x->hold || y->hold || x->k.nseq <= y->k.nseq || !y->k.nseq) return 0;
  int j = 0;
  for (int i = 0; i < x->k.nseq && j < y->k.nseq; i++) if (x->k.seq[i] == y->k.seq[j]) j++;
  return j == y->k.nseq;
}
// (TRIES: the breaks the next decisions have the time for, a break's time each -- two lines that neither live survive alike when they
// leave as many, or three or more each: run 446, build, a line lost at 266 taken over one lost at 385 that broke more, two tries against
// three. Past three the material decides: run 451, the later loss taken there too, spent the panels -- large_garbage's material under
// garbage 19 where it was 23 -- finish 15 against 17)
#define NEAR_LOSS 3
static int32_t raceOn;   // (the enemy topped out: the game is the race of two boards to the top -- decide.c read)
static int32_t livedPrev;   // (the last decision offered a line, not the one in progress, that lives: answer.c)
static int32_t inOpener;   // (the opener still playing: its chain is the opener's to build -- decide.c read)
#define NEAR_GAIN 30
static int lostAlike(const Judge *x, const Judge *y) {
  // (never alike near the end where the board itself is lost a break's time apart: the walk's charge is a preference, not a loss --
  // r1362, 16608: a cut lost at 158 over a line lost at 414, alike on the walk charged; r1351, 478-513: a ready lost at 160 over 315)
  // (each line's own loss: no walk charged, and no credit for moves after it -- a promise is no loss told: set 86 combo_storm 1, 6846, a
  // toward lost at 218 credited 494 put a break in progress lost at 242 down, the promise never kept and the board lost at 7141)
  { double dx = lostAtOf(x->o.lostAt, x->hold), dy = lostAtOf(y->o.lostAt, y->hold), dlo = dx < dy ? dx : dy, dhi = dx < dy ? dy : dx;
    if (!x->o.lives && !y->o.lives && dlo >= 0 && dhi < 1e299 && dlo < NEAR_LOSS * rankSave && dhi - dlo >= rankSave) return 0; }
  double lo = lostOf(x) < lostOf(y) ? lostOf(x) : lostOf(y), hi = lostOf(x) < lostOf(y) ? lostOf(y) : lostOf(x);
  int tlo = (int)(lo / rankSave), thi = (int)(hi / rankSave);
  // (run 200: above six colours under garbage, alike only within a quarter of a break's time -- run 199 8 colours, the line put first
  // over one lost later, both breaking the same: combo s22 12984 a break lost at 241 over a convert at 297 (20 broken each), thicc s21
  // 7959 225 over an entry at 308 (12 each); the rules after alike kept the sooner loss, lost at 13227 and 8428)
  if (decQ.b && decQ.b->colors > 6 && decF.under) return lo >= rankSave && (tlo >= 3 || hi - lo < rankSave / 4);
  return lo >= rankSave && (tlo == thi || tlo >= 3 || hi - lo < rankSave);   // (or lost less than a break's time apart: the later buys no break more)
}
// (LOST ALIKE AT THE FINISH: within one break's time of each other -- the finish's own keys trade the board's life for a combo or a
// shorter chain only where the trade costs less than a break; three breaks' time and more apart is a break the next decision loses)
static int finishAlike(const Judge *x, const Judge *y) {
  // (never alike where the boards themselves are lost a break's time apart near the end: as lostAlike -- the walk's charge and a promise
  // are preferences, not a loss)
  { double dx = lostAtOf(x->o.lostAt, x->hold), dy = lostAtOf(y->o.lostAt, y->hold), dlo = dx < dy ? dx : dy, dhi = dx < dy ? dy : dx;
    if (!x->o.lives && !y->o.lives && dlo >= 0 && dhi < 1e299 && dlo < NEAR_LOSS * rankSave && dhi - dlo >= rankSave) return 0; }
  double lo = lostOf(x) < lostOf(y) ? lostOf(x) : lostOf(y), hi = lostOf(x) < lostOf(y) ? lostOf(y) : lostOf(x);
  return lo >= rankSave && hi - lo < rankSave;
}
// (THE KEY THAT DECIDED: the line of the last return compareJudged took -- answer.c logs it for the line played over one lost later)
static int32_t cmpKey;
// (BOUGHT WITH THE PANELS: the later loss of a line that clears panels below the floor and breaks nothing is stop time, bought with the
// panels the next break is made from. Beside one that spends none and leaves the next decision a break's time (rankSave), the two
// survive alike, and the list puts the one that keeps its panels first -- under garbage too: a chain fired for its stop leaves the
// garbage where it is and fewer panels to break it with)
// (THE NEXT BREAK'S PANELS: under garbage below the floor, the panels a break leaves under the lowest garbage once everything shown has
// landed -- what the next break is made of; -1 not known)
static int32_t panelsLeft(const Judge *J) { return J->o.j.readyMat >= 0 ? J->o.j.readyMat : J->o.matLeft; }
static int shortOfPanels(const Judge *x, const Judge *y) {
  return decF.under && decF.belowFloor && x->apBroke > 0 && y->apBroke > 0 && panelsLeft(x) >= 0 && panelsLeft(y) >= 0 &&
         iabs(panelsLeft(x) - panelsLeft(y)) >= 3;
}
// (the break's time a line that breaks garbage leaves is read on its board as the engine has it, no walk charged: the judge pressed
// the walk when its loss was judged, and a break across the board, lost a break's time off or more, is the board kept -- the charge
// is the order's preference for the nearer, never frames the board does not have)
static double leftBy(const Judge *J) { return J->apBroke > 0 ? lostAtOf(J->o.lostAt, J->hold) : lostOf(J); }
static int boughtWithPanels(const Judge *x, const Judge *y) {
  double lo = leftBy(x) < leftBy(y) ? leftBy(x) : leftBy(y);
  if (lo >= rankSave && x->spends != y->spends && (lostOf(x) > lostOf(y) ? x : y)->spends) return 1;
  // (and two breaks below the floor: the later loss bought by spending a three's worth of panels more, within two breaks' time -- a board
  // short of panels that spends them for a little more life finds no next break)
  if (lo >= rankSave && shortOfPanels(x, y)) {
    const Judge *late = lostOf(x) > lostOf(y) ? x : y, *early = late == x ? y : x;
    if (panelsLeft(late) < panelsLeft(early) && lostOf(late) - lostOf(early) < 2 * rankSave) return 1;
  }
  return 0;
}
// (A COMBO OF FOUR OUTSIDE THE LIST: panels spent for a small piece the mode does not ask for -- the owner: a last resort)
static int wastesFour(const Judge *J) { return !J->hold && !J->o.dead && J->outside && J->o.j.made.combo == 4 && J->o.j.made.chain < 2; }
// (THE CHAIN FALLING GROWN: the longest chain the mode's list asks -- an entry of "or more" its target, the length it asks at least: a
// link past the target is presses and panels the list does not ask for)
#define BACK_CALM 1   // (breaks' time, rankSave: a loss nearer than this, the line that does best plays whether it swaps back or not)
static int32_t chainReach(const Judge *J) { return J->o.dead ? 0 : J->o.j.chainAll; }
static int32_t opNeed;   // (the chain the opener still needs to reach its eight, decide.c; 0 with the opener not in force)
static int32_t needKept, needLost;   // (the log's need=: comparisons 1'L left to the opener's chain, and those it did not, the break's chain as judged)
// (A 2x ITS LINE DOES NOT CONTINUE: the chain the line makes ends at two -- read on the judge's count whether or not the board is lost
// while the line plays out: a line on a board lost later makes its 2x all the same)
static int shortChain(const Judge *J) { int32_t reach = J->o.dead ? imax(J->apChain, J->o.j.chainAll) : chainReach(J); return !J->hold && J->apChain >= 2 && reach == 2; }
// (THE PLAN IN PROGRESS STANDS WHILE IT STANDS THE HORIZON: lives is a line on the board's life -- HORIZON frames from now and REST after
// its last swap -- and a line near it is judged on one side of it one decision and the other the next, as the horizon moves on and garbage
// is told. The line in progress keeps its place while it stands HORIZON frames from now, so it is put down only where it fails, not where
// the next decision's horizon reaches a frame further: every swap of a plan put down is a move for nothing)
static int goalLine(const Judge *J) { return !J->hold && (J->met == 0 || J->modeFirst); }
// (THE FINISH UNDER GARBAGE -- the owner: in finish them a combo only where it can kill, and the enemy is where it can: an attack the
// list asks, a combo of four or more with at most a 2x, that leaves the input allowance a break's walk at the next landing -- under
// garbage it is no stall, the attack is the mode's whole aim)
static int finishFree(const Judge *J) {
  return finishAsked() && goalLine(J) && !J->o.dead && J->apCombo >= 4 && J->apChainAll <= 2 && J->k.nseq > 0 &&
         (pressAllowance < 0 || allowAtLanding(lineWalk(J)) >= BREAK_WALK);
}
// (OFF THE MODE: a line whose attack the mode's list does not ask -- a chain where it asks combos, a 2x or a chain past its length, a combo
// of four or more it does not ask -- the board's own chain going on counted, as every line has it alike)
#define OFF_MODE_LIFE 2   // (breaks' time, rankSave: the life a line that keeps to the mode needs for the off-mode one to go after it)
// (in finish them a combo of four or more with at most a 2x is the mode's, never off it -- set 86 combo_storm 1, 1073-1107: the hold
// over a 6 with its 2x, both living)
static int offMode(const Judge *J) {
  if (finishAsked() && !J->hold && J->apCombo >= 4 && J->apChainAll <= 2 && !J->outside) return 0;
  // (nor a line whose chain is the board's own falling, no longer -- every line on the board carries it: set 86 combo_storm 1, 3734: a break
  // kept to 576 put after the line in progress lost at 372, both on the board's own 5x)
  if (finishAsked() && !J->hold && J->apChainAll <= imax(2, aloneChain) && !(J->o.j.whole.combo >= 4 && J->outside)) return 0;
  return !J->hold && !J->o.dead && !J->lengthens && J->met < 0 && (chainReach(J) >= 2 || J->o.j.whole.combo >= 4);
}
#define FINISH_SAFE (2 * HORIZON)   // (frames from now a finish board is safe at: rank.c, key 1)
#define FINISH_8_LIFE 2   // (the breaks' time (rankSave) an eight's board must still stand, its next moves played, to be fired over a line that lives longer)
static double diesAt(const Judge *x);
// (a combo of four or more, its chain two at most, beside a line that is lost no later than it)
// (and beside a bigger combo too -- set 86 combo_storm 1, 1953: an 8 lost at 299 passed over for a 4 in progress lost at 252)
static int finishComboBy(const Judge *c, const Judge *o) { return !c->hold && !c->o.dead && c->apCombo >= 4 && c->apChainAll <= 2 && (!(o->apCombo >= 4) || c->apCombo > o->apCombo) && diesAt(c) >= diesAt(o); }
#define FINISH_SAFE_ON 0   // (the safe board's credit: 0 off -- a board lost later than FINISH_SAFE is ranked by its loss)
// (A BIGGER COMBO AT THE FINISH: a combo of four or more with at most a 2x, bigger than the other line's and lost no sooner -- never put
// after it for the reserve or the cursor's place: set 86 combo_storm 1, 1219-1282, a 6 lost later passed over three times for a 4)
// (A COMBO THE FINISH ASKS, OVER THE ALLOWANCE'S RESERVE: sp a combo of four or more within the list with at most a 2x, beside kp that
// makes no combo as big with as short a chain, lost no sooner (or living) -- the owner: any combo beats a 3; the combo is the break itself)
static int finishAsks(const Judge *sp, const Judge *kp) {
  // (its chain held against the other's: the board's own chain falling is sent by both -- set 86 combo_storm 1, run 4086, 7187-7241: an 8
  // lost at 408 that left the board's 3x falling put after a 4 lost at 366 that sent the same 3x, for the reserve)
  return finishAsked() && !sp->hold && !sp->outside && sp->apCombo >= 4 && sp->apChainAll <= imax(2, kp->hold ? 0 : kp->apChainAll) &&
         !(!kp->hold && !kp->outside && kp->apCombo >= sp->apCombo && kp->apChainAll <= sp->apChainAll) &&
         (sp->o.lives || (!kp->o.lives && diesAt(sp) >= diesAt(kp)));
}
static int finishBigger(const Judge *a, const Judge *b) {
  return finishAsked() && !a->hold && !a->o.dead && !a->outside && a->apCombo >= 4 && a->apChainAll <= 2 && a->apCombo > (b->hold ? 0 : b->apCombo) && diesAt(a) >= diesAt(b);
}
static int finishSafe(const Judge *J) { if (!FINISH_SAFE_ON || J->o.dead || J->o.lives) return 0; double d = diesAt(J); return d >= FINISH_SAFE && d < 1e299; }
// (A COMBO SAFE BESIDE A CHAIN -- the owner: survive by breaking garbage with combos, not chains: in finish them, a combo the list asks
// (four or more, at most a 2x) whose board is lost HORIZON or more from now -- a break's time and more for the next decision -- survives
// as one that lives does beside a line whose chain runs past two; the shorter chain then decides, 1'c)
static int finishSafeCombo(const Judge *J, const Judge *o) {
  if (!FINISH_SAFE_ON || !finishAsked() || J->hold || J->o.dead || J->o.lives || J->outside || J->apCombo < 4 || chainPastTwo(J) || !chainPastTwo(o)) return 0;
  double d = diesAt(J); return d >= HORIZON && d < 1e299;
}
// (the horizon's credit only for a line in progress the window can still press: its walk within the actions the window has left --
// set 86 combo_storm 1, 2718-2775: a line of five swaps across the board kept on the credit with five actions left, over a break lost
// at 478; it was put down at 2805 with the board lost in 20)
static int lineWalk(const Judge *J);
static int livesOn(const Judge *J) {
  if (J->o.lives) return 1;
  if (!(J->carried && !J->o.dead && J->o.lostAt != NOT_ASKED && J->o.lostAt >= HORIZON)) return 0;
  return pressAllowance < 0 || lineWalk(J) <= pressAllowance;
}
// (A BOARD THAT OUTLIVES ANOTHER: c's is lost -- past the horizon or not -- and o's lives, stands the whole judging, or is lost a break's
// time (rankSave) or more later, on the frame each is lost, no walk charged; a loss not asked outlives nothing)
static int outlives(const Judge *o, const Judge *c) {
  double dc = diesAt(c), dn = diesAt(o);
  if (c->o.lives || dc < 0 || dc >= 1e299) return 0;
  if (o->o.lives || dn >= 1e300) return 1;
  return dn >= 0 && dn < 1e299 && dn - dc >= rankSave;
}
// (THE LINE IN PROGRESS PLAYED OUT ON A CALM BOARD -- the owner: no changing minds, no wasted moves: no garbage on the board and none on
// its way, nothing can land that the judge has not seen, so a line in progress lost past the horizon that still stands NEAR_LOSS breaks'
// time is finished before the line that lives beside it is begun: the board has that line's time once this one is done, and every
// swap pressed of a line put down is the window spent for nothing)
static int calmKept(const Judge *c, const Judge *o) {
  return !decF.under && !garbageComing() && c->carried && !c->hold && !c->o.dead && o->o.lives && diesAt(c) >= NEAR_LOSS * rankSave && diesAt(c) < 1e299;
}
// THE SURVIVAL CREDIT of two lines, each beside the other: lives, or counted as living (the horizon, the finish's safe board), and
// where it is taken back -- compareJudged's first step, and the log's cr=
static void creditPair(const Judge *x, const Judge *y, int *lxo, int *lyo) {
  int lx = livesOn(x), ly = livesOn(y);
  // (the horizon's credit is no life beside a board that outlives it: the line in progress lost past the horizon, beside a line that
  // lives or is lost a break's time later, is a line that is lost -- death is never an option)
  // (run 210: above six colours, nor beside a board lost a quarter of a break's time later -- as lostAlike there. Run 208 8 colours chain
  // s21 2664: a carry_wait lost at 232 kept by the horizon credit over a convert lost at 319 (1. lives before does not), lost at 3201)
  #define OUT_Q(A, B) (decQ.b->colors > 6 && !(A)->o.dead && ((A)->o.lives || diesAt(A) - diesAt(B) >= rankSave / 4))
  if (lx && !x->o.lives && (outlives(y, x) || OUT_Q(y, x)) && !calmKept(x, y)) lx = 0;
  if (ly && !y->o.lives && (outlives(x, y) || OUT_Q(x, y)) && !calmKept(y, x)) ly = 0;
  // (nor, under garbage, the credit of a line that breaks nothing beside a break lost within a break's time of it: the break is the way
  // out the board has, the horizon is a promise -- r1363, 14839: a 4x stall in progress lost at 296 kept over a break lost at 282, and no
  // break offered again; r1362, 16120)
  if (lx && !x->o.lives && decF.under && brokeSeen(x) <= 0 && !y->hold && !y->o.dead && y->apBroke > 0 && diesAt(x) - diesAt(y) < rankSave) lx = 0;
  if (ly && !y->o.lives && decF.under && brokeSeen(y) <= 0 && !x->hold && !x->o.dead && x->apBroke > 0 && diesAt(y) - diesAt(x) < rankSave) ly = 0;
  // (IN FINISH THEM, A BOARD THAT STANDS TWICE THE HORIZON IS SAFE -- the owner: survival is not pushed where the board is not dying: a
  // line whose board is lost FINISH_SAFE or more from now, its next moves played (diesAt: its own loss or the life after it), survives as
  // one that lives does, and the combos decide between them)
  if (finishAsked()) { if (!lx && (finishSafe(x) || finishSafeCombo(x, y))) lx = 1; if (!ly && (finishSafe(y) || finishSafeCombo(y, x))) ly = 1; }
  // (and the line in progress's horizon credit is no life beside a combo lost no sooner than it: the combo is the attack)
  if (finishAsked()) {
    if (lx && !x->o.lives && !finishSafe(x) && finishComboBy(y, x)) lx = 0;
    if (ly && !y->o.lives && !finishSafe(y) && finishComboBy(x, y)) ly = 0;
    // (nor beside a combo that sends no chain lost within a break's time of it, where the line in progress runs past 2x -- the owner:
    // finish them sends combos, not chains; set 86, 517 decisions of run 4046 a chain past 2x kept by its horizon credit over a line
    // with none as long lived)
    #define PURE_COMBO(J) (!(J)->hold && !(J)->o.dead && (J)->apCombo >= 4 && (J)->apChainAll < 2)
    if (lx && !x->o.lives && !finishSafe(x) && chainPastTwo(x) && PURE_COMBO(y) && finishAlike(x, y)) lx = 0;
    if (ly && !y->o.lives && !finishSafe(y) && chainPastTwo(y) && PURE_COMBO(x) && finishAlike(x, y)) ly = 0;
    // (and beside any line that runs no chain past 2x and is lost no sooner -- set 86 combo_storm 1, 1422-1486: a 6x in progress lost at
    // 328 kept over a break with none lost at 351)
    #define NO_SLAB(J) (!(J)->hold && !(J)->o.dead && !chainPastTwo(J))
    if (lx && !x->o.lives && !finishSafe(x) && chainPastTwo(x) && NO_SLAB(y) && diesAt(y) >= diesAt(x)) lx = 0;
    if (ly && !y->o.lives && !finishSafe(y) && chainPastTwo(y) && NO_SLAB(x) && diesAt(x) >= diesAt(y)) ly = 0;
    #undef NO_SLAB
    #undef PURE_COMBO
    // (and beside any line lost no sooner at all -- the horizon's credit is the line in progress's alone, so a line lost later past the
    // horizon too was put after it; set 86 combo_storm 1, 62 decisions of run 4076, 1437: a 4 in progress lost at 476 over a line lost at 524)
    if (lx && !x->o.lives && !finishSafe(x) && !y->o.dead && diesAt(y) >= diesAt(x) && diesAt(y) < 1e299) lx = 0;
    if (ly && !y->o.lives && !finishSafe(y) && !x->o.dead && diesAt(x) >= diesAt(y) && diesAt(x) < 1e299) ly = 0;
  }
  *lxo = lx; *lyo = ly;
}
static int32_t chaosOpenQuiet;   // (decide.c: the opening -- before garbage first comes)
static int32_t chaosOpenHigh;    // (decide.c: the opening above six colours with the stack seven rows or more)
static int compareJudged(const Judge *x, const Judge *y) {
  int lx, ly; creditPair(x, y, &lx, &ly);
  // (run 87, CHAOS, SCARCE FUEL UNDER GARBAGE IS NOT SPENT ON ATTACK: under garbage with fewer than five rows of panels under it
  // (materialOn < 5 x W), of two lines that both live and break no garbage, the one clearing fewer panels first -- what is under the
  // garbage is the next break's material, and Training's garbage is scripted, so attack buys nothing. Only among living lines (run 49's
  // rule, among dying ones, cost seeds 3-4 two early losses). Run 85 level 9 chain s8: an extend clearing 12 panels breaking none at 28
  // panels, 11-17 after, lost at 1282)
  // (run 90: off -- L9 seeds 7-8 7/8 with it (6/8 without), but on the L10 gate seeds 3-4 7/8 where the gate's bot had 8/8: not kept)
  // (run 138: on again above six colours only -- the gate it cost a game on is six colours; at 8 colours the losses starve under garbage
  // (runs 130-137: 9-36 panels, 15-25 clears a minute breaking nothing), and the stop such a clear buys halts the rise that brings panels)
  // (run 139: off again -- run 138 with it above six colours 3/8 against 6/8)
  if (0 && decQ.b->colors > 6 && decF.under && x->o.lives && y->o.lives && x->apBroke <= 0 && y->apBroke <= 0 &&
      materialOn(decQ.b) < 5 * W && x->o.j.clearedPanels != y->o.j.clearedPanels)
    return (cmpKey = __LINE__, (x->o.j.clearedPanels < y->o.j.clearedPanels ? -1 : 1));
  // (run 140, CHAOS, ABOVE SIX COLOURS, A STARVED BOARD'S BREAK PAYS FOR ITSELF: under garbage below five rows of panels, of two living
  // lines that both break garbage, the one whose cells broken less panels cleared is a row (W) or more better first -- a broken cell
  // comes back as one panel, a cleared panel is gone. Run 139 8 colours thicc s7, 645-765: lines judged living cleared 12-15 panels to
  // break 6 cells, 27 -> 14 panels, then 8-11 under the next slab, lost at 911)
  if (decQ.b->colors > 6 && decF.under && x->o.lives && y->o.lives && x->apBroke > 0 && y->apBroke > 0 && materialOn(decQ.b) < 5 * W) {
    int32_t nx = x->apBroke - x->o.j.clearedPanels, ny = y->apBroke - y->o.j.clearedPanels;
    if (iabs(nx - ny) >= W) return (cmpKey = __LINE__, (nx > ny ? -1 : 1));
  }
  // (run 80, CHAOS, TOPPED WITH GARBAGE WAITING, DIG: nothing waiting drops while anything is in the top row (Stack:shouldDropGarbage,
  // panels_in_top_row first), and fifty waiting is the loss whatever the health. Topped with pieces waiting, of two lines judged alike,
  // the one breaking more garbage first -- the room under the top row is what lets the queue drop. Run 79 level 7 combo s1: topped all
  // game under its own garbage and living on stop (100-390 frames, never a point of health lost), 25 waiting through a 150-frame hold,
  // none dropped; five of eight lost to the queue at full health (30))
  // (run 81: off -- level 7 2/8 with it too, five losses to the queue; digging first does not make the room either at level 7)
  if (0 && decF.topped && decQ.b->ninc > 0 && x->o.lives == y->o.lives) {
    int32_t bx = imax(0, x->apBroke), by = imax(0, y->apBroke);
    if (bx != by) return (cmpKey = __LINE__, (bx > by ? -1 : 1));
  }
  // (run 100, CHAOS, THE QUEUE NEAR ITS LIMIT: with the queue's limit in force (margin off: fifty waiting is the loss whatever the
  // health, Stack.lua) and QUEUE_ROOM or fewer pieces short of it, of two lines that do not die before a break's time, the one leaving
  // the top row empty first -- nothing waiting drops while anything rests there (Stack:shouldDropGarbage), so a board kept topped on
  // stop time only lets the queue grow. Run 99 L11 vs 11/11, 8 colours: both games lost to the queue at full health (queue 38-46 on
  // average over the last 1200 frames, stop 86-115))
  // (run 105: and within QUEUE_LAST of fifty whatever either is judged lost at -- the health is planned as one, but a piece dropped on a
  // topped board costs health, never the game, where fifty waiting is the game: run 104 chain s2 and combo s2 lost to the queue at
  // 21591 and 21485 with health 13 and 6 left, boards of ~50 panels kept topped)
  // (run 106: off while the searches' shape is measured again -- run 105 with it 1/8)
  if (0 && decQ.b->marginTime == 1 && decQ.b->ninc >= CHAOS_QUEUE_LIMIT - QUEUE_LAST && x->o.j.topRow != y->o.j.topRow && !x->o.dead && !y->o.dead)
    return (cmpKey = __LINE__, (x->o.j.topRow ? 1 : -1));
  // (run 142: above six colours from twenty waiting, not thirty-five -- the 8-colour backlog losses died with 24-36 waiting (runs 135-141:
  // insane s7/s8, combo s8, thicc s8, queue 24-31 on average over their last 1200 frames): the queue piled while the top row was taken
  // and then came down at once)
  // (run 142 kept it from twenty waiting above six colours: 2/8, 91868 frames -- back to thirty-five)
  if (decQ.b->marginTime == 1 && decQ.b->ninc >= CHAOS_QUEUE_LIMIT - QUEUE_ROOM && x->o.j.topRow != y->o.j.topRow &&
      !x->o.dead && !y->o.dead && (x->o.lives || diesAt(x) >= rankSave) && (y->o.lives || diesAt(y) >= rankSave))
    return (cmpKey = __LINE__, (x->o.j.topRow ? 1 : -1));
  // (run 117, CHAOS, ABOVE SIX COLOURS, NO CANYON DUG FOR NOTHING: under garbage, of two lines that break the same garbage -- none -- the
  // one that digs W or more empty cells more under the garbage (judge.c gapOf, against the board as it stands) goes after one that digs
  // under half of that, unless the other is lost a break's time sooner. Run 115 8 colours combo s5, 3959-4382: 5x and 6x chains breaking
  // nothing emptied columns 1-3 from row 4 to 9 under garbage resting on the edge towers, lost at 4491)
  // (run 153 measured it off on the wider search: 4/8 against 5/8 -- back on)
  if (decQ.b->colors > 6 && decF.under && !x->o.dead && !y->o.dead && imax(0, x->apBroke) == 0 && imax(0, y->apBroke) == 0 &&
      x->o.j.gap >= 0 && y->o.j.gap >= 0) {
    // (run 135 added the open side a line digs beside a slab (sideDig): 5/8 against 6/8 -- removed)
    int32_t g0 = gapOf(decQ.b), dx = x->o.j.gap - g0, dy = y->o.j.gap - g0;
    int xd = dx >= W && dy < W / 2, yd = dy >= W && dx < W / 2;
    if (xd || yd) { const Judge *dig = xd ? x : y, *o = xd ? y : x;
      // (run 227: unless the dig outlives it by a quarter of a break's time, as the other rules above six colours -- run 226 8 colours combo
      // s22 9918-9947 (24 queued): the hold lost at 201, 187, 172 kept over a dig lost at 258, lost at 10343)
      if (o->o.lives || diesAt(o) + rankSave / 4 > diesAt(dig)) return (cmpKey = __LINE__, (xd ? 1 : -1)); }
  }
  // (run 119, CHAOS, ABOVE SIX COLOURS, NO LONG CHAIN FOR NOTHING UNDER GARBAGE: of two lines, one whose whole chain (the board's falling
  // chain with it) runs past three links breaking no garbage goes after one whose chain stays at three or under, unless that one is lost
  // a break's time sooner -- a 2x or 3x buys the stop; past it a chain at 8 colours only digs the columns out from under the garbage.
  // Run 117 8 colours insane s6, 12641-12943: a 7x then 8x breaking nothing emptied columns 0-3 under garbage left on the right towers,
  // lost at 13029)
  // (run 120: and with garbage on its way too -- run 119 chain s5, a 5x breaking nothing at 472-568 before the first slab, lost at 660)
  // (run 121: off -- run 119 4/8, run 120 (garbage on its way too) about 2/8; run 117 without it 5/8)
  if (0 && decQ.b->colors > 6 && (decF.under || decQ.narr > 0 || decQ.b->ninc > 0) && !x->o.dead && !y->o.dead) {
    int lx4 = x->o.j.chainAll > 3 && x->apBroke <= 0, ly4 = y->o.j.chainAll > 3 && y->apBroke <= 0;
    if (lx4 != ly4) { const Judge *lng = lx4 ? x : y, *o = lx4 ? y : x;
      if (o->o.j.chainAll <= 3 && (o->o.lives || diesAt(o) + rankSave > diesAt(lng))) return (cmpKey = __LINE__, (lx4 ? 1 : -1)); }
  }
  // (run 118, CHAOS, ABOVE SIX COLOURS, A STARVED BOARD BREAKS CHEAPLY: under garbage with fewer than four rows' worth of panels (4 x W),
  // of two lines that break the same garbage and live or are lost alike, the one clearing fewer panels first -- each panel spent is
  // one the next break lacks. Run 117 8 colours insane s5: 16-25 panels from 1264 to the loss at 1957, breaks of 6 clearing 6 each)
  // (run 118: off -- 8 colours s5-6 about 2/8 with it, run 117 5/8)
  if (0 && decQ.b->colors > 6 && decF.under && panelsOn(decQ.b) < 4 * W && (lx || lostAlike(x, y)) &&
      imax(0, x->apBroke) == imax(0, y->apBroke) && x->o.j.clearedPanels != y->o.j.clearedPanels)
    return (cmpKey = __LINE__, (x->o.j.clearedPanels < y->o.j.clearedPanels ? -1 : 1));
  // (run 55, CHAOS, THE OPENING KEEPS ITS PANELS: before garbage first comes (the opening, decide.c), of two lines that both live and
  // break no garbage, the one clearing fewer panels first -- the stack rises on its own until then and the first garbage is broken with
  // what is kept; Training's garbage is scripted, so attack before it buys nothing. Run 52 insane s5: entries from frame 192 spent the
  // 30 opening panels to 17 by 588, panels 9-25 after, lost at 4463 (and 1667, 2124 in runs 53, 34))
  // (run 53's version -- only while a raise was wanted -- never acted: the opening's raise height at level 10 is already there)
  if (chaosOpenQuiet && x->o.lives && y->o.lives && x->apBroke <= 0 && y->apBroke <= 0 &&
      x->o.j.clearedPanels != y->o.j.clearedPanels)
    return (cmpKey = __LINE__, (x->o.j.clearedPanels < y->o.j.clearedPanels ? -1 : 1));
  // (run 160, CHAOS, ABOVE SIX COLOURS, A HIGH OPENING MAKES ROOM: before garbage first comes, with the stack seven rows or more, of two
  // living lines the one clearing more panels first -- at 8 colours the stack passes six rows by ~440 on set-ups alone, and the first slab
  // (two or three rows, ~700) on an eight-row stack is every line lost the moment it is told. Runs 151 combo s8 and 159 insane s8 (the same
  // board, the same opening): 30 -> 48 panels by 441 on set-ups and zips, every line dying from 545, topped at 768, lost at ~605)
  // (run 183 counted cleared panels up to two rows' worth on run 180's bot: 1/8. Back)
  // (run 204: OFF -- built on seed 8's opening (runs 151, 159); on 8 colours' own seeds 21-22 it spends the stack before the first garbage:
  // run 201 thicc s21 a 4-, 5- and 6-chain put first by it (427-618), the garbage met with 14 panels, lost at 2827; run 203 with a 30-panel
  // floor still met it with 20, 4/8)
  if (0 && chaosOpenHigh && x->o.lives && y->o.lives && x->apBroke <= 0 && y->apBroke <= 0 &&
      x->o.j.clearedPanels != y->o.j.clearedPanels)
    return (cmpKey = __LINE__, (x->o.j.clearedPanels > y->o.j.clearedPanels ? -1 : 1));
  // THE LAST CHANCE: the hold lost inside a break's time, beside a line lost no sooner whose next moves promise a break's time more (the
  // readiness break, the survival search after it): the line first -- holding is the loss for certain. Only against the hold: the
  // promise is never weighed against another line's own life. 244 of 419 lost games held, dying, over such a line.
  if (x->hold != y->hold && rankHoldClock == decQ.b->clock && rankHoldOwn >= 0 && rankHoldOwn < rankSave) {
    const Judge *h = x->hold ? x : y, *l = h == x ? y : x;
    if (!l->o.dead && !l->o.lives && l->extLost != NOT_ASKED && lostAtOf(l->o.lostAt, 0) >= rankHoldOwn && lostAtOf(l->extLost, 0) - rankHoldOwn >= rankSave)
      return (cmpKey = __LINE__, (l == x ? -1 : 1));
  }
  // THE BREAK THAT PAYS (the owner: keep enough panels to break the garbage): under garbage below the floor, of two breaks that convert
  // the same rows and neither lives, the one that spends more panels goes first only where it is lost later by a break's time (rankSave)
  // for each three more it spends -- a three kept is the next break. Runs 4196-4220, large_garbage 7 and 8: every row broke for more than
  // the six it returns, the losers ~22 panels a game on a break of the same rows offered three or more panels cheaper
  if (decF.under && !x->o.lives && !y->o.lives && shortOfPanels(x, y) && imax(0, x->apBroke) / W == imax(0, y->apBroke) / W &&
      lostOf(x) >= rankSave && lostOf(y) >= rankSave) {
    const Judge *keep = panelsLeft(x) > panelsLeft(y) ? x : y, *sp = keep == x ? y : x;
    if (lostOf(sp) - lostOf(keep) < ((panelsLeft(keep) - panelsLeft(sp)) / 3) * rankSave) return (cmpKey = __LINE__, (keep == x ? -1 : 1));
  }
  // (CHAOS, DIG THE BACKLOG: under garbage with more queued, of two lines that both die, the one breaking more rows of garbage first,
  // unless the other lives a break's time (rankSave, read off the level) longer. Garbage broken is panels made and the backlog shrunk;
  // a life bought with stop time spends the panels the next break needs -- run 16 insane_combo_storm s1: 15-24 pieces queued for 1,700
  // frames, panels 40 to 7 on survive lines breaking nothing, then the top-out)
  if (decF.under && decQ.b->ninc > 0 && !x->o.lives && !y->o.lives) {
    int32_t bx = imax(0, x->apBroke) / W, by = imax(0, y->apBroke) / W;
    if (bx != by) {
      const Judge *dig = bx > by ? x : y, *other = dig == x ? y : x;
      if (lostOf(other) - lostOf(dig) < rankSave) return (cmpKey = __LINE__, (dig == x ? -1 : 1));
    }
  }
  // (CHAOS, STOP TIME IS A MAX, NOT A SUM: a new award only replaces what is left (checkMatches.lua awardStopTime), so panels cleared
  // while stopped buy only the difference. Under garbage and stopped longer than a break's time (rankSave, read off the level), of two
  // lines that both die and break no garbage, the one keeping more panels first, unless the other lives a break's time longer: the
  // panels are the next break's material -- run 19 thicc s1: survive lines at stop 70-127, panels 45 to 8, then nothing to break with.
  // And with garbage queued and none on the board too: run 21 thicc s3, 8-9 queued, the board kept busy -- the chaos queue drops only
  // with nothing moving -- by clears breaking nothing at stop 53-94, panels 27 to 12, then the queue dropped on a board with none left.
  // Whatever the stop left: run 22 thicc s4, survive and hold both lost at 238 at stop 63-82 -- under a break's time, so this was not
  // asked -- and the survive line spent panels 50 to 17 for nothing. Spending is worth it only if it lives a break's time longer)
  // (run 31: off -- made when every line was judged lost (the engine's settles never ended, runs 1-27); with lines judged, it puts
  // the hold first among dying lines and the bot holds its margin away -- run 30 combo s4, holds at margin 95 to 58 to the loss)
  if (0 && (decF.under || decQ.b->ninc > 0) && !x->o.lives && !y->o.lives && x->apBroke <= 0 && y->apBroke <= 0) {
    int32_t px = panelsLeft(x), py = panelsLeft(y);
    if (px != py) {
      const Judge *keep = px > py ? x : y, *sp = keep == x ? y : x;
      if (lostOf(sp) - lostOf(keep) < rankSave) return (cmpKey = __LINE__, (keep == x ? -1 : 1));
    }
  }
  // (run 48, CHAOS, A CLEAR THAT BREAKS NO GARBAGE IS PAID IN FUEL: with garbage on the board or queued, of two lines that both die,
  // both clear panels and neither breaks garbage, the one spending fewer first, unless the other lives a break's time (rankSave)
  // longer. Holds clear nothing, so this never puts a hold first (run 31's trouble with the rule above). Run 46 insane s10 and run
  // 48 thicc s1, both lost in the last 15 s: 22-33 pieces queued, entries and combos clearing 6-18 panels breaking nothing --
  // Training's garbage is scripted, so attack buys no life -- panels down to 13-21, then nothing to break the slab with)
  // (run 51: off, to test it -- run 50 seeds 3-4 survived 5/8 with it, two early losses (chain s4 3860, insane s3 5221))
  if (0 && (decF.under || decQ.b->ninc > 0) && !x->o.lives && !y->o.lives && x->apBroke <= 0 && y->apBroke <= 0 &&
      x->o.j.clearedPanels > 0 && y->o.j.clearedPanels > 0 && x->o.j.clearedPanels != y->o.j.clearedPanels) {
    const Judge *keep = x->o.j.clearedPanels < y->o.j.clearedPanels ? x : y, *sp = keep == x ? y : x;
    if (lostOf(sp) - lostOf(keep) < rankSave) return (cmpKey = __LINE__, (keep == x ? -1 : 1));
  }
  // (CHAOS, DIG DOWN TO THE GARBAGE: under garbage with panels plenty -- two rows' worth or more under it (2 x W), the fuel raise's
  // other side -- of two lines that both die and break no garbage, the one leaving the stack lower first, unless the other lives a
  // break's time longer: clearing panels brings the garbage down within reach -- run 40 chain_garbage s10, 34-56 panels under the slab,
  // nothing in reach, holds while the stack rose to the loss)
  // (run 41: off -- survived 5/8, three new losses on seed 9 (insane at 1926): clearing panels whenever they are plenty spends the
  // fuel the next minute needs)
  if (0 && decF.under && materialOn(decQ.b) >= 2 * W && !x->o.lives && !y->o.lives && x->apBroke <= 0 && y->apBroke <= 0 &&
      x->o.topAfter >= 0 && y->o.topAfter >= 0 && x->o.topAfter != y->o.topAfter) {
    const Judge *low = x->o.topAfter < y->o.topAfter ? x : y, *hi = low == x ? y : x;
    if (lostOf(hi) - lostOf(low) < rankSave) return (cmpKey = __LINE__, (low == x ? -1 : 1));
  }
  // 1. lives before does not -- the line in progress that lives by the horizon alone beside a line of the mode's first entry lost no sooner
  // than it, the two alike: the mode gives way to survival only (the owner), never to a plan that lives by the horizon alone
  if (lx != ly) {
    const Judge *l = lx ? x : y, *o = lx ? y : x;
    // (A NEW LINE THAT LIVES PUTS THE ONE IN PROGRESS DOWN ONLY ONCE IT HAS LIVED TWO DECISIONS RUNNING, where the one in progress stands
    // NEAR_LOSS breaks' time: a line found living one decision and lost the next is garbage not yet told of -- r1344, 7308-7677: five lines
    // in progress put down after one swap each for lines that lived once, the window spent from 23 presses to 2, the board lost at 8117)
    int fresh = l->o.lives && !l->carried && !l->hold && o->carried && !o->hold && !o->o.dead && !livedPrev && diesAt(o) >= NEAR_LOSS * rankSave && diesAt(o) < 1e299;
    // (NOR A LIFE BOUGHT WITH THE NEXT BREAK'S PANELS: under garbage, a line that lives by clearing panels below the floor and breaking
    // nothing lives on stop time, and the panels it spends are the next break's -- the break beside it that keeps the board NEAR_LOSS
    // breaks' time is played first: the garbage broken is the board kept)
    int bought = decF.under && l->o.lives && !l->hold && !(l->apBroke > 0) && l->spends && !o->hold && !o->o.dead && o->apBroke > 0 &&
                 diesAt(o) >= NEAR_LOSS * rankSave && diesAt(o) < 1e299;
    if (bought) return (cmpKey = __LINE__, (lx ? 1 : -1));
    // (run 102, CHAOS: but never a dying plan kept over a line that lives and breaks as much garbage -- under garbage the break that
    // lives is the plan. Run 101 8 colours combo s1, 561: three lines living on a three that broke 3 put after an eight breaking the
    // same 3 lost at 352, eight swaps walked 150 frames on a rising board, lost at 706)
    if (fresh && decF.under && l->apBroke > 0 && l->apBroke >= o->apBroke) fresh = 0;
    if (fresh) lx = ly = 0;
    else {
      if (!(!l->o.lives && goalLine(o) && !o->o.dead && o->o.lostAt != NOT_ASKED && diesAt(o) >= diesAt(l))) return (cmpKey = __LINE__, (lx ? -1 : 1));
      lx = ly = 1;
    }
  }
  // 1. THE PLAN KEPT (the owner: changing plans is wasteful): the line in progress on the board it was planned on -- nothing told since,
  // itself still judged lost on the frame it was judged when played (carriedSame) -- its board standing a break's time, is not put down for another line found this time: every action spent on it
  // is thrown away. Only for a line that breaks more garbage -- as seen, or as the line makes it -- or outlives it by a break's time
  // (lives before does not, above). Near its loss every frame decides, and the later loss is played
  if (lx == ly && x->carried != y->carried && !x->hold && !y->hold) {
    const Judge *c = x->carried ? x : y, *o = x->carried ? y : x;
    if (carriedSame(c) && (c->o.lives || diesAt(c) >= rankSave) && !o->o.dead && imax(0, brokeSeen(o)) <= imax(0, brokeSeen(c)) && imax(0, o->apBroke) <= imax(0, c->apBroke) &&
        !outlives(o, c) && !finishEightBy(o, c) &&
        // (run 199: above six colours under garbage, nor over a line lost half a break's time later -- run 198 8 colours, every loss
        // late with a backlog: combo s21 11929-11947 kept lost at 117 and 99 over 193 and 191; insane s22 9876-9903 222 over 299, 195
        // over 272; combo s22 16117-16448 202 over 257, 171 over 223)
        // (run 202: garbage resting or not, a quarter of a break's time -- as lostAlike and 1b there. Run 201 combo s22 2543 kept lost at
        // 220 over 264, lost at 2711; chain s22 15665 132 over 236 with 23 queued, lost at 16201)
        !(decQ.b->colors > 6 && !c->o.lives && !o->o.lives && diesAt(o) - diesAt(c) >= rankSave / 4) &&
        // (run 216: nor where the other's own board, no promise counted either side, is lost a quarter break later -- run 214 8 colours
        // insane s22 7060-7100 (11 queued): a carry lost at 213, 195, 173 (promising 369, 351, 329) kept over entries lost at 304, 286, 225
        // (promising 349, 331, 347), lost at 7635)
        !(decQ.b->colors > 6 && !c->o.lives && !o->o.lives && !o->o.dead &&
          lostAtOf(o->o.lostAt, o->hold) - lostAtOf(c->o.lostAt, c->hold) >= rankSave / 4))
      return (cmpKey = __LINE__, (x->carried ? -1 : 1));
  }
  // 1. READY WHEN IT LANDS (the owner: just be ready -- the stack raised, the garbage on its way): with garbage on its way and none on the
  // board, of two that live or are lost alike, the one that leaves a break ready once everything lands (judge.c breaksAfterLanding, the
  // window counted) goes first: the break is in place when the block arrives, not walked to after it
  if (lx == ly && !decF.under && garbageComing() && (lx || lostAlike(x, y)) && x->readyNext != NOT_ASKED && y->readyNext != NOT_ASKED &&
      (x->readyNext == 1) != (y->readyNext == 1))
    return (cmpKey = __LINE__, (x->readyNext == 1 ? -1 : 1));
  // 1. NOTHING AMID THE GARBAGE (amidGarbage): under garbage, of two that do not live, a line that swaps among the slabs and breaks nothing
  // after one that does not -- unless it keeps the board a break's time (rankSave) longer
  if (!lx && decF.under && !x->o.dead && !y->o.dead) {
    int ax = amidGarbage(x), ay = amidGarbage(y);
    if (ax != ay) { const Judge *a = ax ? x : y, *o = ax ? y : x;
      // (each board's own loss, no promise credited -- the owner: walking up between the blocks to move things around without breaking
      // is a waste; if it goes there, it breaks: r1427, 3750, a cut among the slabs lost at 125 as the hold was, put first for its promise)
      if (lostAtOf(a->o.lostAt, a->hold) - lostAtOf(o->o.lostAt, o->hold) < rankSave) return (cmpKey = __LINE__, (ax ? 1 : -1)); }
  }
  // 1. NEAR THE END A LATER LOSS IS A LATER LOSS: neither living, the sooner lost within NEAR_LOSS breaks' time, the one lost NEAR_GAIN
  // frames later or more first -- before the line in progress, the mode and every key after: each decision near the end found a line
  // lost a little later "alike" the hold, or off the mode, and held, and the board died of the holds (live p65, r661, 8097-8204: a
  // survival line lost 74 frames later passed over six times as the stack came down from 170 frames to 63)
  // (only in the race: the enemy topped out -- under garbage mid-game a board is lost within three breaks' time most of the time, and
  // there the line in progress and the mode decide: finish them, sets 86-89, 97 against main's 105 with the key always on)
  if (!lx && raceOn) {
    // (the losses as the board has them, no walk charged: the judge pressed the walk on the engine, its time is in the loss already --
    // r1362, 16763: a level lost at 52 over a break lost at 452, the walk's charge leaving the two 30 frames apart, the board lost at 16820)
    // (and its own loss, no credit for moves after it: a promise is no later loss)
    // (nor a later loss bought in the wait with the window the break at rest is pressed from -- waitSpent: the wait is not the end;
    // nor one bought with the panels beside a break that leaves the board a break's time -- boughtWithPanels: the garbage broken is
    // the board kept, and the keys after this one order the two)
    double a = lostAtOf(x->o.lostAt, x->hold), b = lostAtOf(y->o.lostAt, y->hold), lo = a < b ? a : b, hi = a < b ? b : a;
    const Judge *late = a > b ? x : y, *soon = a > b ? y : x;
    if (lo >= 0 && lo < NEAR_LOSS * rankSave && hi - lo >= NEAR_GAIN && !x->o.dead == !y->o.dead && !waitSpent(late, soon) &&
        !(soon->apBroke > 0 && boughtWithPanels(x, y)))
      return (cmpKey = __LINE__, (a > b ? -1 : 1));
  }
  // 1. NO HOLDING INTO A LOSS: neither living, the hold lost within a break's time and a move lost NEAR_GAIN frames later or more, the move
  // first -- a break's time is the least a garbage line takes to come off, and a hold that dies inside it waits for nothing (set 89,
  // combo_storm 6, 10335 and 10374: holds lost in 95 and 56 frames over a line lost 77 and 74 frames later, the board lost at 10530)
  if (!lx && x->hold != y->hold) {
    const Judge *h = x->hold ? x : y, *m = x->hold ? y : x;
    double a = diesAt(h), b = diesAt(m);   // (the frames each is lost, no walk charged: the walk's charge is the order's preference, not a loss)
    if (a >= 0 && a < rankSave && !m->o.dead && b < 1e299 && b - a >= NEAR_GAIN) return (cmpKey = __LINE__, (m == x ? -1 : 1));
  }
  // 1. NO CHANGING MINDS (the owner: efficiency, no mistakes, no changing minds): of two that survive alike -- both live, or lost alike --
  // the line in progress before the other, the hold too, where it breaks as much garbage: every swap pressed of a line put down is the input budget
  // spent for nothing, and only a break's time of life, or more garbage broken, is worth it
  if (x->carried != y->carried && (lx || lostAlike(x, y))) {
    const Judge *c = x->carried ? x : y, *o = x->carried ? y : x;
    // (and never over a board that outlives it: that is the break's time of life worth the switch)
    // (nor over a line that meets the mode's first entry where it does not, and breaks as much garbage: the same break made as the mode
    // asks -- the owner: modes are respected, in every mode)
    int modeOver = goalKeyOf(o) == 0 && goalKeyOf(c) > 0 && imax(0, brokeSeen(o)) >= imax(0, brokeSeen(c));
    // (in finish them, a combo the list asks over a line in progress that makes none, whatever each breaks: the combo is the attack -- the
    // owner: the most combos)
    // (and a bigger combo over a smaller one in progress: set 86 combo_storm 1, a 4 timed 224 frames out kept over 6s for 220 frames)
    if (finishAsked() && !o->hold && o->apCombo >= 4 && !o->outside && (!(c->apCombo >= 4) || o->apCombo > c->apCombo)) modeOver = 1;
    // (and a line whose chain stays at 2x or less over one in progress that runs past it -- the owner: combos, not chains; set 86
    // combo_storm 1, 2806-2857: a 4x in progress lost at 365 kept over a break that stops the chain lost at 466)
    if (finishAsked() && !o->hold && !o->o.dead && chainPastTwo(c) && !chainPastTwo(o) && diesAt(o) >= diesAt(c)) modeOver = 1;
    // (run 218: above six colours a quarter of a break's time is outliving here too (OUT_Q, creditPair) -- run 216 8 colours insane s21
    // 7195 a carry lost at 225 kept over an entry lost at 289, 7607/7621 137 and 123 over 181 and 171 (10-12 queued), lost at 7746)
    if (!c->hold && !modeOver && imax(0, brokeSeen(c)) >= imax(0, brokeSeen(o)) && !c->o.dead && ((!outlives(o, c) && !OUT_Q(o, c)) || calmKept(c, o))) return (cmpKey = __LINE__, (x->carried ? -1 : 1));
  }
  // 1. THE MODE, AMONG LINES THAT LIVE (the owner: just don't die; the mode is respected, garbage on the board or not): a line off the
  // mode after one that keeps to it and lives -- where the one keeping to it does not live, the later loss decides. Under garbage, only
  // one that breaks as much of it
  if (offMode(x) != offMode(y)) {
    const Judge *f = offMode(x) ? x : y, *o = f == x ? y : x;
    // (garbage on its way counts as garbage on the board: set 86 combo_storm 2, 14200, the hold lost at 245 put before a line breaking the
    // garbage 81 frames off and lost at 409 -- the board lost at 14666 with no break)
    if (livesOn(o) && (!(decF.under || garbageComing()) || imax(0, brokeSeen(o)) >= imax(0, brokeSeen(f))))
      return (cmpKey = __LINE__, (f == x ? 1 : -1));
  }
  // 1. (neither lives) SURVIVAL FIRST: the later loss, unless the two are lost alike (lostAlike: as many breaks' time left) -- every key
  // after decides only between lines that survive alike
  // 1. (neither lives, garbage on the board or on its way, below the material floor) THE BREAK'S MATERIAL KEPT (the owner: low, spend
  // less and break) (the owner: the board spent to three rows and
  // dying for want of panels): a clear that breaks nothing (spends) after a line that keeps the panels and is lost a break's time away or
  // more -- the panels it spends to stall are the next break's; it is played only where every line that keeps them is lost within one
  // (and only where the line that keeps them leaves more of them: a board the garbage lands on loses its panels under the lowest garbage
  // held or not, and a hold that leaves no more of them keeps nothing -- outcome.c matLeft)
  if (!lx && (decF.under || garbageComing()) && x->spends != y->spends) {
    const Judge *o = x->spends ? y : x, *sp = x->spends ? x : y;
    // (and only where the spend buys less than a break's time more: one that keeps the board alive a break's time longer buys the next
    // break's chance -- death is never an option)
    if (diesAt(o) >= rankSave && o->o.matLeft >= 0 && sp->o.matLeft >= 0 && o->o.matLeft > sp->o.matLeft && diesAt(sp) - diesAt(o) < rankSave)
      return (cmpKey = __LINE__, (x->spends ? 1 : -1));
  }
  // 1. (neither lives, garbage on the board, no break offered) THE GARBAGE LET DOWN (letsDown): a line that lets the garbage down onto
  // more of the stack before the hold and before a line that does not, where the two survive alike or it is lost later: with no break
  // to press, the frames a hold keeps build none, and a clear lower down leaves the perch as it is. Two that let it down are ordered
  // as any two lines
  if (!lx && decF.under && !breakOffered) {
    int dx = letsDown(x), dy = letsDown(y);
    // (never over a line that breaks garbage -- the line in progress, an entry: letting the garbage down stands in for a break, and that
    // line is one)
    if (dx != dy) { const Judge *d = dx ? x : y, *o = dx ? y : x; if (!(o->apBroke > 0) && (lostOf(d) >= lostOf(o) || lostAlike(d, o))) return (cmpKey = __LINE__, (dx ? -1 : 1)); }
    // (and of two lost alike that break nothing, the one whose board at rest leaves the garbage nearer coming down onto the stack
    // (restOn, outcome.c restOf): a perch built up is a break put further off -- the garbage on two towers over a well, every break
    // walked to it a support at a time)
    if (!x->hold && !y->hold && !(x->apBroke > 0) && !(y->apBroke > 0) && lostAlike(x, y)) {
      int32_t rx = restOn(x), ry = restOn(y);
      if (rx >= 0 && ry >= 0 && rx != ry) return (cmpKey = __LINE__, (rx < ry ? -1 : 1));
    }
  }
  // 1. (run 167, CHAOS) ABOVE SIX COLOURS UNDER GARBAGE, NO BREAK OFFERED, THE PANELS KEPT: of two lost alike that break nothing, the
  // one clearing fewer panels first -- the panels a clear spends under garbage are the next break's. Run 166 thicc s8: four rows of
  // full-width garbage on 41 panels, no break offered, levels spent them to 31 (5296-5566) and the next slab buried it, lost at 5395
  // (run 198: and never the one lost sooner -- 8 colours chain s21 1176-1231, the hold lost at 194 kept over a 2-chain lineup lost at
  // 257, five decisions in a row, 14 panels under seven rows of garbage, lost at 1601)
  if (!lx && decQ.b->colors > 6 && decF.under && !breakOffered && lostAlike(x, y) && !(x->apBroke > 0) && !(y->apBroke > 0) &&
      x->o.j.clearedPanels != y->o.j.clearedPanels &&
      lostOf(x->o.j.clearedPanels < y->o.j.clearedPanels ? x : y) >= lostOf(x->o.j.clearedPanels < y->o.j.clearedPanels ? y : x))
    return (cmpKey = __LINE__, (x->o.j.clearedPanels < y->o.j.clearedPanels ? -1 : 1));
  // (survival as the board is lost: a line that meets the mode's first entry and is lost no sooner is never passed over for the walk the
  // order charges it -- the mode gives way to survival only)
  int goalNoSooner = goalLine(x) != goalLine(y) && diesAt(goalLine(x) ? x : y) >= diesAt(goalLine(x) ? y : x);
  if (finishEightBy(x, y) || finishEightBy(y, x)) goalNoSooner = 1;
  // (A BREAK IN HAND BEFORE A PROMISE -- the owner: break the garbage: under garbage, of two that do not live, a line that breaks none of
  // it and is credited past its own loss by the moves after it, beside a line that breaks garbage and is lost no sooner on its own board,
  // the break first -- the moves after are planned again each decision, on the window the line spent, and the break is on the board now.
  // r1350, 5110: a ready lost at 98, then344, over a break in progress lost at 273; the 344 was never kept and the board was lost at
  // 5287. The finish's eight keeps its own rule: finishEightBy)
  if (!lx && decF.under) {
    int bx = !x->hold && !x->o.dead && x->apBroke > 0, by = !y->hold && !y->o.dead && y->apBroke > 0;
    if (bx != by) {
      const Judge *b = bx ? x : y, *p = bx ? y : x;
      double own = lostAtOf(p->o.lostAt, 0);
      if (!p->hold && !p->o.dead && own >= 0 && diesAt(p) > own && lostAtOf(b->o.lostAt, 0) >= own && !finishEightBy(p, b)) return (cmpKey = __LINE__, (bx ? -1 : 1));
    }
  }
  // (A BREAK BEGUN IS FINISHED -- the owner: walking up for one swap and back is wasted input; if it had to go there, it finishes its
  // break: a break in progress that has pressed a swap of it, beside a line that does not live and breaks no more, lost no sooner than a
  // break's time from now, is kept before the later loss -- runs 4094 and 4119: 180 lines put down by the later loss right after a walk
  // of six actions or more to them)
  if (!lx && x->carried != y->carried && !x->hold && !y->hold) {
    const Judge *c = x->carried ? x : y, *o = x->carried ? y : x;
    if (carriedSunk >= 0 && carriedSunk - lineWalk(c) > 0 && !c->o.dead && brokeSeen(c) > 0 && imax(0, brokeSeen(o)) <= brokeSeen(c) && !o->o.lives && lostOf(c) >= rankSave)
      return (cmpKey = __LINE__, (x->carried ? -1 : 1));
  }
  // (THE ACTIONS ALREADY SPENT -- the owner: efficiency is key, no wasted moves: a line in progress that has walked and pressed some of
  // its actions already, beside one that breaks no more and does not live, is kept unless the other outlives it by more than those actions
  // are worth (WALK_FRAMES each, the walk's own charge) -- put down for less, every action spent on it bought nothing -- and unless it is
  // lost within a break's time, its walk charged: a line the window cannot pay for is no plan to keep)
  if (!lx && x->carried != y->carried && !x->hold && !y->hold) {
    const Judge *c = x->carried ? x : y, *o = x->carried ? y : x;
    int sunk = carriedSunk >= 0 ? carriedSunk - lineWalk(c) : 0;
    if (sunk > 0 && !c->o.dead && !o->o.lives && lostOf(c) >= rankSave && imax(0, brokeSeen(o)) <= imax(0, brokeSeen(c)) && !finishEightBy(o, c) &&
        diesAt(o) - diesAt(c) < (double)WALK_FRAMES * sunk)
      return (cmpKey = __LINE__, (x->carried ? -1 : 1));
  }
  // (THE BREAK THE WINDOW STILL PRESSES -- the owner: break the garbage, at once: under garbage with the window under a break's walk
  // (BREAK_WALK), of two that do not live, a line that breaks garbage before one that presses swaps and breaks none, unless that one's
  // board outlives the break's (outlives): there every action pressed for no break is one the break is not pressed with, and the
  // break put off is found again with the window spent)
  if (!lx && decF.under && pressAllowance >= 0 && pressAllowance < BREAK_WALK) {
    int bx = !x->hold && !x->o.dead && x->apBroke > 0, by = !y->hold && !y->o.dead && y->apBroke > 0;
    if (bx != by) {
      const Judge *b = bx ? x : y, *o = bx ? y : x;
      if (!o->hold && o->k.nseq > 0 && !outlives(o, b)) return (cmpKey = __LINE__, (bx ? -1 : 1));
    }
  }
  // (A PROMISE NEVER BEATS A BREAK -- the owner: breaking garbage is super important: under garbage, of two that do not live, a line
  // that breaks garbage before one that breaks none -- the hold too -- unless that one's own board, not what its next moves promise,
  // outlives the break's by a break's time: 4538 combo_storm 3, 4887, a chain breaking nothing lost at 409, promising 697, played over a
  // break of 16 lost at 429; the panels drained and the breaks after it came too late)
  if (!lx && decF.under) {
    int bx = !x->hold && !x->o.dead && x->apBroke > 0, by = !y->hold && !y->o.dead && y->apBroke > 0;
    if (bx != by) {
      const Judge *b = bx ? x : y, *o = bx ? y : x;
      double bb = lostAtOf(b->o.lostAt, 0), ob = lostAtOf(o->o.lostAt, o->hold);
      if (!o->o.lives && bb >= rankSave && ob - bb < rankSave) return (cmpKey = __LINE__, (bx ? -1 : 1));
    }
  }
  // (A PROMISE NEVER BEATS A LIFE: of two that do not live, one whose own board -- no next moves credited, the walk pressed on the
  // engine -- outlives the other's by a break's time comes first, where the other is ahead only on what its next moves promise
  // (extCounts): run 4609, factory 3, 11099, an entry lost at 128 promising 282 over a survive lost at 293, the board lost to the next
  // block with no break)
  if (!lx && !x->o.dead && !y->o.dead) {
    double ox = lostAtOf(x->o.lostAt, x->hold), oy = lostAtOf(y->o.lostAt, y->hold);
    if (ox >= 0 && oy >= 0 && ox < 1e299 && oy < 1e299) {
      if (oy - ox >= rankSave && extCounts(x) && !extCounts(y)) return (cmpKey = __LINE__, 1);
      if (ox - oy >= rankSave && extCounts(y) && !extCounts(x)) return (cmpKey = __LINE__, -1);
    }
  }
  // (THE WALK TURNS IT: neither lives, and the walk charged is what puts one ahead -- the later loss on the boards as they are first)
  if (!lx && walkTurns(x, y)) return (cmpKey = __LINE__, (diesAt(y) > diesAt(x) ? 1 : -1));
  // (SURVIVAL FIRST, THE LATER LOSS: neither lives and the two are not lost alike -- the one lost later first; the '1. (neither lives)
  // SURVIVAL FIRST' rule above, applied here after the exceptions to it)
  if (!lx && !lostAlike(x, y) && !boughtWithPanels(x, y) && !goalNoSooner && lostOf(x) != lostOf(y)) return (cmpKey = __LINE__, (lostOf(y) > lostOf(x) ? 1 : -1));
  // (neither lives, lost alike, under garbage, the window short) OF TWO BREAKS, THE CHEAPER: the game allows 76 actions in 600 frames, a
  // block lands every 100-150 in factory and a break walks 15-25 -- once the window holds less than three breaks' walks, the break that
  // spends CHEAP_STEP actions fewer comes first, before the panels and the mode: the actions it keeps are the next break's (run 4604,
  // factory 5 of 8, every loss a board with a break on it and 0-7 actions to press it)
  #define CHEAP_STEP 3
  if (!lx && decF.under && pressAllowance >= 0 && allowLeftAt(0, 0) < 3 * BREAK_WALK && x->apBroke > 0 && y->apBroke > 0 && !x->o.dead && !y->o.dead) {
    int wx = lineWalk(x), wy = lineWalk(y);
    if (wx - wy >= CHEAP_STEP || wy - wx >= CHEAP_STEP) return (cmpKey = __LINE__, (wx - wy));
  }
  // (neither lives, lost alike or bought with panels, under garbage below the floor) of two breaks, the one that leaves the next break
  // more panels -- before the mode and the walk
  // (not in finish them between a combo and a line that makes none: the combo is the attack, and the panels it spends are what it is made of)
  // (nor in finish them between a line whose chain runs past 2x and one whose does not: the shorter chain decides, 1'c -- set 86
  // combo_storm 1, 1987: a 3x lost at 351 over a break lost at 368 for the panels it left)
  if (!lx && shortOfPanels(x, y) && lostOf(x) >= rankSave && lostOf(y) >= rankSave && !(finishAsked() && (x->apCombo >= 4) != (y->apCombo >= 4)) &&
      !(finishAsked() && chainPastTwo(x) != chainPastTwo(y)) && !finishBigger(x, y) && !finishBigger(y, x))   // (nor a bigger combo lost no sooner: set 86 combo_storm 1, 2679-3001, a 7 passed over 18 times for a 6 that left more panels)
    return (cmpKey = __LINE__, (panelsLeft(x) > panelsLeft(y) ? -1 : 1));
  // 1'2. NO 2x WHERE THE BOARD IS SAFE (the owner: a 2x is continued or not made -- one made with nothing to survive is for nothing): of
  // two that live, no garbage on the board and the board making no chain of its own, a line whose chain ends at two after one that makes
  // none and breaks as much
  if (lx && !decF.under && aloneChain < 2 && shortChain(x) != shortChain(y)) {
    const Judge *sc = shortChain(x) ? x : y, *o = shortChain(x) ? y : x;
    if (imax(0, o->apBroke) >= imax(0, sc->apBroke)) return (cmpKey = __LINE__, (shortChain(x) ? 1 : -1));
  }
  // 1'. THE CHAIN FALLING, CARRIED ON (the owner: a chain going is continued unless continuing kills the board): while the board chains,
  // of two that survive alike, the one that takes the chain further, up to the longest the list asks -- before every key but survival,
  // under garbage too: a chain left to end short of the target is the attack thrown away
  // (and a chain the board is about to make on its own -- garbage converting into a match, panels falling -- is a chain going too: the
  // line that takes it further is chosen while it can still be reached, not once its second link has popped)
  if (decQ.b && (decQ.b->chainCounter >= 2 || aloneChain >= 2) && (lx || lostAlike(x, y)) && !finishAsked() && listChainCap() > 0) {   // (and not where the list asks no chain: rules.c ownChainAsked)
    int32_t cap = imax(listChainCap(), 3);   // (at least to three: the owner)
    {
      int32_t cx = imin(chainReach(x), cap), cy = imin(chainReach(y), cap);
      // (neither living: a 2x is still taken on to three -- the owner: a 2x is continued unless that kills the board -- but a chain longer
      // than that only where it breaks as much garbage as the other: passed over, a break is the board's life)
      const Judge *lc = cx > cy ? x : y, *sc = cx > cy ? y : x;
      if (!lx && imax(0, lc->apBroke) < imax(0, sc->apBroke)) { cx = imin(cx, 3); cy = imin(cy, 3); }
      // (and a line that breaks more and is lost no sooner is never passed over for a chain past three, nor one that is lost later for a
      // 2x taken to three: the break is the longer life)
      int brokeMore = !lx && imax(0, sc->apBroke) > imax(0, lc->apBroke) && (imin(cx, cy) >= 3 ? lostOf(sc) >= lostOf(lc) : lostOf(sc) > lostOf(lc));
      // (a chain taken further on the window the next break is pressed from is not -- nor, garbage on the board, one that leaves the
      // window under half a break's walk where the other leaves it more: the next break would not be there to press)
      int spends = (spendsReserve(lc) && !spendsReserve(sc)) ||
                   (decF.under && pressAllowance >= 0 && pressAllowance - lineWalk(lc) < BREAK_WALK / 2 && reserveShort(lc) > reserveShort(sc));
      if (cx != cy && !brokeMore && !spends) return (cmpKey = __LINE__, (cy - cx));
    }
  }
  // 1'e. FLAT, NO GARBAGE ON ITS WAY (the stack at speed: a well between towers is where the board dies -- a canyon is never dug out at
  // forty-seven frames a row): with no garbage on the board, held or due, and the board not chaining, of two that survive alike the
  // one that leaves the board flatter by FLAT_ROWS or more, whatever the window holds
  // (run 148: above six colours with garbage on its way too, so long as none is on the board -- at 8 colours garbage is told nearly the
  // whole opening, so the rule never acted there. Run 147 combo s8 (and run 145): the opening's clears from 431 dug columns 1-5 to rows
  // 3-6 beside an eight-row tower in column 0; the first 6-wide slab perched on it at 707 out of every break's reach, lost at 812)
  if ((lx || lostAlike(x, y)) && !decF.under && ((decQ.narr == 0 && decF.next == NOT_ASKED) || decQ.b->colors > 6) && decQ.b->chainCounter < 2 &&
      x->o.j.even >= 0 && y->o.j.even >= 0 && iabs(x->o.j.even - y->o.j.even) >= FLAT_ROWS)
    return (cmpKey = __LINE__, (x->o.j.even - y->o.j.even));
  // (run 98: off -- 1'g alone L10 seeds 15-16 7/8, the gate's bot 7/8; with the other changes seeds 13-16 13-14/16, the gate's 14/16)
  // 1'g. (run 94, CHAOS) UNDER GARBAGE, NO CANYON UNDER IT: garbage on the board, of two that both live or are lost alike and break
  // the same garbage, the one leaving GAP_CELLS fewer empty cells under the garbage (judge.c gapOf) first -- a piece perched over a
  // cleared middle is out of reach of every break, and what lands next lands on it. Run 92 insane s16 17400-18158, lost at 18633
  // (run 111: on again above six colours -- run 110 8 colours combo s4, column 3 dug to a well seven rows deep under garbage resting on
  // the columns beside it, lost at 4447)
  // (run 112: off again -- runs 111-112 4/8 and 3/8 against run 110's 5/8 on the same seeds; the losses moved, none fixed)
  if (0 && decQ.b->colors > 6 && decF.under && (lx || lostAlike(x, y)) && imax(0, x->apBroke) == imax(0, y->apBroke) && x->o.j.gap >= 0 && y->o.j.gap >= 0 &&
      iabs(x->o.j.gap - y->o.j.gap) >= GAP_CELLS)
    return (cmpKey = __LINE__, (x->o.j.gap - y->o.j.gap));
  // 1'i. (run 112, CHAOS) ABOVE SIX COLOURS, ROOM FOR WHAT IS COMING: when the garbage on its way and waiting, stacked on the board as it
  // stands (fullTop), reaches the top row, of two that both live or are lost alike, the one leaving the stack lower first -- a slab that
  // lands on a topped board with no stop running ends the game inside the shake. Run 111 8 colours insane s3: a 7-row board told of a
  // 5-row slab 50 frames out, the frames spent on a slow break and walks, lost 70 frames after it landed
  // (run 112: off -- 3/8; chain s3 and s4 lost, lived in run 110)
  if (0 && decQ.b->colors > 6 && (lx || lostAlike(x, y)) && x->o.topAfter >= 0 && y->o.topAfter >= 0 && x->o.topAfter != y->o.topAfter) {
    int32_t rows = 0, h = decQ.b->height ? decQ.b->height : 12;
    for (int i = 0; i < decQ.narr; i++) rows += decQ.arr[i].height > 0 ? decQ.arr[i].height : 1;
    for (int i = 0; i < decQ.b->ninc; i++) rows += decQ.b->inc[i].height > 0 ? decQ.b->inc[i].height : 1;
    if (rows > 0 && fullTop(decQ.b) + rows >= h - 1) return (cmpKey = __LINE__, (x->o.topAfter - y->o.topAfter));
  }
  // 1'j. (run 127, CHAOS) ABOVE SIX COLOURS UNDER GARBAGE, THE PANELS KEPT EVEN: of two that live or are lost alike and break the same
  // garbage, the one leaving its panel columns two rows or more more even (judge.c panelEvenOf: garbage never counted) first -- every
  // canyon of runs 115-126 was panel towers beside emptied columns with the garbage resting on the towers (run 126 thicc s6: columns 3-5
  // emptied from row 7 to 10 by 4x chains breaking nothing, lost at 9240)
  // (run 128: off -- run 127 with it 1/8)
  if (0 && decQ.b->colors > 6 && decF.under && (lx || lostAlike(x, y)) && imax(0, x->apBroke) == imax(0, y->apBroke) &&
      x->o.j.pEven >= 0 && y->o.j.pEven >= 0 && iabs(x->o.j.pEven - y->o.j.pEven) >= 2)
    return (cmpKey = __LINE__, (x->o.j.pEven - y->o.j.pEven));
  // 1'h. (run 107, CHAOS) ABOVE SIX COLOURS, THE COLOURS LINED UP (the owner: be more purposeful with colours): of two that both live
  // or are lost alike and break the same garbage, the one leaving more breaks a swap away (judge.c readyOf: a single swap that makes a
  // match touching garbage), then more matches a swap away -- at 8 colours a match seldom arrives by itself, and runs 101-106 found no
  // break on 57% of decisions under garbage
  // (run 128 measured it off: 4/8 against 5/8 on -- kept on)
  // (run 151: off, measured on the wider search (64 x 6) -- run 128 measured it off at 4/8 against 5/8, within the noise)
  if (0 && decQ.b->colors > 6 && (lx || lostAlike(x, y)) && imax(0, x->apBroke) == imax(0, y->apBroke)) {
    if (x->o.j.readyBreak != y->o.j.readyBreak) return (cmpKey = __LINE__, (x->o.j.readyBreak > y->o.j.readyBreak ? -1 : 1));
    if (x->o.j.swapReady != y->o.j.swapReady) return (cmpKey = __LINE__, (x->o.j.swapReady > y->o.j.swapReady ? -1 : 1));
  }
  // (1'h', run 136: of two dying lines breaking nothing, a break a swap away over waiting though lost up to two breaks' time sooner --
  // 2/8 against run 132's 6/8: removed)
  // 1'f. NO SLAB AT THE FINISH: where the list is the finish (finishAsked), of two that survive alike, the line that sends no slab of two
  // rows or more (a chain of three or longer, the board's own going on included) before one that does, whatever either breaks -- the
  // owner: no big chains at the finish; a chain is played there only where nothing else lives as long
  if (finishAsked() && (lx || finishAlike(x, y))) {
    // (a 2x is allowed -- the owner: a chain at the finish, if any, is a 2x; the slab is a chain of three or longer)
    int at = 3, bx = chainReach(x) >= at, by = chainReach(y) >= at;
    if (bx != by) return (cmpKey = __LINE__, (bx ? 1 : -1));
  }
  // 1'L. UNDER GARBAGE, BREAK (the owner: it waits too long to break garbage; low, spend less and focus on breaking): garbage on the
  // board, of two that both live, or are lost alike with the break lost no sooner, a line that breaks garbage before one that breaks none
  // and meets nothing the mode asks for (the hold, a set-up) -- waiting meets the mode no more than the break does, and the garbage left
  // is the board's danger; below the material floor before any line that breaks none, the list's or not: the break is the panels the
  // board lacks, and a board waited on below the floor finds no break later
  if (decF.under && (lx || lostAlike(x, y)) && breaksFirst(x, lx) != breaksFirst(y, lx)) {
    const Judge *b = breaksFirst(x, lx) ? x : y, *o = breaksFirst(x, lx) ? y : x;
    // (not over the opener's chain: a line whose chain is one the opener still needs, the board's own included, made before any loss
    // the judging finds after it, is no line that meets nothing -- the owner: the eight first, survival after)
    int keepsNeed = opNeed && o->o.j.chainAll >= opNeed && b->o.j.chainAll < opNeed;
    if (opNeed && o->o.j.chainAll >= opNeed) { if (keepsNeed) needKept++; else needLost = b->o.j.chainAll; }
    // (the mode's goal no exception -- the owner, 2026-11-19: garbage on the board, break it immediately, then do everything else; r1405,
    // 5461: a six with a 3x that broke nothing, the mode's goal, played over the breaks with eight seconds to spare)
    if ((lx || diesAt(b) >= diesAt(o)) && !keepsNeed) return (cmpKey = __LINE__, (b == x ? -1 : 1));
  }
  // 1'Lc. THE BREAK THAT CHAINS (the owner: break the garbage and the next chain is there): the opener in force under garbage, of two
  // that survive alike, neither making the chain the opener still needs, the one whose break is a link of a chain before one whose break
  // is not -- garbage a link breaks pops chaining (pa.c convertGarbagePanels), the chain living while it pops and its panels the next links
  if (opNeed && decF.under && (lx || lostAlike(x, y)) && x->o.j.chainAll < opNeed && y->o.j.chainAll < opNeed) {
    int cx = !x->hold && x->o.j.brokeLink > 0, cy = !y->hold && y->o.j.brokeLink > 0;
    if (cx != cy) return (cmpKey = __LINE__, (cx ? -1 : 1));
  }
  // 1'r. READY FOR THE NEXT BLOCK (the owner: there should always be pieces): of two that survive alike, the readier before the other
  // where it breaks no less and the other meets no goal it misses -- readier is a break in reach once the next block lands (readyNext,
  // asked where none lives), else, under garbage, a swap that brings the nearest break nearer (propose.c readyBuild), the hold included
  if (lx || lostAlike(x, y)) {
    int rx = readier(x, y);
    if (rx) {
      const Judge *r = rx < 0 ? x : y, *o = rx < 0 ? y : x;
      if (imax(0, brokeSeen(r)) >= imax(0, brokeSeen(o)) && !(goalLine(o) && !goalLine(r)) && !cutsShort(r)) return (cmpKey = __LINE__, rx);
    }
  }
  // 1'g. UNDER GARBAGE, NOT AWAY FROM IT (the owner: the garbage at the top, a move at the bottom makes no sense): of two that survive
  // alike, a line that breaks nothing and whose first swap is GARBAGE_AWAY rows or more under the lowest garbage after one that does not
  // go there, breaks as much, meets the mode as much and is lost no sooner -- the walk down and back is the window spent for nothing. Two
  // moves, never a move and the hold: the hold goes nowhere either
  if (decF.under && !x->hold && !y->hold && (lx || lostAlike(x, y))) {
    int fx = awayFromGarbage(x), fy = awayFromGarbage(y);
    if (fx != fy) {
      const Judge *f = fx ? x : y, *o = fx ? y : x;
      if (imax(0, brokeSeen(o)) >= imax(0, brokeSeen(f)) && !(goalLine(f) && !goalLine(o)) && (lx || diesAt(o) >= diesAt(f))) return (cmpKey = __LINE__, (fx ? 1 : -1));
    }
  }
  // 1'b. COMBOS ONLY WHERE THE MODE ASKS (the owner): of two that survive alike, a combo the mode does not ask for after a line that makes
  // none and breaks as much garbage -- a combo that breaks more is the break, a combo that breaks no more is the panels of an attack the
  // mode does not want
  if ((lx || lostAlike(x, y)) && comboOutside(x) != comboOutside(y)) {
    const Judge *cb = comboOutside(x) ? x : y, *o = comboOutside(x) ? y : x;
    if (imax(0, o->apBroke) >= imax(0, cb->apBroke)) return (cmpKey = __LINE__, (comboOutside(x) ? 1 : -1));
  }
  // 1'c. THE FINISH SENDS NO CHAIN PAST A 2 (the owner: in finish them a chain, if any, is a 2x -- large chains down, eights up): of two
  // that survive alike, a line whose whole chain -- the board's own falling chain with it -- runs past two after one whose does not:
  // a cut taken over the hold that lets the garbage's chain run to a 4
  // (and a chain already past two when the decision is made is cut where it stands: of two past two, the shorter -- a 3 before a 5)
  if (finishAsked() && (lx || finishAlike(x, y)) && (chainPastTwo(x) || chainPastTwo(y)) && x->apChainAll != y->apChainAll) {
    const Judge *cl = x->apChainAll > y->apChainAll ? x : y, *o = cl == x ? y : x;
    // (both living or lost alike: the shorter chain, whatever each breaks -- the owner: no big chains at the finish; set 86 combo_storm 1,
    // a 7x lost at 502 over a 4x lost at 498 with the next moves, on the garbage the 7x broke)
    return (cmpKey = __LINE__, (cl == x ? 1 : -1));
  }
  // 1'k. COMBOS, NOT CHAINS (the owner: finish them sends combos, not chains): of two that live, or are lost alike, a combo of four or
  // more that sends no chain before a line that sends one -- the board's own falling chain counted with it
  // (never in the opener: its chain is asked -- set 86 combo_storm 1, 192, the opener's 5x played with a swap more)
  if (finishAsked() && !inOpener && (lx || lostAlike(x, y)) && !x->hold && !y->hold) {
    int px = x->apCombo >= 4 && x->apChainAll < 2, py = y->apCombo >= 4 && y->apChainAll < 2;
    int cx = x->apChainAll >= 2, cy = y->apChainAll >= 2;
    // (only where the combo with no chain is lost no sooner -- survival first: set 86 combo_storm 1, 6301, an 8 lost at 225 over a 9 with
    // its 2x lost at 296, the board lost at 6583)
    if (px && cy && !cx && diesAt(x) >= diesAt(y)) return (cmpKey = __LINE__, -1);
    if (py && cx && !cy && diesAt(y) >= diesAt(x)) return (cmpKey = __LINE__, 1);
  }
  // 1'a. THE ALLOWANCE'S RESERVE: of two that survive alike (both live, or lost alike), a line that walks the input allowance below a
  // break's walk (BREAK_WALK) after one that keeps it, and of two that leave it short the one that leaves it shorter after -- two
  // breaks as two of anything else -- the next break is pressed out of what is left, and what is spent comes back only a window later, the garbage it is needed
  // for may be told of by then or not
  if (pressAllowance >= 0 && (lx || lostAlike(x, y))) {
    int rx = reserveShort(x), ry = reserveShort(y);
    // (but never against the board's own rise: with no garbage on the board or on its way, the board is lost to the stack rising, and
    // the line that keeps it alive longer by a cursor step's walk or more is played over the reserve -- the board kept doing things)
    const Judge *kp = rx < ry ? x : y, *sp = rx < ry ? y : x;
    int rises = !lx && !decF.under && !garbageComing() && !sp->o.dead && diesAt(sp) >= diesAt(kp) + WALK_FRAMES;
    // (nor, in finish them, against a combo the list asks: a combo of four or more with at most a 2x, beside a line that makes no such
    // combo, is played over the reserve where it is lost no sooner -- the owner: any combo beats a 3; the combo is the break itself)
    int asks = finishAsks(sp, kp);
    // (nor against a flatten the window has room for, beside the hold or a line that is none: rank.c flattenFree -- the set-up key below
    // decides between them)
    int flat = flattenFree(sp) && !flattenFree(kp);
    if (rx != ry && !rises && !asks && !flat) return (cmpKey = __LINE__, (rx - ry));
  }
  // 1'u. NO SWAP BACK (the owner: no flip and back): of two that both live, or are lost alike and BACK_CALM breaks' time off or more, a line whose first swap swaps back the pair the last swap
  // pressed swapped after one that does not and breaks as much -- the two swaps are inputs spent to stand where the board stood
  if ((lx || (lostAlike(x, y) && (lostOf(x) < lostOf(y) ? lostOf(x) : lostOf(y)) >= BACK_CALM * rankSave)) && !x->hold && !y->hold && x->back != y->back) {
    const Judge *b = x->back ? x : y, *o = x->back ? y : x;
    if (imax(0, o->apBroke) >= imax(0, b->apBroke)) return (cmpKey = __LINE__, (x->back ? 1 : -1));
  }
  // 1'h. FOCUS (the owner: precise, efficient -- the cursor kept where the work is): of two that survive alike and both break garbage or
  // both do not, the one begun nearer the cursor -- within FOCUS_NEAR cells, then short of FOCUS_FAR, then farther: the board is
  // worked where the cursor is, and left only for what survives better or breaks where the near one does not
  // (of two that break garbage, begun nearer is no saving where the nearer walks more for the break -- a swap put in front of the break the
  // other already has: the fewer actions for as much garbage decides first, 1'' below)
  // (never an eight left for a nearer line in finish them: the two 4s fired as one -- set 86 combo_storm 1, 2864: a set-up lost at 150
  // over an eight lost at 308, for its walk)
  if ((lx || lostAlike(x, y)) && !x->hold && !y->hold && (x->apBroke > 0) == (y->apBroke > 0) && x->k.nseq && y->k.nseq &&
      !finishEightBy(x, y) && !finishEightBy(y, x) && !finishBigger(x, y) && !finishBigger(y, x) &&
      !(x->apBroke > 0 && imax(0, x->apBroke) == imax(0, y->apBroke) && lineWalk(x) != lineWalk(y))) {
    int bx = focusBand(x), by = focusBand(y);
    // (and a far line that breaks more garbage than the near one is not left for it: the near one is worked only where it breaks as much
    // -- the garbage broken for the walk decides, 1'' below)
    const Judge *nr = bx < by ? x : y, *fr = bx < by ? y : x;
    if (bx != by && !(nr->apBroke > 0 && imax(0, nr->apBroke) < imax(0, fr->apBroke))) return (cmpKey = __LINE__, (bx - by));
  }
  // 1'0. THE LINE IN PROGRESS OVER ONE IT OUTLASTS AND OUTBREAKS (the owner: a move is wasted only where survival asks it): of two that
  // survive alike, the line the last decision was playing before another lost no later that breaks no more garbage -- every swap
  // pressed of a line put down is spent from the input window for nothing
  if (x->carried != y->carried && !x->hold && !y->hold && (lx || lostAlike(x, y))) {
    const Judge *c = x->carried ? x : y, *o = x->carried ? y : x;
    if (lostOf(c) >= lostOf(o) && imax(0, c->apBroke) >= imax(0, o->apBroke) && !(goalLine(o) && !goalLine(c))) return (cmpKey = __LINE__, (x->carried ? -1 : 1));
  }
  // 1''. UNDER GARBAGE, THE WINDOW SPENT ON BREAKS: of two that survive alike, a line that breaks before one that breaks nothing, then
  // the one that walks fewer actions -- the hold walks none: under garbage only a break is worth what it spends from the input window,
  // and the rest wait for it to give some back
  // (and once the opener is over, with garbage on its way and none on the board yet: the stack it lands on is the one built now --
  // towers left at the edges over cleared middle columns perch it, and no break is in reach under it for hundreds of frames, g4453
  // factory 8, 610-993. Not in the opener: there the set-ups walked the window down before the first blocks landed, g4456)
  if ((decF.under || (!inOpener && garbageComing())) && pressAllowance >= 0 && (lx || lostAlike(x, y))) {
    int bx = breaksFirst(x, lx), by = breaksFirst(y, lx);
    // (but not over the mode's first entry thrown where the break meets none of it: the mode is played under garbage too -- the goal
    // decides between them, 1b)
    if (bx != by && !((bx ? y : x)->modeFirst && !(bx ? x : y)->modeFirst)) return (cmpKey = __LINE__, (bx ? -1 : 1));
    // (of two that break nothing: a fallback after a line that fires none -- the mode's list before the walk; then the fewer actions)
    if (!bx) {
      int fx = fallbackOf(x), fy = fallbackOf(y);
      if (fx != fy) return (cmpKey = __LINE__, (fx ? 1 : -1));
      // (and a swap toward an eight, lost no sooner and the reserve kept, before the wait -- set up between moves: rank.c nearerEight)
      int ex = nearerEight(x, y), ey = nearerEight(y, x);
      if (ex != ey) return (cmpKey = __LINE__, (ex ? -1 : 1));
      // (WHILE GARBAGE POPS, THE CURSOR FREE (the owner: it holds too much -- it can do things while garbage is breaking): a set-up --
      // a set-up, a lineup, a line toward the next break or nearest the list; no clear of three for nothing, the reserve kept, lost no
      // sooner -- before the hold, whatever it walks: the wait buys nothing the pop does not. A line the survival search found is no
      // set-up: pressed for nothing it spends the window the next break needs)
      // (and while the board's own chain falls -- the owner: set up and started, it can do something else; it just sits there waiting for
      // it to finish: a set-up that keeps the chain as far as the hold does, the same)
      // (and every other time too -- the owner: hold is dumb, a set-up or flattening is better 90% of the time; swaps over distance, the
      // set-up is key: a set-up, a lineup, a line toward the next break or nearest the list, or a level, before the hold and before a
      // line of another kind, whatever either walks -- lost alike is safe enough: the frames its walk costs are no break's time)
      int chaining = decQ.b && (decQ.b->chainCounter >= 2 || aloneChain >= 2);
      int sx = setupKind(x), sy = setupKind(y);
      if (sx != sy) {
        const Judge *m = sx ? x : y, *h = sx ? y : x;
        // (but never far for it -- the owner, 2026-11-19: not moving super far for no good reason, a swap nearby before a move far away:
        // the set-up first only within WALK_EARN actions of the other, or lost NEAR_GAIN frames later; run 4119, 849: a toward walked 20
        // actions over a hold lost on the same frame)
        int nearEnough = lineWalk(m) - lineWalk(h) <= WALK_EARN || (diesAt(m) - diesAt(h) >= NEAR_GAIN && !m->o.dead);
        if (m->k.nseq && nearEnough && !wastesThree(m) && (!spendsReserve(m) || flattenFree(m)) && (!chaining || (chainReach(m) >= chainReach(h) && !cutsShort(m))))
          return (cmpKey = __LINE__, (sx ? -1 : 1));
      }
      if (sx && sy && zipOver(x, y)) return (cmpKey = __LINE__, zipOver(x, y));
      // (of two set-ups: the one that leaves more crossed seams -- a swap finishing two colours at once, the players' 8+ combo)
      if (sx && sy && x->o.j.seams != y->o.j.seams) return (cmpKey = __LINE__, (x->o.j.seams > y->o.j.seams ? -1 : 1));
      // (then the fewer actions -- against the hold only where the move spends the reserve: a window that keeps a break's walk either way
      // buys nothing by holding)
      int wx = lineWalk(x), wy = lineWalk(y);
      if (wx != wy && ((!x->hold && !y->hold) || spendsReserve(x->hold ? y : x))) return (cmpKey = __LINE__, (wx - wy));
    }
    // (of two that break: one that leaves a break in reach once the next block lands, where neither lives -- a dig runs dry on the
    // break it did not keep; then the one that breaks more garbage for each action it walks -- the window pays for every cell walked)
    // (of two that break: one that breaks as much garbage without a combo of four the list does not ask for, before one that spends it)
    else if (wastesFour(x) != wastesFour(y) && (wastesFour(x) ? y : x)->apBroke >= (wastesFour(x) ? x : y)->apBroke) return (cmpKey = __LINE__, (wastesFour(x) ? 1 : -1));
    else if (x->readyNext != NOT_ASKED && y->readyNext != NOT_ASKED && (x->readyNext == 1) != (y->readyNext == 1)) return (cmpKey = __LINE__, (x->readyNext == 1 ? -1 : 1));
    // (of two that break: the one that meets the earlier combo entry of the mode's list -- the combo the mode asks goes with the break)
    else if (comboEntry(x) != comboEntry(y)) return (cmpKey = __LINE__, (comboEntry(x) - comboEntry(y)));
    // (of two that break: the one that meets the mode's first entry, chain or combo -- the mode's attack under garbage, the break with
    // it: the owner, the mode passed over for survival only)
    else if (goalLine(x) != goalLine(y)) return (cmpKey = __LINE__, (goalLine(x) ? -1 : 1));
    // (a line put down for another throws away the actions pressed of it: the other is charged them -- the walk the line in progress was
    // played for, less what is left of it)
    else {
      int sx = lineWalk(x), sy = lineWalk(y);
      if (carriedSunk >= 0 && x->carried != y->carried) { const Judge *c = x->carried ? x : y; int sunk = imax(0, carriedSunk - lineWalk(c)); if (c == x) sy += sunk; else sx += sunk; }
      // (THE DIG ZIPPED -- the owner: digging goes for the zipper: of two that break as much garbage, walking within ZIP_WALK actions of
      // each other, the one that leaves the colours more zippered -- fewer of a colour touching, more a swap apart: judge.c spreadOf)
      if (x->apBroke == y->apBroke && iabs(sx - sy) <= ZIP_WALK && x->o.j.spread != y->o.j.spread) return (cmpKey = __LINE__, (x->o.j.spread > y->o.j.spread ? -1 : 1));
      int64_t px = (int64_t)x->apBroke * imax(1, sy), py = (int64_t)y->apBroke * imax(1, sx); if (px != py) return (cmpKey = __LINE__, (px > py ? -1 : 1));
    }
  }
  // 1a. THE LINE IN PROGRESS KEPT: of two that both live or both do not, the line the last decision was playing, judged again on the
  // board as it is, before another -- unless the other is lost later and not alike (neither lives: lostAlike, as 3 counts them) or meets
  // an earlier entry of the list (both live). A line put down halfway leaves a board its forecast never judged.
  // (and not over a break where neither lives and the line in progress breaks nothing: the break is put first (2) -- the panels it
  // converts are the board's next, and only a break gives back what a clear spends)
  if (x->carried != y->carried && !x->hold && !y->hold) {
    const Judge *c = x->carried ? x : y, *o = x->carried ? y : x;
    // (the losses as the engine has them, the walk pressed on it: charged again, a break of 14 actions lost at 174 read as 60 beside a
    // line in progress lost at 107 -- run 4597, factory 2, 8856, the board lost at 107)
    double oOwn = lostAtOf(o->o.lostAt, 0), cOwn = lostAtOf(c->o.lostAt, 0);
    int oBreaks = o->apBroke > 0 && oOwn >= rankSave && !(c->apBroke > 0) && (decF.belowFloor || cOwn - oOwn < rankSave);
    // (in finish them, alike within a break's time -- set 86 combo_storm 1, 2387: a 5x in progress lost at 351 kept over a combo of 6
    // lost at 580, both three breaks off)
    // (and never over a line the engine has outliving it by a break's time, its walk already pressed there -- run 4608, combo_storm 1,
    // 506: a survive lost at 227 read below the line in progress lost at 115 for the walk charged again, the board lost at 115)
    int oOutlives = !lx && !o->o.dead && oOwn < 1e299 && cOwn < 1e299 && oOwn - cOwn >= rankSave;
    int keep = lx ? !(o->met >= 0 && (c->met < 0 || o->met < c->met)) : (lostOf(o) <= lostOf(c) || (finishAsked() ? finishAlike(c, o) : lostAlike(c, o))) && !oBreaks && !oOutlives;
    // (and under garbage, a break in progress over another break that costs more presses than what is left of it -- switching spends the
    // window on swaps pressed for nothing -- unless the one in progress is lost within a break's time)
    if (!keep && !oOutlives && decF.under && c->apBroke > 0 && o->apBroke > 0 && lineWalk(o) > lineWalk(c) && lostOf(c) >= rankSave) keep = 1;
    if (finishEightBy(o, c)) keep = 0;
    if (keep) return (cmpKey = __LINE__, (x->carried ? -1 : 1));
  }
  // 1b. THE MODE'S GOALS (the owner: a mode plays its first entry, builds toward it otherwise, and takes a fallback only where the board
  // dies without it -- survival first): of two that survive alike -- both live, or both lost no sooner than a break's time and less than
  // a break's time apart, where the later buys no break more -- and keep the board's own chain alike, the first entry, then a line that
  // fires no fallback, then each fallback in the list's order (goalKeyOf)
  if (cutsShort(x) == cutsShort(y)) {
    double lo = lostOf(x) < lostOf(y) ? lostOf(x) : lostOf(y), hi = lostOf(x) < lostOf(y) ? lostOf(y) : lostOf(x);
    // (time attack: nothing coming, the rise never still -- of two that do not live the later loss decides, never the goal: a board held
    // for the mode's goal while it climbs is one that runs out of ways to live)
    // (run 195: nor under garbage where no clear buys stop time (game mode 3 and up: ca.c awardStopTime) -- of two that do not live there
    // the mode's attack is no way to live. Run 194 no stop time combo s7: 2979 the hold kept by this rule, 3017-3123 a combo of 6 breaking
    // nothing carried while the board ran from 109 frames to 1, lost at 3652)
    // (run 201: above six colours, the goal decides only within a quarter of a break's time -- as lostAlike there (run 200). Run 200 8
    // colours insane s21: 687 the hold lost at 287 kept over a 7-chain extend lost at 448, 1162 166 over 223; lost at 1289)
    // (run 214: and above six colours, two counted living only by the credit (the horizon, the finish's safe board) are held to the same
    // quarter break -- run 213 chain s21 3085-3112 (9 queued): the hold lost at 175, 162, 148 put over entries lost at 267, 213, 240 by the
    // goal, both counted safe, lost at 3444)
    int credOnly = decQ.b->colors > 6 && !x->o.lives && !y->o.lives && hi - lo >= rankSave / 4;
    if ((lx && !credOnly) || (!ruleNoEnemy && !(decQ.b->gameMode >= 3 && decF.under) && lo >= rankSave &&
               hi - lo < (decQ.b->colors > 6 ? rankSave / 4 : rankSave))) {
      int gx = goalKeyUnder(x), gy = goalKeyUnder(y);
      if (gx != gy) return (cmpKey = __LINE__, (gx - gy));
      // (and of two that make the first entry, or two set-ups toward it, the fewer presses: the owner, the goal first and the shortest
      // way to it, the set-up included -- a press is a press, a cursor step or a swap)
      int sx = !x->hold && setupPlay(x->k.play), sy = !y->hold && setupPlay(y->k.play);
      if (sx && sy && zipOver(x, y)) return (cmpKey = __LINE__, zipOver(x, y));
      if (gx == 0 || (sx && sy)) { int wx = lineWalk(x), wy = lineWalk(y); if (wx != wy) return (cmpKey = __LINE__, (wx - wy)); }
    }
  }
  // 1c. DOWNTIME, FLAT (the owner: flatter boards give more options): with no garbage on the board or due within two breaks' time,
  // the board not chaining and the window holding two breaks' walks, of two that live and meet the mode's list alike, the one that
  // leaves the board flatter by FLAT_ROWS or more -- the hold too
  if (lx && downtime() && x->o.j.even >= 0 && y->o.j.even >= 0 && iabs(x->o.j.even - y->o.j.even) >= FLAT_ROWS)
    return (cmpKey = __LINE__, (x->o.j.even - y->o.j.even));
  if (lx) {
    // 2. (both live) the board's own chain kept before cut short: a chain the board is making is never stopped by a line that need not
    if (cutsShort(x) != cutsShort(y)) return (cmpKey = __LINE__, (cutsShort(x) ? 1 : -1));
    // 2. (both live) within the list before outside it
    if (x->outside != y->outside) return (cmpKey = __LINE__, (x->outside ? 1 : -1));
    // 2b. (both live) the line that throws before one that throws nothing -- a three that breaks, a set-up, the hold: a board that lives
    // either way sends garbage (the owner: twice as aggressive, no threes)
    if ((thrownOf(x) > 0) != (thrownOf(y) > 0)) return (cmpKey = __LINE__, (thrownOf(x) > 0 ? -1 : 1));
    // 3. (both live) a hold that lives by the break it waits for is that break played later: a line that breaks and lives now first
    int hx = x->hold && x->o.ready == 1 && !(y->hold) && y->apBroke > 0, hy = y->hold && y->o.ready == 1 && !(x->hold) && x->apBroke > 0;
    if (hx != hy) return (cmpKey = __LINE__, (hx ? 1 : -1));
  } else {
    // 1b. (neither lives) THE BOARD'S OWN CHAIN KEPT: a line that cuts the chain the board is making short ranks after one that keeps it
    // -- unless keeping it loses the board within a break's time (rankSave): a chain begun is the attack the board already has, and the
    // three that began it is wasted once it is cut (the owner: never spoil the board's own chain)
    // -- or the board is short of panels (below the floor) and the cut breaks garbage the keeping does not, lost a break's time later: the
    // chain spends the panels a break is made from, and a board short of them finds none after it
    if (cutsShort(x) != cutsShort(y)) { const Judge *keep = cutsShort(x) ? y : x, *cut = cutsShort(x) ? x : y;
      int spends = decF.belowFloor && cut->apBroke > 0 && !(keep->apBroke > 0) && lostOf(cut) - lostOf(keep) >= rankSave;
      if (lostOf(keep) >= rankSave && !spends) return (cmpKey = __LINE__, (cutsShort(x) ? 1 : -1)); }
    // 2. (neither lives) one that breaks garbage, while it leaves the next decision the time a break takes (rankSave): the panels a
    // break converts are what the next is made from -- a break lost before the next could be made converts them for nothing
    // -- on a board short of panels (below the floor) always; on one with panels to spare, not over a line lost a break's time later (run
    // 443, pressure, 47 panels: a break lost at 193 played over a line lost at 335). Short, the panels a break converts are the next
    // break's (run 444: large_garbage 7 to 3 of 8 with the break held to the later loss everywhere)
    int bx = x->apBroke > 0 && lostOf(x) >= rankSave, by = y->apBroke > 0 && lostOf(y) >= rankSave;
    if (bx != by) { const Judge *b = bx ? x : y, *o = bx ? y : x; if (decF.belowFloor || lostOf(o) - lostOf(b) < rankSave) return (cmpKey = __LINE__, (bx ? -1 : 1)); }
    // 2'. (neither lives, under garbage) THE LINEUP FIRST: of two that break, the one that converts more full rows of the block -- the
    // lineup that keeps a slab breaking, row after row -- unless it is lost a break's time sooner: a row a line leaves is a row a later
    // break must make, and the board dies when the rows on it and coming outrun the rows broken (1d596973)
    // -- but of two lost alike, one within the mode's list before one outside it: the rows a line converts are no reason for an attack
    // the mode does not ask (the owner: every attack is what the mode asks)
    if (decF.under && bx && by && x->outside != y->outside && lostAlike(x, y)) return (cmpKey = __LINE__, (x->outside ? 1 : -1));
    if (decF.under && bx && by) { int rx = imax(0, x->apBroke) / W, ry = imax(0, y->apBroke) / W;
      if (rx != ry && (lostAlike(x, y) || (rx > ry) == (lostOf(x) > lostOf(y)))) return (cmpKey = __LINE__, (ry - rx)); }
    // 3. (neither lives) the later loss -- unless both leave the next decision the time a break takes (rankSave): those survive alike, and
    // the material, the saving and the list decide between them before the later loss does (10). Not alike: one that leaves the board
    // only that one break's time, beside one that leaves it a break's time more -- the next decision has one try where it had two.
    int alike = lostAlike(x, y);
    // (bought with the panels: alike -- boughtWithPanels)
    if (!alike && boughtWithPanels(x, y)) alike = 1;
    if (!alike && lostOf(x) != lostOf(y)) return (cmpKey = __LINE__, (lostOf(y) > lostOf(x) ? 1 : -1));
    // (neither lives, lost alike) the board's own chain kept before cut short, as for two that live
    if (cutsShort(x) != cutsShort(y)) return (cmpKey = __LINE__, (cutsShort(x) ? 1 : -1));
    // (neither lives, lost alike) THE ALLOWANCE'S RESERVE: a line that walks the input allowance below a break's walk (BREAK_WALK) after
    // one that keeps it, two breaks as two of anything else -- the break the next decisions find has to be pressed out of what is left
    // (nor over a combo the finish asks, lost no sooner: set 86 combo_storm 1, 7638, a 6x kept, lost at 300, over a 4 lost at 507)
    if (pressAllowance >= 0) {
      int rx = reserveShort(x), ry = reserveShort(y);
      if (rx != ry && !finishAsks(rx < ry ? y : x, rx < ry ? x : y)) return (cmpKey = __LINE__, (rx - ry));
    }
    // 4. (neither lives) a break in reach once the next block lands
    if (x->readyNext != NOT_ASKED && y->readyNext != NOT_ASKED && x->readyNext != y->readyNext) return (cmpKey = __LINE__, (x->readyNext ? -1 : 1));
    // 5. (neither lives) within the list before outside it -- but not between two breaks under garbage: every mode defends itself while
    // it attacks, and of two breaks that both die the list's ask is not what decides -- the garbage they break (7b) and the material they
    // leave (6, 7a) do (run 441, big chain: a combo that breaks is outside a list of 8-chains, and was ranked below a plain three)
    // -- nor, under garbage, between two that both die where the one outside it spends no panels below the floor: dying, the list's
    // order is not what keeps the board (run 491, large_garbage-6: a hold lost at 194 over a line toward a break lost at 212)
    // -- nor the hold over a line lost a break's time later: holding is no entry of the list, and lost alike past three breaks' time
    // (lostAlike) the hold put first by the list is the board left to the frame it dies, the tower growing while a line that lives on waits
    // -- but of two breaks lost alike that convert the same full rows (2'), the list decides: a combo or chain it does not ask for is the
    // one rule's last clear, after its entries and the three that breaks
    int sameBreak = decF.under && x->apBroke > 0 && y->apBroke > 0 && imax(0, x->apBroke) / W == imax(0, y->apBroke) / W;
    if (x->outside != y->outside && (sameBreak || (!(decF.under && x->apBroke > 0 && y->apBroke > 0) && !(decF.under && !x->spends && !y->spends))) &&
        !((x->hold || y->hold) && (lostOf(x) > lostOf(y) ? lostOf(x) - lostOf(y) : lostOf(y) - lostOf(x)) >= rankSave)) return (cmpKey = __LINE__, (x->outside ? 1 : -1));
  }
  // 5a. TWO THAT LIVE: the list before the material -- a board that lives either way throws the attack the list asks, not the cheaper
  // break (the owner: twice as aggressive)
  // -- and a far line earns its walk only within WALK_EARN actions of the nearer: of two that live and both attack, the one the cursor
  // walks much less is played (the owner: no big corner-to-corner moves; the far idea is still there next decision, nearer)
  if (lx && x->met >= 0 && y->met >= 0 && !x->hold && !y->hold) { int wx = lineWalk(x), wy = lineWalk(y); if (iabs(wx - wy) > WALK_EARN) return (cmpKey = __LINE__, (wx - wy)); }
  if (lx) { int ax = x->met >= 0 ? x->met : MAXAIMS, ay = y->met >= 0 ? y->met : MAXAIMS; if (ax != ay) return (cmpKey = __LINE__, (ax - ay)); }
  // 6. THE NEXT BREAK'S MATERIAL: of two breaks under garbage, the one that leaves a break to build (outcome.c nextBuild) and keeps the
  // board's floor -- before the list's entry: the list orders the breaks the board can afford
  if (x->material >= 0 && y->material >= 0 && x->material != y->material) return (cmpKey = __LINE__, (x->material - y->material));
  // 7. SAVING PANELS UP (decide.c read: begun topped and short, kept until the list's largest combo is sure): of two breaks under
  // garbage, the one whose board has more life by its panels -- before the list's entry: the board's life is its next breaks
  if (x->saving && y->saving && x->o.lifeLeft != y->o.lifeLeft) return (cmpKey = __LINE__, (x->o.lifeLeft > y->o.lifeLeft ? -1 : 1));
  // 7a. THE NEXT BREAKS' PANELS (topped under garbage, or below the floor -- a board that cannot raise, or is short): of two breaks, the
  // one that leaves more panels under the lowest garbage once everything shown has landed (judge.c readyMat, the board the readiness
  // lands) -- what a break converts lands there, and the next breaks are made of it; the board the line ends on where that was not asked
  if (decF.under && (decF.topped || decF.belowFloor) && x->apBroke > 0 && y->apBroke > 0) {
    int lx2 = x->o.j.readyMat >= 0 && y->o.j.readyMat >= 0;
    int32_t mx = lx2 ? x->o.j.readyMat : x->o.matLeft, my = lx2 ? y->o.j.readyMat : y->o.matLeft;
    if (mx >= 0 && my >= 0 && mx != my) return (cmpKey = __LINE__, (mx > my ? -1 : 1));
  }
  // 7a'. THE BREAK THAT ATTACKS (the owner: break first, but with the lineup, not a three -- attack under pressure, as the mode asks):
  // of two breaks under garbage alike so far, the one that meets the earlier entry of the list, then the one that throws more blocks,
  // then the one that makes a chain on the way -- the break is a link, and the attack goes with it
  if (!lx && decF.under && x->apBroke > 0 && y->apBroke > 0 && !x->hold && !y->hold) {
    int ax = x->met >= 0 ? x->met : MAXAIMS, ay = y->met >= 0 ? y->met : MAXAIMS;
    if (ax != ay) return (cmpKey = __LINE__, (ax - ay));
    if (x->o.j.blocks != y->o.j.blocks) return (cmpKey = __LINE__, (y->o.j.blocks - x->o.j.blocks));
    int cx = x->apWhole >= 2, cy = y->apWhole >= 2;
    if (cx != cy) return (cmpKey = __LINE__, (cx ? -1 : 1));
  }
  // 7b. UNDER GARBAGE THE RULE IS TO BREAK (the rules' underGarbage): of two breaks under garbage that neither lives, the one that breaks
  // more of it -- before the list's entry: the board's life is the garbage it gets off
  if (!lx && decF.under && x->apBroke > 0 && y->apBroke > 0 && x->apBroke != y->apBroke) return (cmpKey = __LINE__, (x->apBroke > y->apBroke ? -1 : 1));
  // 7c. THE BREAK SOONER: of two such breaks alike so far, the one whose last swap is pressed sooner -- a break put off is one a later
  // decision may put off again, each new line a few frames longer lived, till the board has no time left to make it (run 457,
  // combo_storm-6: 1585 to 1816, a break of 24 to 28 cells in every line played, never made). After the material: put before it, the
  // sooner break spends the panels the next is made of
  if (!lx && decF.under && x->apBroke > 0 && y->apBroke > 0 && x->apFire >= 0 && y->apFire >= 0 && x->apFire != y->apFire) return (cmpKey = __LINE__, (x->apFire - y->apFire));
  // 7d. AN EIGHT NEARER (the owner: an eight is set up outside the mode that fires it, in the modes leading up to the top-out, and between
  // moves -- the move that leaves a better set-up): of two lines every key above leaves equal, the one whose board is TWIN_STEP swaps or
  // more nearer a two-column combo of eight (outcome.c twinAfter) -- survival, the chain, the breaks and their material all decide first
  // (only where the nearer is lost no sooner: a set-up is never paid for with the board's life)
  // (and only within TWIN_KEY_REACH swaps: an eight farther off is set up of the moves that cost nothing -- 1'', nearerEight -- not by
  // this key over every key after it)
  int t8x = x->o.twinAfter > TWIN_KEY_REACH ? 99 : x->o.twinAfter, t8y = y->o.twinAfter > TWIN_KEY_REACH ? 99 : y->o.twinAfter;
  if (t8x >= 0 && t8y >= 0 && iabs(t8x - t8y) >= TWIN_STEP) {
    const Judge *nr = t8x < t8y ? x : y, *fr = nr == x ? y : x;
    if (nr->o.lives || (!fr->o.lives && diesAt(nr) >= diesAt(fr))) return (cmpKey = __LINE__, (t8x - t8y));
  }
  // 7e. THE FINISH'S STACK (the owner: zip and flatten for the eights -- multiple combos of eight, quickly, under pressure): in finish
  // them, of two lines every key above leaves equal, the one leaving more crossed seams ready (judge.c seamsOf: one swap finishing two
  // colours at once), then the flatter by FLAT_ROWS or more, then the more zipped (judge.c spreadOf) -- under garbage too, where no eight
  // is in reach and the rows it is sorted from are made; only between lines meeting the same entry, and where it is lost no sooner or alike
  if (finishAsked() && (x->met >= 0 ? x->met : MAXAIMS) == (y->met >= 0 ? y->met : MAXAIMS)) {
    const Judge *fb = 0; int fk = 0;
    if (x->o.j.seams != y->o.j.seams) { fb = x->o.j.seams > y->o.j.seams ? x : y; fk = __LINE__; }
    else if (x->o.j.even >= 0 && y->o.j.even >= 0 && iabs(x->o.j.even - y->o.j.even) >= FLAT_ROWS) { fb = x->o.j.even < y->o.j.even ? x : y; fk = __LINE__; }
    else if (x->o.j.spread != y->o.j.spread) { fb = x->o.j.spread > y->o.j.spread ? x : y; fk = __LINE__; }
    if (fb) { const Judge *ob = fb == x ? y : x;
      if (fb->o.lives || (!ob->o.lives && (diesAt(fb) >= diesAt(ob) || finishAlike(fb, ob)))) return (cmpKey = fk, (fb == x ? -1 : 1)); }
  }
  // 8. THE LIST: the earlier entry the judged line meets, its break as the entry asks it (rules.c metOf) -- before the kind of line, so a
  // line that keeps a topped board held is ordered by the list like every other
  // (CHAOS: under garbage with more queued, a hold is never put first by the list -- holding builds nothing while the backlog waits;
  // run 12's two Level 10 losses held 10-12% of their frames so, the hold meeting an attack entry the dig did not. The keys after decide)
  // (run 24 took every line out of the list's order under a backlog: survived 5/8, three early losses -- reverted to the hold alone)
  int chaosBacklog = decF.under && decQ.b->ninc > 0 && (x->hold || y->hold);
  { int ax = x->met >= 0 ? x->met : MAXAIMS, ay = y->met >= 0 ? y->met : MAXAIMS; if (ax != ay && !chaosBacklog) return (cmpKey = __LINE__, (ax - ay));
    // 8a. MORE THROWN (several ideas at once): of two that live and meet the same entry, the one that throws more blocks, every attack
    // its own -- two ideas fired before one. (Not of two that die: there the panels a line spends are the next break's material.)
    if (ax < MAXAIMS && lx) { int tx = thrownOf(x), ty = thrownOf(y); if (tx != ty) return (cmpKey = __LINE__, (ty - tx)); }
    // 8b. MORE DONE ON THE WAY: of two that meet the same entry, one that presses every swap of the other and more that helps -- work
    // on its way (propose.c wayLines), a second line made one with it (decide.c routeJudged), a second idea fired (search/plan.c pair)
    // -- first: the keys above found it no worse, and every step the cursor takes does something rather than only going there
    if (ax < MAXAIMS) { int cx = holdsLine(x, y), cy = holdsLine(y, x); if (cx != cy) return (cmpKey = __LINE__, (cx ? -1 : 1)); }
    // 8c. THE IDEAS KEPT: of two that live, meet the same entry and throw alike, the one whose board holds more ideas ready -- one
    // fired, the others kept, each to be fired on its own
    if (ax < MAXAIMS && lx) { if (moreIdeas(x, y)) return (cmpKey = __LINE__, (-1)); if (moreIdeas(y, x)) return (cmpKey = __LINE__, (1)); }
    // 8d. THE NEARER LINE: of two that meet the same entry, the one the cursor walks less -- a far line has to earn its walk
    if (ax < MAXAIMS) { int wx = lineWalk(x), wy = lineWalk(y); if (wx != wy) return (cmpKey = __LINE__, (wx - wy)); } }
  // 9. the tier, then its keys in turn (facts.c tierOf; the life its panels leave and the nearest break after the list's own keys)
  // (two that do not live and survive alike: the later loss, before the kind of line)
  // -- under garbage, of two alike (as many tries left) the one nearer its next break first: with no break in reach, the frames a hold
  // keeps are frames nothing is built in (run 495: large_garbage held in 1028 decisions with no break in reach and a stop of over 60)
  if (!lx && decF.under && x->o.nearAfter >= 0 && y->o.nearAfter >= 0 && x->o.nearAfter != y->o.nearAfter) {
    double lo = lostOf(x) < lostOf(y) ? lostOf(x) : lostOf(y), hi = lostOf(x) < lostOf(y) ? lostOf(y) : lostOf(x);
    int tlo = (int)(lo / rankSave), thi = (int)(hi / rankSave);
    // (and only a nearer line the input allowance affords with a break's walk to spare (BREAK_WALK): one that walks the allowance down
    // to nothing is nearer a break it cannot then press)
    const Judge *nr = x->o.nearAfter < y->o.nearAfter ? x : y;
    if (lo >= rankSave && tlo == thi && (pressAllowance < 0 || allowAtNeed(lineWalk(nr)) >= BREAK_WALK)) return (cmpKey = __LINE__, (x->o.nearAfter - y->o.nearAfter));
  }
  if (!lx && lostOf(x) != lostOf(y)) return (cmpKey = __LINE__, (lostOf(y) > lostOf(x) ? 1 : -1));
  Tier tx = tierView(x), ty = tierView(y);
  if (tx.tier != ty.tier) return (cmpKey = __LINE__, (tx.tier - ty.tier));
  // 9a. (two set-ups that live, neither clearing anything, no garbage on the board) the one that leaves more ideas ready -- before the kind of set-up
  if (tx.tier == 4 && lx && !decF.under && !clears(x) && !clears(y)) { if (moreIdeas(x, y)) return (cmpKey = __LINE__, (-1)); if (moreIdeas(y, x)) return (cmpKey = __LINE__, (1));
    if (x->o.j.seams != y->o.j.seams) return (cmpKey = __LINE__, (x->o.j.seams > y->o.j.seams ? -1 : 1));
    }
  int n = tx.nsub < ty.nsub ? tx.nsub : ty.nsub;
  for (int q = 0; q < n; q++) if (tx.sub[q] != ty.sub[q]) return (cmpKey = __LINE__, (tx.sub[q] < ty.sub[q] ? -1 : 1));
  // 10. THE PLAN KEPT (plans/gambit-infra.md F, stable): of two lines every key leaves equal, the one the last decision kept (an
  // intention) -- a plan that does not thrash is one the cursor does not swing for
  if (x->k.kept != y->k.kept) return (cmpKey = __LINE__, (x->k.kept ? -1 : 1));
  // (run 180, CHAOS: above six colours under garbage, of two lines every key leaves equal, a move before the hold -- the hold goes nowhere
  // (1'g). Run 179 insane s8, 1599-1625: 54 panels under garbage, 160-134 frames of stop, the hold kept first over a walk toward a break
  // and a line-up lost no sooner, three decisions running; lost at 2275)
  if (decQ.b->colors > 6 && decF.under && x->hold != y->hold) return (cmpKey = __LINE__, (x->hold ? 1 : -1));
  // 11. THE NEARER FIRST SWAP: of two lines every key leaves equal, the one whose first swap the cursor reaches in fewer actions
  // (core/nodes.h actionsFor, as the frame loop walks) -- the hold presses nothing, nearest of all
  { int nx = firstWalk(x), ny = firstWalk(y); if (nx != ny) return (cmpKey = __LINE__, (nx - ny)); }
  return (cmpKey = __LINE__, (0));
}
// A LINE IN WALKING ORDER: its swaps pressed in the order the cursor reaches them soonest -- from where the cursor is, each swap's walk
// counted as the frame loop walks it (core/nodes.h actionsFor) -- two swaps on a shared cell kept in the line's own order. Every order
// for a short line (WALK_ALL swaps or fewer), the nearest swap next for a longer one; of two orders that walk alike, the line's own first.
// 0 when the line's own order walks least.
// (A SWAP THAT WAITS: a swap the judge found not there to press in a walking order (judge.c cutWhy 2) is there in the line's own order,
// so it waits on what that order presses before it. walkNeeds: the swap, and the swaps the line's own order presses before it that the
// order cut had still to press -- every order made after presses one of them first. Where it had pressed them all, the swap came too
// soon after the one before it -- walkNots: no order made after presses the two one after the other. Each by its place in the line)
#define WALK_ALL 6
static int32_t walkSeq[MAXLINE], walkBest[MAXLINE], walkCost;   // (an order: each swap's place in the line's own)
static int64_t walkPlaced;
static int32_t walkNeedOf[MAXLINE], nWalkNeeds, walkNotOf[MAXLINE], walkNotAfter[MAXLINE], nWalkNots;
static int64_t walkNeedAny[MAXLINE];
static int sharesCell(int32_t a, int32_t b) { return CR(a) == CR(b) && iabs(CC(a) - CC(b)) <= 1; }
static int walkFree(const Cand *k, int i, int after) {
  if (walkPlaced >> i & 1) return 0;
  for (int p = 0; p < i; p++) if (!(walkPlaced >> p & 1) && sharesCell(k->seq[p], k->seq[i])) return 0;
  for (int w = 0; w < nWalkNeeds; w++) if (walkNeedOf[w] == i && !(walkPlaced & walkNeedAny[w])) return 0;
  for (int w = 0; w < nWalkNots; w++) if (walkNotOf[w] == i && walkNotAfter[w] == after) return 0;
  return 1;
}
static int walkStep(int row, int col, int32_t s) { return actionsFor(row, col, CR(s), CC(s), HOLDTIGHT + 1); }
static void walkAll(const Cand *k, int d, int row, int col, int after, int cost) {
  if (cost >= walkCost) return;
  if (d == k->nseq) { walkCost = cost; for (int i = 0; i < d; i++) walkBest[i] = walkSeq[i]; return; }
  for (int i = 0; i < k->nseq; i++) {
    if (!walkFree(k, i, after)) continue;
    walkPlaced |= (int64_t)1 << i; walkSeq[d] = i;
    walkAll(k, d + 1, CR(k->seq[i]), CC(k->seq[i]), i, cost + walkStep(row, col, k->seq[i]));
    walkPlaced &= ~((int64_t)1 << i);
  }
}
static int walkOrder(const Cand *k, Cand *out) {
  if (k->nseq < 2) return 0;
  int row = decQ.b->curRow, col = decQ.b->curCol, own = 0;
  for (int i = 0, r = row, c = col; i < k->nseq; i++) { own += walkStep(r, c, k->seq[i]); r = CR(k->seq[i]); c = CC(k->seq[i]); }
  walkPlaced = 0;
  walkCost = own;
  if (k->nseq <= WALK_ALL) walkAll(k, 0, row, col, -1, 0);
  else {
    int cost = 0, r = row, c = col, after = -1;
    for (int d = 0; d < k->nseq; d++) {
      int best = -1, bc = 0;
      for (int i = 0; i < k->nseq; i++) {
        if (!walkFree(k, i, after)) continue;
        int s = walkStep(r, c, k->seq[i]);
        if (best < 0 || s < bc) { best = i; bc = s; }
      }
      if (best < 0) return 0;
      after = best; walkPlaced |= (int64_t)1 << best; walkSeq[d] = best; cost += bc; r = CR(k->seq[best]); c = CC(k->seq[best]);
    }
    if (cost < walkCost) { walkCost = cost; for (int i = 0; i < k->nseq; i++) walkBest[i] = walkSeq[i]; }
  }
  if (walkCost >= own) return 0;
  *out = *k;
  for (int i = 0; i < k->nseq; i++) out->seq[i] = k->seq[walkBest[i]];
  return 1;
}
static int compareJudged(const Judge *x, const Judge *y);
// A CANDIDATE JUDGED, and in walking order too when that walks less: the walking order is played when the one order puts it no lower --
// what it makes is the engine's, as for every line; only the drops and the log's count are the line's own order's (walkTried: 1 when
// the walking order took the line's place in J). With `most` over one, a walking order the judge cut at a swap not there, or that the one order puts lower, is made again with what that taught
// (walkNeeds, walkNots: of an order played out and put lower, the first swap it pressed before one the line's own order presses
// first), up to `most` orders
// STEADY, NOT IN BURSTS (the owner): a line judged settled -- each swap once the board has stopped moving -- waits out a popping slab and
// then presses the rest at once. While a slab pops it is judged pressed straight through as well, each swap as soon as its pair is free,
// and that one is the line unless the order puts it after the settled one: the same swaps spread over the pop
static int walkTried(const Read *R, const Cand *k, Judge *J, int ok, int most) {
  static Cand w; static Judge JW;
  nWalkNeeds = nWalkNots = 0;
  for (int tries = 0; tries < most && !clockOut() && walkOrder(k, &w); tries++) {
    int32_t keepDrops[NPLAYS][NDROPS], keepCut[4], keepCutBr[4]; memcpy(keepDrops, dropped, sizeof dropped); memcpy(keepCut, cutWhy, sizeof cutWhy); memcpy(keepCutBr, cutWhyBreak, sizeof cutWhyBreak);
    int keepUnbroken = unbroken.set;
    lastCut = -1;
    int wok = judgeCand(R, &w, &JW);
    memcpy(dropped, keepDrops, sizeof dropped); memcpy(cutWhy, keepCut, sizeof cutWhy); memcpy(cutWhyBreak, keepCutBr, sizeof cutWhyBreak); unbroken.set = keepUnbroken;
    if (wok && !(ok && compareJudged(&JW, J) > 0)) { *J = JW; return 1; }
    if (!wok && (lastCut < 0 || lastCutWhy != 2 || lastCut >= k->nseq)) break;
    int learnt = 0;
    for (int p = wok ? 0 : lastCut; p < (wok ? k->nseq : lastCut + 1) && !learnt; p++) {
      int32_t at = walkBest[p];
      int64_t any = 0;
      for (int i = p + 1; i < k->nseq; i++) if (walkBest[i] < at) any |= (int64_t)1 << walkBest[i];
      if (any && nWalkNeeds < MAXLINE) { walkNeedOf[nWalkNeeds] = at; walkNeedAny[nWalkNeeds++] = any; learnt = 1; }
      else if (!any && !wok && p > 0 && nWalkNots < MAXLINE) { walkNotOf[nWalkNots] = at; walkNotAfter[nWalkNots++] = walkBest[p - 1]; learnt = 1; }
    }
    if (!learnt) break;
  }
  return 0;
}
static int judgeWalkedIn(const Read *R, const Cand *k, Judge *J, int most) { int ok = judgeCand(R, k, J); return walkTried(R, k, J, ok, most) || ok; }
static int judgeWalked(const Read *R, const Cand *k, Judge *J) { return judgeWalkedIn(R, k, J, 1); }
// (A LINE MOVED AFTER THE SORT: the line of the move that put a line on top past the order's own keys -- outlivingFirst and the eight
// here (negative: rank.c), the hold put in a line's place in decide.c rank() (positive: decide.c); 0 where none did. The label reads it:
// won=moved:k<line> / moved:d<line> -- the owner: every decision labelled, the order and the line played not disagreeing unsaid)
static int32_t rankMoved;
// sorted stably by the one order
static void outlivingFirst(Judge **a, int n) {
  // (THE LINE THAT OUTLIVES THE TOP AND BEATS IT IS THE TOP: the keys are not transitive, and a line that loses to another head to head
  // on survival can end on top through a third -- r1350, 4490: the hold played, lost at 156, over a break in progress lost at 264 that
  // beats it alone. Each line that outlives the top by a break's time and beats it compared alone moves up, a bounded number of times --
  // after the sort, and after the hold is put on top in place of a line that does nothing: decide.c)
  { int32_t keep = cmpKey;
    for (int pass = 0; pass < 4 && n > 1; pass++) { int moved = 0;
      // (run 212: above six colours a quarter of a break's time is outliving -- as lostAlike there (OUT_Q, creditPair). Run 211 8 colours:
      // the hold on top lost at 118 over an entry at 159 (insane s21 12423), 216 over a carry at 300 (thicc s22 16414), 331 over 376
      // (insane s22 3371) -- each through a third line)
      for (int i = 1; i < n; i++) if (!a[i]->o.dead && (outlives(a[i], a[0]) || OUT_Q(a[i], a[0])) && compareJudged(a[i], a[0]) < 0) {
        Judge *e = a[i]; for (int q = i; q > 0; q--) a[q] = a[q - 1]; a[0] = e; moved = 1; rankMoved = -__LINE__; break; }
      if (!moved) break; }
    cmpKey = keep; }
}
static void sortJudged(Judge **a, int n) {
  static Judge *tmp[512];
  rankMoved = 0;
  markIdle(a, n);
  for (int w = 1; w < n; w *= 2)
    for (int lo = 0; lo < n; lo += 2 * w) {
      int mid = lo + w < n ? lo + w : n, hi = lo + 2 * w < n ? lo + 2 * w : n, i = lo, j = mid, k = lo;
      while (i < mid && j < hi) tmp[k++] = compareJudged(a[j], a[i]) < 0 ? a[j++] : a[i++];
      while (i < mid) tmp[k++] = a[i++];
      while (j < hi) tmp[k++] = a[j++];
      for (k = lo; k < hi; k++) a[k] = tmp[k];
    }
  // (run 182 put the line beating the most others compared alone on top: 4/8, and the inversions labelled hardly moved (404 of 7227) --
  // most were not the sort's: answer.c's label compared after livedPrev changed (answer.c), and lines are moved after the sort. Removed)
  // (run 185, THE TOP PAIR AGREES -- the owner: the order and the line played must not disagree. The keys are not transitive: inside one
  // half of the merge the top can rise above a line it never meets, through a third (the hold over A, A over B, B over the hold). Read in
  // playOf, run 184 had 79 of 7095 decisions with the line played losing to the next compared alone, 44 of them the hold. Where the
  // second beats the top compared alone, the two change places -- nothing else in the order moves)
  // (run 185 did it here: 2/8, and the inversions labelled hardly moved (56 of 6410) -- decide.c rank() drops lines after the last sort
  // (the wasted three, the window, the short chain, amid the garbage), and a top pair never compared is left. Done at rank()'s end now)
  outlivingFirst(a, n);
  // (THE EIGHT THAT BEATS THE TOP IS THE TOP: the keys are not transitive -- an eight put first by the finish's own key beside the line
  // on top can end below it through a third line -- so in finish them, the first eight offered whole that the order puts before the top
  // line, compared with it alone, is moved up to the top)
  if (finishAsked() && n > 1 && !(a[0]->apCombo >= 8 && a[0]->apChain < 2)) {
    int32_t keep = cmpKey;
    for (int i = 1; i < n; i++) if (a[i]->k.twin == 1 && !a[i]->o.dead && a[i]->apCombo >= 8 && compareJudged(a[i], a[0]) < 0) {
      Judge *e = a[i]; for (int q = i; q > 0; q--) a[q] = a[q - 1]; a[0] = e; rankMoved = -__LINE__; break;
    }
    cmpKey = keep;
  }
  // (AN EIGHT IS WORTH THE LIFE IT COSTS, UP TO TWO BREAKS' TIME -- the owner: in finish them the eight is fired wherever its board still
  // stands two breaks' time (FINISH_8_LIFE rankSaves) with the next moves played, whatever line lives longer: the eight on offer whose
  // board stands longest, put on top -- where it leaves the input window a break's walk)
  if (finishAsked() && n > 1 && !(a[0]->apCombo >= 8 && a[0]->apChain < 2)) {
    int best = -1;
    for (int i = 1; i < n; i++) { const Judge *e = a[i];
      if (e->hold || e->o.dead || e->apCombo < 8 || e->apChain >= 2) continue;
      if (!(e->o.lives || diesAt(e) >= FINISH_8_LIFE * rankSave)) continue;
      // (run 196: nor, under garbage where no clear buys stop time (game mode 3 and up: ca.c awardStopTime), over a top line that dies
      // later than the eight -- run 195 moved the 1b goal key off there, and this move put it back: no stop time combo s8 3092 an eight
      // dying at 172 over a chain at 256, 3118 146 over 247, lost at 3116; thicc s7 16907 an eight breaking none dying at 205 over a
      // break of 6 at 213, lost at 17012)
      if (decQ.b->gameMode >= 3 && decF.under && !a[0]->o.lives && diesAt(e) < diesAt(a[0])) continue;
      if (pressAllowance >= 0 && pressAllowance - lineWalk(e) < BREAK_WALK) continue;   // (and a break's walk of the window kept: the next break is pressed from it)
      if (best < 0 || (e->o.lives && !a[best]->o.lives) || (!a[best]->o.lives && diesAt(e) > diesAt(a[best]))) best = i; }
    if (best > 0) { Judge *e = a[best]; for (int q = best; q > 0; q--) a[q] = a[q - 1]; a[0] = e; rankMoved = -__LINE__; }
  }
}
