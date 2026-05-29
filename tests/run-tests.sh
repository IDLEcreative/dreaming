#!/bin/bash
# run-tests.sh — test suite for dreaming's core logic.
#
# Covers:
#   - core/lib/render-prompt.sh   (path templating correctness)
#   - core/dream-quality-check.sh (each fitness rule R1-R7 fires correctly)
#
# These are the two pieces whose silent breakage would be worst: a render bug
# sends the LLM at the wrong paths; a fitness bug lets degradation through.
#
# Usage: bash tests/run-tests.sh   (exit 0 = all pass, 1 = any fail)

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0
TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/dreaming-tests.XXXXXX")
trap 'rm -rf "$TMPROOT"' EXIT

# ── assertion helpers ───────────────────────────────
ok()   { PASS=$((PASS+1)); printf "  \033[32m✓\033[0m %s\n" "$1"; }
bad()  { FAIL=$((FAIL+1)); printf "  \033[31m✗\033[0m %s\n" "$1"; [ -n "${2:-}" ] && printf "      %s\n" "$2"; }

assert_eq() { # <desc> <expected> <actual>
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi
}
assert_contains() { # <desc> <haystack> <needle>
    if printf '%s' "$2" | grep -qF "$3"; then ok "$1"; else bad "$1" "missing [$3]"; fi
}
assert_not_contains() { # <desc> <haystack> <needle>
    if printf '%s' "$2" | grep -qF "$3"; then bad "$1" "unexpectedly found [$3]"; else ok "$1"; fi
}

# ════════════════════════════════════════════════════
# render-prompt.sh
# ════════════════════════════════════════════════════
echo "render-prompt.sh"
. "$REPO/core/lib/render-prompt.sh"

RP_TMPL="$TMPROOT/tmpl.md"
RP_OUT="$TMPROOT/out.md"
cat > "$RP_TMPL" <<'EOF'
read: ${MEMORY_ROOT}/proj/memory/
cross: ${CROSS_PROJECT_ROOT}/memory/
config: ${AGENT_CONFIG_HOME}/CLAUDE.md
state: ${DREAMING_HOME}/dream-history.md
runtime-ref-untouched: $DREAM_RUN_ID and $jsonl
EOF

# Default resolution
DREAMING_HOME="$TMPROOT/dh" dreaming_render_prompt "$RP_TMPL" "$RP_OUT"
rendered=$(cat "$RP_OUT")
assert_eq      "no unsubstituted \${} tokens remain" "0" "$(grep -c '\${' "$RP_OUT")"
assert_contains "MEMORY_ROOT → DREAMING_HOME/projects" "$rendered" "$TMPROOT/dh/projects/proj/memory/"
assert_contains "CROSS_PROJECT_ROOT default → -Users-<whoami>" "$rendered" "$TMPROOT/dh/projects/-Users-$(whoami)/memory/"
assert_contains "AGENT_CONFIG_HOME default → ~/.claude" "$rendered" "$HOME/.claude/CLAUDE.md"
assert_contains "DREAMING_HOME → state path" "$rendered" "$TMPROOT/dh/dream-history.md"
assert_contains "runtime \$DREAM_RUN_ID left untouched" "$rendered" '$DREAM_RUN_ID'
assert_contains "runtime \$jsonl left untouched" "$rendered" '$jsonl'

# Override resolution
DREAMING_HOME="$TMPROOT/dh" \
DREAMING_AGENT_CONFIG="$TMPROOT/custom-config" \
DREAMING_CROSS_PROJECT_ROOT="$TMPROOT/custom-xp" \
    dreaming_render_prompt "$RP_TMPL" "$RP_OUT"
rendered=$(cat "$RP_OUT")
assert_contains "DREAMING_AGENT_CONFIG override respected" "$rendered" "$TMPROOT/custom-config/CLAUDE.md"
assert_contains "DREAMING_CROSS_PROJECT_ROOT override respected" "$rendered" "$TMPROOT/custom-xp/memory/"

# ════════════════════════════════════════════════════
# dream-quality-check.sh — fixtures
# ════════════════════════════════════════════════════
echo ""
echo "dream-quality-check.sh"

QC="$REPO/core/dream-quality-check.sh"
QC_HOME="$TMPROOT/qc-home"
mkdir -p "$QC_HOME/projects/proj-a/memory" "$QC_HOME/dream-logs"
# One clean memory file with a valid self-referential wiki-link target
cat > "$QC_HOME/projects/proj-a/memory/alpha.md" <<'EOF'
# Alpha
Related: [[beta]]
EOF
cat > "$QC_HOME/projects/proj-a/memory/beta.md" <<'EOF'
# Beta
EOF

# A log that should pass all of R1-R5 (R6/R7 depend on the tree/queue state)
make_passing_log() {
    cat > "$1" <<'EOF'
## RUN SUMMARY

**Audited:** 10 files / 2 projects / split: 3 cross-project + 7 project-local
**Sessions harvested:** 5 sessions / 2 matches / 1 denylist drops
**Memory delta vs last dream run:** 2 added / 0 trimmed / +5 KB
**Merged:** none.
**Examined but did not merge:**
- Cluster `theme-x`: [file_a.md, file_b.md]. Why kept distinct: different layers.
**Trimmed:** none.
**Deferred:**
- thing-y: needs more signal. **Re-trigger:** 2026-09.
**Caps hit:**
- none.

DREAM RUN COMPLETE — merged 0 / trimmed 0 / synth-live 0 / synth-pending 0 / caps none
EOF
}

