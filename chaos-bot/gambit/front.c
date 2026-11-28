// GAMBIT'S FRAME LOOP: one match, a frame at a time, in the game's own process (native.c). Each frame the host hands it the board as the
// player sees it and the garbage the senders' telegraphs show, and it returns the keys pressed. Decisions are asked ahead, of the board
// predicted for the frame they are due, and answered on Gambit's thread (native.c); the frame never waits on one.
//
// THE BOARD PLAYED IS THE BOARD DECIDED ON. The board after each frame is predicted from the board and the keys pressed; the next
// frame's board is compared with it, and anything the prediction could not know (a row's or a break's colours) aside, a difference
// drops every plan and question made before it. So does garbage shown that the plan was not made knowing, and a broken slab's
// colours shown.

#define STAGING (45 + 45 + 1)   // a sender stages garbage this long, then it lands LAND frames later
#define LAND 60
#define PLANN 4096         // frames of plan kept, by clock
#define ASK_IDLE 30        // frames with no keys planned past which the next question is asked anyway
#define MAXKEYS 2048
#define MAXARRIVALS 1024
#define FTHINK 8           // the answers' times kept, for how soon the next comes

typedef struct { int32_t at, capped; Incoming g; } Arrival;   // at: the stopWatch it is received on; capped: held back (search.h CAPPED_AT)
typedef struct { int32_t bits, holdLeft, holdStarted, swap, save, asked, play, lid, idx; } Planned;   // save: a key of a line the survival search found the board needed; asked: the frame the question it came of was posted on; play: the kind of line it is a key of, plus one (0: none); lid, idx: the answer whose line it is, plus one, and the swap's place in it
typedef struct { int32_t n, ins[MAXKEYS], hl[MAXKEYS], hs[MAXKEYS], held; } Keys;

// what the worker is asked, and what it answers (native.c carries them across)
typedef struct {
  int32_t id, epoch, at, lead, allowance, topped, lineFrom, linePressed, holdLeft, holdStarted, narr;
  int32_t moveOff;                           // the swap the answer `lineFrom` played was never pressed and no key of it is planned: its plan was dropped
  int32_t oppHas, oppOut, oppTop, oppStop;   // the opponent's stop: the frames it is held up by at the question's frame
  int32_t refA, refB, refUntil;              // a pair the press guard refused (a wasted three), its panels' ids, kept out until a frame
  int32_t swapA, swapB;                      // the pair the last swap pressed swapped, its panels' ids (0: none): the swap back the judge refuses
  int32_t nages, ages[512], window;          // the input window at the question's frame: how long before it each action inside went down
  int32_t noRaise;                           // a raise not offered: the countdown's, asked before any garbage is shown (frontCountdown)
  double ms, posted;
  Arrival arr[MAXARRIVALS];
  Board *b;
} FQuestion;
typedef struct {
  int32_t id, epoch, at, kind, move, raiseNow, raiseAfter, nhand, hand[MAXLINE], holdLives, brk, urgent, error;
  int32_t lineKept;            // the line handed on breaks garbage, lives, or outlives the hold by a break's time (answer.c): carried across a switch of the mode
  int32_t tap;                 // the board near its end: the line's walks tapped while the allowance has some to spare (core/nodes.h pressTap)
  int32_t raiseWait;           // a raise held from this many frames after `at`, the first the stack takes one (0: from `at`)
  int32_t handAt[MAXLINE];     // the frame each swap handed on was judged pressed from (0: as soon as the one before is done)
  int32_t empty;               // a hold the clock left no time to judge anything for
  int32_t wastes;              // the line makes a three for nothing, kept by the order as the board's save (answer.c)
  int32_t play;                // the kind of line played (facts.c PLAY_NAME; -2 the raise)
  int32_t ended;               // what ended the line in progress before it (front.c lineEnds; answer.c)
  int32_t nalt, alt[MAXLINE];  // the move in hand: the best line that lives and is no hold, its swaps (0: none)
  int32_t aim;                 // a hold's: where the best line that is no hold begins (answer.c), the cursor walked there (0: none)
  double ms, idleMs, closeMs;
} FAnswer;
static void postQuestion(FQuestion *q);   // native.c
static int takeAnswer(FAnswer *a);        // native.c: 1 when one was waiting
static int answerWaiting(int32_t id);     // native.c
static void abortTo(int32_t id);          // native.c: every question up to id is no longer wanted
static void flog(const char *s);          // native.c: a line into the run's log
static void dumpBoard(const char *tag, int32_t at, const Board *b, const Arr *arr, int narr, int32_t allow);   // native.c: a board into the log
// (the boards the last swaps were pressed on, a ring: the one a wasted three came of is logged with it)
#define SWAPRING 4
static Board *swapRing[SWAPRING]; static int32_t swapRingAt[SWAPRING], swapRingN;

typedef struct {
  int32_t frames, decisions, played, late, diverged, refused, guarded, unasked, idle, followed, noLine, unforeseen, reasked, revealed,
          raiseCut, actions, maxWindow, overInput, heldWalks, paced, swaps, starved, inHand, aimed;
  int32_t winChecked, winShort, winShortWorst;   // (THE WINDOW HELD: a line's later swaps checked against the window as the judge read it, those it held too few actions for, and by how many at most)
  int32_t behind, behindWorst;   // (a line's swaps whose keys began later than the frame the judge pressed them from, and by how much at most)
  int32_t revealCleared;         // (plans dropped for a panel unseen when they were made coming to a clear: front.c revealClears)
  int32_t early;                 // (frames the queue held garbage the telegraph had due a frame or few later: front.c arrivedEarly)
  int32_t queueOnly;             // (divergences in the queue alone, the plan kept: front.c frontFrame)
  // (CHAOS, THE FORECAST CHECKED: each frame garbage comes into the stack's queue, the frames the telegraph had garbage inside the
  // look-ahead before it -- under LAND, a surprise; and the fewest frames of notice any arrival had. native.c noticeCheck)
  int32_t arrivals, surprises, noticeMin;
  int32_t combo[64], chain[32];
  // each chain link past the list's two, by its cause: panels out of garbage (colours not shown when it was decided), a swap pressed
  // since the link before it, or neither (the stack alone)
  int32_t linkBy[3][32];
  // EVERY MOVE ON THE WAY: each swap pressed by what it came to (moveOn) -- a clear before the next swap, a set-up (a clear after it),
  // a break, or nothing -- and the cells the cursor walked
  int32_t moveClear, moveSetup, moveBreak, moveNone, cursorCells;
  int32_t noneBy[NPLAYS];   // (the swaps that came to nothing, by the kind of line that pressed them)
  int32_t noneDropped, noneOn, noneLast;
  int32_t noneWhy[1024];   // (and dropped, by what ended the line: lineEnds)
  int32_t actsBy[NPLAYS + 1], actsLost[1024];   // (THE WINDOW SPENT: the actions pressed, by the kind of line -- 0 none -- and those of a line put down or dropped before its end, by what ended it)   // (and by what became of their line: dropped before its later swaps, those pressed, its last swap)
  int32_t together;   // (several ideas at once: a clear begun, no link of a chain, while another is still clearing)
  int32_t wasted, wastedAlone, wasteRefused, saved, guardLet, refusedSpoil, through;   // (a wasted three: a clear of three that broke no garbage, was no link of a chain and whose line broke none after it -- a swap's, the stack's own; saved: one of a line the survival search found the board needed not to die; through: a three whose line broke garbage after it)
} FStats;
enum { LINK_GARBAGE, LINK_SWAP, LINK_ALONE };
// (a swap pressed, followed: the ids of the panels it moved -- the two swapped, and those above them that fall in the frames after
// it -- and how many swaps were pressed since)
#define LOGGED_MAX 4000   // (the frame loop's notes a game -- a line dropped, an answer refused, guarded, late, a line behind: every one, for the reader)
#define MOVE_OPEN 64
#define MOVE_IDS 32
#define MOVE_FOR 600
#define LOGGED_KEYS 400   // (the swaps keyed logged at most, a game: GAMBITK)
#define FOLLOW_FOR 360   // (the frames a swap's three waits for a break by a later swap of its line: past them, unbroken, it was wasted)
#define MOVE_FALL 60
typedef struct { int32_t at, n, ids[MOVE_IDS], moved[MOVE_IDS], swapsAfter, save, guard, play, lid, idx, row, col, acts, pa, pb; } MoveOpen;   // pa, pb: the ids of the two cells swapped (0: none there)   // row, col: where it was pressed; acts: the actions pressed since the swap before, its own included   // save: pressed as a key of a save (Planned.save); guard: what the press guard saw (0 no three, 2 a three let through as the board's save)
// (the lines whose swaps are followed: each answer's swaps in all and how many of them were pressed, by the answer's id)
#define LINE_RECS 64
typedef struct { int32_t id, total, pressed, why, next, acts, inh, q, dropped; } LineRec;   // dropped: its swap's keys cleared by a board not foreseen (dropFrom, dropAll) before it was pressed   // q: the frame of the decision that played the line   // inh: the actions it took over from the line it carried on   // why: what ended the line (END_*, or the order's key that put it down); next: the answer's line it was carried on as (END_ON)
static LineRec lineRecs[LINE_RECS];
static LineRec *lineRec(int32_t lid) { LineRec *r = lid > 0 ? &lineRecs[(lid - 1) % LINE_RECS] : 0; return r && r->id == lid ? r : 0; }
// WHAT ENDED A LINE, for the swaps of it that came to nothing (noneWhy): the answer's word (answer.c ended: carried on, held, not
// carried, dropped by the carry -- or the line number of the order's key that put it down, rank.c cmpKey), or the frame loop's own drop
enum { END_ON = 1, END_HELD, END_NOTCARRIED, END_ANCHOR, END_STEP, END_NOBREAK, END_RAISE, END_MODE = 10, END_NOBOARD, END_NOKEYS, END_NOFIT, END_OVERWALK, END_DROPPED, NEND = 1024 };   // (16-21: answer.c ended, decide.c carryNone)
static void lineEnds(int32_t why);

static struct {
  int32_t now, epoch, nextAt, lastSwapEnd, haveSwapEnd, jitterFor, jitterGap, raiseCutUntil;
  int32_t holdLeft, holdStarted, overLogged, loggedAskNow, loggedRefused, loggedKeys, nalt, alt[MAXLINE];
  Planned plan[PLANN]; int32_t planAt[PLANN];
  Board *truth, *expect, *pr, *scratch;
  int32_t haveExpect;
  Arrival arr[MAXARRIVALS]; int32_t narr;            // garbage on its way, this frame
  Arrival knew[MAXARRIVALS]; int32_t nknew;          // the garbage on its way the plan was decided knowing
  Arrival nextPend[MAXARRIVALS]; int32_t nnextPend;  // still to land after the predicted next frame
  Arrival prPend[MAXARRIVALS]; int32_t nprPend;
  // the question out: its id and frame, the board it was asked of, its raise and garbage, the garbage known when it was asked
  int32_t pending, pId, pEpoch, pAt, pPaced, pHoldLeft, pHoldStarted, pNarr, pNknew;
  int32_t countdownAsked;   // (the opening asked during the countdown: frontCountdown)
  int32_t askNoRaise;       // (the question asked next offers no raise: ask)
  Board *cdBoard;           // (and the board it was asked of)
  Board *pBoard; Arrival pArr[MAXARRIVALS], pKnew[MAXARRIVALS];
  int32_t nextId;
  // the line after the move, pressed as it was decided: its swaps, each from the frame it was judged pressed from (lineAt, 0: as soon as
  // the one before is done)
  int32_t lineN, line[MAXLINE], lineAt[MAXLINE], lineOfId, lineOfPressed, haveLineOf, lineOfSwap, lineOfMoved;   // (lineOfSwap: the answer played a swap; lineOfMoved: that swap was pressed)
  int32_t actsAtSwap;   // (the action count at the last swap pressed: moveBegin)
  int32_t lineMode, altMode, lineTap, lineKept;   // the mode each was handed under (answer.c modeAt): a line is never pressed into another mode's game
  int32_t lastHold, lastBrk, lastUrgent, havePace;
  int32_t lineWastes;   // the line in hand was played for a three, as the board's save
  int32_t linePlay;     // and the kind of line it is, plus one
  double thinking[FTHINK]; int32_t nthinking;
  double msPerFrame, wall;
  // the input budget: its limit and window, the frames the keys still inside it were pressed, the keys held last frame
  int32_t limit, window, pressFrames[512], npress, prevBits;
  int32_t oppHas, oppOut, oppTop, oppStop;
  int32_t toppedNow;
  // the attacks made, read off the board as it is shown
  int32_t chainMax, pendCombo[16], npendCombo, pendThree, pendThreeAlone, pendSave, matchedIds[MAXROWS * W], nmatched, swapSince;
  // the swaps pressed still followed, the garbage cells matched last frame, and the cursor where it was and whether it was walked
  MoveOpen moves[MOVE_OPEN]; int32_t nmoves, gMatched, curRowWas, curColWas, curWalked;
  int32_t unseenIds[MAXROWS * W], nunseen;   // (the panels whose colours the plan in force was made without: revealClears)
  int32_t reaction, ahead, gap, jitter;
  uint32_t rnd;
  FStats st;
  char pendLog[200];   // (the wasted three's log line, written once it is counted)
  struct { int32_t lid, until, open; char log[200]; } w3[16]; int32_t nw3, matchLid;   // (a swap's three waiting for its line's break: FOLLOW_FOR)
  int32_t loggedDiffer, matchAt, matchAfter, matchSave, matchGuard, loggedWasted, pendSwapAt, refA, refB, refUntil, guardSpoil, loggedRefusedBoards, swapA, swapB, prSwapA, prSwapB;
  int32_t pPosted, lineAsked, altAsked, lastReveal;   // (the frames questions were posted on, and colours were last shown on)   // (the followed swap a clear came of: pressed at, swaps since, a save's -- for the wasted three's count and log)
} F;

static double fNow(void) { return clock_ms(); }

