#!/usr/bin/env zsh
# Static type-check Lua sources via lua-language-server (LuaLS).
#
# Reads .luarc.json, enables undefined-field, then filters output to
# diagnostic codes that indicate likely runtime crashes (missing methods,
# wrong arg types, undefined globals, bad returns). Noise-only categories
# (annotation typos, intentional duplicate set fields, internal-field access
# in tests) are suppressed.
#
# Usage:  zsh run_lua_check.sh
# Exit:   0 if zero crash-risk diagnostics, 1 otherwise.

set -u

ROOT="${0:A:h}"
cd "$ROOT"

if ! command -v lua-language-server >/dev/null 2>&1; then
  echo "lua-language-server not installed."
  echo "  brew install lua-language-server"
  exit 1
fi

LOG_DIR="$ROOT/.luals-check"
mkdir -p "$LOG_DIR"

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
with open(dst, "w") as f:
  json.dump(cfg, f, indent=2)
PY

RAW_OUTPUT="$LOG_DIR/output.raw.txt"
lua-language-server \
  --check="$ROOT" \
  --checklevel=Warning \
  --logpath="$LOG_DIR" \
  --configpath="$STRICT_CONFIG" \
  >"$RAW_OUTPUT" 2>&1

# Filter to crash-risk diagnostics only. Uses python because the raw output
# spans multiple lines per diagnostic (header line + code snippet line +
# pointer line) and zsh/awk are awkward for stanza-based filtering.
python3 - "$RAW_OUTPUT" <<'PY'
import re, sys, collections

CRASH_RISK = {
  "undefined-field",       # method/field doesn't exist on class
  "undefined-global",      # variable not declared anywhere
  "param-type-mismatch",   # wrong arg type passed
  "return-type-mismatch",  # function returns wrong type
  "assign-type-mismatch",  # incompatible assignment
  "missing-return-value",  # function should return but doesn't
  "redundant-parameter",   # extra arg silently dropped
  "cast-local-type",       # bad ---@cast
}

with open(sys.argv[1]) as f:
  raw = f.read()

# Strip ANSI for the regex scan but keep the original for display.
ANSI = re.compile(r'\x1b\[[0-9;]*m')

# Each diagnostic looks like:
#   <file>:<line>:<col> [Warning] <message...possibly multi-line...>(<code>)
#   <code snippet>
#   <pointer>
# The (<code>) closer may be on the header line OR a continuation line.
HEADER = re.compile(r'^[^\s:]+:\d+:\d+ \[(?:Warning|Error|Information|Hint)\]', re.MULTILINE)
CODE = re.compile(r'\(([a-z][a-z0-9-]+)\)\s*$', re.MULTILINE)

plain = ANSI.sub('', raw)
header_positions = [m.start() for m in HEADER.finditer(plain)]
matches = []
for idx, start in enumerate(header_positions):
  end = header_positions[idx+1] if idx + 1 < len(header_positions) else len(plain)
  chunk = plain[start:end]
  # Find the LAST (code) in the chunk that sits on its own message line
  # (i.e. before the code-snippet/pointer lines). Take the first match —
  # later parens in snippets are inside code, not diagnostic codes.
  m = CODE.search(chunk)
  if m:
    matches.append((start, end, m.group(1), chunk))

kept = []
by_code = collections.Counter()
total = 0
for start, end, code, chunk in matches:
  total += 1
  by_code[code] += 1
  if code not in CRASH_RISK:
    continue
  kept.append(chunk.rstrip())

# Print filtered diagnostics.
for entry in kept:
  print(entry)
  print()

# Summary.
print('-' * 60)
print(f"Total diagnostics: {total}")
print(f"Crash-risk shown:  {len(kept)}")
print()
print("By code (all):")
for code, n in by_code.most_common():
  marker = "  [crash-risk]" if code in CRASH_RISK else ""
  print(f"  {n:4d}  {code}{marker}")

sys.exit(1 if kept else 0)
PY
RC=$?

echo
echo "Raw output: $RAW_OUTPUT"
exit $RC