run_qc() { # <log> → prints verdict (pass|fail)
    DREAMING_HOME="$QC_HOME" bash "$QC" --log "$1" --json 2>/dev/null \
        | python3 -c 'import sys,json; print(json.load(sys.stdin)["verdict"])' 2>/dev/null
}
run_qc_failures() { # <log> → prints failure rule IDs joined
    DREAMING_HOME="$QC_HOME" bash "$QC" --log "$1" --json 2>/dev/null \
        | python3 -c 'import sys,json; print(" ".join(f.split(":")[0] for f in json.load(sys.stdin)["failures"]))' 2>/dev/null
}

LOG="$TMPROOT/run.log"

# Baseline: clean log + clean tree + no pending → PASS
make_passing_log "$LOG"
assert_eq "baseline clean run → pass" "pass" "$(run_qc "$LOG")"

# R1: insight box present → fail
make_passing_log "$LOG"
cat >> "$LOG" <<'EOF'

★ Insight ─────────────────────────────────────
this is filler that should be caught
─────────────────────────────────────────────────
EOF
assert_contains "R1 fires on a real insight box" "$(run_qc_failures "$LOG")" "R1"

# R1 false-positive guard: a bare mention of the phrase (no box shape) → still pass
make_passing_log "$LOG"
printf '\nNote: do not emit ★ Insight ─── blocks in the summary.\n' >> "$LOG"
assert_eq "R1 ignores substring mention (no box shape)" "pass" "$(run_qc "$LOG")"

# R2: audited line without cross-project split → fail
make_passing_log "$LOG"
sed -i.bak 's/.*Audited:.*/**Audited:** 10 files \/ 2 projects/' "$LOG" && rm -f "$LOG.bak"
assert_contains "R2 fires when audited split missing" "$(run_qc_failures "$LOG")" "R2"

# R3: memory delta line missing → fail
make_passing_log "$LOG"
grep -v "Memory delta vs last dream run" "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
assert_contains "R3 fires when memory-delta line missing" "$(run_qc_failures "$LOG")" "R3"

# R4: deferred item without re-trigger → fail
make_passing_log "$LOG"
perl -0pi -e 's/- thing-y: needs more signal\. \*\*Re-trigger:\*\* 2026-09\./- thing-y: needs more signal./' "$LOG"
assert_contains "R4 fires when a deferred item lacks re-trigger" "$(run_qc_failures "$LOG")" "R4"

# R5: examined cluster without filename citation → fail
make_passing_log "$LOG"
perl -0pi -e 's/- Cluster `theme-x`: \[file_a\.md, file_b\.md\]\. Why kept distinct: different layers\./- Cluster `theme-x`: four worktree files. Why kept distinct: different layers./' "$LOG"
assert_contains "R5 fires when examined cluster lacks filenames" "$(run_qc_failures "$LOG")" "R5"

# R6: broken wiki-link in a recent memory file → fail
make_passing_log "$LOG"
echo 'Related: [[does_not_exist]]' >> "$QC_HOME/projects/proj-a/memory/alpha.md"
assert_contains "R6 fires on a broken wiki-link" "$(run_qc_failures "$LOG")" "R6"
# R6 code-span guard: bracket syntax inside backticks is NOT a wiki-link
git checkout "$QC_HOME/projects/proj-a/memory/alpha.md" 2>/dev/null || cat > "$QC_HOME/projects/proj-a/memory/alpha.md" <<'EOF'
# Alpha
Related: [[beta]]
EOF
echo 'Route file: `app/_sites/[slug]/[[...path]]/route.ts`' >> "$QC_HOME/projects/proj-a/memory/alpha.md"
assert_eq "R6 ignores [[...]] inside code spans" "pass" "$(run_qc "$LOG")"
# reset alpha.md to clean
cat > "$QC_HOME/projects/proj-a/memory/alpha.md" <<'EOF'
# Alpha
Related: [[beta]]
EOF

# R7: pending-review dir aged >7d → fail
make_passing_log "$LOG"
STALE_PENDING="$QC_HOME/projects/proj-a/memory/_pending_review/2026-01-01T00-00-00-old"
mkdir -p "$STALE_PENDING"
echo "stale proposal" > "$STALE_PENDING/merge_x.md"
# Backdate the dir mtime to >7 days ago
touch -t "$(date -v-10d +%Y%m%d%H%M 2>/dev/null || date -d '10 days ago' +%Y%m%d%H%M)" "$STALE_PENDING"
assert_contains "R7 fires on pending-review aged >7d" "$(run_qc_failures "$LOG")" "R7"
rm -rf "$QC_HOME/projects/proj-a/memory/_pending_review"

# ── summary ──
echo ""
echo "─────────────────────────────────"
printf "  passed: %d   failed: %d\n" "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
    echo "  VERDICT: FAIL"
    exit 1
fi
echo "  VERDICT: PASS"
