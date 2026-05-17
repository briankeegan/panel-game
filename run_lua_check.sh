#!/usr/bin/env zsh
# Static type-check Lua sources via lua-language-server (LuaLS).
#
# Single source of truth for "what crash-risk warnings remain?" — runs LuaLS,
# caches the raw output, and produces a digestible report. Scope filtering is
# applied to the cache so per-file iteration is instant.
#
# Usage:
#   zsh run_lua_check.sh                # full fresh run (~45s), update cache
#   zsh run_lua_check.sh <scope>        # filter cached output to <scope>
#                                       # (file path or directory prefix)
#   zsh run_lua_check.sh --refresh      # force fresh full run
#   zsh run_lua_check.sh --refresh <scope>
#   zsh run_lua_check.sh --files        # show TOP FILES summary (no per-diag)
#   zsh run_lua_check.sh --files <scope>
#   zsh run_lua_check.sh --fields       # show TOP undefined-field names
#   zsh run_lua_check.sh --quiet        # summary only, no per-diag dump
#   zsh run_lua_check.sh --help
#
# Cache lives at .luals-check/output.raw.txt. Auto-refresh if cache is empty,
# truncated, or older than the most recent .lua source.
# Exit: 0 if zero crash-risk diagnostics in scope, 1 otherwise.

set -u

ROOT="${0:A:h}"
cd "$ROOT"

LOG_DIR="$ROOT/.luals-check"
RAW_OUTPUT="$LOG_DIR/output.raw.txt"
DONE_MARKER="$LOG_DIR/output.raw.done"

REFRESH=0
SCOPE=""
MODE="diag"   # diag | files | fields | quiet
for arg in "$@"; do
  case "$arg" in
    --refresh|-r) REFRESH=1 ;;
    --files|-F) MODE="files" ;;
    --fields)   MODE="fields" ;;
    --quiet|-q) MODE="quiet" ;;
    --help|-h)
      sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*)
      echo "Unknown flag: $arg" >&2
      exit 2
      ;;
    *)
      if [[ -z "$SCOPE" ]]; then
        SCOPE="$arg"
      else
        echo "Multiple scope args not supported" >&2
        exit 2
      fi
      ;;
  esac
done

# Cache validity: must have completion marker AND be newer than any tracked
# .lua source. Otherwise refresh.
cache_valid() {
  [[ -s "$RAW_OUTPUT" && -f "$DONE_MARKER" ]] || return 1
  local newest_src
  newest_src=$(find client common server main.lua conf.lua -name '*.lua' -newer "$DONE_MARKER" -print -quit 2>/dev/null)
  [[ -z "$newest_src" ]]
}

NEED_RUN=0
if [[ $REFRESH -eq 1 ]]; then
  NEED_RUN=1
elif ! cache_valid; then
  NEED_RUN=1
fi

if [[ $NEED_RUN -eq 1 ]]; then
  if ! command -v lua-language-server >/dev/null 2>&1; then
    echo "lua-language-server not installed." >&2
    echo "  brew install lua-language-server" >&2
    exit 1
  fi

  mkdir -p "$LOG_DIR"
  rm -f "$DONE_MARKER"

  # Build a strict config overlay from .luarc.json. Strips JSONC comments
  # correctly (naive `//[^\n]*` would corrupt the `https://` $schema URL).
  STRICT_CONFIG="$LOG_DIR/luarc.strict.json"
  python3 - "$ROOT/.luarc.json" "$STRICT_CONFIG" <<'PY'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
with open(src) as f:
  raw = f.read()
out, i, in_str, escape = [], 0, False, False
while i < len(raw):
  c = raw[i]
  if escape:
    out.append(c); escape = False; i += 1; continue
  if in_str:
    if c == '\\': out.append(c); escape = True
    elif c == '"': out.append(c); in_str = False
    else: out.append(c)
    i += 1; continue
  if c == '"':
    out.append(c); in_str = True; i += 1; continue
  if c == '/' and i + 1 < len(raw) and raw[i+1] == '/':
    while i < len(raw) and raw[i] != '\n': i += 1
    continue
  out.append(c); i += 1
cfg = json.loads(''.join(out))
cfg.setdefault("diagnostics.neededFileStatus", {})["undefined-field"] = "Any"
cfg["diagnostics.neededFileStatus"]["need-check-nil"] = "Any"
with open(dst, "w") as f:
  json.dump(cfg, f, indent=2)