// ---------------------------------------------------------------- the garbage on its way
// What the senders' telegraphs show, as the garbage this board will receive and the stopWatch it arrives on (garbage due at T is
// received once the frame before T has run): a source's transit by the stopWatch it lands on, its staged shipped from the end of the
// list, none before the one ahead of it; a chain still going ships once it ends, at the soonest. The host's words (gn_tele):
// nsrc, then per source its stopWatch, whether it is held back (an attack engine's queue: GarbageDelivery delivers it only while fewer
// than CAPPED_AT are queued, a transit a frame, the late ones too), ntransit, each transit's at and npieces and pieces -- every transit
// not yet delivered, the finished ones held back as well -- nstaged and pieces; a piece is width, height, isChain, isMetal,
// frameEarned, finalized (NUL, 0, 1).
static int32_t tele[1 << 15];
// (THE RECEIVER'S OWN TIME, as upstream Panel Attack delivers it -- Match:pushGarbageTo before the frame runs, after the frame's keys
// are asked: a transit due on this stack's stopWatch now is still on its way when the question is asked, and lands before the frame
// runs. The host says so (lua/GambitNative.lua, no GarbageDelivery); elsewhere a transit due now has landed already.)
static int32_t receiverTimed;
EXPORT(gn_receiver_timed) void gn_receiver_timed(int32_t on) { receiverTimed = !!on; }
static void arrivalsOf(const Board *b) {
  const int32_t *w = tele;
  int32_t mine = b->stopWatch, nsrc = *w++;
  F.narr = 0;
  for (int s = 0; s < nsrc; s++) {
    int32_t sw = *w++, capped = *w++, offset = mine - sw, floor = mine + (receiverTimed ? 0 : 1), nt = *w++, free = floor;
    for (int t = 0; t < nt; t++) {
      int32_t at = *w++ + offset, np = *w++;
      // (a held-back source delivers a transit a frame, in order: its transits are given frames one apart, none before the next free)
      if (capped) { if (at < free) at = free; free = at + 1; }
      else if (at < floor) at = floor;
      for (int k = 0; k < np; k++, w += 6)
        if (F.narr < MAXARRIVALS) { Arrival *a = &F.arr[F.narr++]; a->at = at; a->capped = capped; a->g = (Incoming){ w[0], w[1], w[2], w[3], w[4], w[5] }; }
    }
    int32_t ns = *w++, ship = sw, lastRaw = NUL, lastAt = NUL;
    const int32_t *g0 = w;
    w += 6 * ns;
    for (int i = ns - 1; i >= 0; i--) {
      const int32_t *g = g0 + 6 * i;
      // (CHAOS: when a chain the sender is still building ends. Run 10 had it end next frame, as vanilla: chaos training's chains run
      // on for seconds (links 67 or 335 frames apart) and the sender's staging (GarbageQueue:processStagedGarbageForClock) holds every
      // piece behind the chain until it is finalized, so the bot braced for 600 frames for blocks that had not left. Run 11 had it end a
      // look-ahead from now (HORIZON): the burst was never inside the look-ahead -- run 14 combo_storm seed 2, the board clear, the
      // forecast 260 frames out for 250 frames, then 17 pieces at once, the loss. Now: one link gap after its last link, the gap its last
      // two links were made at (lua/GambitNative.lua writes it as g[5] = 2 + frames from its first link, g[4]); with one link, the
      // soonest it can ship (its first link + STAGING). Once finalized a chain ships as soon as its first link + STAGING has passed, so
      // what is behind it lands LAND frames after it ends.)
      int32_t chainEnd = g[2] && g[5] >= 2 && g[4] != NUL ? g[4] + g[5] - 2 : 0;
      ship = imax(ship, imax((g[4] == NUL ? sw : g[4]) + STAGING, chainEnd));
      // (pieces shipped together are one transit, landing together)
      int32_t raw = ship + LAND + offset, at = imax(raw, capped ? free : floor);
      if (capped) { if (raw == lastRaw) at = lastAt; else free = at + 1; lastRaw = raw; lastAt = at; }
      if (F.narr < MAXARRIVALS) { Arrival *a = &F.arr[F.narr++]; a->at = at; a->capped = capped; a->g = (Incoming){ g[0], g[1], g[2], g[3], g[4], g[5] >= 2 ? 0 : g[5] }; }
    }
  }
  // (sorted by when they arrive, the order they came in kept between equals)
  for (int i = 1; i < F.narr; i++) { Arrival x = F.arr[i]; int j = i - 1; while (j >= 0 && F.arr[j].at > x.at) { F.arr[j + 1] = F.arr[j]; j--; } F.arr[j + 1] = x; }
}
// A COLOUR SHOWN THAT CLEARS (the plan made without it): the panels whose colours the question's board did not show -- a broken slab's,
// a row not yet risen -- kept when its answer's keys are planned; one of them coming to a clear is a board no line of that plan was
// judged on (an unseen colour matches nothing in the engine), and the frame loop's check, a frame at a time, never sees it differ
static int unseenColour(int32_t c);
static void unseenOf(const Board *b) {
  F.nunseen = 0;
  for (int r = 0; r < b->nrows; r++) for (int c = 1; c <= W; c++) {
    const int32_t *f = b->p[r][c].f;
    if (!f[ISGARBAGE] && unseenColour(f[COLOR]) && F.nunseen < MAXROWS * W) F.unseenIds[F.nunseen++] = f[ID];
  }
}
static int revealClears(const Board *t) {
  for (int r = 1; r < t->nrows; r++) for (int c = 1; c <= W; c++) {
    const int32_t *f = t->p[r][c].f;
    if (f[ISGARBAGE] || f[STATE] != MATCHED) continue;
    for (int i = 0; i < F.nunseen; i++) if (F.unseenIds[i] == f[ID]) return 1;
  }
  return 0;
}
// The garbage of `now` a decision made knowing `knew` did not count on: each piece of `knew` accounts for one no bigger, due no sooner;
// the stopWatch the soonest of it is due (0x7fffffff: none), and whether any of it is due by `by`.
static int32_t unforeseenFirst(const Arrival *knew, int nk, const Arrival *now, int nn) {
  static uint8_t used[MAXARRIVALS];
  memset(used, 0, (unsigned long)nk);
  int32_t first = 0x7fffffff;
  for (int i = 0; i < nn; i++) {
    const Arrival *a = &now[i];
    int found = 0;
    for (int k = 0; k < nk && !found; k++) {
      const Arrival *b = &knew[k];
      if (!used[k] && b->at <= a->at && b->g.width == a->g.width && b->g.height >= a->g.height && !!b->g.isChain == !!a->g.isChain &&
          !!b->g.isMetal == !!a->g.isMetal) { used[k] = 1; found = 1; }
    }
    if (!found && a->at < first) first = a->at;
  }
  return first;
}
static int unforeseenBy(const Arrival *knew, int nk, const Arrival *now, int nn, int32_t by) { return unforeseenFirst(knew, nk, now, nn) <= by; }
// Garbage due by the frame just reached, received as the server receives it; what lands is taken out of `pend`.
// (garbage held back lands as the search lands it, search.h runFrame: only while fewer than CAPPED_AT are queued, the earliest due a frame)
// THE QUEUE A BOARD HOLDS: fuller than MAXINC, the board keeps the pieces that drop soonest, as the host loads it -- the piece to drop
// last is let go; a board asked of the search keeps MAXINC - MAXARR of them, room for the MAXARR the search lands (keepQueue).
static void receiveKept(Board *b, const Arrival *a) {
  Incoming g = { a->g.width, a->g.height, a->g.isChain ? 1 : 0, a->g.isMetal ? 1 : 0, a->g.frameEarned == NUL ? b->stopWatch : a->g.frameEarned, a->g.finalized };
  if (b->ninc >= MAXINC) {
    if (orderBefore(&g, &b->inc[0])) return;
    for (int i = 1; i < b->ninc; i++) b->inc[i - 1] = b->inc[i];
    b->ninc--;
  }
  nb_receive(b, g.width, g.height, g.isChain, g.isMetal, g.frameEarned, g.finalized);
}
static void keepQueue(Board *b, int keep) {
  if (b->ninc <= keep) return;
  int drop = b->ninc - keep;
  for (int i = drop; i < b->ninc; i++) b->inc[i - drop] = b->inc[i];
  b->ninc = keep;
}
static void landOn(Board *b, Arrival *pend, int32_t *n) {
  int k = 0, first = 0x7fffffff;
  for (int i = 0; i < *n; i++) if (pend[i].capped && pend[i].at <= b->stopWatch && pend[i].at < first) first = pend[i].at;
  int open = first != 0x7fffffff && b->ninc < CAPPED_AT;
  for (int i = 0; i < *n; i++) {
    Arrival *a = &pend[i];
    if (a->at > b->stopWatch || (a->capped && !(open && a->at == first))) { pend[k++] = *a; continue; }
    receiveKept(b, a);
  }
  *n = k;
}
// The same, as the search takes it: frames from this board, the 64 soonest.
static int arrivalsFrom(const Board *b, const Arrival *arr, int n, Arr *out) {
  int k = 0;
  for (int i = 0; i < n && k < MAXARR; i++) {
    const Arrival *a = &arr[i];
    if (a->at <= b->stopWatch) continue;
    out[k++] = (Arr){ imax(1, a->at - b->stopWatch), a->g.width, a->g.height, a->g.isChain ? 1 : 0, (a->g.isMetal ? 1 : 0) | (a->capped ? 2 : 0) };
  }
  return k;
}

// ---------------------------------------------------------------- the board, as predicted
static int unseenColour(int32_t c) { return (c >= 30 && c <= 119) || (c >= 130 && c <= 219); }
static int sameInc(const Incoming *a, const Incoming *b) {
  return a->width == b->width && a->height == b->height && a->isChain == b->isChain && a->isMetal == b->isMetal && a->frameEarned == b->frameEarned &&
         a->finalized == b->finalized;
}
// The queue the game has is the one predicted less pieces it has not let in yet: a plan made with them is made with more garbage than there is.
static int heldBack(const Board *want, const Board *got) {
  if (got->ninc >= want->ninc) return 0;
  static uint8_t used[MAXINC];
  memset(used, 0, (unsigned long)want->ninc);
  for (int i = 0; i < got->ninc; i++) {
    int found = 0;
    for (int k = 0; k < want->ninc && !found; k++) if (!used[k] && sameInc(&got->inc[i], &want->inc[k])) { used[k] = 1; found = 1; }
    if (!found) return 0;
  }
  return 1;
}
// THE QUEUE AHEAD OF THE TELEGRAPH (loose sync: the server delivers a wired source's garbage a frame or three before its copy here
// says it is due): the queue the game has is the one predicted and, after it, pieces the telegraph shows on their way and due within
// EARLY_MAX frames -- known garbage come early, not garbage unforeseen; the plan made knowing it stands (counted: F.st.early)
#define EARLY_MAX 4
static int arrivedEarly(const Board *want, const Board *got) {
  if (got->ninc <= want->ninc) return 0;
  for (int i = 0; i < want->ninc; i++) if (!sameInc(&want->inc[i], &got->inc[i])) return 0;
  static uint8_t used[MAXARRIVALS];
  memset(used, 0, sizeof used);
  for (int i = want->ninc; i < got->ninc; i++) {
    int found = 0;
    for (int k = 0; k < F.narr && !found; k++)
      if (!used[k] && F.arr[k].at - got->stopWatch <= EARLY_MAX && sameInc(&got->inc[i], &F.arr[k].g)) { used[k] = 1; found = 1; }
    if (!found) return 0;
  }
  return 1;
}
static const int PANEL_FIELDS[] = { COLOR, STATE, TIMER, ISGARBAGE, CHAINING, METAL, GARBAGEID, XOFF, YOFF, GWIDTH, GHEIGHT, COMBOINDEX, COMBOSIZE,
                                    MATCHANYWAY, PROPCHAIN, STATECHANGED, DONTSWAP, QUEUEDHOVER, SHAKETIME, FELL, POPTIME, POPINDEX, INITIALTIME };
// Where two boards first disagree (0: they agree), into `why`.
static int differQ(const Board *w, const Board *g, char *why, int cap, int queue);
static int differ(const Board *w, const Board *g, char *why, int cap) { return differQ(w, g, why, cap, 1); }
static int differQ(const Board *w, const Board *g, char *why, int cap, int queue) {
#define DIFF1(f) if (w->f != g->f) { snprintf(why, (unsigned long)cap, "stack." #f " %d vs %d", (int)w->f, (int)g->f); return 1; }
  DIFF1(clock) DIFF1(speed) DIFF1(displacement) DIFF1(riseLock) DIFF1(hasRisen) DIFF1(manualRaise) DIFF1(manualRaiseYet)
  DIFF1(preventManualRaise) DIFF1(stopTime) DIFF1(preStopTime) DIFF1(shakeTime) DIFF1(peakShakeTime) DIFF1(health) DIFF1(chainCounter)
  DIFF1(nActive) DIFF1(nPrevActive) DIFF1(curRow) DIFF1(curCol) DIFF1(topCurRow) DIFF1(queuedSwapRow) DIFF1(queuedSwapCol) DIFF1(curTimer)
  DIFF1(cursorDirection) DIFF1(metalPanelsQueued) DIFF1(garbageCreatedCount) DIFF1(highestGarbageIdMatched) DIFF1(gameOverClock)
  DIFF1(panelsCleared) DIFF1(swapCount)
#undef DIFF1
  if (w->riseTimer != g->riseTimer) { snprintf(why, (unsigned long)cap, "stack.riseTimer"); return 1; }
  int sameQ = w->ninc == g->ninc;
  for (int i = 0; sameQ && i < w->ninc; i++) sameQ = sameInc(&w->inc[i], &g->inc[i]);
  if (queue && !sameQ && !heldBack(w, g)) {
    if (!arrivedEarly(w, g)) { snprintf(why, (unsigned long)cap, "incoming %d vs %d", w->ninc, g->ninc); return 1; }
    F.st.early++;
  }
  int sameS = w->nstall == g->nstall;
  for (int i = 0; sameS && i < w->nstall; i++)
    sameS = w->stall[i].leftId == g->stall[i].leftId && w->stall[i].rightId == g->stall[i].rightId && w->stall[i].row == g->stall[i].row &&
            w->stall[i].col == g->stall[i].col && w->stall[i].clock == g->stall[i].clock;
  if (!sameS) { snprintf(why, (unsigned long)cap, "swap-stall log"); return 1; }
  if (w->nrows != g->nrows) { snprintf(why, (unsigned long)cap, "rows %d vs %d", w->nrows, g->nrows); return 1; }
  for (int r = 0; r < w->nrows; r++) for (int c = 1; c <= W; c++)
    for (unsigned k = 0; k < sizeof PANEL_FIELDS / sizeof PANEL_FIELDS[0]; k++) {
      int f = PANEL_FIELDS[k];
      if (f == COLOR && unseenColour(w->p[r][c].f[COLOR])) continue;
      if (w->p[r][c].f[f] != g->p[r][c].f[f]) { snprintf(why, (unsigned long)cap, "panel %d,%d field %d %d vs %d", r, c, f, w->p[r][c].f[f], g->p[r][c].f[f]); return 1; }
    }
  return 0;
}
// A broken slab's colours shown: a panel predicted with a garbage row's unseen colour that the game now shows.
static int revealed(const Board *w, const Board *g) {
  for (int r = 0; r < w->nrows && r < g->nrows; r++) for (int c = 1; c <= W; c++) {
    int32_t p = w->p[r][c].f[COLOR], q = g->p[r][c].f[COLOR];
    if (p >= 130 && p <= 219 && q >= 1 && q <= 10) return 1;
  }
  return 0;
}

