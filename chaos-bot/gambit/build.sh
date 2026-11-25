#!/bin/sh
# Builds gambit.wasm from gambit.c (the server's engine in ../eval/native, the infra in core/, Gambit's pieces) and records every hash
# in BUILT. Needs clang with the wasm32 target (clang 18 here; no libc: the engine's libc.h has what is used). The only imports allowed are the
# memory, abort_poll (the host's abort) and clock_ms (the host's time).
set -e
cd "$(dirname "$0")"
# ./build.sh native: libgambit.so, Gambit in the game's own process (native.c, host.c; lua/GambitNative.lua loads it). Built on the
# machine that plays (training.sh); not tracked. With GC_GAMBIT_PGO=1, built on gambit.profdata where the compiler reads it (the same
# clang that wrote it): 1.2x as fast, the same answers on the replay's fixed work -- in a game the search gets that much more of the
# clock, and a round with it scored 77 of 84 against 80-82 without, so it is off until that is understood.
if [ "${1:-}" = native ]; then
  N="clang -O3 -march=native -pthread -fPIC -shared -Wl,-z,nodelete -DPA_HEAP -Wall -Wno-unused-function -Wno-unknown-attributes -Wno-ignored-attributes native.c host.c -lm -o libgambit.so"
  P="-fprofile-use=gambit.profdata -Wno-profile-instr-out-of-date -Wno-profile-instr-unprofiled -Wno-backend-plugin"
  { [ "${GC_GAMBIT_PGO:-0}" = 1 ] && [ -f gambit.profdata ] && $N $P 2>/dev/null; } || $N
  exit
fi
# ./build.sh test [golden|speed]: the C checks, natively (test/main.c: the board as bits, perched blocks, the decisions replayed against the
# golden; "golden" writes it from this build; "speed" answers questions on the wall clock and prints the engine work a decision does;
# "replay LOG MODE" answers each of a lost game's last boards (GAMBITL) at half, once, twice and four times a decision's work;
# "board LOG FRAME" draws the logged board of that frame). With no argument the wait's window (test wait), the line in progress past the clock (test carry), the raise pressed as answered (test raise), the later loss bought (test spend), the window that leaves no break (test windead), the walk for nothing (test toward), the flips keyed as judged (test flips), the line that outlives the hold (test reason) and the opening (test opening)
# are checked after them, a process each.
# ./build.sh tsan: the C checks built with ThreadSanitizer (gcc's runtime) and run on GC_GAMBIT_WORKERS (default 4) workers -- every
# search a worker runs beside Gambit's thread is raced against it; any data race fails (exit 66)
if [ "${1:-}" = tsan ]; then
  gcc -O1 -g -fsanitize=thread -pthread -DPA_HEAP -DGB_TEST -w native.c host.c test/main.c -lm -lz -o /tmp/gambit-tsan &&
    GC_GAMBIT_WORKERS=${GC_GAMBIT_WORKERS:-4} TSAN_OPTIONS="halt_on_error=1 exitcode=66 report_signal_unsafe=0 history_size=2" /tmp/gambit-tsan test &&
    GC_GAMBIT_WORKERS=${GC_GAMBIT_WORKERS:-4} TSAN_OPTIONS="halt_on_error=1 exitcode=66 report_signal_unsafe=0 history_size=2" /tmp/gambit-tsan test opening
  exit
fi
if [ "${1:-}" = test ]; then
  shift
  clang -O2 -pthread -DPA_HEAP -DGB_TEST -Wall -Wno-unused-function -Wno-unknown-attributes -Wno-ignored-attributes \
    native.c host.c test/main.c -lm -lz -o /tmp/gambit-test && GC_GAMBIT_WORKERS=${GC_GAMBIT_WORKERS:-0} /tmp/gambit-test test "$@" && { [ -n "${1:-}" ] || { GC_GAMBIT_WORKERS=0 /tmp/gambit-test test wait && GC_GAMBIT_WORKERS=0 /tmp/gambit-test test carry && GC_GAMBIT_WORKERS=0 /tmp/gambit-test test raise && GC_GAMBIT_WORKERS=0 /tmp/gambit-test test spend && GC_GAMBIT_WORKERS=0 /tmp/gambit-test test windead && GC_GAMBIT_WORKERS=0 /tmp/gambit-test test toward && GC_GAMBIT_WORKERS=0 /tmp/gambit-test test flips && GC_GAMBIT_WORKERS=0 /tmp/gambit-test test reason && GC_GAMBIT_WORKERS=${GC_GAMBIT_WORKERS:-4} /tmp/gambit-test test opening; }; }
  exit
fi
# ./build.sh material DIR...: core/material.h, the life a board has by its panels, measured on the games in DIR... (material.c, on the
# system's libc). Not part of the bot; run when the bot changes enough to move it.
if [ "${1:-}" = material ]; then
  shift
  clang -O2 -Wall material.c -o /tmp/gambit-material && /tmp/gambit-material core/material.h "$@"
  exit
fi
FLAGS="--target=wasm32 -O3 -matomics -mbulk-memory -nostdlib -Wall -Wno-unused-function -Wl,--no-entry -Wl,--allow-undefined"
clang $FLAGS gambit.c -o gambit.wasm
node -e '
var fs = require("fs"), bad = [];
for (var i of WebAssembly.Module.imports(new WebAssembly.Module(fs.readFileSync("gambit.wasm"))))
  if (i.name !== "memory" && i.name !== "abort_poll" && i.name !== "clock_ms") bad.push("gambit.wasm imports " + i.module + "." + i.name);
if (bad.length) { console.error(bad.join("\n")); process.exit(1); }'
h() { sha256sum "$1" | cut -c1-64; }
{ for f in ../eval/native/pa.c ../eval/native/pa.h ../eval/native/libc.h ../eval/native/memory.h ../eval/native/search.h core/*.h *.c search/*.c gambit.wasm; do printf '%s %s\n' "$f" "$(h $f)"; done; } > BUILT
# THE PROFILE (gambit.profdata): the replay of test/pgo.txt.gz's boards -- lost games' last boards, none of the checks' own -- on a build
# that counts every branch, merged for native's -fprofile-use. Measured on boards it was not made from: the same answers, 1.2x as fast.
# Kept as it was where llvm-profdata is not installed: a function changed since is built as if unprofiled.
if command -v llvm-profdata >/dev/null; then
  rm -rf /tmp/gambit-pgo && mkdir -p /tmp/gambit-pgo && gunzip -c test/pgo.txt.gz > /tmp/gambit-pgo/boards.log &&
    clang -O3 -march=native -pthread -DPA_HEAP -DGB_TEST -w -fprofile-generate=/tmp/gambit-pgo native.c host.c test/main.c -lm -lz -o /tmp/gambit-pgo/gen &&
    GC_GAMBIT_WORKERS=0 /tmp/gambit-pgo/gen test replay /tmp/gambit-pgo/boards.log 1 > /dev/null &&
    llvm-profdata merge -o gambit.profdata /tmp/gambit-pgo/*.profraw
fi
printf '%s %s\n' gambit.profdata "$(h gambit.profdata)" >> BUILT
cat BUILT
