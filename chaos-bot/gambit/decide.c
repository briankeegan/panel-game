// GAMBIT'S DECISION (plans/decision.md): read the board, propose, judge, rank, play -- in that order, once a decision.

// THE QUESTION'S OWN FACTS from the host (answer.c gb_answer): the enemy as the host sends it, whether a raise may begin
typedef struct { int32_t has, out, topKnown, top, stopKnown, stop; } Opp;
static Opp theOpp;
static int32_t garbageSeen;   // (garbage has been on the board or on its way this game)
// (WHY THE LINE PLAYED, WHEN NOT THE ORDER'S FIRST: the line of playOf that put a line other than the order's first in its place, 0 where
// the order's first is played -- answer.c logs it as won=d<line>; the order's own key is won=k<line> (rank.c cmpKey))
static int32_t decWhy;
// (the order against itself, read in playOf with the state the order was made in: decInv 1 where the line played first is put after the
// next by the order's own key (decInvKey, decInvRu), 2 where the keys leave the two alike; answer.c logs it as won=inv/won=tie)
static int32_t decInv, decInvKey, decInvRu;
static int32_t canRaiseNow, gambitHit, modeRule = -1, hostTopped, surviveAsked, chaosSmallFirst;
#define OP_FALL_LOST AT_LEVEL(200)   // (frames to the board's loss inside which an extension short of the eight gives way: set 86 combo_storm 7, its extensions lost at 130-193 and a break at 442-465; combo_storm 3's at 205, kept, made its 8; the large slabs', lost at 299-471 a second chain is still made)
#define OP_KEEP_PANELS 36   // (the panels the opener's chain leaves once landed, at least: six rows -- the owner: keep enough to break)
#define OP_FALL_KEEP AT_LEVEL(250)   // (and how much longer the line it gives way to keeps the board: set 86 combo_storm 7, a break 294-312 frames longer; combo_storm 3, 135-232, the chain the eight needed given up and the board lost all the same)
#define OPENER_LOST AT_LEVEL(90)   // (frames to the board's loss inside which the opener gives way: a second and a half, the next mode's dig)
#define OPENER_CHAINS 3
#define OP_TWO_UNDER 2   // (the chain asked under tall garbage once a chain is thrown: a two whose link breaks the slab, decide.c read)
static int tallGarbage(const Question *q);
static int32_t openerOver, openerChained, openerThrown, openerSum, openerPaused;   // (the opener played out; the longest link of the chain falling; the chains of OPENER_LEAST or more thrown, and their links added: the log's osum=)
static int32_t openerAt;     // (and the frame it was played out on: a fight's switching begins there -- answer.c modeAt)
static int32_t nswitch; static int32_t modeAt(int32_t at);   // (answer.c)
static int32_t thenRule = -1;
static int32_t opRaiseLog[5];   // (the opening raise judged: the rows short, the rows held to, the rows alive, the blocks on their way, negative where the raise was held to the first landing -- the log's opRaise=)
static int32_t carryNone;   // (why no line in progress was offered: carriedCand)
static int32_t carryJudgeDrop = -1;   // (and for 19, why the judging dropped it: rank.c DROP_*, -1 none said)
static int32_t rescues; static int32_t rescueOn;   // (decisions whose lines were all judged again past the clock: ranked, nothing judged in time)   // (the mode a named opener gives way to at the top-out; -1: none)

// 1. READ: the facts of both boards, the mode and its list, the deadline, the floor every line keeps
#define RAISE_MS 150
static int32_t raiseRefill;   // (the raise asked is the floor's, not the opening's: answer.c lets nothing go before it)
static int32_t raiseOpening, raiseTo, raiseRows;
// CHAOS: THE RAISE'S CEILING, READ OFF THE LEVEL BEING PLAYED (docs/NUMBERS.md: every number dynamic). Health never refills in chaos, so
// the stack is raised only to where it keeps the headroom the next look-ahead needs: the rows it rises on its own within HORIZON (a row
// is sixteen steps of caRiseFrames(speed) frames -- ca.c advancePassiveRaise) and CHAOS_BLOCK_ROWS more for a block landing on it. A
// faster level, or the speed's climb through a game, lowers it by itself. Never below CHAOS_RAISE_MIN rows (a board needs rows to
// break with) nor above the height less CHAOS_BLOCK_ROWS.
#define CHAOS_BLOCK_ROWS 3
static int32_t decFuelLow;   // (the fuel raise's test this decision, logged as fuel=: 0 not low, 1 low, 2 low with room)
#define CHAOS_QUEUE_WAIT 10    // (pieces waiting from which a stopped board is left quiet for the queue: run 79)
#define CHAOS_QUEUE_LIMIT 50   // (pieces waiting: the loss at this many, chaos Stack queue limit)
static int32_t chaosLetDrop;   // (decisions the board was left alone so waiting garbage could drop: the log's letDrop)
static int32_t chaosWaiting = -1;   // (the rows waiting at the last such test, -1 none: the log's q)
#define CHAOS_RAISE_MIN 3
static int32_t chaosRaiseTo(const Board *b) {
  int32_t h = b->height ? b->height : 12, perRow = 16 * caRiseFrames(b->speed ? b->speed : 1);
  int32_t risen = (HORIZON + perRow - 1) / (perRow > 0 ? perRow : 1);
  int32_t to = h - risen - CHAOS_BLOCK_ROWS;
  return to < CHAOS_RAISE_MIN ? CHAOS_RAISE_MIN : to > h - CHAOS_BLOCK_ROWS ? h - CHAOS_BLOCK_ROWS : to;
}   // (the raise asked this decision: the opening's, and the rows it raises to -- the log's raiseFor)
static int32_t refillAsked, refillReady, refillAlive;   // (the floor's raise: the rows asked, ready, alive -- the log's)
static int32_t raiseWait; static Board *raiseWaitBoard;   // (the floor's raise put off to the frame the stack takes one, and that board)
static int32_t opLineOn;
#define TA_LINKS 13        // a design this long is built at once
#define TA_DESIGN_MS 600   // the time searched on a design before it is built, at most -- a short start fired soon; the chain is
                           // taken on while it falls
#define TA_MAXSW 10        // the swaps a design may take
#define TA_EXT_WIDTH 80    // the chain going's search: the lines a level keeps, and its swaps deep (the chain puzzles: 80 and 9 went
#define TA_EXT_DEPTH 8     // furthest on the huge tower, 12 links where 40 and 6 reached 8 to 11)
#define TA_TOP 10          // the stack's top at which a design is built whatever it holds, and the raise's -- a chain is taken to 13 only
                           // with the panels for it: the chain going finds its next link 46% of the time at 8 links, 25% at 10
#define TA_MARGIN 30       // the frames to spare when the trigger goes down
#define TA_SWAP_FRAMES 16  // a design's swap, walked to and pressed: the frames it takes, near enough to know a build will be in time
#define TA_EVEN 2          // the rows the tallest column may stand over the shortest with the stack still raised to TA_TOP
#define TA_DANGER 120      // the frames left alone under which a time-attack board is played for its life: about two and a half rows of
                           // the level-11 rise (45 frames a row at rest, measured: 281 at seven rows, 374 at four)
#define TA_STAND 190      // the frames a time-attack board, raised, still stands left alone: a design's TA_MAXSW swaps walked and pressed,
                           // TA_MARGIN to spare
#define TA_STEP 4          // the design's swaps handed on a decision
#define TA_FULL 6          // the full rows a board has before a design is searched on it
// (a judged line that clears anything: a combo, a chain, a three, a clear of its own)
static int taClears(const Judge *J) {
  const Judged *j = &J->o.j;
  return j->made.cells > 0 || j->made.combo > 0 || j->made.chain > 0 || j->threes > 0 || j->nsingles > 0 || j->chainAll > 0;
}
static int32_t taxBase, taxLong, taxN, taxMs;   // (the chain going, the log's: the chain left alone, the longest found, its swaps, the ms given)
static int32_t taLog;      // (the log's: 3 the chain going taken on, 1 swaps handed, 2 the trigger, -1 the design lost, -2 no order, -3 not in time, -4 too few full rows, -10 - the judge's drop)   // (the planned opener handed on and not yet done: carried, not grown over)
static int carryHeld(void);
#define OP_TRIES 3            // (the opening plans judged in a decision, the best first)
#define CD_GROW 0.35   // (the share of the countdown's decision time left that grows the opening's plan: the designs, their judging and the plans' falls extended take the rest)
#define OPEN_SWAP_FRAMES 16   // (the frames a planned set-up takes to press, its walk with it: the plan's set-ups pressed before the next block lands -- 16.5 measured, the countdown plans of 100 opener games, their trigger's frame over their swaps)
#define OPEN_FIRE_BY 338      // (the frame the opener's trigger is pressed by while no garbage is shown: the frame before the first garbage lands, 339 in every pattern of the 99 opener games -- it lands on the stack's top, not on the chain)
#define NEAR_SAVE 3   // (the breaks' time within which a three that buys a break's time more is a save, asked of no search)
#define FINISH_ROWS 8   // the rows finish them raises a low stack to where no garbage has come: an eight's columns, and rows over them
#define LOW_ROWS 6   // a stack under this many rows of panels is raised (the floor's raise)
#define PRESS_FRAMES 3   // the frames an action of a break's walk is pressed in, held walks and taps between
#define OPENING_RAISE 600   // the opening raise's frames: the countdown and the seconds before garbage first lands (340-400 in the garbage patterns)
#define RAISE_WAIT 120   // the frames the floor's raise waits for the stack to take one, at most
static int32_t savingPanels;   // (saving panels up, across decisions; a new game ends it -- gb_new_game)
// THE FLOOR A LINE'S BOARD KEEPS, as the rule in force tests it (facts.c keepsFloor, the line's breaks aside): outcome.c asks it of the
// board every line ends on
static Keep floorKeep; static int32_t floorKeepOn;
#define MODE_DEBOUNCE 60   // the frames a mode the enemy's board calls must hold before it is played (a second): modes.js's too
// THE CHAIN THE ENEMY'S ROOM ASKS (the owner: modes are dynamic -- fill with chains, top out with a small combo, keep the next coming):
// a list's aim {"chain":"fill"} is the chains that fit the rows the enemy will have free when they land, leaving it one -- an n-chain
// lands as n - 1 rows, FILL_FLIGHT frames after it is made and FILL_LINK more a link, and the enemy rises a row every
// SPEED_TO_RISE_TIME frames of it not held by its stop (its height is the row four of its six columns reach and the rows on their way:
// GambitNative opponentOf, rowsOnItsWay).
// Every chain of three or more that fits is the mode's -- one that fills the room exactly first, then the longer -- never a 2x (the
// owner: a 3x and a 4x, or two 3x, as well as a 6x). No three-chain fits: a three-chain all the same -- fill plays chains, never combos.
#define FILL_FLIGHT 151
// (a link: its three flashing, faced and popped, the panels above hovering and falling a row -- FILL_FALL, the engine's -- read off the
// board, so every level's own: 66 at level 11)
#define FILL_FALL 15
#define FILL_LINK (decQ.b->fFLASH + decQ.b->fFACE + 3 * decQ.b->fPOP + decQ.b->fHOVER + FILL_FALL)
#define FILL_ROWS (decQ.b->height ? decQ.b->height : 12)   // (the enemy's rows: the level is both boards')
static int32_t fillN = NOT_ASKED;   // (the longest chain the room took this decision, 0 none: the log's)
static void fillList(List *L) {
  int at = -1;
  for (int i = 0; i < L->n && at < 0; i++) if (L->aim[i].chain.op == OP_FILL) at = i;
  if (at < 0) { fillN = NOT_ASKED; return; }
  int32_t top = theOpp.has && theOpp.topKnown ? theOpp.top : 0, free = FILL_ROWS - top, stop = theOpp.stopKnown ? imax(0, theOpp.stop) : 0;
  int32_t perRow = decQ.b->speed >= 1 && decQ.b->speed <= 99 ? 16 * SPEED_TO_RISE_TIME[decQ.b->speed - 1] : 120, nmax = 0;   // (chaos: a step's frames x 16)
  for (int n = MAXCHAIN; n >= 3 && !nmax; n--) { int32_t risen = imax(0, FILL_FLIGHT + FILL_LINK * (n - 1) - stop) / perRow; if (n - 1 <= free - risen - 1) nmax = n; }
  List out; memset(&out, 0, sizeof out);
  for (int n = imax(3, nmax); n >= 3 && out.n < MAXAIMS; n--) { Aim a; memset(&a, 0, sizeof a); a.chain.op = OP_EQ; a.chain.n = n; a.chain.near = 1; a.brk = -1; out.aim[out.n++] = a; }
  *L = out; fillN = nmax;
}
static int decisionFloor(const Board *b) { return floorKeepOn ? keepsFloor(&floorKeep, b, 0) : -1; }
// (TIME ATTACK'S RAISE, ON THE ENGINE'S CLOCK: the rows the board, raised, still stands `stand` frames through left alone -- the rise never
// stops, and a raise brings the top nearer by every row it lifts: a board raised into its last frames has no time left to build on)
static int32_t taRaiseRows(const Board *b, int32_t rows, int32_t stand) {
  static Board *st; if (!st) st = nb_new();
  if (!st || rows <= 0) return 0;
  int32_t ok = 0, top0 = fullTop(b);
  for (int k = 1; k <= rows; k++) {
    cloneBoard(st, b);
    int32_t f = 0;
    while (fullTop(st) < top0 + k && st->gameOverClock <= 0 && f < 40 * k) { st->input = RAISE_IN; run(st); f++; }
    if (st->gameOverClock > 0 || fullTop(st) < top0 + k) break;
    for (int32_t g = 0; g < stand && st->gameOverClock <= 0; g++) { st->input = 0; run(st); }
    if (st->gameOverClock > 0) break;
    ok = k;
  }
  return ok;
}
static int carryOpener(void);   // (the line in progress was begun under the opener: below, with the carry)
static int32_t twinWaste[5], twinWasteC, twinWasteX, twinWasteN;   // (the two-column eights taken out as wasting a three, by the test that called it so -- rank.c wasteWhy: the log's twinW=)
static CbSeq opKeepSeq; static CbGrid opKeepPrev; static int opKeepOn; static int32_t opKeepHeld, opKeepAt;   // (the next chain's design carried on, and the decisions it was: the log's keep=)
static int readBoard_(Read *R) {
  chaosOpenQuiet = 0; chaosOpenHigh = 0;   // (set again below once the raise is asked: never carried from the last decision)
  memset(R, 0, sizeof *R);
  FactSet *F = &R->F;
  factsOf(decQ.b, decQ.arr, decQ.narr, hostTopped, F);
  // (what every outcome reads of them: when the last block shown lands, and topped -- JUDGE.lastLanding, R.F.us.topped)
  decF.topped = !!F->v[FACT_US_TOPPED];
  decF.land = NOT_ASKED;
  for (int i = 0; i < decQ.narr; i++) if (decF.land == NOT_ASKED || decQ.arr[i].at > decF.land) decF.land = decQ.arr[i].at;
  if (decF.land == NOT_ASKED && F->known[FACT_US_NEXTLANDS]) decF.land = (int32_t)F->v[FACT_US_NEXTLANDS];
  decF.next = F->known[FACT_US_NEXTLANDS] ? (int32_t)F->v[FACT_US_NEXTLANDS] : NOT_ASKED;
  if (theOpp.has) { factSet(F, FACT_ENEMY_TOPPED, !!theOpp.out); if (theOpp.topKnown) factSet(F, FACT_ENEMY_HEIGHT, theOpp.top); if (theOpp.stopKnown) factSet(F, FACT_ENEMY_STOP, theOpp.stop); }
  // (no enemy board to read -- time attack, nobody across: the rules' `enemy.none`)
  factSet(F, FACT_ENEMY_NONE, !theOpp.has);
  R->enemyTopped = theOpp.has && theOpp.out; raceOn = R->enemyTopped;
  // (the frames until the board is lost if nothing is done, from the engine with the garbage the game shows landing when it lands:
  // sooner than the rise alone takes, the garbage on its way decides it -- queueKills)
  int32_t alone = diesIn(&decQ, F->v[FACT_US_DIES]);
  // (no answer -- the clock stopped it: NOT_ASKED, -1 -- is no death in -1 frames: the stack's own estimate stands; read as a frame count
  // it made the planner's urgency and the log's `dies` say the board was safe at the end of a game)
  if (alone >= 0 && alone < F->v[FACT_US_DIES]) { factSet(F, FACT_US_QUEUEKILLS, 1); F->v[FACT_US_DIES] = alone; }
  // (the rule: the mode in force, else the first whose `when` the facts hold -- with no opponent to read, the rule asking `enemy.none`;
  // else the first of the rules, so a board with nobody across still plays)
  // (THE OPENER: in a fight with no mode named, from the game's start until its chain is thrown or either board tops out -- garbage
  // landed above its top row, not garbage sent -- the opener's rule, big chains; then the mode the enemy's board picks)
  // (the opener named and a mode to follow it -- the profile's `then`, answer.c gb_then: at the top-out the named mode becomes that one,
  // nothing carried let go, as the opener gives way to the enemy's mode in a fight)
  // (THE OPENER IS OVER ONCE ITS CHAINS ADD UP -- the owner: chains to eight or more, a 3x and a 5x or two 4x alike, and a 2x counts for
  // nothing: each chain thrown its longest link, the board's chain counter at its height before it ends, counted where it is
  // OPENER_LEAST or more; over at OPENER_SUM, or OPENER_CHAINS such chains thrown, or a board topped out first)
  if (decQ.b->chainCounter > openerChained) openerChained = decQ.b->chainCounter;
  else if (openerChained && decQ.b->chainCounter == 0) { if (openerChained >= OPENER_LEAST) { openerSum += openerChained; openerThrown++; } openerChained = 0; }
  int thrown = openerSum >= OPENER_SUM || openerThrown >= OPENER_CHAINS;
  // (THE OPENER ENDS AT THE EIGHT -- the owner: get every opener to chains adding up to eight, survival after: its chains add up, or the
  // enemy tops out, or our board is about to be lost -- within OPENER_LOST, no chain of ours falling: a board topped out and standing is
  // the opener's to carry on from, the garbage broken and the next chain built from it; set 86 combo_storm 7, the opener carried on to
  // the last frame and the board lost at 697)
  int ownFalling = decQ.b->chainCounter > 0 || (opFiredAt >= 0 && decQ.b->clock - opFiredAt <= OP_FIRE_HOLD && (cascadeLive(decQ.b) || popLeft(decQ.b) > 0));
  // (nor while its plan is still pressed: a plan the board is lost under before it fires is put down for survival, and the opener ends
  // at the decision after; set 86 combo_storm 7, the opener ended at 297 with its 3's trigger a swap away)
  // (nor while a line it began is still pressed -- a break of the garbage: set 86 large_garbage 2, the opener ended at 499 with its break a
  // swap from done, and at 513 the board stood 409 frames)
  // (nor while the next chain's design is pressed and fires before the board is lost, its swaps and the slab's pop still to come counted:
  // a chain falling is a board that cannot top out --
  // set 86 large_garbage 6, a 5 designed and pressed after the 3, put down at 69 frames for a dig that left nothing to build with)
  int nextFires = opKeepOn && openerSum > 0 && decQ.b->clock - opKeepAt <= 40 && (opKeepSeq.n + 1) * OPEN_SWAP_FRAMES + popLeft(decQ.b) < F->v[FACT_US_DIES];
  int aboutLost = F->v[FACT_US_DIES] > 0 && F->v[FACT_US_DIES] < OPENER_LOST && !ownFalling && !opLineOn && !carryOpener() && !nextFires;
  // (A BOARD ABOUT TO BE LOST PAUSES THE OPENER, never ends it -- the owner: carry on after the garbage is broken: the mode after it plays
  // while the board is lost within OPENER_LOST, its breaks the board's way out, and the opener takes up again once it stands -- its
  // chains, thrown before or after, add up to the eight; set 86 combo_storm 2, a 4 thrown, the opener ended, and a 5 at 1027 the mode's)
  openerPaused = aboutLost && !openerOver;
  if (((theOpp.has && theOpp.out) || thrown) && !openerOver) {
    openerOver = 1; openerAt = decQ.b->clock;
    if (nswitch && modeRule < 0) modeRule = modeAt(0);   // (switching: the schedule's first mode from the opener's end on)
    int ni = modeRule >= 0 && thenRule >= 0 ? namedRule(modeRule) : -1;
    if (thenRule >= 0 && ((ni >= 0 && theTables.r[ni].table == 2) || modeRule < 0)) modeRule = thenRule;
  }
  inOpener = !openerOver;
  int oi = -1;
  for (int i = 0; i < theTables.n && oi < 0 && !openerOver && !openerPaused && modeRule < 0; i++) if (theTables.r[i].table == 2) oi = i;
  int pausedRule = openerPaused ? (thenRule >= 0 ? namedRule(thenRule) : nswitch ? namedRule(modeAt(0)) : -1) : -1;
  int ri = oi >= 0 ? oi : pausedRule >= 0 ? pausedRule : modeRule >= 0 ? namedRule(modeRule) : chooseRule(F);
  // (THE MODE DEBOUNCED -- the owner: a board flickering at a line does not switch the mode back and forth: the enemy topped out calls
  // finish them at once; any other change of the mode the facts call is played once it has been called MODE_DEBOUNCE frames running)
  if (oi < 0 && modeRule < 0 && ri >= 0) {
    static int32_t steady = -1, cand = -1, candAt = 0, lastClk = -1; int32_t now = decQ.b->clock;
    if (now < lastClk) steady = cand = -1;
    lastClk = now;
    if (steady < 0 || ri == steady || (theOpp.has && theOpp.out)) { steady = ri; cand = -1; }
    else { if (cand != ri) { cand = ri; candAt = now; } if (now - candAt >= MODE_DEBOUNCE) { steady = ri; cand = -1; } else ri = steady; }
  }
  if (ri < 0 && !theOpp.has && theTables.n > 0) ri = 0;
  if (ri < 0) return 0;
  const Rule *rule = &theTables.r[ri];
  R->rule = ri;
  ruleNoEnemy = asksNoEnemy(rule);
  // (A GAME WITH GARBAGE IN IT: garbage on the board once this game, or on its way -- a stack topped by its own rise is none. The floor,
  // the searches' and the rank's, and the floor's raise are the next break's material; with no garbage ever, endless, they hold the stack
  // seven rows high at forty-seven frames a row)
  if (F->known[FACT_US_CONTACT] || decQ.narr > 0 || decQ.b->ninc > 0) garbageSeen = 1;
  int garbageGame = garbageSeen;
  R->keep = rule->keep.on ? rule->keep : theTables.keep; R->keepOn = R->keep.on && garbageGame;
  floorKeep = R->keep; floorKeepOn = R->keepOn; floorOf = decisionFloor;
  R->list = rule->list; R->end = rule->end;
  // (run 97, CHAOS, THE COMBO SIZE BY THE PANELS: a four buys about 23 frames of freeze and stop a panel, an eight about 15 (40 x
  // 1.05^(c-4) stop, FLASH+FACE+POP x n) -- with the board at or under the panels it lives longest with (outcome.c lifePeakOf, 33),
  // the list's combos asked smallest first; above it, as the profile lists them (eights first: a full board needs panels off it).
  // Within W panels of the peak the last order holds. Run 95 (combos 4-6 first always): L10 seeds 15-16 8/8 at full health; run 96:
  // seeds 13-14 6/8, combo s14 lost at 2901 with 44-61 panels on the board)
  {
    static int32_t smallFirst = 0, lastClk = -1;
    if (decQ.b->clock < lastClk) smallFirst = 0;
    lastClk = decQ.b->clock;
    int32_t pn = panelsOn(decQ.b), peak = lifePeakOf();
    // (run 98: off -- by the panels L10 seeds 13-16 13/16, the gate's bot 14/16, small always 14/16: no better than the noise)
    if (0 && pn <= peak - W / 2) smallFirst = 1; else smallFirst = 0;
    if (smallFirst) {
      for (int i = 1; i < R->list.n; i++) for (int j = i; j > 0; j--) {
        const Test *a = &R->list.aim[j - 1].combo, *b = &R->list.aim[j].combo;
        if (a->op == OP_EQ && b->op == OP_EQ && !R->list.aim[j - 1].chain.op && !R->list.aim[j].chain.op && b->n < a->n) {
          Aim t = R->list.aim[j - 1]; R->list.aim[j - 1] = R->list.aim[j]; R->list.aim[j] = t;
        } else break;
      }
    }
    chaosSmallFirst = smallFirst;
  }
  // (run 110, CHAOS, ABOVE SIX COLOURS, CHAINS FOR STOP (the owner: be more purposeful with colours): the stack rises a row a second at
  // level 10 and only stop time halts it; at 8 colours a combo of 8-10 is seldom there, while a 2x -- colours stacked so one clear drops
  // a panel into the next -- buys stop (40 x 1.1^(c-2)) with six panels. The list asks a 2x, then a 3x, then a combo of four or more;
  // the profile's list as it is at six colours and fewer. Runs 101-109 at 8 colours: about 2/8, 12-14k frames on average)
  // (run 155: the 8-colour aims off, the profile's own list kept -- run 110 brought them in on the narrow search (40 x 7), measured now
  // on the wide one (64 x 6))
  // (run 155 measured them off on the wide search: 2/8 -- back on)
  if (decQ.b->colors > 6 && R->list.n > 0) {
    List L; memset(&L, 0, sizeof L);
    // (run 121: starving -- garbage on the board and under four rows' worth of panels -- each aim is met only by a line that breaks
    // garbage (facts.c: brk 1): a chain breaking nothing spends the panels the next break needs. Run 119 thicc s5, 40 -> 13 panels on
    // 2x clears breaking nothing for stop, lost at 11927)
    // (run 123: and starving whenever the garbage on the board outweighs the panels -- run 122 insane s5, ~30 panels under seven rows of
    // garbage, 2885-3058 clears of 12-14 panels breaking nothing, 33 -> 15 panels, lost at 3408)
    int32_t pn = panelsOn(decQ.b);
    // (run 124: back to the panels alone -- run 123 with the garbage weighed 4/8)
    // (run 129: with garbage on the board at all, not only starving -- run 128's losses chose 15-25 clears breaking nothing a minute,
    // 140-180 panels, with 19-32 pieces waiting)
    // (run 129 asked it under garbage at all: 3/8 -- back to starving only)
    // (run 132: starving from five rows' worth, not four -- run 131 chain s7, 2x/3x clears breaking nothing took 47 panels to 29 before
    // the rule began, then starved under garbage held on the right tower, lost at 4143)
    // (run 159 tried four rows' worth on the wide search: 3/8 -- back to five)
    int32_t brk = F->known[FACT_US_CONTACT] && pn < 5 * W ? 1 : -1;
    // (run 161: and with no garbage on the board and the stack under six rows, the chains asked only as breaks -- none can be met, so
    // nothing is asked: a chain there buys a stop that halts the rise and spends the panels the first slab is broken with. Run 160 chain
    // s7 (and runs 156-159, 1647-4637): 2x and 4x chains from 298 to 838 with no garbage near, 36 -> 21 -> 15 panels, a 6-row slab on
    // three rows at ~1028, lost at 2000)
    // (run 163: or under six rows' worth of panels whatever the tallest column -- run 161 combo s8 (as 160, 162): between waves, none on
    // the board, 2x/4x/6x chains took 63 panels to 25 (3556-4117) while a tower kept the top at six rows or more, then 20 pieces came)
    // (runs 168-169 tried seven rows' worth -- run 167 thicc s7: the opening rose to exactly 36 panels and a 12-panel chain spent the
    // board to 18 before the first slab: all game 1/8, in the opening only 0/8 (the opening grew to 48 and the chain spent that). Six)
    if (!F->known[FACT_US_CONTACT] && (panelTop(decQ.b) < LOW_ROWS || pn < 6 * W)) brk = 1;
    // (run 174 tried brk 1 whenever garbage rests on the stack: 2/8, the seed-8 opening lost three times at ~950)
    // (run 179 tried brk 1 before the first contact while garbage is on its way: 3/8 -- thicc s8 lived, insane s8 lost at 2275)
    L.aim[0].chain.op = OP_EQ; L.aim[0].chain.n = 2; L.aim[0].chain.near = 1; L.aim[0].brk = brk;
    // (run 125 dropped the 3x: 8 colours s5-6 about 2/8 -- back)
    L.aim[1].chain.op = OP_EQ; L.aim[1].chain.n = 3; L.aim[1].chain.near = 1; L.aim[1].brk = brk;
    L.aim[2].combo.op = OP_GE; L.aim[2].combo.n = 4; L.aim[2].combo.near = 1; L.aim[2].brk = brk;
    L.n = 3;
    // (run 126: a full board -- eight rows' worth of panels or more -- asks the combo first: it needs panels off it, and a combo takes
    // more of them than a 2x. Run 121 combo s6, 47-60 panels twelve rows high at the fastest rise, lost at 18990)
    // (run 127: off -- run 126 with it 4/8)
    // (run 164: on again on the wide search -- run 163 insane s8 (and 161, 6406): 54-57 panels, eight rows, under garbage with 13-14
    // waiting, 2x/3x asked first while the board had to come down, lost at 6859)
    // (run 164 had it on: 3/8, 100688 frames -- off)
    if (0 && pn >= 8 * W) { Aim c = L.aim[2]; L.aim[2] = L.aim[1]; L.aim[1] = L.aim[0]; L.aim[0] = c; }
    // (run 141: starving, any break first -- a combo of three or more that breaks garbage, ahead of the chains: every aim above asks a
    // chain or a combo of four, so a plain three-panel break met nothing and the chain breaks were taken however much they cost. Run 139
    // thicc s7, 645-765: 12-15-panel chains breaking 6 cells, 27 -> 14 panels, lost at 911)
    // (run 141: 3/8 against run 140's 4/8 -- off)
    if (0 && brk == 1) {
      for (int i = L.n; i > 0; i--) L.aim[i] = L.aim[i - 1];
      memset(&L.aim[0], 0, sizeof L.aim[0]);
      L.aim[0].combo.op = OP_GE; L.aim[0].combo.n = 3; L.aim[0].combo.near = 1; L.aim[0].brk = 1;
      L.n++;
    }
    // (run 156: and starving, any break asked last -- after the chains and the combo of four, so a plain three-panel break meets the list
    // where nothing else does, without ranking over the chains (run 141 asked it first))
    // (run 156: 3/8 -- off)
    if (0 && brk == 1) {
      memset(&L.aim[L.n], 0, sizeof L.aim[L.n]);
      L.aim[L.n].combo.op = OP_GE; L.aim[L.n].combo.n = 3; L.aim[L.n].combo.near = 1; L.aim[L.n].brk = 1;
      L.n++;
    }
    R->list = L;
  }
  // (EIGHT AND UP -- the owner: 8x plus, 9s and 10s alike: in a list that asks combos and no chain, an entry of exactly eight asks eight
  // or more -- a two-column eight of 11 or 12 panels is the attack asked, never a combo outside the list taken out as a wasted three;
  // set 86 combo_storm 1, 261 of 277 eights taken out so)
  { int chain = 0; for (int i = 0; i < R->list.n; i++) if (R->list.aim[i].chain.op) chain = 1;
    if (!chain) for (int i = 0; i < R->list.n; i++) { Test *c = &R->list.aim[i].combo; if (c->op == OP_EQ && c->n == 8) c->op = OP_GE; }
    // (ANY COMBO BEFORE A THREE -- the owner: in finish them a three is the last resort, and every combo beats it: in a list that asks combos
    // and no chain, its entry of exactly four asks four or more, so a 7 meets the list as a 4 does and is never a combo outside it)
    if (!chain) for (int i = 0; i < R->list.n; i++) { Test *c = &R->list.aim[i].combo; if (c->op == OP_EQ && c->n == 4) c->op = OP_GE; } }
  // (WHAT THE OPENER STILL NEEDS IS ASKED -- the owner: a 6 and a 3 are the eight: with chains thrown, the opener's list asks a chain of
  // what is still needed in its place among its own entries, where none of them asks it)
  // (and under tall garbage, a chain of two that breaks it after the rest of the eight: its link breaks the slab chaining, the chain lives
  // while it pops, and the converted row comes down as its next link -- the second chain begun a pop sooner)
  // (the opener in force, or paused for the board's life: its chains still add up, and what it still needs is asked all the same)
  int opOn = !openerOver && (theTables.r[ri].table == 2 || openerPaused);
  opNeed = opOn ? imax(OPENER_LEAST, OPENER_SUM - openerSum) : 0;
  needKept = 0; needLost = -1;
  if (opOn && openerSum > 0) {
    // (in its place: before the first entry asking a shorter chain, unless one asks it already)
    int32_t need = imax(OPENER_LEAST, OPENER_SUM - openerSum), at = R->list.n, have = 0;
    for (int i = R->list.n - 1; i >= 0; i--) { const Test *t = &R->list.aim[i].chain; int32_t n = t->op == OP_GE ? t->n : t->op == OP_GT ? t->n + 1 : 0;
      if (!n) continue; if (n == need) have = 1; if (n < need) at = i; }
    if (!have && R->list.n < MAXAIMS) {
      Aim a; memset(&a, 0, sizeof a); a.chain.op = OP_GE; a.chain.n = need;
      for (int i = R->list.n; i > at; i--) R->list.aim[i] = R->list.aim[i - 1];
      R->list.aim[at] = a; R->list.n++;
    }
    if (tallGarbage(&decQ) && need > OP_TWO_UNDER && R->list.n < MAXAIMS) { Aim a; memset(&a, 0, sizeof a); a.chain.op = OP_GE; a.chain.n = OP_TWO_UNDER; a.brk = 1; R->list.aim[R->list.n++] = a; }
  }
  fillList(&R->list);
  R->guides = R->list;
  R->by = deadlineOf(F, rule);
  // (THE OPENER BEFORE THE GARBAGE: an opening chain fires before the next block lands, or it is not begun -- a chain the block lands on
  // spends the panels the board digs out with; one already begun is the line in progress, never dropped for the frame: rank.c judgeCand)
  if (oi >= 0 && ri == oi && decF.next != NOT_ASKED && decF.next > 0 && (R->by == NOT_ASKED || decF.next < R->by)) R->by = decF.next;
  // (below the material floor a step that clears and breaks nothing is out, as the judge drops it)
  R->belowFloor = garbageGame && R->keepOn && R->keep.t[KEEP_MATERIAL].op && !test(F->v[FACT_US_MATERIAL], R->keep.t[KEEP_MATERIAL]);
  theList = R->list; listOn = 1; decF.belowFloor = R->belowFloor;
  // (an eight is set up ahead wherever some mode asks one -- outcome.c twinAfter, rank.c 7d)
  twinWanted = 0;
  for (int i = 0; i < theTables.n && !twinWanted; i++) for (int k = 0; k < theTables.r[i].list.n; k++) { const Test *t = &theTables.r[i].list.aim[k].combo; if ((t->op == OP_GE || t->op == OP_GT || t->op == OP_EQ) && t->n + (t->op == OP_GT) >= 8) twinWanted = 1; }
  // (garbage on the board: the search asks every entry to break it too; garbage on it or topped out, the deadline is a break's -- before
  // the board dies; the rule's `by` is an attack's)
  R->under = !theTables.underIgnore && F->known[FACT_US_CONTACT];
  if (R->under) { for (int i = 0; i < R->guides.n; i++) R->guides.aim[i].brk = 1; R->end = 1; }
  decF.under = R->under;
  // (the owner: the reason is dying -- the rise tops the board out as surely as garbage lands on it, and the moves that keep it alive are
  // the same)
  R->dying = R->under || (F->known[FACT_US_DIES] && F->v[FACT_US_DIES] > 0 && F->v[FACT_US_DIES] < HORIZON + REST);
  // (time attack's own line: the rise is never still, so at level 11 a board under eight rows is within HORIZON + REST of its top all
  // the time; the raise, the design and the hold give way to the board's life inside TA_DANGER frames only)
  R->taDying = R->under || (F->known[FACT_US_DIES] && F->v[FACT_US_DIES] > 0 && F->v[FACT_US_DIES] < AT_LEVEL(TA_DANGER));
  // (and after its entries, the one rule's three that breaks (rules.c withRule): the list as the board asks it, the searches' and the
  // rank's alike)
  // (the rank's list is the mode's as written -- a combo of eight is ranked before one of six whatever the searches are led toward)
  R->asked = R->guides;
  if (R->under) guideShort(&R->guides);
  if (R->under) { withRule(&R->guides); withRule(&R->asked); }
  if (R->under) { withAttacks(&R->guides, &R->list); withAttacks(&R->asked, &R->list); }
  // (A LIST ENDED BY "default" -- every list under garbage -- falls back to the default's own move when none of it can be made: the
  // break search looks off it when it finds no break within it (breakSearch), the searches that aim keep to it, and the order takes a
  // line off it only by living where nothing within it does)
  R->topped = !!F->v[FACT_US_TOPPED]; R->breakWaits = !!F->v[FACT_US_BREAKWAITS];
  // (SAVING UP PANELS, as the raise holds a band: begun topped with four rows' worth of panels or fewer, and kept until the board holds
  // eight rows' worth and the panels sure to make the list's largest combo ((size - 1) x colours and one); then it spends again)
  {
    int32_t colours = decQ.b->colors > 0 ? decQ.b->colors : 1, panels = panelsOn(decQ.b), big = 3;
    for (int i = 0; i < R->list.n; i++) { const Test *t = &R->list.aim[i].combo; if (t->op == OP_GE || t->op == OP_EQ || t->op == OP_GT) big = imax(big, t->n + (t->op == OP_GT)); }
    int32_t low = 4 * W, high = imax((big - 1) * colours + 1, 8 * W);
    if (!savingPanels && R->topped && panels <= low) savingPanels = 1;
    else if (savingPanels && panels >= high) savingPanels = 0;
    R->saving = savingPanels;
    // (the board fuller than it lives longest with -- the life table's peak -- and not saving: while the owner's band saves panels up,
    // the band decides, never the table)
    // (CHAOS: kept. Run 12 turned it off -- run 11 chain_garbage had spent 54 panels to 18 with 10 pieces queued -- and survival fell
    // from 6/8 to 4/8: a board kept high has less room for the next block. Back on)
    R->full = !savingPanels && panels > lifePeakOf();
  }
  if (R->under || R->topped) R->by = NOT_ASKED;
  // (ready: garbage on its way and none on the board -- the frames until the next block lands, 0 for one queued to drop once settled)
  R->readyAt = NOT_ASKED;
  if (!R->under) { for (int i = 0; i < decQ.narr; i++) if (R->readyAt == NOT_ASKED || decQ.arr[i].at < R->readyAt) R->readyAt = decQ.arr[i].at; if (R->readyAt == NOT_ASKED && decQ.b->ninc) R->readyAt = 0; }
  // (the opening raise: until garbage first reaches the board, below `to` rows and no chain running -- and after it, the rules' material
  // floor kept by raising, a reserve: below it, not topped, the panels under `to` -- garbage on them aside, a slab is no panel to break
  // with -- the rows the next break is made of brought in)
  int32_t to = rule->raiseTo ? rule->raiseTo : theTables.raiseTo;
  if (to < 0) to = chaosRaiseTo(decQ.b);   // (chaos: the rules' "raise": {"to": -1} -- the ceiling read off the level being played)
  int opening = !gambitHit && !F->known[FACT_US_CONTACT] && !R->topped && decQ.b->clock < OPENING_RAISE;
  // (and A LOW STACK: under LOW_ROWS rows of panels, not topped, it is raised all the same -- the owner's rule: below six rows, raise high;
  // in a game garbage has reached or is on its way to -- the owner: the opener raise changed only where it kills, and with no garbage
  // ever it does: endless at level 11, 15 of 28 raising, 25 of 28 not)
  int refill = !opening && garbageGame && (R->belowFloor || panelTop(decQ.b) < LOW_ROWS) && !R->topped;
  // (CHAOS, THE FUEL RAISE: the bot never raised in any game, and its losses ran out of panels -- insane s5 at 2124, 5 colours at
  // 2755, panels 5-8 with nothing to break with. Garbage in play, no break on it to build and fewer than two threes of panels: raise
  // a row -- fresh panels from below -- when the whole stack, garbage and all, still leaves a break's time (levelBreak) of rise after
  // it, at this speed (caRiseFrames, read off the level); asked only when the game takes a raise (chaosRaisable, below))
  int chaosFuelRaise = 0; decFuelLow = 0;
  if (!opening && garbageGame && !R->topped) {
    // (run 38: "no garbage break and fewer than two threes" never passed on the boards that lose -- 3-5 threes scattered over
    // 7-16 panels; never raised in runs 37-38. Fuel under garbage is the panels under it, the next break's material: under two rows'
    // worth (2 x W) is low. With no garbage, fewer than two threes)
    int fuelLow = garbageOn(decQ.b) ? materialOn(decQ.b) < 2 * W : groupsOn(decQ.b) < 2;
    int32_t rowFrames = 16 * caRiseFrames(decQ.b->speed), roomRows = decQ.b->height - fullTop(decQ.b) - 1;
    decFuelLow = fuelLow ? (rowFrames > 0 && roomRows * rowFrames >= levelBreak ? 2 : 1) : 0;   // (logged: fuel=1 low, 2 low with room)
    if (fuelLow && rowFrames > 0 && roomRows * rowFrames >= levelBreak) { refill = 1; chaosFuelRaise = 1; }
  }
  // (and FINISH THEM'S RAISE: the eights it fires need rows to sort -- three to five tall in two columns side by side -- so a stack
  // under LOW_ROWS is raised to FINISH_ROWS in a game garbage has not reached too; set 86 endless, a stack of four rows cleared by 4s
  // and 6s, no eight in reach in four decisions of five)
  int finishRefill = !opening && !refill && !garbageGame && finishAsked() && panelTop(decQ.b) < LOW_ROWS && !R->topped;
  if (finishRefill) { refill = 1; if (!rule->raiseTo || rule->raiseTo > FINISH_ROWS) to = FINISH_ROWS; }
  // (TIME ATTACK'S RAISE: no design being built and the stack under its top -- the owner: flatten, raise to the top, then the chain; no
  // garbage is coming, so the rows are raised as they are, never held to a break's readiness. The top is TA_TOP less each row the tallest
  // column stands over the shortest past TA_EVEN: an uneven stack raised to TA_TOP puts its tallest column where the rise ends it)
  // (run 281: above six colours the top lowered only past TA_EVEN + 1 rows of unevenness -- seven colours flatten slowly, and runs 277-280's
  // 15:6 stood on ~30 panels: the chain going takes a falling chain on with the panels there are; run 258 took the lowering off whole)
  int32_t taTo = TA_TOP - imax(0, evenOf(decQ.b) - (decQ.b->colors > 6 ? TA_EVEN + 1 : TA_EVEN));
  int taRaise = ruleNoEnemy && !opening && !refill && !R->topped && !R->taDying && !taOn && panelTop(decQ.b) < taTo;
  if (taRaise) to = taTo;
  // (run 253: and with nobody across the opening raises to time attack's top too, not to the chaos ceiling, which keeps room for blocks
  // that cannot come there -- run 247 tried it on run 241's bot (the design never built then): rows a minute up, one stage fewer. Now the
  // design is searched and built (runs 251-252): Line Clear 15:6 at 28-29 rows a minute where about 32 are asked)
  if (ruleNoEnemy && opening && !R->topped && taTo > to) to = taTo;
  raiseRefill = refill; raiseOpening = opening; raiseTo = to;
  int32_t rowsUp = to - (opening ? fullTop(decQ.b) : panelTop(decQ.b));
  if (chaosFuelRaise) { to = panelTop(decQ.b) + 1; rowsUp = 1; }   // (one row at a time: the next decision asks again)
  raiseRows = rowsUp;
  // (CHAOS: A RAISE IS AN OPTION ONLY WHEN THE GAME TAKES ONE -- the owner: the decision is offered only when it is allowed. The chaos
  // engine raises on the press only with no swap queued, no shake, nothing moving, nothing in the top row and no raise running
  // (ca.c controls and the manual raise: rise lock, panels_in_top_row, prevent_manual_raise); otherwise no raise is asked or waited for)
  int chaosRaisable = !swapQueued(decQ.b) && decQ.b->shakeTime == 0 && !hasActivePanels(decQ.b) && !hasPanelsInTopRow(decQ.b) &&
                      !decQ.b->preventManualRaise && !decQ.b->manualRaise;
  // (rank.c compareJudged: the opening keeps its panels -- while under LOW_ROWS rows (the owner: below six rows, raise high). Run 58
  // insane s10: kept to frame 600 the opening grew 30 to 48 panels, eight rows, and every line was judged dying from 484 at that height)
  // (run 114: never above six colours -- the stack climbs past six rows in the opening whatever is kept there, and the chains set up
  // are never fired: run 113 8 colours insane s4, 30 -> 48 panels by frame 458 on set-ups alone, lost at 1007)
  // (run 114 tried it at six colours or fewer only: 8 colours s3-4 2/8 -- openings lower (30-38 panels), three run-113 survivors lost; back)
  // (run 137: above six colours a row higher -- the stack passes six rows by ~450 at 8 colours and the opening then fires its chains
  // before the first garbage: run 136 thicc s7, a carry clearing 12 at 498 with no garbage near, 45 -> 24 panels by the first slab, lost
  // at 2106; runs 58 and 114: eight rows kept is every line judged dying)
  // (run 137 kept it to seven rows above six colours: 4/8 against 6/8 -- back to six)
  chaosOpenQuiet = opening && panelTop(decQ.b) < LOW_ROWS;
  // (run 162: above six colours between waves too -- no garbage on the board, the stack under six rows: what is kept is what the next
  // wave is broken with. Run 161 combo s8 (and run 160, 5028): 63 -> 25 panels between waves (3574-4180, none on the board), then about
  // eight rows of slabs on three or four rows at ~4690, buried by 4975, lost at 4842)
  // (run 162: 2/8 -- off)
  if (0 && !chaosOpenQuiet && decQ.b->colors > 6 && !F->known[FACT_US_CONTACT] && !R->under && panelTop(decQ.b) < LOW_ROWS) chaosOpenQuiet = 1;
  // (run 160: and the other side -- above six colours, the opening's stack at seven rows or more makes room: rank.c)
  chaosOpenHigh = opening && decQ.b->colors > 6 && panelTop(decQ.b) >= LOW_ROWS + 1;
  R->low = to && (opening || refill || taRaise) && rowsUp > 0 && chaosRaisable; R->up = R->low && !cascadeLive(decQ.b) && canRaiseNow;
  refillAsked = refillReady = refillAlive = 0; raiseWait = 0; opRaiseLog[4] = 0;
  // (THE FLOOR'S RAISE, TIMED: a board busy now -- a cascade, panels moving, the shake -- is one the engine would not raise; it is run on,
  // left alone with the garbage shown landing as the game lands it, to the first frame it would (search/ready.c raiseOpenIn), and the
  // raise is judged on that board and pressed then)
  Question rq = decQ;
  // (and THE OPENING'S RAISE, TIMED THE SAME: the owner -- raise up to 11 before the first garbage; a chain begun first holds the raise
  // shut until it ends, and the garbage lands on the board short of it: set 86 combo_storm 5 fill, the raise asked from 192 and never
  // pressed, the chain's links spending the panels 36 to 11, the board lost at 766; the players raise in the first second, then build)
  if (0 && (refill || opening) && R->low && !R->up && !clockOut()) {   // (chaos: never waited for -- a raise is asked only when taken now)
    if (!raiseWaitBoard) raiseWaitBoard = nb_new();
    int32_t w = raiseWaitBoard ? raiseOpenIn(&decQ, RAISE_WAIT, raiseWaitBoard) : NOT_ASKED;
    if (w > 0) {
      rq.b = raiseWaitBoard; rq.holdLeft = 0; rq.holdStarted = 0;
      rq.narr = 0; for (int i = 0; i < decQ.narr; i++) if (decQ.arr[i].at > w) { rq.arr[rq.narr] = decQ.arr[i]; rq.arr[rq.narr++].at -= w; }
      rowsUp = to - panelTop(raiseWaitBoard);
      if (rowsUp > 0) { R->up = 1; raiseWait = w; }
    }
    if (!R->up) refillAsked = -(w == NOT_ASKED ? 1 : 2);   // (asked, and the stack takes no raise within RAISE_WAIT: -1, or nothing to raise once it does: -2)
  }
  // (the raise is held for as many rows as leave the board a plan once everything the game shows has landed -- and alive while they rise)
  if (R->up) {
    double l = leftMs(); if (l < 1) l = 1;
    raiseOpens = opening;
    int32_t rows = taRaise ? taRaiseRows(rq.b, rowsUp, AT_LEVEL(TA_STAND)) : raiseReady(&rq, rowsUp, l < RAISE_MS ? l : RAISE_MS);
    // (THE FLOOR'S RAISE ON A BOARD TOO SHORT TO BREAK: below the floor, no row count leaves a break once everything lands -- the panels
    // a break is made of are what the board lacks -- so the rows the board lives through once everything lands are raised all the same:
    // the panels are the next break's material, and the opening's raise is held to readiness, never the floor's)
    // (and THE OPENER'S RAISE, the same -- the owner: the opener raises the moment it is flat; its plan is built on the board raised and
    // fired before the block lands, so the readiness it is held to is its own, not the raise's)
    refillAsked = refill ? rowsUp : 0; refillReady = rows; refillAlive = raiseAlive;
    int opRaise = opening && R->rule >= 0 && theTables.r[R->rule].table == 2;
    if (rows <= 0 && (refill || opRaise)) rows = raiseAlive;
    // (and, the opening's raise and the floor's alike: garbage on its way or on the board, never more than the board lives through once
    // it lands -- a raise ends the stop the board is held up by -- and never the stack's top, garbage on it counted, up to the top row: a
    // raise into the garbage is a death)
    if ((rq.narr > 0 || R->under) && rows > raiseAlive) rows = raiseAlive;
    { int32_t h = rq.b->height ? rq.b->height : 12; rows = imin(rows, h - 1 - fullTop(rq.b)); }
    if (opening) { opRaiseLog[0] = rowsUp; opRaiseLog[1] = rows; opRaiseLog[2] = raiseAlive; opRaiseLog[3] = raiseFirstOnly ? -rq.narr : rq.narr; opRaiseLog[4] = 1; }
    // (the opening's raise a row a decision: the next decision looks again, and garbage told of meanwhile stops it where the board lives
    // through it -- set 86 large_garbage 2 finish: four rows raised at 192 in one go, a tall block told of at 209, the board lost at 744)
    if (opening && rows > 1) rows = 1;
    if (rows <= 0) { R->up = R->low = 0; raiseWait = 0; } else to = fullTop(rq.b) + rows;
  }
  R->to = to;
  R->pop = popLeft(decQ.b) > 0;
  // (what the board left alone makes while a chain falls or a slab pops, as the game counts it -- for the log)
  ownChainBy = ownChainN = 0;
  if (cascadeLive(decQ.b) || R->pop) {
    ownChainOf(&decQ);
    Outcome a = leftAlone();
    if (!a.dead) { R->aloneChain = a.j.chainAll; Made z = { 0, 0, 0, 0 }; R->aloneOut = !fitsList(&R->list, z, &a.j, 0); }
  }
  return 1;
}

