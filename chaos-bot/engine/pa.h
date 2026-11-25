// THE SERVER'S BOARD, as pa.c holds it: shared by the engine and by the
// bot's front end (front.c), which reads the board it plays.
#ifndef PA_H
#define PA_H
#include "libc.h"

#define W 6
#define MAXROWS 48
#define NUL (-2147483647 - 1)   // Lua nil
#define UND (-2147483647)
#define SETB(v) ((v) != NUL && (v) != 0)   // Lua truthiness of a nil-or-boolean
#define SETN(v) ((v) != NUL)               // of a nil-or-number: 0 is true

// Panel fields: pa-engine.js's names, in this order (native.js reads them).
enum { ROW, COL, ID, COLOR, CHAINING, MATCHING, TIMER, INITIALTIME, POPTIME, POPINDEX, XOFF, YOFF, GWIDTH,
       GHEIGHT, SHAKETIME, ISGARBAGE, STATE, COMBOINDEX, COMBOSIZE, SWAPFROMLEFT, DONTSWAP, QUEUEDHOVER, FELL,
       STATECHANGED, PROPCHAIN, MATCHANYWAY, PROPFALL, GARBAGEID, METAL, NF };
enum { NORMAL, DIMMED, SWAPPING, MATCHED, POPPING, POPPED, HOVERING, FALLING, LANDING, DEAD };

typedef struct { int32_t f[NF]; } Panel;
typedef struct { int32_t width, height, isChain, isMetal, frameEarned, finalized; } Incoming;   // finalized: NUL/0/1
typedef struct { int32_t leftId, rightId, row, col, clock; } Stall;

#define FEED 16
// The garbage queued. The Lua's queue has no end: a drill sends fifty slabs a
// burst, and a stack kept busy lets few drop. The bot (PA_LIB) plays drills
// of 120000 frames; the search's boards (pa.wasm) hold a training volley.
#ifdef PA_LIB
#define MAXINC 8192
#else
#define MAXINC 256   // a training volley queues fifty at once, and an unbroken queue keeps the last ones
#endif
#define MAXSTALL 64
#define MAXLANDED 16
#define MAXCOMBOS 16
#define MAXMATCH 160
#define MAXIDS 64

#define ERR_ROWS 1
#define ERR_INC 2
#define ERR_STALL 8
#define ERR_LANDED 16
#define ERR_MATCH 32
#define ERR_WIDTH 64
#define ERR_STATE 128

#define CD_NULL (-1)
#define DIR_UP 0
#define DIR_DOWN 1
#define DIR_LEFT 2
#define DIR_RIGHT 3

// The server's input bits (KeyDataEncoding).
#define IN_RIGHT 1
#define IN_LEFT 2
#define IN_DOWN 4
#define IN_UP 8
#define IN_SWAP 16
#define IN_RAISE 32

