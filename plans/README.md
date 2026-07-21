# Animation plans

| # | Title | Severity | Status |
|---|-------|----------|--------|
| [001](001-unify-pill-expand-motion.md) | Unify the pill→card hover-expand motion | HIGH | DONE |
| [002](002-meeting-escalation-morph.md) | Meeting T-5→T-1 escalation morph | MEDIUM | DONE |
| [003](003-button-press-feedback.md) | Button press feedback (Open run / Join / ✕) | HIGH | DONE |

## Execution order

1. **001** — no dependencies. Unifies the panel-resize and content curves and scopes
   the hover-reveal transition so the pill *unfolds* into the card instead of
   sliding-while-growing.

Executed inline (the diagnosing agent had full context), not via a worktree
executor. Verified: `swift build` clean, full suite green at 165. Feel-check is
still worth doing live — hover a running-deploy pill and confirm the unfold reads as
one coordinated motion.
