// THE C ENGINE HELD TO THE CHAOS LUA, FRAME BY FRAME.
//   cc -O2 -o check check.c ca.c -lm && luajit ../lua/record.lua 1 3000 | ./check [-v]
// Reads a recording (lua/record.lua), loads its starting board, then for every frame hands over what the Lua dealt
// (rows, break colours) and the garbage pushed onto the queue, runs one frame, and compares every scalar, every panel
// field, the queue, the stall log, the drop columns and what was sent. Exit 0 if every frame matches.
#include "ca.h"
#include <stdio.h>
#include <stdlib.h>

#define MAXLINE 65536
typedef struct { const char *name; size_t off; } Field;
#define F(n, m) { n, offsetof(Board, m) }
#include <stddef.h>
static const Field FIELDS[] = {
  F("riseTimer", riseTimer), F("speed", speed), F("nextSpeedIncreaseClock", nextSpeedIncreaseClock), F("clock", clock),
  F("stopWatch", stopWatch), F("displacement", displacement), F("riseLock", riseLock), F("hasRisen", hasRisen),
  F("manualRaise", manualRaise), F("manualRaiseYet", manualRaiseYet), F("preventManualRaise", preventManualRaise),
  F("swapThisFrame", swapThisFrame), F("stopTime", stopTime), F("preStopTime", preStopTime), F("shakeTime", shakeTime),
  F("prevShakeTime", prevShakeTime), F("shakeTimeOnFrame", shakeTimeOnFrame), F("peakShakeTime", peakShakeTime),
  F("health", health), F("topRow", topRow), F("chainCounter", chainCounter), F("clearCounter", clearCounter),
  F("hasAllClear", hasAllClear), F("nActive", nActive), F("nPrevActive", nPrevActive), F("nActiveGarbage", nActiveGarbage),
  F("nPrevActiveGarbage", nPrevActiveGarbage), F("landedThis", landedThis), F("landedLast", landedLast),
  F("matchedThis", matchedThis), F("swappingCount", swappingCount), F("panelsCleared", panelsCleared),
  F("metalPanelsQueued", metalPanelsQueued), F("curRow", curRow), F("curCol", curCol), F("topCurRow", topCurRow),
  F("queuedSwapRow", queuedSwapRow), F("queuedSwapCol", queuedSwapCol), F("swapCount", swapCount), F("curTimer", curTimer),
  F("curWaitTime", curWaitTime), F("cursorDirection", cursorDirection), F("garbageCreatedCount", garbageCreatedCount),
  F("highestGarbageIdMatched", highestGarbageIdMatched), F("gameOverClock", gameOverClock), F("marginCounter", marginCounter),
  F("shakeMargin", shakeMargin), F("colorCount", colorCount), F("garbagePanelsCleared", garbagePanelsCleared),
  F("panelIdCount", panelIdCount),
};
#define NFIELDS (int)(sizeof FIELDS / sizeof FIELDS[0])
static const char *PANEL_NAMES[NF] = { "row", "col", "id", "color", "chaining", "matching", "timer", "initialTime", "popTime",
  "popIndex", "xOff", "yOff", "width", "height", "shakeTime", "isGarbage", "state", "comboIndex", "comboSize", "swapFromLeft",
  "dontSwap", "queuedHover", "fell", "stateChanged", "propChain", "matchAnyway", "propFall", "garbageId", "metal" };

static int32_t *field(Board *b, const Field *f) { return (int32_t *)((char *)b + f->off); }
static const Field *fieldNamed(const char *n) {
  for (int i = 0; i < NFIELDS; i++) if (!strcmp(FIELDS[i].name, n)) return &FIELDS[i];
  return 0;
}