// 2-4. PROPOSE, JUDGE AND RANK: every candidate offered -- the hold among them -- judged by its outcome and put in the one order. With
// none that lives and time left, the survival search proposes its line too.
#define MAXCANDS 128
#define NINTENT 4   // the intentions a decision keeps (keepIntents)
#define NROUTE 10   // the routes a decision judges (routeJudged)
#define PROPOSED (2 * MAXCANDS)   // what the proposers may offer; past MAXCANDS, every play keeps its share (fairShare)
static Cand theCands[PROPOSED];
static int32_t cappedN;   // the candidates left unjudged past MAXCANDS, a decision (the log's capped=)
// EVERY PROPOSER ITS SHARE: past MAXCANDS, the candidates are taken a play at a time -- each play's first, then each play's second, in the
// order each offered them -- so a proposer offering last is never the one cut; how many are left, counted
static int fairShare(Cand *c, int n, int cap) {
  cappedN = n > cap ? n - cap : 0;
  if (n <= cap) return n;
  static Cand kept[MAXCANDS]; static uint8_t taken[PROPOSED];
  memset(taken, 0, sizeof taken);
  int k = 0;
  while (k < cap) {   // (a round: each play's next)
    int seen[NPLAYS] = { 0 }, any = 0;
    for (int i = 0; i < n && k < cap; i++) {
      if (taken[i]) continue;
      int p = c[i].play;
      if (seen[p]++ != 0) continue;
      kept[k++] = c[i]; taken[i] = 1; any = 1;
    }
    if (!any) break;
  }
  for (int i = 0; i < k; i++) c[i] = kept[i];
  return k;
}
#define NSTRIP 12   // the lines judged again with one swap left out (THE THREE TAKEN OUT)
#define STRIP_LINES 3   // the best lines that waste a three, each judged again so
static Judge theJudged[MAXCANDS + 4 + NINTENT + NROUTE], *order[MAXCANDS + 6 + NINTENT + NROUTE + NSTRIP], stripped[NSTRIP];
static int32_t orderN;   // (the lines in the order the move was picked from: decide's n)
static int32_t phaseMs[3];
static Outlived svJob; static int32_t svJobDone;   // (the survival search already searched on a worker: answer.c breakJob)
static int carriedCand(const Read *R, Cand *k, int *wait);
static void pvKeep(const Judge *k, int first, int32_t qid); static int32_t pvSet, pvId, pvNew, pvKind, pvV[5];   // (pvKind: 0 not asked, 1 same, 2 not played, 3 the line ends past this frame, 4 lost, 5 clock, 6 rows, 9 a cell -- pvV its row, column, field, foreseen, real -- 10 a head field -- its index in pa.c HEAD from 1, foreseen, real -- 11 the rise timer, thousandths)
static int32_t carryRule(void);   // (the mode the line in progress was begun in)
static int carriedFromReady(void), carryWaitsOut(void);
static void readySpread(int n), readyStop(void);
static int keptJudged(const Read *R, int n), routeJudged(const Read *R, int n);
static const Judge *carriedJ;   // the line in progress among the ranked, for the log
static const Judge *carryCrossJ;   // the line in progress begun in another mode, offered as any line (carryNone 23)
// (THE OPENER'S LINE IN PROGRESS -- the owner: the opener is one continuous string; only a line no longer possible is put down: the
// carried line, whatever the filters after its judging take out, while it lives or presses its last swap before the next block lands)
static const Judge *opCarried;
static int32_t carrySave;   // (the line in progress was begun on a three let through as the save: carryOf -- it keeps that leave while it is carried on)
static int32_t carryTwo;   // (and begun on a 2x let through: it keeps that leave too)
static const Judge *strippedCarry;   // (the line in progress without the swap that makes its three: THE THREE TAKEN OUT)
// THE BOARD AFTER A LINE AND THE BEST ON (contLostOf): the line played to its end, the survival search asked of the board it leaves with
// the garbage still on its way, for `give` ms (SAVE_MS at most, an equal part of the decision's own time each); the frame that board is lost, 1e9 if it lives, -1 if
// it could not be asked. The hold's board is the board left alone. A line lost before its end is lost where the judge saw it lost, and a
// board the search finds no line on is lost where it is lost left alone.
#define SAVE_MS 10
#define SAVE_KEEP_MS 4
static int32_t saveAsked, saveNot, saveOk;   // (saves asked of the survival search this decision, the threes it found not needed, and whether it found one needed: the log's, and the frame loop's count)
static int32_t saveBlind;   // (a three kept as the save because the save check gave no answer this decision: the log's)
static double saveCw = -1, saveCk = -1;
static double svLost = -1; static int32_t svClean;   // (the survival search's loss from now this decision, and whether its line wastes no three: the save's other side)
static double saveRoomMs(void) { return C2.due ? C2.due - C2.margin - nowMs() : 1e9; }
#define CONT_LINES 6   // (the lines judged with the survival search run on after them, a decision: decide.c, the life after the line)
#define COMBO_TIMED 3   // (the combo lines judged pressed later, a decision: decide.c, the combo timed for its stop)
#define COMBO_WAIT 30   // (the frames between the waits tried)
#define COMBO_WAIT_MAX 120
static int32_t comboTimed;   // (the frames waited for a combo this decision, 0 none: the log's timed=)
#define CUT8_LINES 4   // (the combos so tried a decision)
#define CUT8_MS 4      // (the judging's time for each eight tried with one swap more: decide.c, the eight without its chain)
#define CONT_MS 6      // (the survival search's time for each)
static int32_t contAsked;   // (the lines so judged this decision: the log's cont=)
static double contLostOf(const Judge *J, double give) {
  static Board *eb; if (!eb) eb = nb_new();
  if (J->o.dead) return J->o.lostAt >= 0 && J->o.lostAt != FOREVER ? (double)J->o.lostAt : -1;
  if (!eb) return -1;
  endNoKeep = 1;
  const Board *e = J->hold ? lineEnd(0, 0, 0) : lineEnd(J->k.seq, J->k.nseq, J->settled);
  endNoKeep = 0;
  if (!e) return -1;
  cloneBoard(eb, e);
  int32_t dt = imax(0, eb->clock - decQ.b->clock);
  Question q2 = decQ; q2.b = eb; q2.holdLeft = 0; q2.holdStarted = 0; q2.narr = 0;
  for (int a = 0; a < decQ.narr; a++) if (decQ.arr[a].at > dt) { q2.arr[q2.narr] = decQ.arr[a]; q2.arr[q2.narr++].at -= dt; }
  // (the moves after the line are pressed out of the window the line leaves, at the frame it ends: core/nodes.h winPast)
  winPast = dt; winGone = J->hold ? 0 : J->o.j.spent;
  Outlived c = outlive(&q2, HORIZON + REST, REST, give, OUT_DEPTH, 30);
  winPast = 0; winGone = 0;
  int32_t lost = c.set ? c.lostAt : diesIn(&q2, HORIZON + REST);
  if (lost < 0) return -1;
  return lost == FOREVER ? 1e9 : (double)dt + lost;
}
static int32_t noopWaits;   // (swaps of the line played handed on as a wait: a swap and its swap back -- playOf)
static int32_t putOffCut;   // (clears taken out for blocks that have not landed: the log's)
static int32_t twoDropped, windowCut;   // (lines taken out as a 2x not taken to three -- the log's)
static int32_t twoWhy; static double twoLostLog, twoKeptLog;   // (what let the 2x rule take one out: 1 a line kept lives, 2 one is lost a break's time on, 3 the 2x is lost no later -- the log's)
static int32_t samesTrimmed;   // (the line played judged again without its swaps of one colour -- the log's)
static int32_t opGrew;   // (the opening grown this decision: 1 for its plan, 2 grown only, the stack being raised -- the log's)
static int32_t chainUp, chainNow, chainAfter;   // (the opener's second hand this decision: 2 a trigger fired, 1 a set-up pressed, -1 turned down; the trigger chain before and after: the log's)
#define OP_TRY_LOG 8
#define OP_NEXT_SHARE 0.5   // (the share of a decision's time the next chain's design is searched in)
#define OP_NEXT_COST 20   // (a swap's worth in the next chain's design: a 3 kept to some eleven swaps -- a long build is pressed late, its board lost under a slab before it fires)
static int32_t opNextCut, opNextCutCell, opNextSeq[16], opNextSeqN; static char opNextRows[200];   // (an unjudged design: the swap cut at and its cell, its swaps, the board -- the log's ndcut=)
static int32_t opNextCh, opNextLen, opNextMs, opNextDrop;   // (opNextDrop: an unjudged design's drop (rank.c DROP_*) * 10 + its cut's why)   // (and its chain designed, its swaps)
static int32_t opNextDesign;   // (the next chain designed this decision: its chain as judged; -1 none designed, -2 short of the need, -3 not judged, -4 its board lost -- the log's nd=)
static int32_t carryWaste[5];   // (the line in progress taken out as a wasted three: why (rank.c wasteWhy), its whole chain, the board's own, its threes, lost -- the log's waste=)
static int32_t opTryLog[OP_TRY_LOG][8], opTryN, opTrySeq[3][OP_DEPTH + 1], opTrySeqN[3];   // (the opener's plans judged: pass, swaps, planned chain, judged chain, fire frames from now, verdict -- the log's opTries=)
static int32_t opKept;   // (the opener's plan played over a line ranked above it for a later loss: the log's opKept=1)
static int32_t opLinkCands, opLinkBest;   // (the lines ranked this decision whose break is a chain's link, and the longest chain of them: the log's linkCands=)
static int32_t amidDropped; static double amidBest;   // (lines among the slabs that break nothing, not played, and the latest own loss of them -- the log's amid=count/lost)
static int32_t opSpent, opSpentMat, opSpentHeld;   // (the opener's chains refused for spending the board: 1 the extension, 2 the link, 4 the second chain, 8 a set-up while it lands; the panels the last refused leaves once landed, and holding's -- the log's spent=)
static int32_t opFallBar, opFallExt, opFallSeen, opFallTop, opFallDead, opFallWay, opFallLink, opFallLinkCh;   // (opFallWay: 1 the extension to the eight, 7 the line that keeps the board over an extension short of it that loses it, 2 a second chain that adds to it, 3 an extension short of it, 6 garbage broken by a link, 5 the garbage broken
                                                                                   // for the next chain, 4 a set-up short of it)
