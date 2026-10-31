#!/bin/bash
# Fails when a strict-concurrency build has more distinct warnings than the
# recorded baseline, so new data-race risks cannot slip in unnoticed while the
# existing ones are worked down. Lower the baseline whenever the count falls.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="${1:-$(mktemp -d)}"
BASELINE_FILE="$ROOT/scripts/strict-concurrency-baseline.txt"
LOG="$(mktemp)"
swift build -c debug --package-path "$ROOT" --scratch-path "$SCRATCH" \
    -Xswiftc -strict-concurrency=complete > "$LOG" 2>&1 || { tail -30 "$LOG"; exit 1; }
# The compiler colors its diagnostics even when the output is a file.
WARNINGS="$(sed $'s/\x1b\\[[0-9;]*m//g' "$LOG" | { grep -E '^/.*: warning: ' || true; } | sed "s|^$ROOT/||" | sort -u)"
COUNT="$(printf '%s\n' "$WARNINGS" | grep -c . || true)"
BASELINE="$(tr -d '[:space:]' < "$BASELINE_FILE")"
echo "strict concurrency warnings: $COUNT (baseline $BASELINE)"
if (( COUNT > BASELINE )); then
    printf '%s\n' "$WARNINGS"
    echo "error: $COUNT warnings is above the baseline of $BASELINE" >&2
    exit 1
fi