// one frame's record, read whole
#define MAXSTATE 4096
typedef struct {
  int clock, input, end;
  int ng; int32_t g[64][6];              // garbage pushed before the frame
  int nc; int32_t c[64];                 // the chain being built changed (height, or -1: finalized)
  int nr; int32_t r[64][6];              // rows dealt
  int nb; int32_t brk[64][6];            // break colours dealt
  int no; int32_t o[MAXSENT][4];         // pieces sent
  int links, ends;
  int ns; char sname[128][40]; long long sval[128];
  int np; int32_t p[MAXROWS * W][NF + 2];
  int nq; int32_t q[MAXINC][6];
  int nw; int32_t w[MAXSTALL][5];
  int32_t d[6];
  int haveState;
} Frame;
static Frame fr;
static char line[MAXLINE];
static char pending[MAXLINE];
static int havePending;
static int verbose;
static int hdr[16]; // seed level queue chaos margin gamemode incomingChaos

static int readLine(FILE *in) {
  if (havePending) { strcpy(line, pending); havePending = 0; return 1; }
  return fgets(line, sizeof line, in) != 0;
}
static void parseInts(const char *s, int32_t *out, int n) {
  char *e;
  for (int i = 0; i < n; i++) { out[i] = (int32_t)strtol(s, &e, 10); s = e; }
}
// Reads the next frame: everything up to and including its D line. Returns 0 at the end.
static int readFrame(FILE *in) {
  memset(&fr, 0, sizeof fr);
  int seenF = 0;
  while (readLine(in)) {
    char k = line[0];
    const char *s = line + 2;
    if (k == 'H') {
      sscanf(line, "H seed %d level %d queue %d chaos %d margin %d gamemode %d incomingChaos %d", &hdr[0], &hdr[1], &hdr[2], &hdr[3], &hdr[4], &hdr[5], &hdr[6]);
    } else if (k == 'X') { fr.end = 1; return 0; }
    else if (k == 'G') { if (seenF) { strcpy(pending, line); havePending = 1; return 1; } parseInts(s, fr.g[fr.ng++], 6); }
    else if (k == 'C') { if (seenF) { strcpy(pending, line); havePending = 1; return 1; } fr.c[fr.nc++] = atoi(s); }
    else if (k == 'F') { if (seenF) { strcpy(pending, line); havePending = 1; return 1; } sscanf(s, "%d %d", &fr.clock, &fr.input); seenF = 1; }
    else if (k == 'R') parseInts(s, fr.r[fr.nr++], 6);
    else if (k == 'B') parseInts(s, fr.brk[fr.nb++], 6);
    else if (k == 'O') parseInts(s, fr.o[fr.no++], 4);
    else if (k == 'L') fr.links++;
    else if (k == 'E') fr.ends++;
    else if (k == 'S') {
      fr.haveState = 1;
      char *t = line + 2, *e;
      while (*t && *t != '\n') {
        char name[40]; int n = 0;
        while (*t == ' ') t++;
        if (!*t || *t == '\n') break;
        while (*t && *t != ' ' && n < 39) name[n++] = *t++;
        name[n] = 0;
        long long v = strtoll(t, &e, 10); t = e;
        strcpy(fr.sname[fr.ns], name); fr.sval[fr.ns++] = v;
      }
    } else if (k == 'P') parseInts(s, fr.p[fr.np++], NF + 2);
    else if (k == 'Q') { char *e; fr.nq = (int)strtol(s, &e, 10); for (int i = 0; i < fr.nq; i++) parseInts(e, fr.q[i], 6), e = (char *)s;
      // re-parse properly: count then 6 per piece
      const char *t = s; char *e2; strtol(t, &e2, 10); t = e2;
      for (int i = 0; i < fr.nq; i++) for (int j = 0; j < 6; j++) { fr.q[i][j] = (int32_t)strtol(t, &e2, 10); t = e2; } }
    else if (k == 'W') { const char *t = s; char *e2; fr.nw = (int)strtol(t, &e2, 10); t = e2;
      for (int i = 0; i < fr.nw; i++) for (int j = 0; j < 5; j++) { fr.w[i][j] = (int32_t)strtol(t, &e2, 10); t = e2; } }
    else if (k == 'D') { parseInts(s, fr.d, 6); return 1; }
  }
  return 0;
}