// ---------------------------------------------------------------- the plan
static Planned *planOf(int32_t t) { int i = t & (PLANN - 1); return F.planAt[i] == t ? &F.plan[i] : 0; }
static void planSet(int32_t t, Planned p) { int i = t & (PLANN - 1); F.plan[i] = p; F.planAt[i] = t; }
static void planDrop(int32_t t) { int i = t & (PLANN - 1); if (F.planAt[i] == t) F.planAt[i] = NUL; }
// THE FRAMES TRACED (GAMBITF, the last FTRACE frames, written when the match ends beside the last boards): each frame's clock, the keys
// pressed, whether they were planned, the question out, the plan's end, the line in hand and its next swap's frame, and what was
// dropped in it (1 all, 2 from a frame, 4 cleared for an answer's keys) -- where a swap a decision played went, when one never comes down
#define FTRACE 512
typedef struct { int32_t clock, bits, planned, pend, nextAt, lineN, lineAt, drops; } FTrace;
static FTrace ftrace[FTRACE]; static int32_t ftraceN, ftraceDrops;
static void planClearFrom(int32_t t) { ftraceDrops |= 4; for (int i = 0; i < PLANN; i++) if (F.planAt[i] != NUL && F.planAt[i] >= t) F.planAt[i] = NUL; }
// Everything planned and asked is dropped: the board is not the one it was made for.
static void boardTookLine(void);
static void dropAll(void) {
  ftraceDrops |= 1; F.nunseen = 0; boardTookLine();
  if (F.pending) abortTo(F.pId);
  F.epoch++; planClearFrom(NUL + 1); F.nextAt = 0; F.lineN = 0; F.pending = 0;
}
// Everything planned from frame `t` and asked is dropped: the board is the one it was made for until then. (from the next frame or
// sooner: all of it)
static void dropFrom(int32_t t) {
  if (t <= F.now + 1) { dropAll(); return; }
  ftraceDrops |= 2;
  if (F.pending) abortTo(F.pId);
  F.epoch++; planClearFrom(t); boardTookLine(); if (F.nextAt > t) F.nextAt = t; F.lineN = 0; F.pending = 0;
  // (the garbage now on its way is what the keys kept are pressed knowing: told once, not again every frame till they end)
  memcpy(F.knew, F.arr, sizeof(Arrival) * (unsigned long)F.narr); F.nknew = F.narr;
}

// The board at `at`, from `b` now, pressing what is planned till then, and the garbage still to land after it (from).
static int32_t predictErr;   // (the engine's error flags the last prediction failed on, for the log)
// A RAISE HELD, a frame of it: the engine's own step (search.h raiseStep, its hold-through as Gambit sets it), so the frame loop
// presses what every search and the judge plan with
static void holdRaise(Board *b, int32_t *hl, int32_t *hs, int32_t *bits) {
  Bot h; memset(&h, 0, sizeof h);
  h.raiseFrames = *hl; h.raiseStarted = *hs;
  raiseStep(&h, b, bits);
  *hl = h.raiseFrames; *hs = h.raiseStarted;
}
static int predict(const Board *b, int32_t at, int32_t holdLeft, int32_t holdStarted, const Arrival *from, int32_t nfrom, Board *out,
                   int32_t *hL, int32_t *hS) {
  copyBoard(out, b);
  memcpy(F.prPend, from, sizeof(Arrival) * (unsigned long)nfrom); F.nprPend = nfrom;
  int32_t hl = holdLeft, hs = holdStarted;
  if (receiverTimed) landOn(out, F.prPend, &F.nprPend);   // (a transit due now lands before the frame runs)
  // (and the last swap planned before `at`, its pair's ids: the swap a question for `at` must not swap back -- pressed by then, not yet now)
  F.prSwapA = F.prSwapB = 0;
  while (out->clock < at && out->gameOverClock <= 0) {
    Planned *p = planOf(out->clock);
    int32_t bits = 0;
    if (p) { bits = p->bits; hl = p->holdLeft; hs = p->holdStarted; }
    else if (hl > 0) holdRaise(out, &hl, &hs, &bits);
    out->input = bits & ~IN_SWAP;
    if (bits & IN_SWAP) {
      out->pressSwap = 1;
      if (out->curCol >= 1 && out->curCol + 1 <= W && out->curRow >= 0 && out->curRow < out->nrows) {
        int32_t a = out->p[out->curRow][out->curCol].f[ID], z = out->p[out->curRow][out->curCol + 1].f[ID];
        if (a != NUL && z != NUL) { F.prSwapA = a; F.prSwapB = z; }
      }
    }
    run(out);
    if (out->err) { predictErr = out->err; return 0; }
    landOn(out, F.prPend, &F.nprPend);
  }
  *hL = hl; *hS = hs;
  return 1;
}

// ---------------------------------------------------------------- the keys
// One decision from a board as keys: the search's own walk, swap and wait (search.h advance), every frame it plays.
static Ctx *keyCtx;
static int keysOf(const Board *b, int32_t holdLeft, int32_t holdStarted, const Arrival *arr, int32_t narr, int kind, int mr, int mc, Keys *k) {
  keyCtx = ctxOf(keyCtx);
  Question q; memset(&q, 0, sizeof q);
  q.b = (Board *)b; q.holdLeft = holdLeft; q.holdStarted = holdStarted; q.narr = arrivalsFrom(b, arr, narr, q.arr);
  int root = rootOf(keyCtx, &q);
  if (root < 0) return 0;
  static LOCAL int32_t buf[3 * MAXKEYS];
  tape = buf; tapeN = 0; tapeCap = MAXKEYS;
  // (a swap whose pair still moves is pressed as the judge presses it: core/nodes.h pressWalk -- the frames before its walk waited, nothing pressed)
  int from = root, r = kind == MK_SWAP ? pressWalk(keyCtx, root, kind, mr, mc, advance, &from) : advance(keyCtx, root, kind, mr, mc, 0);
  // (a swap whose walk cannot begin within a reaction -- its pair held up by a pop, say -- is no keys: waited for in the plan, no question
  // is asked until its keys are done, and the board goes on moving undecided; refused, the next question is asked at once)
  int32_t waited = from >= 0 ? NODE(keyCtx, from)->t - NODE(keyCtx, root)->t : 0;
  tape = 0;
  ns_reset(keyCtx);
  if (r == STEP_NULL || r == STEP_ERR || from < 0 || waited > F.reaction) return 0;
  k->n = tapeN; k->held = 0;
  for (int i = 0; i < tapeN; i++) { k->ins[i] = buf[3 * i]; k->hl[i] = buf[3 * i + 1]; k->hs[i] = buf[3 * i + 2]; }
  return 1;
}
// A walk of n cells in one direction is played as n taps four frames apart; from four cells up (three where another walk follows) a held
// key gets the cursor to the same cell on the same frame or sooner, so it is held for as long as the cursor needs and released.
// (only a walk that ends at the wall: core/nodes.h legHeld; the cursor at (row, col) when the keys begin)
static void fHoldWalks(Keys *k, int row, int col) {
  Keys o = *k;
  int held = 0, i = 0, n0 = k->n;
  while (i < n0) {
    Leg L;
    if (!walkLeg(k->ins, n0, i, &L)) { i++; continue; }
    legMove(L.v, L.cells, &row, &col);
    if (L.cells >= MIN_LEG && L.last <= L.end && legHeld(L.v, row, col)) { for (int f = i; f <= L.end; f++) o.ins[f] = f <= L.last ? L.v : L.base; held++; }
    i = L.p + 1;
  }
  o.held = held;
  *k = o;
}
// The same walks held from two cells, when the allowance is tight; the frames the cursor is late by are put in before the next key,
// each carrying the raise held of the frame it follows.
static void fSlowWalks(Keys *k, int row, int col) {
  static Keys o;
  int held = 0, i = 0, n0 = k->n;
  o.n = 0;
#define PUSH(v, f) do { if (o.n < MAXKEYS) { o.ins[o.n] = (v); o.hl[o.n] = k->hl[f]; o.hs[o.n] = k->hs[f]; o.n++; } } while (0)
  while (i < n0) {
    Leg L;
    if (!walkLeg(k->ins, n0, i, &L)) { PUSH(k->ins[i], i); i++; continue; }
    int w, b, shape = legShape(L.v, L.cells, row, col, &w, &b);
    legMove(L.v, L.cells, &row, &col);
    // (slid to the wall and tapped back: core/nodes.h legSlide, the keys the judge's slowWalks presses)
    if (shape == 2) { static int32_t sl[MAXKEYS]; int ns = legSlide(L.v, L.base, w, b, L.end - i + 1, sl, MAXKEYS); for (int g = 0; g < ns; g++) PUSH(sl[g], imin(i + g, L.end)); held++; i = L.end + 1; continue; }
    if (shape != 1) { for (int f = i; f <= L.end; f++) PUSH(k->ins[f], f); i = L.end + 1; continue; }
    for (int g = i; g <= imax(L.last, L.end); g++) PUSH(g <= L.last ? L.v : L.base, imin(g, L.end));
    held++;
    i = L.end + 1;
  }
#undef PUSH
  o.held = held;
  *k = o;
}

// ---------------------------------------------------------------- the input budget
#define COUNTED (IN_SWAP | IN_UP | IN_DOWN | IN_LEFT | IN_RIGHT)
// How many actions the game still allows a move starting on frame `at`: the allowance less the presses made and planned in the window.
static int allowanceAt(int32_t at) {
  int32_t lo = at - F.window, used = 0, prev = F.prevBits;
  for (int i = 0; i < F.npress; i++) if (F.pressFrames[i] > lo) used++;
  for (int32_t t = F.now; t < at; t++) {
    Planned *p = planOf(t);
    int32_t bits = p ? p->bits : 0, down = bits & COUNTED & ~prev;
    prev = bits;
    for (int b = 1; b <= 16; b <<= 1) if ((down & b) && t > lo) used++;
  }
  return imax(0, F.limit - used);
}
// Whether the keys from frame `at` stay inside the allowance in every window.
static int keysFit(int32_t at, const Keys *k) {
  static int32_t spent[1024];
  int ns = 0, head = 0;
  for (int i = 0; i < F.npress && ns < 1024; i++) spent[ns++] = F.pressFrames[i];
  int32_t prev = F.prevBits;
  for (int32_t t = F.now; t < at + k->n; t++) {
    Planned *p = planOf(t);
    int32_t bits = t >= at ? k->ins[t - at] : (p ? p->bits : 0), down = bits & COUNTED & ~prev;
    prev = bits;
    for (int b = 1; b <= 16; b <<= 1) if (down & b) {
      while (head < ns && t - spent[head] >= F.window) head++;
      if (ns - head >= F.limit) return 0;
      if (ns < 1024) spent[ns++] = t;
    }
  }
  return 1;
}
static void countActions(int32_t bits, int32_t now, int32_t play, int32_t lid) {
  int32_t down = bits & COUNTED & ~F.prevBits;
  F.prevBits = bits;
  LineRec *lr = lineRec(lid);
  for (int b = 1; b <= 16; b <<= 1) if ((down & b) && F.npress < 512) {
    F.pressFrames[F.npress++] = now; F.st.actions++;
    F.st.actsBy[play >= 0 && play <= NPLAYS ? play : 0]++; if (lr) lr->acts++;
  }
  int k = 0;
  for (int i = 0; i < F.npress; i++) if (now - F.pressFrames[i] < F.window) F.pressFrames[k++] = F.pressFrames[i];
  F.npress = k;
  if (k > F.st.maxWindow) F.st.maxWindow = k;
  if (k > F.limit) F.st.overInput++;
}
// (b: the board the keys begin on)
#define AIM_RESERVE 40   // (the actions a hold's walk to the next work leaves the window at least: two breaks' walks)
static void walkKeys(Keys *k, int32_t at, const Board *b) { if (tightAt(allowanceAt(at))) fSlowWalks(k, b->curRow, b->curCol); else fHoldWalks(k, b->curRow, b->curCol); }

