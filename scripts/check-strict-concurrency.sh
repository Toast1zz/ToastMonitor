#!/bin/bash
# Fails when a strict-concurrency build has more distinct warnings than the
# recorded baseline, so new data-race risks cannot slip in unnoticed while the
# existing ones are worked down. Lower the baseline whenever the count falls.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OWNED_SCRATCH=""
if [[ -n "${1:-}" ]]; then
    SCRATCH="$1"
else
    SCRATCH="$(mktemp -d)"
    OWNED_SCRATCH="$SCRATCH"
fi
BASELINE_FILE="$ROOT/scripts/strict-concurrency-baseline.txt"
LOG="$(mktemp)"
trap 'rm -f "$LOG"; if [[ -n "$OWNED_SCRATCH" ]]; then rm -rf "$OWNED_SCRATCH"; fi' EXIT
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