static int32_t opFallLine[8][6], opFallLineN;   // (each extension under the fall: its swaps, those the judge pressed, its chain as judged, lost, its chain as its search said, the frames to its loss -1 living: the log's fallLines=)   // (and the extensions in the order: how many, the longest judged chain of those not lost, those lost)   // (under the falling chain: the chain the hold reaches, the extension's played, 0 none -- the log's fallBar=)
static int32_t opTried, opFallHeld, opFalling, opFallAt = -1, opFiredAt = -1;   // (the opening plans judged this decision; the lines the opener's falling chain held off this decision: the log's; the opener's chain still falling)
static int32_t carryBeganAt = -1, carryBeganPlay = -1;
// (an extension of the falling chain: a line played as one -- PLAY_EXTEND, or PLAY_LINEUP, the same search's lines while a garbage slab
// pops beside the chain -- or the line in progress begun as one)
// (an extension of the chain falling: an extend or a lineup, or the line in progress begun as one -- or begun as finish's entry, the chain
// it fired still falling when the mode turns back to the opener: run 4148 combo_storm 6, 563, the entry's 8 in progress, lost at 366,
// passed for an extend's 5 lost at 231, the board lost at 804)
static int opExtLine(const Judge *J) { int p = J->k.play; int b = carryBeganPlay; return p == PLAY_EXTEND || p == PLAY_LINEUP || ((J->carried || J == carryCrossJ) && (b == PLAY_EXTEND || b == PLAY_LINEUP || b == PLAY_ENTRY)); }
// (an eight still loaded on the board the line ends on -- one swap from firing)
static int loadedAfter(const int32_t *seq, int n) {
  static Board *eb; if (!eb) eb = nb_new(); if (!eb) return 0;
  const Board *e = lineEnd(seq, n, 0);
  if (!e) return 0;
  cloneBoard(eb, e);
  return twinCostOn(eb) == 0;
}
static int32_t freeSetup;   // (the second hand this decision: 1 a set-up swap pressed over the hold, 2 one before the carried line, 3 the whole eight before it; -1 to -6 asked and turned down, -7 the whole eight turned down, -8 the second eight's swap unloading the first; 0 not asked: the log's)
static int32_t reachCut;   // (lines taken out for walking past the reach this decision: the log's reach=)
static int goalKeyOf(const Judge *J);
// (the swaps of a line before its first step past the reach)
static int reachPrefix(const Judge *J) {
  int r = decQ.b->curRow, c = decQ.b->curCol;
  for (int i = 0; i < J->k.nseq; i++) { int sr = CR(J->k.seq[i]), sc = CC(J->k.seq[i]); if (iabs(sr - r) + iabs(sc - c) > REACH_STEPS) return i; r = sr; c = sc; }
  return J->k.nseq;
}
static int reachesFar(const Judge *J) {
  int r = decQ.b->curRow, c = decQ.b->curCol;
  for (int i = 0; i < J->k.nseq; i++) { int sr = CR(J->k.seq[i]), sc = CC(J->k.seq[i]); if (iabs(sr - r) + iabs(sc - c) > REACH_STEPS) return 1; r = sr; c = sc; }
  return 0;
}
// (every line keeps to the reach -- breaks, attacks and set-ups alike: the owner's rule is the cursor's, not the line's kind)
static int farForNothing(const Judge *J) { return !J->hold && reachesFar(J); }
// (THE SWAP JUST PRESSED: the two panels the last swap pressed swapped, left and right as they stood after it -- for the next decision
// only: one that holds or raises lets it go, the board having moved on (answer.c, front.c set it))
static int32_t undoIdL = -1, undoIdR = -1, undoFresh;
static int32_t undoCut;   // (lines taken out for swapping them straight back this decision: the log's undo=)
// (A LINE THAT SWAPS THEM STRAIGHT BACK: its first swap trades the same two panels back where they were -- the owner: no flip and back,
// and a flip pressed by one decision and taken back by the next is two swaps for nothing)
static int undoesLast(const Judge *J) {
  if (J->hold || !__atomic_load_n(&undoFresh, __ATOMIC_ACQUIRE) || J->k.nseq < 1) return 0;
  int r = CR(J->k.seq[0]), c = CC(J->k.seq[0]);
  if (r < 0 || r >= decQ.b->nrows || c < 1 || c + 1 > W) return 0;
  int32_t L = decQ.b->p[r][c].f[ID], R = decQ.b->p[r][c + 1].f[ID];
  return (L > 0 || R > 0) && L == __atomic_load_n(&undoIdL, __ATOMIC_RELAXED) && R == __atomic_load_n(&undoIdR, __ATOMIC_RELAXED);
}
// (THE LINES A FILTER TAKES OUT: every one it names, whatever the board -- the owner: everything is an emergency, that is not good enough.
// The hold names nothing and is always kept. Returns the lines kept)
static int cutAlways(Judge **ord, int n, int (*named)(const Judge *), int32_t *cut, int carryWhy) {
  int m = 0;
  for (int i = 0; i < n; i++) { Judge *J = ord[i];
    if (named(J)) { (*cut)++; if (J == carriedJ) { carriedJ = 0; carryNone = carryWhy; } if (J == opCarried) opCarried = 0; continue; }
    ord[m++] = J; }
  return m;
}
// THE NEXT BLOCK'S RESERVE (the owner: don't overspend if it's killing you; it's all about efficiency): with garbage on the board or on its
// way, while the hold's own board stands a break's time, a line that breaks none of it is taken out where it leaves less than the next
// break needs -- the panels it settles to under the rule's material floor and fewer than the hold keeps, or, where it does not live, the window
// under a break's walk (BREAK_WALK) by the sooner of the next block's landing and the hold's own loss. Taken out of the order and held to
// at the end of the move, whatever put the line there: the opener's chain, a set-up between moves, a dig
static const Judge *overHold; static int overMat; static Test overFloor; static int32_t overCut;
static int32_t overNeedAt(void) {
  int32_t t = EARLIEST_LANDING;
  for (int a = 0; a < decQ.narr; a++) if (decQ.arr[a].at >= 0 && decQ.arr[a].at < t) t = decQ.arr[a].at;
  { int32_t q = holdQueueAt(); if (q != NOT_ASKED && q >= 0 && q < t) t = q; }
  if (overHold && !overHold->o.lives && diesAt(overHold) < t) t = (int32_t)diesAt(overHold);
  return t < 0 ? 0 : t;
}
static int overspends(const Judge *J) {
  if (!overHold || J->hold || J->o.dead || J->apBroke > 0) return 0;
  // (the floor holds a line that lives too: it lives through the garbage told, and the storm tells more -- the rule's floor is for the
  // breaks of what is not told yet)
  // (only beside a hold that lives as well: a life is never given up for the floor)
  if (overMat && (!J->o.lives || overHold->o.lives) && J->o.matSettled >= 0 && !test(J->o.matSettled, overFloor) && overHold->o.matSettled > J->o.matSettled) return 1;
  if (J->o.lives) return 0;
  // (a dig toward a break, or a perch let down, with none offered: on the dig's own terms -- rank.c digPaid)
  return pressAllowance >= 0 && !digPaid(J) && allowLeftAt(overNeedAt(), lineWalk(J)) < BREAK_WALK;
}
static int32_t stallCut, enPlayed;   // (lines taken out as stalls under garbage this decision: the log's stall=)
static int digsForBreak(const Judge *J);
// (THE WAY TO THE ACTION -- the owner: instead of waiting, walk over to the area it needs to get to and flatten or zip along the way, so it
// is closer to the action: the target is the next swap of the line in progress that waits for the board, else under garbage the cell
// under the lowest garbage nearest the cursor -- where the next break is made. A level or zip line that ends nearer it than the cursor
// stands is on the way)
static int enOn, enR, enC;
static int enRoute(const Judge *J) {
  if (!enOn || J->hold || J->o.dead || J->k.nseq < 1 || (J->k.play != PLAY_LEVEL && J->k.play != PLAY_ZIP)) return 0;
  int lr = CR(J->k.seq[J->k.nseq - 1]), lc = CC(J->k.seq[J->k.nseq - 1]);
  return iabs(lr - enR) + iabs(lc - enC) < iabs(decQ.b->curRow - enR) + iabs(decQ.b->curCol - enC);
}
static int stallsUnder(const Judge *J) { return !J->hold && !J->o.lives && !(J->apBroke > 0) && !digsForBreak(J) && !enRoute(J) && !flattenFree(J) && !finishFree(J) && J->k.play != PLAY_CONVERT && J->k.play != PLAY_CARRY && J->k.play != PLAY_CARRYWAIT; }
static int32_t needlessTrimmed;   // (swaps taken out of the line played that it lost nothing without: the log's)
static int32_t combosDropped;   // (combos the mode does not ask for, played as a line without one: the log's)
static void dropCombo(const Read *R, Judge *J) {
  static Judge t;
  // (in the time to the move's own frame, the host's hard stop, where there is one)
  double due = clockDue, share = clockShare;
  if (clockFrameOut) { clockDue = 0; clockShare = 0; }
  for (int i = 0; i < J->k.nseq && J->k.nseq >= 2 && !clockOut(); i++) {
    Cand c = J->k; c.nseq = J->k.nseq - 1;
    for (int q = i; q < c.nseq; q++) c.seq[q] = J->k.seq[q + 1];
    if (!judgeCand(R, &c, &t) || t.o.dead || J->o.dead || comboOutside(&t)) continue;
    if (!!t.o.lives < !!J->o.lives || lostOf(&t) < lostOf(J) || imax(0, t.apBroke) < imax(0, J->apBroke) || goalKeyOf(&t) > goalKeyOf(J)) continue;
    if ((wastesThree(&t) && !wastesThree(J)) || (cutsShort(&t) && !cutsShort(J))) continue;
    t.carried = J->carried; t.first = J->first; t.wait = J->wait; t.waitMax = J->waitMax; t.saving = J->saving; t.material = J->material;
    *J = t; combosDropped++; break;
  }
  clockDue = due; clockShare = share;
}
// A 2x MADE A PLAIN BREAK, AS AN OPTION (the owner: a 2x that cannot go to three may be made a plain break instead): the line is
// judged with each of its swaps left out in turn, and the first that makes no 2x not taken to three, lives as long, is lost no sooner
// and breaks as much is offered beside it
static int twoMadeThree(const Read *R, const Judge *J, Judge *out) {
  Judge t;
  double due = clockDue, share = clockShare;
  if (clockFrameOut) { clockDue = 0; clockShare = 0; }
  int done = 0;
  for (int i = 0; i < J->k.nseq && J->k.nseq >= 2 && !clockOut() && !done; i++) {
    Cand c = J->k; c.nseq = J->k.nseq - 1;
    for (int q = i; q < c.nseq; q++) c.seq[q] = J->k.seq[q + 1];
    if (!judgeCand(R, &c, &t) || shortChain(&t)) continue;
    if (!!t.o.lives < !!J->o.lives || lostOf(&t) < lostOf(J) || imax(0, t.apBroke) < imax(0, J->apBroke)) continue;
    if ((wastesThree(&t) && !wastesThree(J)) || (cutsShort(&t) && !cutsShort(J))) continue;
    t.carried = 0; t.first = J->first; t.wait = J->wait; t.waitMax = J->waitMax; t.saving = J->saving; t.material = J->material;
    *out = t; done = 1;
  }
  clockDue = due; clockShare = share;
  return done;
}
static int32_t twoRemade;   // (2x lines made a plain break: the log's)
static int32_t carryShort;   // (the swaps of the line in progress let go past a walk the window does not hold: the log's carryShort=)
static int ranked(const Read *R, const Found *S) {
  memset(dropped, 0, sizeof dropped); memset(offered, 0, sizeof offered); memset(cutWhy, 0, sizeof cutWhy); memset(cutWhyBreak, 0, sizeof cutWhyBreak);
  carriedJ = 0; carryCrossJ = 0; opCarried = 0; orderN = 0; twoDropped = 0; windowCut = 0; putOffCut = 0; twoWhy = 0; twoRemade = 0; samesTrimmed = 0; needlessTrimmed = 0; reachCut = 0; stallCut = 0; overCut = 0; overHold = 0; enPlayed = 0; undoCut = 0; amidDropped = 0; amidBest = -1; noopWaits = 0; unbroken.set = 0; saveAsked = saveNot = saveOk = saveBlind = 0; saveCw = saveCk = -1; svLost = -1; svClean = 0;
  ideaAims = &R->guides; ideasAsks = 0; rankHold = 0;
  double t0 = nowMs();
  int nc = fairShare(theCands, proposeAll(R, S, theCands, PROPOSED), MAXCANDS), n = 0;
  double t1 = nowMs();
  for (int i = 0; i < nc; i++) offered[theCands[i].play]++;
  readyDefer = 1;   // (the proposers above ask readiness whole; the judging below ranks first)
  readyStop(); readyPendClear(); readyCollect = 1;   // (and keeps each landed board: searched once, its nearest break measured)
  rankReact = C2.reaction + 1;
  rankSave = rankReact + decQ.b->fFLASH + decQ.b->fFACE + decQ.b->fPOP * (3 + W);   // (pa.c matchGarbagePanels: a row of W cells)
  // (THE LINE IN PROGRESS JUDGED FIRST: its swaps are already on the board, so it is read before any proposed line, while the decision
  // has its time -- judged after them it was let go unread hundreds of times a run, the move's own frame reached before its judge pressed
  // a swap. Its judging runs to the host's hard stop (clockFrameOut) all the same)
  static Judge carryPre; Cand ckPre; int ccPre = 0, cwaitPre = 0, carryPreOk = 0;
  carryNone = 21; carryJudgeDrop = -1; carryShort = 0;
  { double pd = clockDue, ps = clockShare; if (clockFrameOut) { clockDue = 0; clockShare = 0; }
    if (R->guides.n && (ccPre = carriedCand(R, &ckPre, &cwaitPre))) { lastDrop = -1; carryPreOk = judgeCand(R, &ckPre, &carryPre); if (!carryPreOk) { carryNone = 19; carryJudgeDrop = lastDrop; } }
    clockDue = pd; clockShare = ps; }
  enOn = 0;
  if (ccPre && cwaitPre && ckPre.nseq > 0) { enR = CR(ckPre.seq[0]); enC = CC(ckPre.seq[0]); enOn = 1; }
  else if (decF.under) {
    const Board *b = decQ.b; int gr = 0;
    for (int r = 1; r < b->nrows && !gr; r++) for (int c = 1; c <= W && !gr; c++) if (b->p[r][c].f[ISGARBAGE]) gr = r;
    if (gr > 1) { int bc = -1; for (int c = 1; c <= W; c++) if (b->p[gr][c].f[ISGARBAGE] && (bc < 0 || iabs(c - b->curCol) < iabs(bc - b->curCol))) bc = c;
      enR = gr - 1; enC = imin(bc, W - 1); enOn = 1; }
  }
  for (int i = 0; i < nc; i++) if (judgeWalked(R, &theCands[i], &theJudged[n])) { order[n] = &theJudged[n]; n++; }
  // (NOTHING JUDGED IN TIME: the searches and the proposing took the decision's time and the clock stopped the judge on every line --
  // every line is judged again up to the move's own frame, the host's hard stop (clockFrameOut): a board is never held for want of a
  // look at its lines. The line in progress and the hold are judged in that time too.)
  double rescueDue = clockDue, rescueShare = clockShare; int rescue = 0;
  if (!n && nc && clockFrameOut && clockOut()) {
    rescue = 1; clockDue = 0; clockShare = 0;
    // (its hard stop RESCUE_FRAMES sooner, for the rest of the decision -- the line in progress and the hold judged after it, the ranking
    // and the answer are frames too: native.c frameOut; the host clears it at the next question)
    rescueOn = 1;
    for (int i = 0; i < nc; i++) if (judgeWalked(R, &theCands[i], &theJudged[n])) { order[n] = &theJudged[n]; n++; }
  }
  n = keptJudged(R, n);   // (the intentions the last decision kept, found again)
  // (the line in progress: first of its tier when its next step is due now; one whose next step must wait for the board is a hold
  // until then -- it ranks with the hold)
  Cand ck = ckPre; int cwait = cwaitPre, cc = ccPre;
  // (THE LINE IN PROGRESS IS JUDGED WHATEVER THE DECISION'S CLOCK SAYS: it comes after every proposed line, and where their judging took
  // the decision's time -- or a search's share of it still in force -- the clock stops its judge before a swap is pressed: a line whose
  // swaps are already on the board would be let go unread for a line read in time. Its judging always runs to the move's own frame, the
  // host's hard stop (clockFrameOut), as the judging of a decision with nothing judged in time does)
  double carryDue = clockDue, carryShare = clockShare; int carryOwnTime = !rescue && clockFrameOut;
  if (carryOwnTime) { clockDue = 0; clockShare = 0; }
  if (cc && carryPreOk) theJudged[n] = carryPre;   // (judged first, above)
  if (R->guides.n && cc && carryNone != 19) {
    carryNone = 0;
    Judge *cj = &theJudged[n];
    cj->wait = cwait;
    if (cwait) cj->waitMax = 1; else if (!carriedFromReady()) cj->first = 1;   // (its place: rank.c tierView)
    // (A WAIT THAT DOES NOT END: a line that has waited CARRY_WAITS decisions for a board that has not settled -- under garbage it may
    // never -- is offered beside the same line pressed straight through, below, ranked with the hold as every wait is: the owner, no lazy
    // waits -- a wait is taken only where it outranks every line that presses -- and a line is put down only when it is no longer there)
    if (cwait && carryWaitsOut()) { cj->carried = 1; order[n] = cj; n++; carriedJ = cj; carryNone = 22; }
    // (A LINE BEGUN IN ANOTHER MODE -- the owner: the modes as the enemy's board calls them: past a switch the line in progress is carried
    // on only where it meets the new mode's first entry or breaks garbage; else it is offered as any line, ranked on what it makes)
    else if (carryRule() != R->rule && !goalLine(cj) && !(cj->apBroke > 0)) { order[n] = cj; n++; carryNone = 23; carryCrossJ = cj; }
    else { cj->carried = 1; order[n] = cj; n++; carriedJ = cj; if (opLineOn && (cj->o.lives || decF.next == NOT_ASKED || (cj->apNats > 0 && cj->apAts[cj->apNats - 1] < decF.next))) opCarried = cj; }
    // (and, the board still moving, the same line pressed straight through -- each swap as soon as the board lets it, not once the
    // board has settled: a slab converting is frames the line can be pressed in)
    static Judge thru;
    Cand k2 = ck; k2.settled = 0; k2.play = PLAY_CARRY;
    if (cwait && judgeCand(R, &k2, &thru)) { thru.carried = 1; order[n] = &thru; n++; }
  }
  if (carryOwnTime) { clockDue = carryDue; clockShare = carryShare; }
  // (the hold, always: the chain the board makes alone is the board's, however far past the list it runs -- never one to stop)
  Judge *H = &theJudged[n];
  holdCand(R, 0, H);
  if (rescue) { clockDue = rescueDue; clockShare = rescueShare; rescues++; }
  order[n] = H; n++;
  for (int i = 0; i < n; i++) if (order[i] != H && digWaits(order[i], H, C2.reaction + 1)) order[i]->wait = 1;
  breakOffered = 0; for (int i = 0; i < n && !breakOffered; i++) breakOffered = order[i]->apBroke > 0;
  sortJudged(order, n);
  // (THE ROUTE: the best lines that make something, two on columns apart made one line, judged whole and ranked with the rest)
  { int n0 = n; n = routeJudged(R, n); if (n > n0) sortJudged(order, n); }
  // (READY, ASKED BEST FIRST: every option is ranked on what the judging alone says; then, in the time left and best-ranked first, each
  // that does not live yet is asked whether a break is there once everything lands -- the break search on the landed board, an equal
  // part of the time left each of those still to be asked -- and the order is made again)
  readyDefer = 0; readyCollect = 0; readyFresh = 1;
  // (the line in progress too: a line that lived by a break in reach lives on by it, its landed board the one already searched)
  #define READY_ASKS(J_) (!(J_)->o.lives && !(J_)->o.dead && (J_)->o.ready == NOT_ASKED)
  // (THE KEPT PLAN'S LINES -- intentions and routes -- take none of the decision's own search: their readiness is what the workers or
  // the kept breaks already hold, so the time is shared only over the lines the decision would ask with no plan kept)
  #define EXTRA(J_) ((J_)->k.kept || (J_)->k.route)
  readySpread(n);
  int toAsk = 0;
  for (int i = 0; i < n; i++) toAsk += READY_ASKS(order[i]) && !EXTRA(order[i]);
  // (BY YIELD: a board with a break in reach by the shape math has one found for it half the time; one with none, settled, once in
  // fifty, in nearly all of the time a decision spends on readiness -- so those in reach are asked first, best-ranked first, and the
  // rest in the time left)
  for (int pass = 0; pass < 2; pass++)
  for (int i = 0; i < n && leftMs() > 0; i++) {
    Judge *J = order[i];
    if (!READY_ASKS(J) || (J->o.j.readyNear < NEAR_MISS) != (pass == 0)) continue;
    readyKnownOnly = EXTRA(J);
    if (!readyKnownOnly) readyShare(toAsk--);
    if (J->hold) holdCand(R, J->wait, J);
    else {
      static Judge again; Cand kc = J->k;
      if (judgeCand(R, &kc, &again)) {
        again.wait = J->wait; again.first = J->first; again.waitMax = J->waitMax; again.carried = J->carried;   // (its place in the order kept: the line in progress)
        again.outside = again.outside || J->outside;
        *J = again;
      }
    }
  }
  readyShare(0); readyFresh = 0; readyKnownOnly = 0;
  sortJudged(order, n);
  // (none lives, or garbage is on the board or on its way (vanilla 7f4d709234, ported run 302): each is asked too whether a break is in reach
  // once the next block lands -- the order puts those first)
  if (!(n && order[0]->o.lives) || decF.under || garbageComing()) {
    int own = 0; for (int i = 0; i < n; i++) own += !EXTRA(order[i]);
    for (int i = 0; i < n; i++) if (!EXTRA(order[i])) { readyShare(own--); readyNextFor(order[i]); }
    readyShare(0); sortJudged(order, n);
  }
  // (THE GARBAGE LET DOWN (the perch -- the owner: break the garbage, set up the break): under garbage, nothing living and no line of
  // the decision breaking, the swap that lets the garbage down off its tallest column is offered too (propose.c letDownCand), and the
  // order is made again with the boards at rest read (rank.c letsDown) -- once every line's readiness has been asked: a decision that
  // has a break, or a line that lives, is the same decision without it)
  if (decF.under && !breakOffered && n && !order[0]->o.lives) {
    int breaks = 0; for (int i = 0; i < n && !breaks; i++) breaks = order[i]->apBroke > 0;
    if (!breaks) {
      static Cand lk; static Judge letJ;
      if (!clockOut() && letDownCand(&lk)) { offered[PLAY_LEVEL]++; if (judgeCand(R, &lk, &letJ)) { order[n] = &letJ; n++; } }
      rankHold = H; sortJudged(order, n);
    }
  }
  double t2 = nowMs();
  surviveAsked = 0;
  // (the survival search's line, the backup where nothing lives: the worker's whenever it has finished -- it was searched beside the
  // decision, in the searches' time -- else searched here in what time the decision has left)
  int svDone = __atomic_load_n(&svJobDone, __ATOMIC_ACQUIRE);
  if (!(n && order[0]->o.lives) && (svDone || leftMs() > 0)) {
    surviveAsked = 1;
    Outlived sv = svDone ? svJob : outliveSave(&decQ, HORIZON + REST, REST, leftMs(), OUT_DEPTH, 30);
    offered[PLAY_SURVIVE] = sv.set && sv.nseq ? 1 : 0;
    Cand sk;
    if (sv.set && sv.nseq && candOf(&sk, PLAY_SURVIVE, sv.seq, sv.nseq, -1, 0)) { sk.settled = 0; if (judgeWalkedIn(R, &sk, &theJudged[n + 1], sk.nseq)) { readyNextFor(&theJudged[n + 1]); svClean = !wastesThree(&theJudged[n + 1]); order[n] = &theJudged[n + 1]; n++; sortJudged(order, n); } }
    if (sv.set) svLost = sv.lostAt == FOREVER ? 1e9 : sv.lostAt;
  }
  // (THE LIFE AFTER THE LINE -- the owner: survival is not the line that buys the most frames alone, with nothing pressed after it: in
  // every mode, where nothing lives, the best lines -- in finish them the combos first -- are each judged with the survival search run on
  // from the board they leave (contLostOf), with the window that line leaves, and ranked on the later of that and their own loss: a line
  // lost at 137 if nothing more is pressed, on a board with room for the next block made by the next moves, is no emergency that only a
  // chain answers, and a line that walks the window out has no moves after it)
  // (asked up to the move's own frame, the host's hard stop, as the judging is -- the decision's own time is spent by then -- each line its
  // own CONT_MS)
  contAsked = 0;
  if (n && !order[0]->o.lives && clockFrameOut && !clockFrameOut()) {
    double due = clockDue, share = clockShare; clockDue = 0; clockShare = 0;
    for (int pass = 0; pass < 2; pass++)
      for (int i = 0; i < n && contAsked < CONT_LINES && !clockFrameOut(); i++) {
        Judge *J = order[i];
        if (J->hold || J->o.lives || J->o.dead || (pass == 0) != (finishAsked() && J->apCombo >= 4)) continue;
        double sh = clockShareBegin(nowMs() + CONT_MS);
        double c = contLostOf(J, CONT_MS); contAsked++;
        clockShareEnd(sh);
        if (c > 0) { int32_t f = c >= 1e9 ? FOREVER : (int32_t)c; if (J->extLost == NOT_ASKED || f > J->extLost) J->extLost = f; }
      }
    clockDue = due; clockShare = share;
    if (contAsked) sortJudged(order, n);
  }
  // (THE COMBO WITHOUT ITS CHAIN -- the owner: make the eight, and before or after it move the panels so the ones that fall make no
  // chain: in finish them, a combo of four or more on offer that sends a chain -- the best CUT8_LINES of them -- is judged
  // again with one swap more, after its trigger, then before its first, near its trigger's rows; the first whose combo is no smaller,
  // that sends no chain and whose board is lost no sooner, or is safe (FINISH_SAFE), takes its place -- a combo with a 2x tried as well;
  // for one past 2x, a 2x where no swap stops the chain whole)
  if (finishAsked() && n && clockFrameOut && !clockFrameOut()) {
    double due = clockDue, share = clockShare; clockDue = 0; clockShare = 0;
    int cut = 0, tried = 0;
    for (int i = 0; i < n && !clockFrameOut(); i++) {
      Judge *E = order[i];
      if (E->hold || E->o.dead || E->apCombo < 4 || E->apChainAll < 2 || E->k.nseq + 1 > MAXLINE || tried >= CUT8_LINES) continue;
      tried++;
      int tr = CR(E->k.seq[E->k.nseq - 1]), done = 0;
      static Judge CE, C2E; int have2 = 0;
      for (int side = 0; side < 2 && !done; side++)
        for (int r = imax(1, tr - 1); r <= tr + 4 && !done && !clockFrameOut(); r++)
          for (int c = 1; c < W && !done && !clockFrameOut(); c++) {
            int32_t seq[MAXLINE]; int ns = 0;
            if (side == 1) seq[ns++] = r * 8 + c;
            for (int q = 0; q < E->k.nseq; q++) seq[ns++] = E->k.seq[q];
            if (side == 0) seq[ns++] = r * 8 + c;
            Cand k; if (!candOf(&k, PLAY_ENTRY, seq, ns, E->k.aim, 0)) continue;
            k.settled = 0; k.twin = E->k.twin; k.x = E->k.x;
            double sh = clockShareBegin(nowMs() + CUT8_MS);
            int ok = judgeCand(R, &k, &CE);
            clockShareEnd(sh);
            if (!ok || CE.o.dead || CE.apCombo < E->apCombo || CE.apChainAll > 2) continue;
            // (lost no sooner, or safe at the finish -- FINISH_SAFE on, where key 1 counts both as living and the shorter chain wins)
            if (!(CE.o.lives || finishSafe(&CE) || (!E->o.lives && diesAt(&CE) >= diesAt(E)))) continue;
            // (no chain at all first -- the owner: finish them sends combos, not chains; a 2x kept for a line past it where none is found)
            if (CE.apChainAll >= 2) { if (E->apChainAll >= 3 && !have2) { C2E = CE; have2 = 1; } continue; }
            *E = CE; done = 1; cut++;
          }
      if (!done && have2) { *E = C2E; cut++; }
    }
    clockDue = due; clockShare = share;
    if (cut) sortJudged(order, n);
  }
  // THE THREE TAKEN OUT: each of the best lines that waste a three, judged again with one of its swaps left out at a time -- the line
  // without the swap that makes the three, where it does as well, is a line the order below keeps
  strippedCarry = 0;
  { int ns = 0, tried = 0, none = !(n && order[0]->o.lives), n0 = n;
    // (the line in progress first, whatever its place: without the swap that makes its three it is still the line in progress -- carried,
    // its swaps pressed so far not for nothing -- where otherwise the order puts it down whole as a wasted three)
    // (not where the list asks a chain: a chain's line is its swaps' order, and one swap left out is a chain begun from another place --
    // fill on seed 86, 25 and 23 against 26 and 26 with it on)
    int asksChain = 0; for (int i = 0; i < theList.n; i++) if (theList.aim[i].chain.op) asksChain = 1;
    int ci = -1; if (!asksChain) for (int i = 0; i < n0; i++) if (order[i] == carriedJ) ci = i;
    for (int i0 = -1; i0 < n0 && tried < STRIP_LINES && ns < NSTRIP && leftMs() > 0; i0++) {
      int i = i0 < 0 ? ci : i0;
      if (i < 0 || (i0 >= 0 && i == ci)) continue;
      const Judge *J = order[i];
      if (J->hold || !wastesThree(J) || J->k.nseq < 2) continue;
      tried++;
      for (int s = 0; s < J->k.nseq && ns < NSTRIP && leftMs() > 0; s++) {
        int32_t seq[MAXLINE]; int m = 0;
        for (int q = 0; q < J->k.nseq; q++) if (q != s) seq[m++] = J->k.seq[q];
        Cand k;
        if (!candOf(&k, J->k.play, seq, m, J->k.aim, J->k.extend)) continue;
        k.settled = J->k.settled; k.way = J->k.way;
        if (!judgeCand(R, &k, &stripped[ns]) || wastesThree(&stripped[ns])) continue;
        if (J == carriedJ && !asksChain && !strippedCarry) { stripped[ns].carried = 1; strippedCarry = &stripped[ns]; }
        if (none) readyNextFor(&stripped[ns]);
        order[n++] = &stripped[ns++];
      }
    }
    if (ns) sortJudged(order, n);
  }
  // NO WASTED THREE (the owner: only when not doing it would kill it): a line whose clears break nothing and throw nothing is taken out
  // of the order -- unless every other line is lost within a break's time (rankSave) and a three lives, or is lost later: only there is
  // a three a save
  { int keeps = 0, wasteLives = 0; double wasteLost = -1, keptLost = -1;
    for (int i = 0; i < n; i++) {
      if (wastesThree(order[i])) { if (order[i]->o.lives) wasteLives = 1; else if (lostOf(order[i]) > wasteLost) wasteLost = lostOf(order[i]); }
      else if (order[i]->o.lives) keeps = 1; else if (lostOf(order[i]) > keptLost) keptLost = lostOf(order[i]);
    }
    // (A SAVE NEAR THE END: every line that keeps its threes lost within NEAR_SAVE breaks' time, and the three lost a break's time later or
    // lives -- the three is the save, asked of no search: by the time the rule's break's time comes the window is too short to press it.
    // Live p65, r661, 8348: the hold lost in 104 frames, a break's time and seven, the line that would have lived 242 frames longer
    // dropped as a wasted three, and the board lost 50 frames later)
    int nearSave = raceOn && keptLost >= 0 && keptLost < NEAR_SAVE * rankSave && (wasteLives || wasteLost - keptLost >= rankSave);
    // (the owner: don't die -- a three is kept out only where a line that keeps it lives, or is lost no sooner than the best that wastes one)
    if (!keeps && !wasteLives && keptLost >= 0 && wasteLost <= keptLost) keeps = 1;
    if (!keeps && nearSave) saveOk = 1;
    // (THE SAVE ASKED: where the rule would let a three through, the best line that wastes one and the best that does not -- the hold
    // among them -- are each played to their end and the survival search asked of the boards they leave, the garbage on its way
    // landing as it would. A three whose board, with the best line on, outlasts the other's by nothing was not needed not to die: it
    // is wasted)
    if (!keeps && !saveOk && saveRoomMs() > SAVE_KEEP_MS + 2) {
      const Judge *bw = 0, *bk = 0;
      for (int i = 0; i < n; i++) {
        const Judge *J = order[i];
        if (wastesThree(J)) { if (!bw || J->o.lives > bw->o.lives || (J->o.lives == bw->o.lives && lostOf(J) > lostOf(bw))) bw = J; }
        else if (!bk || lostOf(J) > lostOf(bk)) bk = J;
      }
      if (bw && bk) {
        // (the side without a three: the survival search's own line from now when it wastes none -- searched already, on a worker -- else
        // the best line without one played to its end and searched on; the decision's time all the three's side's when it need not)
        // (the three's side first, with the time; then the side without, bounded below by what is known already -- the best line's own
        // loss, the survival line's when it wastes none: a three that does not beat that is not needed, and only
        // otherwise is the side without searched, in what time is left)
        int have = svLost >= 0 && svClean;
        double kLow = lostOf(bk); if (have && svLost > kLow) kLow = svLost;
        double give = saveRoomMs() - SAVE_KEEP_MS; if (give > SAVE_MS) give = SAVE_MS;
        double cw = contLostOf(bw, give), ck = -1;
        // (and the survival search's own loss on the three's side where its line wastes one: each side is bounded below by what the
        // decision's longer search already found for it, not only the one without)
        if (svLost >= 0 && !svClean && cw >= 0 && svLost > cw) cw = svLost;
        if (cw >= 0 && kLow >= cw) ck = kLow;
        else if (cw >= 0) {
          double give2 = saveRoomMs() - SAVE_KEEP_MS; if (give2 > SAVE_MS) give2 = SAVE_MS;
          double c2 = give2 >= 1 ? contLostOf(bk, give2) : -1;
          ck = c2 > kLow ? c2 : (c2 >= 0 ? kLow : -1);
        }
        saveAsked++;
        saveCw = cw; saveCk = ck;
        if (cw >= 0 && ck >= 0 && ck >= cw) { keeps = 1; saveNot++; }
        else if (cw >= 0 && ck >= 0) saveOk = 1;
      }
    }
    // (A SAVE THE CHECK COULD NOT ANSWER -- no time left to ask it, or no answer in the time it had: every line that keeps its threes is
    // lost within a break's time and the three lives or is lost later, so the three is the save -- death is never an option. Only a
    // check that answered takes a three out)
    if (!keeps && !saveOk && (wasteLives || wasteLost >= 0) && !(saveAsked && saveCw >= 0 && saveCk >= 0)) { saveOk = 1; saveBlind = 1; }
    // (only a three the save confirmed is played: any other line that wastes one goes, the hold always left -- the press guard refuses
    // what the order lets through, a walk spent for nothing)
    // (and never the line in progress begun on its three as the save: the input pressed of it is spent, and taken out now it is spent for
    // nothing)
    memset(twinWaste, 0, sizeof twinWaste); twinWasteC = twinWasteX = twinWasteN = 0;
    // (UNDER GARBAGE A BREAK IS NEVER A THREE FOR NOTHING where it is the only break and lost no sooner than the best line that keeps
    // its threes: no line lives and no line breaks without a three -- the three is on the way to the break, and taken out the board
    // is held, or its panels cleared for stop time, until it is lost)
    // (lost on the frame the engine has it, no walk charged: rank.c diesAt)
    int breakThrough = 0; double keptDies = -1;
    if (!saveOk && decF.under) {
      int lives = 0, clean = 0;
      for (int i = 0; i < n; i++) {
        if (order[i]->o.lives) lives = 1;
        if (wastesThree(order[i])) continue;
        if (!order[i]->hold && order[i]->apBroke > 0) clean = 1;
        if (diesAt(order[i]) > keptDies) keptDies = diesAt(order[i]);
      }
      breakThrough = !lives && !clean;
    }
    if (!saveOk) { int m = 0; for (int i = 0; i < n; i++) { if (wastesThree(order[i]) && order[i] != opCarried && !(order[i] == carriedJ && carrySave) && !(breakThrough && order[i]->apBroke > 0 && diesAt(order[i]) >= keptDies)) { dropAs(order[i]->k.play, DROP_WASTE); if (order[i]->k.twin == 1 && wasteWhy >= 1 && wasteWhy <= 4) { twinWaste[wasteWhy]++; if (wasteWhy == 2) { twinWasteC = order[i]->apCombo; twinWasteX = order[i]->k.x.combo; twinWasteN = order[i]->apChain; } } if (order[i] == carriedJ) { carryWaste[0] = wasteWhy; carryWaste[1] = order[i]->o.j.whole.chain; carryWaste[2] = aloneChain; carryWaste[3] = order[i]->o.j.threes; carryWaste[4] = order[i]->o.dead; carriedJ = strippedCarry; if (!carriedJ) carryNone = 20; } } else order[m++] = order[i]; } n = m; } }
  // THE REACH (the owner: can't move more than five, keep moves close by -- and no emergency lets one through): no line may walk the
  // cursor more than REACH_STEPS steps, rows and columns, from the cursor to its first swap or from one swap to the next
  // (THE LINE UP TO ITS FIRST FAR STEP: a line past the reach is offered as its swaps before the step that leaves it -- re-judged as a line
  // of its own, the cursor carried toward what the whole line was for within the reach -- and the rest let go; a line whose first swap is
  // past the reach has nothing to offer)
  { static Judge within[64]; int nw = 0, n0 = n;
    for (int i = 0; i < n0 && nw < 64 && !clockOut(); i++) { const Judge *J = order[i]; if (J->hold || !reachesFar(J)) continue;
      int p = reachPrefix(J); if (p < 1) continue;
      Cand c = J->k; c.nseq = p; c.settled = 0;
      if (judgeCand(R, &c, &within[nw]) && !within[nw].o.dead && !reachesFar(&within[nw])) { readyNextFor(&within[nw]); order[n++] = &within[nw]; nw++; reachCut--; }
    }
    if (nw) sortJudged(order, n); }
  // (THE WAY TO THE LINE THE REACH CUT: once the opener is over, under garbage with no break offered, the best line past the reach that
  // digs toward a break or lets a perch down is where the cursor is going: the way to the action (enRoute, its own checks: lost no sooner,
  // the reserve kept) walks it there in hops within the reach, unless a line in progress waits for its own next swap)
  if (openerOver && decF.under && !breakOffered && !(ccPre && cwaitPre)) for (int i = 0; i < n; i++) { const Judge *J = order[i];
    if (!J->hold && !J->o.dead && J->k.nseq > 0 && farForNothing(J) && digsForBreak(J)) { enR = CR(J->k.seq[0]); enC = CC(J->k.seq[0]); enOn = 1; break; } }
  // (NO STALLING UNDER GARBAGE -- the owner: efficiency is key, no wasted moves: under garbage, while the hold's own board stands a break's
  // time, a line that breaks none of it, does not live, does not dig toward a break (rank.c digsForBreak, a perch let down among them)
  // and is no flatten the window has room for (rank.c flattenFree) nor the finish's attack (rank.c finishFree) is taken out: the actions it
  // spends are the next break's, and the hold keeps them. Where the hold is lost within a break's time, a stall may be the life)
  { const Judge *H = 0; for (int i = 0; i < n && !H; i++) if (order[i]->hold) H = order[i];
    if (decF.under && H && !H->o.dead && (H->o.lives || diesAt(H) >= rankSave)) n = cutAlways(order, n, stallsUnder, &stallCut, 30); }
  { const Judge *H = 0; for (int i = 0; i < n && !H; i++) if (order[i]->hold) H = order[i];
    overHold = 0;
    if ((decF.under || garbageComing()) && !ruleNoEnemy && H && !H->o.dead && (H->o.lives || diesAt(H) >= rankSave)) {
      overHold = H; overMat = R->keepOn && R->keep.t[KEEP_MATERIAL].op; overFloor = R->keep.t[KEEP_MATERIAL];
      n = cutAlways(order, n, overspends, &overCut, 31);
    } }
  n = cutAlways(order, n, farForNothing, &reachCut, 28);
  // NO FLIP AND BACK ACROSS DECISIONS: a line that swaps straight back the two panels the last decision swapped is taken out, whatever
  // the board
  n = cutAlways(order, n, undoesLast, &undoCut, 29);
  // THE WINDOW BACK BEFORE THE TOP (no garbage: the board is lost to its own rise, and saved only by a clear the window has the actions
  // for): a line -- the hold too -- after which the window does not hold a break's walk (BREAK_WALK) again, with the frames to press it
  // (PRESS_FRAMES an action), before its board is lost, leaves a board that cannot save itself; where another line does, it is taken out.
  // The rise and the window both counted: the presses leaving the window by each frame (core/nodes.h allowLeftAt), the frame each line's
  // board is lost (diesAt). Endless on main: the deaths with 5-12 actions left; held whatever the rise, 21 of 28 (idea354)
  if (!garbageSeen && pressAllowance >= 0) {
    int n0w = n;
    int ok[MAXCANDS + 5 + NINTENT + NROUTE + NSTRIP], anyOk = 0;
    for (int i = 0; i < n; i++) {
      const Judge *J = order[i]; ok[i] = 1;
      if (J->o.lives || J->apBroke > 0) { anyOk = 1; continue; }
      double d = diesAt(J); if (d < 0 || d >= 1e299) { anyOk = 1; continue; }
      int walk = J->hold ? 0 : lineWalk(J), back = -1;
      // (the window is whole again once its length has passed -- every action in it gone -- so the frames asked end there: a board lost
      // far off asked to its frame was millions of steps, 5 s a decision and the board lost holding: endless on seed 86, 15754)
      int last = d < winLen ? (int)d : winLen;
      for (int t = 0; t <= last; t += 4) if (allowLeftAt(t, walk) >= BREAK_WALK) { back = t; break; }
      ok[i] = back >= 0 && back + BREAK_WALK * PRESS_FRAMES <= d;
      if (ok[i]) anyOk = 1;
    }
    if (anyOk) { int m = 0; for (int i = 0; i < n; i++) { if (!ok[i] && order[i] != opCarried) { if (order[i] == carriedJ) { carriedJ = 0; carryNone = 25; } } else order[m++] = order[i]; } n = m; windowCut = n0w - n; }
  }
  // NO 2x NOT TAKEN TO THREE (the owner: a 2x is taken to three, and one that cannot be is not made): a line whose chain ends at two
  // (rank.c shortChain) is taken out of the order -- unless every other line is lost within a break's time (rankSave) and a 2x lives,
  // or is lost later: only there is a 2x a save
  // (each such line, the best ranked first, offered beside it as a plain break where it can be: twoMadeThree)
  { static Judge remade[4]; int n0 = n;
    for (int i = 0, tries = 0; i < n0 && tries < 4 && n < MAXCANDS + 5 + NINTENT + NROUTE + NSTRIP && !clockOut(); i++)
      if (shortChain(order[i])) { if (twoMadeThree(R, order[i], &remade[tries])) { order[n++] = &remade[tries]; twoRemade++; } tries++; }
    if (twoRemade) sortJudged(order, n); }
  { int keeps = 0, twoLives = 0; double twoLost = -1, keptLost = -1;
    for (int i = 0; i < n; i++) {
      if (shortChain(order[i])) { if (order[i]->o.lives) twoLives = 1; else if (lostOf(order[i]) > twoLost) twoLost = lostOf(order[i]); }
      else if (spendsReserve(order[i])) continue;   // (a line that spends the window the next break is pressed from keeps nothing)
      else if (order[i]->o.lives) keeps = 1; else if (lostOf(order[i]) > keptLost) keptLost = lostOf(order[i]);
    }
    int why = keeps ? 1 : 0;
    // (the owner: don't die -- a 2x is kept out only where a line that makes none lives, or is lost no sooner than the best 2x)
    if (!keeps && !twoLives && keptLost >= 0 && twoLost <= keptLost) keeps = 1, why = 3;
    twoWhy = why; twoLostLog = twoLives ? 1e300 : twoLost; twoKeptLog = keptLost;
    // (not where the list asks no chain: a 2x taken to three is a bigger slab the mode does not ask)
    // (nor the line in progress begun on its 2x: the input pressed of it is spent, and taken out now it is spent for nothing)
    if (keeps && listChainCap() > 0) { int m = 0; for (int i = 0; i < n; i++) { if (shortChain(order[i]) && order[i] != opCarried && !(order[i] == carriedJ && carryTwo)) { dropAs(order[i]->k.play, DROP_TWO); twoDropped++; if (order[i] == carriedJ) { carriedJ = 0; carryNone = 24; } } else order[m++] = order[i]; } n = m; } }
  // NO CLEAR FOR BLOCKS THAT HAVE NOT LANDED (the owner: low, spend less and break): garbage queued behind the board's own motion and
  // none on the board (outcome.c holdQueueAt), below the material floor, nothing living -- a clear that breaks nothing (spends) is taken
  // out of the order where a line that leaves more of the panels is offered, unless its board lasts a break's time (rankSave) longer
  // than that line's once the blocks have landed, the drop it puts off taken out (outcome.c putOff). However near the kept line's loss,
  // so long as its board is still there a reaction after the blocks drop, when the first move can answer them: no line breaks a block
  // before it lands, and the break after it is made of the panels kept. The line in progress is held to it like any other
  if (n && !order[0]->o.lives && holdQueueAt() != NOT_ASKED) {
    const Judge *kept = 0;
    for (int i = 0; i < n; i++) { const Judge *J = order[i];
      if (J->spends || J->o.dead || J->o.matLeft < 0 || diesAt(J) < holdQueueAt() + rankReact) continue;
      if (!kept || J->o.matLeft > kept->o.matLeft || (J->o.matLeft == kept->o.matLeft && diesAt(J) > diesAt(kept))) kept = J; }
    if (kept) { int m = 0;
      for (int i = 0; i < n; i++) { const Judge *J = order[i];
        if (J->spends && J != opCarried && J->o.matLeft >= 0 && J->o.matLeft < kept->o.matLeft && diesAt(J) - diesAt(kept) < rankSave) { putOffCut++; if (J == carriedJ) { carriedJ = 0; carryNone = 27; } }
        else order[m++] = order[i]; }
      n = m; }
  }
  // (NO COMBO THE MODE DOES NOT ASK FOR, where a three does as well: the line ranked first making one is played with each of its swaps
  // left out in turn, and one that makes none, lives as long, breaks as much and makes as much of the list is the line -- a fourth panel
  // walked in by a swap the break did not need is a panel and a walk for nothing (the owner: no mode asks a combo of four))
  if (n && order[0] && !order[0]->hold && comboOutside(order[0])) dropCombo(R, order[0]);
  // (EVERY SWAP THE LINE NEEDS, NO OTHER -- the owner: everything is about efficiency: the line ranked first, each of its swaps left
  // out in turn; one it loses nothing without -- it lives as long, breaks as much, chains and combos as much, leaves its next break no
  // farther, and is ranked no lower -- is taken out and the line judged again: the walk to that swap and its press are inputs for
  // nothing. A swap and its swap back, a swap of two panels alike and a swap back of the last pair pressed are such swaps.)
  // (NO SWAP AMONG THE SLABS THAT BREAKS NOTHING -- the owner: it shouldn't go up there to make any swap that doesn't break; if it goes
  // there, it breaks: under garbage, a line that swaps among the garbage and breaks none of it is not played while any line that does
  // not, the hold among them, is not lost already)
  // (the one exception, the owner's -- a Shogun: the garbage under the swap about to convert -- matched and popping, not converted yet --
  // and the swap setting up
  // that drop to make something: a clear or a chain once it lands)
  #define AMID_BANNED(J) (amidGarbage(J) && !(popLeft(decQ.b) > 0 && ((J)->apChainAll >= 2 || (J)->apCombo >= 3)))
  if (decF.under && n > 1) {
    int other = 0; for (int i = 0; i < n && !other; i++) if (!order[i]->o.dead && !AMID_BANNED(order[i])) other = 1;
    if (other) { int m = 0; for (int i = 0; i < n; i++) { if (AMID_BANNED(order[i]) && order[i] != opCarried) { amidDropped++; if (!order[i]->o.dead) { double dl = order[i]->o.lives ? 99999 : lostAtOf(order[i]->o.lostAt, 0); if (dl > amidBest) amidBest = dl; } if (order[i] == carriedJ) { carriedJ = 0; carryNone = 26; } } else order[m++] = order[i]; } n = m; }
  }
  #undef AMID_BANNED
  for (int pass = 0; pass < 4 && n && order[0] && !order[0]->hold && order[0]->k.nseq >= 2 && !clockOut(); pass++) {
    static Cand w; static Judge JL; Judge *J = order[0]; int took = 0;
    for (int i = 0; i < J->k.nseq && !took && !clockOut(); i++) {
      w = J->k; w.nseq = 0; w.xNats = 0;
      for (int q = 0; q < J->k.nseq; q++) if (q != i) w.seq[w.nseq++] = J->k.seq[q];
      if (!judgeCand(R, &w, &JL) || JL.o.dead) continue;
      // (a swap whose life bought is less than the time its own walk takes, and less than a break's time, is a swap for nothing --
      // pointless moves, the far ones above all, waste the window; a swap that buys a break's time is never one)
      double walkSaved = (double)WALK_FRAMES * imax(0, lineWalk(J) - lineWalk(&JL)), bought = diesAt(J) - diesAt(&JL);
      int forNothing = !J->o.lives && !JL.o.lives && bought <= walkSaved && bought < rankSave && walkSaved > 0 && lostAlike(J, &JL);
      if (!JL.o.lives && (J->o.lives || (diesAt(&JL) < diesAt(J) && !forNothing))) continue;
      if (imax(0, JL.apBroke) < imax(0, J->apBroke) || JL.apChain < J->apChain || JL.apCombo < J->apCombo || JL.apChainAll < J->apChainAll) continue;
      if (J->o.nearAfter >= 0 && JL.o.nearAfter > J->o.nearAfter) continue;
      // (nor a swap of a line that lets the garbage down, unless the line lets it down as far without it: rank.c letsDown)
      if (letsDown(J) && !(restOn(&JL) >= 0 && restOn(&JL) <= restOn(J))) continue;
      // (nor one that, a swap less, clears panels below the floor and breaks nothing where the line clears none: the panels are what it loses)
      if (JL.spends && !J->spends) continue;
      if (!forNothing && compareJudged(&JL, J) > 0) continue;
      JL.carried = J->carried; *J = JL; took = 1; needlessTrimmed++;
    }
    if (!took) break;
  }
  // (and a line of one swap that buys less than its own walk takes, making, breaking and bringing nothing nearer, is the hold -- a far
  // swap for nothing is the waste the owner sees most; a plain three is no chain, and a break brought nearer that keeps the board no
  // longer is a walk for nothing -- only a board left ready where the hold leaves none is kept)
  // (nor the swap that lets the garbage down onto more of the stack where no break is offered: rank.c letsDown)
  // (but never a flatten the window has room for: rank.c flattenFree -- the board it leaves is the one the next break is walked on)
  // (run 184 turned this off above six colours under garbage: 4/8 -- the hold still first on 44 of 79 true inversions, from the sort)
  // (run 189 had this off above six colours with garbage on the board, resting or not; the owner moved on to the next mode with run 180's bot)
  if (n && order[0] && !order[0]->hold && order[0]->k.nseq == 1 && !order[0]->o.lives && !letsDown(order[0]) && !flattenFree(order[0])) {
    Judge *J = order[0]; const Judge *h = 0; int hi = -1;
    for (int i = 1; i < n; i++) if (order[i]->hold) { h = order[i]; hi = i; break; }
    if (h && !h->o.dead && !(J->apBroke > 0) && (J->apChainAll <= h->apChainAll || J->apChainAll < 2) && J->apCombo < 3 && !(J->o.j.ready == 1 && h->o.j.ready != 1) &&
        !(J->o.nearAfter >= 0 && h->o.nearAfter >= 0 && J->o.nearAfter < h->o.nearAfter && diesAt(J) >= diesAt(h)) &&
        diesAt(J) - diesAt(h) <= (double)WALK_FRAMES * lineWalk(J) && diesAt(J) - diesAt(h) < rankSave && lostAlike(J, h) && lineWalk(J) > 0) {
      Judge *hh = order[hi]; for (int k = hi; k > 0; k--) order[k] = order[k - 1]; order[0] = hh; needlessTrimmed++; outlivingFirst(order, n); if (!rankMoved) rankMoved = __LINE__; }
  }
  // (and a line of nothing but swaps of two panels alike is the hold: the board it leaves is the board as it is)
  if (n && order[0] && !order[0]->hold && order[0]->o.j.sames && order[0]->k.nseq >= 1) {
    Judge *J = order[0]; int all = 1;
    for (int i = 0; i < J->k.nseq && all; i++) if (!(i < 64 && (J->o.j.sames >> i & 1))) all = 0;
    if (all) for (int i = 1; i < n; i++) if (order[i]->hold) { Judge *h = order[i]; for (int k = i; k > 0; k--) order[k] = order[k - 1]; order[0] = h; samesTrimmed = 2; outlivingFirst(order, n); if (!rankMoved) rankMoved = __LINE__; break; }
  }
  // (run 186, THE TOP PAIR AGREES, ON THE ORDER AS IT IS LEFT -- the owner: the order and the line played must not disagree. The keys are
  // not transitive, and the cuts above drop lines after the last sort: the two left on top may never have been compared. Where the
  // second beats the top compared alone, the two change places, once, after every cut; a line put on top on purpose above (the hold for a
  // needless swap, rankMoved) stays)
  // (run 186 did this: 0 inversions over 6985 decisions, survived 5/8 against run 180's 7/8 -- off by the rule kept; the owner may keep it)
  if (0 && n > 1 && !rankMoved) { int32_t keep = cmpKey; if (compareJudged(order[1], order[0]) < 0) { Judge *e = order[0]; order[0] = order[1]; order[1] = e; } cmpKey = keep; }
  phaseMs[0] = (int32_t)(t1 - t0); phaseMs[1] = (int32_t)(t2 - t1); phaseMs[2] = (int32_t)(nowMs() - t2);
  return n;
}