PY

  # Atomic write: stage to .tmp, rename on success, drop completion marker.
  # Prevents the script from reusing a partial output if a parallel run
  # crashes / gets killed mid-stream.
  echo "Running lua-language-server (full workspace)..." >&2
  TMP="$RAW_OUTPUT.tmp.$$"
  lua-language-server \
    --check="$ROOT" \
    --checklevel=Warning \
    --logpath="$LOG_DIR" \
    --configpath="$STRICT_CONFIG" \
    >"$TMP" 2>&1
  mv "$TMP" "$RAW_OUTPUT"
  date +%s >"$DONE_MARKER"
fi

# Filter to crash-risk diagnostics (and optionally scope). Uses python because
# raw output spans multiple lines per diagnostic.
SCOPE="$SCOPE" MODE="$MODE" CACHED=$([[ $NEED_RUN -eq 0 ]] && echo 1 || echo 0) \
python3 - "$RAW_OUTPUT" <<'PY'
import os, re, sys, collections

CRASH_RISK = {
  "undefined-field",       # method/field doesn't exist on class
  "undefined-global",      # variable not declared anywhere
  "param-type-mismatch",   # wrong arg type passed
  "return-type-mismatch",  # function returns wrong type
  "assign-type-mismatch",  # incompatible assignment
  "missing-return-value",  # function should return but doesn't
  "redundant-parameter",   # extra arg silently dropped
  "cast-local-type",       # bad ---@cast
  "need-check-nil",        # accessing field on possibly-nil value
}

scope = os.environ.get("SCOPE", "")
mode  = os.environ.get("MODE", "diag")
cached = os.environ.get("CACHED") == "1"

with open(sys.argv[1]) as f:
  raw = f.read()

ANSI = re.compile(r'\x1b\[[0-9;]*m')
HEADER = re.compile(r'^[^\s:]+:\d+:\d+ \[(?:Warning|Error|Information|Hint)\]', re.MULTILINE)
CODE = re.compile(r'\(([a-z][a-z0-9-]+)\)\s*$', re.MULTILINE)
PATH = re.compile(r'^([^\s:]+):\d+:\d+ \[')
FIELD = re.compile(r"Undefined field `([^`]+)`")

plain = ANSI.sub('', raw)
header_positions = [m.start() for m in HEADER.finditer(plain)]
records = []  # (code, path, chunk, message)
for idx, start in enumerate(header_positions):
  end = header_positions[idx+1] if idx + 1 < len(header_positions) else len(plain)
  chunk = plain[start:end]
  m = CODE.search(chunk)
  if not m:
    continue
  pm = PATH.match(chunk)
  if not pm:
    continue
  records.append((m.group(1), pm.group(1), chunk))

# Apply scope filter.
in_scope = [r for r in records if (not scope) or r[1].startswith(scope)]

# Tallies.
by_code = collections.Counter()
by_file = collections.Counter()
by_field = collections.Counter()
crash = []
for code, path, chunk in in_scope:
  by_code[code] += 1
  if code in CRASH_RISK:
    by_file[path] += 1
    crash.append((code, path, chunk))
    fm = FIELD.search(chunk)
    if fm:
      by_field[fm.group(1)] += 1

# Render.
if mode == "diag":
  for code, path, chunk in crash:
    print(chunk.rstrip()); print()
elif mode == "files":
  for path, n in by_file.most_common():
    print(f"  {n:4d}  {path}")
  print()
elif mode == "fields":
  for field, n in by_field.most_common():
    print(f"  {n:4d}  {field}")
  print()

print('-' * 60)
src_tag = " (cached)" if cached else ""
if scope:
  print(f"Scope: {scope}{src_tag}")
else:
  print(f"Scope: <full workspace>{src_tag}")
print(f"Total diagnostics in scope: {sum(by_code.values())}")
print(f"Crash-risk diagnostics:     {len(crash)}")
print()
print("By code (crash-risk in scope):")
for code, n in by_code.most_common():
  if code in CRASH_RISK:
    print(f"  {n:4d}  {code}")
if mode != "files" and len(by_file) > 0:
  print()
  print("Top files (crash-risk):")
  for path, n in by_file.most_common(10):
    print(f"  {n:4d}  {path}")
if mode != "fields" and len(by_field) > 0:
  print()
  print("Top undefined fields:")
  for field, n in by_field.most_common(10):
    print(f"  {n:4d}  {field}")

sys.exit(1 if crash else 0)
PY
RC=$?

echo
echo "Raw output: $RAW_OUTPUT"
exit $RC