// ---------------------------------------------------------------- pacing
// How soon an answer can be had, in frames: half again the slowest of the last few.
static int soon(void) {
  double worst = 300;
  if (F.nthinking) { worst = 0; for (int i = 0; i < F.nthinking; i++) if (F.thinking[i] > worst) worst = F.thinking[i]; }
  return imax(6, imin(600, (int)__builtin_ceil(worst / F.msPerFrame * 1.5)));
}
static int aheadOf(void) { return imax(F.ahead, soon()); }
static uint32_t frand(void) { F.rnd = F.rnd * 1664525u + 1013904223u; return F.rnd >> 8; }
// THE SLACK: after a swap whose decision found the hold lives and nothing urgent, the next swap waits the profile's gap and a jitter.
// (never while a chain of ours falls: its links are pressed in the frames they were judged in -- a link pressed a gap late is no link, set 86
// large_garbage 2, a swap judged for 353 pressed at 358 and a 5 come down a 3)
static int calmGap(const Board *next) {
  // (run 277: never with nobody across -- time attack's stage is won against the clock (a Line Clear: its rows sent in two minutes), so
  // a board that lives is no reason to wait: run 276's 7-colour Line Clears spent their time between chains on flattening, set-ups and
  // designs walked a swap at a time, each swap after the first waiting the profile's gap (20) and a jitter (to 16) once the hold lived)
  if (ruleNoEnemy) return -1;
  if (F.gap < 0 || !F.haveSwapEnd || !F.havePace || !F.lastHold || F.lastUrgent) return -1;
  if (next->chainCounter > 0 || cascadeLive(next)) return -1;
  int32_t stop = next->stopTime + next->preStopTime;
  if (F.toppedNow && !(stop > F.gap)) return -1;
  if (F.jitter) {
    if (F.jitterFor != F.lastSwapEnd) { F.jitterFor = F.lastSwapEnd; F.jitterGap = F.gap + (int)(frand() % (uint32_t)(F.jitter + 1)); }
    return F.jitterGap;
  }
  return F.gap;
}

// ---------------------------------------------------------------- questions and answers
// (THE LINE'S SWAPS PRESSED BY A FRAME: those handed to the keys, less those with a key still planned at the frame or after -- the answer
// taken then clears the keys from that frame on, so a swap whose keys run past it is never pressed, and the line is carried on from it)
static int32_t linePressedBy(int32_t at) {
  int32_t n = F.lineOfPressed; uint32_t open = 0;
  for (int i = 0; i < PLANN; i++)
    if (F.planAt[i] != NUL && F.planAt[i] >= at && F.plan[i].swap && F.plan[i].lid == F.lineOfId + 1 && F.plan[i].idx >= 1 && F.plan[i].idx < 32) open |= 1u << F.plan[i].idx;
  while (open) { n -= (int32_t)(open & 1); open >>= 1; }
  return imax(0, n);
}
// (THE ANSWER'S OWN SWAP NEVER PRESSED BY A FRAME: not pressed yet, and its press not planned before the frame -- the plan was dropped
// with it still to come; the line it began is carried on whole, decide.c theCarryOff)
static int32_t moveOffBy(int32_t at) {
  if (!F.haveLineOf || !F.lineOfSwap || F.lineOfMoved) return 0;
  for (int i = 0; i < PLANN; i++)
    if (F.planAt[i] != NUL && F.planAt[i] < at && F.plan[i].swap && (F.plan[i].bits & IN_SWAP) && F.plan[i].lid == F.lineOfId + 1 && F.plan[i].idx == 0) return 0;
  return 1;
}
static void ask(int32_t at, const Board *b, int32_t hl, int32_t hs, const Arrival *pend, int32_t npend) {
  static FQuestion q;
  F.pending = 1; F.pPosted = F.now; F.pId = F.nextId++; F.pEpoch = F.epoch; F.pAt = at; F.pPaced = 0; F.pHoldLeft = hl; F.pHoldStarted = hs;
  if (!F.pBoard) F.pBoard = nb_new();
  copyBoard(F.pBoard, b);
  keepQueue(F.pBoard, MAXINC - MAXARR);
  F.pNarr = 0;
  for (int i = 0; i < npend; i++) if (pend[i].at > b->stopWatch) F.pArr[F.pNarr++] = pend[i];
  memcpy(F.pKnew, F.arr, sizeof(Arrival) * (unsigned long)F.narr); F.pNknew = F.narr;
  q.id = F.pId; q.epoch = F.epoch; q.at = at; q.lead = at - F.now; q.ms = (at - F.now) * F.msPerFrame; q.posted = fNow();
  q.allowance = allowanceAt(at); q.topped = F.toppedNow; q.lineFrom = F.haveLineOf ? F.lineOfId : -1; q.linePressed = F.haveLineOf ? linePressedBy(at) : 0;
  q.moveOff = moveOffBy(at);
  q.noRaise = F.askNoRaise;
  q.holdLeft = hl; q.holdStarted = hs; q.narr = F.pNarr; memcpy(q.arr, F.pArr, sizeof(Arrival) * (unsigned long)F.pNarr);
  { int32_t prev = F.prevBits; q.nages = 0; q.window = F.window;
    for (int i = 0; i < F.npress && q.nages < 512; i++) if (at - F.pressFrames[i] < F.window) q.ages[q.nages++] = at - F.pressFrames[i];
    for (int32_t t = F.now; t < at; t++) { Planned *p = planOf(t); int32_t bits = p ? p->bits : 0, down = bits & COUNTED & ~prev; prev = bits;
      for (int b = 1; b <= 16; b <<= 1) if ((down & b) && at - t < F.window && q.nages < 512) q.ages[q.nages++] = at - t; } }
  q.swapA = F.prSwapA ? F.prSwapA : F.swapA; q.swapB = F.prSwapA ? F.prSwapB : F.swapB;
  q.refA = F.refUntil > at ? F.refA : 0; q.refB = F.refUntil > at ? F.refB : 0; q.refUntil = F.refUntil;
  q.oppHas = F.oppHas; q.oppOut = F.oppOut; q.oppTop = F.oppTop; q.oppStop = imax(0, F.oppStop - (at - F.now));
  q.b = F.pBoard;
  postQuestion(&q);
  F.st.decisions++;
}
// The answers: an answer's keys go in the plan, and the next decision is due on the frame they end on. One that came after its frame is
// not played (a swap is pressed only on the board it was judged on); the next question is asked of the board as it is.
static int follow(void);
// A RAISE'S KEYS: the button down for the frames the row has left (raiseNow), and raiseAfter held after them for the rows on to the
// decision's `to` -- the rows the decision judged the board alive through and no more. A button down past the row's end begins the
// next row, which the engine then brings in whole whether or not the button stays down (pa.c handleManualRaise).
static void raiseKeys(const FAnswer *a, Keys *k) {
  k->n = imin(imax(1, a->raiseNow), MAXKEYS); k->held = 0;
  for (int q = 0; q < k->n; q++) { k->ins[q] = IN_RAISE; k->hl[q] = q == k->n - 1 ? a->raiseAfter : 0; k->hs[q] = q == k->n - 1 && a->raiseAfter > 0; }
}
// (a raise answered for the board b: no keys where the search's own raise step makes none there; else the answer's own, whatever
// that step holds)
static int raiseKeysOn(const FAnswer *a, const Board *b, int32_t holdLeft, int32_t holdStarted, const Arrival *arr, int32_t narr, Keys *k) {
  if (!keysOf(b, holdLeft, holdStarted, arr, narr, MK_RAISE, 0, 0, k)) return 0;
  raiseKeys(a, k);
  return 1;
}
static void take(void) {
  static FAnswer a;
  static Keys k;
  while (takeAnswer(&a)) {
    if (F.nthinking == FTHINK) { memmove(F.thinking, F.thinking + 1, sizeof(double) * (FTHINK - 1)); F.nthinking--; }
    // (how soon an answer can be had: what it took, up to a reaction's frames -- a decision given longer, because its move was further
    // off, used time it was given, not time the next one needs)
    double took = a.ms - a.idleMs > 0 ? a.ms - a.idleMs : 0, most = (F.reaction + 1) * F.msPerFrame;
    F.thinking[F.nthinking++] = took < most ? took : most;
    if (!F.pending || a.id != F.pId) { F.st.unasked++; continue; }
    F.pending = 0;
    if (a.error || a.kind < 0) continue;
    if (a.epoch != F.epoch || a.at < F.now) {
      F.st.late++;
      if (a.epoch == F.epoch && F.st.late <= 40) { char l[160]; snprintf(l, sizeof l, "LATE answer for %d taken at %d: %.0f ms, closing %.0f ms, %.1f ms a frame", a.at, F.now, a.ms, a.closeMs, F.msPerFrame); flog(l); }
      continue;
    }
    int32_t at = a.at;
    // (THE MOVE IN HAND: a hold the clock left no time to judge for is no answer -- the line already in hand, or else the last answer's
    // line that lives and is no hold, is played on, from the frame it was asked for, each swap checked by the keys it makes)
    if (a.kind == 0 && a.empty) {
      F.st.starved++;
      if (F.nalt && F.altMode != modeAt(at)) F.nalt = 0;
      if (!F.lineN && F.nalt) { F.lineMode = F.altMode; F.lineTap = 0; F.lineKept = 0; F.lineN = F.nalt; F.lineAsked = F.altAsked; for (int i = 0; i < F.nalt; i++) { F.line[i] = F.alt[i]; F.lineAt[i] = 0; } F.nalt = 0; F.haveLineOf = 0; }
      if (F.lineN) { if (F.nextAt < at) F.nextAt = at; if (follow()) { F.st.inHand++; continue; } }
      // (and nothing in hand to follow: the keys already planned -- the rest of the line in progress, every swap of it made keys -- are
      // pressed on as they are, never cleared for a hold nobody judged)
      { int planned = 0; for (int32_t t = at; t < at + F.window && !planned; t++) { Planned *p = planOf(t); planned = p && p->bits; }
        if (planned) { F.st.inHand++; continue; } }
    }
    if (!a.empty) { F.altMode = modeAt(a.at); F.altAsked = F.pPosted; F.nalt = a.nalt; for (int i = 0; i < a.nalt; i++) F.alt[i] = a.alt[i]; }
    int kind = a.kind == 1 ? MK_SWAP : a.kind == 2 ? MK_RAISE : MK_HOLD;
    // (A RAISE PUT OFF: nothing pressed until the frame the stack takes it, then the raise held for its rows -- the keys made here, as a
    // raise's are, on the board as it will be then. The questions go on meanwhile, from the frame after this answer's: the wait is the
    // board's, and what lands in it is the next decision's to see -- an answer before the raise is due takes its keys' place)
    if (a.kind == 2 && a.raiseWait > 0) {
      raiseKeys(&a, &k);
      planClearFrom(at);
      F.nextAt = at + 1;
      at += a.raiseWait;
      F.st.played++;
      for (int i = 0; i < k.n; i++) planSet(at + i, (Planned){ k.ins[i], k.hl[i], k.hs[i], 0, 0, F.pPosted });
      F.lastHold = a.holdLives; F.lastBrk = a.brk; F.lastUrgent = a.urgent; F.havePace = 1;
      memcpy(F.knew, F.pKnew, sizeof(Arrival) * (unsigned long)F.pNknew); F.nknew = F.pNknew;
      lineEnds(END_RAISE); F.lineN = 0; F.haveLineOf = 0;
      continue;
    }
    // (A HOLD WALKS THE CURSOR TO THE NEXT WORK: where the best line that is no hold begins, with the window to spare -- AIM_RESERVE actions
    // kept -- and the cursor two cells or more from it; nothing swapped, the board the same)
    int aimed = 0;
    // (never ahead of a line handed on judged pressed later: its walk was judged from the cursor as the hold leaves it -- a step aimed
    // before it walks a cell short, and its swap is pressed frames before the judge pressed it; set 86 factory 1, a link pressed 3 early
    // and a 6 come down a 2)
    if (a.kind == 0 && a.aim && !a.empty && allowanceAt(at) >= AIM_RESERVE && !(a.nhand && a.handAt[0] > at) &&
        iabs(F.pBoard->curRow - CR(a.aim)) + iabs(F.pBoard->curCol - CC(a.aim)) >= 2 &&
        keysOf(F.pBoard, F.pHoldLeft, F.pHoldStarted, F.pArr, F.pNarr, MK_GO, CR(a.aim), CC(a.aim), &k) && k.n > 0) { aimed = 1; F.st.aimed++; }
    if (!aimed && !(a.kind == 2 ? raiseKeysOn(&a, F.pBoard, F.pHoldLeft, F.pHoldStarted, F.pArr, F.pNarr, &k)
                                : keysOf(F.pBoard, F.pHoldLeft, F.pHoldStarted, F.pArr, F.pNarr, kind, a.kind == 1 ? CR(a.move) : 0, a.kind == 1 ? CC(a.move) : 0, &k))) {
      F.st.refused++;
      if (F.loggedRefused < LOGGED_MAX) { char l[160]; snprintf(l, sizeof l, "REFUSED answer for %d taken at %d: no keys press %d,%d there within a reaction", a.at, F.now, CR(a.move), CC(a.move)); flog(l); F.loggedRefused++; }
      continue;
    }
    // (A LINE JUDGED PRESSED LATER: its hold lasts until the line's first swap is due, not a reaction -- the swap pressed on the frame it
    // was judged pressed from)
    if (a.kind == 0 && a.nhand && a.handAt[0] > at) k.n = imin(k.n, a.handAt[0] - at);
    F.st.played++;
    pressTap = a.tap;
    walkKeys(&k, at, F.pBoard);
    if (!keysFit(at, &k)) {
      F.st.guarded++;
      if (F.loggedRefused < LOGGED_MAX) { char l[160]; snprintf(l, sizeof l, "GUARDED answer for %d taken at %d: its %d keys do not fit the input allowance", a.at, F.now, k.n); flog(l); F.loggedRefused++; }
      continue;
    }
    F.st.heldWalks += k.held;
    if (a.kind == 1) F.st.swaps++;
    planClearFrom(at);
    if (a.kind == 1 && F.loggedKeys < LOGGED_KEYS) { char l[160]; snprintf(l, sizeof l, "GAMBITK %d judged=%d cur=%d,%d sw=%d,%d keys=%d press=%d q=%d taken=%d", at, at, F.pBoard->curRow, F.pBoard->curCol, CR(a.move), CC(a.move), k.n, at + k.n - 1, F.pPosted, F.now); flog(l); F.loggedKeys++; }
    for (int i = 0; i < k.n; i++) planSet(at + i, (Planned){ k.ins[i], k.hl[i], k.hs[i], a.kind == 1, a.wastes, F.pPosted, a.play >= 0 ? a.play + 1 : 0, a.kind == 1 ? a.id + 1 : 0, 0 });
    { LineRec *o = F.haveLineOf ? lineRec(F.lineOfId + 1) : 0;
      lineEnds(a.ended);
      if (a.kind == 1) { LineRec *r = &lineRecs[a.id % LINE_RECS]; r->id = a.id + 1; r->q = a.at; r->total = a.nhand + 1; r->pressed = 0; r->why = 0; r->next = 0; r->dropped = 0;
        if (o && o->why == END_ON && o != r) { o->next = r->id; r->acts = r->inh = o->acts; } else r->acts = r->inh = 0; } }
    F.nextAt = at + k.n;
    if (a.kind == 1) { F.lastSwapEnd = F.nextAt; F.haveSwapEnd = 1; }
    F.lastHold = a.holdLives; F.lastBrk = a.brk; F.lastUrgent = a.urgent; F.havePace = 1;
    memcpy(F.knew, F.pKnew, sizeof(Arrival) * (unsigned long)F.pNknew); F.nknew = F.pNknew;
    F.lineWastes = a.wastes; F.linePlay = a.play >= 0 ? a.play + 1 : 0;
    unseenOf(F.pBoard);
    F.lineN = a.nhand; F.lineAsked = F.pPosted; F.lineMode = modeAt(a.at); F.lineTap = a.tap; F.lineKept = a.lineKept; for (int i = 0; i < a.nhand; i++) { F.line[i] = a.hand[i]; F.lineAt[i] = a.handAt[i]; }
    F.haveLineOf = 1; F.lineOfId = a.id; F.lineOfPressed = 0; F.lineOfSwap = a.kind == 1; F.lineOfMoved = 0;
  }
}
// The frame the line's next swap is pressed from: where the plan ends, or later when it was judged pressed later.
static int32_t lineDue(void) { return imax(F.nextAt, F.lineAt[0]); }
// The line behind the move, its next swap played from the frame it is due, on the board predicted for then.
// (a line it cannot press on is dropped, and the run's log says why)
// (THE LINE THE BOARD DROPPED: a line whose next swap has no key left planned once a board not foreseen cleared the plan is marked,
// and if it then ends not played out it ends as END_DROPPED -- whatever the next answer says, the board took it, not the answer)
static int32_t swapsPlanned(const LineRec *r);
static void boardTookLine(void) {
  LineRec *r = F.haveLineOf ? lineRec(F.lineOfId + 1) : 0;
  if (!r || r->why || r->pressed >= r->total || swapsPlanned(r)) return;
  r->dropped = 1;
}
// (A LINE'S SWAPS STILL COMING: those whose keys are planned and not yet pressed -- an answer comes ahead of the frame it is for, and the
// line before it is ended while its last keys are still to press)
static int32_t swapsPlanned(const LineRec *r) {
  uint32_t seen = 0;
  for (int i = 0; i < PLANN; i++) if (F.planAt[i] != NUL && F.plan[i].swap && F.plan[i].lid == r->id && F.plan[i].idx < 32) seen |= 1u << F.plan[i].idx;
  int32_t n = 0; while (seen) { n += seen & 1; seen >>= 1; }
  return n;
}
static void lineEnds(int32_t why) {
  LineRec *r = F.haveLineOf ? lineRec(F.lineOfId + 1) : 0;
  if (r && !r->why) {
    r->why = why > 0 && why < NEND ? why : END_NOTCARRIED;
    int32_t done = r->pressed + swapsPlanned(r);
    if (r->why != END_ON && r->dropped && done < r->total) r->why = END_DROPPED;
    if (r->why != END_ON && done < r->total) F.st.actsLost[r->why] += r->acts;
    // (THE LINE NOT PLAYED OUT, one line each (GAMBITE): the frame, what ended it, its swaps pressed of its total, the actions charged
    // to it, those it took over from the line it carried on, and its kind -- the actions of its own are the walk spent on it alone. A
    // line whose swaps not pressed are all still planned is played out)
    if (r->why != END_ON && done < r->total) { char l[120]; snprintf(l, sizeof l, "GAMBITE %d %d %d/%d %d %d", F.now, r->why, r->pressed, r->total, r->acts, r->inh); flog(l); }
  }
}
static int lineDropped(int32_t due, const char *why, int32_t code) {
  lineEnds(code);
  if (F.loggedRefused < LOGGED_MAX) { char l[160]; snprintf(l, sizeof l, "LINE dropped at %d (due %d, %d left): %s", F.now, due, F.lineN, why); flog(l); F.loggedRefused++; }
  F.lineN = 0; return 0;
}
static int follow(void) {
  static Keys k;
  if (!F.lineN) return 0;
  int32_t due = imax(lineDue(), F.now + 1);
  // (a line already begun is finished across a switch of the mode -- the owner: a break begun is finished; r1393, 4078: a break put down
  // after one of its three swaps for the switch, the walk to it spent for nothing -- and so is a line the board's life hangs on, begun or
  // not: one that breaks garbage, lives, or outlives the hold by a break's time; breaking garbage and surviving are every mode's. 4538
  // combo_storm 3 and 4, a break due 13 and 18 frames on, and 4551 combo_storm 1, a chain the board lived on, each dropped at the switch
  // and the board lost. Any other line not begun is dropped, the new mode plans its own)
  if (modeAt(due) != F.lineMode) {
    const LineRec *r = F.haveLineOf ? lineRec(F.lineOfId + 1) : 0;
    if (!(r && r->pressed > 0) && !F.lineKept) return lineDropped(due, "another mode", END_MODE);
    F.lineMode = modeAt(due);
  }
  // (THE LINE AS JUDGED: a swap keyed later than the judge pressed it from is pressed on a board the judge never judged -- counted, and
  // the first few logged; plans/gambit-goal.md, the truth)
  if (F.lineAt[0] > 0 && due > F.lineAt[0]) {
    F.st.behind++; F.st.behindWorst = imax(F.st.behindWorst, due - F.lineAt[0]);
    if (F.loggedRefused < LOGGED_MAX) { char l[160]; snprintf(l, sizeof l, "LINE behind at %d: %d,%d keyed from %d, judged from %d", F.now, CR(F.line[0]), CC(F.line[0]), due, F.lineAt[0]); flog(l); F.loggedRefused++; }
  }
  int32_t mv = F.line[0], hl, hs;
  if (!predict(F.expect, due, F.holdLeft, F.holdStarted, F.nextPend, F.nnextPend, F.pr, &hl, &hs)) return lineDropped(due, "no board predicted", END_NOBOARD);
  if (!keysOf(F.pr, hl, hs, F.prPend, F.nprPend, MK_SWAP, CR(mv), CC(mv), &k)) return lineDropped(due, "no keys press it", END_NOKEYS);
  if (F.pending) abortTo(F.pId);
  F.pending = 0;
  pressTap = F.lineTap;
  walkKeys(&k, due, F.pr);
  int left = allowanceAt(due), need = actionsFor(F.pr->curRow, F.pr->curCol, CR(mv), CC(mv), left);
  F.st.winChecked++;
  if (!keysFit(due, &k)) { F.st.guarded++; F.st.winShort++; F.st.winShortWorst = imax(F.st.winShortWorst, need - left); return lineDropped(due, "its keys do not fit", END_NOFIT); }
  if (need > left) { F.st.winShort++; F.st.winShortWorst = imax(F.st.winShortWorst, need - left); return lineDropped(due, "its walk is over the allowance", END_OVERWALK); }
  F.st.heldWalks += k.held;
  // (EVERY SWAP KEYED, ONE LINE (GAMBITK): the frame its keys begin, the frame the judge pressed it from (0 none), the cursor then, the
  // swap, its keys -- its press the last of them -- and the decision whose line it is: a press later than the judge's is read off here)
  if (F.loggedKeys < LOGGED_KEYS) {
    // (and the keys already planned from now to its first, as bits a frame, and the cursor now: what moves the cursor before it)
    char ks[64]; int kn = 0; for (int32_t t = F.now; t < due && kn < 60; t++) { Planned *p = planOf(t); kn += snprintf(ks + kn, sizeof ks - kn, "%x", p ? p->bits & 0xf : 0); } ks[kn] = 0;
    char l[240]; snprintf(l, sizeof l, "GAMBITK %d judged=%d cur=%d,%d sw=%d,%d keys=%d press=%d q=%d now=%d curNow=%d,%d before=%s", due, F.lineAt[0], F.pr->curRow, F.pr->curCol, CR(mv), CC(mv), k.n, due + k.n - 1, F.lineAsked, F.now, F.truth ? F.truth->curRow : -1, F.truth ? F.truth->curCol : -1, ks); flog(l); F.loggedKeys++; }
  for (int i = 0; i < k.n; i++) planSet(due + i, (Planned){ k.ins[i], k.hl[i], k.hs[i], 1, F.lineWastes, F.lineAsked, F.linePlay, F.lineOfId + 1, F.lineOfPressed + 1 });
  F.nextAt = due + k.n;
  F.lastSwapEnd = F.nextAt; F.haveSwapEnd = 1;
  memmove(F.line, F.line + 1, sizeof(int32_t) * (unsigned long)(F.lineN - 1)); memmove(F.lineAt, F.lineAt + 1, sizeof(int32_t) * (unsigned long)(F.lineN - 1)); F.lineN--;
  F.lineOfPressed++;
  F.st.followed++;
  return 1;
}

