#!/bin/bash
# Stop hook — surfaces aged dream/self-learn proposals waiting in
# `_pending_review/` across all project memory dirs.
#
# Rationale: dream + self-learn are scheduled (cron/launchd) and run
# unattended. They stage proposals to `_pending_review/` and then stop.
# Adoption requires a human running `/promote-dream`. Without a nudge,
# proposals accumulate for days (verified empirically: today's run
# adopted runs from 2026-05-18 that had been waiting 6 days).
#
# Output discipline:
#  - Silent when nothing qualifies (no output = no chat noise)
#  - When proposals are aged >= AGE_DAYS, emit ONE compact line per run
#    to stdout. Claude sees stdout as a system note; the user can decide
#    whether to act.
#  - Never block, never error out. Hook must finish in well under 1s
#    to avoid interrupting the user's flow.

set -uo pipefail

AGE_DAYS="${PENDING_REVIEW_AGE_DAYS:-3}"
PROJECTS_ROOT="${DREAMING_HOME:-$HOME/.dreaming}/projects"
# Backward compat: fall back to ~/.claude/projects if DREAMING_HOME isn't set up yet.
if [ ! -d "$PROJECTS_ROOT" ] && [ -d "$HOME/.claude/projects" ]; then
    PROJECTS_ROOT="$HOME/.claude/projects"
fi
[ -d "$PROJECTS_ROOT" ] || exit 0

# `find` with -mtime treats a fractional day as one full day boundary.
# +N means "modified more than N*24h ago". The earliest mtime in a
# pending_review dir is when dream wrote into it.
aged_runs=()
while IFS= read -r run_dir; do
    [ -d "$run_dir" ] || continue
    proj=$(basename "$(dirname "$(dirname "$run_dir")")")
    run_id=$(basename "$run_dir")
    file_count=$(find "$run_dir" -maxdepth 1 -name '*.md' -type f 2>/dev/null | wc -l | tr -d ' ')
    [ "$file_count" -eq 0 ] && continue
    age_days=$(( ( $(date +%s) - $(stat -f %m "$run_dir" 2>/dev/null || echo 0) ) / 86400 ))
    aged_runs+=("$proj/$run_id ($file_count file$([ "$file_count" -eq 1 ] || echo "s"), ${age_days}d old)")
done < <(find "$PROJECTS_ROOT"/*/memory/_pending_review -maxdepth 1 -mindepth 1 -type d -mtime "+$AGE_DAYS" 2>/dev/null)

[ "${#aged_runs[@]}" -eq 0 ] && exit 0

echo ""
echo "📥 Dream/self-learn proposals waiting for review (>${AGE_DAYS}d old):"
for run in "${aged_runs[@]}"; do
    echo "  • $run"
done
echo "   → run \`dreaming promote\` (or /promote-dream in Claude Code) to review + adopt or discard"

exit 0
