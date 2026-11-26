// GAMBIT'S C CHECKS (./build.sh test), on Gambit's own games:
//   - the board as bits held to the cells it replaced, on boards of games and the boards one and two swaps from them (test/boards.txt);
//     every perched block the reader finds, its line played on the engine, counted by whether its block came down;
//     the line that lets the garbage down off its tallest column, played on the engine, counted by whether the garbage is nearer coming down;
//   - the decision replayed (test/decisions.txt.gz: questions from runs on the fair board, a mode each): each answered twice, the same
//     answer both times, and against test/decisions.golden -- every question whose answer moved printed, with what decided it;
//   - the answers: every mode answered, and when any candidate lives, what is played lives (or is the raise);
//   - the raise: each mode's boards cut to a low stack with nothing on it or on its way are raised, and the raise held down.
//   the rules every decision is replayed on: test/rules.words (words.js, the finish profile; its mode set a question at a time).
//   test DIR [golden|speed]: "golden" writes test/decisions.golden from this build; "speed" is the wall-clock check (speed()).
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <zlib.h>
int32_t *gb_io(void);
int gb_question_bytes(int nbytes, int narr);
int gb_bits_agree(void);
int gb_bits_boards(void);
int gb_perch_counts(int which);
int gb_let_counts(int which);
double gb_bits_ms(int cells);
int gb_replay(int nbytes, int narr, int mode, int64_t work, char *out, int cap);
void gb_replay_last(int32_t *v);
void gb_replay_low(int keep);
void gb_replay_raise(int on);
int gb_front_raise(int32_t *out);
int gb_carry_short(const int32_t *rest, int n);
void gb_replay_allow(int allow);
int gb_wait_last(int which);
void gb_replay_enemy(int top, int out, int stop);
void gb_replay_ages(const int32_t *ages, int n);
int gb_spend_first(const int32_t *keep, int nkeep, int keepAt, const int32_t *spend, int nspend);
int gb_replay_on(int nbytes, int narr, int mode, int64_t work);
int gb_line_agree(int *n);
int gb_held_off(int *held, int *offCell);
const char *gb_line_shown(void);
int gb_front_sim(int frames, int msPerFrame, int mode, int32_t *out);
int gb_frames(int mr, int mc, int frames, int32_t *out);
int gb_clock_work(void);
int gb_switch_check(int games, int frames, int min, int max, int32_t *counts, int *nrules);
int gb_opening_check(int nbytes, int ms, int32_t *out); void gb_opening_lower(int on);
int gb_design_check(int n, int rows, int colours, int ms, unsigned seed, int32_t *out);
int gb_design_engine(int nbytes, int rows, int colours, int ms, unsigned seed, int32_t *out);
void gb_design_skill(int on, int ms);
int gb_puzzle_engine(int nbytes, const char *rows, int ms, int32_t *out);
void gb_puzzle_opts(int width, int depth);
void paThreadId(int id);
int gn_setup(int reaction, int swapGap, int cursor, int ahead, int gap, int jitter, int planHealth, const char *logPath);
int32_t *gn_io(void);
int gn_rules(int n);
void gn_rule_name(int i, const char *name);
void gn_profile(int mode, int ms, int extendMs, int width, int depth, int pool, int extendDepth, int extendOff);
#define REPLAY_WORK 20000   // a decision's work in the replay: engine frames, as step() charges them
#define WAIT_WORK 4   // the decisions' work the wait's boards are answered with: the lines that walk the window out are found from two
static int b64v(int ch) { return ch >= 'A' && ch <= 'Z' ? ch - 'A' : ch >= 'a' && ch <= 'z' ? ch - 'a' + 26 : ch >= '0' && ch <= '9' ? ch - '0' + 52 : ch == '+' ? 62 : ch == '/' ? 63 : -1; }
// a GAMBITB line's board into the io, its arrivals after it: the bytes, *narr
static int loadLine(const char *line, int *narr) {
  const char *p = strchr(line, ':');
  if (!p) return -1;
  unsigned char *out = (unsigned char *)gb_io();
  int n = 0, v = 0, bits = 0;
  for (p++; *p && *p != ' ' && *p != '\n'; p++) { int d = b64v(*p); if (d < 0) continue; v = v << 6 | d; bits += 6; if (bits >= 8) { bits -= 8; out[n++] = (unsigned char)(v >> bits & 255); } }
  int32_t *a = gb_io() + (n + 3) / 4;
  *narr = 0;
  const char *q = strstr(p, "[[");
  if (q) for (q++; *q == '['; ) { int at, w, h; if (sscanf(q, "[%d,%d,%d]", &at, &w, &h) != 3) break; a[3 * *narr] = at; a[3 * *narr + 1] = w; a[3 * *narr + 2] = h; (*narr)++; q = strchr(q, ']'); if (!q) break; q++; if (*q == ',') q++; }
  return n;
}
static int loadWords(const char *path) {
  FILE *f = fopen(path, "r");
  if (!f) return 0;
  static char line[1 << 20];
  int setup[8] = { 0 }, profile[9] = { 0 }, nrules = -1, have = 0;
  while (fgets(line, sizeof line, f)) {
    char *rest = strchr(line, ' ');
    if (!rest) continue;
    *rest++ = 0;
    if (!strcmp(line, "setup")) { sscanf(rest, "%d %d %d %d %d %d %d", &setup[0], &setup[1], &setup[2], &setup[3], &setup[4], &setup[5], &setup[6]); have |= 1; }
    else if (!strcmp(line, "profile")) { sscanf(rest, "%d %d %d %d %d %d %d %d", &profile[0], &profile[1], &profile[2], &profile[3], &profile[4], &profile[5], &profile[6], &profile[7]); have |= 2; }
    else if (!strcmp(line, "name")) { int i; char nm[64]; if (sscanf(rest, "%d %63[^\n]", &i, nm) == 2) gn_rule_name(i, nm); }
    else if (!strcmp(line, "rules")) {
      char *s = rest; int len;
      nrules = (int)strtol(s, &s, 10); len = (int)strtol(s, &s, 10);
      int32_t *io = gn_io();
      for (int i = 0; i < len; i++) io[i] = (int32_t)strtol(s, &s, 10);
      have |= 4;
    }
  }
  fclose(f);
  if (have != 7) return 0;
  gn_setup(setup[0], setup[1], setup[2], setup[3], setup[4], setup[5], setup[6], "");
  if (gn_rules(nrules) != nrules) return 0;
  paThreadId(0);   // (the checks answer on this thread, as Gambit's own does: the engine's thread 0 -- gn_setup made it the game's)
  gn_profile(profile[0], profile[1], profile[2], profile[3], profile[4], profile[5], profile[6], profile[7]);
  return 1;
}
// THE SPEED (test DIR speed): the first SPEEDQ questions answered each in the wall clock's REPLAY_MS, as a game gives it -- the engine's
// work done a decision (frames stepped), on the threads the host started (GC_GAMBIT_WORKERS)
#define SPEEDQ 60
static int speed(const char *dir) {
  char path[4096]; static char line[1 << 17], rec[4096];
  snprintf(path, sizeof path, "%s/rules.words", dir);
  if (!loadWords(path)) return 1;
  snprintf(path, sizeof path, "%s/decisions.txt.gz", dir);
  gzFile z = gzopen(path, "r");
  if (!z) return 2;
  long long work = 0; int nq = 0;
  while (nq < SPEEDQ && gzgets(z, line, sizeof line)) {
    int mode = atoi(line);
    const char *b = strstr(line, "GAMBITQ ");
    if (!b) b = strstr(line, "GAMBITB ");
    if (!b) continue;
    int narr, n = loadLine(b, &narr);
    if (n < 0 || gb_replay(n, narr, mode, 0, rec, sizeof rec) < 0) continue;
    work += gb_clock_work(); nq++;
  }
  gzclose(z);
  printf("speed: %d decisions in the wall clock's time, %lld frames stepped a decision\n", nq, nq ? work / nq : 0);
  return 0;
}
// THE OPENING PLANNED (test DIR opening, its own process: no other thread has run on the boards' pools): the first boards of the
// games, each grown 300 ms -- a plan found on every one, on every thread there is
static int opening(const char *dir) {
  char path[4096]; static char line[1 << 17]; int fail = 0;
  snprintf(path, sizeof path, "%s/rules.words", dir);
  if (!loadWords(path)) { fprintf(stderr, "test: %s is not a whole profile\n", path); return 1; }
  { snprintf(path, sizeof path, "%s/boards.txt", dir); FILE *o = fopen(path, "r"); int tried = 0, found = 0, lv = 0, most = 0;
    while (o && tried < 6 && fgets(line, sizeof line, o)) {
      if (strncmp(line, "GAMBITB ", 8) && strncmp(line, "GAMBITO ", 8)) continue;
      int narr, n = loadLine(line, &narr); int32_t r[6];
      if (n < 0 || gb_opening_check(n, 300, r) != 0) continue;
      printf("  opening: plan of %d set-ups, scored %d cells; played back %d cells; judged chain %d combo %d\n", r[1], r[2], r[3], r[4], r[5]);
      if (getenv("GC_OPENING_WHOLE")) {
        int32_t w[6];
        gb_opening_lower(0);
        n = loadLine(line, &narr);
        if (n >= 0 && gb_opening_check(n, 300, w) == 0)
          printf("  opening, the board whole: plan of %d set-ups, scored %d cells; played back %d cells; judged chain %d combo %d\n", w[1], w[2], w[3], w[4], w[5]);
        gb_opening_lower(1);
      }
      tried++; found += r[1] >= 0; lv += r[0]; if (r[2] > most) most = r[2];
    }
    if (o) fclose(o);
    printf("%s: the opening planned -- %d of %d boards with a plan, %d levels grown in all, the best sending %d cells\n", tried && found ? "ok" : "FAIL", found, tried, lv, most);
    fail |= !tried || !found; }
  return fail;
}
// THE LOSS REPLAYED (test DIR replay LOG MODE): each of a game's last boards (GAMBITL) answered at half, once, twice and four times a
// decision's work -- whether the answer, and the break it plays, waits on the time the decision had
static int replayLoss(const char *dir, const char *log, int mode) {
  char path[4096]; static char line[1 << 17], rec[4096];
  snprintf(path, sizeof path, "%s/rules.words", dir);
  if (!loadWords(path)) { fprintf(stderr, "test: %s is not a whole profile\n", path); return 1; }
  FILE *f = fopen(log, "r");
  if (!f) return 2;
  static const int mult[4] = { 1, 2, 4, 8 };
  while (fgets(line, sizeof line, f)) {
    const char *b = strstr(line, "GAMBITL ");
    if (!b) continue;
    int at = atoi(b + 8);
    for (int m = 0; m < 4; m++) {
      int narr, n = loadLine(b, &narr);
      if (n < 0 || gb_replay(n, narr, mode, (int64_t)REPLAY_WORK * mult[m] / 2, rec, sizeof rec) < 0) { printf("%d x%.1f: does not load\n", at, mult[m] / 2.0); break; }
      printf("%d x%.1f: %s\n", at, mult[m] / 2.0, rec);
    }
  }
  fclose(f);
  return 0;
}
// THE LATER LOSS BOUGHT (test DIR spend, its own process: the game's own profile, wait.words): boards of games on which a line that
// clears panels and breaks nothing was played for its later loss (spend.txt: the mode, the enemy's top row / topped out / stop time
// -- a top under 0: none --, what is kept, the line that spends, the frames ago each key inside the input window went down, the board). Kept is `-`, the hold, on a board in the wait whose
// window the spend walks out; or a break the break search finds on the board, with the frames on it fires after `@`, which leaves the
// board a break's time. A live game's boards are built from its replay page's frames, the others are the games' own dumps. Each board is answered as its game asked it and the two lines judged on it: the spend is never put first --
// rank.c waitSpent, boughtWithPanels
static int seqOf(const char *s, int32_t *out, int cap) {
  int n = 0;
  while (s && *s && *s != '@' && n < cap) { int r = atoi(s); const char *c = strchr(s, ','); if (!c) return 0; out[n++] = r * 8 + atoi(c + 1); s = strchr(s, ';'); if (s) s++; }
  return n;
}
static int spendKeptOn(const char *dir, const char *file, const char *what) {
  char path[4096]; static char line[1 << 17], rec[4096];
  snprintf(path, sizeof path, "%s/wait.words", dir);
  if (!loadWords(path)) { fprintf(stderr, "test: %s is not a whole profile\n", path); return 1; }
  snprintf(path, sizeof path, "%s/%s", dir, file);
  FILE *f = fopen(path, "r");
  if (!f) { fprintf(stderr, "test: no %s\n", path); return 2; }
  int boards = 0, first = 0, unjudged = 0;
  while (fgets(line, sizeof line, f)) {
    int mode, top, out, stop; char keep[256], spend[256]; static char aged[2048];
    const char *b = strstr(line, "GAMBITL ");
    if (!b || sscanf(line, "%d %d/%d/%d %255s %255s %2047s", &mode, &top, &out, &stop, keep, spend, aged) != 7) continue;
    int narr, n = loadLine(b, &narr);
    const char *al = strstr(b, "] a");
    gb_replay_allow(al ? atoi(al + 3) : -1); gb_replay_enemy(top, out, stop);
    { int32_t ages[512]; int na = 0; for (const char *q = aged; *q && na < 512; ) { ages[na++] = atoi(q); q = strchr(q, ','); if (!q) break; q++; } gb_replay_ages(ages, na); }
    if (n < 0 || gb_replay(n, narr, mode, (int64_t)REPLAY_WORK * WAIT_WORK, rec, sizeof rec) < 0) continue;
    int32_t ks[64], ss[64]; int nk = keep[0] == '-' ? 0 : seqOf(keep, ks, 64), ns = seqOf(spend, ss, 64);
    const char *at = strchr(keep, '@');
    int r = gb_spend_first(ks, nk, at ? atoi(at + 1) : -1, ss, ns);
    boards++;
    if (r < 0) { unjudged++; printf("  a line that does not judge (board %d)\n", atoi(b + 8)); }
    if (r > 0) { first++; printf("  the spend put first (board %d, mode %d): %s over %s\n", atoi(b + 8), mode, spend, keep[0] == '-' ? "the hold" : keep); }
  }
  fclose(f);
  gb_replay_enemy(-1, 0, 0);
  printf("%s: %s -- %d boards, the spend put first on %d\n", first || unjudged || !boards ? "FAIL" : "ok", what, boards, first);
  return first || unjudged || !boards;
}
static int spendKept(const char *dir) { return spendKeptOn(dir, "spend.txt", "the later loss bought"); }
// THE WINDOW THAT LEAVES NO BREAK (test DIR windead, its own process, as spend: windead.txt): boards of games lost with the window
// spent, each with a line that leaves the next break its walk within its own life (keep) and a later loss whose walk leaves no break's
// walk in the window before its board is lost (spend) -- the spend, lost sooner with its walk charged, is never put first: rank.c
// windowDead, walkTurns
static int windowKept(const char *dir) { return spendKeptOn(dir, "windead.txt", "the window that leaves no break"); }
// THE WALK FOR NOTHING (test DIR toward, its own process, as spend: toward.txt): boards under garbage where a set-up that breaks none of
// it, lost on the hold's frame, was put first for the mode's goal (the spend judged as the toward it was) -- the hold is kept: rank.c
// goalKeyUnder. And no such toward, digging for a break with the hold standing a break's time, is let spend the next break's reserve:
// rank.c digPaid
void gb_spend_toward(int on);
int gb_dig_free(void);
static int towardKept(const char *dir) {
  gb_dig_free(); gb_spend_toward(1); int r = spendKeptOn(dir, "toward.txt", "the walk for nothing"); gb_spend_toward(0);
  int freed = gb_dig_free();
  printf("%s: the dig that keeps no reserve -- %d digs let spend the next break's window with the hold standing a break's time\n", freed ? "FAIL" : "ok", freed);
  return r || freed;
}
int gb_cells(void);
// THE BOARD DRAWN (test DIR board LOG FRAME): the logged board (GAMBITL, GAMBITQ...) of that frame, top row first -- a colour's digit,
// garbage G, empty '.', a dimmed (rising) row in lower case; then the garbage on its way
static int drawBoard(const char *log, int frame) {
  FILE *f = fopen(log, "r");
  if (!f) return 2;
  static char line[1 << 17];
  while (fgets(line, sizeof line, f)) {
    const char *b = strstr(line, "GAMBITL "); if (!b) b = strstr(line, "GAMBITQ "); if (!b) b = strstr(line, "GAMBITB "); if (!b) continue;
    if (atoi(b + 8) != frame) continue;
    int narr, n = loadLine(b, &narr);
    if (n < 0 || gb_question_bytes(n, narr) != 0) continue;
    int k = gb_cells(); int32_t *v = gb_io();
    int rows = v[0];
    printf("frame %d: %d rows, stop %d, shake %d\n", frame, rows, v[1], v[2]);
    for (int r = rows - 1; r >= 0; r--) {
      printf("%2d ", r);
      for (int c = 1; c <= 6; c++) { int o = 3 + (r * 6 + c - 1) * 3, col = v[o], g = v[o + 1]; printf("%c", g ? 'G' : col == 0 ? '.' : col >= 1 && col <= 9 ? '0' + col : '?'); }
      printf("\n");
    }
    const char *a = strstr(b, " ["); if (a) printf("on its way: %.200s", a);
    (void)k; fclose(f); return 0;
  }
  fclose(f); printf("no board at %d\n", frame); return 1;
}
// THE WAIT'S WINDOW (test DIR wait, its own process: the game's own profile, wait.words -- a combo of six is finish them's there):
// boards of games in the wait -- a slab popping, no break offered -- answered with the allowance the game gave and WAIT_WORK
// decisions' work, the lines that walk the window out found: none is played that breaks nothing, leaves the window under a break's
// walk at rest and, its walk charged, is lost sooner than the hold -- rank.c walkTurns
static int waitWindow(const char *dir) {
  char path[4096]; static char line[1 << 17], rec[4096];
  snprintf(path, sizeof path, "%s/wait.words", dir);
  if (!loadWords(path)) { fprintf(stderr, "test: %s is not a whole profile\n", path); return 1; }
  snprintf(path, sizeof path, "%s/wait.txt", dir);
  FILE *f = fopen(path, "r");
  if (!f) { fprintf(stderr, "test: no %s\n", path); return 2; }
  int waits = 0, spent = 0;
  while (fgets(line, sizeof line, f)) {
    int mode = atoi(line);
    const char *b = strstr(line, "GAMBITL ");
    if (!b) continue;
    int narr, n = loadLine(b, &narr);
    const char *al = strstr(b, "] a");
    gb_replay_allow(al ? atoi(al + 3) : -1);
    if (n < 0 || gb_replay(n, narr, mode, (int64_t)REPLAY_WORK * WAIT_WORK, rec, sizeof rec) < 0) continue;
    if (!gb_wait_last(0)) continue;
    waits++;
    if (gb_wait_last(1)) { spent++; printf("  the window walked out in the wait (mode %d): %s\n", mode, rec); }
  }
  fclose(f);
  printf("%s: the wait's window -- %d boards in the wait, %d walked the window out for no break\n", spent || !waits ? "FAIL" : "ok", waits, spent);
  return spent || !waits;
}
// THE FLIPS KEYED AS JUDGED (test DIR flips, its own process: the game's own profile, wait.words): boards where the line put first
// swaps a pair and straight back, and the swaps left without the flips could not be keyed as judged (flips.txt: the mode, the enemy
// TOP/OUT/STOP, the ages of the presses in the window, then the board with the allowance the game gave). Each is answered with
// WAIT_WORK decisions' work, then its first line is put first with a swap and its swap back before it and the swaps left due past the
// board's life: the line is played as judged, never the hold in its place -- decide.c playOf (gb_flips_late)
int gb_flips_late(void);
static int flipsKeyed(const char *dir) {
  char path[4096]; static char line[1 << 17], rec[4096];
  snprintf(path, sizeof path, "%s/wait.words", dir);
  if (!loadWords(path)) { fprintf(stderr, "test: %s is not a whole profile\n", path); return 1; }
  snprintf(path, sizeof path, "%s/flips.txt", dir);
  FILE *f = fopen(path, "r");
  if (!f) { fprintf(stderr, "test: no %s\n", path); return 2; }
  int boards = 0, held = 0;
  while (fgets(line, sizeof line, f)) {
    int mode, top, out, stop; static char aged[4096];
    const char *b = strstr(line, "GAMBITL ");
    if (!b || sscanf(line, "%d %d/%d/%d %4095s", &mode, &top, &out, &stop, aged) != 5) continue;
    int narr, n = loadLine(b, &narr);
    const char *al = strstr(b, "] a");
    gb_replay_allow(al ? atoi(al + 3) : -1); gb_replay_enemy(top, out, stop);
    { int32_t ages[512]; int na = 0; for (const char *q = aged; *q && na < 512; ) { ages[na++] = atoi(q); q = strchr(q, ','); if (!q) break; q++; } gb_replay_ages(ages, na); }
    int r = n < 0 ? -1 : gb_replay(n, narr, mode, (int64_t)REPLAY_WORK * WAIT_WORK, rec, sizeof rec);
    gb_replay_enemy(-1, 0, 0);
    if (r < 0) continue;
    boards++;
    int k = gb_flips_late();
    if (k < 0) { boards--; continue; }
    if (k == 0) { held++; printf("  the hold played for a line whose swaps left could not be keyed as judged (board %d)\n", atoi(b + 8)); }
  }
  fclose(f);
  printf("%s: the flips keyed as judged -- %d boards, %d held\n", held || !boards ? "FAIL" : "ok", boards, held);
  return held || !boards;
}
// THE LINE THAT OUTLIVES THE HOLD (test DIR reason, its own process: the game's own profile, wait.words): boards where the line put
// first had no named reason and nothing after it had one, and the hold played in its place was lost first (reason.txt: the mode, the
// enemy TOP/OUT/STOP, the ages of the presses in the window, then the board with the allowance the game gave). Each is answered with
// WAIT_WORK decisions' work, then its first line made lost REASON_SPAN frames past the hold, its walk charged: that line is kept, and
// one lost on the hold's frame gives way to it -- answer.c outlivesHold (gb_reason_keeps)
int gb_reason_keeps(int span);
#define REASON_SPAN 435   // (frames the line outlived the hold by on the board it was lost on: factory 8, fill, 3331 -- 540 against 105)
static int reasonKept(const char *dir) {
  char path[4096]; static char line[1 << 17], rec[4096];
  snprintf(path, sizeof path, "%s/wait.words", dir);
  if (!loadWords(path)) { fprintf(stderr, "test: %s is not a whole profile\n", path); return 1; }
  snprintf(path, sizeof path, "%s/reason.txt", dir);
  FILE *f = fopen(path, "r");
  if (!f) { fprintf(stderr, "test: no %s\n", path); return 2; }
  int boards = 0, held = 0;
  while (fgets(line, sizeof line, f)) {
    int mode, top, out, stop; static char aged[4096];
    const char *b = strstr(line, "GAMBITL ");
    if (!b || sscanf(line, "%d %d/%d/%d %4095s", &mode, &top, &out, &stop, aged) != 5) continue;
    int narr, n = loadLine(b, &narr);
    const char *al = strstr(b, "] a");
    gb_replay_allow(al ? atoi(al + 3) : -1); gb_replay_enemy(top, out, stop);
    { int32_t ages[512]; int na = 0; for (const char *q = aged; *q && na < 512; ) { ages[na++] = atoi(q); q = strchr(q, ','); if (!q) break; q++; } gb_replay_ages(ages, na); }
    int r = n < 0 ? -1 : gb_replay(n, narr, mode, (int64_t)REPLAY_WORK * WAIT_WORK, rec, sizeof rec);
    gb_replay_enemy(-1, 0, 0);
    if (r < 0) continue;
    boards++;
    int k = gb_reason_keeps(REASON_SPAN);
    if (k < 0) { boards--; continue; }
    if (!k) { held++; printf("  the hold played for a line that outlives it (board %d)\n", atoi(b + 8)); }
  }
  fclose(f);
  printf("%s: the line that outlives the hold -- %d boards, %d held\n", held || !boards ? "FAIL" : "ok", boards, held);
  return held || !boards;
}
int gb_reach_last(void);
int gb_over_last(void);
int gb_no_das(void);
int gb_undo_cut(void);
// THE LINE IN PROGRESS, THE CLOCK OUT (test DIR carry, its own process: the game's own profile, wait.words): pairs of boards a decision
// apart, of games whose line in progress was let go with the decision's clock out (carry.txt: the mode, then the board; two lines a
// pair). The first is answered with CARRY_WORK decisions' work, the second as the same game going on with the line played in hand, at
// each share of a decision's work in CARRY_SHARES: where the clock goes out with lines judged in time, the line in hand is judged all
// the same, never let go unread
#define CARRY_WORK 4
static int carryClock(const char *dir) {
  char path[4096]; static char line[1 << 17], rec[4096];
  snprintf(path, sizeof path, "%s/wait.words", dir);
  if (!loadWords(path)) { fprintf(stderr, "test: %s is not a whole profile\n", path); return 1; }
  snprintf(path, sizeof path, "%s/carry.txt", dir);
  static const int CARRY_SHARES[] = { 8, 4, 2, 1 };   // (the second decision's work: a decision's, divided by each)
  int outs = 0, unread = 0, pairs = 0;
  for (unsigned s = 0; s < sizeof CARRY_SHARES / sizeof *CARRY_SHARES; s++) {
    FILE *f = fopen(path, "r");
    if (!f) { fprintf(stderr, "test: no %s\n", path); return 2; }
    int second = 0, ok = 0;
    while (fgets(line, sizeof line, f)) {
      int mode = atoi(line);
      const char *b = strstr(line, "GAMBITL ");
      if (!b) continue;
      int narr, n = loadLine(b, &narr);
      const char *al = strstr(b, "] a");
      gb_replay_allow(al ? atoi(al + 3) : -1);
      if (!second) { ok = n >= 0 && gb_replay(n, narr, mode, (int64_t)REPLAY_WORK * CARRY_WORK, rec, sizeof rec) >= 0; second = 1; continue; }
      second = 0;
      if (!ok || n < 0) continue;
      int r = gb_replay_on(n, narr, mode, REPLAY_WORK / CARRY_SHARES[s]);
      if (r < 0 || !(r & 1)) continue;
      if (!s) pairs++;
      if (r & 2) outs++;
      if (r & 4) { unread++; printf("  the line in hand let go unread, the clock out (board %d, a decision's work / %d)\n", atoi(b + 8), CARRY_SHARES[s]); }
    }
    fclose(f);
  }
  // (THE WINDOW SHORT AT A LATER SWAP: short.txt -- the mode, a line in hand, then the board with the allowance the game gave -- each
  // answered, then asked for the line in progress with that line in hand: its swaps before the walk the window does not hold are
  // offered, never the line let go whole)
  snprintf(path, sizeof path, "%s/short.txt", dir);
  int shorts = 0, whole = 0;
  { FILE *f = fopen(path, "r");
    if (!f) { fprintf(stderr, "test: no %s\n", path); return 2; }
    while (fgets(line, sizeof line, f)) {
      int mode = atoi(line); char hand[256];
      const char *b = strstr(line, "GAMBITL ");
      if (!b || sscanf(line, "%*d %255s", hand) != 1) continue;
      int narr, n = loadLine(b, &narr);
      const char *al = strstr(b, "] a");
      gb_replay_allow(al ? atoi(al + 3) : -1);
      if (n < 0 || gb_replay(n, narr, mode, REPLAY_WORK, rec, sizeof rec) < 0) continue;
      int32_t sq[64]; int ns = seqOf(hand, sq, 64), got = gb_carry_short(sq, ns);
      if (got < 0 || got >= ns) continue;
      shorts++;
      if (!got) { whole++; printf("  the line in hand let go whole, its next swap within the window (board %d)\n", atoi(b + 8)); }
    }
    fclose(f); }
  printf("%s: the line in progress, the window short -- %d lines in hand cut at a later swap, %d let go whole\n", whole || !shorts ? "FAIL" : "ok", shorts, whole);
  printf("%s: the line in progress past the clock -- %d pairs with a line in hand, the clock out with lines judged %d times, the line in hand let go unread %d\n", unread || !outs ? "FAIL" : "ok", pairs, outs, unread);
  return unread || !outs || whole || !shorts;
}
// THE RAISE PRESSED AS ANSWERED (test DIR raise, its own process: the game's own profile, wait.words): boards of games lost to a
// raise, the row partway in when the raise was answered (raise.txt: the mode, then the board). Each is answered, the raise offered, and
// the raise keyed as the frame loop keys it and played: the rows the answer asked come in, none is begun after them, the board stands.
// Answered with RAISE_WORK decisions' work
#define RAISE_WORK 8   // (decisions' work: the least of 2, 4 and 8 at which the replay's clock leaves raise.txt's raise its rows judged)
static int raisePressed(const char *dir) {
  char path[4096]; static char line[1 << 17], rec[4096];
  snprintf(path, sizeof path, "%s/wait.words", dir);
  if (!loadWords(path)) { fprintf(stderr, "test: %s is not a whole profile\n", path); return 1; }
  snprintf(path, sizeof path, "%s/raise.txt", dir);
  FILE *f = fopen(path, "r");
  if (!f) { fprintf(stderr, "test: no %s\n", path); return 2; }
  int raises = 0, over = 0;
  gb_replay_raise(1);
  while (fgets(line, sizeof line, f)) {
    int mode = atoi(line), narr; const char *b = strstr(line, "GAMBITL ");
    if (!b) continue;
    int n = loadLine(b, &narr);
    if (n < 0 || gb_replay(n, narr, mode, (int64_t)REPLAY_WORK * RAISE_WORK, rec, sizeof rec) < 0) continue;
    int32_t v[9], o[4]; gb_replay_last(v);
    if (v[0] != 2 || !gb_front_raise(o)) { printf("  no raise keyed (board %d): %s\n", atoi(b + 8), rec); continue; }
    raises++;
    if (o[2] || o[0] > o[1] || o[3]) { over++; printf("  a raise pressed past its rows (board %d): %d rows in of %d asked, a row begun after them %d, lost %d\n", atoi(b + 8), o[0], o[1], o[2], o[3]); }
  }
  fclose(f);
  printf("%s: the raise pressed as answered -- %d raises keyed, %d pressed past the rows they asked\n", over || !raises ? "FAIL" : "ok", raises, over);
  return over || !raises;
}
int main(int argc, char **argv) {
  const char *dir = argc > 1 ? argv[1] : "test";
  if (argc > 4 && !strcmp(argv[2], "board")) return drawBoard(argv[3], atoi(argv[4]));
  if (argc > 4 && !strcmp(argv[2], "replay")) return replayLoss(dir, argv[3], atoi(argv[4]));
  if (argc > 2 && !strcmp(argv[2], "speed")) return speed(dir);
  if (argc > 2 && !strcmp(argv[2], "opening")) return opening(dir);
  if (argc > 2 && !strcmp(argv[2], "wait")) return waitWindow(dir);
  if (argc > 2 && !strcmp(argv[2], "reason")) return reasonKept(dir);
  if (argc > 2 && !strcmp(argv[2], "flips")) return flipsKeyed(dir);
  if (argc > 2 && !strcmp(argv[2], "windead")) return windowKept(dir);
  if (argc > 2 && !strcmp(argv[2], "toward")) return towardKept(dir);
  if (argc > 2 && !strcmp(argv[2], "carry")) return carryClock(dir);
  if (argc > 2 && !strcmp(argv[2], "raise")) return raisePressed(dir);
  if (argc > 2 && !strcmp(argv[2], "spend")) return spendKept(dir);
  if (argc > 2 && !strcmp(argv[2], "design")) {
    int n = argc > 3 ? atoi(argv[3]) : 6, rows = argc > 4 ? atoi(argv[4]) : 10, cols = argc > 5 ? atoi(argv[5]) : 6, ms = argc > 6 ? atoi(argv[6]) : 2000;
    char path[4096]; snprintf(path, sizeof path, "%s/rules.words", dir); if (!loadWords(path)) return 1;   // (the setup: the workers)
    static int32_t out[4 * 64]; gb_design_check(n, rows, cols, ms, 7, out);
    for (int i = 0; i < n; i++) printf("board %d: chain %d, %d swaps, worth %d, order %d\n", i, out[4 * i], out[4 * i + 1], out[4 * i + 2], out[4 * i + 3]);
    return 0;
  }
  if (argc > 3 && !strcmp(argv[2], "puzzle")) {
    char path[4096]; static char line[1 << 17], pz[4096];
    snprintf(path, sizeof path, "%s/rules.words", dir); if (!loadWords(path)) return 1;
    snprintf(path, sizeof path, "%s/boards.txt", dir); FILE *o = fopen(path, "r"); int nb = -1;
    while (o && fgets(line, sizeof line, o)) { if (!strncmp(line, "GAMBITB ", 8)) { int narr; nb = loadLine(line, &narr); break; } }
    if (o) fclose(o);
    FILE *f = fopen(argv[3], "r"); int ms = argc > 4 ? atoi(argv[4]) : 60;
    gb_puzzle_opts(argc > 5 ? atoi(argv[5]) : 40, argc > 6 ? atoi(argv[6]) : 6);
    static unsigned char saved[1 << 17]; extern int32_t *gb_io(void); memcpy(saved, gb_io(), (size_t)(nb > 0 ? nb : 0));
    while (f && fgets(pz, sizeof pz, f)) {
      char name[256], rows[512]; if (sscanf(pz, "%255s %511s", name, rows) != 2) continue;
      memcpy(gb_io(), saved, (size_t)nb);
      int32_t r[5] = { 0 }; int k = gb_puzzle_engine(nb, rows, ms, r);
      printf("%s: %s alone chain %d, %d panels left; continued chain %d, %d panels left, %d swaps\n", name, k ? "FAIL" : "", r[0], r[1], r[2], r[3], r[4]);
    }
    if (f) fclose(f);
    return 0;
  }
  if (argc > 2 && !strcmp(argv[2], "engine")) {
    int n = argc > 3 ? atoi(argv[3]) : 4, rows = argc > 4 ? atoi(argv[4]) : 10, cols = argc > 5 ? atoi(argv[5]) : 6, ms = argc > 6 ? atoi(argv[6]) : 1000;
    char path[4096]; static char line[1 << 17];
    snprintf(path, sizeof path, "%s/rules.words", dir); if (!loadWords(path)) return 1;
    snprintf(path, sizeof path, "%s/boards.txt", dir); FILE *o = fopen(path, "r"); int done = 0;
    while (o && done < n && fgets(line, sizeof line, o)) {
      if (strncmp(line, "GAMBITB ", 8)) continue;
      int narr, nb = loadLine(line, &narr); int32_t r[8] = { 0 };
      gb_design_skill(argc > 7 ? atoi(argv[7]) : 0, argc > 8 ? atoi(argv[8]) : 60);
      int k = gb_design_engine(nb, rows, cols, ms, 11 + done, r);
      if (k < 0) continue;
      printf("board %d: designed %d links in %d swaps; the engine made a chain of %d, %d panels cleared; stopped at swap %d of %d; continued: chain %d, %d swaps pressed\n", done, r[0], r[1], r[2], r[3], r[4], k, r[5], r[6]);
      done++;
    }
    if (o) fclose(o);
    return 0;
  }
  int golden = argc > 2 && !strcmp(argv[2], "golden"), fail = 0;
  char path[4096];
  static char line[1 << 17];
  // ---- the bits
  snprintf(path, sizeof path, "%s/boards.txt", dir);
  FILE *f = fopen(path, "r");
  if (!f) { fprintf(stderr, "test: no %s\n", path); return 2; }
  int boards = 0, wrong = 0;
  while (fgets(line, sizeof line, f)) {
    if (strncmp(line, "GAMBITB ", 8)) continue;
    int narr, n = loadLine(line, &narr);
    if (n < 0 || gb_question_bytes(n, 0) != 0) { fprintf(stderr, "test: a board that does not load\n"); return 1; }
    wrong = gb_bits_agree(); boards++;
  }
  fclose(f);
  printf("the nearest break, 50 times a board: %.1f ms on the bits, %.1f ms on the cells\n", gb_bits_ms(0), gb_bits_ms(1));
  printf("%s: bits against cells -- %d boards of games, %d boards in all, %d disagreements\n", wrong ? "FAIL" : "ok", boards, gb_bits_boards(), wrong);
  int offered = gb_perch_counts(0), dropped = gb_perch_counts(1);
  printf("%s: perched blocks -- %d lines offered, %d let their block down\n", offered && !dropped ? "FAIL" : "ok", offered, dropped);
  int letOff = gb_let_counts(0), letDown = gb_let_counts(1);
  printf("%s: the garbage let down -- %d lines offered, %d left it nearer coming down a row at rest\n", letOff && !letDown ? "FAIL" : "ok", letOff, letDown);
  fail |= wrong || !boards || (offered && !dropped) || (letOff && !letDown);
  // ---- the decisions
  snprintf(path, sizeof path, "%s/rules.words", dir);
  if (!loadWords(path)) { fprintf(stderr, "test: %s is not a whole profile\n", path); return 1; }
  snprintf(path, sizeof path, "%s/decisions.txt.gz", dir);
  gzFile z = gzopen(path, "r");
  if (!z) { fprintf(stderr, "test: no %s\n", path); return 2; }
  snprintf(path, sizeof path, "%s/decisions.golden", dir);
  FILE *g = fopen(path, golden ? "w" : "r");
  if (!g) { fprintf(stderr, "test: no %s (test DIR golden writes it)\n", path); return 2; }
  static char rec[4096], rec2[4096], want[4096];
  int nq = 0, unsteady = 0, moved = 0, changed = 0, liveDied = 0, sooner = 0, far = 0, over = 0, undoTried = 0, undoKept = 0, lows = 0, lowRaised = 0, raises = 0, raiseHeld = 0, modes[64] = { 0 };
  while (gzgets(z, line, sizeof line)) {
    int mode = atoi(line);
    const char *b = strstr(line, "GAMBITQ ");
    if (!b) b = strstr(line, "GAMBITB ");
    if (!b) continue;
    int narr, n = loadLine(b, &narr);
    if (n < 0 || gb_replay(n, narr, mode, REPLAY_WORK, rec, sizeof rec) < 0) { fprintf(stderr, "test: question %d does not load\n", nq); return 1; }
    // (the answer: when anything lives, what is played lives -- or is the raise; a low stack with nothing on it or on its way is raised;
    // a raise is held down through its row)
    { int32_t v[9]; gb_replay_last(v);
      if (v[2] > 0 && v[0] != 2 && v[1] != 1) { liveDied++; if (liveDied <= 3) printf("  lives but died %d (mode %d): %s\n", nq, mode, rec); }
      if (v[8] && v[0] != 2) { sooner++; if (sooner <= 3) printf("  lost sooner %d (mode %d): %s\n", nq, mode, rec); }
      { int u = gb_undo_cut(); if (u >= 0) { undoTried++; undoKept += !u; } }
      { int k = gb_reach_last(); far += k; if (k && far <= 3) printf("  past the reach %d (mode %d): %s\n", nq, mode, rec); }
      { int o = gb_over_last(); over += o; if (o && over <= 3) printf("  the next block's reserve spent %d (mode %d): %s\n", nq, mode, rec); }
        if (mode >= 0 && mode < 64) modes[mode]++; }
    n = loadLine(b, &narr);
    gb_replay(n, narr, mode, REPLAY_WORK, rec2, sizeof rec2);
    if (strcmp(rec, rec2)) { unsteady++; if (unsteady <= 3) printf("  unsteady %d: %s\n               %s\n", nq, rec, rec2); }
    if (golden) fprintf(g, "%s\n", rec);
    else if (fgets(want, sizeof want, g)) {
      want[strcspn(want, "\n")] = 0;
      if (strcmp(rec, want)) {
        changed++;
        int mv = strncmp(rec, want, (size_t)(strchr(rec, '|') - rec)) != 0;
        if (mv) { moved++; if (moved <= 12) printf("  moved %d (mode %d): was %s\n              now %s\n", nq, mode, want, rec); }
      }
    }
    nq++;
  }
  gzclose(z);
  fclose(g);
  // (the raise: each mode's question boards cut to a low stack with nothing on it or on its way, in a game garbage has reached -- each
  // raised, and held down)
  snprintf(path, sizeof path, "%s/decisions.txt.gz", dir);
  if ((z = gzopen(path, "r"))) {
    gb_replay_low(3);
    int perMode[64] = { 0 };
    while (gzgets(z, line, sizeof line)) {
      int mode = atoi(line);
      if (mode < 0 || mode >= 64 || perMode[mode] >= 4) continue;
      const char *b = strstr(line, "GAMBITQ ");
      if (!b) b = strstr(line, "GAMBITB ");
      if (!b) continue;
      int narr, n = loadLine(b, &narr);
      if (n < 0 || gb_replay(n, narr, mode, REPLAY_WORK, rec, sizeof rec) < 0) continue;
      int32_t v[9]; gb_replay_last(v);
      perMode[mode]++; lows++; lowRaised += v[0] == 2; raises += v[0] == 2; raiseHeld += v[0] == 2 && v[7] > 0;
      if (v[0] != 2 && lows - lowRaised <= 3) printf("  low stack not raised (mode %d): %s\n", mode, rec);
    }
    gb_replay_low(0); gzclose(z);
  }
  // (THE LINE PRESSED AS JUDGED: each question answered again with the input budget tight -- walks held from two cells -- and the line
  // the answer hands on keyed as the frame loop keys it: every swap's keys begin on the frame the judge pressed it from, never later. A
  // swap pressed later is a board the judge never judged: front.c follow, core/nodes.h pressDelay)
  snprintf(path, sizeof path, "%s/decisions.txt.gz", dir);
  if ((z = gzopen(path, "r"))) {
    int compared = 0, late = 0, lines = 0, qi = -1;
    while (gzgets(z, line, sizeof line)) {
      int mode = atoi(line);
      const char *b = strstr(line, "GAMBITQ ");
      if (!b) b = strstr(line, "GAMBITB ");
      if (!b) continue;
      qi++;
      for (int t = 0; t < 3; t++) {
        int narr, n = loadLine(b, &narr), c;
        gb_replay_allow(t == 2 ? 76 : t ? 12 : 30);
        if (n < 0 || gb_replay(n, narr, mode, REPLAY_WORK, rec, sizeof rec) < 0) continue;
        int l = gb_line_agree(&c);
        compared += c; late += l; lines += c > 0;
        if (l && late - l < 3) printf("  pressed later than judged (question %d, allowance %d, mode %d): %s\n    the line (swap@judged/keyed): %s\n", qi, t == 2 ? 76 : t ? 12 : 30, mode, rec, gb_line_shown());
      }
    }
    gb_replay_allow(-1); gzclose(z);
    printf("%s: the line pressed as judged -- %d swaps of %d lines keyed, %d begun later than the judge pressed them\n", late || !compared ? "FAIL" : "ok", compared, lines, late);
    fail |= late || !compared;
    // (A HELD KEY ENDS AT THE WALL: of those keys, every direction held let go with the cursor at the wall it walks toward)
    // (and every swap of them pressed with the cursor on the cell it was keyed for -- a slide and the taps back included)
    // (with no DAS -- core/nodes.h NO_DAS, the owner -- no key is held at all)
    int held, offCell, off = gb_held_off(&held, &offCell), noDas = gb_no_das(), badHeld = noDas ? held > 0 : !held;
    printf("%s: held keys end at the wall -- %d held of the lines keyed%s, %d let go off the wall, %d swaps pressed off their cell\n", off || offCell || badHeld ? "FAIL" : "ok", held, noDas ? " (no DAS: none may be)" : "", off, offCell);
    fail |= off || offCell || badHeld;
  }
  // (A BOARD ON ITS WAY OUT, played by the frame loop and Gambit's thread as a game plays it, the engine the game, a frame each 16 ms:
  // each lives past the frame it is lost on left alone -- its question asked while a swap answered still comes down in time (front.c
  // afterFrame). Not under the thread sanitizer, whose clock is not the game's)
  snprintf(path, sizeof path, "%s/front.txt", dir);
  FILE *fb = getenv("TSAN_OPTIONS") ? 0 : fopen(path, "r");
  if (fb) {
    int boards = 0, outlived = 0;
    static int32_t fo[2 * 4000];
    while (fgets(line, sizeof line, fb)) {
      int mode = atoi(line), narr;
      const char *b = strstr(line, "GAMBIT");
      if (!b) continue;
      int n = loadLine(b, &narr);
      if (n < 0 || gb_question_bytes(n, 0) != 0) continue;
      int alone = gb_frames(0, 0, 2000, fo);
      if (gb_question_bytes(n, 0) != 0) continue;
      int k = gb_front_sim(alone + 120, 16, mode, fo);
      boards++; outlived += k > alone + 1;
      if (k <= alone + 1) printf("  lost on its way out (mode %d): %d frames left alone, %d played\n", mode, alone, k);
    }
    fclose(fb);
    printf("%s: a board on its way out -- %d of %d outlived the frame they are lost on left alone\n", outlived < boards || !boards ? "FAIL" : "ok", outlived, boards);
    fail |= outlived < boards || !boards;
  }
  // ---- switching: every direction between the modes, over a run's games (gambit-switch.json's stretch)
  { int32_t counts[64 * 64]; int nr = 0, missing = gb_switch_check(24, 21600, 300, 1800, counts, &nr), lo = 1 << 30, hi = 0;
    for (int a = 0; a < nr; a++) for (int b = 0; b < nr; b++) if (a != b) { if (counts[a * nr + b] < lo) lo = counts[a * nr + b]; if (counts[a * nr + b] > hi) hi = counts[a * nr + b]; }
    printf("%s: switching -- %d modes, %d directions, each switched %d to %d times over 24 games, %d never\n", missing || nr < 2 ? "FAIL" : "ok", nr, nr * (nr - 1), lo, hi, missing);
    fail |= missing || nr < 2; }
  // (with workers, a break they find reaches the decision whenever it is found: an answer the same twice is asked only of one thread)
  int workers = getenv("GC_GAMBIT_WORKERS") && atoi(getenv("GC_GAMBIT_WORKERS")) > 0;
  printf("%s: decisions replayed -- %d questions, %d answered differently on a second asking%s\n", unsteady && !workers ? "FAIL" : "ok", nq, unsteady,
         workers ? " (workers: not held)" : "");
  { int nm = 0; for (int i = 0; i < 64; i++) nm += modes[i] > 0;
    printf("%s: the answers -- %d questions over %d modes, %d played a line that dies while one lived, %d one lost a break's time sooner than one offered, %d lines past the reach kept (decide.c, the owner's reach), %d of %d flips back kept (decide.c undoesLast), %d lines kept that spend the next block's reserve (decide.c overspends)\n",
           liveDied || sooner || far || undoKept || !undoTried || nm < 4 || over ? "FAIL" : "ok", nq, nm, liveDied, sooner, far, undoKept, undoTried, over);
    printf("%s: the raise -- %d of %d low stacks with no garbage on them (a garbage game) raised, %d of %d raises held down\n", lowRaised < lows || raiseHeld < raises || !raises ? "FAIL" : "ok", lowRaised, lows, raiseHeld, raises);
    fail |= liveDied || sooner || far || undoKept || !undoTried || nm < 4 || over || !lows || lowRaised < lows || raiseHeld < raises; }
  if (golden) printf("wrote %s/decisions.golden\n", dir);
  else printf("%s: against the golden -- %d moves changed, %d records changed\n", moved ? "CHANGED" : "ok", moved, changed);
  fail |= (unsteady && !workers) || !nq;
  return fail ? 1 : 0;
}