// ---------------------------------------------------------------- the attacks made, counted off the board shown
// A match of 4 or more is a combo when it is a clear of its own; a chain is counted at its longest when it ends.
// (a panel out of garbage keeps the garbage's id: every id seen as garbage is kept)
#define WASG (1 << 20)
static uint8_t wasGarbage[WASG];
static int movesOn(const Board *b, const int32_t *fresh, int nfresh, int broke);
// A THREE FOLLOWED THROUGH (the owner: never a three unless it follows through): a swap's three that breaks nothing waits FOLLOW_FOR
// frames for a break by a swap of its own line -- the line it was pressed in, or one that line was carried on as; one that comes is
// no waste (through), one that does not is counted wasted then. A three that begins a chain is no waste either (open ones dropped)
static int sameLine(int32_t from, int32_t lid) {
  const LineRec *r = lineRec(from);
  for (int hop = 0; r && hop < LINE_RECS; hop++) { if (r->id == lid) return 1; if (r->why != END_ON || !r->next) return 0; r = lineRec(r->next); }
  return 0;
}
static void threeOpen(int32_t lid, int32_t now) {
  if (F.nw3 == 16) { F.st.wasted++; memmove(F.w3, F.w3 + 1, sizeof F.w3[0] * 15); F.nw3--; }
  F.w3[F.nw3].lid = lid; F.w3[F.nw3].until = now + FOLLOW_FOR; F.w3[F.nw3].open = 1; F.w3[F.nw3].log[0] = 0; F.nw3++;
}
static void threesOpenDrop(void) { int k = 0; for (int i = 0; i < F.nw3; i++) if (!F.w3[i].open) F.w3[k++] = F.w3[i]; F.nw3 = k; }
static int threesSettle(const char *log) {
  int took = 0;
  for (int i = 0; i < F.nw3; i++) if (F.w3[i].open) { F.w3[i].open = 0; if (log[0] && !took) { snprintf(F.w3[i].log, sizeof F.w3[i].log, "%s", log); took = 1; } }
  return took;
}
static void threeThrough(int32_t lid) {
  int k = 0; for (int i = 0; i < F.nw3; i++) { if (sameLine(F.w3[i].lid, lid)) F.st.through++; else F.w3[k++] = F.w3[i]; } F.nw3 = k;
}
static void threesDue(int32_t now) {
  int k = 0;
  for (int i = 0; i < F.nw3; i++) {
    if (F.w3[i].open || now < F.w3[i].until) { F.w3[k++] = F.w3[i]; continue; }
    F.st.wasted++;
    if (F.w3[i].log[0] && F.loggedWasted < 400) { flog(F.w3[i].log); F.loggedWasted++; }
  }
  F.nw3 = k;
}
static void countAttacks(const Board *b) {
  static int32_t now[MAXROWS * W], freshIds[MAXROWS * W];
  int nn = 0, fresh = 0, fromGarbage = 0, gm = 0;
  for (int r = 1; r < b->nrows; r++) for (int c = 1; c <= W; c++) {
    const int32_t *f = b->p[r][c].f;
    if (f[ISGARBAGE] && f[ID] != NUL) wasGarbage[f[ID] & (WASG - 1)] = 1;
    if (f[ISGARBAGE] && f[STATE] == MATCHED) gm++;
    if (f[STATE] == MATCHED && !f[ISGARBAGE] && f[COLOR] > 0) {
      now[nn++] = f[ID];
      int seen = 0;
      for (int i = 0; i < F.nmatched && !seen; i++) seen = F.matchedIds[i] == f[ID];
      if (!seen) { freshIds[fresh++] = f[ID]; if ((f[ID] != NUL && wasGarbage[f[ID] & (WASG - 1)]) || (f[FELL] != NUL && f[FELL] > 0)) fromGarbage++; }
    }
  }
  memcpy(F.matchedIds, now, sizeof(int32_t) * (unsigned long)nn); F.nmatched = nn;
  int brokeNow = gm > F.gMatched;
  int bySwap = movesOn(b, freshIds, fresh, brokeNow); F.gMatched = gm;
  int32_t cc = b->chainCounter;
  // (a clear of three with no garbage broken waits: a chain it starts makes it a link, and it was no waste)
  // (wasted: a swap's -- a panel a followed swap moved is in it; wastedAlone: the stack's own, panels out of garbage or fallen)
  // (counted once its clear and every panel falling from it have settled: a three's chain comes after it pops)
  if (cc >= 2) { F.pendThree = F.pendThreeAlone = F.pendSave = 0; F.pendLog[0] = 0; threesOpenDrop(); }
  threesDue(b->clock);
  if (cc == 0 && (F.pendThree || F.pendThreeAlone || F.pendSave) && !hasActivePanels((Board *)b)) {
    if (threesSettle(F.pendLog)) F.pendLog[0] = 0;
    F.st.wastedAlone += F.pendThreeAlone; F.st.saved += F.pendSave; F.pendThree = F.pendThreeAlone = F.pendSave = 0;
    if (F.pendLog[0] && F.loggedWasted < 400) {
      flog(F.pendLog);
      // (the first few with the board their swap was pressed on: GAMBITX <frame pressed>)
      if (F.loggedWasted < 24) for (int i = 0; i < SWAPRING; i++) if (swapRing[i] && swapRingAt[i] == F.pendSwapAt) dumpBoard("GAMBITX", swapRingAt[i], swapRing[i], 0, 0, -1);
      F.loggedWasted++;
    }
    F.pendLog[0] = 0;
  }
  if (fresh == 3 && cc < 2 && !brokeNow) {
    if (bySwap && F.matchSave) F.pendSave++; else if (bySwap) { F.pendThree++; threeOpen(F.matchLid, b->clock); } else F.pendThreeAlone++;
    // (each logged, the first few hundred: where, and the swap it came of -- to find what pressed it)
    if (F.loggedWasted < 400 && !F.pendLog[0]) {
      char *l = F.pendLog; int k = snprintf(l, sizeof F.pendLog, "GAMBITW %d three", b->clock);
      for (int r = 1; r < b->nrows; r++) for (int c = 1; c <= W; c++) { const int32_t *f = b->p[r][c].f; for (int q = 0; q < fresh; q++) if (f[ID] == freshIds[q] && k < (int)sizeof F.pendLog) k += snprintf(l + k, sizeof F.pendLog - (unsigned long)k, " %d,%d", r, c); }
      // (touch: a garbage cell beside one of its cells -- a three beside garbage breaks it, whatever frame the garbage is matched on)
      int touch = 0;
      for (int r = 1; r < b->nrows; r++) for (int c = 1; c <= W; c++) {
        const int32_t *f = b->p[r][c].f; int mine = 0;
        for (int q = 0; q < fresh; q++) if (f[ID] == freshIds[q]) mine = 1;
        if (!mine) continue;
        static const int DR[4] = { 1, -1, 0, 0 }, DC[4] = { 0, 0, 1, -1 };
        for (int d = 0; d < 4; d++) { int rr = r + DR[d], cc2 = c + DC[d]; if (rr >= 1 && rr < b->nrows && cc2 >= 1 && cc2 <= W && b->p[rr][cc2].f[ISGARBAGE]) touch = 1; }
      }
      F.pendSwapAt = bySwap ? F.matchAt : -1;
      if (k < (int)sizeof F.pendLog) snprintf(l + k, sizeof F.pendLog - (unsigned long)k, " by=%s swapAt=%d after=%d touch=%d save=%d guard=%d", bySwap ? "swap" : "alone", bySwap ? F.matchAt : -1, bySwap ? F.matchAfter : -1, touch, bySwap && F.matchSave ? 1 : 0, bySwap ? F.matchGuard : -1);
    }
  }
  if (fresh > 0 && nn > fresh && !(cc > F.chainMax)) F.st.together++;
  if (cc >= 2 && F.npendCombo) F.npendCombo = 0;
  // (EVERY COMBO OF FIVE OR MORE, ONE LINE (GAMBITC): the frame it is counted on and its size -- the mode it was made in is the one the
  // decision before it was asked in: gambit_eights.js. EVERY ATTACK, ONE LINE (GAMBITA <frame> c <size> | x <chain>): the mode's aim
  // read in the mode it was made in, gambit_summary.js)
  if (cc == 0 && F.npendCombo) {
    for (int i = 0; i < F.npendCombo; i++) {
      F.st.combo[imin(F.pendCombo[i], 63)]++;
      { char la[48]; snprintf(la, sizeof la, "GAMBITA %d c %d", F.now, F.pendCombo[i]); flog(la); }
      if (F.pendCombo[i] >= 5) { char l[48]; snprintf(l, sizeof l, "GAMBITC %d %d", F.now, F.pendCombo[i]); flog(l); }
    }
    F.npendCombo = 0;
  }
  if (fresh >= 4 && cc < 2 && F.npendCombo < 16) F.pendCombo[F.npendCombo++] = fresh;
  if (cc > F.chainMax) {
    if (cc >= 3) F.st.linkBy[fromGarbage ? LINK_GARBAGE : F.swapSince ? LINK_SWAP : LINK_ALONE][imin(cc, 31)]++;
    F.chainMax = cc; F.swapSince = 0;
  }
  if (cc == 0 && F.chainMax >= 2) { F.st.chain[imin(F.chainMax, 31)]++; char la[48]; snprintf(la, sizeof la, "GAMBITA %d x %d", F.now, F.chainMax); flog(la); }
  if (cc == 0) F.chainMax = 0;
}