static void load(Board *b) {
  for (int i = 0; i < fr.ns; i++) {
    if (!strcmp(fr.sname[i], "score")) { b->score = (double)fr.sval[i]; continue; }
    if (!strcmp(fr.sname[i], "scoreFrac")) { b->score += fr.sval[i] / 1e6; continue; }
    const Field *f = fieldNamed(fr.sname[i]);
    if (f) *field(b, f) = (int32_t)fr.sval[i];
  }
  int top = 0;
  for (int i = 0; i < fr.np; i++) if (fr.p[i][0] > top) top = fr.p[i][0];
  b->nrows = top + 1;
  for (int i = 0; i < fr.np; i++) memcpy(b->p[fr.p[i][0]][fr.p[i][1]].f, &fr.p[i][2], sizeof(int32_t) * NF);
  b->ninc = fr.nq;
  for (int i = 0; i < fr.nq; i++) { Incoming g = { fr.q[i][0], fr.q[i][1], fr.q[i][2], fr.q[i][3], fr.q[i][4], fr.q[i][5] < 0 ? NUL : fr.q[i][5] }; b->inc[i] = g; }
  b->nstall = fr.nw;
  for (int i = 0; i < fr.nw; i++) { Stall s = { fr.w[i][0], fr.w[i][1], fr.w[i][2], fr.w[i][3], fr.w[i][4] }; b->stall[i] = s; }
  for (int i = 1; i <= 6; i++) b->dropColumnIndex[i] = fr.d[i - 1];
}

static int bad;
static void report(int clock, const char *what, long long lua, long long c) {
  if (bad < 40) fprintf(stderr, "frame %d: %s lua %lld c %lld\n", clock, what, lua, c);
  bad++;
}
static int compare(Board *b, int sent0, int links0, int ends0) {
  int before = bad;
  char what[96];
  for (int i = 0; i < fr.ns; i++) {
    if (!strcmp(fr.sname[i], "score")) { if ((long long)b->score != fr.sval[i]) report(fr.clock, "score", fr.sval[i], (long long)b->score); continue; }
    if (!strcmp(fr.sname[i], "scoreFrac")) continue;
    const Field *f = fieldNamed(fr.sname[i]);
    if (!f) continue;
    if (*field(b, f) != (int32_t)fr.sval[i]) report(fr.clock, fr.sname[i], fr.sval[i], *field(b, f));
  }
  int top = 0;
  for (int i = 0; i < fr.np; i++) if (fr.p[i][0] > top) top = fr.p[i][0];
  if (b->nrows != top + 1) report(fr.clock, "nrows", top + 1, b->nrows);
  for (int i = 0; i < fr.np; i++) {
    int r = fr.p[i][0], c = fr.p[i][1];
    if (r >= b->nrows) continue;
    for (int k = 0; k < NF; k++)
      if (b->p[r][c].f[k] != fr.p[i][2 + k]) { snprintf(what, sizeof what, "panel %d,%d %s", r, c, PANEL_NAMES[k]); report(fr.clock, what, fr.p[i][2 + k], b->p[r][c].f[k]); }
  }
  if (b->ninc != fr.nq) report(fr.clock, "queue length", fr.nq, b->ninc);
  else for (int i = 0; i < fr.nq; i++) {
    Incoming *g = &b->inc[i];
    int32_t fin = g->finalized == NUL ? -1 : g->finalized;
    int32_t v[6] = { g->width, g->height, g->isChain, g->isMetal, g->frameEarned, fin };
    for (int j = 0; j < 6; j++) if (v[j] != fr.q[i][j]) { snprintf(what, sizeof what, "queue[%d].%d", i, j); report(fr.clock, what, fr.q[i][j], v[j]); }
  }
  if (b->nstall != fr.nw) report(fr.clock, "stall length", fr.nw, b->nstall);
  else for (int i = 0; i < fr.nw; i++) {
    Stall *s = &b->stall[i];
    int32_t v[5] = { s->leftId, s->rightId, s->row, s->col, s->clock };
    for (int j = 0; j < 5; j++) if (v[j] != fr.w[i][j]) { snprintf(what, sizeof what, "stall[%d].%d", i, j); report(fr.clock, what, fr.w[i][j], v[j]); }
  }
  for (int i = 1; i <= 6; i++) if (b->dropColumnIndex[i] != fr.d[i - 1]) { snprintf(what, sizeof what, "dropColumnIndex[%d]", i); report(fr.clock, what, fr.d[i - 1], b->dropColumnIndex[i]); }
  // what was sent this frame
  if (b->nsent - sent0 != fr.no) report(fr.clock, "pieces sent", fr.no, b->nsent - sent0);
  else for (int i = 0; i < fr.no; i++) {
    CaSent *s = &b->sent[sent0 + i];
    int32_t v[4] = { s->width, s->height, 0, s->metal };
    for (int j = 0; j < 4; j++) if (v[j] != fr.o[i][j]) { snprintf(what, sizeof what, "sent[%d].%d", i, j); report(fr.clock, what, fr.o[i][j], v[j]); }
  }
  if (b->outLinks - links0 != fr.links) report(fr.clock, "chain links", fr.links, b->outLinks - links0);
  if (b->outChains - ends0 != fr.ends) report(fr.clock, "chains ended", fr.ends, b->outChains - ends0);
  return bad == before;
}

