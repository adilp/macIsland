#!/usr/bin/env bash
#
# idle-memory-check.sh — the app-process half of the idle-memory ceiling
# (perf spec §1.3 / §5.1: "Launch, settle, assert phys footprint under ceiling").
#
# The headless `PerformanceBudgetTests.test_idleFootprint_underCeiling` measures the
# test host, which bears none of the shipped SwiftUI-on-AppKit framework baseline — so
# it only guards the *core target*. This script measures the **real resident app
# process** and is the authoritative ≤100 MB check: run it before a release, or as a
# gating CI step on a runner with a window server.
#
# Reads phys footprint via `vmmap --summary` (the same "Physical footprint" number as
# Activity Monitor's "Memory" column) — no sudo required for a same-user process.
#
# Usage:
#   Scripts/idle-memory-check.sh                # build, launch, settle 10s, assert <100 MB
#   CEILING_MB=100 SETTLE_SECS=10 Scripts/idle-memory-check.sh
#   Scripts/idle-memory-check.sh --pid 1234     # measure an already-running pid instead
set -euo pipefail

CEILING_MB="${CEILING_MB:-100}"
SETTLE_SECS="${SETTLE_SECS:-10}"

# Parse a `vmmap` "Physical footprint" value (e.g. "2089K", "48.3M", "1.2G") to whole MB.
footprint_mb() {
  local pid="$1"
  local raw
  raw="$(vmmap --summary "$pid" 2>/dev/null \
    | awk -F: '/Physical footprint:/{gsub(/[ \t]/,"",$2); print $2; exit}')"
  if [[ -z "$raw" ]]; then
    echo "ERROR: could not read phys footprint for pid $pid" >&2
    return 1
  fi
  # Split the numeric part from the K/M/G suffix and normalise to MB.
  local num unit
  num="${raw%[KMGkmg]}"
  unit="${raw: -1}"
  awk -v n="$num" -v u="$unit" 'BEGIN {
    u = toupper(u)
    if (u == "K") n = n / 1024
    else if (u == "G") n = n * 1024
    printf "%.0f", n
  }'
}

# --- Measure an existing pid and exit (used to self-test the parser) ---
if [[ "${1:-}" == "--pid" ]]; then
  mb="$(footprint_mb "$2")"
  echo "pid $2 phys footprint: ${mb} MB (ceiling ${CEILING_MB} MB)"
  [[ "$mb" -lt "$CEILING_MB" ]] || { echo "FAIL: over ceiling" >&2; exit 1; }
  exit 0
fi

# --- Build, launch, settle, measure, assert, clean up ---
echo "Building MacIslandApp (release)…"
swift build -c release --product MacIslandApp >/dev/null

BIN="$(swift build -c release --product MacIslandApp --show-bin-path)/MacIslandApp"
[[ -x "$BIN" ]] || { echo "ERROR: app binary not found at $BIN" >&2; exit 1; }

echo "Launching $BIN and settling ${SETTLE_SECS}s…"
"$BIN" &
APP_PID=$!
cleanup() { kill "$APP_PID" 2>/dev/null || true; }
trap cleanup EXIT

sleep "$SETTLE_SECS"
if ! kill -0 "$APP_PID" 2>/dev/null; then
  echo "ERROR: app exited during settle (needs a window server — run on a windowed runner)" >&2
  exit 1
fi

MB="$(footprint_mb "$APP_PID")"
echo "Idle phys footprint: ${MB} MB (ceiling ${CEILING_MB} MB)"
if [[ "$MB" -ge "$CEILING_MB" ]]; then
  echo "FAIL: idle memory ${MB} MB exceeds the ${CEILING_MB} MB ceiling (spec §1.3)" >&2
  exit 1
fi
echo "PASS"