// ---------------------------------------------------------------- every move on the way: what each swap pressed came to
// A swap pressed is followed by the ids of the panels it moves -- the two swapped, and those above them that fall in the MOVE_FALL
// frames after it -- until one of them is matched or MOVE_FOR frames pass: matched before the next swap is pressed, the swap cleared;
// after it, the swap set the clear up; a clear that breaks garbage, a break; none matched, a swap that did nothing.
// EVERY SWAP, ONE LINE (GAMBITM): the frame it was pressed, where, the kind of line, what it came to (c a clear, s a set-up, b a break,
// n nothing), its place in its line, the actions pressed for it since the swap before, what ended its line (front.c lineEnds; 0
// not yet), the ids of the two cells it swapped (0 none: a swap of the same two ids twice running is a swap back), and q= the frame of
// the decision that played its line (its GAMBITD line: the line's reason)
static void moveLog(const MoveOpen *m, char outcome) {
  const LineRec *r = lineRec(m->lid);
  char l[200]; snprintf(l, sizeof l, "GAMBITM %d %d,%d %s %c %d/%d %d %d %d %d q=%d", m->at, m->row, m->col, m->play > 0 && m->play <= NPLAYS ? PLAY_NAME[m->play - 1] : "-",
                        outcome, m->idx + 1, r ? r->total : 0, m->acts, r ? r->why : -1, m->pa, m->pb, r ? r->q : -1);
  flog(l);
}
static void noneOf(const MoveOpen *m) {
  moveLog(m, 'n');
  F.st.moveNone++; if (m->play > 0 && m->play <= NPLAYS) F.st.noneBy[m->play - 1]++;
  const LineRec *r = lineRec(m->lid);
  // (a line carried on is the same line: what became of it is what became of the last answer it was carried on as)
  int on = 0;
  for (int hop = 0; r && r->why == END_ON && r->next && hop < LINE_RECS; hop++) { const LineRec *n = lineRec(r->next); if (!n) break; r = n; on = 1; }
  if (r) {
    if (on ? r->pressed >= r->total || !r->why : m->idx >= r->total - 1) F.st.noneLast++;
    else if (!on && r->pressed > m->idx + 1) F.st.noneOn++;
    else { F.st.noneDropped++; F.st.noneWhy[r->why > 0 && r->why < NEND ? r->why : 0]++; }
  }
}
static void moveBegin(const Board *b, int32_t save, int32_t guard, int32_t play, int32_t lid, int32_t idx) {
  { int i = swapRingN++ % SWAPRING; if (!swapRing[i]) swapRing[i] = nb_new(); if (swapRing[i]) { cloneBoard(swapRing[i], b); swapRingAt[i] = b->clock; } }
  for (int i = 0; i < F.nmoves; i++) F.moves[i].swapsAfter++;
  if (F.nmoves == MOVE_OPEN) { noneOf(&F.moves[0]); memmove(F.moves, F.moves + 1, sizeof(MoveOpen) * (MOVE_OPEN - 1)); F.nmoves--; }
  MoveOpen *m = &F.moves[F.nmoves++]; memset(m, 0, sizeof *m); m->at = b->clock; m->save = save; m->guard = guard; m->play = play; m->lid = lid; m->idx = idx;
  m->row = b->curRow; m->col = b->curCol; m->acts = F.st.actions + 1 - F.actsAtSwap; F.actsAtSwap = F.st.actions + 1;
  { LineRec *r = lineRec(lid); if (r && r->pressed < idx + 1) r->pressed = idx + 1; }
  if (F.haveLineOf && lid == F.lineOfId + 1 && idx == 0) F.lineOfMoved = 1;
  int r0 = b->curRow;
  if (r0 >= 0 && r0 < b->nrows && b->curCol >= 1 && b->curCol + 1 <= W) {
    int32_t a = b->p[r0][b->curCol].f[ID], z = b->p[r0][b->curCol + 1].f[ID];
    m->pa = a == NUL ? 0 : a; m->pb = z == NUL ? 0 : z;
  }
  for (int c = b->curCol; c <= b->curCol + 1 && c <= W; c++)
    for (int r = r0; r < b->nrows && m->n < MOVE_IDS; r++) {
      const int32_t *f = b->p[r][c].f;
      if (f[COLOR] <= 0 || f[ISGARBAGE] || f[ID] == NUL) continue;
      m->ids[m->n] = f[ID]; m->moved[m->n++] = r == r0;
    }
}
// (1 when a panel a followed swap moved is among the fresh matches: the clear is the swap's)
static int movesOn(const Board *b, const int32_t *fresh, int nfresh, int broke) {
  static int32_t ids[MAXROWS * W], states[MAXROWS * W];
  int nc = 0, k = 0, bySwap = 0;
  if (!F.nmoves) return 0;
  for (int r = 1; r < b->nrows; r++) for (int c = 1; c <= W; c++) {
    const int32_t *f = b->p[r][c].f;
    if (f[COLOR] > 0 && !f[ISGARBAGE] && f[ID] != NUL) { ids[nc] = f[ID]; states[nc++] = f[STATE]; }
  }
  for (int i = 0; i < F.nmoves; i++) {
    MoveOpen *m = &F.moves[i];
    int done = 0, alive = 0;
    for (int j = 0; j < m->n && !done; j++) {
      int st = -1;
      for (int q = 0; q < nc && st < 0; q++) if (ids[q] == m->ids[j]) st = states[q];
      if (st < 0) continue;
      alive = 1;
      if (!m->moved[j] && b->clock - m->at <= MOVE_FALL && (st == HOVERING || st == FALLING)) m->moved[j] = 1;
      if (m->moved[j]) for (int q = 0; q < nfresh && !done; q++) done = fresh[q] == m->ids[j];
    }
    if (done) { bySwap = 1; F.matchLid = m->lid; if (broke) threeThrough(m->lid); F.matchAt = m->at; F.matchAfter = m->swapsAfter; F.matchSave = m->save; F.matchGuard = m->guard; if (broke) F.st.moveBreak++; else if (!m->swapsAfter) F.st.moveClear++; else F.st.moveSetup++; moveLog(m, broke ? 'b' : !m->swapsAfter ? 'c' : 's'); continue; }
    if (!alive || b->clock - m->at > MOVE_FOR) { noneOf(m); continue; }
    if (k != i) F.moves[k] = *m;
    k++;
  }
  F.nmoves = k;
  return bySwap;
}

