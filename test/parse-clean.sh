#!/usr/bin/env bash
# Assert that one or more .jac files parse with zero ERROR/MISSING nodes.
# Usage: test/parse-clean.sh <file.jac> [more.jac ...]
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Prefer a locally installed CLI, fall back to one on PATH.
TS="$ROOT/node_modules/.bin/tree-sitter"
[ -x "$TS" ] || TS="tree-sitter"

status=0
for f in "$@"; do
  if out="$("$TS" parse "$f" 2>&1)" && ! grep -q -E 'ERROR|MISSING' <<<"$out"; then
    echo "ok   $f"
  else
    echo "FAIL $f"
    grep -nE 'ERROR|MISSING' <<<"$out" | head -5
    status=1
  fi
done
exit $status