// 5. PLAY: the raise when the opening calls for it, a hold while the raise waits for a busy board, else the first candidate in the one
// order -- a line's first swap, or the hold
typedef struct { const Judge *top, *line; int32_t name, nlive, ncands, urgent, wait, deferred; } Played;
// (the hold put in a line's place only where the board it leaves is lost no sooner, as the engine has it: the owner -- you can't choose to
// die)
#define TA_WALL 7200          // a Challenge stage's wall: two minutes of the stopwatch
#define TA_WALL_FRAMES 150    // the frames before it from which a falling chain is let end: a link or two, and the rows' way across --
                              // a chain's slab leaves the telegraph once finalized and 91 frames past its first link, and lands 60 later
                              // (GarbageQueue.lua STAGING_DURATION, GARBAGE_DELAY_LAND_TIME; run 271: 150, was 120)
char *getenv(const char *);
static int taWallNear(const Board *b) {
  static int stage = -1;
  if (stage < 0) { const char *e = getenv("CHAOSBOT_CHALLENGE"); stage = e && *e ? 1 : 0; }
  return stage && b->stopWatch >= TA_WALL - TA_WALL_FRAMES;
}
static int taHoldNoSooner(const Judge *line, int n) {
  if (!line) return 1;
  for (int i = 0; i < n; i++) if (order[i]->k.play == PLAY_HOLD) return diesAt(order[i]) >= diesAt(line);
  return 0;
}
// THE BOARD THE OPENER BUILDS ON (opTarget): the question's board flattened -- search/level.c's swap, played and settled, again and again
// while one is found, OP_FLAT at most, into opFlat -- then raised `rows` rows on the engine, the raise key held as the game would take
// it. 0 where the board is lost on the way.
#define OP_FLAT 8
static int32_t opFlat[OP_FLAT], opFlatN, opFlatPlayed;
static Ctx *opTCtx;
static int opTarget(const Question *q, int32_t rows, Question *out) {
  static Board *cur, *tgt; if (!cur) { cur = nb_new(); tgt = nb_new(); } if (!cur || !tgt) return 0;
  cloneBoard(cur, q->b); opFlatN = 0;
  for (int k = 0; k < OP_FLAT && !clockOut(); k++) {
    Question t = *q; t.b = cur; t.narr = 0;
    int32_t sw = level(&t, NOT_ASKED);
    if (!sw) break;
    Ctx *x = opTCtx = ctxOf(opTCtx);
    int root = rootOf(x, &t); if (root < 0) break;
    int nd = step(x, root, MK_SETTLE, CR(sw), CC(sw), 0);
    if (!liveNode(x, nd)) break;
    const Board *b = ensureBoard(x, nd); if (!b) break;
    cloneBoard(cur, b); opFlat[opFlatN++] = sw;
  }
  cloneBoard(tgt, cur);
  int32_t top0 = fullTop(tgt);
  for (int32_t f = 0; fullTop(tgt) < top0 + rows && tgt->gameOverClock <= 0 && f < 60 * rows; f++) { tgt->input = RAISE_IN; run(tgt); }
  if (tgt->gameOverClock > 0) return 0;
  tgt->input = 0;
  *out = *q; out->b = tgt; out->narr = 0;
  return 1;
}
// (an opening plan the decision may press: set-ups to press, a chain longer than the board's own trigger's and one the mode asks for,
// its set-ups pressed before the next block lands)
// (and, no garbage shown yet, its trigger pressed by OPEN_FIRE_BY: the opener's chain goes before anything can land on it)
static int opBefore(void) { return decF.next == NOT_ASKED && decQ.b->clock < OPEN_FIRE_BY; }
// (pass 0: a chain the mode asks for, fired by OPEN_FIRE_BY; 1: a chain of OP_FAST_CH or more fired by then -- a chain going is a board
// that cannot top out, and the extension grows it while it falls; 2 -- the owner: start with a 2 and extend: a chain of two fired by then,
// its fall extended to the eight -- before a longer plan fired late, whose many swaps are as many chances to come apart; 3: a chain of
// OP_FAST_CH or more fired within OP_LATE of it; 4: a chain the mode asks for, fired when it can)
#define OP_FAST_CH 3
#define OP_LATE 60   // (the frames past OPEN_FIRE_BY pass 3 takes a chain fired in: about four set-ups' worth)
#define OP_PASSES 5
#define OP_START_CH 2
static int32_t opFireBy(int pass) { return OPEN_FIRE_BY + (pass == 3 ? OP_LATE : 0); }
static int32_t opPassLeast(int pass) { return pass == 1 || pass == 3 ? OP_FAST_CH : pass == 2 ? OP_START_CH : 0; }
static int opFits(const OpPath *p, int32_t trigCh, int pass) {
  int32_t frames = (p->len + 1) * OPEN_SWAP_FRAMES; int by = pass < 4;
  return p->len > 0 && p->ch > trigCh && (opPassLeast(pass) ? p->ch >= opPassLeast(pass) : opAsked(p->ch)) && !(decF.next != NOT_ASKED && decF.next <= frames) &&
         !(by && opBefore() && decQ.b->clock + frames > opFireBy(pass) + OPEN_SWAP_FRAMES);
}
// THE SECOND CHAIN BUILT UNDER THE FIRST (the owner: two 4-chains): the board the falling chain leaves once it has landed, the opening's
// plan grown there in a share of the decision's time; the plan's next set-up pressed now where it would be pressed then -- its two panels,
// and every panel under them in their columns, where they will be once the chain lands and none of them moving -- and only where the
// chain falls on as long as it does left alone. 0 where there is none.
#define OP_SECOND_DESIGN 0.6   // (the designer's part of it)
#define OP_SECOND_SHARE 0.9   // (the share of what the decision has left that the second chain's plan takes: the extension has had its share)
#define OP_CB_COST 30
#define OP_CB_MAXSW 14
#define OP_NEXT_MAXSW 10   // (and the next chain's: its swaps pressed while garbage lands and the game's clock runs -- set 86 large_garbage 7, a 4 of 14 swaps half pressed and never fired)
static int opDesign(const Board *b, double ms, OpPath *out, int maxSw);
static int32_t opDesignCost = OP_CB_COST;   // (a swap's worth in a design's score: the opening's race, or the next chain's OP_NEXT_COST)   // (the last design asked: 1 no full row, 2 no time, 3 no chain of OP_TWO_FROM (its links), 4 no order, 5 made)
static int32_t opDesignLeast = OP_TWO_FROM;   // (the chain a design must make: the opening's OP_TWO_FROM, the next chain's what is still needed)
static int opDesignAsIs;   // (a design on a board that is not the board as it stands -- the landed board: the row under it left out)
static char opLandedRows[160], opCdRows[160];   // (the log's landed= and, at the countdown's decision, cdboard=)
// (a board as rows bottom up, a digit a panel's colour, g garbage, . empty)
static void boardRows(const Board *b, char *out, int cap) {
  int k = 0;
  for (int r = 1; r < b->nrows && k < cap - 9; r++) { if (r > 1) out[k++] = '/';
    for (int c = 1; c <= W; c++) { const int32_t *f = b->p[r][c].f; out[k++] = f[ISGARBAGE] ? 'g' : f[ID] > 0 && f[COLOR] > 0 ? (char)('0' + f[COLOR] % 10) : '.'; } }
  out[k] = 0;
}   // (the log's landed=)
static int32_t opSecondCh, opSecondWhy, opSecondMs, opSecondN;   // (and the time it had, the boards its beam grew: the log's)   // (the second chain's plan, its chain; how far the try went -- 1 begun, 2 no landed board, 8 its chain still counting, 3 time, 4 a plan, 5 a swap on the board, 6 still panels, 7 pressed:
                                            // the log's)
