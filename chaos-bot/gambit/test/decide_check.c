// THE DECISION REPLAYED (test/main.c asks it, built with GB_TEST): a question Gambit met in a game, its board and the garbage on its way
// (gb_question_bytes), answered as a new game with the mode's rules. Its time is a game's (REPLAY_MS, shared out among the searches and
// the judging as a game's is), read off the work done -- `work` engine frames to the whole decision, never the wall clock, so the same
// board gives the same answer every time. Its record: the move, the play, and the first three of the one order with the keys they were
// ranked by.
#define REPLAY_MS 150   // a decision's time, as the frame loop gives one
static int64_t replayWork;
static double replayNow(void) { return (double)clockWork * REPLAY_MS / (double)replayWork; }
// (the last replay's answer as numbers, for the checks: its kind (0 hold, 1 swap, 2 raise), verdict (answer.c Answer), the candidates
// that live, the garbage on the board, the blocks on their way, the stack's top row, the rules' raise row, the raise's held steps)
static int32_t replayLast[9];
EXPORT(gb_replay_last) void gb_replay_last(int32_t *v) { for (int i = 0; i < 9; i++) v[i] = replayLast[i]; }
// A LOW STACK (gb_replay_low KEEP, before a replay): the question's board cut to its bottom KEEP rows, nothing queued or on its way --
// refused (-2) when those rows hold garbage or anything not at rest
static int32_t replayLow;
EXPORT(gb_replay_low) void gb_replay_low(int keep) { replayLow = keep; }
// (THE ALLOWANCE THE GAME GAVE, gb_replay_allow ALLOW before a replay: the actions left in the input window, the walks tapped near the
// end as the native host's frame loop taps them -- -1: none said, as the checks replay)
static int32_t replayAllow = -1;
EXPORT(gb_replay_allow) void gb_replay_allow(int allow) { replayAllow = allow; }
// (THE RAISE OFFERED, gb_replay_raise 1 before a replay: the question asked as the frame loop asks one it may answer with a raise)
static int32_t replayRaise;
EXPORT(gb_replay_raise) void gb_replay_raise(int on) { replayRaise = on; }
static int lowered(Board *b, int keep) {
  const Panel *empty = 0;
  for (int c = 1; c <= W && !empty; c++) if (!b->p[b->nrows - 1][c].f[COLOR] && !b->p[b->nrows - 1][c].f[ISGARBAGE]) empty = &b->p[b->nrows - 1][c];
  if (!empty || keep + 1 >= b->nrows) return 0;
  for (int r = 0; r <= keep; r++) for (int c = 1; c <= W; c++) if (b->p[r][c].f[ISGARBAGE] == 1 || b->p[r][c].f[STATE] != (r ? NORMAL : DIMMED)) return 0;   // (row 0: the row rising, dimmed)
  Panel e = *empty;
  for (int r = keep + 1; r < b->nrows; r++) for (int c = 1; c <= W; c++) { int32_t id = b->p[r][c].f[ID]; b->p[r][c] = e; b->p[r][c].f[ROW] = r; b->p[r][c].f[COL] = c; b->p[r][c].f[ID] = id; }
  b->ninc = 0; b->nstall = 0; b->chainCounter = 0; b->shakeTime = 0; b->riseLock = 0; b->stopWatch = 0; b->preventManualRaise = 0; b->manualRaise = 0;
  b->stopTime = 0; b->preStopTime = 0; b->nActive = 0; b->nPrevActive = 0;
  for (int r = 0; r < b->nrows; r++) { b->rowActive[r] = -1; for (int c = 1; c <= W; c++) b->p[r][c].f[CHAINING] = 0; }
  return 1;
}
// (THE ENEMY THE GAME SAW, gb_replay_enemy TOP OUT STOP before a replay: its top row, whether it is topped out, its stop time -- TOP
// under 0: none said, as the checks replay)
static int32_t replayOppTop = -1, replayOppOut, replayOppStop;
EXPORT(gb_replay_enemy) void gb_replay_enemy(int top, int out, int stop) { replayOppTop = top; replayOppOut = out; replayOppStop = stop; }
// (THE WINDOW'S PRESSES, gb_replay_ages before a replay: the frames ago each key still inside the input window went down, as a native
// host says them with the question -- that replay's alone)
EXPORT(gb_replay_ages) void gb_replay_ages(const int32_t *ages, int n) { hostWin = 1; nWinAges = imin(n, WINMAX); for (int i = 0; i < nWinAges; i++) winAges[i] = ages[i]; }
EXPORT(gb_replay) int gb_replay(int nbytes, int narr, int mode, int64_t work, char *out, int cap) {
  if (gb_question_bytes(nbytes, replayLow ? 0 : narr) != 0) return -1;
  if (replayLow && !lowered(hostBoard, replayLow)) return -2;
  if (replayLow) hostQ.narr = 0;
  gb_new_game();
  if (replayLow) gambitHit = garbageSeen = 1;   // (the boards are cut from garbage games: garbage has been on them -- with none ever, endless, no stack is raised)
  modeRule = mode;
  curQid = abortId + 1;
  replayWork = work; clockNowOf = work > 0 ? replayNow : 0; clockFrameOut = 0; clockWork = 0;
  int topped = fullTop(hostBoard) >= hostBoard->height;
  // (work 0: the wall clock's REPLAY_MS, as a game gives it -- the speed check's; else the work's, the same answer every time)
  double t0 = work > 0 ? 0 : clock_ms(), due = t0 + REPLAY_MS;
  int32_t taps = hostTaps; if (replayAllow >= 0) hostTaps = 1;
  int opp = replayOppTop >= 0;
  answerQuestion(1, 0, topped, opp, opp && replayOppOut, opp, opp ? replayOppTop : 0, opp && replayOppStop >= 0, opp ? replayOppStop : 0,
                 replayAllow >= 0, imax(0, replayAllow), -1, 0, (replayLow || replayRaise) && canRaiseOn(hostBoard), due, t0, 0);
  hostTaps = taps;   // (the raise asked of a low stack only)
  clockNowOf = 0;
  const Answer *A = &theAnswer;
  replayLast[0] = A->d.kind; replayLast[1] = A->verdict; replayLast[2] = A->nlive; replayLast[3] = garbageOn(hostBoard);
  replayLast[4] = hostQ.narr; replayLast[5] = fullTop(hostBoard); replayLast[6] = theTables.raiseTo; replayLast[7] = A->d.kind == 2 ? A->raiseNow : 0; replayLast[8] = A->sooner;
  int k = snprintf(out, (unsigned long)cap, "move %d %d,%d play %d live %d/%d |", A->d.kind, A->d.move ? CR(A->d.move) : 0, A->d.move ? CC(A->d.move) : 0,
                   A->play, A->nlive, A->ncands);
  // (the chain the board makes left alone and the one it makes with the line played, where the board is making one)
  if (aloneChain > 1) k += snprintf(out + k, (unsigned long)(cap - k), " own %d/%d", aloneChain, A->whole >= 0 ? A->whole : aloneChain);
  for (int i = 0; i < 3 && i < A->ncands && k < cap - 160; i++) {
    const Judge *J = order[i];
    k += snprintf(out + k, (unsigned long)(cap - k), " %d:%d,%d,%d,%d,%d,%d,%d,t%d", J->hold ? PLAY_HOLD : J->k.play, J->o.lives, J->o.lostAt, J->outside,
                  J->met, J->material, J->saving, J->o.lifeLeft, tierView(J).tier);
  }
  return k;
}
// SWITCHING'S DIRECTIONS (answer.c gb_switch_game): over `games` games of `frames` frames each, how often each ordered pair of the
// attack rules is switched between -- into counts (n x n, by the rules' order), the pairs never switched between returned
EXPORT(gb_switch_check) int gb_switch_check(int games, int frames, int min, int max, int32_t *counts, int *nrules) {
  int32_t idx[MAXRULES], nr = 0;
  for (int i = 0; i < theTables.n && nr < MAXRULES; i++) if (theTables.r[i].table == 1 && !asksNoEnemy(&theTables.r[i])) idx[nr++] = theTables.r[i].name;
  *nrules = nr;
  for (int i = 0; i < nr * nr; i++) counts[i] = 0;
  gb_switch(min, max);
  for (int g = 0; g < games; g++) {
    gb_switch_game((uint32_t)(g * 7919 + 1));
    for (int k = 1; k < nswitch && switchAt[k] < frames; k++) {
      int a = -1, b = -1;
      for (int i = 0; i < nr; i++) { if (idx[i] == switchMode[k - 1]) a = i; if (idx[i] == switchMode[k]) b = i; }
      if (a >= 0 && b >= 0) counts[a * nr + b]++;
    }
  }
  gb_switch(0, 0); nswitch = 0;
  int missing = 0;
  for (int a = 0; a < nr; a++) for (int b = 0; b < nr; b++) if (a != b && !counts[a * nr + b]) missing++;
  return missing;
}
// A BOARD RUN A FRAME AT A TIME (gb_frames, the checks' tool for a board a game dumped): the question's board (gb_question_bytes), the
// swap at (mr, mc) pressed as the judge presses it (mr 0: none), then `frames` frames left alone; per frame into out: the frame, the
// chain counter, the panels active, the clears so far -- 4 words a frame. The frames written.
#define FRAMESW 16
static int32_t framesR2[FRAMESW], framesC2[FRAMESW], framesAt2[FRAMESW], framesN2;   // (swaps after the first, each pressed from its frame: gb_frames2)
static int32_t framesAskAt = -1; static Board *framesAsk;   // (the board kept at framesAskAt, for gb_frames_ask)
EXPORT(gb_frames_keep) void gb_frames_keep(int at) { framesAskAt = at; }
EXPORT(gb_frames2) void gb_frames2(int r, int c, int at) { if (framesN2 < FRAMESW) { framesR2[framesN2] = r; framesC2[framesN2] = c; framesAt2[framesN2++] = at; } }
EXPORT(gb_frames) int gb_frames(int mr, int mc, int frames, int32_t *out) {
  static Ctx *fx; fx = ctxOf(fx);
  curQid = abortId + 1; clockNowOf = 0; clockFrameOut = 0; clockStart(0);
  int n = rootOf(fx, &hostQ);
  if (n < 0) return -1;
  if (mr) { int from; n = pressWalk(fx, n, MK_SWAP, mr, mc, stepTapped, &from); if (!liveNode(fx, n)) return -2; }
  int k = 0, clears = 0, next = 0;
  for (int f = 0; f < frames; f++) {
    int w;
    if (next < framesN2 && NODE(fx, n)->t >= framesAt2[next]) { int from; w = pressWalk(fx, n, MK_SWAP, framesR2[next], framesC2[next], stepTapped, &from); next++; }
    else w = step(fx, n, MK_LONG, 0, 0, 1);
    if (!liveNode(fx, w)) break;
    Board *b = ensureBoard(fx, w);
    if (framesAskAt >= 0 && NODE(fx, w)->t == framesAskAt) { if (!framesAsk) framesAsk = nb_new(); cloneBoard(framesAsk, b); }
    Stats st; if (statsOf(fx, w, &st)) clears += st.n;
    out[4 * k] = NODE(fx, w)->t; out[4 * k + 1] = b->chainCounter; out[4 * k + 2] = b->nActive; out[4 * k + 3] = clears; k++;
    n = w;
  }
  return k;
}
// THE DECISION ON THE BOARD KEPT (gb_frames_ask): answered as gb_replay answers, and the first candidates' chain keys -- for the checks
EXPORT(gb_frames_ask) int gb_frames_ask(int mode, int64_t work, char *out, int cap) {
  if (!framesAsk) return -1;
  if (!hostBoard) hostBoard = nb_new();
  cloneBoard(hostBoard, framesAsk);
  hostQ.b = hostBoard; hostQ.narr = 0; hostQ.holdLeft = 0; hostQ.holdStarted = 0;
  gb_new_game(); modeRule = mode; curQid = abortId + 1;
  replayWork = work; clockNowOf = replayNow; clockFrameOut = 0; clockWork = 0;
  answerQuestion(1, 0, fullTop(hostBoard) >= hostBoard->height, 0, 0, 0, 0, 0, 0, 0, 0, -1, 0, 0, REPLAY_MS, 0, 0);
  clockNowOf = 0;
  int k = snprintf(out, (unsigned long)cap, "ownChainBy %d N %d aloneChain %d | ", ownChainBy, ownChainN, aloneChain);
  for (int i = 0; i < 6 && i < theAnswer.ncands && k < cap - 200; i++) {
    const Judge *J = order[i];
    k += snprintf(out + k, (unsigned long)(cap - k), " [%s lost %d keeps %d whole %d cuts %d broke %d]", J->hold ? "hold" : PLAY_NAME[J->k.play], J->o.lostAt, J->o.j.keepsChain, J->apWhole, cutsShort(J), J->apBroke);
  }
  k += snprintf(out + k, (unsigned long)(cap - k), "\n%s", logBuf);
  return k;
}
// THE LINE AS THE FRAME LOOP PRESSES IT (gb_front_line, the checks' tool): the question's board, its swaps mv[0..n) followed as front.c
// follow() makes their keys -- each from the frame the keys before it end, or the frame it was judged pressed from (at, from the
// board's clock; 0 none), whichever is later -- with `allow` actions left in the input window and the walks tapped (tap) or not. Per
// swap into out: the frame its keys begin, the frame its swap goes down, its keys. The swaps keyed (a swap no keys press ends it).
static int frontLine(int n, const int32_t *mv, const int32_t *at, int allow, int tap, int32_t *out);
// (THE HELD KEYS, OFF THE WALL: the keys played on the board they begin on, every direction held two frames or more and let go with the
// cursor anywhere but the wall it walks toward -- core/nodes.h legHeld -- counted)
static int32_t frontHeldOff, frontHeld, frontOffCell;
static Board *heldBoard;
// (and the swap: pressed with the cursor on the swap the keys were made for, mv -- frontOffCell counts those that are not)
static int heldOffWall(const Board *b, const Keys *k, int32_t mv) {
  if (!heldBoard) heldBoard = nb_new();
  Board *g = heldBoard;
  copyBoard(g, b);
  int off = 0, held = 0;
  int32_t dir = 0;
  for (int q = 0; q <= k->n && g->gameOverClock <= 0; q++) {
    int32_t bits = q < k->n ? k->ins[q] : 0, d = bits & 15;
    if (dir && d != dir) { if (held >= 2) { frontHeld++; off += !legHeld(dir, g->curRow, g->curCol); } held = 0; }
    dir = d; if (d) held++;
    if (q == k->n) break;
    g->input = bits & ~IN_SWAP; g->pressSwap = !!(bits & IN_SWAP);
    if ((bits & IN_SWAP) && (g->curRow != CR(mv) || g->curCol != CC(mv))) frontOffCell++;
    run(g);
  }
  return off;
}
EXPORT(gb_held_off) int gb_held_off(int *held, int *offCell) { *held = frontHeld; *offCell = frontOffCell; int o = frontHeldOff; frontHeldOff = frontHeld = frontOffCell = 0; return o; }
// (on the game's thread, as the frame loop runs: its own board pool, apart from thread 0's that the workers' searches hand out -- native.c)
EXPORT(gb_front_line) int gb_front_line(int n, const int32_t *mv, const int32_t *at, int allow, int tap, int32_t *out) {
  paThreadId(MAXTHREADS - 1);
  int keyed = frontLine(n, mv, at, allow, tap, out);
  paThreadId(0);
  return keyed;
}
static int frontLine(int n, const int32_t *mv, const int32_t *at, int allow, int tap, int32_t *out) {
  frontNew(cfgReaction, 90, -1, 0);
  Board *b0 = F.truth; cloneBoard(b0, hostBoard);
  int32_t t0 = b0->clock;
  F.now = t0; F.npress = 0;
  for (int i = 0; i < F.limit - allow; i++) F.pressFrames[F.npress++] = t0 - 1;
  Arrival arr[MAXARR]; int32_t narr = 0;
  for (int i = 0; i < hostQ.narr; i++) { Arrival a; memset(&a, 0, sizeof a); a.at = b0->stopWatch + hostQ.arr[i].at; a.g.width = hostQ.arr[i].width; a.g.height = hostQ.arr[i].height; a.g.isChain = hostQ.arr[i].isChain; a.g.frameEarned = NUL; arr[narr++] = a; }
  static Keys k;
  int32_t nextAt = t0, i = 0;
  for (; i < n; i++) {
    int32_t due = imax(nextAt, at[i] ? t0 + at[i] : 0), hl, hs;
    if (!predict(b0, due, 0, 0, arr, narr, F.pr, &hl, &hs)) break;
    if (!keysOf(F.pr, hl, hs, F.prPend, F.nprPend, MK_SWAP, CR(mv[i]), CC(mv[i]), &k)) break;
    pressTap = tap;
    walkKeys(&k, due, F.pr);
    frontHeldOff += heldOffWall(F.pr, &k, mv[i]);
    int sw = -1;
    for (int q = 0; q < k.n && sw < 0; q++) if (k.ins[q] & IN_SWAP) sw = q;
    for (int q = 0; q < k.n; q++) planSet(due + q, (Planned){ k.ins[q], k.hl[q], k.hs[q], 1, 0 });
    out[3 * i] = due - t0; out[3 * i + 1] = sw >= 0 ? due + sw - t0 : -1; out[3 * i + 2] = k.n;
    nextAt = due + k.n;
  }
  return i;
}
// THE RAISE AS THE FRAME LOOP PRESSES IT (gb_front_raise, after a replay that answered a raise from the question's own frame): the
// answer's raise keyed as front.c take() keys it and played on the question's board with its garbage on its way, to two frames past
// the last frame the button is down. Into out: the rows that came in, the rows the answer asked, 1 where a raise is still going -- a
// row begun that the answer did not ask -- and 1 where the board is lost. 0 where the last answer is no such raise or makes no keys.
EXPORT(gb_front_raise) int gb_front_raise(int32_t *out) {
  const Answer *A = &theAnswer;
  if (A->d.kind != 2 || A->raiseWait) return 0;
  paThreadId(MAXTHREADS - 1);
  frontNew(cfgReaction, 90, -1, 0);
  Board *b0 = F.truth; cloneBoard(b0, hostBoard);
  int32_t t0 = b0->clock, hl, hs, keyed = 0;
  F.now = t0;
  Arrival arr[MAXARR]; int32_t narr = 0;
  for (int i = 0; i < hostQ.narr; i++) { Arrival a; memset(&a, 0, sizeof a); a.at = b0->stopWatch + hostQ.arr[i].at; a.g.width = hostQ.arr[i].width; a.g.height = hostQ.arr[i].height; a.g.isChain = hostQ.arr[i].isChain; a.g.frameEarned = NUL; arr[narr++] = a; }
  static FAnswer fa; static Keys k;
  memset(&fa, 0, sizeof fa); fa.kind = 2; fa.raiseNow = A->raiseNow; fa.raiseAfter = A->raiseAfter;
  if (raiseKeysOn(&fa, b0, 0, 0, arr, narr, &k)) {
    for (int q = 0; q < k.n; q++) planSet(t0 + q, (Planned){ k.ins[q], k.hl[q], k.hs[q], 0, 0 });
    if (predict(b0, t0 + k.n + k.hl[k.n - 1] + 2, 0, 0, arr, narr, F.pr, &hl, &hs)) {
      out[0] = fullTop(F.pr) - fullTop(b0); out[1] = 1 + A->raiseAfter / ROW_STEPS; out[2] = F.pr->manualRaise != 0; out[3] = F.pr->gameOverClock > 0;
      keyed = 1;
    }
  }
  paThreadId(0);
  return keyed;
}
// THE LINE AS THE JUDGE PRESSES IT (gb_judge_line, beside gb_front_line): the question's board, its swaps judged with `allow` actions
// left and the walks tapped (tap) or not, as a decision judges them. Into out: each swap's frame (ats), then dead, deadAt, lostAt.
EXPORT(gb_judge_line) int gb_judge_line(int n, const int32_t *mv, int allow, int tap, int settled, int32_t *out) {
  curQid = abortId + 1; clockNowOf = 0; clockFrameOut = 0; clockStart(0);
  decQ = hostQ;
  pressTap = decTap = tap; decQ.tight = tightAt(allow); pressTight = decQ.tight; pressAllowance = allow;
  JudgeOpts jo = { settled, decQ.tight, NOT_ASKED, 0, 0, -1, 0, 0, 0, 0, 0 };
  Judged j;
  judge(&decQ, mv, n, &jo, &j);
  int k = 0;
  for (int i = 0; i < j.nats; i++) out[k++] = j.ats[i];
  out[k++] = j.dead; out[k++] = j.deadAt; out[k++] = j.cut;
  return j.nats;
}
// THE LINE PRESSED AS JUDGED (gb_line_agree, after a replay given an allowance: gb_replay_allow): the answer's swap and the line it hands
// on, keyed as the frame loop keys them (gb_front_line) -- the swaps whose keys begin later than the frame the judge pressed them from,
// or that no keys press. *n: the swaps compared.
static char lineShown[512];
EXPORT(gb_line_agree) int gb_line_agree(int *n) {
  const Answer *A = &theAnswer;
  int32_t mv[MAXLINE + 1], at[MAXLINE + 1], out[3 * (MAXLINE + 1)], k = 0;
  *n = 0;
  if (replayAllow < 0 || !(A->d.kind == 1 || (A->d.kind == 0 && A->nhand))) return 0;
  if (A->d.kind == 1) { mv[k] = A->d.move; at[k++] = 0; }
  for (int i = 0; i < A->nhand && k <= MAXLINE && A->handAt[i] > 0; i++) { mv[k] = A->hand[i]; at[k++] = A->handAt[i]; }
  int keyed = gb_front_line(k, mv, at, replayAllow, A->tap, out), late = k - keyed;
  for (int i = 0; i < keyed; i++) late += out[3 * i] > at[i];
  *n = k;
  // (the line, for the checks' report: each swap, the frame judged, the frame keyed)
  int w = snprintf(lineShown, sizeof lineShown, "tap %d settled %d:", A->tap, A->handSettled);
  for (int i = 0; i < k && w < (int)sizeof lineShown - 40; i++) w += snprintf(lineShown + w, sizeof lineShown - (unsigned long)w, " %d,%d@%d/%d", CR(mv[i]), CC(mv[i]), at[i], i < keyed ? out[3 * i] : -1);
  return late;
}
EXPORT(gb_line_shown) const char *gb_line_shown(void) { return lineShown; }
// COLOURS SHOWN (gb_reveal_keep, then a board loaded, then gb_reveal_apply -- the checks' tool): the board kept gives the board loaded
// the colours it shows where the loaded one has them unseen, panel by panel id. The panels coloured.
static Board *revealSrc;
EXPORT(gb_reveal_keep) void gb_reveal_keep(void) { if (!revealSrc) revealSrc = nb_new(); cloneBoard(revealSrc, hostBoard); }
EXPORT(gb_reveal_apply) int gb_reveal_apply(void) {
  int n = 0;
  if (!revealSrc) return 0;
  for (int r = 0; r < hostBoard->nrows; r++) for (int c = 1; c <= W; c++) {
    int32_t *f = hostBoard->p[r][c].f;
    if (!((f[COLOR] >= 30 && f[COLOR] <= 119) || (f[COLOR] >= 130 && f[COLOR] <= 219))) continue;
    for (int r2 = 0; r2 < revealSrc->nrows; r2++) for (int c2 = 1; c2 <= W; c2++) {
      const int32_t *g = revealSrc->p[r2][c2].f;
      if (g[ID] == f[ID] && g[COLOR] >= 1 && g[COLOR] <= 10 && f[COLOR] != g[COLOR]) { f[COLOR] = g[COLOR]; n++; }
    }
  }
  return n;
}
// THE FRAME LOOP ON ITS OWN (gb_front_sim, the checks' tool): the question's board played `frames` frames by the frame loop and Gambit's
// thread as a game plays them -- the engine is the game: each frame's board is the one the frame loop predicted -- a frame each
// `msPerFrame` of the wall clock, under the rule `mode` (-1: the profile's). Per frame into out: the clock, the keys. The frames played (the game lost: the last).
EXPORT(gb_front_sim) int gb_front_sim(int frames, int msPerFrame, int mode, int32_t *out) {
  paThreadId(MAXTHREADS - 1);
  gn_match();
  if (mode >= 0) modeRule = mode;
  cloneBoard(F.truth, hostBoard);
  // (the garbage on its way with the question, as one sender's telegraph: each piece's transit at the stopWatch it lands on, shown until
  // it has)
  int32_t na = hostQ.narr, absAt[MAXARR];
  for (int i = 0; i < na; i++) absAt[i] = F.truth->stopWatch + hostQ.arr[i].at;
  tele[0] = 0;
  int k = 0;
  double next = clock_ms();
  for (; k < frames; k++) {
    while (clock_ms() < next) {}
    next += msPerFrame;
    double t = clock_ms(), per = msPerFrame;
    __atomic_store(&gameFrameMs, &t, __ATOMIC_SEQ_CST); __atomic_store(&gameMsPerFrame, &per, __ATOMIC_SEQ_CST); __atomic_store_n(&gameFrame, F.truth->clock, __ATOMIC_SEQ_CST);
    { int32_t *w = tele, nt = 0; w[0] = na ? 1 : 0; w[1] = F.truth->stopWatch; w[2] = 0; int32_t *ntAt = &w[3]; int x = 4;
      for (int i = 0; i < na; i++) if (absAt[i] > F.truth->stopWatch) { w[x++] = absAt[i]; w[x++] = 1; w[x++] = hostQ.arr[i].width; w[x++] = hostQ.arr[i].height;
        w[x++] = hostQ.arr[i].isChain; w[x++] = hostQ.arr[i].isMetal; w[x++] = NUL; w[x++] = 1; nt++; }
      *ntAt = nt; w[x++] = 0; }
    int32_t clock = F.truth->clock, bits = frontFrame();
    afterFrame(bits);
    out[2 * k] = clock; out[2 * k + 1] = bits;
    if (F.truth->gameOverClock > 0 || F.expect->gameOverClock > 0) { k++; break; }
    cloneBoard(F.truth, F.expect);
  }
  statsOut();
  paThreadId(0);
  return k;
}
// (the board kept at gb_frames_keep's frame, a few of its numbers: its clock, stop, shake, the queue, the garbage made, the top -- for the
// checks' tools to hold it beside a board the game logged)
EXPORT(gb_frames_kept_info) int gb_frames_kept_info(int32_t *out) {
  if (!framesAsk) return 0;
  const Board *b = framesAsk;
  out[0] = b->clock; out[1] = b->stopTime + b->preStopTime; out[2] = b->shakeTime; out[3] = b->ninc; out[4] = b->garbageCreatedCount; out[5] = fullTop(b);
  return 6;
}
// THE OPENING PLANNED (search/opening.c) on the question's board cut to six rows, as an opening's is, its garbage on the way left off, for `ms` of the wall clock: the levels
// grown, the plan's set-ups and the cells its trigger sends into out[0..2]; the mode's list one chain of four or longer. On workers
// (./build.sh tsan) its paths are scored on every thread.
static int openingLower = 1;   // (0: the board as the game gave it, not cut to six rows)
EXPORT(gb_opening_lower) void gb_opening_lower(int on) { openingLower = on; }
EXPORT(gb_opening_check) int gb_opening_check(int nbytes, int ms, int32_t *out) {
  if (gb_question_bytes(nbytes, 0) != 0) return -1;
  if (openingLower && !lowered(hostBoard, 6)) return -2;
  gb_new_game();
  curQid = abortId + 1; clockNowOf = 0; clockFrameOut = 0; clockStart(0);
  List keep = theList;
  memset(&theList, 0, sizeof theList); theList.n = 1; theList.aim[0].chain.op = OP_GE; theList.aim[0].chain.n = 4; theList.aim[0].brk = -1;
  Question q = hostQ; q.narr = 0;
  double sh = clockShareBegin(clock_ms() + ms);
  openingGrow(&q, q.b);
  clockShareEnd(sh);
  theList = keep;
  out[0] = opLevels; out[1] = opHave ? opBest.len : -1; out[2] = opHave ? opBest.sent : 0;
  // (the plan played back: its set-ups replayed from the board as the beam does, then its trigger swapped and settled -- the cells that
  // sends, and the plan's whole line judged as the decision judges it (outcome.c, each swap settled): its chain and what it throws)
  out[3] = out[4] = out[5] = -1;
  if (opHave) {
    Ctx *x = ctxOf(0); int root = rootOf(x, &q), at = opReplay(x, root, &opBest);
    if (at >= 0) { int o = opPress(x, at, opBest.trig);
      Stats s; out[3] = 0; if (o >= 0 && liveNode(x, o) && statsOf(x, o, &s)) out[3] = sentCells(&s); }
    int32_t seq[OP_DEPTH + 1]; int ns = 0; for (int k = 0; k < opBest.len; k++) seq[ns++] = opBest.path[k]; seq[ns++] = opBest.trig;
    decQ = q; Outcome oc = outcome(seq, ns, 1); out[4] = oc.dead ? -2 : imax(oc.j.made.chain, oc.j.chainAll); out[5] = oc.dead ? -2 : oc.j.made.combo;
  }
  return 0;
}
// THE CHAIN DESIGNED (search/chainbuild.c) on `n` boards of `rows` full rows of `colours` colours, none matching, dealt from `seed`, each
// searched `ms` of the wall clock: per board into out (links, swaps, score), the boards designed returned
EXPORT(gb_design_check) int gb_design_check(int n, int rows, int colours, int ms, uint32_t seed, int32_t *out) {
  uint32_t s = seed ? seed : 1;
  for (int i = 0; i < n; i++) {
    CbGrid G; memset(&G, 0, sizeof G); G.rows = 12;
    for (int r = 1; r <= rows; r++) for (int c = 1; c <= W; c++) {
      for (int tries = 0; tries < 50; tries++) {
        s ^= s << 13; s ^= s >> 17; s ^= s << 5;
        G.g[r][c] = (cb8)(1 + s % (unsigned)colours);
        if (cbStable(&G)) break;
      }
    }
    CbGrid D; int32_t tr = 0; int links = 0, swaps = 0;
    cbRand = s;
    clockStart(0); clockNowOf = 0;
    int32_t v = cbDesignAll(&G, 0, ms, &D, &tr, &links, &swaps);
    int32_t seq[CB_MAXSWAPS + 1]; int ord = cbOrder(&G, &D, tr, seq, CB_MAXSWAPS + 1);
    { int cl; cbAcross = cbUpDown = 0; if (tr) cbRun(&D, CR(tr), CC(tr), &cl); }
    out[4 * i] = links; out[4 * i + 1] = swaps; out[4 * i + 2] = cbAcross * 100 + cbUpDown; out[4 * i + 3] = ord;
  }
  return n;
}
// THE DESIGN ON THE ENGINE: the question's board cut to `rows` full rows of `colours` colours dealt from `seed` (none matching), the
// rise held off (rows < 0: left on), designed (`ms` of the wall clock) and its swaps then trigger played on the engine one after another, each settled.
// Into out: the chain designed, the swaps, the chain the engine made, the panels it cleared, the swap the engine first refused or
// matched on (-1 none).
static int32_t designSkill; static double designSkillMs;
EXPORT(gb_design_engine) int gb_design_engine(int nbytes, int rows, int colours, int ms, uint32_t seed, int32_t *out) {
  if (gb_question_bytes(nbytes, 0) != 0) return -1;
  int rise = rows < 0; if (rise) rows = -rows;
  Board *b = hostBoard;
  if (rows + 2 >= b->nrows) return -2;
  const Panel *full = 0, *empty = 0;
  for (int r = 1; r < b->nrows && (!full || !empty); r++) for (int c = 1; c <= W; c++) {
    const Panel *p = &b->p[r][c];
    if (!full && p->f[COLOR] > 0 && !p->f[ISGARBAGE] && p->f[STATE] == NORMAL) full = p;
    if (!empty && !p->f[COLOR] && !p->f[ISGARBAGE]) empty = p;
  }
  if (!full || !empty) return -3;
  Panel pf = *full, pe = *empty;   // (copies: the board's own cells are written over below)
  CbGrid G; memset(&G, 0, sizeof G); G.rows = b->height;
  uint32_t s = seed ? seed : 1;
  for (int r = 1; r <= rows; r++) for (int c = 1; c <= W; c++)
    for (int tries = 0; tries < 50; tries++) { s ^= s << 13; s ^= s >> 17; s ^= s << 5; G.g[r][c] = (cb8)(1 + s % (unsigned)colours); if (cbStable(&G)) break; }
  for (int r = 1; r < b->nrows; r++) for (int c = 1; c <= W; c++) {
    int32_t id = b->p[r][c].f[ID];
    b->p[r][c] = r <= rows ? pf : pe; b->p[r][c].f[ROW] = r; b->p[r][c].f[COL] = c; b->p[r][c].f[ID] = id;
    if (r <= rows) b->p[r][c].f[COLOR] = G.g[r][c];
  }
  b->ninc = 0; b->nstall = 0; b->chainCounter = 0; b->shakeTime = 0; b->stopWatch = 0; b->nActive = 0; b->nPrevActive = 0;
  b->stopTime = rise ? 0 : 1 << 20; b->preStopTime = 0;   // (the rise held off unless asked: rows < 0)
  for (int r = 0; r < b->nrows; r++) { b->rowActive[r] = -1; for (int c = 1; c <= W; c++) b->p[r][c].f[CHAINING] = 0; }
  gb_new_game(); curQid = abortId + 1; clockNowOf = 0; clockFrameOut = 0; clockStart(0);
  CbGrid D; int32_t tr = 0; int links = 0, swaps = 0;
  cbRand = s;
  cbDesign(&G, 0, ms, &D, &tr, &links, &swaps);
  int32_t seq[CB_MAXSWAPS + 1]; int n = cbOrder(&G, &D, tr, seq, CB_MAXSWAPS + 1);
  out[0] = links; out[1] = swaps; out[2] = 0; out[3] = 0; out[4] = -1;
  if (n <= 0) return 0;
  Question q = hostQ; q.narr = 0;
  Ctx *x = ctxOf(0); int at = rootOf(x, &q);
  for (int i = 0; i < n && at >= 0; i++) {
    int s1 = step(x, at, MK_SWAP, CR(seq[i]), CC(seq[i]), 0);
    if (!liveNode(x, s1)) { out[4] = 1000 + i; out[2] = s1; break; }
    int o = settleOf(x, s1);
    if (!liveNode(x, o)) { out[4] = 2000 + i; break; }
    Stats st; int cl = 0, ch = 0;
    if (statsOf(x, s1, &st)) { cl += st.cleared; if (chainOfStats(&st) > ch) ch = chainOfStats(&st); }
    if (statsOf(x, o, &st)) { cl += st.cleared; if (chainOfStats(&st) > ch) ch = chainOfStats(&st); }
    if (i < n - 1 && cl > 0) { out[4] = 3000 + i; out[2] = ch; out[3] = cl; break; }
    if (i == n - 1) { out[2] = ch; out[3] = cl; }
    at = o;
  }
  // (THE CHAIN CONTINUED, designSkill: the trigger pressed again from the board before it, and while the chain falls the extension asked
  // every few frames, its longest line's first swap pressed -- the chain it reaches into out[5], the swaps pressed into out[6])
  out[5] = 0; out[6] = 0;
  if (designSkill && n > 0 && out[4] < 0) {
    int pre = rootOf(x, &q);
    for (int i = 0; i < n - 1 && liveNode(x, pre); i++) { int s1 = step(x, pre, MK_SWAP, CR(seq[i]), CC(seq[i]), 0); pre = liveNode(x, s1) ? settleOf(x, s1) : -1; }
    int cur = liveNode(x, pre) ? step(x, pre, MK_SWAP, CR(seq[n - 1]), CC(seq[n - 1]), 0) : -1;
    int best = 0, pressed = 0;
    List L; memset(&L, 0, sizeof L); L.n = 1; L.aim[0].chain.op = OP_GE; L.aim[0].chain.n = 2; L.aim[0].brk = -1;
    for (int it = 0; it < 200 && liveNode(x, cur); it++) {
      Board *eb = ensureBoard(x, cur);
      if (!eb) break;
      if (eb->chainCounter > best) best = eb->chainCounter;
      if (it > 0 && eb->chainCounter == 0 && !hasActivePanels(eb)) break;
      Question qq = hostQ; qq.b = eb; qq.narr = 0; qq.holdLeft = 0; qq.holdStarted = 0;
      decQ = qq; ncache = 0;
      ExtOpts eo = { 40, 6, &L, NOT_ASKED, 0, designSkillMs };
      static Ext E; extend(&qq, &eo, &E);
      if (E.longest.set && E.longest.nseq > 0) {
        int s1 = step(x, cur, MK_SWAP, CR(E.longest.seq[0]), CC(E.longest.seq[0]), 0);
        if (liveNode(x, s1)) { cur = s1; pressed++; continue; }
      }
      cur = step(x, cur, MK_LONG, 0, 0, 6);
    }
    out[5] = best; out[6] = pressed;
  }
  return n;
}
static int32_t designSkill; static double designSkillMs = 60;
EXPORT(gb_design_skill) void gb_design_skill(int on, int ms) { designSkill = on; designSkillMs = ms > 0 ? ms : 60; }

