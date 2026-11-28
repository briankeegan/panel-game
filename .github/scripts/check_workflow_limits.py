#!/usr/bin/env python3
"""Fail before GitHub does: a workflow GitHub cannot parse refuses EVERY dispatch (HTTP 422),
so a bot that needs a restart or a handover cannot get one.

GitHub's limit: any value that contains ${{ }} is one expression, and an expression can be at most
21000 characters (a whole `run:` script counts). This check fails at 18000 to leave headroom.
Fix a long step by moving ${{ }} into the step's env: and reading $VARS in the script.

Usage: python3 .github/scripts/check_workflow_limits.py [workflow files...]  (default: all of .github/workflows)
"""
import glob, sys
import yaml

LIMIT, WARN_AT = 21000, 18000
MAX_DISPATCH_INPUTS = 25

def walk(node, path):
    if isinstance(node, dict):
        for k, v in node.items():
            yield from walk(v, path + [str(k)])
    elif isinstance(node, list):
        for i, v in enumerate(node):
            name = v.get("name") or v.get("id") or v.get("uses") if isinstance(v, dict) else None
            yield from walk(v, path + [f"[{i}]{' ' + str(name) if name else ''}"])
    elif isinstance(node, str):
        yield path, node

bad = 0
files = sys.argv[1:] or sorted(glob.glob(".github/workflows/*.yml") + glob.glob(".github/workflows/*.yaml"))
for f in files:
    try:
        doc = yaml.safe_load(open(f))
    except yaml.YAMLError as e:
        print(f"::error file={f}::not valid YAML: {e}"); bad += 1; continue
    biggest = 0
    for path, s in walk(doc, []):
        if "${{" not in s:
            continue
        biggest = max(biggest, len(s))
        if len(s) >= WARN_AT:
            print(f"::error file={f}::{' > '.join(path)}: {len(s)} chars with ${{{{ }}}} in it "
                  f"(GitHub rejects the whole file at {LIMIT}; this check stops at {WARN_AT}). "
                  "Move the ${{ }} into env: and read $VARS.")
            bad += 1
    on = doc.get("on", doc.get(True, {})) or {}
    wd = on.get("workflow_dispatch") if isinstance(on, dict) else None
    n = len((wd or {}).get("inputs") or {}) if isinstance(wd, dict) else 0
    if n > MAX_DISPATCH_INPUTS:
        print(f"::error file={f}::{n} workflow_dispatch inputs (GitHub allows {MAX_DISPATCH_INPUTS})"); bad += 1
    print(f"{f}: ok so far, longest expression {biggest} chars" if not bad else f"{f}: checked")
sys.exit(1 if bad else 0)
