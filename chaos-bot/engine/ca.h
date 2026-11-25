// THE CHAOS v3 STACK, as ca.c holds it. Ported from Gambit's pa.h (GameCreator eval/native, copied, never linked)
// and changed to the chaos build's rules: reference/chaos-v3/common/engine/{Stack,checkMatches,GarbageQueue,
// WigglePay,Panel}.lua. check.c holds every field to recordings of that Lua (lua/record.lua), frame by frame.
#ifndef CA_H
#define CA_H
#include <stdint.h>
#include <string.h>

#define W 6
#define MAXROWS 48
#define NUL (-2147483647 - 1)   // Lua nil
#define SETB(v) ((v) != NUL && (v) != 0)   // Lua truthiness of a nil-or-boolean
#define SETN(v) ((v) != NUL)               // of a nil-or-number: 0 is true

// Panel fields, in record.lua's order (P lines after row, col).
enum { ROW, COL, ID, COLOR, CHAINING, MATCHING, TIMER, INITIALTIME, POPTIME, POPINDEX, XOFF, YOFF, GWIDTH,
       GHEIGHT, SHAKETIME, ISGARBAGE, STATE, COMBOINDEX, COMBOSIZE, SWAPFROMLEFT, DONTSWAP, QUEUEDHOVER, FELL,
       STATECHANGED, PROPCHAIN, MATCHANYWAY, PROPFALL, GARBAGEID, METAL, NF };
enum { NORMAL, DIMMED, SWAPPING, MATCHED, POPPING, POPPED, HOVERING, FALLING, LANDING, DEAD };

typedef struct { int32_t f[NF]; } Panel;
// A queued piece. finalized: NUL / 0 / 1. Kept in the Lua's array order: index 0 is Lua's [1], the next to drop is last.
typedef struct { int32_t width, height, isChain, isMetal, frameEarned, finalized; } Incoming;
typedef struct { int32_t leftId, rightId, row, col, clock; } Stall;
// A piece this stack sent (pushGarbage): combo, shock and all-clear pieces; chains are counted by link (see Board).
typedef struct { int8_t width, height, metal, allClear; int32_t clock; } Sent;

#define FEED 16
#define MAXINC 512
#define MAXSTALL 64
#define MAXLANDED 16
#define MAXMATCH 160
#define MAXIDS 64
#define MAXSENT 64

#define ERR_ROWS 1
#define ERR_INC 2
#define ERR_STALL 8
#define ERR_LANDED 16
#define ERR_MATCH 32
#define ERR_WIDTH 64
#define ERR_STATE 128
#define ERR_SENT 256

#define CD_NULL (-1)
#define DIR_UP 0
#define DIR_DOWN 1
#define DIR_LEFT 2
#define DIR_RIGHT 3

// The game's input bits (KeyDataEncoding).
#define IN_RIGHT 1
#define IN_LEFT 2
#define IN_DOWN 4
#define IN_UP 8
#define IN_SWAP 16
#define IN_RAISE 32

// margin time (Stack.margin_time) and game modes (Stack.game_mode)
#define MARGIN_OFF 1
#define MARGIN_COLORS 2
#define MARGIN_MODOKI 3
#define MARGIN_CHAOS 4
#define GARBAGE_LIMIT 50

typedef struct Board {
  // ---- the level, the stack's settings and behaviours (constant through a game)
  int32_t maxHealth, shockFrequency, shockCap;
  int32_t fHOVER, fGARBAGE_HOVER, fFLASH, fFACE, fPOP, fGARBAGE_POP;
  int32_t stopBase;                      // levelData.stop.BaseConstant
  int32_t gameMode, marginTime, chaosMode;   // the stack's own (chaos mode: what it sends and where garbage drops)
  int32_t queueType, incChaos, incIllegal;   // the incoming queue's (set by whoever sends to it)
  int32_t passiveRaise, allowManualRaise, swapStallingMode, swapStallingPunish, startTimersWithSwapCount;
  int32_t height;
  // ---- state
  int32_t nrows, panelIdCount, speed, nextSpeedIncreaseClock, clock, stopWatch, displacement, riseTimer;
  int32_t riseLock, hasRisen, manualRaise, manualRaiseYet, preventManualRaise, swapThisFrame;
  int32_t stopTime, preStopTime, shakeTime, prevShakeTime, shakeTimeOnFrame, peakShakeTime, health, topRow;
  int32_t chainCounter, clearCounter, hasAllClear;
  int32_t nActive, nPrevActive, nActiveGarbage, nPrevActiveGarbage, swappingCount;
  int32_t landedThis, landedLast, matchedThis;
  int32_t panelsCleared, metalPanelsQueued, garbagePanelsCleared;
  double score;
  int32_t curRow, curCol, topCurRow, queuedSwapRow, queuedSwapCol, swapCount, curTimer, curWaitTime, cursorDirection;
  int32_t garbageCreatedCount, highestGarbageIdMatched, gameOverClock;
  int32_t marginCounter, shakeMargin, colorCount;
  int32_t input;                         // the next frame's keys
  int32_t unseenRows, unseenBreaks, err;
  // ---- what the stack sent (pushGarbage), since sentReset: pieces, chain links added, chains finished and their size.
  // The chain being built is outChain rows tall (0: none). Not part of the Lua's stack: the game's outgoing queue.
  int32_t nsent, outChain, outLinks, outChains, outChainRows;
  Sent sent[MAXSENT];
  // ---- FED ROWS: the rows and break colours the game dealt, played as dealt; empty, unseen colours are dealt.
  int32_t rowFeed[FEED][W], nRowFeed, rowFeedAt, brkFeed[FEED][W], nBrkFeed, brkFeedAt;
  int32_t ninc, nstall, nlanded;
  int32_t dropColumnIndex[7];            // [width], 1-based as the Lua keeps them
  Stall stall[MAXSTALL];
  int32_t landed[MAXLANDED];
  // the queue and the panels last, so a copy takes the ninc queued and the nrows rows and nothing past them
  Incoming inc[MAXINC];
  Panel p[MAXROWS][W + 1];
} Board;
#define BOARD_HEAD ((unsigned long)&((Board *)0)->inc)
static inline void caCopy(Board *dst, const Board *src) {
  memcpy(dst, src, BOARD_HEAD);
  memcpy(dst->inc, src->inc, (unsigned long)src->ninc * sizeof(Incoming));
  memcpy(dst->p, src->p, (unsigned long)src->nrows * sizeof(Panel) * (W + 1));
}

// ---- the engine
void caInit(Board *b, int level, int gameMode, int marginTime, int chaosMode, int queueType);
void caRun(Board *b);                    // one frame with b->input
int caGameEnded(const Board *b);
void caReceive(Board *b, int32_t w, int32_t h, int32_t isChain, int32_t isMetal, int32_t frameEarned, int32_t finalized);
int caFeedRow(Board *b, const int32_t *c);
int caFeedBreak(Board *b, const int32_t *c);
int caToppedOut(Board *b);
int caCanSwap(Board *b, int row, int col);
int caRiseFrames(int speed);             // frames per displacement step at `speed`
void caSentReset(Board *b);

#endif