// A PUZZLE ON THE ENGINE (panel-game's chain puzzles: test DIR puzzle FILE): the question's board replaced by the puzzle's rows (top
// first, '0' empty), the rise held off; the swap that sets off the longest chain on the abstract board pressed, then the chain left alone
// (out[0] its chain, out[1] the panels it leaves) and again continued -- the extension asked every few frames as it falls, its longest
// line's first swap pressed (out[2] the chain, out[3] the panels left, out[4] the swaps pressed)
static int puzWidth = 40, puzDepth = 6;
EXPORT(gb_puzzle_opts) void gb_puzzle_opts(int width, int depth) { puzWidth = width > 0 ? width : 40; puzDepth = depth > 0 ? depth : 6; }
EXPORT(gb_puzzle_engine) int gb_puzzle_engine(int nbytes, const char *rows, int ms, int32_t *out) {
  if (gb_question_bytes(nbytes, 0) != 0) return -1;
  Board *b = hostBoard;
  const Panel *full = 0, *empty = 0;
  for (int r = 1; r < b->nrows && (!full || !empty); r++) for (int c = 1; c <= W; c++) {
    const Panel *p = &b->p[r][c];
    if (!full && p->f[COLOR] > 0 && !p->f[ISGARBAGE] && p->f[STATE] == NORMAL) full = p;
    if (!empty && !p->f[COLOR] && !p->f[ISGARBAGE]) empty = p;
  }
  if (!full || !empty) return -3;
  Panel pf = *full, pe = *empty;
  int nr = 0; const char *q0 = rows; while (*q0) { if (*q0 == '|') nr++; q0++; } nr++;
  CbGrid G; memset(&G, 0, sizeof G); G.rows = b->height;
  for (int i = 0; i < nr; i++) { int r = nr - i; for (int c = 1; c <= W; c++) { char ch = rows[i * 7 + c - 1]; if (r <= G.rows) G.g[r][c] = (cb8)(ch - '0'); } }
  for (int r = 1; r < b->nrows; r++) for (int c = 1; c <= W; c++) {
    int32_t id = b->p[r][c].f[ID]; int v = r <= G.rows ? G.g[r][c] : 0;
    b->p[r][c] = v ? pf : pe; b->p[r][c].f[ROW] = r; b->p[r][c].f[COL] = c; b->p[r][c].f[ID] = id;
    if (v) b->p[r][c].f[COLOR] = v;
  }
  b->ninc = 0; b->nstall = 0; b->chainCounter = 0; b->shakeTime = 0; b->stopWatch = 0; b->nActive = 0; b->nPrevActive = 0;
  b->stopTime = 1 << 20; b->preStopTime = 0;
  for (int r = 0; r < b->nrows; r++) { b->rowActive[r] = -1; for (int c = 1; c <= W; c++) b->p[r][c].f[CHAINING] = 0; }
  gb_new_game(); curQid = abortId + 1; clockNowOf = 0; clockFrameOut = 0; clockStart(0);
  int32_t tr = 0; int links = 0; cbBest(&G, &tr, &links);
  if (!tr) return -4;
  Question q = hostQ; q.narr = 0;
  Ctx *x = ctxOf(0); int root = rootOf(x, &q);
  // (left alone)
  int s1 = step(x, root, MK_SWAP, CR(tr), CC(tr), 0), o = liveNode(x, s1) ? settleOf(x, s1) : -1;
  Stats st; int ch = 0; if (liveNode(x, o) && statsOf(x, o, &st)) ch = chainOfStats(&st);
  { Board *eb = liveNode(x, o) ? ensureBoard(x, o) : 0; out[1] = eb ? panelsOn(eb) : -1; }
  out[0] = imax(ch, links ? 1 : 0);
  // (continued)
  root = rootOf(x, &q);
  int cur = step(x, root, MK_SWAP, CR(tr), CC(tr), 0), best = 0, pressed = 0;
  List L; memset(&L, 0, sizeof L); L.n = 1; L.aim[0].chain.op = OP_GE; L.aim[0].chain.n = 2; L.aim[0].brk = -1;
  for (int it = 0; it < 300 && liveNode(x, cur); it++) {
    Board *eb = ensureBoard(x, cur);
    if (!eb) break;
    if (eb->chainCounter > best) best = eb->chainCounter;
    if (it > 0 && eb->chainCounter == 0 && !hasActivePanels(eb)) break;
    Question qq = hostQ; qq.b = eb; qq.narr = 0; qq.holdLeft = 0; qq.holdStarted = 0;
    decQ = qq; ncache = 0;
    ExtOpts eo = { puzWidth, puzDepth, &L, NOT_ASKED, 0, ms };
    static Ext E; extend(&qq, &eo, &E);
    if (E.longest.set && E.longest.nseq > 0) {
      int n1 = step(x, cur, MK_SWAP, CR(E.longest.seq[0]), CC(E.longest.seq[0]), 0);
      if (liveNode(x, n1)) { cur = n1; pressed++; continue; }
    }
    cur = step(x, cur, MK_LONG, 0, 0, 6);
  }
  { Board *eb = liveNode(x, cur) ? ensureBoard(x, cur) : 0; out[3] = eb ? panelsOn(eb) : -1; }
  out[2] = best; out[4] = pressed;
  return 0;
}
// THE LINE IN PROGRESS PAST THE DECISION'S CLOCK (gb_replay_on, after a replay of the board before): the next board of the same game
// answered as the game goes on -- the line the replay played in hand, its first swap pressed -- with `work` of a decision's time and the
// move's own frame not yet come. Bit 0: a line was in hand; bit 1: the decision's clock went out with lines judged in time (no rescue);
// bit 2: the line in hand was let go unread, the clock stopping its judge -- decide.c ranked
static int frameNotCome(void) { return 0; }
EXPORT(gb_replay_on) int gb_replay_on(int nbytes, int narr, int mode, int64_t work) {
  int held = carryHeld();
  if (gb_question_bytes(nbytes, narr) != 0) return -1;
  modeRule = mode;
  curQid = abortId + 1;
  int32_t rescued0 = rescues;
  replayWork = work; clockNowOf = replayNow; clockFrameOut = frameNotCome; clockWork = 0;
  int topped = fullTop(hostBoard) >= hostBoard->height;
  int32_t taps = hostTaps; if (replayAllow >= 0) hostTaps = 1;
  answerQuestion(2, 0, topped, 0, 0, 0, 0, 0, 0, replayAllow >= 0, imax(0, replayAllow), 1, 1, 0, REPLAY_MS, 0, 0);
  hostTaps = taps;
  int out = clockWentOut != 0 && rescues == rescued0;
  clockNowOf = 0; clockFrameOut = 0;
  return (held ? 1 : 0) | (out ? 2 : 0) | (held && carryDrop == 2 && carryLate ? 4 : 0);
}
// THE LINE IN PROGRESS, THE WINDOW SHORT (gb_carry_short, after a replay): the board just answered with the swaps `rest` in hand as
// the line in progress, each due as soon as the one before is pressed -- carriedCand's answer: the swaps of it offered (0: let go
// whole), -1 no board or no bottom-row panel to anchor it
EXPORT(gb_carry_short) int gb_carry_short(const int32_t *rest, int n) {
  Read R; Cand k; int wait;
  if (!readBoard_(&R) || n < 1 || n > MAXLINE) return -1;
  int32_t row1[W + 2]; for (int c = 1; c <= W; c++) row1[c] = decQ.b->p[1][c].f[ID];
  Carry *C = &theCarry; memset(C, 0, sizeof *C);
  if (!anchorOf(row1, rest, n)) return -1;
  C->set = 1; C->id = carryFrom; carryPressed = 0; carryMoveOff = 0; C->nrest = n; C->rule = R.rule;
  for (int i = 0; i < n; i++) C->rest[i] = rest[i];
  clockIgnore = 1;
  int got = carriedCand(&R, &k, &wait) ? k.nseq : 0;
  clockIgnore = 0;
  return got;
}
// THE SPEND BESIDE WHAT IS KEPT (gb_spend_first, after a replay): two lines of the board just answered, judged as the decision judges a
// line, and the order put on the two. `keep`: none (nkeep 0) the decision's hold; else a break the break search found on the board,
// firing `keepAt` frames on. `spend`: a line of the game's own that clears panels for a later loss. 1 the spend is put first, 0 the
// keep, -1 a line that does not judge
// (gb_spend_toward 1: the spend is judged as the toward line it was played as, not as a survival line)
static int spendToward;
// (and with it, the digs let off the reserve: the toward judged digs for a break under garbage with none offered, the hold standing a
// break's time or more and the window it leaves under a break's walk now and when the next block can land, yet is found not to spend
// the reserve -- rank.c digPaid)
static int digFree;
EXPORT(gb_dig_free) int gb_dig_free(void) { int n = digFree; digFree = 0; return n; }
EXPORT(gb_spend_toward) void gb_spend_toward(int on) { spendToward = on; }
EXPORT(gb_spend_first) int gb_spend_first(const int32_t *keep, int nkeep, int keepAt, const int32_t *spend, int nspend) {
  static Judge K, Sp; Cand c; Read R;
  if (!readBoard_(&R)) return -1;
  const Judge *k = 0;
  clockIgnore = 1;
  // (the two lines are judged on the logged board, not after the replay's own answer: the swap-back record that answer left is lifted)
  Back back = theBack; int32_t ra = refusedA, rb = refusedB; memset(&theBack, 0, sizeof theBack); refusedA = refusedB = 0;
  int ok = 1;
  if (!nkeep) { for (int i = 0; i < orderN && !k; i++) if (order[i]->hold) k = order[i]; ok = k != 0; }
  else {
    ok = candOf(&c, PLAY_BREAKSEARCH, keep, nkeep, -1, 0);
    if (ok) { c.x.broke = W; c.xDone = c.xFire = keepAt; c.settled = 0; ok = judgeWalkedIn(&R, &c, &K, c.nseq); }
    if (ok) { readyNextFor(&K); k = &K; }
  }
  if (ok) ok = candOf(&c, spendToward ? PLAY_TOWARD : PLAY_SURVIVE, spend, nspend, -1, 0);
  if (ok) { c.settled = 0; ok = judgeWalkedIn(&R, &c, &Sp, c.nseq); }
  if (ok) readyNextFor(&Sp);
  if (ok && spendToward && decF.under && !breakOffered && digsForBreak(&Sp) && rankHold && !rankHold->o.dead && !rankHold->o.lives &&
      diesAt(rankHold) >= rankSave && allowAtNeed(lineWalk(&Sp)) < BREAK_WALK && allowAtLanding(lineWalk(&Sp)) < BREAK_WALK && !spendsReserve(&Sp)) digFree++;
  clockIgnore = 0;
  int r = ok ? compareJudged(&Sp, k) < 0 : -1;
  theBack = back; refusedA = ra; refusedB = rb;
  return r;
}
// THE WAIT'S WINDOW (gb_wait_last, after a replay): the decision was made in the wait with the hold's own board standing a break's
// time (which 0), and the line the order puts first breaks nothing, leaves the window under a break's walk at rest and, its walk
// charged, is lost sooner than the hold (which 1): a walk the break at rest is not pressed after -- rank.c walkTurns
// THE FLIPS KEYED AS JUDGED (gb_flips_late, after a replay): the order's first line that is no hold, with a swap and its swap back put
// before it and every swap left due past the board's life, so the swaps left without the flips cannot be keyed as judged -- the line
// is played as judged (1), something else (2), or the hold (0); -1 none to try -- decide.c playOf
#define FLIPS_FAR 100000   // (frames past any board's life: the swaps left are due where no board stands)
EXPORT(gb_flips_late) int gb_flips_late(void) {
  Read R; if (!readBoard_(&R)) return -1;
  const Judge *T = 0;
  for (int i = 0; i < orderN && !T; i++) if (!order[i]->hold && !order[i]->o.dead && order[i]->k.nseq >= 1 && order[i]->k.nseq + 2 <= MAXLINE) T = order[i];
  if (!T) return -1;
  static Judge L; L = *T;
  L.k.seq[0] = L.k.seq[1] = T->k.seq[0];
  for (int q = 0; q < T->k.nseq; q++) L.k.seq[q + 2] = T->k.seq[q];
  L.k.nseq = T->k.nseq + 2; L.o.j.noops = 2; L.wait = 0;
  L.apNats = L.k.nseq; for (int q = 0; q < L.k.nseq; q++) L.apAts[q] = FLIPS_FAR;
  const Judge *first = order[0]; order[0] = &L;
  Played P = playOf(&R, 1);
  order[0] = first;
  return P.line == &L ? 1 : P.line ? 2 : 0;
}
// THE LINE THAT OUTLIVES THE HOLD (gb_reason_keeps, after a replay): the order's hold, and its first line that is no hold made lost
// SPAN frames past the hold, its walk charged, then lost on the hold's frame -- 1 where the first is kept and the second gives way to
// the hold, 0 otherwise, -1 none to try -- answer.c outlivesHold
EXPORT(gb_reason_keeps) int gb_reason_keeps(int span) {
  const Judge *H = 0, *T = 0;
  for (int i = 0; i < orderN; i++) { if (order[i]->hold) { if (!H) H = order[i]; } else if (!T && !order[i]->o.dead) T = order[i]; }
  if (!H || !T || H->o.dead || H->o.lives || H->o.lostAt == NOT_ASKED) return -1;
  static Judge L; L = *T; L.o.lives = 0; L.idle = 0; L.extLost = NOT_ASKED;
  L.o.lostAt = H->o.lostAt + span + WALK_FRAMES * lineWalk(&L);
  int keeps = outlivesHold(&L, H);
  L.o.lostAt = H->o.lostAt;
  int gives = !outlivesHold(&L, H);
  return keeps && gives;
}
// THE REACH (gb_reach_last, after a replay): the lines the order kept that walk the cursor past REACH_STEPS between swaps, whatever the
// board -- decide.c farForNothing
EXPORT(gb_reach_last) int gb_reach_last(void) {
  int far = 0;
  for (int i = 0; i < orderN; i++) far += farForNothing(order[i]);
  return far;
}
// THE NEXT BLOCK'S RESERVE (gb_over_last, after a replay): the lines the order kept that spend what the next break needs -- panels under
// the floor or the window under a break's walk, breaking nothing, the hold standing a break's time -- decide.c overspends
EXPORT(gb_over_last) int gb_over_last(void) {
  int over = 0;
  for (int i = 0; i < orderN; i++) over += overspends(order[i]);
  return over;
}
// NO FLIP AND BACK ACROSS DECISIONS (gb_undo_cut, after a replay): the order's first line that is no hold and does not live made the
// one that swaps straight back the swap just pressed -- its first swap's two panels named as that swap left them -- and the order cut as
// the decision cuts it: 1 where it is taken out, 0 kept, -1 none to try -- decide.c undoesLast
EXPORT(gb_undo_cut) int gb_undo_cut(void) {
  const Judge *T = 0, *H = 0;
  for (int i = 0; i < orderN; i++) { if (order[i]->hold) { if (!H) H = order[i]; } else if (!T && !order[i]->o.lives && !order[i]->o.dead && order[i]->k.nseq >= 1) T = order[i]; }
  if (!T || !H) return -1;
  int r = CR(T->k.seq[0]), c = CC(T->k.seq[0]);
  if (r < 0 || r >= decQ.b->nrows || c < 1 || c + 1 > W) return -1;
  undoIdL = decQ.b->p[r][c].f[ID]; undoIdR = decQ.b->p[r][c + 1].f[ID]; undoFresh = 1;
  if (!(undoIdL > 0 || undoIdR > 0)) { undoFresh = 0; return -1; }
  static Judge *ord[512]; int n = 0; for (int i = 0; i < orderN && n < 512; i++) ord[n++] = (Judge *)order[i];
  int32_t cut = 0; int m = cutAlways(ord, n, undoesLast, &cut, 29);
  undoFresh = 0;
  int kept = 0; for (int i = 0; i < m; i++) kept |= ord[i] == T;
  return !kept;
}
// (whether walks are ever held: core/nodes.h NO_DAS -- the held-keys check asks none then)
EXPORT(gb_no_das) int gb_no_das(void) { return NO_DAS; }
EXPORT(gb_wait_last) int gb_wait_last(int which) {
  const Judge *H = 0; for (int i = 0; i < orderN && !H; i++) if (order[i]->hold) H = order[i];
  if (!H || waitOf() <= 0 || rankHoldOwn < rankSave) return 0;
  if (!which) return 1;
  const Judge *J = order[0];
  return !J->hold && !J->idle && waitSpends(J) && lostOf(J) < lostOf(H);
}