// ---------------------------------------------------------------- no wasted three, on the board itself
// THE PRESS GUARD (the owner: a wasted three is never played): a swap about to be pressed is played first on a copy of the board as it is
// -- beside the board with it not pressed, by the judge's own test (judge.c wastedThree) -- and refused when it makes a three for
// nothing. The judge saw the board predicted for its question's frame; this one is the board as it is, every colour shown since. 1: refuse it.
#define REFUSE_BLOCK 60      // the frames a refused swap's pair is kept out of the next decisions' first swaps
#define GUARD_DIE 120   // the frames the board is played on, with the swap and without, to tell a three that saves it
static Board *guardBoard, *aloneBoard;
static int32_t planKeyAt(int32_t f) { Planned *q = planOf(F.now + f + 1); return q ? q->bits : 0; }
static Arrival guardPendG[MAXARRIVALS], guardPendA[MAXARRIVALS]; static int32_t guardNpG, guardNpA;
static void guardLand(Board *g, Board *a) { landOn(g, guardPendG, &guardNpG); landOn(a, guardPendA, &guardNpA); }
static int wastedSwap(const Board *t, int32_t bits) {
  if (!guardBoard) guardBoard = nb_new();
  if (!aloneBoard) aloneBoard = nb_new();
  if (!guardBoard || !aloneBoard) return 0;
  copyBoard(guardBoard, t); copyBoard(aloneBoard, t);
  guardBoard->input = bits & ~IN_SWAP; guardBoard->pressSwap = 1;
  aloneBoard->input = bits & ~IN_SWAP; aloneBoard->pressSwap = 0;
  F.guardSpoil = 0;
  if (wastedThree(guardBoard, aloneBoard)) return 1;
  // (and the board's own chain spoiled by the swap, the board left alone after it -- as the judge asks it of every swap of a line; a
  // chain the mode asks, rules.c ownChainAsked)
  copyBoard(guardBoard, t); copyBoard(aloneBoard, t);
  guardBoard->input = bits & ~IN_SWAP; guardBoard->pressSwap = 1;
  aloneBoard->input = bits & ~IN_SWAP; aloneBoard->pressSwap = 0;
  memcpy(guardPendG, F.arr, sizeof(Arrival) * (unsigned long)F.narr); memcpy(guardPendA, F.arr, sizeof(Arrival) * (unsigned long)F.narr);
  guardNpG = guardNpA = F.narr;
  int s = spoilsChain(guardBoard, aloneBoard, 0, guardLand);
  F.guardSpoil = s;
  return s;
}
// THE SAVE: the board played on for GUARD_DIE frames, the garbage on its way landing as the game lands it -- with the swap not pressed
// and nothing after it (livesFor 0), or with it pressed and the plan's keys after it as they will be pressed (livesFor 1). A three the
// judge saw on the line's way to the garbage it breaks (Planned.save 2, rank.c wastesThree) is let through as the judge let it, and the
// survival search's save (Planned.save 1) when the board is lost without it; any other -- one the judge did not see, a colour it could
// not know shown -- when the board is lost without it and lives longer with it pressed: refused there, the next decision comes after the
// stop time it was pressed in has run out. Otherwise the swap is refused and the next decision asked.
static Board *dieBoard;
// (the frames the board is played on before it is lost, GUARD_DIE when it is not)
static int32_t livesFor(const Board *t, int32_t bits, int press) {
  Board *g = dieBoard;
  copyBoard(g, t);
  static Arrival pend[MAXARRIVALS];
  int32_t np = F.narr;
  memcpy(pend, F.arr, sizeof(Arrival) * (unsigned long)np);
  if (receiverTimed) landOn(g, pend, &np);
  g->input = bits & ~(IN_SWAP | IN_RAISE); g->pressSwap = press;
  for (int f = 0; f < GUARD_DIE && g->gameOverClock <= 0; f++) {
    run(g); landOn(g, pend, &np);
    Planned *q = press ? planOf(F.now + f + 1) : 0;
    g->input = q ? q->bits & ~(IN_SWAP | IN_RAISE) : 0; g->pressSwap = q && (q->bits & IN_SWAP);
  }
  return g->gameOverClock > 0 ? g->gameOverClock - t->clock : GUARD_DIE;
}
static int threeSaves(const Board *t, int32_t bits, int planned) {
  if (!dieBoard) dieBoard = nb_new();
  if (!dieBoard) return 0;
  if (planned == 2) return 1;
  int32_t without = livesFor(t, bits, 0);
  if (without >= GUARD_DIE) return 0;
  return planned == 1 || livesFor(t, bits, 1) > without;
}
// ---------------------------------------------------------------- the countdown
// THE OPENING THOUGHT THROUGH THE COUNTDOWN: the board does not move while the countdown runs, so the board of the first frame in play
// is the one shown now, its clock and stop-watch those it will have then. The opening's question is asked of it once, `left` frames before
// play begins and for CD_SLACK frames after -- its lead, and with it the decision's time, the countdown's -- and answered as any question
// is: the first frame in play takes the answer, its keys from that frame.
#define CD_SLACK 4
#define CD_ASKS 2   // (the opening and the decision after it, on the board its swaps leave -- planned on the layers shown, neither offered a raise: no garbage is shown before play begins, and the raise is the first decision's in play to make on what it shows)
static void take(void);
static int frontCountdown(int32_t left) {
  if (left <= 0) return 0;
  Board *t = F.truth;
  int32_t now = t->clock, at = now + left + CD_SLACK;
  // (THE NEXT ONE ASKED TOO: the opening's answer taken, its keys laid from the first frame in play, and the board they leave at the frame
  // they end predicted from the first frame's -- asked now, in the countdown's time, as the frame loop would once they were pressed)
  if (F.countdownAsked && F.countdownAsked < CD_ASKS && F.cdBoard) {
    F.now = now;
    take();
    if (F.pending || F.nextAt <= F.cdBoard->clock) return 0;
    int32_t hl, hs, next = F.nextAt;
    if (!predict(F.cdBoard, next, 0, 0, 0, 0, F.pr, &hl, &hs) || F.pr->gameOverClock > 0) { F.countdownAsked = CD_ASKS; return 0; }
    F.now = now;
    F.askNoRaise = 1; ask(next, F.pr, hl, hs, F.prPend, F.nprPend); F.askNoRaise = 0;
    F.countdownAsked++;
    { char l[96]; snprintf(l, sizeof l, "COUNTDOWN clock %d: the next asked for %d, %d frames ahead", now, next, next - now); flog(l); }
    return 1;
  }
  // (and the last one's answer taken while the countdown runs, as it comes: its keys laid before play begins)
  if (F.countdownAsked >= CD_ASKS && F.pending) { F.now = now; take(); return 0; }
  if (F.pending || F.countdownAsked) return 0;
  if (!F.cdBoard) F.cdBoard = nb_new();
  if (!F.cdBoard) return 0;
  copyBoard(F.cdBoard, t);
  F.cdBoard->inCountdown = 0; F.cdBoard->stopWatchIsRunning = 1; F.cdBoard->riseLock = 0;
  F.cdBoard->clock = at; F.cdBoard->stopWatch = CD_SLACK - 1;
  F.now = now;
  F.askNoRaise = 1; ask(at, F.cdBoard, 0, 0, 0, 0); F.askNoRaise = 0;
  F.countdownAsked = 1;
  { char l[96]; snprintf(l, sizeof l, "COUNTDOWN clock %d: the opening asked for %d, %d frames ahead", now, at, at - now); flog(l); }
  return 1;
}
// ---------------------------------------------------------------- one frame
static int32_t idleWin = -1, idleWins, idleWinsKeyed, idleKeyed;   // (the half-seconds in play and those with a key: frontFrame)
static int frontFrame(void) {
  Board *t = F.truth;
  int32_t now = t->clock;
  char why[160];
  F.now = now;
  countAttacks(t);
  if (F.curWalked) F.st.cursorCells += iabs(t->curRow - F.curRowWas) + iabs(t->curCol - F.curColWas);
  F.curRowWas = t->curRow; F.curColWas = t->curCol;
  F.toppedNow = isToppedOut(t);
  F.st.frames++;
  double wall = fNow();
  if (F.wall) F.msPerFrame += ((wall - F.wall < 100 ? wall - F.wall : 100) - F.msPerFrame) / 60;
  F.wall = wall;
  int diverged = 0;
  if (F.haveExpect && differ(F.expect, t, why, sizeof why)) {
    // (GARBAGE COME UNFORESEEN, THE BOARD ITSELF AS PREDICTED: only the queue differs -- the panels the keys planned act on are the ones
    // they were judged on, and the garbage drops as the next frame's prediction from the board has it. The keys and the line in hand
    // are pressed on; the question out, asked without the garbage, is dropped and asked again on this board -- its answer takes the
    // line's place. Anything else that differs drops the plan.)
    char why2[160]; int queueOnly = !differQ(F.expect, t, why2, sizeof why2, 0);
    if (queueOnly) {
      if (F.pending) { abortTo(F.pId); F.pending = 0; }
      memcpy(F.knew, F.arr, sizeof(Arrival) * (unsigned long)F.narr); F.nknew = F.narr;
      F.st.queueOnly++;
    } else dropAll();
    F.st.diverged++; diverged = !queueOnly;
    if (F.loggedDiffer < 40) {
      // (and the garbage on its way as the telegraph shows it now, and as the plan knew it: how many, and how many due by now)
      // (and the soonest the plan knew of, in frames from now: how late a forecast that did not come due was)
      int dueNow = 0, dueKnew = 0; int32_t soonest = 0x7fffffff;
      for (int i = 0; i < F.narr; i++) dueNow += F.arr[i].at <= t->stopWatch;
      for (int i = 0; i < F.nknew; i++) { dueKnew += F.knew[i].at <= t->stopWatch; if (F.knew[i].at < soonest) soonest = F.knew[i].at; }
      char l[320]; snprintf(l, sizeof l, "DIVERGED clock %d: %s (on its way %d, due %d; known %d, due %d, soonest in %d)", now, why, F.narr, dueNow, F.nknew, dueKnew,
                            F.nknew ? soonest - t->stopWatch : -1);
      flog(l); F.loggedDiffer++;
    }
  }
  // (colours shown where the board had them unseen -- a broken slab's, a cell at a time as it pops: the plan stands and so does the
  // question out -- a swap is where it is whatever the colour, and a board the colour does change is caught as one that differs. Asked
  // again on every colour shown, a slab popping would leave no question answered until it is done.)
  if (!diverged && F.haveExpect && revealed(F.expect, t)) { F.st.revealed++; F.lastReveal = now; }
  // (and a colour shown coming to a clear: the plan was made on a board without it -- dropped, the next question asked on this one)
  if (!diverged && F.nunseen && revealClears(t)) {
    if (F.loggedDiffer < 40) { char l[120]; snprintf(l, sizeof l, "REVEALCLEAR clock %d: a panel the plan was made without came to a clear", now); flog(l); F.loggedDiffer++; }
    dropAll(); F.st.revealCleared++;
  }
  int32_t off = t->clock - t->stopWatch;
  // (GARBAGE UNFORESEEN: the keys planned before it lands are pressed as planned -- the board is the one they were judged on until then --
  // the rest dropped and asked again; garbage due at T is received once the frame before it has run)
  if (F.nextAt > now) { int32_t u = unforeseenFirst(F.knew, F.nknew, F.arr, F.narr); if (u <= F.nextAt - off) { dropFrom(u + off - 1); F.st.unforeseen++; } }
  if (F.pending && unforeseenBy(F.pKnew, F.pNknew, F.arr, F.narr, F.pAt - off)) { abortTo(F.pId); F.pending = 0; F.st.reasked++; }
  take();
  int32_t bits, save = 0, asked = 0, play = 0, lid = 0, idx = 0;
  Planned *p = planOf(now);
  if (p) { bits = p->bits; save = p->save; asked = p->asked; play = p->play; lid = p->lid; idx = p->idx; F.holdLeft = p->holdLeft; F.holdStarted = p->holdStarted; planDrop(now); }
  else {
    bits = 0;
    if (F.holdLeft > 0) holdRaise(t, &F.holdLeft, &F.holdStarted, &bits);
    F.st.idle++;
  }
  // (never raised while topped out: the raise is let go, and what was planned with it dropped)
  if ((bits & IN_RAISE) && (F.toppedNow || t->wasToppedOut)) {
    bits &= ~IN_RAISE; F.holdLeft = 0; F.holdStarted = 0;
    if (!(now < F.raiseCutUntil)) { dropAll(); F.st.raiseCut++; }
    F.raiseCutUntil = now + 30;
  }
  // (no wasted three pressed: the swap refused, the plan dropped, the next decision asked on the board as it is)
  // (let through only as the save: the board lost without it)
  // (only where colours were shown since the question the swap came of was asked: otherwise the board is the one the judge played the
  // line on -- the truth held -- and its test, the guard's own, said the same)
  int32_t guard = 0;
  if ((bits & IN_SWAP & ~F.prevBits) && F.lastReveal >= asked && F.lastReveal > 0 && wastedSwap(t, bits)) {
    if (!threeSaves(t, bits, save)) {
      // (the first few refused boards, the plan's keys after the swap and the garbage on its way, for replaying the guard and the judge
      // on them: GAMBITR board, GAMBITRK f:bits..., GAMBITRA at,w,h,chain,metal,capped...)
      if (F.loggedRefusedBoards < 12) {
        F.loggedRefusedBoards++;
        dumpBoard("GAMBITR", now, t, 0, 0, -1);
        static char l[8192]; int k = snprintf(l, sizeof l, "GAMBITRK %d spoil=%d bits=%d keys", now, F.guardSpoil, bits);
        for (int32_t f = 0; f < 430 && k < (int)sizeof l - 24; f++) { int32_t b = planKeyAt(f); if (b) k += snprintf(l + k, sizeof l - (unsigned long)k, " %d:%d", f, b); }
        flog(l);
        k = snprintf(l, sizeof l, "GAMBITRA %d", now);
        for (int i = 0; i < F.narr && k < (int)sizeof l - 48; i++) k += snprintf(l + k, sizeof l - (unsigned long)k, " %d,%d,%d,%d,%d,%d", F.arr[i].at, F.arr[i].g.width, F.arr[i].g.height, F.arr[i].g.isChain, F.arr[i].g.isMetal, F.arr[i].capped);
        flog(l);
      }
      bits &= ~IN_SWAP; dropAll(); F.st.wasteRefused++; F.st.refusedSpoil += F.guardSpoil;
      F.lineOfSwap = 0;   // (a swap the guard refused is not carried on)
      // (and its pair kept out of the next decisions' first swaps a while: a three the judge did not see is not planned again)
      if (t->curCol >= 1 && t->curCol + 1 <= W && t->curRow >= 0 && t->curRow < t->nrows) {
        F.refA = t->p[t->curRow][t->curCol].f[ID]; F.refB = t->p[t->curRow][t->curCol + 1].f[ID]; F.refUntil = now + REFUSE_BLOCK;
      }
    } else { guard = 2; F.st.guardLet++; }
  }
  // (THE SWAP PRESSED NOW, every one the frame loop presses -- a line's later swaps and those timed after the decision too: the two panels
  // as they stand once it is pressed, for the next decision's no flip and back -- decide.c undoesLast)
  if ((bits & IN_SWAP & ~F.prevBits) && t->curCol >= 1 && t->curCol + 1 <= W && t->curRow >= 0 && t->curRow < t->nrows) {
    __atomic_store_n(&undoFresh, 0, __ATOMIC_RELEASE);
    __atomic_store_n(&undoIdL, t->p[t->curRow][t->curCol + 1].f[ID], __ATOMIC_RELAXED); __atomic_store_n(&undoIdR, t->p[t->curRow][t->curCol].f[ID], __ATOMIC_RELAXED);
    __atomic_store_n(&undoFresh, 1, __ATOMIC_RELEASE);
  }
  if (bits & IN_SWAP & ~F.prevBits) {
    moveBegin(t, save == 1, guard, play, lid, idx);   // (save: the survival search's three, for the count)
    if (t->curCol >= 1 && t->curCol + 1 <= W && t->curRow >= 0 && t->curRow < t->nrows) { F.swapA = t->p[t->curRow][t->curCol].f[ID]; F.swapB = t->p[t->curRow][t->curCol + 1].f[ID]; }
  }
  F.curWalked = !!(bits & (IN_UP | IN_DOWN | IN_LEFT | IN_RIGHT));
  countActions(bits, now, play, lid);
  if (bits & IN_SWAP) F.swapSince = 1;
  { FTrace *r = &ftrace[ftraceN++ % FTRACE];
    *r = (FTrace){ now, bits, p != 0, F.pending ? F.pAt : -1, F.nextAt, F.lineN, F.lineN ? F.lineAt[0] : -1, ftraceDrops }; ftraceDrops = 0; }
  // (THE HALF-SECONDS PRESSED: of the game's half-seconds in play, those with any key pressed -- the goal's never idle, GAMBITI at the end)
  { int32_t w = now / 30; if (w != idleWin) { idleWin = w; idleWins++; idleKeyed = 0; } if (bits && !idleKeyed) { idleKeyed = 1; idleWinsKeyed++; } }
  return bits;
}
static void frontTraceOut(void) {
  if (idleWins) { char l[64]; snprintf(l, sizeof l, "GAMBITI %d %d", idleWins, idleWinsKeyed); flog(l); }
  idleWins = idleWinsKeyed = idleKeyed = 0; idleWin = -1;
  int n = ftraceN < FTRACE ? ftraceN : FTRACE;
  for (int i = 0; i < n; i++) {
    const FTrace *r = &ftrace[(ftraceN - n + i) % FTRACE];
    char l[160]; snprintf(l, sizeof l, "GAMBITF %d %d %d %d %d %d %d %d", r->clock, r->bits, r->planned, r->pend, r->nextAt, r->lineN, r->lineAt, r->drops);
    flog(l);
  }
  ftraceN = 0;
}
// After the frame: the board it makes, then the line followed on or the next question asked.
static void afterFrame(int32_t bits) {
  int32_t now = F.now;
  copyBoard(F.expect, F.truth);
  memcpy(F.nextPend, F.arr, sizeof(Arrival) * (unsigned long)F.narr); F.nnextPend = F.narr;
  if (receiverTimed) landOn(F.expect, F.nextPend, &F.nnextPend);   // (a transit due now lands before the frame runs)
  F.expect->input = bits & ~IN_SWAP;
  if (bits & IN_SWAP) F.expect->pressSwap = 1;
  run(F.expect);
  landOn(F.expect, F.nextPend, &F.nnextPend);
  F.haveExpect = 1;
  Board *next = F.expect;
  if (next->gameOverClock > 0) return;
  // (a swap handed on with the frame it was judged pressed from is pressed then, paced or not -- the line judged is the line played)
  if (F.pending && (!F.pPaced || (F.lineN && F.lineAt[0])) && !answerWaiting(F.pId)) { if (F.lineN) { if (lineDue() - now <= 1) follow(); } else if (F.nextAt - now == 1) F.st.noLine++; }
  if (F.pending) return;
  int gap = calmGap(next);
  while (gap < 0 && F.lineN && F.nextAt > now && lineDue() - now < soon() && follow()) {}
  // (and one due before an answer could be had is pressed then, the question asked after it)
  while (F.lineN && F.lineAt[0] && lineDue() - now < soon() && follow()) {}
  int lead = F.nextAt > now ? soon() : imax(soon(), imin(aheadOf(), popLeft(next) / 4));
  // (A BOARD ON ITS WAY OUT WITH NO BREAK FOUND: the last answer held a board that dies and its break search found none -- asked a
  // reaction ahead at least, so the decision has a reaction's time to find one where it had the few ms recent answers took (run 448: 4
  // of 5 breaks missed were not found again in the live search's own 3 to 27 ms); a board lost before then is asked for its last frame
  // alive, below)
  if (F.havePace && !F.lastHold && !F.lastBrk && F.nextAt <= now) lead = imax(lead, imin(aheadOf(), F.reaction + 1));
  int32_t at = imax(F.nextAt > now ? F.nextAt : 0, now + lead);
  // (A LONG WAIT IS ASKED ABOUT: keys planned no sooner than ASK_IDLE frames off -- a line in hand waiting for its chain, its walk
  // planned on the frame it was judged to begin -- leave the frames before them idle, and they are asked about as any are: the answer
  // carries the line on, its swaps pressed the frames they were judged pressed from (decide.c carriedCand), or takes its place)
  if (at - now > ASK_IDLE) {
    int32_t first = 0;
    for (int32_t t = now + 1; t <= now + ASK_IDLE && !first; t++) { Planned *p = planOf(t); if (p && p->bits) first = t; }
    if (!first) at = now + lead;
  }
  int paced = 0;
  if (gap >= 0 && F.lastSwapEnd + gap > at) { at = F.lastSwapEnd + gap; paced = 1; }
  // (A LINE IN HAND: asked no later than the frame its next swap is due -- a board predicted past it is one without the swap, and the
  // answer to it takes the line's place, so the swap is never pressed and the board the line was judged to leave never is)
  if (F.lineN && lineDue() > now && at > lineDue()) { at = lineDue(); paced = 0; }
  if (at - now > aheadOf()) return;
  int32_t hl, hs;
  int ok = predict(next, at, F.holdLeft, F.holdStarted, F.nextPend, F.nnextPend, F.pr, &hl, &hs);
  // (the board predicted lost by then: asked a reaction before the last frame it is still alive, or as soon as an answer can be had
  // when that is later -- never for the last frame itself, where no swap pressed comes down before the board is lost)
  if (ok && F.pr->gameOverClock > 0) {
    int32_t alive = F.pr->gameOverClock - 1, want = imin(alive - 1, imax(now + soon(), alive - F.reaction));
    ok = want > now + 1 && predict(next, want, F.holdLeft, F.holdStarted, F.nextPend, F.nnextPend, F.pr, &hl, &hs) && F.pr->gameOverClock <= 0;
    if (ok) at = want;
  }
  if (!ok || F.pr->gameOverClock > 0) {
    if (F.loggedAskNow < 40) {
      char l[200]; snprintf(l, sizeof l, "ASKNOW clock %d: the board for frame %d %s (engine error %d, queued %d)", now, at, !ok ? "could not be predicted" : "is lost by then", predictErr, next->ninc);
      flog(l); F.loggedAskNow++;
    }
    at = now + 1; copyBoard(F.pr, next); hl = F.holdLeft; hs = F.holdStarted;
    memcpy(F.prPend, F.nextPend, sizeof(Arrival) * (unsigned long)F.nnextPend); F.nprPend = F.nnextPend;
  }
  ask(at, F.pr, hl, hs, F.prPend, F.nprPend);
  if (paced && at > now + 1) { F.pPaced = 1; F.st.paced++; }
}