typedef struct Board {
  // the level and the stack's behaviours
  int32_t colors, maxHealth, shockFrequency, shockCap, speedIncreaseMode;
  int32_t fHOVER, fGARBAGE_HOVER, fFLASH, fFACE, fPOP;
  int32_t sFormula, sComboConstant, sChainConstant, sDangerConstant, sCoefficient, sDangerCoefficient;
  int32_t startingSpeed;
  int32_t passiveRaise, allowManualRaise, swapStallingMode, swapStallingPunish;
  int32_t height;
  // state
  double riseTimer;
  int32_t nrows, panelIdCount, speed, nextSpeedIncreaseClock, clock, stopWatch, stopWatchIsRunning, inCountdown, displacement;
  int32_t riseLock, hasRisen, manualRaise, manualRaiseYet, preventManualRaise, swapThisFrame;
  int32_t stopTime, preStopTime, shakeTime, prevShakeTime, shakeTimeOnFrame, peakShakeTime, health, wasToppedOut;
  int32_t chainCounter, nActive, nPrevActive, swappingCount, panelsCleared, metalPanelsQueued, score;
  int32_t curRow, curCol, topCurRow, queuedSwapRow, queuedSwapCol, swapCount, curTimer, curWaitTime, cursorDirection, cursorLock;
  int32_t garbageCreatedCount, highestGarbageIdMatched, gameOverClock, gameOver;
  int32_t input, pressSwap, swapDenied, inputBits, unseenRows, unseenBreaks, err;
  int32_t quiet, noQuiet;   // see QUIET; not part of the board, never sent
  int32_t hi;               // see SETTLED ROWS; not part of the board, never sent
  int32_t cdLeft;           // see COUNTDOWN FRAMES; not part of the board, never sent
  int32_t popSeen;          // garbage popping was updated this frame (updatePanels); not part of the board
  signed char rowActive[MAXROWS];   // ROWS COUNTED: a row's active panels, known by updatePanels; -1 unknown; not part of the board
  // WHAT A STEP DID (search.h MK_SETTLE): each clear's size and the chain
  // counter it reached, panels cleared, garbage cells converted, the most
  // stop time one clear paid, garbage cells at rest that started to fall, the
  // empty cells under garbage as it landed (pa.c HOLLOW).
  // Counted since the step began; not part of the board, never sent.
  int32_t sCombo[MAXCOMBOS], sChainAt[MAXCOMBOS], sNCombo, sCleared, sBroke, sEarned, sFell, sHollow;
  // FED ROWS: the real rows and break colours, from the game being played;
  // empty, the unseen colours are dealt, as the search wants. A row
  // cell is a colour, or 100 + colour / 200 + colour for a letter (upper /
  // lower) that becomes shock with one / two shock panels queued. Not part of the board,
  // never sent.
  int32_t rowFeed[FEED][W], nRowFeed, rowFeedAt, brkFeed[FEED][W], nBrkFeed, brkFeedAt;
  int32_t ninc, nstall, nlanded;
  int32_t dropColumnIndex[7];     // [width], 1-based as the Lua keeps them
  Stall stall[MAXSTALL];
  int32_t landed[MAXLANDED];
  // the queue and the panels last, so a copy takes the ninc queued and the
  // nrows rows and nothing past them
  Incoming inc[MAXINC];           // the next to drop last
  Panel p[MAXROWS][W + 1];
  // (WHAT A STEP DID, more: of each clear, whether it is a link of a chain -- its panels fell from one -- and whether garbage is joined
  // to it, breaking some. After the board's head and its queue: not part of the board, never sent, no board's bytes changed by them)
  int32_t sLink[MAXCOMBOS], sTouch[MAXCOMBOS];
} Board;
#define BOARD_HEAD ((unsigned long)&((Board *)0)->inc)
static inline void paCopy(Board *dst, const Board *src) {
  memcpy(dst, src, BOARD_HEAD);
  memcpy(dst->inc, src->inc, (unsigned long)src->ninc * sizeof(Incoming));
  memcpy(dst->p, src->p, (unsigned long)src->nrows * sizeof(Panel) * (W + 1));
}
#define COPY_BOARD(dst, src) paCopy(dst, src)

// What the bot's front end (front.c) and the drill (drill.c) call.
Board *nb_new(void);
void nb_free(Board *b);
void nb_copy(Board *dst, Board *src);
int nb_run(Board *b);
int nb_can_swap(Board *b, int r, int c);
int nb_try_queue_swap(Board *b, int r, int c);
void nb_push_incoming(Board *b, int32_t w, int32_t h, int32_t isChain, int32_t isMetal);
int nb_topped(Board *b);
int nb_pressed(Board *b);
int nb_falling_garbage(Board *b);
int nb_active(Board *b);
int nb_spawn_col(Board *b, int width);
double nb_rise_time(int speed);
int nb_shake_frames(int count);
int nb_drain_in(Board *b, int most);
int nb_feed_row(Board *b, int32_t c1, int32_t c2, int32_t c3, int32_t c4, int32_t c5, int32_t c6);
int nb_feed_break(Board *b, int32_t c1, int32_t c2, int32_t c3, int32_t c4, int32_t c5, int32_t c6);
int nb_fed(Board *b);
void nb_receive(Board *b, int32_t w, int32_t h, int32_t isChain, int32_t isMetal, int32_t frameEarned, int32_t finalized);
Board *paLibBoard(void);

#endif