int main(int argc, char **argv) {
  verbose = argc > 1 && !strcmp(argv[1], "-v");
  static Board b;
  if (!readFrame(stdin) || !fr.haveState) { fprintf(stderr, "no starting board\n"); return 2; }
  caInit(&b, hdr[1], hdr[5], hdr[4], hdr[3], hdr[2]);
  b.incChaos = hdr[6]; b.incIllegal = 1;
  load(&b);
  int frames = 0;
  while (readFrame(stdin)) {
    for (int i = 0; i < fr.ng; i++) caReceive(&b, fr.g[i][0], fr.g[i][1], fr.g[i][2], fr.g[i][3], fr.g[i][4], fr.g[i][5] < 0 ? NUL : fr.g[i][5]);
    for (int i = 0; i < fr.nc; i++) {
      // the chain the sender is building, changed in place (no re-sort), if it is still queued
      for (int j = 0; j < b.ninc; j++) if (b.inc[j].isChain && b.inc[j].finalized == 0) {
        if (fr.c[i] < 0) b.inc[j].finalized = 1; else b.inc[j].height = fr.c[i];
        break;
      }
    }
    for (int i = 0; i < fr.nr; i++) caFeedRow(&b, fr.r[i]);
    for (int i = 0; i < fr.nb; i++) caFeedBreak(&b, fr.brk[i]);
    int sent0 = b.nsent, links0 = b.outLinks, ends0 = b.outChains;
    if (b.nsent > MAXSENT - 16) { caSentReset(&b); sent0 = 0; links0 = 0; ends0 = 0; }
    b.input = fr.input;
    caRun(&b);
    if (b.err) { fprintf(stderr, "frame %d: engine error %d\n", fr.clock, b.err); return 1; }
    int ok = compare(&b, sent0, links0, ends0);
    frames++;
    if (!ok) {
      fprintf(stderr, "first difference at frame %d (input %d)\n", fr.clock, fr.input);
      return 1;
    }
    if (verbose && frames % 500 == 0) fprintf(stderr, "%d frames ok\n", frames);
  }
  static const char *EVN[NEV] = EV_NAMES;
  printf("events");
  for (int i = 0; i < NEV; i++) printf(" %s %d", EVN[i], b.ev[i]);
  printf("\n");
  printf("%d frames identical (seed %d level %d queue %d chaos %d margin %d gamemode %d)\n", frames, hdr[0], hdr[1], hdr[2], hdr[3], hdr[4], hdr[5]);
  return 0;
}
