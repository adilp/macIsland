#!/bin/sh
# macIsland deploy-watch nudge (git pre-push hook).
#
# Pokes the running island to fast-poll GitHub Actions the instant you push, so your
# deploy lights up the notch immediately instead of waiting for the idle backoff.
#
# FULLY LOCAL: this lives in .git/hooks/, which git never tracks, commits, or pushes —
# it can't reach other developers. It's a no-op when the island isn't running (the
# support dir is absent), and it never blocks or slows your push (touch is instant,
# and it always exits 0).
#
# Install (run once, per clone you push from):
#   cp /path/to/macIsland/scripts/macisland-prepush-nudge.sh .git/hooks/pre-push
#   chmod +x .git/hooks/pre-push

poke="$HOME/Library/Application Support/macIsland/github.poke"
[ -d "$(dirname "$poke")" ] && touch "$poke" 2>/dev/null
exit 0