// THE MATCH'S STATS as one JSON line, as the reports read it ("match over: {...}")
static void statsLine(char *out, int cap) {
  int k = snprintf(out, (unsigned long)cap, "match over: {\"frames\":%d,\"decisions\":%d,\"played\":%d,\"late\":%d,\"diverged\":%d,\"refused\":%d,"
                   "\"guarded\":%d,\"unasked\":%d,\"idle\":%d,\"followed\":%d,\"noLine\":%d,\"unforeseen\":%d,\"reasked\":%d,\"revealed\":%d,"
                   "\"raiseCut\":%d,\"actions\":%d,\"maxWindow\":%d,\"overInput\":%d,\"heldWalks\":%d,\"paced\":%d,\"swaps\":%d,\"starved\":%d,\"inHand\":%d,\"aimed\":%d,\"behind\":%d,\"behindWorst\":%d,\"winChecked\":%d,\"winShort\":%d,\"winShortWorst\":%d,\"revealCleared\":%d,\"early\":%d,\"queueOnly\":%d,\"arrivals\":%d,\"surprises\":%d,\"noticeMin\":%d,\"attacks\":{\"combo\":{",
                   F.st.frames, F.st.decisions, F.st.played, F.st.late, F.st.diverged, F.st.refused, F.st.guarded, F.st.unasked, F.st.idle,
                   F.st.followed, F.st.noLine, F.st.unforeseen, F.st.reasked, F.st.revealed, F.st.raiseCut, F.st.actions, F.st.maxWindow,
                   F.st.overInput, F.st.heldWalks, F.st.paced, F.st.swaps, F.st.starved, F.st.inHand, F.st.aimed, F.st.behind, F.st.behindWorst, F.st.winChecked, F.st.winShort, F.st.winShortWorst, F.st.revealCleared, F.st.early, F.st.queueOnly, F.st.arrivals, F.st.surprises, F.st.noticeMin);
  int first = 1;
  for (int z = 0; z < 64 && k < cap; z++) if (F.st.combo[z]) { k += snprintf(out + k, (unsigned long)(cap - k), "%s\"%d\":%d", first ? "" : ",", z, F.st.combo[z]); first = 0; }
  if (k < cap) k += snprintf(out + k, (unsigned long)(cap - k), "},\"chain\":{");
  first = 1;
  for (int z = 0; z < 32 && k < cap; z++) if (F.st.chain[z]) { k += snprintf(out + k, (unsigned long)(cap - k), "%s\"%d\":%d", first ? "" : ",", z, F.st.chain[z]); first = 0; }
  if (k < cap) k += snprintf(out + k, (unsigned long)(cap - k), "}},\"linkBy\":{");
  static const char *CAUSE[3] = { "garbage", "swap", "alone" };
  for (int w = 0; w < 3 && k < cap; w++) {
    k += snprintf(out + k, (unsigned long)(cap - k), "%s\"%s\":{", w ? "," : "", CAUSE[w]);
    first = 1;
    for (int z = 0; z < 32 && k < cap; z++) if (F.st.linkBy[w][z]) { k += snprintf(out + k, (unsigned long)(cap - k), "%s\"%d\":%d", first ? "" : ",", z, F.st.linkBy[w][z]); first = 0; }
    if (k < cap) k += snprintf(out + k, (unsigned long)(cap - k), "}");
  }
  if (k < cap) k += snprintf(out + k, (unsigned long)(cap - k), "}");
  // (the swaps still followed when the match ends are counted by what they came to so far: nothing yet)
  if (k < cap) k += snprintf(out + k, (unsigned long)(cap - k), ",\"moves\":{\"clear\":%d,\"setup\":%d,\"break\":%d,\"none\":%d,\"open\":%d,\"cells\":%d,\"together\":%d,\"wasted\":%d,\"wastedAlone\":%d,\"refusedWaste\":%d,\"saved\":%d,\"guardLet\":%d,\"refusedSpoil\":%d,\"through\":%d}",
                        F.st.moveClear, F.st.moveSetup, F.st.moveBreak, F.st.moveNone, F.nmoves, F.st.cursorCells, F.st.together, F.st.wasted + F.nw3, F.st.wastedAlone, F.st.wasteRefused, F.st.saved, F.st.guardLet, F.st.refusedSpoil, F.st.through);
  if (k < cap) k += snprintf(out + k, (unsigned long)(cap - k), ",\"noneBy\":{");
  first = 1;
  for (int z = 0; z < NPLAYS && k < cap; z++) if (F.st.noneBy[z]) { k += snprintf(out + k, (unsigned long)(cap - k), "%s\"%s\":%d", first ? "" : ",", PLAY_NAME[z], F.st.noneBy[z]); first = 0; }
  if (k < cap) k += snprintf(out + k, (unsigned long)(cap - k), "},\"noneHow\":{\"dropped\":%d,\"on\":%d,\"last\":%d},\"noneWhy\":{", F.st.noneDropped, F.st.noneOn, F.st.noneLast);
  first = 1;
  for (int z = 0; z < NEND && k < cap; z++) if (F.st.noneWhy[z]) { k += snprintf(out + k, (unsigned long)(cap - k), "%s\"%d\":%d", first ? "" : ",", z, F.st.noneWhy[z]); first = 0; }
  if (k < cap) k += snprintf(out + k, (unsigned long)(cap - k), "},\"actsBy\":{");
  first = 1;
  for (int z = 0; z <= NPLAYS && k < cap; z++) if (F.st.actsBy[z]) { k += snprintf(out + k, (unsigned long)(cap - k), "%s\"%s\":%d", first ? "" : ",", z ? PLAY_NAME[z - 1] : "none", F.st.actsBy[z]); first = 0; }
  if (k < cap) k += snprintf(out + k, (unsigned long)(cap - k), "},\"actsLost\":{");
  first = 1;
  for (int z = 0; z < NEND && k < cap; z++) if (F.st.actsLost[z]) { k += snprintf(out + k, (unsigned long)(cap - k), "%s\"%d\":%d", first ? "" : ",", z, F.st.actsLost[z]); first = 0; }
  if (k < cap) snprintf(out + k, (unsigned long)(cap - k), "}}");
}

static void frontNew(int reaction, int ahead, int gap, int jitter) {
  if (F.pending) abortTo(F.pId);
  Board *keep[5] = { F.truth, F.expect, F.pr, F.pBoard, F.cdBoard };
  int32_t nextId = F.nextId;
  memset(&F, 0, sizeof F); memset(lineRecs, 0, sizeof lineRecs);
  F.truth = keep[0] ? keep[0] : nb_new(); F.expect = keep[1] ? keep[1] : nb_new(); F.pr = keep[2] ? keep[2] : nb_new(); F.pBoard = keep[3]; F.cdBoard = keep[4];
  for (int i = 0; i < PLANN; i++) F.planAt[i] = NUL;
  F.nextId = nextId ? nextId : 1;
  F.reaction = reaction; F.ahead = ahead; F.gap = gap; F.jitter = jitter;
  F.msPerFrame = 1000.0 / 60; F.limit = 1 << 20; F.window = 600;   // chaos: no input allowance (plans/chaos-goal.md §6)
  F.rnd = (uint32_t)fNow();
  memset(wasGarbage, 0, sizeof wasGarbage);
  swapRingN = 0; for (int i = 0; i < SWAPRING; i++) swapRingAt[i] = NUL;
}