// TALL GARBAGE: a slab OP_TALL rows or more on the board or on its way -- one broken gives back one row, a pop at a time, so the next
// chain's panels come slowly (the large slabs; a factory's are two rows)
#define OP_TALL 6
static int garbageRows(const Question *q, int rows) {
  for (int i = 0; i < q->narr; i++) if (q->arr[i].height >= rows) return 1;
  for (int i = 0; i < q->b->ninc; i++) if (q->b->inc[i].height >= rows) return 1;
  for (int r = 1; r < q->b->nrows; r++) for (int c = 1; c <= W; c++) { const int32_t *f = q->b->p[r][c].f; if (f[ISGARBAGE] && f[ISGARBAGE] != NUL && f[GHEIGHT] >= rows) return 1; }
  return 0;
}
static int tallGarbage(const Question *q) { return garbageRows(q, OP_TALL); }
static int32_t opSecondFall;   // (the chain falling as the fall rule reads it -- its hold's -- with the need left: what a second chain must make is the rest)
// (the chain a second chain must make: with the first thrown, any of OPENER_LEAST or more; with one falling, the rest of the eight
// after it, OPENER_LEAST or more)
static int32_t opSecondLeast(void) { return openerSum > 0 ? OPENER_LEAST : imax(OPENER_LEAST, imax(OPENER_LEAST, opNeed) - opSecondFall); }
// (a swap's panels, and every panel under them, where the landed board has them and at rest: a swap there can be pressed now)
static int opAtRest(const Board *landed, int32_t sw) {
  const Board *b = decQ.b; int r = CR(sw), c = CC(sw);
  if (r < 1 || r >= b->nrows || c < 1 || c >= W) return 0;
  for (int cc = c; cc <= c + 1; cc++) for (int rr = 1; rr <= r; rr++) {
    const int32_t *now = b->p[rr][cc].f, *then = landed->p[rr][cc].f;
    if (now[ID] != then[ID] || (now[ID] > 0 && now[STATE] != NORMAL)) return 0;
  }
  return 1;
}
// (the frames until the chain falling has landed and the board is still: the root run on to its settle -- 0 when it is still already)
static int32_t opLandIn(void) {
  static Ctx *lx; lx = ctxOf(lx);
  int root = rootOf(lx, &decQ), calm = root >= 0 ? settleOf(lx, root) : -1;
  return root >= 0 && liveNode(lx, calm) ? imax(0, NODE(lx, calm)->t - NODE(lx, root)->t) : 0;
}
// (and the panels the board keeps once it has landed, left alone: the hold's, where the order no longer holds the hold)
static int32_t opRootMat(void) {
  static Ctx *mx; mx = ctxOf(mx);
  int root = rootOf(mx, &decQ), calm = root >= 0 ? settleOf(mx, root) : -1;
  const Board *b = liveNode(mx, calm) ? ensureBoard(mx, calm) : 0;
  return b ? materialOn(b) : -1;
}
static const Judge *opSecondSwap(const Read *R, int n) {
  static Board *landed; static Ctx *sx;
  if (!landed) landed = nb_new();
  opSecondWhy = 1;
  if (!landed || clockOut()) return 0;
  sx = ctxOf(sx);
  int root = rootOf(sx, &decQ), calm = root >= 0 ? settleOf(sx, root) : -1;
  const Board *lb = liveNode(sx, calm) ? ensureBoard(sx, calm) : 0;
  // (garbage landing on top while the chain falls adds rows above ours: the swap's panels are checked one by one below, panel for panel)
  opSecondWhy = 2;
  if (!lb) return 0;
  opSecondWhy = 8;
  if (lb->chainCounter != 0) return 0;
  cloneBoard(landed, lb);
  Question lq = decQ; lq.b = landed;
  // (the landed board, once a fall, for the log: each row bottom up, a digit a panel's colour, g garbage, . empty)
  { static int32_t loggedFor = -1;
    if (loggedFor != opFallAt) { loggedFor = opFallAt; int k = 0;
      for (int r = 1; r < landed->nrows && k < (int)sizeof opLandedRows - 9; r++) { if (r > 1) opLandedRows[k++] = '/';
        for (int c = 1; c <= W; c++) { const int32_t *f = landed->p[r][c].f; opLandedRows[k++] = f[ISGARBAGE] ? 'g' : f[ID] > 0 ? (char)('0' + f[COLOR] % 10) : '.'; } }
      opLandedRows[k] = 0; } else opLandedRows[0] = 0; }
  double left = C2.due ? C2.due - C2.margin - nowMs() : 50, ms = left * OP_SECOND_SHARE;
  opSecondWhy = 3;
  if (ms < 2) return 0;
  // (the designer's chain first, in OP_SECOND_DESIGN of the time: its whole plan at once; the beam in the rest, grown on decision after
  // decision -- the landed board is the same board every decision of the fall -- where the designer finds none)
  static OpPath dp; const OpPath *pl = 0; double t0 = nowMs();
  opDesignAsIs = 1; opDesignCost = OP_NEXT_COST; opDesignLeast = opSecondLeast();
  // (THE NEXT CHAIN KEPT: the design pressed a swap at a time is the one carried on -- on each landed board the fewest of its swaps still
  // to press that make a chain of opDesignLeast or more; a new design only where none does: one swap from each of a new design every
  // decision is a chain never built, set 86 factory 3)
  if (opKeepOn) {
    static CbGrid KG, KT; cbPartial = 1; cbOfBoard(landed, &KG);
    // (its first swap pressed already where the landed board shows it so -- its two cells swapped since the last decision: never pressed
    // again, which is a swap and its swap back)
    int minK = 0;
    if (opKeepSeq.n > 0) { int r = opKeepSeq.r[0], c = opKeepSeq.c[0]; cb8 a = opKeepPrev.g[r][c], b = opKeepPrev.g[r][c + 1];
      if (a != b && KG.g[r][c] == b && KG.g[r][c + 1] == a) minK = 1; }
    for (int k = opKeepSeq.n; k >= minK && !pl; k--) {
      CbSeq s; s.n = opKeepSeq.n - k; for (int i = 0; i < s.n; i++) { s.r[i] = opKeepSeq.r[k + i]; s.c[i] = opKeepSeq.c[k + i]; }
      int32_t tk = 0; int lk = 0;
      if (cbSeqPlay(&KG, &s, &KT) && cbBest(&KT, &tk, &lk) > 0 && tk && lk >= opDesignLeast) {
        memset(&dp, 0, sizeof dp); dp.len = s.n; for (int i = 0; i < s.n; i++) dp.path[i] = s.r[i] * 8 + s.c[i]; dp.trig = tk; dp.ch = lk; dp.design = 1;
        opKeepSeq = s; pl = &dp; opKeepHeld++; opKeepAt = decQ.b->clock; }
    }
    cbPartial = 0;
    if (!pl) opKeepOn = 0;
    else opKeepPrev = KG;
  }
  // (the next chain that reaches what is still needed looked for first, in half the time, a shorter one only where none does -- a 3 and a
  // 4 is a 7: set 86 large_garbage 6, 3s and 4s designed after the 3 with 5 still needed)
  int32_t want = openerSum > 0 ? imax(opDesignLeast, opNeed) : opDesignLeast; int fresh = 0;
  // (in the swaps that can be pressed before the board is lost, the slab's pop still to come counted: a design that fires after it is put
  // down for the dig -- set 86 large_garbage 6, the 5 the eight needed designed in 11 swaps with the board lost in 119 frames)
  int maxSw = OP_NEXT_MAXSW;
  if (R->F.known[FACT_US_DIES] && R->F.v[FACT_US_DIES] > 0) maxSw = imax(1, imin(maxSw, (int)((R->F.v[FACT_US_DIES] - popLeft(decQ.b)) / OPEN_SWAP_FRAMES) - 1));
  if ((!pl || pl->ch < want) && want > opDesignLeast) {
    static OpPath dw; int32_t lo = opDesignLeast; opDesignLeast = want;
    if (opDesign(landed, ms * OP_SECOND_DESIGN * 0.5, &dw, maxSw)) { dp = dw; pl = &dp; fresh = 1; }
    opDesignLeast = lo;
  }
  if (!pl && opDesign(landed, ms * OP_SECOND_DESIGN * (want > opDesignLeast ? 0.5 : 1), &dp, maxSw)) { pl = &dp; fresh = 1; }
  if (fresh) {
    opKeepOn = dp.len <= CB_SEQ_MAX; opKeepSeq.n = imin(dp.len, CB_SEQ_MAX); opKeepAt = decQ.b->clock; cbOfBoard(landed, &opKeepPrev);
    for (int i = 0; i < opKeepSeq.n; i++) { opKeepSeq.r[i] = (cb8)CR(dp.path[i]); opKeepSeq.c[i] = (cb8)CC(dp.path[i]); } }
  opDesignAsIs = 0; opDesignLeast = OP_TWO_FROM; opDesignCost = OP_CB_COST;
  double rest = ms - (nowMs() - t0);
  static int32_t grownFor = -1;
  if (grownFor != opFallAt) { openingReset(); grownFor = opFallAt; }
  if (!pl && rest > 1) {
    double keepDue = clockDue, keepShare = clockShare; clockDue = 0; clockShare = 0;
    { double sh = clockShareBegin(nowMs() + rest); openingGrow(&lq, decQ.b); clockShareEnd(sh); }
    clockDue = keepDue; clockShare = keepShare;
  }
  opSecondWhy = 4; opSecondCh = opHave ? opBest.ch : -1; opSecondMs = (int32_t)ms; opSecondN = opGrewN;
  if (!pl && opHave && opBest.ch >= (opSecondLeast())) pl = &opBest;
  if (!pl) return 0;
  opSecondCh = pl->ch;
  // (a plan of its trigger alone -- the landed board's own chain one swap away -- is that swap)
  // (a design's swap whose panels are not yet at rest gives way to another of its swaps that is, where the design pressed in that order
  // still makes its chain: a chain falling through one column holds back a swap in it, not the whole design -- set 86 combo_storm 2, a
  // 3 kept 200 frames under a 6, its first swap in the 6's column)
  if (pl == &dp && dp.len >= 2 && !opAtRest(landed, dp.path[0])) {
    static CbGrid RG, RT; cbPartial = 1; cbOfBoard(landed, &RG);
    for (int i = 1; i < dp.len && i < CB_SEQ_MAX; i++) {
      if (!opAtRest(landed, dp.path[i])) continue;
      CbSeq s; s.n = imin(dp.len, CB_SEQ_MAX); s.r[0] = (cb8)CR(dp.path[i]); s.c[0] = (cb8)CC(dp.path[i]);
      for (int j = 0, k = 1; j < s.n; j++) if (j != i) { s.r[k] = (cb8)CR(dp.path[j]); s.c[k] = (cb8)CC(dp.path[j]); k++; }
      int32_t tk = 0; int lk = 0;
      if (cbSeqPlay(&RG, &s, &RT) && cbBest(&RT, &tk, &lk) > 0 && tk && lk >= dp.ch) {
        for (int j = 0; j < s.n; j++) dp.path[j] = s.r[j] * 8 + s.c[j]; dp.trig = tk;
        if (opKeepOn) opKeepSeq = s;
        break;
      }
    }
    cbPartial = 0;
  }
  int32_t sw = pl->len >= 1 ? pl->path[0] : pl->trig;
  opSecondWhy = 5;
  if (!opAtRest(landed, sw)) return 0;
  opSecondWhy = 6;
  // (and the chain no shorter for it: the hold's chain, all of it, is the bar)
  int32_t bar = 0; for (int i = 0; i < n; i++) if (order[i]->hold) bar = order[i]->apChainAll;
  static Judge J; Cand k; int32_t one[1] = { sw };
  if (!candOf(&k, PLAY_SETUP, one, 1, -1, 0)) return 0;
  k.settled = 0; lastDrop = -1;
  if (!judgeCand(R, &k, &J) || J.o.dead || J.apChainAll < bar) return 0;
  // (nor a set-up that makes a link: a link short of what is needed spends the next chain's panels on a chain that does not count, or on
  // the falling chain short of the eight -- set 86 large_garbage 3, the 3's set-ups linked into the 5 as it fell, a 7 and no 3)
  opSecondWhy = 9;
  if (pl->len >= 1 && J.apChainAll > bar && J.apChainAll < imax(OPENER_LEAST, opNeed)) return 0;
  opSecondWhy = 7; opPressed = sw;
  return &J;
}
// THE OPENER'S CHAIN DESIGNED (search/chainbuild.c, time attack's designer): the board's full rows ordered, a swap at a time, into the
// best chain OP_CB_MAXSW swaps or fewer make, a swap worth OP_CB_COST of a chain's score -- the opener's chains are a few swaps, never time
// attack's long builds -- and its swaps put in an order that sets nothing off, the trigger last: a plan, into *out, where its chain is
// OP_TWO_FROM or more
#define OP_CB_FEWEST 3
#define OP_PROVE_MAX 4   // (the designs judged at most: the plans' falls extended need the countdown's time after them)
static int32_t opDesignWhy, opDesignLinks, opSeqLinks;   // (and the swaps' design's links, -1 none)
static int32_t opProveTried, opProved, opProvedBest;   // (the countdown's designs judged, those that chain as judged, the longest: the log's opgrew /p)
static int32_t opDesigned, opDesignedQuick;   // (the chain of the design offered this decision, 0 none: the log's)
static int opDesignIn(const Board *b, double ms, OpPath *out, int maxSw) {
  static CbGrid G, D; static int32_t seq[CB_MAXSWAPS + 1], sseq[CB_SEQ_MAX + 1];
  cbOfBoard(b, &G); if (!opDesignAsIs) cbPreview(b, &G);
  int full = 0; for (int r = 1; r <= G.rows; r++) full += cbRowOk(&G, r);
  opDesignWhy = 2;
  if (ms < 1) return 0;
  // (the rows ordered, in half the time)
  int n = 0, links = 0;
  if (full) {
    int keepSw = cbJMaxSw; int32_t keepCost = cbJSwapCost; cbJMaxSw = maxSw; cbJSwapCost = opDesignCost; cbJPartial = 1;
    int32_t tr = 0; int sw = 0;
    int32_t v = cbDesignAll(&G, 0, ms * 0.5, &D, &tr, &links, &sw);
    cbJMaxSw = keepSw; cbJSwapCost = keepCost; cbJPartial = 0;
    opDesignWhy = 3; opDesignLinks = links;
    if (v > 0 && tr && links >= opDesignLeast) {
      cbCurR = b->curRow; cbCurC = b->curCol;
      n = cbOrder(&G, &D, tr, seq, OP_DEPTH + 1);
      cbCurR = 0;
      opDesignWhy = 4;
      if (n < 1) n = 0;
    } else links = 0;
  }
  // (and the swaps themselves, panels moved into gaps and between rows, in the other half: kept only where its chain is longer -- the
  // rows' order is the one walked shortest)
  { int32_t keepCost = cbSwapCost; cbSwapCost = opDesignCost;
    int32_t str = 0; int sl = 0, sn = cbSeqDesign(&G, ms * 0.5, imin(maxSw, OP_DEPTH), sseq, &str, &sl);
    cbSwapCost = keepCost; opSeqLinks = sn >= 0 ? sl : -1;
    if (sn >= 0 && sl >= opDesignLeast && (!n || sl > links)) { for (int i = 0; i < sn; i++) seq[i] = sseq[i]; seq[sn] = str; n = sn + 1; links = sl; opDesignLinks = sl; } }
  if (n < 1) return 0;
  opDesignWhy = 5;
  memset(out, 0, sizeof *out);
  out->len = n - 1; for (int i = 0; i < n - 1; i++) out->path[i] = seq[i]; out->trig = seq[n - 1]; out->ch = links; out->design = 1;
  if (maxSw == OP_CB_MAXSW) opDesigned = links;
  return 1;
}
// (the opener's designs order rows with gaps too: search/chainbuild.c cbPartial)
static int opDesign(const Board *b, double ms, OpPath *out, int maxSw) { cbPartial = 1; cbSeqSlot = opDesignAsIs ? 1 : 0; int ok = opDesignIn(b, ms, out, maxSw); cbPartial = 0; cbSeqSlot = 0; return ok; }
// THE PLANS' FALLS EXTENDED (the countdown's: the owner's three seconds): each plan kept, its chain OP_FAST_CH or more, played to its trigger
// on the engine and its fall searched for the longest extension in an equal share of `ms` -- the chain it reaches into chx; the best
// ranked again
#define OP_EXT_PLANS 6
static int32_t opExtBest, opExtMs, opExtN, opExtCh[OP_EXT_PLANS][3];   // (and its time, and each plan ranked: swaps, chain, chain its fall reached extended -- the log's opExt=)   // (the longest chain a plan's fall reached extended: the log's opgrew /x)
static void opExtendAll(const Question *q, double ms) {
  const OpPath *pl[OP_EXT_PLANS]; OpPath *mut[OP_EXT_PLANS]; int np = 0; opExtBest = 0; opExtMs = (int32_t)ms; opExtN = 0;
  for (int ln = 1; ln <= OP_DEPTH && np < OP_EXT_PLANS; ln++) if (opByLenHave[ln] && opByLen[ln].ch >= OP_FAST_CH) { pl[np] = &opByLen[ln]; mut[np++] = &opByLen[ln]; }
  if (!np) return;
  static Ctx *ex; Ctx *x = ex = ctxOf(ex);
  for (int i = 0; i < np && !clockOut(); i++) {
    int root = rootOf(x, q); if (root < 0) return;
    int at = opReplay(x, root, pl[i]); if (at < 0) continue;
    int out = step(x, at, MK_SWAP, CR(pl[i]->trig), CC(pl[i]->trig), 0);
    for (int k = 0; k < 6 && liveNode(x, out); k++) { const Board *bb = ensureBoard(x, out); if (bb && cascadeLive(bb)) break; out = step(x, out, MK_LONG, 0, 0, 2); }
    const Board *fb = liveNode(x, out) ? ensureBoard(x, out) : 0;
    if (!fb || !cascadeLive(fb)) continue;
    static Board *fall; if (!fall) fall = nb_new(); if (!fall) return;
    cloneBoard(fall, fb);
    Question fq = *q; fq.b = fall;
    List L; memset(&L, 0, sizeof L); L.n = 1; L.aim[0].chain.op = OP_GE; L.aim[0].chain.n = 2; L.aim[0].brk = -1;
    ExtOpts eo = { 40, 6, &L, NOT_ASKED, 0, ms / np, 2 };   // (longest, unjudged -- the fall is a board played forward: the chain it reaches extended; without it chx is the chain left alone)
    static Ext E; extend(&fq, &eo, &E);
    int32_t c = E.longest.set ? E.longest.chain : E.baseChain;
    mut[i]->chx = c; if (c > opExtBest) opExtBest = c;
    if (opExtN < OP_EXT_PLANS) { opExtCh[opExtN][0] = pl[i]->len + 1; opExtCh[opExtN][1] = pl[i]->ch; opExtCh[opExtN][2] = c; opExtN++; }
    x = ex = ctxOf(ex);
  }
  for (int ln = 1; ln <= OP_DEPTH; ln++) if (opByLenHave[ln] && (!opHave || opPacier(&opByLen[ln], &opBest))) { opBest = opByLen[ln]; opHave = 1; }
}
// THE SECOND CHAIN EACH PLAN LEAVES, the countdown's (the owner: chains of three or more adding up to eight -- a 5 and a 3 alike): each
// plan kept whose chain is short of OPENER_SUM played out by the judge as the game will play it -- rooted, the stack rising under its
// swaps, its chain landed and the garbage on its way with it (outcome.c lineEnd) -- and the next chain designed on the board it leaves, as the next chain is after it (opDesign as it stands, OP_NEXT_COST a swap) -- its chain into
// ch2; the best ranked again (search/opening.c opMakesEight)
static int32_t opPairBest, opPairN;   // (the longest second chain designed, and the plans asked: the log's opgrew /r)
static void opPairAll(const Question *q, double ms) {
  int np = 0; opPairBest = 0; opPairN = 0;
  for (int ln = 1; ln <= OP_DEPTH; ln++) if (opByLenHave[ln] && opByLen[ln].ch >= OPENER_LEAST && imax(opByLen[ln].ch, opByLen[ln].chx) < OPENER_SUM) np++;
  if (!np) return;
  int32_t kLeast = opDesignLeast, kCost = opDesignCost, kDesigned = opDesigned, kWhy = opDesignWhy, kLinks = opDesignLinks, kSeq = opSeqLinks; int kAsIs = opDesignAsIs;
  for (int ln = 1; ln <= OP_DEPTH && !clockOut(); ln++) {
    OpPath *p = &opByLen[ln];
    if (!opByLenHave[ln] || p->ch < OPENER_LEAST || imax(p->ch, p->chx) >= OPENER_SUM) continue;
    int32_t seq[OP_DEPTH + 1]; int ns = 0; for (int k = 0; k < p->len; k++) seq[ns++] = p->path[k]; seq[ns++] = p->trig;
    // (judged with no garbage on its way: the next chain fires as this one lands, and a chain falling is a board the garbage cannot top
    // out -- the slab lands on top of it; that judging is never kept, the game's own is)
    int rd = readyDefer, kn = decQ.narr, kk = endNoKeep; int32_t kl = decF.land; readyDefer = 1; endWanted = 1; outRooted = p->design;
    static Board *quiet; if (!quiet) quiet = nb_new();
    Board *kb = decQ.b; if (quiet) { cloneBoard(quiet, kb); quiet->ninc = 0; decQ.b = quiet; }
    decQ.narr = 0; decF.land = NOT_ASKED; endNoKeep = 1;
    Outcome oo = outcome(seq, ns, 1);
    decQ.b = kb; decQ.narr = kn; decF.land = kl; endNoKeep = kk;
    outRooted = 0; int got = endWanted == 2; endWanted = 0; readyDefer = rd;
    p->ch2 = 0; opPairN++;
    const Board *lb = got ? endBoard : 0;
    if (!lb || oo.dead || imax(chainOf(oo.j.made), oo.j.chainAll) < p->ch || lb->chainCounter != 0 || cascadeLive((Board *)lb)) continue;
    OpPath dp; opDesignAsIs = 1; opDesignCost = OP_NEXT_COST; opDesignLeast = OPENER_LEAST;
    p->ch2 = opDesign(lb, ms / np, &dp, OP_NEXT_MAXSW) ? dp.ch : 0;
    if (p->ch2 > opPairBest) opPairBest = p->ch2;
  }
  opDesignLeast = kLeast; opDesignCost = kCost; opDesigned = kDesigned; opDesignWhy = kWhy; opDesignLinks = kLinks; opSeqLinks = kSeq; opDesignAsIs = kAsIs;
  opBest.ch2 = 0;   // (the plan held is ranked again on the second chains just designed, its own among them where it is one of these)
  for (int ln = 1; ln <= OP_DEPTH; ln++) if (opByLenHave[ln] && (!opHave || opPacier(&opByLen[ln], &opBest))) { opBest = opByLen[ln]; opHave = 1; }
  opGrewCh2 = opHave ? opBest.ch2 : 0;
}
static Played playOf(const Read *R, int n) {
  Played P; memset(&P, 0, sizeof P);
  // (the opening's wait for the raise is a hold, so only while the hold lives: where it does not, the order decides -- a line that lives
  // is never passed over for a raise to come)
  int holdLivesNow = 0;
  for (int i = 0; i < n; i++) if (order[i]->hold && order[i]->o.lives) holdLivesNow = 1;
  // (and never while a chain falls: the raise cannot come then, and the chain is extended)
  P.wait = R->low && !R->up && !(n && order[0]->k.extend) && holdLivesNow && !cascadeLive(decQ.b) && decQ.b->chainCounter == 0 && !cdAsk;
  decWhy = 0; P.top = R->up || P.wait ? 0 : (n ? order[0] : 0);
  // (the line in progress that waits for the board is played as it was judged: its next swap from the frame the judge pressed it from)
  P.line = P.top && !P.top->hold && (!P.top->wait || P.top->k.play == PLAY_CARRYWAIT) ? P.top : 0;
  // (A SWAP AND ITS SWAP BACK ARE A WAIT -- the owner: no flip and back: two swaps of the line played that swap a pair and straight back
  // (judge.c noops) leave the board as it stood, so the line is handed on without them, every swap left pressed from the frame the judge
  // pressed it from; a line of nothing else is the hold)
  if (P.line && !P.line->o.dead && P.line->o.j.noops) {
    static Judge Wt; const Judge *L = P.line; int64_t m = L->o.j.noops; int q = 0, nq = 0;
    Wt = *L;
    for (int i = 0; i < L->k.nseq; i++) {
      if (i + 1 < L->k.nseq && i + 1 < 64 && ((m >> (i + 1)) & 1)) { i++; noopWaits++; continue; }
      Wt.k.seq[q] = L->k.seq[i];
      if (i < L->apNats) Wt.apAts[nq++] = L->apAts[i];
      q++;
    }
    Wt.k.nseq = q; Wt.apNats = nq;
    int kept = q;
    // (THE LINE AS IT WILL BE KEYED: the judge walked to each flip and paid for it out of the window; the frame loop presses neither, so
    // the swaps left are judged again as it keys them -- the cursor from where it stands, the window unspent, each walk begun no sooner
    // than the judge began it -- and handed on from the frames that judging presses them: a swap is never handed on from a frame
    // sooner than its keys can begin. The swaps it presses are the line; one it cannot press ends it there, and with none the hold.)
    if (q && nq == q) {
      int32_t nb[MAXLINE]; Judged wj;
      for (int i = 0; i < q; i++) nb[i] = decQ.b->clock + Wt.apAts[i];
      JudgeOpts jo = { L->settled, decQ.tight, NOT_ASKED, 0, 0, -1, 0, 0, 0, 0, 0, 1 };
      jo.notBefore = nb; jo.nNotBefore = q; jo.winWait = L->apBroke > 0;
      __atomic_store_n(&clockIgnore, 1, __ATOMIC_RELAXED); judge(&decQ, Wt.k.seq, q, &jo, &wj); __atomic_store_n(&clockIgnore, 0, __ATOMIC_RELAXED);
      q = wj.late ? 0 : imin(q, wj.nats);
      for (int i = 0; i < q; i++) Wt.apAts[i] = wj.ats[i];
      Wt.k.nseq = q; Wt.apNats = q;
    }
    // (and where the swaps left cannot be keyed as judged -- the walk without the flips takes longer than the frames the judge pressed
    // them from -- the line is played as it was judged, flips and all: the board it was judged on is the board the frame loop makes,
    // and the hold in its place is a board nobody judged it would keep)
    P.line = q ? &Wt : kept ? L : 0;
  }
  // (JUST IN TIME: a line whose first swap clears nothing and whose next is not due until well after the next decision is held while it
  // does as well with that swap pressed later -- the next decision plans it again, so a first swap pressed early is undone by the next
  // plan's)
  // (held only while the board left alone lasts to the frame the swap would be pressed)
  double holdLost = -1;
  // (the hold's loss as the order reads it, rank.c lostOf: a hold whose loss was not judged is lost now, never 'never' -- an unknown
  // never licenses waiting)
  // (and only while the hold lives: on a board left alone that is lost, a swap put off is put off again by the next plan until the board
  // is gone -- a line that saves it is played now)
  int holdLives = 0;
  for (int i = 0; i < n; i++) if (order[i]->hold && !order[i]->o.dead) { holdLost = lostOf(order[i]); holdLives = !!order[i]->o.lives; }
  // (run 280: never with nobody across above six colours -- the stage is against the clock, and the decisions held so (held=timing) were
  // 1-13 a 7-colour Line Clear in runs 271-279, each a swap pressed a decision later than it could be)
  if (P.line && holdLives && !(ruleNoEnemy && decQ.b->colors > 6) && P.line->apNats >= 2 && P.line->apAts[1] - P.line->apAts[0] > 2 * rankReact && holdLost > P.line->apAts[1] &&
      firstClear(&decQ, P.line->k.seq, P.line->k.nseq, 0) != 0 && !clockOut()) {
    const Judge *L = P.line;
    Outcome d = outcomeOf(L->k.seq, L->k.nseq, L->settled, 0, L->apAts[1] - rankReact);
    // (the line pressed later must be known to last as long: a loss it was not judged for never licenses waiting)
    double dl = d.lostAt == NOT_ASKED ? -1 : lostAtOf(d.lostAt, 0), ol = lostAtOf(L->o.lostAt, 0);
    if (!d.late && !d.dead && d.lives >= L->o.lives && d.j.made.broke >= L->apBroke && dl >= ol) { decWhy = __LINE__, P.line = 0; P.deferred = 1; }
  }
  // (THE COMBO TIMED FOR ITS STOP -- the owner: wait to do a combo to give more time, not as soon as it can be: in finish them, where
  // nothing lives, each of the best COMBO_TIMED combo lines (four or more, a 2x at most) is judged pressed later, COMBO_WAIT frames on and
  // on; one whose board then stands at least as long as the line on top's -- the stop its clear gives coming when the board needs it --
  // and still makes its combo is waited for: this decision presses nothing, the next one asks again)
  comboTimed = 0;
  // (never with an eight on top -- it is fired -- nor on a board left alone lost within two breaks' time: a wait there is a wait the
  // board does not survive the next decision getting wrong; set 86 combo_storm 1, an eight waited for at 92 frames from the loss, lost)
  if (finishAsked() && P.line && n && !order[0]->o.lives && !P.deferred && clockFrameOut && !clockFrameOut() &&
      !(P.line->apCombo >= 8 && P.line->apChain < 2) && !(holdLost >= 0 && holdLost < 2 * rankSave)) {
    double due = clockDue, share = clockShare; clockDue = 0; clockShare = 0;
    double topLost = diesAt(P.line);
    int tried = 0;
    for (int i = 0; i < n && tried < COMBO_TIMED && !clockFrameOut() && !comboTimed; i++) {
      const Judge *J = order[i];
      if (J->hold || J->o.dead || J->o.lives || J->apCombo < 4 || J->apCombo >= 8 || J->apChainAll > 2) continue;
      tried++;
      for (int w = COMBO_WAIT; w <= COMBO_WAIT_MAX && !clockFrameOut(); w += COMBO_WAIT) {
        if (holdLost >= 0 && w + rankSave >= holdLost) break;   // (a wait ends a break's time before the board left alone is lost)
        double sh = clockShareBegin(nowMs() + CUT8_MS);
        Outcome d = outcomeOf(J->k.seq, J->k.nseq, J->settled, 0, w);
        clockShareEnd(sh);
        if (d.late || d.dead) continue;
        double dl = d.lives ? 1e9 : d.lostAt == NOT_ASKED ? -1 : lostAtOf(d.lostAt, 0);
        if (d.j.made.combo >= J->apCombo && d.j.chainAll <= 2 && dl >= topLost && dl > diesAt(J)) { decWhy = __LINE__, P.line = 0; P.deferred = 1; comboTimed = w; break; }
      }
    }
    clockDue = due; clockShare = share;
  }
  // (THE SECOND HAND -- the owner: set up between moves, never at the cost of the board's life: where the decision is the hold, the next
  // swap toward the eight kept as the target (propose.c twinNextSwap), judged on the engine, is pressed instead -- only where it lives
  // as the hold does or is lost no sooner, breaks the board's chain no shorter, wastes no three and keeps the window's reserve)
  freeSetup = 0;
  if (!P.line && P.top && P.top->hold && !P.deferred && !R->up && !P.wait && twinWanted && !clockOut()) {
    int32_t sw;
    if (twinNextSwap(decQ.b, &sw)) {
      static Judge FS; Cand k; int32_t one[1] = { sw };
      const Judge *H = P.top;
      if (candOf(&k, PLAY_SETUP, one, 1, -1, 0)) {
        k.settled = 0; k.twin = 2; freeSetup = -1;
        // (turned down: -1 not played out, -2 lost sooner, -3 the chain cut short, -4 a wasted three, -5 the reserve -- the swap is the kept
        // eight's own, so it brings that eight a swap nearer by its making)
        if (!judgeCand(R, &k, &FS) || FS.o.dead) freeSetup = -1;
        else if (!(H->o.lives ? FS.o.lives : (FS.o.lives || (FS.o.lostAt != NOT_ASKED && diesAt(&FS) >= diesAt(H))))) freeSetup = -2;   // (an unknown loss is never no sooner)
        else if (cutsShort(&FS)) freeSetup = -3;
        else if (wastesThree(&FS)) freeSetup = -4;
        else if (spendsReserve(&FS)) freeSetup = -5;
        else if (twinSecond && !loadedAfter(one, 1)) freeSetup = -8;   // (the second eight's swap: never one that unloads the first)
        else { decWhy = __LINE__, P.line = &FS; freeSetup = 1; }
      }
    }
  }
  // (and IN THE CARRIED LINE'S WAIT -- the owner: build the eight in increments, between breaks and smaller combos: where the line in
  // progress waits for its next swap, the kept eight's next swap is pressed first and the line carried on after it, the two one line,
  // judged whole: only where it is lost no sooner than the line alone, breaks as much, meets as early an entry, cuts no chain short and
  // wastes no three)
  if (freeSetup == 0 && P.line && P.line->k.play == PLAY_CARRYWAIT && !P.line->o.dead && !P.deferred && !R->up && twinWanted && !clockOut()) {
    int32_t sw; const Judge *C = P.line;
    if (C->k.nseq + 1 <= MAXLINE && twinNextSwap(decQ.b, &sw)) {
      static Judge FW; Cand k; int32_t seq[MAXLINE + 1]; int ns = 0;
      seq[ns++] = sw; for (int i = 0; i < C->k.nseq && ns < MAXLINE; i++) seq[ns++] = C->k.seq[i];
      freeSetup = -6;
      if (candOf(&k, PLAY_SETUP, seq, ns, -1, 0)) {
        k.settled = C->settled; k.twin = 2;
        if (judgeCand(R, &k, &FW) && !FW.o.dead &&
            (C->o.lives ? FW.o.lives : (FW.o.lives || (FW.o.lostAt != NOT_ASKED && diesAt(&FW) >= diesAt(C)))) &&
            imax(0, FW.apBroke) >= imax(0, C->apBroke) && (FW.met < 0 ? MAXAIMS : FW.met) <= (C->met < 0 ? MAXAIMS : C->met) &&
            !cutsShort(&FW) && !wastesThree(&FW)) { decWhy = __LINE__, P.line = P.top = &FW; P.wait = 0; freeSetup = 2; }
      }
    }
  }
  // (THE WHOLE EIGHT BEFORE THE LINE IN PROGRESS -- the owner: eights between breaks: in finish them, where the decision carries a line
  // on, an eight offered whole (propose.c twinLines) is pressed first and the carried line after it, the two one line, judged whole:
  // taken where it fires the eight and is lost within a break's time of the carried line alone, or later -- each judged alone is lost
  // as if it were the last thing pressed, so an eight beside a break is never seen to leave the time for the break)
  if (freeSetup == 0 && P.line && P.line->carried && (P.line->k.play == PLAY_CARRY || P.line->k.play == PLAY_CARRYWAIT) && !P.line->o.dead &&
      !(P.line->apCombo >= 8 && P.line->apChain < 2) && !P.deferred && !R->up && finishAsked() && !clockOut()) {
    const Judge *C = P.line, *E = 0;
    for (int i = 0; i < n; i++) if (order[i]->k.twin == 1 && !order[i]->o.dead && order[i]->apCombo >= 8 && (!E || diesAt(order[i]) > diesAt(E))) E = order[i];
    if (E && E->k.nseq + C->k.nseq <= MAXLINE) {
      static Judge EW; Cand k; int32_t seq[MAXLINE]; int ns = 0;
      for (int i = 0; i < E->k.nseq; i++) seq[ns++] = E->k.seq[i];
      for (int i = 0; i < C->k.nseq; i++) seq[ns++] = C->k.seq[i];
      freeSetup = -7;
      if (candOf(&k, PLAY_ENTRY, seq, ns, -1, 0)) {
        k.settled = C->settled; k.twin = 1; k.x.combo = E->k.x.combo;
        if (judgeCand(R, &k, &EW) && EW.apCombo >= 8 && (finishEightBy(&EW, C) || (!EW.o.dead && diesAt(&EW) >= diesAt(C)))) { decWhy = __LINE__, P.line = P.top = &EW; P.wait = 0; freeSetup = 3; }
      }
    }
  }
  // (THE OPENER'S SECOND HAND -- the owner: the opener has the time to set its chain up and goes for its goal: where its decision is the
  // hold, on a board with no garbage on it and not raising (a block on its way is judged with the line), the trigger of a chain the mode's first entry asks for is
  // pressed, else the set-up swap the trigger chain is longest after (search/chainup.c) -- each judged as any line, pressed only living)
  chainUp = chainNow = chainAfter = 0; opTried = 0; opFallHeld = 0; opSecondCh = 0; opSecondWhy = 0; opLandedRows[0] = 0; opCdRows[0] = 0; opFallBar = opFallExt = 0; opFallWay = 0; opSpent = opSpentMat = opSpentHeld = 0; opFallLink = opFallLinkCh = 0; opDesigned = 0; opDesignedQuick = 0; opGrew = 0; opTryN = 0; opProveTried = opProved = opProvedBest = 0; opPairN = opPairBest = 0;
  // (not while a chain falls: that chain is extended -- the extension's lines are the move -- and nothing is begun or flattened under it)
  // (and the next chain, the first thrown, is planned under garbage too: its panels are the ones under it)
  int opNext = openerSum > 0 && opNeed > 0;
  int opWants = (!R->under || opNext) && R->rule >= 0 && theTables.r[R->rule].table == 2 && theList.n > 0 && (theList.aim[0].chain.op || opNext) && clockFrameOut && !clockFrameOut() &&
                (opNext || !cascadeLive(decQ.b)) && decQ.b->chainCounter == 0;
                // (run 71 tried no opener plan above six colours: 7 colours 5/8 against 6/8 with it -- thicc s2 lived, combo s1 and
                // insane s2 were lost. The opener stays at every colour count)
  // (THE OPENER AS ONE PLAN -- the owner: the opener includes everything it is going to do, the flattening too, and raises the moment
  // it is flat: while the opening raise is due and done before the next block lands, the plan is made on the board it will build on -- the stack
  // flattened (opFlatten), then raised the rows the raise asks on the engine -- and grown there in the decision's time. The flattening
  // is pressed first, as one line; with none left, the raise; then the plan, kept through the rows risen)
  opFlatPlayed = 0;
  // (not the countdown's: a plan made on the board raised is made on rows not yet dealt -- the countdown plans the board as it is, and
  // the raise is play's)
  if (opWants && !opLineOn && raiseOpening && !cdAsk) {
    double keepDue = clockDue, keepShare = clockShare; clockDue = 0; clockShare = 0;
    double left = C2.due ? C2.due - C2.margin - nowMs() : 100, grow = left * (cdAsk ? CD_GROW : 0.7); if (grow < 2) grow = 2;
    opGrowMs = (int32_t)grow; readyStop();
    static Question tq; tq = decQ;
    // (the flattening and the raise done before the next block lands: the plan is built on the board raised, the block judged with it)
    if (opTarget(&decQ, raiseRows, &tq) && (R->readyAt == NOT_ASKED || R->readyAt > tq.b->clock - decQ.b->clock)) {
      double sh = clockShareBegin(nowMs() + grow); openingGrow(&tq, decQ.b); clockShareEnd(sh);
      opGrew = 2;
      if (opFlatN > 0) {
        static Judge FL; Cand k;
        if (!decF.under && candOf(&k, PLAY_LEVEL, opFlat, opFlatN, -1, 0)) { k.settled = 1; if (judgeCand(R, &k, &FL) && !FL.o.dead && (FL.o.lives || !P.top || diesAt(&FL) >= diesAt(P.top))) { decWhy = __LINE__, P.line = P.top = &FL; P.wait = 0; opFlatPlayed = 1; } }
      }
    }
    clockDue = keepDue; clockShare = keepShare;
  }
  // (the plan takes the move whenever the move chosen lives and breaks nothing -- a level, a set-up, a line in progress, the hold -- not
  // only where the hold was chosen: the opening's whole time is the plan's)
  opLinkCands = 0; opLinkBest = 0;
  for (int i = 0; i < n; i++) if (!order[i]->hold && !order[i]->o.dead && order[i]->o.j.brokeLink > 0) { opLinkCands++; if (order[i]->apChainAll > opLinkBest) opLinkBest = order[i]->apChainAll; }
  const Judge *opTop = P.line ? P.line : P.top;
  // (the planned opener in progress goes on: no plan is grown or begun over it -- the carry presses it, and survival alone puts it down)
  // (and no other line takes its place while it can still be pressed and either lives or presses its last swap before the next block
  // lands -- one that cannot fire in time is survival's to decide)
  // (but not with garbage on the board: there the opener's line competes as every line does -- the owner: efficiency is key -- and the
  // window it would spend is the next break's)
  if (opLineOn && opCarried && !decF.under && !(P.line && P.line->carried)) { decWhy = __LINE__, P.line = P.top = opCarried; P.wait = 0; P.deferred = 0; }
  // (THE OPENER'S CHAIN FALLING -- the owner: as long as you extend, you can't die: the stack is still while it falls and the garbage
  // waits for it, so nothing is pressed under it but its extension -- a swap of anything else is a link taken from it)
  // (the opener's chain: one falling while the opener is the mode, held to until it lands whatever mode comes after it)
  // (the opener's chain: from the frame its trigger was handed on -- its first clear and the fall after it, before the chain counter
  // shows a link -- while the board still moves, and on while the chain counter runs; a slab popping with no trigger of ours is none)
  { int ours = opFiredAt >= 0 && decQ.b->clock - opFiredAt <= OP_FIRE_HOLD && (cascadeLive(decQ.b) || popLeft(decQ.b) > 0);
    int falling = decQ.b->chainCounter > 0 || ours;
    if (!falling) { opFalling = 0; if (opFiredAt >= 0 && decQ.b->clock - opFiredAt > OP_FIRE_HOLD) opFiredAt = -1; }
    else if (!opFalling && R->rule >= 0 && theTables.r[R->rule].table == 2) { opFalling = 1; opFallAt = decQ.b->clock; } }
  if (opFalling) {
    // (the best extension the order holds is played, the line on top too, whatever it is called; with none, the second chain's set-up or the hold)
    // (AN EXTENSION ONLY PAST THE CHAIN PLANNED -- the owner: planned for a 4x, the extension is only needed at the 5x: a line is played
    // only where its chain, as judged all of it, is longer than the chain left alone reaches -- the longest of them; anything else holds,
    // and the planned links fall untouched)
    // (AND ONLY UP TO WHAT THE OPENER STILL NEEDS -- the owner's eight, less the chains already thrown: a chain taken past it spends the
    // panels the garbage it brings back is dug with. A chain left alone that reaches it is not extended; of the extensions, the shortest
    // that reaches it, else the longest)
    const Judge *ext = 0; int32_t bar = 0, need = imax(OPENER_LEAST, OPENER_SUM - openerSum);
    for (int i = 0; i < n; i++) if (order[i]->hold) bar = order[i]->apChainAll;
    for (int i = 0; i < n && bar < need; i++) {
      const Judge *J = order[i];
      if (J->hold || J->o.dead || !opExtLine(J)) continue;
      if (J->apChainAll <= bar) continue;
      int32_t c = J->apChainAll, e = ext ? ext->apChainAll : 0;
      // (SHORT OF IT, THE BOARD KEPT -- the owner: survival comes after the eight, and a board lost after the chain makes no second one:
      // of two extensions short of what is still needed, the one whose board lives, else the one lost a break's time later, before the
      // longer)
      if (ext && c < need && e < need) {
        int la = J->o.lives, lb = ext->o.lives;
        if (la != lb) { if (la) ext = J; continue; }
        if (!la && J->o.lostAt != NOT_ASKED && ext->o.lostAt != NOT_ASKED && iabs(J->o.lostAt - ext->o.lostAt) >= rankSave) { if (J->o.lostAt > ext->o.lostAt) ext = J; continue; }
      }
      // (AND REACHING IT, THE BOARD KEPT ALL THE SAME -- the opener survives as well as making the eight: of two extensions that reach
      // what is needed, the one whose board lives, else the one lost a break's time later, before the shorter -- set 86 large_garbage 2,
      // an 8 extended to a board lost 74 frames after it)
      if (ext && c >= need && e >= need) {
        int la = J->o.lives, lb = ext->o.lives;
        if (la != lb) { if (la) ext = J; continue; }
        if (!la && J->o.lostAt != NOT_ASKED && ext->o.lostAt != NOT_ASKED && iabs(J->o.lostAt - ext->o.lostAt) >= rankSave) { if (J->o.lostAt > ext->o.lostAt) ext = J; continue; }
      }
      // (OF TWO ALIKE, THE ONE THAT COSTS FEWER ACTIONS -- the owner: distance matters, a swap nearby before one further away: the same
      // chain, the boards alike -- both living, or lost within a break's time of each other -- the one the window pays less for; the
      // window is the game's 76 actions in 600 frames, and run 4165 large_garbage 8 spent 74 of them in 340 frames, the opener's extends
      // walking row 8 to row 1, and held at 1 to 2 as the garbage landed)
      if (ext && c == e && J->o.lives == ext->o.lives && (J->o.lives || (J->o.lostAt != NOT_ASKED && ext->o.lostAt != NOT_ASKED && iabs(J->o.lostAt - ext->o.lostAt) < rankSave))) {
        if (lineWalk(J) < lineWalk(ext)) ext = J;
        continue;
      }
      if (!ext || (c >= need ? (e < need || c < e) : (e < need && c > e))) ext = J;
    }
    // (NO LINK PAST WHAT A SECOND CHAIN LEAVES TO DO -- the owner: a 5 and a 3: short of what is still needed, the next chain must be a
    // chain of OPENER_LEAST or more however long this one runs, so links that do not reach need spend the panels the next chain is made
    // of: past need - OPENER_LEAST the chain as it falls is kept, and below it the extension that reaches there in the fewest links -- in
    // a garbage game, where the panels the next chain is made of come back slowly)
    int tall = tallGarbage(&decQ); const Judge *two = 0; int twoAsked = 0;
    // (THE CHAIN NEVER SPENDS THE BOARD -- the owner: keep enough to break the garbage: an extension that leaves fewer than OP_KEEP_PANELS
    // panels once its chain has landed (matSettled) is not played where holding keeps more and is lost no sooner (run 4151 large_garbage 8, 519: an
    // extend lost at 155 refused for a set-up lost at 99) -- the chain falling kept as it is, the raise
    // pressed once it lands; r1412: three chains back to back, the panels 54 to 27 before any garbage landed, the board lost at 2538)
    // (the hold measured on the board itself where the order has dropped it: run 4153 combo_storm 4, 767-921, the hold out of the order
    // and lineups the floor never saw took the chain 4 to 13 and the panels 26 to 5 under garbage, the board lost at 1533)
    const Judge *heldJ = 0; for (int i = 0; i < n; i++) if (order[i]->hold) heldJ = order[i];
    int32_t heldMat = heldJ ? heldJ->o.matSettled : opRootMat();
    double heldDies = heldJ ? diesAt(heldJ) : R->F.v[FACT_US_DIES];
    // (and under garbage, a chain that leaves the next break farther than holding does: run 4159 large_garbage 6, 541-680, lineups to
    // the eight took the stack down from under the slab, left perched on one column, no break proposed again, the board lost at 858)
    // (and under garbage, a chain that spends the input window's reserve for the next break (rank.c spendsReserve) -- the game allows 76
    // actions in 600 frames: run 4166 large_garbage 1, 571-749, the opener's lineups under the slab took the window 27 to 0 and the
    // board was held to its loss at 976. With no garbage on the board the opener spends freely: the reserve everywhere cost the eights)
    #define FARTHER_OFF(J) (decF.under && heldJ && (J)->o.nearAfter >= 0 && heldJ->o.nearAfter >= 0 && (J)->o.nearAfter > heldJ->o.nearAfter)
    // (a chain that buys less than a break's time over holding buys no break with the panels it spends; and the window's reserve is kept
    // for the break once garbage is on its way -- telegraphed, or queued behind the chain falling (rank.c garbageComing) -- not only once
    // it has landed)
    // (AND NEVER A CHAIN THAT LEAVES THE BOARD UNREADY WHERE ANOTHER WAY KEEPS IT READY -- the owner: just don't die: the chain falling
    // holds the garbage back, and when it lands the whole queue drops at once, so a chain that leaves no break ready once everything
    // lands (judge.c breaksAfterLanding, the window counted) is refused where the hold or another line leaves one -- however much longer
    // its own chain postpones the loss. Runs 4223-4231: 9 of 13 early losses, the opener's chain run to x8-x12 and 5-12 pieces dropped
    // on a board with no break, g4228 logging no line ready at 510 and spending 22 actions more on the eight)
    int readyElse = 0; for (int i = 0; i < n && !readyElse; i++) if (!order[i]->o.dead && order[i]->o.j.ready == 1) readyElse = 1;
    #define UNREADY(J) ((J) && readyElse && (J)->o.j.ready == 0)
    #define SPENDS_BOARD(J) ((J) && !(J)->o.lives && ((heldDies + rankSave > diesAt(J) && ((heldMat >= 0 && (J)->o.matSettled >= 0 && (J)->o.matSettled < OP_KEEP_PANELS && heldMat > (J)->o.matSettled) || FARTHER_OFF(J) || ((decF.under || garbageComing()) && spendsReserve(J)))) || UNREADY(J)))
    opSpentHeld = heldMat;
    if (SPENDS_BOARD(ext) && (ext->apChainAll < need || UNREADY(ext))) { opSpent |= 1; opSpentMat = ext->o.matSettled; ext = 0; }   // (the eight made is never refused)
    // (AND NEVER THE NEXT BREAK'S ACTIONS -- the owner: don't overspend if it's killing you: in any game with an enemy, an extension that
    // breaks no garbage and leaves the window under a break's walk where the next break can be needed (rank.c spendsReserve: now under
    // garbage, else at its landing or the soonest an attack can land) is refused, the eight included and however long its chain keeps the
    // stack still: when the garbage lands the window is empty and the garbage unbroken)
    if (ext && !(ext->apBroke > 0) && spendsReserve(ext)) { opSpent |= 4; ext = 0; }
    // (and in any game, a chain that counts already held where the board it lands on has the rest: the next chain designed there a chain
    // of need - bar or more -- the countdown's pair, a 4 and the 4 it leaves, never spent on links that stop short of need)
    if (ext && ext->apChainAll < need && bar >= OPENER_LEAST) { opSecondFall = bar; two = opSecondSwap(R, n); twoAsked = 1; if (opSecondCh >= opSecondLeast()) ext = 0; }
    if (ext && ext->apChainAll < need && (tall || garbageSeen)) {
      int32_t enough = need - OPENER_LEAST;
      // (held for the next chain only where the board the chain lands on has one: the next chain designed there (opSecondSwap) a chain of
      // OPENER_LEAST or more; with none the chain falling is all there is, extended as any chain short of need)
      // (under smaller garbage held all the same: the board it lands on is full of colours its pops have not shown, a next chain seldom
      // designed there, and the 5 and the 3 come; under tall garbage, a 5 often leaves no 3 at all)
      if (bar >= enough && !tall) ext = 0;
      else if (bar >= enough) { if (!twoAsked) { opSecondFall = bar; two = opSecondSwap(R, n); twoAsked = 1; } if (opSecondCh >= OPENER_LEAST) ext = 0; }
      else if (ext->apChainAll > enough) {
        const Judge *fit = 0;
        for (int i = 0; i < n; i++) { const Judge *J = order[i];
          if (J->hold || J->o.dead || !opExtLine(J) || J->apChainAll <= bar || J->apChainAll < enough || J->apChainAll >= need) continue;
          if (!fit || J->apChainAll < fit->apChainAll || (J->apChainAll == fit->apChainAll && J->o.lives && !fit->o.lives)) fit = J; }
        if (fit) ext = fit;
      }
    }
    opFallBar = bar; opFallExt = ext ? ext->apChainAll : 0;
    opFallSeen = 0; opFallTop = -1; opFallDead = 0; opFallLineN = 0;
    for (int i = 0; i < n; i++) { const Judge *J = order[i]; if (J->hold || !opExtLine(J)) continue;
      opFallSeen++; if (J->o.dead) opFallDead++; else if (J->apChainAll > opFallTop) opFallTop = J->apChainAll;
      if (opFallLineN < 8) { int32_t *t = opFallLine[opFallLineN++]; t[0] = J->k.nseq; t[1] = J->apNats; t[2] = J->apChainAll; t[3] = J->o.dead; t[4] = J->k.x.chain; t[5] = J->o.lives ? -1 : J->o.lostAt; } }
    P.wait = 0; P.deferred = 0; opFallHeld++;
    // (THE WAY TO THE EIGHT -- the owner: two 4s, a 5 and a 3, or an 8: an extension that reaches what is still needed is played; else a
    // second chain set up where its chain and the falling one's add up to it -- the panels an extension short of it would spend are the
    // second chain's; else the extension, else the second chain's set-up)
    if (!twoAsked && !(ext && ext->apChainAll >= need)) { opSecondFall = bar; two = opSecondSwap(R, n); }
    int twoReaches = two && opSecondCh >= OPENER_LEAST && bar + opSecondCh >= need;
    // (THE GARBAGE BROKEN FOR THE NEXT CHAIN -- the owner: break the garbage and the second chain is there: with no extension at all --
    // extending comes first, any extension -- nor a second chain that adds to the eight, the line that breaks the most garbage beyond the hold, the chain as long as the
    // hold's -- the panels the garbage turns into are the next chain's)
    const Judge *brk = 0;
    if (bar < need && !(ext && ext->apChainAll >= need) && !twoReaches && (R->under || garbageComing())) {
      int32_t holdBroke = 0; const Judge *hj = 0; for (int i = 0; i < n; i++) if (order[i]->hold) { holdBroke = imax(0, order[i]->apBroke); hj = order[i]; }
      // (a hold that loses the board: a break that keeps it longer may end the chain falling short of the hold's, down to need -
      // OPENER_LEAST -- a 6 or a 5 the next chain a 3 all the same; the board left alone does not live)
      int32_t floor = hj && !hj->o.lives ? imin(bar, imax(OPENER_LEAST, need - OPENER_LEAST)) : bar;
      for (int i = 0; i < n; i++) {
        const Judge *J = order[i];
        if (J->hold || J->o.dead || J->apChainAll < floor || !(J->apBroke > holdBroke)) continue;
        if (J->apChainAll < bar && !(J->o.lives || (hj->o.lostAt != NOT_ASKED && J->o.lostAt != NOT_ASKED && J->o.lostAt > hj->o.lostAt))) continue;
        if (!brk || J->apBroke > brk->apBroke || (J->apBroke == brk->apBroke && J->apChainAll > brk->apChainAll)) brk = J;
      }
    }
    // (THE CHAIN CARRIED INTO THE GARBAGE -- the owner: break the garbage and the next chain is there: garbage a link breaks is converted
    // chaining (pa.c convertGarbagePanels) and the chain lives while it pops, its panels the next links as they come down. With no
    // extension reaching what is still needed nor a second chain adding to it, the line whose link breaks the most garbage, its chain as
    // long as the extension short of it, is played over that extension and over a break after the chain has ended -- never where the
    // chain left alone already reaches it)
    const Judge *lnk = 0;
    if (bar < need && !(ext && ext->apChainAll >= need) && !twoReaches)
      for (int i = 0; i < n; i++) {
        const Judge *J = order[i];
        if (J->hold || J->o.dead || J->o.j.brokeLink <= 0 || J->apChainAll < bar || (ext && J->apChainAll < ext->apChainAll)) continue;
        if (!lnk || J->apChainAll > lnk->apChainAll || (J->apChainAll == lnk->apChainAll && J->o.j.brokeLink > lnk->o.j.brokeLink)) lnk = J;
      }
    if (lnk) { opFallLink = lnk->o.j.brokeLink; opFallLinkCh = lnk->apChainAll; }
    // (SHORT OF IT, NOT AT THE BOARD -- the owner: a board lost after the chain makes no second one: an extension short of what is still
    // needed whose board is lost within OP_FALL_LOST gives way to the line ranked first of those whose board lives, or is lost
    // OP_FALL_KEEP later; never under a slab of two rows or more, where the loss foreseen counts neither the panels its pop brings -- their
    // colours not shown till then -- nor the time its pop stops the board: combo garbage, a row a piece, only)
    // (and the hold the rule falls back on with nothing else to play, alike, where its chain is short of need; never for a line that makes
    // the chain falling shorter than the hold's)
    const Judge *keep = 0, *held = 0;
    for (int i = 0; i < n; i++) if (order[i]->hold) held = order[i];
    // (THE OPENER NEVER DIES FOR ITS CHAIN -- the owner: the opener must not die: the hold the chain falls in, its chain made (bar >= need)
    // too, gives way the same; under a slab of two rows or more to a line that breaks it, and to a break that cuts the chain short -- set 86
    // large_garbage 1 finish, 819-1040: an 8x falling held, the board lost at 206, over a break lost at 586, the panels 39 to 16)
    // (and whatever the rule would play -- the chain carried into the garbage, a break, the second chain: set 86 combo_storm 8 finish,
    // 627-667, the chain carried on lost at 166-206 over a break of 36 cells lost at 348-369, the board lost at 832)
    const Judge *pick = ext && ext->apChainAll >= need ? ext : twoReaches ? two : lnk ? lnk : ext ? ext : brk ? brk : two ? two : held;
    const Judge *base = pick ? pick : held;
    int slab = garbageRows(&decQ, 2);
    // (lost too soon: before the chain falling has landed and a break could be made after it -- the board's own time, never a fixed count)
    int32_t fallLost = opLandIn() + rankSave;
    // (and under garbage, a break that keeps the board a break's time longer whatever the danger -- the owner: break the garbage
    // immediately: run 4158 large_garbage 8 fill, 475-585, extensions lost at 162-200 played over a break lost at 444-469, the board
    // lost at 811)
    int danger = base && base->o.lostAt != NOT_ASKED && base->o.lostAt < fallLost;
    if (base && !base->o.lives && base->o.lostAt != NOT_ASKED && (danger || decF.under))
      for (int i = 0; i < n && !keep; i++) { const Judge *J = order[i];
        if (slab && !(J->apBroke > 0)) continue;
        if (!danger && !(J->apBroke > 0)) continue;
        if (J != base && !J->hold && (J->apChainAll >= bar || J->apBroke > 0) && (J->o.lives || (J->o.lostAt != NOT_ASKED && J->o.lostAt - base->o.lostAt >= rankSave))) keep = J; }   // (a break's time: set 86 factory 8 finish, 612, a break 156 frames longer passed at OP_FALL_KEEP's 250, the board lost at 776)
    // (AND UNDER GARBAGE, A CHAIN THAT SPENDS THE WINDOW'S RESERVE GIVES WAY TO A BREAK LOST NO SOONER -- the eight too: the chain that
    // breaks nothing and leaves no walk for the next break leaves the garbage where it is and the window empty; a break that keeps the
    // board as long is the break made now)
    // (and a break kept a break's time longer under garbage is played over the eight too: the garbage broken is the board kept)
    int keepEight = keep && decF.under && keep->apBroke > 0;
    if (!keep && decF.under && base && base != held && !base->hold && !base->o.lives && !(base->apBroke > 0) && spendsReserve(base) && base->o.lostAt != NOT_ASKED)
      for (int i = 0; i < n && !keep; i++) { const Judge *J = order[i];
        if (J != base && !J->hold && !J->o.dead && J->apBroke > 0 && (J->o.lives || (J->o.lostAt != NOT_ASKED && J->o.lostAt >= base->o.lostAt))) { keep = J; keepEight = 1; } }
    if (!keep) { if (SPENDS_BOARD(lnk)) { opSpent |= 2; opSpentMat = lnk->o.matSettled; lnk = 0; } if (SPENDS_BOARD(two)) { opSpent |= 4; opSpentMat = two->o.matSettled; two = 0; twoReaches = 0; } }
    opFallWay = ext && ext->apChainAll >= need && !keepEight ? 1 : keep ? 7 : twoReaches ? 2 : lnk ? 6 : ext ? 3 : brk ? 5 : two ? 4 : 0;
    if (opFallWay == 7) { decWhy = __LINE__, P.top = keep; decWhy = __LINE__, P.line = keep->hold ? 0 : keep; }
    else if (opFallWay == 1 || opFallWay == 3) decWhy = __LINE__, P.line = P.top = ext;
    else if (opFallWay == 6) decWhy = __LINE__, P.line = P.top = lnk;
    else if (opFallWay == 5) decWhy = __LINE__, P.line = P.top = brk;
    // (never the second chain over the line ranked first where that line outlives it by a break's time: the opener gives way to survival
    // -- r1351, 807: a set-up lost at 103 played over an extend lost at 428, the board lost at 1119)
    else if (two && P.line && !P.line->hold && outlives(P.line, two)) { }
    else if (two) decWhy = __LINE__, P.line = P.top = two;
    else {
      // (WHILE IT LANDS, THE CURSOR WORKS -- the owner: can it not do something while it waits? organize, zip, set up: the best set-up,
      // lineup, zip, level or line toward a break in the order that keeps the chain falling as far as the hold does, wastes no three,
      // keeps the window's reserve and is lost no sooner than the hold -- else the hold)
      const Judge *h = 0, *sk = 0;
      for (int i = 0; i < n; i++) if (order[i]->hold) { h = order[i]; break; }
      const Judge *kp = 0;   // (no give-way while the chain lands: set 86 combo_storm 1, a line kept a break's time longer taken at 514, the board lost at 800 all the same -- main's opener survives it)
      // (A BREAK FIRST WHILE IT LANDS -- the owner: it can break with threes while it is still doing things: a line that breaks garbage,
      // keeps the chain falling as far as the hold does and is lost no sooner, is played over the hold and any set-up)
      for (int i = 0; i < n && !sk && h; i++) { const Judge *J = order[i];
        // (the chain cut short only by a break that outlives the hold by a break's time -- the garbage broken is the board kept: run 4151
        // large_garbage 8, 497, a break lost at 390 passed for a set-up lost at 121, the board lost at 733)
        // (and under garbage, the break the order itself puts first stands whatever chain it cuts: the garbage on the board is broken now,
        // and a set-up played in its place spends the window that break is pressed from)
        int first = decF.under && J == order[0];
        if (J->hold || J->o.dead || !J->k.nseq || !(J->apBroke > 0) || (!first && (cutsShort(J) || chainReach(J) < chainReach(h)) && !outlives(J, h))) continue;
        if (!(J->o.lives || (!h->o.lives && diesAt(J) >= diesAt(h)))) continue;
        sk = J; }
      for (int i = 0; i < n && !sk; i++) { const Judge *J = order[i];
        if (J->hold || J->o.dead || !J->k.nseq || !setupKind(J) || wastesThree(J) || spendsReserve(J) || cutsShort(J)) continue;
        if (SPENDS_BOARD(J)) { opSpent |= 8; opSpentMat = J->o.matSettled; continue; }   // (a set-up that spends what an extension may not)
        if (h && chainReach(J) < chainReach(h)) continue;
        if (!(J->o.lives || (h && !h->o.lives && diesAt(J) >= diesAt(h)))) continue;
        sk = J; }
      #undef SPENDS_BOARD
      #undef FARTHER_OFF
      #undef UNREADY
      if (sk) { decWhy = __LINE__, P.line = P.top = sk; opFallWay = kp ? 8 : 9; }
      else { decWhy = __LINE__, P.line = 0; decWhy = __LINE__, P.top = h ? h : P.top; } } }
  // (THE OPENER'S PLAN IS NOT PUT DOWN FOR A LATER LOSS -- the owner: nothing stops the opener's chain but survival: the plan in progress,
  // as judged still a chain of OPENER_LEAST or more and its board not lost while it is pressed, is played over any line ranked above it
  // for a loss after it -- what comes after the chain is the next decision's, and its stop time is the board's)
  opKept = 0;
  if (opLineOn && carriedJ && carriedJ->carried && P.line != carriedJ && !carriedJ->o.dead && carriedJ->apChainAll >= OPENER_LEAST && !R->up && !opFalling) {
    decWhy = __LINE__, P.line = P.top = carriedJ; P.wait = 0; P.deferred = 0; opKept = 1;
  }
  if (opLineOn && !(carryHeld() && P.line && P.line->carried)) opLineOn = 0;
  // (THE NEXT CHAIN DESIGNED -- the owner: chains of three or more adding up to the eight: the first thrown and the eight not yet made,
  // no chain falling -- garbage may be popping, a slab's pop lasting longer than the rest of the game -- and no plan of the opener's carried, the designer plans the chain still needed on the board as it stands, its
  // full rows under any garbage, judged ROOTED as the opener's first plans are; a plan whose chain as judged is what is still needed, its
  // board standing till it fires, is the opener's line -- any chain of OPENER_LEAST or more: every one adds to the eight, and a chain
  // short of what is still needed leaves the rest to the one after it)
  opNextDesign = 0;
  if (opNeed > 0 && openerSum > 0 && !opLineOn && decQ.b->chainCounter == 0 && !R->up && clockFrameOut && !clockFrameOut()) {
    double left = C2.due ? C2.due - C2.margin - nowMs() : 0;
    OpPath dp;
    opNextDesign = -1; opNextMs = (int32_t)(left * OP_NEXT_SHARE); opDesignWhy = 0;
    // (on the board as it stands only while nothing on it moves: a panel hovering above a swap refuses it, and a board in motion is not the
    // one its swaps meet -- moving, the next chain is designed on the board it settles to, below)
    // (what is still needed looked for first, in half the time, then any chain that counts)
    int32_t wantAll = imax(OPENER_LEAST, opNeed); int got = 0;
    opDesignCost = OP_NEXT_COST;
    if (left > 8 && !hasActivePanels(decQ.b)) {
      if (wantAll > OPENER_LEAST) { opDesignLeast = wantAll; got = opDesign(decQ.b, left * OP_NEXT_SHARE * 0.5, &dp, OP_NEXT_MAXSW); }
      if (!got) { opDesignLeast = OPENER_LEAST; got = opDesign(decQ.b, left * OP_NEXT_SHARE * (wantAll > OPENER_LEAST ? 0.5 : 1), &dp, OP_NEXT_MAXSW); }
    }
    opDesignCost = OP_CB_COST; opDesignLeast = OP_TWO_FROM;
    if (got) {
      opNextDesign = -2; opNextCh = dp.ch; opNextLen = dp.len + 1;
      int32_t seq[OP_DEPTH + 1]; int ns = 0; for (int i = 0; i < dp.len; i++) seq[ns++] = dp.path[i]; seq[ns++] = dp.trig;
      static Judge ND; Cand k;
      // (each swap pressed once its two panels are still, not once the whole board is: under a slab popping, a board let settle after
      // every swap waits out the pop each time)
      if (dp.ch >= OPENER_LEAST && candOf(&k, PLAY_ENTRY, seq, ns, -1, 0)) {
        k.settled = 0; lastDrop = -1; lastCut = -1;
        outRooted = 1; int ok = judgeCand(R, &k, &ND); outRooted = 0;
        opNextDesign = !ok ? -3 : ND.o.dead ? -4 : ND.apChainAll; opNextDrop = !ok ? lastDrop * 10 + (lastCut >= 0 ? lastCutWhy : 0) : -1;
        if (!ok) { opNextCut = lastCut; opNextCutCell = lastCutCell; opNextSeqN = imin(ns, 16); for (int i = 0; i < opNextSeqN; i++) opNextSeq[i] = seq[i]; boardRows(decQ.b, opNextRows, sizeof opNextRows); }
        if (ok && !ND.o.dead && ND.apChainAll >= OPENER_LEAST) {
          for (int s2 = 0; s2 < ND.o.j.nats && s2 < ND.k.nseq && s2 < MAXLINE; s2++) ND.k.seq[s2] = (CR(ND.k.seq[s2]) + ND.o.j.risen[s2]) * 8 + CC(ND.k.seq[s2]);
          decWhy = __LINE__, P.line = P.top = &ND; P.wait = 0; P.deferred = 0; opLineOn = 1;
        }
      }
    }
    // (and with the board still moving -- a slab popping, its panels' colours shown one by one -- the next chain designed on the board it
    // settles to (opSecondSwap), its next swap pressed as soon as its panels stand where that board has them: a chain of what is still
    // needed built as the colours show)
    // (over the line ranked first, unless that line's board lives and the swap's does not)
    if (opNextDesign < 0 && opNextDesign != -4 && cascadeLive(decQ.b)) {
      const Judge *t2 = opSecondSwap(R, n);
      // (the design's swap is judged alone, a board left as it is after it; its chain fired before the board is lost keeps the board -- a
      // chain falling cannot top out -- so it gives way only where it does not fire in time: set 86 large_garbage 6, a 3's design half
      // pressed, put down at 190 frames for a break that made a 2)
      int fires = opKeepOn && decQ.b->clock - opKeepAt <= 40 && R->F.known[FACT_US_DIES] && (opKeepSeq.n + 1) * OPEN_SWAP_FRAMES + popLeft(decQ.b) < R->F.v[FACT_US_DIES];
      // (nor over a line ranked first that outlives the swap by a break's time, where the swap's chain does not fire in time -- r1351, 1048: a
      // set-up lost at 71 over a line in progress lost at 306, the board lost 71 frames later)
      // (under garbage, nor over a break lost no sooner than it at all)
      // (nor over a break that outlives it, fired in time or not -- the garbage broken is the board kept: g4226 combo_storm 8, 715, a
      // design lost at 51 over a break of 28 cells lost at 646; g4230 factory 6, 1131)
      // (and under garbage, never a swap whose walk spends the next break's reserve (rank.c spendsReserve): the design's chain is built
      // out of the same window the break is pressed from)
      if (t2 && opSecondCh >= OPENER_LEAST && !(decF.under && spendsReserve(t2)) && !(P.line && P.line->o.lives && !t2->o.lives && !fires) && !(P.line && !P.line->hold && !fires && outlives(P.line, t2)) && !(P.line && !P.line->hold && P.line->apBroke > 0 && (outlives(P.line, t2) || (decF.under && !P.line->o.dead && (P.line->o.lives || diesAt(P.line) >= diesAt(t2)))))) { decWhy = __LINE__, P.line = P.top = t2; P.wait = 0; P.deferred = 0; opNextDesign = 100 + opSecondCh; }
      // (and while it waits for its panels to come to rest, the board is held: a clear short of what is needed spends the panels it is
      // made of -- set 86 factory 5, a 3's design half pressed, two 2s played in its waits and no 3)
      else if (!t2 && fires && opKeepOn && (opSecondWhy == 5 || opSecondWhy == 9) && P.line && !P.line->hold &&
               (P.line->apCombo > 0 || P.line->apChain > 0) && P.line->apChainAll < imax(OPENER_LEAST, opNeed)) {
        const Judge *h = 0; for (int i = 0; i < n; i++) if (order[i]->hold) h = order[i];
        if (h) { decWhy = __LINE__, P.top = h; decWhy = __LINE__, P.line = 0; P.wait = 0; P.deferred = 0; opNextDesign = 200; }
      }
    }
  }
  // (in its order: the flattening pressed, then the raise -- no plan begun over either)
  if (opWants && !opLineOn && !opFlatPlayed && opTop && (opNext || (opTop->o.lives && !(opTop->apBroke > 0))) && !P.deferred && !R->up && !P.wait) {
    double keepDue = clockDue, keepShare = clockShare; clockDue = 0; clockShare = 0;
    // (THE OPENING PLANNED, search/opening.c: the plan grown in the most of this decision's time the judging leaves, its next set-up
    // pressed while the plan's chain is longer than the chain of the trigger the board has now, its set-ups can be pressed before the next block lands and
    // its chain is one the mode asks for; else that trigger fires, if its chain is one the mode asks for)
    double left = C2.due ? C2.due - C2.margin - nowMs() : 100;
    double grow = left * (cdAsk ? CD_GROW : 0.7); if (grow < 2) grow = 2;
    opGrowMs = (int32_t)grow;
    // (the pool taken back from the readiness beside the decision, which would search on past it: the beam is scored on every thread)
    readyStop();
    { double sh = clockShareBegin(nowMs() + grow); openingGrow(&decQ, decQ.b); clockShareEnd(sh); }
    // (and the design: a chain the board's full rows make, offered as a plan beside the beam's -- in the countdown's time, or a slice of
    // the decision's)
    // (the countdown's design in 0.3 of what is left: on a slower runner a smaller share finds no plan at all -- set 86 factory 3)
    // (and a second design, in the swaps that can be pressed before the first garbage lands -- OPEN_FIRE_BY, OPEN_SWAP_FRAMES a swap: the
    // chain that fires in time, where the first design's fires past it)
    { double l3 = C2.due ? C2.due - C2.margin - nowMs() : 0, dms = cdAsk ? l3 * 0.3 : l3 * 0.2; OpPath dp;
      int quickSw = opBefore() ? (OPEN_FIRE_BY - decQ.b->clock) / OPEN_SWAP_FRAMES - 1 : 0;
      if (quickSw >= 2 && quickSw < OP_CB_MAXSW) opDesignedQuick = -quickSw;   // (tried in quickSw swaps, none found: the log's /q-N)
      for (int pass = 0; pass < (quickSw >= 2 && quickSw < OP_CB_MAXSW ? 2 : 1); pass++)
        if (opDesign(decQ.b, pass ? dms * 0.5 : dms * (quickSw >= 2 ? 0.5 : 1), &dp, pass ? quickSw : OP_CB_MAXSW)) {
          if (pass) opDesignedQuick = dp.ch;
          if (!opHave || opPacier(&dp, &opBest)) { opBest = dp; opHave = 1; }
          if (!opByLenHave[dp.len] || opPacier(&dp, &opByLen[dp.len])) { opByLen[dp.len] = dp; opByLenHave[dp.len] = 1; } } }
    // (THE DESIGNS PROVED, the countdown's: the designer asked at every swap budget from OP_CB_FEWEST to OP_CB_MAXSW -- it works on the
    // panels standing, not on the frames, so a design is judged as the game will play it at once: a design
    // whose chain as judged is OP_FAST_CH or more is kept at that chain, any other let go -- the plans tried are then plans that chain)
    if (cdAsk) {
      int32_t lastLen = -1;
      for (int sw = OP_CB_FEWEST; sw <= OP_CB_MAXSW && opProveTried < OP_PROVE_MAX && !clockOut(); sw++) {
        double l4 = C2.due ? C2.due - C2.margin - nowMs() : 0; if (l4 < 40) break;
        OpPath dp; if (!opDesign(decQ.b, l4 * 0.04, &dp, sw) || dp.ch < OP_FAST_CH || dp.len == lastLen) continue;
        lastLen = dp.len; opProveTried++;
        int32_t seq[OP_DEPTH + 1]; int ns = 0; for (int k = 0; k < dp.len; k++) seq[ns++] = dp.path[k]; seq[ns++] = dp.trig;
        static Judge PJ; Cand k; if (!candOf(&k, PLAY_ENTRY, seq, ns, -1, 0)) continue;
        k.settled = 1; lastDrop = -1;
        outRooted = 1; int pok = judgeCand(R, &k, &PJ); outRooted = 0;
        if (!pok || PJ.o.dead || !PJ.o.lives || PJ.apChainAll < OP_FAST_CH) continue;
        dp.ch = PJ.apChainAll; opProved++; if (dp.ch > opProvedBest) opProvedBest = dp.ch;
        if (!opByLenHave[dp.len] || opByLen[dp.len].ch < OP_FAST_CH || opPacier(&dp, &opByLen[dp.len])) { opByLen[dp.len] = dp; opByLenHave[dp.len] = 1; }
        if (!opHave || opPacier(&dp, &opBest)) { opBest = dp; opHave = 1; }
      }
    }
    // (the countdown's: the plans kept scored on the second chain each leaves, in the time the grow left)
    if (cdAsk) { double l2 = C2.due ? C2.due - C2.margin - nowMs() : 0; if (l2 > 4) { double sh = clockShareBegin(nowMs() + l2 * 0.6); opExtendAll(&decQ, l2 * 0.55); clockShareEnd(sh); } }
    // (and the second chain each leaves, at every decision until the first chain is thrown -- a plan grown longer later is kept only where
    // it makes the eight too: in the most of what the countdown's extensions left, a share of any other decision's)
    if (openerSum == 0) { double l5 = C2.due ? C2.due - C2.margin - nowMs() : 0; if (l5 > 8) { double sh = clockShareBegin(nowMs() + l5 * (cdAsk ? 0.5 : 0.3)); opPairAll(&decQ, l5 * (cdAsk ? 0.45 : 0.25)); clockShareEnd(sh); } }
    opGrew = 1;
    int32_t trig = 0, trigCh = 0;
    triggerSendOf(&decQ, &trig, &trigCh);
    chainNow = trigCh; chainAfter = opHave ? opBest.sent : 0;
    // (ONE MOVE, START TO FINISH -- the owner: the opener is a continuous move; once started it goes on, nothing stops or replans it but
    // survival: the plan's set-ups and its trigger handed on as one line, judged whole, then carried as the line in progress)
    // (THE PLANS TRIED, a pass at a time (opFits): each pass's plans, OP_TRIES at most, the best first -- the best of each length, ranked as
    // the plan is (search/opening.c opPacier) -- judged in turn; a plan that does not live, or as judged fires past OPEN_FIRE_BY in a pass
    // that asks it by then, gives way to the next, and a pass that plays none to the next pass; with none in any, the board's own trigger)
    opTried = 0;
    if (cdAsk) boardRows(decQ.b, opCdRows, sizeof opCdRows);
    // (a plan of OP_TWO_FROM or more that fires within OP_LATE is tried before a 2 to extend: half the eight in one chain, against a 2
    // that grows to a 3 -- set 86 factory 3, every 4 fired at 344-354 and the 2 taken made a 3)
    int late4 = opHave && opBest.ch >= OP_TWO_FROM && opFits(&opBest, trigCh, 3);
    for (int ln = 1; ln <= OP_DEPTH && !late4; ln++) late4 = opByLenHave[ln] && opByLen[ln].ch >= OP_TWO_FROM && opFits(&opByLen[ln], trigCh, 3);
    // (and before the 3 fired in time: a 4 and the 4 after it come sooner than a 3 and the 5 after it, the game's clock running out on
    // the second chain -- set 86 large_garbage 6, the 5 after the 3 landing at 1265 of a game that ends at 1300; the early slot takes plans
    // of OP_TWO_FROM or more only, the judge's board living all the same)
    static const int passOrder[2][OP_PASSES + 1] = { { 0, 1, 2, 3, 4, -1 }, { 0, 3, 1, 2, 3, 4 } };
    for (int pi = 0; pi < OP_PASSES + 1 && passOrder[late4][pi] >= 0 && chainUp <= 0; pi++) {
      int pass = passOrder[late4][pi], fourOnly = late4 && pi == 1;
      const OpPath *tries[OP_TRIES]; int nt = 0;
      if (opHave && opFits(&opBest, trigCh, pass) && (!fourOnly || opBest.ch >= OP_TWO_FROM)) tries[nt++] = &opBest;
      for (int ln = 1; ln <= OP_DEPTH; ln++) {
        const OpPath *c = &opByLen[ln];
        if (!opByLenHave[ln] || !opFits(c, trigCh, pass) || (fourOnly && c->ch < OP_TWO_FROM) || (nt && tries[0] == &opBest && !memcmp(c, &opBest, sizeof *c))) continue;
        int at = nt < OP_TRIES ? nt++ : OP_TRIES;
        // (passes 2 and 3 ask a chain in time: their plans tried fewest swaps first -- the one pressed soonest fires soonest; the others the plan's own
        // order)
        #define OP_BEFORE(a, b) (pass == 2 || pass == 3 ? (a)->len < (b)->len : opPacier(a, b))
        if (at == OP_TRIES) { if (!OP_BEFORE(c, tries[OP_TRIES - 1])) continue; at = OP_TRIES - 1; }
        tries[at] = c;
        for (int j = at; j > 0 && OP_BEFORE(tries[j], tries[j - 1]) && !(pass != 2 && pass != 3 && tries[j - 1] == &opBest); j--) { const OpPath *t = tries[j]; tries[j] = tries[j - 1]; tries[j - 1] = t; }
        #undef OP_BEFORE
      }
      for (int t = 0; t < nt && chainUp <= 0; t++) {
        int32_t seq[OP_DEPTH + 1]; int ns = 0;
        const OpPath *pl = tries[t]; for (int k = 0; k < pl->len; k++) seq[ns++] = pl->path[k]; seq[ns++] = pl->trig; opTried++;
        static Judge CU; Cand k;
        if (!candOf(&k, PLAY_ENTRY, seq, ns, -1, 0)) continue;
        k.settled = 1;
        // (turned down: -10 less the judge's drop code where it took it out (rank.c DROP_*), -2 its board is lost, -3 it does not live,
        // -4 it fires past OPEN_FIRE_BY in a pass that asks it by then, -5 a second chain under the floor, -6 judged short of the chain asked:
        // the log's, the first plan's)
        // (a design is judged ROOTED: its swaps are named on the board as it stands now (search/chainbuild.c), each pressed in the row its
        // panels have risen to by its frame -- the stack rises while a plan is pressed -- and handed on named where it is pressed. The
        // search's plans are named where each swap is pressed already, the rise in them, and are judged as named)
        lastDrop = -1; lastCut = -1;
        outRooted = pl->design;
        int jok = judgeCand(R, &k, &CU);
        outRooted = 0;
        int why = !jok ? -10 - lastDrop : CU.o.dead ? -2 : !CU.o.lives && !opNext ? -3 : 0;
        if (!why && pass < 4 && opBefore() && decQ.b->clock + (CU.apFire >= 0 ? CU.apFire : CU.apNats > 0 ? CU.apAts[CU.apNats - 1] : 0) > opFireBy(pass)) why = -4;
        // (-5 a second chain, in a garbage game, that leaves the board under its material floor: the panels the garbage is dug with)
        if (!why && openerThrown >= 1 && garbageSeen && CU.o.floorKept == 0) why = -5;
        // (-6 the chain as judged is not the chain the pass asks -- the judge plays the plan as the game will, the stack rising under it and
        // the rows it brings up, so a plan the search counts a chain and the judge counts none is a plan on a board that never was)
        if (!why && (opPassLeast(pass) ? CU.apChainAll < opPassLeast(pass) : !opAsked(CU.apChainAll))) why = -6;
        if (opTryN < OP_TRY_LOG) { int32_t *t = opTryLog[opTryN++]; t[0] = pass; t[1] = pl->len + 1; t[2] = pl->ch; t[3] = jok ? CU.apChainAll : -1;
          t[4] = jok ? (CU.apFire >= 0 ? CU.apFire : CU.apNats > 0 ? CU.apAts[CU.apNats - 1] : -1) : -1; t[5] = why; t[7] = pl->design; t[6] = jok ? CU.o.j.clearStep : lastCut >= 0 ? -1000 - lastCut * 100 - lastCutWhy * 10 - lastCutRisen : -2;
          if (opTryN <= 3) { opTrySeqN[opTryN - 1] = ns; for (int s = 0; s < ns; s++) opTrySeq[opTryN - 1][s] = seq[s]; } }
        if (!why) { if (pl->design) for (int s = 0; s < CU.o.j.nats && s < CU.k.nseq && s < MAXLINE; s++) CU.k.seq[s] = (CR(CU.k.seq[s]) + CU.o.j.risen[s]) * 8 + CC(CU.k.seq[s]);
          decWhy = __LINE__, P.line = &CU; chainUp = 3; openingReset(); opLineOn = 1; }
        else if (!chainUp) chainUp = why;
      }
    }
    if (chainUp <= 0 && trig && opAsked(trigCh)) {
      static Judge CT; Cand k; int32_t one[1] = { trig };
      if (candOf(&k, PLAY_ENTRY, one, 1, -1, 0)) { k.settled = 0; lastDrop = -1; if (judgeCand(R, &k, &CT) && !CT.o.dead && CT.o.lives) { decWhy = __LINE__, P.line = &CT; chainUp = 2; openingReset(); opLineOn = 0; } }
    }
    clockDue = keepDue; clockShare = keepShare;
  }
  // (TIME ATTACK, THE CHAIN DESIGNED -- the owner: flatten, raise to the top, then one chain that uses every block, up to 13, again and
  // again; the score is all there is, a combo is worth nothing: the design searched on in each decision's time (search/chainbuild.c) until
  // it holds TA_LINKS links, TA_DESIGN_MS have gone on it, or the stack is at the top; then its swaps are pressed TA_STEP at a time, worked
  // out afresh each decision from the board as it is, and its trigger last. A design the board no longer holds is let go.)
  taLog = 0; taxMs = -1;
  // (A CHAIN GOING, TIME ATTACK: the extension given the decision's time, and its longest line -- up to 13 -- played, every decision the
  // chain falls; the panel-game puzzles' way: a chain is taken a link at a time, a swap a link, in the time its own clears stop the rise)
  // (run 270: A STAGE'S WALL -- a Challenge stage (CHAOSBOT_CHALLENGE, the launcher's) ends at two minutes of the stopwatch (Match.lua
  // timeLimit 120), and a chain's rows are sent when it ends: a chain taken on past the wall sends none of them. Run 269 Line Clear 15:6
  // s35 counted 64 rows (60 asked) with a 5-chain begun at 7095 still going at the wall. Within TA_WALL_FRAMES of it the chain going is
  // no longer extended, so the chain ends and its rows land)
  if (ruleNoEnemy && !R->under && !R->topped && clockFrameOut && !clockFrameOut() && (cascadeLive(decQ.b) || decQ.b->chainCounter > 0) &&
      !taWallNear(decQ.b)) {
    double keepDue = clockDue, keepShare = clockShare; clockDue = 0; clockShare = 0;
    double left = C2.due ? C2.due - C2.margin - nowMs() : 100, ms = left * 0.8; if (ms < 2) ms = 2;
    readyStop();
    List L; memset(&L, 0, sizeof L); L.n = 1; L.aim[0].chain.op = OP_GE; L.aim[0].chain.n = 2; L.aim[0].brk = -1;
    ExtOpts eo = { TA_EXT_WIDTH, TA_EXT_DEPTH, &L, NOT_ASKED, 0, ms };
    static Ext E; extend(&decQ, &eo, &E);
    taxBase = E.baseChain; taxLong = E.longest.set ? E.longest.chain : 0; taxN = E.longest.set ? E.longest.nseq : 0; taxMs = (int32_t)ms;
    if (E.longest.set && E.longest.nseq > 0) {
      static Judge CU; Cand k;
      if (candOf(&k, PLAY_EXTEND, E.longest.seq, E.longest.nseq, -1, 1)) {
        k.settled = 0; lastDrop = -1;
        // (never a sooner death: the extension in the rank's place only where it lives or its board is lost no sooner than the rank's line's
        // -- a chain taken on over a tower ends with the tower at the top)
        if (judgeCand(R, &k, &CU) && !CU.o.dead && (CU.o.lives || !P.line || diesAt(&CU) >= diesAt(P.line))) { decWhy = __LINE__, P.line = &CU; taLog = 3; }
        else taLog = -20 - lastDrop;
      }
    }
    // (run 282: THE LINE BEGUN KEPT -- a new answer takes the place of the line the frame loop is pressing (front.c), so a line whose
    // deciding swap is due after the next decision is planned again and again and never pressed: run 281's 15:6 s35 played the chain going
    // five decisions running at 1981-2093 and 391-475, each time a 2-chain foreseen in 1-3 swaps and none made. So the line in progress
    // (carried) that makes the chain at least as long, and lives as long, is played on in the new line's place)
    if (taLog == 3 && P.line) {
      const Judge *NL = P.line;
      for (int i = 0; i < n; i++) { const Judge *J = order[i];
        if (!J->carried || J == NL || J->o.dead || J->o.j.made.chain < NL->o.j.made.chain || J->o.j.made.chain <= 0) continue;
        if (!(J->o.lives || diesAt(J) >= diesAt(NL))) continue;
        decWhy = __LINE__, P.line = J; taLog = 4; break; }
    }
    clockDue = keepDue; clockShare = keepShare;
  }
  else if (ruleNoEnemy && !R->under && !R->topped && clockFrameOut && !clockFrameOut() && !cascadeLive(decQ.b) && !R->pop) {
    double keepDue = clockDue, keepShare = clockShare; clockDue = 0; clockShare = 0;
    static CbGrid G; cbOfBoard(decQ.b, &G);
    if (taHave) { int sft = cbShiftOf(&G, &taD); if (sft < 0) { taReset(); taLog = -1; } else cbShiftUp(&taD, &G, sft); }
    int nfull = 0; for (int r = 1; r <= G.rows; r++) nfull += cbFull(&G, r);
    // (flattened and raised first -- the owner's order: a design is searched only on a board with TA_FULL full rows; till then the board
    // is played as any is, levelled and raised)
    // (run 251: above six colours from 4 full rows, not 6 -- run 250 Line Clear 15:5 (7 colours): the design never built in 312 decisions,
    // 190 of them never searched, the chains only those taken on as they fell; 23-28 rows a minute where 26-32 were asked)
    if (!taOn && nfull < (decQ.b->colors > 6 ? 4 : TA_FULL)) { if (taHave) { taReset(); taLog = -4; } }
    else if (!taOn) {
      double left = C2.due ? C2.due - C2.margin - nowMs() : 100, ms = left * 0.7; if (ms < 2) ms = 2;
      readyStop();
      static CbGrid D; int32_t tr = 0; int links = 0, sw = 0;
      // (no more swaps than the board lives to press: the frames it has left alone, a swap's frames each, TA_MARGIN to spare)
      int32_t dies = R->F.known[FACT_US_DIES] && R->F.v[FACT_US_DIES] > 0 ? (int32_t)R->F.v[FACT_US_DIES] : NOT_ASKED;
      cbJMaxSw = imin(TA_MAXSW, dies == NOT_ASKED ? CB_MAXSWAPS : imax(1, (dies - TA_MARGIN) / TA_SWAP_FRAMES - 1));
      if (taHave && cbSwapsTo(&G, &taD) > cbJMaxSw) { taReset(); taLog = -3; }
      int32_t v = cbDesignAll(&G, taHave ? &taD : 0, ms, &D, &tr, &links, &sw);
      taMs += ms;
      if (tr && v > 0 && (!taHave || v >= taVal)) { taD = D; taTr = tr; taLinks = links; taSwaps = sw; taVal = v; taHave = 1; }
      // (run 252: above six colours built after half the search -- searched from 4 full rows now (run 251), the design was let go 18 times in
      // run 251 Line Clear 15:6 s35 (the board no longer held it) and never built, 67 decisions searching; 15:5 s36 built it 11 times and won)
      if (taHave && (taLinks >= TA_LINKS || taMs >= (decQ.b->colors > 6 ? TA_DESIGN_MS / 2 : TA_DESIGN_MS) || panelTop(decQ.b) >= TA_TOP)) taOn = 1;
      // (and while it is searched, the board is left as it is -- a swap played meanwhile changes the rows the design is of -- unless it
      // is dying or raised: a raise only lifts the rows)
      else if (taHave && !R->taDying && !R->up && taHoldNoSooner(P.line, n)) decWhy = __LINE__, P.line = 0;
    }
    // (both held to the engine's clock: the hold is put in the line's place only where it tops the board out no sooner -- an uneven stack
    // whose tall column a clear brings down is never held up while the rise takes it to the top)
    // (and till a design is on, nothing cleared on a board that lives -- the owner: flatten, raise, then the chain that uses every block; a
    // clear made on the way spends the panels the design is made of, and starts a chain too short to take to 13)
    if (!taOn && !R->taDying && P.line && taClears(P.line) && taHoldNoSooner(P.line, n)) decWhy = __LINE__, P.line = 0;
    if (taOn) {
      int32_t seq[CB_MAXSWAPS + 1]; int n = cbOrder(&G, &taD, taTr, seq, CB_MAXSWAPS + 1);
      // (never a build the board does not live through -- the owner: you can't choose to die: the swaps left and the trigger, walked and
      // pressed, inside the frames the board has left alone with TA_MARGIN to spare -- the chain's clears stop the rise; else the design is
      // let go and the board is played for its life)
      int32_t dies = R->F.known[FACT_US_DIES] && R->F.v[FACT_US_DIES] > 0 ? (int32_t)R->F.v[FACT_US_DIES] : NOT_ASKED;
      if (n > 0 && dies != NOT_ASKED && dies < n * TA_SWAP_FRAMES + TA_MARGIN) { taReset(); taLog = -3; n = 0; }
      else if (n <= 0) { taReset(); taLog = -2; }
      else {
        int hand = n == 1 ? 1 : imin(TA_STEP, n - 1);
        static Judge CU; Cand k;
        if (candOf(&k, PLAY_ENTRY, seq, hand, -1, 0)) {
          k.settled = 1; lastDrop = -1;
          int jok = judgeCand(R, &k, &CU);
          if (jok && !CU.o.dead) { decWhy = __LINE__, P.line = &CU; taStep = hand; taLog = n == 1 ? 2 : 1; if (n == 1) taReset(); }
          else { taLog = -10 - lastDrop; if (n == 1) taReset(); }
        }
      }
    }
    clockDue = keepDue; clockShare = keepShare;
  }
  // (and the rank's own line that takes the falling chain on, near the wall, held -- the chain let end, its rows sent -- where the board
  // lives as long held)
  // (run 271: any line, not only one the judge counts as lengthening it -- run 270 15:6 s36's 2-chain fired at 7047 was taken to 6 by
  // 7224 through lines carried on and set-ups; and no line put in the hold's place on the way to the action, below)
  int wallHold = ruleNoEnemy && taWallNear(decQ.b) && decQ.b->chainCounter > 0 && !R->taDying;
  if (wallHold && P.line && taHoldNoSooner(P.line, n)) decWhy = __LINE__, P.line = 0;
  // (AND NO WAITING WHERE THERE IS A WAY TO THE ACTION: where the move is the hold or a line in progress waiting for the board, the best
  // line on the way to the action (enRoute) is played instead -- lost no sooner than the hold, the next break's reserve kept)
  if (!R->up && !P.wait && enOn && !wallHold && (!P.line || P.line->k.play == PLAY_CARRYWAIT)) {
    const Judge *H = 0; for (int i = 0; i < n && !H; i++) if (order[i]->hold) H = order[i];
    const Judge *T = P.top ? P.top : H;   // (the line it would take the place of: the order's first, the hold among them)
    for (int i = 0; i < n && H && T && !H->o.dead; i++) { const Judge *J = order[i];
      if (!enRoute(J) || farForNothing(J) || undoesLast(J) || spendsReserve(J)) continue;
      // (lost no sooner than the line it takes the place of, nor a break's time sooner than any line offered)
      if (!(J->o.lives || (!T->o.lives && diesAt(J) >= diesAt(T)))) continue;
      // (as the answer's own check reads it -- answer.c sooner: no line offered is lost later, its walk charged, and not alike)
      { int sooner = 0; for (int q = 0; q < n && !sooner; q++) { const Judge *K = order[q]; if (K == J || K->o.dead) continue;
          if (!(K->o.lives || lostOf(K) > lostOf(J))) continue;
          sooner = K->o.lives ? !J->o.lives : (!J->o.lives && !lostAlike(J, K) && !(walkTurns(J, K) && diesAt(J) > diesAt(K))); }
        if (sooner) continue; }
      decWhy = __LINE__, P.line = P.top = J; P.deferred = 0; enPlayed++; break; }
  }
  // (THE REACH HELD TO THE END: a line put in the order's place after the cut -- a set-up, a plan, a trigger -- keeps to the reach and
  // takes no flip back as the order does: the best line the order kept is played instead, the hold among them)
  if (P.line && !R->up && (farForNothing(P.line) || undoesLast(P.line) || overspends(P.line))) {
    const Judge *in = 0; for (int i = 0; i < n && !in; i++) if (!farForNothing(order[i]) && !undoesLast(order[i]) && !overspends(order[i])) in = order[i];
    decWhy = __LINE__, P.line = !in || in->hold || (in->wait && in->k.play != PLAY_CARRYWAIT) ? 0 : in; decWhy = __LINE__, P.top = in; P.wait = 0; P.deferred = 0; reachCut++;
  }
  // (CHAOS: DON'T STALL THE QUEUE. Chaos drops queued garbage only while the board is quiet (Stack:shouldDropGarbage: no matching or
  // chaining panels for the modern queue, none active for classic and chaos), so a clear made while garbage waits holds it back -- and
  // the judge, its horizon short, ranks that later loss higher, again and again, until the panels are spent and every block drops at
  // once (run 7 combo_storm: 13-15 pieces held at the door, 47 panels burned to 9, broke=0). So while garbage waits in the queue, none
  // is on the board, the chosen line breaks none, and what waits fits under the level's ceiling with the stack as it is, the board is
  // left alone: the garbage drops while it is small, and is broken from the board.)
  // (run 100: and under garbage too while the queue is QUEUE_ROOM or fewer short of its limit (margin off) and the top row is empty --
  // fifty waiting is the loss, and only a quiet board drops; run 99 L11 8 colours lost both games to the queue at full health)
  // (run 166: above six colours from twenty-five waiting, not thirty-five -- the late 8-colour losses carry 20-35 waiting for thousands of
  // frames (run 165 insane s8: 21-35 from 12000 to the loss at 20355); only a quiet board drops, and from 25 the slabs held back come down
  // at once. Run 142 lowered the ranking rule (the top row kept empty) instead: 2/8)
  // (run 234: above six colours from fifteen waiting -- run 232 7 colours thicc s24 17000-19013: 26-32 waiting for a thousand frames with
  // 14-20 panels on the board, the breaks three cells each, lost at 19013; what drops and is broken is the panels the board was short of)
  int queueNear = decQ.b->marginTime == 1 && decQ.b->ninc >= CHAOS_QUEUE_LIMIT - (decQ.b->colors > 6 ? 35 : QUEUE_ROOM);
  if (P.line && (!R->under || queueNear) && !R->up && decQ.b->ninc > 0 && P.line->apBroke <= 0) {
    int32_t waiting = 0;
    for (int i = 0; i < decQ.b->ninc; i++) waiting += decQ.b->inc[i].height > 0 ? decQ.b->inc[i].height : 1;
    int32_t h = decQ.b->height ? decQ.b->height : 12;
    // (what waits must land without topping the board out; held back further, it only grows and the panels go -- run 9's insane
    // combo storm never let it drop under the stricter ceiling test, letDrop=0, and lost at 3455 with 11 rows dropped at once)
    chaosWaiting = waiting;
    // (run 170: above six colours, short of the queue's last 25, the board left alone only where what waits lands two rows under the
    // ceiling -- insane s7 lost runs 163-167 alike: between waves the stack grew to 57-62 panels, the board was left alone with 3 waiting
    // (run 167 at 6647, the top at row 10), a 6-wide slab landed on row 12 perched on one panel, and the waves after buried it at 7886)
    // (runs 170-171 tried it, 3/8 and 0/8 (from the start, then once garbage first landed): back to the ceiling)
    int32_t room = 1;
    if (panelTop(decQ.b) + waiting <= h - room) { decWhy = __LINE__, P.line = 0; P.deferred = 0; chaosLetDrop++; }
  }
  // (runs 75-76 tried draining the queue under garbage -- the hold over lines breaking nothing from 25 waiting, then over any line from 40:
  // level 8 6/8 then 5/8, the queue still reaching fifty (CHAOS_QUEUE_LIMIT) with full health -- a hold does not quiet a board whose
  // garbage pops slowly, and the breaks put off grow the queue. Reverted: the queue's limit at levels 7-8 is open)
  // (runs 78-79 left the board quiet for the queue -- a living hold, then the hold while stopped: level 7 2/8 both times. A quiet board
  // drops nothing with anything in the top row (Stack:shouldDropGarbage: panels_in_top_row first): run 79 combo s1 held 150 frames at
  // stop 258-114 with 25 waiting and none dropped. Reverted; run 80 digs instead (rank.c))
  P.name = P.line ? P.line->k.play : R->up ? -2 : PLAY_HOLD;   // -2: the raise
  for (int i = 0; i < n; i++) if (order[i]->o.lives) P.nlive++;
  P.ncands = n; orderN = n;
  // (the opener's trigger handed on now -- its line's last swap, or a plan or trigger it begins with nothing before: the chain it fires is
  // held to from here, its first clear and fall too)
  if (P.line && P.line->k.nseq == 1 && R->rule >= 0 && theTables.r[R->rule].table == 2 && ((opLineOn && P.line->carried) || chainUp >= 2)) opFiredAt = decQ.b->clock;
  decInv = 0;
  if (!decWhy && P.top && n > 1) { const Judge *ru = order[0] == P.top ? order[1] : order[0]; int32_t keep = cmpKey;
    if (ru && ru != P.top) { int c = compareJudged(P.top, ru); if (c > 0) { decInv = rankMoved ? 3 : 1; decInvKey = rankMoved ? rankMoved : cmpKey; decInvRu = ru->hold ? PLAY_HOLD : ru->k.play; } else if (c == 0) decInv = 2; }
    cmpKey = keep; }
  return P;
}
// THE LINE IN PROGRESS (carryOf): the line of the move played, when it has more than one swap and is a play -- not a hold or a clear. It
// keeps how it is pressed, what it was begun for (its entry, a break), and a panel of the bottom row it does not touch, by which it is
// found again once the stack has risen. A line handed to the frame loop is the line in progress too: the next decision judges what is
// left of it once the swaps the frame loop pressed of it since (carryFrom, carryPressed: the question's lineFrom, linePressed) are
// played, so a line begun is played on unless something ranks above it.
// (popping: a slab of garbage was popping on the board it was begun on -- a break the next decision finds popping is the line's own
// only when none was then)
// (ready: a break found on the board once everything lands, carried from a swap played for it -- offered, not put first: it was found
// on a board the stack is not yet)
// (made: what the line was ranked as making when it was played -- the judge's count, or the search's word for a line whose board is lost
// during it (rank.c judgeCand): the rest of such a line is read on it too, carriedCand)
enum { WHY_NONE, WHY_CHAIN, WHY_COMBO, WHY_BREAK, WHY_TWIN, WHY_FLAT, WHY_ZIP, WHY_DROP, WHY_LIVE, WHY_READY };   // (WHY_NONE: no reason -- a bug)
typedef struct { int32_t kind, a, b; } Why;
typedef struct { int32_t set, id, nrest, rest[MAXLINE], risen[MAXLINE], at[MAXLINE], settled, hasAim, broke, popping, ready, anchorRow, anchorCol, anchorId, waits, rule; Aim aim; Made made; Why why; } Carry;   // (rule: the mode it was begun in; why: the reason it was begun, the log's aim=)
static Carry theCarry;
static int carryHeld(void) { return theCarry.set; }
static int carryOpener(void) { return theCarry.set && theCarry.rule >= 0 && theCarry.rule < theTables.n && theTables.r[theCarry.rule].table == 2; }
// THE BREAK A LINE LIVES BY, NEXT: a line played that lives only by a break in reach once everything lands (its readiness) carries that
// break too, to be the line in progress once the line's own swaps are pressed -- the next decisions need not find it again
static Carry theCarryNext;
static int carriedFromReady(void) { return theCarry.ready; }
#define CARRY_WAITS 2
static int carryWaitsOut(void) { return theCarry.waits >= CARRY_WAITS; }
static int32_t carryFrom = -1, carryPressed;
// THE LINE WHOSE FIRST SWAP WAS NEVER PRESSED: the frame loop drops its plan when the board is not the one it was made for, and the
// swap an answer played can go with it, unpressed. The line played is kept whole beside the line in progress, and where the next
// question says the swap never went down (carryMoveOff: native.c, the question's moveOff) the whole line is the line in progress
// -- judged on the board as it is, as any carried line: a break begun is pressed while the board still allows it.
static Carry theCarryOff;
static int32_t hostMoveOff, carryMoveOff;
static Judged carryJ;   // (the line in progress as its own judging found it: the log's cj=)
// THE ANCHOR a line in progress is found again by: the first panel of the bottom row (its ids, row1) that no swap of the line touches,
// into theCarry; 0 when every one is touched. carryOf and carryReady ask it.
static int anchorInto(Carry *C, const int32_t *row1, const int32_t *seq, int n) {
  for (int c = 1; c <= W; c++) {
    if (row1[c] == NUL) continue;
    int touched = 0;
    for (int i = 0; i < n; i++) if (CR(seq[i]) == 1 && (CC(seq[i]) == c || CC(seq[i]) + 1 == c)) touched = 1;
    if (!touched) { C->anchorRow = 1; C->anchorCol = c; C->anchorId = row1[c]; return 1; }
  }
  return 0;
}
static int anchorOf(const int32_t *row1, const int32_t *seq, int n) { return anchorInto(&theCarry, row1, seq, n); }
// (first: the line's first swap left to carry -- 1 when it is the move played, 0 when the whole line is handed on, nothing pressed now)
// (waits: the decisions in a row the line has waited for the board to settle -- carryWaitsOut)
// (WHY THE LINE PLAYED WAS NOT HANDED ON, for the log: 0 it was, 1 no line, 2 it waits, 3 nothing of it left, 4 a tier past the set-ups
// that breaks nothing, 5 no bottom-row panel to anchor it to; -1 none asked)
static int32_t carrySkip = -1;
// (THE LINE IN PROGRESS, WHERE IT BEGAN: the frame and the kind of line it was begun as -- carried on, it is played as `carry` from then on;
// the log's `from`, so a reader sees what the swap pressed now is for)
// (WHAT LAST LET THE LINE IN PROGRESS GO, for the log of a decision that found none carried (answer.c ended 16): 1-5 the decision before
// played no line to hand on (carrySkip's), 6 a hold's break in reach not anchored, 7 the mode changed, 8 a new game)
static int32_t carryClr;
// (A SAVE: the line played outlives the hold -- it lives where the hold does not, or both are lost and it is lost later. Its swaps after
// the first are what the board lives by, whatever its tier: the next decision is asked before they are pressed, often with little
// time, and without the line in progress its answer -- a hold -- takes their keys' place)
static int savesOverHold(const Judge *k) {
  const Judge *H = 0;
  for (int i = 0; i < orderN && !H; i++) if (order[i]->hold) H = order[i];
  if (!H || !k || k->hold || k->o.dead || H->o.lives) return 0;
  return k->o.lives || diesAt(k) > diesAt(H);
}
// (the line from its swap `first` on, into C: anchored, each swap named in the rows of the board it was begun on; 0 with no anchor)
static int carryInto(Carry *C, const Read *R, const Judge *k, int32_t qid, int first) {
  int32_t row1[W + 1];
  for (int c = 1; c <= W; c++) row1[c] = anchorIdAt(decQ.b, c);
  // (the anchor is a panel of the board as it is now that no swap of the line moves: each swap named in this board's rows, the rows risen
  // by its press taken off)
  int32_t root[MAXLINE], nroot = imin(k->k.nseq, MAXLINE);
  for (int i = 0; i < nroot; i++) root[i] = (CR(k->k.seq[i]) - k->o.j.risen[i]) * 8 + CC(k->k.seq[i]);
  if (!anchorInto(C, row1, root, nroot)) return 0;
  // (each swap kept in the rows of the board it was begun on: a swap the judge pressed after the stack rose is named in the rows of the
  // board it is pressed on, so the rows risen by then are taken off, and only the rows risen since the line began beyond those are put
  // back when it is carried on -- a rise foreseen is never counted twice)
  C->set = 1; C->id = qid; C->nrest = k->k.nseq - first;
  for (int i = first; i < k->k.nseq; i++) { int32_t up = i < MAXLINE ? k->o.j.risen[i] : 0; C->rest[i - first] = (CR(k->k.seq[i]) - up) * 8 + CC(k->k.seq[i]); C->risen[i - first] = up;
    // (and the clock each swap's walk was judged to begin on: the carried line is judged pressing it no sooner)
    C->at[i - first] = i < k->o.j.nats && i < MAXLINE ? decQ.b->clock + k->o.j.ats[i] : 0; }
  C->settled = k->settled; C->broke = k->apBroke > 0; C->popping = popLeft(decQ.b) > 0;
  C->made = (Made){ k->apCombo, k->apChain, k->apBroke, k->k.x.cells };
  if (k->aim >= 0) { C->hasAim = 1; C->aim = R->guides.aim[k->aim]; }
  C->rule = R->rule;
  return 1;
}
static void carryOf(const Read *R, const Judge *k, int32_t qid, int first) {
  pvKeep(k, first, qid);
  if (k && !k->carried && k != carryCrossJ && !k->hold) { carryBeganAt = decQ.b ? decQ.b->clock : -1; carryBeganPlay = k->k.play; }
  else if (!k) carryBeganAt = carryBeganPlay = -1;
  int32_t waits = k && k->k.play == PLAY_CARRYWAIT ? theCarry.waits + 1 : 0;
  Why keepWhy = k && k->carried ? theCarry.why : (Why){ WHY_NONE, 0, 0 };
  carrySave = k && !k->hold && ((k->carried && carrySave) || wastesThree(k));
  carryTwo = k && !k->hold && ((k->carried && carryTwo) || shortChain(k));
  memset(&theCarry, 0, sizeof theCarry);
  theCarry.why = keepWhy;
  theCarry.waits = waits; carriedSunk = -1;
  // (a line that breaks garbage is carried whatever its tier: under garbage while the break waits, a breaking line ranks in the last
  // tier, and its swaps after the first are the break it was chosen for)
  carrySkip = !k ? 1 : (k->wait && k->k.play != PLAY_CARRYWAIT) ? 2 : k->k.nseq < first + 1 ? 3 : (k->t.tier > 4 && !(k->apBroke > 0) && !savesOverHold(k)) ? 4 : 0;
  // (the whole line kept, its first swap too, for the answer whose swap is played now: the same lines the line in progress keeps)
  memset(&theCarryOff, 0, sizeof theCarryOff);
  if (first == 1 && k && !k->hold && k->k.nseq >= 1 && !(k->wait && k->k.play != PLAY_CARRYWAIT) && !(k->t.tier > 4 && !(k->apBroke > 0) && !savesOverHold(k))) {
    theCarryOff.why = keepWhy;
    if (!carryInto(&theCarryOff, R, k, qid, 0)) memset(&theCarryOff, 0, sizeof theCarryOff);
  }
  if (carrySkip) { carryClr = carrySkip; return; }
  if (!carryInto(&theCarry, R, k, qid, first)) { carrySkip = 5; carryClr = 5; return; }
  carriedSunk = lineWalk(k);
  carriedTold = toldNow(); carriedLostAbs = k->o.lives ? -2 : (k->o.lostAt == NOT_ASKED || k->o.lostAt == FOREVER) ? -1 : (int64_t)decQ.b->clock + k->o.lostAt;
}
static int32_t carryRule(void) { return theCarry.rule; }
// THE BREAK A HOLD WAITS FOR is the line in progress too: a hold chosen because a break is in reach once everything lands is a promise
// of that break, kept by carrying it -- anchored to a bottom-row panel of the board it was found on -- so the next decision plays it on
// as soon as it lives. A swap played for the break it leaves in reach once everything lands (one swap: nothing of it handed on) is the
// same promise.
static void carryNextOf(const Judge *L) {
  memset(&theCarryNext, 0, sizeof theCarryNext);
  const Judged *j = L ? &L->o.j : 0;
  if (!j || L->hold || L->o.ready != 1 || j->readyN < 1 || !theCarry.set) return;
  if (!anchorInto(&theCarryNext, j->readyRow1, j->readyLine, j->readyN)) return;
  theCarryNext.set = 1; theCarryNext.id = -1; theCarryNext.nrest = j->readyN;
  for (int i = 0; i < j->readyN; i++) { theCarryNext.rest[i] = j->readyLine[i]; theCarryNext.at[i] = 0; }   // (found on the board once it lands: no frame judged)
  theCarryNext.settled = 0; theCarryNext.broke = 1; theCarryNext.ready = 1; theCarryNext.made = (Made){ 0, 0, 1, 0 };
}
static void carryReady(const Judge *H, int32_t qid) {
  const Judged *j = &H->o.j;
  if ((!H->hold && H->k.nseq != 1) || H->o.ready != 1 || j->readyN < 1) return;
  memset(&theCarry, 0, sizeof theCarry);
  if (!anchorOf(j->readyRow1, j->readyLine, j->readyN)) { carryClr = 6; return; }
  theCarry.set = 1; theCarry.id = qid; theCarry.nrest = j->readyN;
  for (int i = 0; i < j->readyN; i++) theCarry.rest[i] = j->readyLine[i];
  theCarry.settled = 0; theCarry.broke = 1; theCarry.popping = popLeft(decQ.b) > 0; theCarry.ready = !H->hold; theCarry.made = (Made){ 0, 0, 1, 0 };
}
// THE READINESS BESIDE THE DECISION (search/break.c readyJob): the boards the order will ask readiness of handed to the workers,
// worst-ranked first -- the decision asks them best-ranked first -- each searched by whichever thread begins it first. They search on
// past the decision, until the next one takes the pool back (readyStop): a break found then is kept for the decisions after. The
// decision itself runs as it would with no workers.
static Ctx *jobCtx;   // (the phase's own: the jobs make nodes only on their threads' contexts)
static void readySpread(int n) {
  if (pool.nworkers <= 0 || !readyPendN || leftMs() <= 0) return;
  uint8_t queued[READYPEND] = { 0 };
  int nj = 0;
  for (int i = n - 1; i >= 0 && nj < READYPEND; i--) {
    const Judge *J = order[i];
    int32_t p = J->o.j.readyPend - 1;
    if (!READY_ASKS(J) || p < 0 || p >= readyPendN || queued[p] || readyPend[p].gen != readyPendGen || readyPend[p].state != PEND_WAITING) continue;
    queued[p] = 1; readyJobs[nj++] = p;
  }
  if (!nj) return;
  if (!jobCtx) jobCtx = ctxOf(0);
  readyJobWork = clockWork; readyJobEnd = 0;   // (no share: each searched whole, unless the next decision comes first)
  __atomic_store_n(&jobStop, 0, __ATOMIC_SEQ_CST);
  startJobs(jobCtx, readyJob, nj);
}
static void readyStop(void) {
  if (!poolBusy) return;
  __atomic_store_n(&jobStop, 1, __ATOMIC_SEQ_CST);
  jobsDone(jobCtx);
}
// THE INTENTIONS (plans/gambit-infra.md A, F): besides the line in progress, the best lines a decision ranked that make something -- a
// clear, a chain, a combo, a break -- each kept with a bottom-row panel it does not touch (found again by it once the stack has risen,
// as the line in progress is) and what it made; the next decision offers each as it is, judged on the engine like every line, so what
// one decision found the next need not search for again. A kept line that no longer makes something is let go.
typedef struct { int32_t set, play, nseq, seq[MAXLINE], settled, anchorRow, anchorCol, anchorId; } Intent;
static Intent theIntents[NINTENT];
static int32_t keptOffered, keptPlayed, routeOffered, routePlayed;   // (the log's, this decision)
static int clearsSomething(const Judge *J) { return !J->hold && (J->apCombo > 0 || J->apChain > 0 || J->apBroke > 0); }
static int anchorFor(const int32_t *row1, const int32_t *seq, int n, int32_t *row, int32_t *col, int32_t *id) {
  for (int c = 1; c <= W; c++) {
    if (row1[c] == NUL) continue;
    int touched = 0;
    for (int i = 0; i < n; i++) if (CR(seq[i]) == 1 && (CC(seq[i]) == c || CC(seq[i]) + 1 == c)) touched = 1;
    if (!touched) { *row = 1; *col = c; *id = row1[c]; return 1; }
  }
  return 0;
}
static void keepIntents(int n, const Judge *played) {
  memset(theIntents, 0, sizeof theIntents);
  int32_t row1[W + 1];
  for (int c = 1; c <= W; c++) row1[c] = anchorIdAt(decQ.b, c);
  for (int i = 0, k = 0; i < n && k < NINTENT; i++) {
    const Judge *J = order[i];
    if (J == played || J->wait || J->o.dead || !clearsSomething(J) || J->k.nseq < 1) continue;
    Intent *I = &theIntents[k];
    if (!anchorFor(row1, J->k.seq, J->k.nseq, &I->anchorRow, &I->anchorCol, &I->anchorId)) continue;
    I->set = 1; I->play = J->k.play; I->nseq = J->k.nseq; I->settled = J->settled;
    for (int q = 0; q < J->k.nseq; q++) I->seq[q] = J->k.seq[q];
    k++;
  }
}
// (a line judged already this decision -- the same swaps, pressed the same way -- is the same answer: never judged twice)
static int judgedHas(int n, const Cand *k) {
  int st = k->settled >= 0 ? k->settled : settledPlay(k->play);
  for (int i = 0; i < n; i++) {
    const Judge *J = order[i];
    if (!J->hold && J->settled == st && J->k.nseq == k->nseq && !memcmp(J->k.seq, k->seq, sizeof k->seq[0] * k->nseq)) return 1;
  }
  return 0;
}
static int keptJudged(const Read *R, int n) {
  keptOffered = 0;
  for (int i = 0; i < NINTENT && !clockOut(); i++) {
    const Intent *I = &theIntents[i];
    if (!I->set) continue;
    // (a line taken from a chain falling or a slab popping is timed to it: the board a decision later is not the one it was found on)
    if (I->play == PLAY_EXTEND || I->play == PLAY_LINEUP) continue;
    int dr = NOT_ASKED;
    for (int r = 0; r < decQ.b->nrows && dr == NOT_ASKED; r++) if (decQ.b->p[r][I->anchorCol].f[ID] == I->anchorId) dr = r - I->anchorRow;
    if (dr == NOT_ASKED) continue;
    int32_t seq[MAXLINE];
    for (int q = 0; q < I->nseq; q++) seq[q] = (CR(I->seq[q]) + dr) * 8 + CC(I->seq[q]);
    Cand k;
    if (!candOf(&k, I->play, seq, I->nseq, -1, 0)) continue;
    k.settled = I->settled; k.kept = 1;
    if (judgedHas(n, &k)) continue;
    keptOffered++;
    if (judgeWalked(R, &k, &theJudged[n]) && clearsSomething(&theJudged[n])) { order[n] = &theJudged[n]; n++; }
  }
  return n;
}
// THE ROUTE (plans/gambit-infra.md B): of the lines ranked so far, the best that make something and are pressed settled, two at a time
// on columns apart -- one's clears cannot move the panels the other swaps -- made one line, pressed in the order the cursor reaches its
// swaps soonest (rank.c judgeWalked), judged whole on the engine and ranked with the rest: one walk that does both. And the same two
// pressed at once, the second while the first still clears (two ideas fired together): both attacks out in the time of one, where the
// engine says the second swap is still there to press.
#define ROUTE_TOP 4
static int routeCols(const Judge *J) { int m = 0; for (int q = 0; q < J->k.nseq; q++) m |= 3 << CC(J->k.seq[q]); return m; }
static int routeJudged(const Read *R, int n) {
  routeOffered = 0;
  const Judge *top[ROUTE_TOP]; int nt = 0;
  for (int i = 0; i < n && nt < ROUTE_TOP; i++) {
    const Judge *J = order[i];
    if (J->wait || J->o.dead || !clearsSomething(J) || !J->settled || J->k.route || J->k.play == PLAY_EXTEND || J->k.play == PLAY_LINEUP) continue;
    top[nt++] = J;
  }
  for (int a = 0; a < nt && routeOffered < NROUTE && !clockOut(); a++)
    for (int b = a + 1; b < nt && routeOffered < NROUTE && !clockOut(); b++) {
      const Judge *A = top[a], *B = top[b];
      if ((routeCols(A) & routeCols(B)) || A->k.nseq + B->k.nseq > MAXLINE) continue;
      int32_t seq[MAXLINE], m = 0;
      for (int q = 0; q < A->k.nseq; q++) seq[m++] = A->k.seq[q];
      for (int q = 0; q < B->k.nseq; q++) seq[m++] = B->k.seq[q];
      Cand k;
      if (!candOf(&k, A->k.play, seq, m, -1, 0)) continue;
      k.settled = 1; k.route = 1;
      if (!judgedHas(n, &k)) { routeOffered++; if (judgeWalked(R, &k, &theJudged[n])) { order[n] = &theJudged[n]; n++; } }
      if (routeOffered >= NROUTE || clockOut()) break;
      k.settled = 0; k.pair = 1;
      if (!judgedHas(n, &k)) { routeOffered++; if (judgeWalked(R, &k, &theJudged[n])) { order[n] = &theJudged[n]; n++; } }
    }
  return n;
}
// CARRIED ON: the rest of the line in progress, found again on this board by its bottom-row panel and
// played on as it is pressed, while every step is legal and it still makes what it was begun for. wait: its next step must wait for
// the board to settle.
// (why the line in progress was not carried on, for the log: 0 carried or none, 1 its anchor panel gone, 2 a step no longer there to
// press, 3 it no longer breaks and its swaps pressed did not, 4 it no longer makes what it was begun for)
static int carryDrop;
static int carryLate;   // (the line in progress dropped only because the clock stopped its judging: answer.c gives no answer then)
// (and for the log, the line dropped: the steps it had left, and for 2 how the judge ended it -- cut at, the steps it pressed)
static int32_t carryDropN, carryDropRest[MAXLINE], carryDropDead, carryDropCut, carryDropWhy, carryDropNats;
// (WHY NO LINE IN PROGRESS WAS OFFERED, for the frame loop's count of what ended its line -- answer.c ended: 0 one was; 16 none was
// carried by the last answer; 17 the frame loop asked on another line than the one carried; 18 every swap of it pressed; 19 the judge
// gave no judgement of it; 20 it wastes a three the save did not confirm; 21 the mode's list asks nothing)
// THE PLAN'S BOARD CHECKED (the log's pv=): the board the decision that played the line in progress was asked on, the swaps of it
// pressed since pressed on it as soon as the board lets them, run on to this frame -- against the board as it is: pv=same, or the first
// thing that differs
static Board *pvBoard; static Question pvQ; static int32_t pvSeq[MAXLINE], pvN, pvFirst;
static void pvKeep(const Judge *k, int first, int32_t qid) {
  // (a hold or a wait keeps the line before it: nothing is pressed, and the board it foresaw is checked on)
  if (!k || k->hold || !decQ.b) return;
  pvSet = 0; pvId = qid; pvNew = 1;
  if (!pvBoard) pvBoard = nb_new();
  if (!pvBoard) return;
  cloneBoard(pvBoard, decQ.b); pvQ = decQ; pvQ.b = pvBoard; pvN = imin(k->k.nseq, MAXLINE); for (int i = 0; i < pvN; i++) pvSeq[i] = k->k.seq[i]; pvFirst = first; pvSet = 1;
}
#define PV_UNSEEN_ROWS 70   // (unseenRows' place in pa.c HEAD, unseenBreaks after it)
static void pvCheckIn(int32_t skip) {
  pvKind = 0;
  int32_t pressed = pvFirst + skip;
  if (!pvSet || pressed <= 0 || pressed > pvN) return;
  Question q = pvQ;
  static Ctx *pvCtx; Ctx *x = pvCtx = ctxOf(pvCtx);   // (its own nodes: the judge's are read on after it)
  int n = rootOf(x, &q);
  for (int i = 0; n >= 0 && i < pressed; i++) {
    int from, out = pressWalk(x, n, MK_SWAP, CR(pvSeq[i]), CC(pvSeq[i]), stepTapped, &from);
    n = liveNode(x, out) ? out : -1;
  }
  if (n < 0 || !liveNode(x, n)) { pvKind = 2; return; }
  int t = decQ.b->clock - pvBoard->clock - NODE(x, n)->t;
  if (t < 0) { pvKind = 3; pvV[0] = -t; return; }
  if (t > 0) n = step(x, n, MK_LONG, 0, 0, t);
  const Board *p = liveNode(x, n) ? ensureBoard(x, n) : 0, *b = decQ.b;
  if (!p) { pvKind = 4; return; }
#define PV(k, a, bb) do { pvKind = (k); pvV[0] = (a); pvV[1] = (bb); return; } while (0)
  if (p->clock != b->clock) PV(5, p->clock, b->clock);
  if (p->nrows != b->nrows) PV(6, p->nrows, b->nrows);
  if (p->riseTimer != b->riseTimer) PV(11, (int32_t)(p->riseTimer * 1000), (int32_t)(b->riseTimer * 1000));
#undef PV
  // (every field of the stack's head, as the host loads it -- pa.c HEAD: 10 its index there, riseTimer first -- but the count of rows
  // and breaks dealt unseen, which the host does not keep)
  { int hi = 1;
#define PVH(f, lua) if ((double)p->f != (double)b->f && hi != PV_UNSEEN_ROWS && hi != PV_UNSEEN_ROWS + 1) { pvKind = 10; pvV[0] = hi; pvV[1] = (int32_t)p->f; pvV[2] = (int32_t)b->f; return; } hi++;
    HEAD(PVH)
#undef PVH
  }
  // (and every field of every panel, the row coming up included -- 9: row, column, field, foreseen, real)
  for (int r = 0; r < p->nrows; r++) for (int c = 1; c <= W; c++) for (int f = 0; f < NF; f++) {
    if (f == COLOR && p->p[r][c].f[COLOR] >= 30) continue;
    if (p->p[r][c].f[f] != b->p[r][c].f[f]) { pvKind = 9; pvV[0] = r; pvV[1] = c; pvV[2] = f; pvV[3] = p->p[r][c].f[f]; pvV[4] = b->p[r][c].f[f]; return; }
  }
  pvKind = 1;
}
// (a log's check, never the decision's: run whatever the clock says, and its work not charged to the decision)
static void pvCheck(int32_t skip) {
  int64_t w0 = clockWork;
  __atomic_store_n(&clockIgnore, 1, __ATOMIC_RELAXED);
  pvCheckIn(skip);
  __atomic_store_n(&clockIgnore, 0, __ATOMIC_RELAXED);
  clockWork = w0;
}
static int carriedCand(const Read *R, Cand *k, int *wait) {
  Carry *C = &theCarry;
  *wait = 0; carryDrop = 0; carryLate = 0;
  if (carryMoveOff && theCarryOff.set && theCarryOff.id == carryFrom) {
    *C = theCarryOff; memset(&theCarryOff, 0, sizeof theCarryOff); memset(&theCarryNext, 0, sizeof theCarryNext); carriedSunk = -1; carryPressed = 0;
  }
  carryNone = !C->set ? 16 : C->id != carryFrom ? 17 : 0;
  int skip = C->id == carryFrom ? carryPressed : 0;
  if (C->set && C->nrest <= skip && theCarryNext.set) {
    // (the line's own swaps all pressed: the break it lived by is the line in progress now, popping or not as the board is now)
    *C = theCarryNext; memset(&theCarryNext, 0, sizeof theCarryNext); carriedSunk = -1; C->popping = popLeft(decQ.b) > 0; skip = 0;
  }
  if (C->set && C->nrest <= skip) carryNone = 18;
  if (!C->set || C->nrest <= skip) return 0;
  int dr = NOT_ASKED;
  // (from the row not yet risen: the board a waited-for break was found on may have risen past this one)
  for (int r = 0; r < decQ.b->nrows && dr == NOT_ASKED; r++) if (decQ.b->p[r][C->anchorCol].f[ID] == C->anchorId) dr = r - C->anchorRow;
  if (dr == NOT_ASKED) { carryDrop = 1; return 0; }
  int32_t rest[MAXLINE], nrest = C->nrest - skip;
  // (each swap named on the board as it is now: the rows risen since; the judge presses it where its panels have risen to by the frame
  // it is pressed -- rooted -- and the line is handed on named so, the rows the stack rose while it was pressed put back)
  for (int i = 0; i < nrest; i++) rest[i] = (CR(C->rest[skip + i]) + dr) * 8 + CC(C->rest[skip + i]);
  // (judged as every line is -- one replayer, what the line makes counted one way -- each step settled when the line was begun so; a
  // settled line waits while the board still moves)
  // (a settled line's next step is pressed on the board settled from the step before, as it was judged: on a board still moving the
  // step is judged once it has settled -- waitTo -- not cut for a walk that cannot begin within a reaction; and a break the readiness
  // found, on the board once everything lands, is pressed on that board: on one still moving it waits as a settled line does)
  int moving = (C->settled || C->ready) && (hasActivePanels(decQ.b) || decQ.b->swappingCount > 0);
  JudgeOpts jo = { C->settled, decQ.tight, NOT_ASKED, 0, 0, -1, 0, 0, 0, moving ? 1 : 0, 0, 1 };
  // (each swap's walk begun no sooner than it was judged to begin: the line in progress played in the frames it was judged in)
  int32_t notBefore[MAXLINE]; for (int i = 0; i < nrest; i++) notBefore[i] = C->at[skip + i];
  jo.notBefore = notBefore; jo.nNotBefore = nrest;
  jo.winWait = C->broke > 0;   // (a break begun waits for the window: judge.c)
  carryNBn = imin(nrest, 64); for (int i = 0; i < carryNBn; i++) carryNB[i] = notBefore[i];   // (and the line's ranking judged so: rank.c judgeCand)
  Judged j;
  judge(&decQ, rest, nrest, &jo, &j);
  // (THE WINDOW SHORT AT A LATER SWAP: the judge pressed the line's next swaps and cut it where a walk is over what the input window
  // holds then (judge.c cutWhy 1) -- the swaps before the cut are still the line's, pressable as they were judged, and what they make
  // was begun for with the swaps already on the board. The line in progress is those swaps, judged as its own line and ranked on what
  // they make; the swaps past the cut are let go, as the frame loop drops them (front.c follow))
  if (!j.dead && j.cutWhy == 1 && j.cut > 0 && j.cut < nrest) {
    carryShort = nrest - j.cut; nrest = j.cut; jo.nNotBefore = nrest; carryNBn = imin(nrest, 64);
    judge(&decQ, rest, nrest, &jo, &j);
  }
  for (int i = 0; i < j.nats && i < nrest; i++) rest[i] = (CR(rest[i]) + j.risen[i]) * 8 + CC(rest[i]);
  carryJ = j;
  carryDropN = nrest; for (int i = 0; i < nrest; i++) carryDropRest[i] = rest[i];
  // (a step no longer legal: the judge pressed fewer than the line has. A line the board is lost on is offered all the same -- judged
  // lost, as any line is, and ranked by its loss: where every line is lost, the line in progress may be lost latest)
  if (!j.dead && j.nats < nrest) { carryDrop = 2; carryLate = j.late || clockOut(); carryDropDead = -1; carryDropCut = j.cut; carryDropWhy = j.cutWhy; carryDropNats = j.nats; return 0; }
  *wait = moving;
  // (the chain as the game counts it -- one already falling is the line's, begun by its first swap -- as the list's check counts it)
  // (A REST THE BOARD IS LOST DURING is read on what the line was played as making, as the rank reads a line the judge could not play
  // out on the search's word (rank.c judgeCand). The judge and the rank then say of this line what they said when it was begun; the
  // next judging ranks it by its loss, as any line lost)
  // (but not for a line that has waited out (carryWaitsOut): nothing of it is pressed while it waits, and read on the search's word it
  // would be the break first every decision it waits. It is read on the judge's count, which counts the step the board is lost in up
  // to the frame before (judge.c): a break made and the board lost in the settle after it is a break made, and the line is carried on)
  Made x = j.dead && !(moving && carryWaitsOut()) ? C->made : (Made){ j.made.combo, imax(j.made.chain, j.chainAll), j.made.broke, 0 };
  int32_t done = j.done, fire = j.fire, nats = j.nats, ats[MAXLINE];
  for (int i = 0; i < nats; i++) ats[i] = j.ats[i];
  // (a line begun for a break whose swaps pressed so far made it -- the slab popping now, none when it was begun -- is carried on for
  // what the rest of it makes: the rest is what the line was judged to live by)
  if (C->broke && !(x.broke > 0) && !(!C->popping && popLeft(decQ.b) > 0)) { carryDrop = 3; return 0; }
  // (the rest no longer meeting the entry it was begun for -- the swaps pressed so far made part of it -- it is carried on for no entry,
  // ranked as the line in progress is: rank.c 1a)
  int aimGone = C->hasAim && !meets(&C->aim, x);
  if (aimGone) carryDrop = 5;
  int aim = -1;
  if (C->hasAim && !aimGone) for (int i = 0; i < R->guides.n && aim < 0; i++) if (!memcmp(&R->guides.aim[i], &C->aim, sizeof(Aim))) aim = i;
  if (!candOf(k, *wait ? PLAY_CARRYWAIT : PLAY_CARRY, rest, nrest, aim, 0)) return 0;
  k->settled = C->settled;
  k->x.combo = x.combo; k->x.chain = x.chain; k->x.broke = x.broke; k->x.cells = x.cells; k->xDone = done; k->xFire = fire;
  k->xNats = nats; for (int i = 0; i < nats; i++) k->xAts[i] = ats[i];
  return 1;
}
// WHY THE MOVE PLAYED (the log's aim=, every decision that presses a swap -- the owner: no move without its reason): what the line makes,
// or for a move that shapes the stack the shape it leaves, or what the board it leaves fires one swap on, or the combo a set-up sorts;
// none of them is a move made for nothing -- a bug, logged as such
static int32_t bumpOf(const Board *b) {
  int32_t hg[W + 2] = { 0 }, bump = 0;
  for (int c = 1; c <= W; c++) for (int r = 1; r < b->nrows; r++) if (b->p[r][c].f[COLOR] > 0 || b->p[r][c].f[ISGARBAGE]) hg[c] = r;
  for (int c = 1; c < W; c++) bump += iabs(hg[c] - hg[c + 1]);
  return bump;
}
static Ctx *whyCtx;
#define WHY_TRIES 6   // (the lines after the one chosen asked for a reason, where it has none)
static int32_t noReason, nrKey, nrLost[2];
static Why whyPlayed;   // (the reason of the move played, measured when it was chosen: the log's aim=)   // (the log's: 1 the line chosen had no reason and the next with one was played, 2 none had one and the hold was)
static Why moveWhy(const Judge *L) {
  Why w = { WHY_NONE, 0, 0 };
  if (!L || L->hold || L->k.nseq < 1) return w;
  int play = L->k.play;
  // (what it makes, the line itself)
  int shapes = play == PLAY_LEVEL || play == PLAY_ZIP || play == PLAY_SURVIVE || play == PLAY_READY || play == PLAY_TOWARD;
  if (!shapes || L->apBroke > 0) {
    // (a line that breaks garbage with a chain of two is for the break: the 2x is what the dig makes, never its goal)
    if (L->apBroke > 0 && L->apChain <= 2) { w.kind = WHY_BREAK; w.a = L->apBroke; return w; }
    if (L->apChain >= 2) { w.kind = WHY_CHAIN; w.a = L->apChain; return w; }
    if (L->apBroke > 0) { w.kind = WHY_BREAK; w.a = L->apBroke; return w; }
    if (L->apCombo >= 3 && !shapes) { w.kind = WHY_COMBO; w.a = L->apCombo; return w; }
  }
  if (L->k.drop) { w.kind = WHY_DROP; return w; }
  // (the board it leaves: every swap played, settled -- after the decision, outside its clock)
  __atomic_store_n(&clockIgnore, 1, __ATOMIC_RELAXED);
  Ctx *x = whyCtx = ctxOf(whyCtx);
  int nd = rootOf(x, &decQ), n0 = nd;
  for (int q = 0; q < L->k.nseq && liveNode(x, nd); q++) { int o = step(x, nd, MK_SETTLE, CR(L->k.seq[q]), CC(L->k.seq[q]), 0); if (!liveNode(x, o)) break; nd = o; }
  const Board *eb = liveNode(x, nd) ? ensureBoard(x, nd) : 0;
  if (eb && play == PLAY_LEVEL) { w.kind = WHY_FLAT; w.a = bumpOf(decQ.b); w.b = bumpOf(eb); }
  else if (eb && play == PLAY_ZIP) { w.kind = WHY_ZIP; w.a = spreadOf(decQ.b); w.b = spreadOf(eb); }
  else if (play == PLAY_READY || play == PLAY_TOWARD) { w.kind = WHY_READY; w.a = L->k.readyGain > 0 ? L->k.readyGain : 1; }
  else if (play == PLAY_SURVIVE) {
    const Judge *H = 0; for (int i = 0; i < orderN && !H; i++) if (order[i]->hold) H = order[i];
    w.kind = WHY_LIVE; w.a = H && !H->o.lives && !L->o.lives ? (int32_t)(diesAt(L) - diesAt(H)) : 0;
    w.b = H && !H->o.lives && L->o.lives ? 1 : !H || H->o.lives || w.a <= 0 ? 2 : 0;   // (1 it lives where the hold does not, 2 it gains nothing on the hold: the log's)
    // (a survive line that gains nothing on the hold has no reason: its swaps are inputs for nothing -- r1335, 15 such lines played, 9
    // swaps that came to nothing, one of them a ten-row walk at 3195)
    if (H && w.b == 2) w.kind = WHY_NONE;
  }
  if (w.kind == WHY_NONE && eb && nd != n0) {
    // (what the board it leaves fires one swap on: the longest chain, else the biggest combo)
    static int32_t ms[MAXROWS * W];
    int m = swapsOfNode(x, nd, ms), bestX = 0, bestC = 0;
    for (int i = 0; i < m; i++) {
      int o = step(x, nd, MK_SETTLE, CR(ms[i]), CC(ms[i]), 0);
      Stats st; if (!liveNode(x, o) || !statsOf(x, o, &st)) continue;
      for (int c = 0; c < st.n && c < MAXCOMBOS; c++) { if (st.chainAt[c] > bestX) bestX = st.chainAt[c]; if (st.size[c] > bestC) bestC = st.size[c]; }
    }
    // (in finish them a chain set up, or a lone three, is no reason -- the owner: combos, not chains, and a 3 the last resort; set 86
    // combo_storm 1, 1644-2250: set-ups toward a 2x and a three pressed for nothing)
    int fin = finishAsked();
    if (bestX >= 2 && !fin) { w.kind = WHY_CHAIN; w.a = bestX; }
    else if (L->k.aimC > 0 && L->k.aimLeft > 1) { w.kind = WHY_TWIN; w.a = L->k.aimC; w.b = L->k.aimLeft; }
    else if (bestC >= (fin ? 4 : 3)) { w.kind = WHY_COMBO; w.a = bestC; }
  }
  if (w.kind == WHY_NONE && L->k.aimC > 0) { w.kind = WHY_TWIN; w.a = L->k.aimC; w.b = L->k.aimLeft; }
  ns_reset(x);
  __atomic_store_n(&clockIgnore, 0, __ATOMIC_RELAXED);
  // (and the board's life: a line that lives where the hold does not, or is lost later than the hold, is pressed for the frames it buys)
  if (w.kind == WHY_NONE && !L->o.dead) {
    const Judge *H = 0; for (int i = 0; i < orderN && !H; i++) if (order[i]->hold) H = order[i];
    if (H && !H->o.lives && (L->o.lives || diesAt(L) > diesAt(H))) { w.kind = WHY_LIVE; w.a = L->o.lives ? 0 : (int32_t)(diesAt(L) - diesAt(H)); w.b = L->o.lives ? 1 : 0; }
  }
  return w;
}
