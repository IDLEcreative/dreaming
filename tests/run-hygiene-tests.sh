#!/bin/bash
# run-hygiene-tests.sh: test suite for the memory hygiene toolkit.
#
# Covers:
#   - core/memory-hygiene.sh    (each check fires; exemptions hold; never mutates)
#   - core/memory-rebalance.py  (no-op, dry-run, apply, entry conservation, honest failure)
#
# Every fixture is a synthetic memory directory in a temp dir. Nothing here
# touches a real memory root, and the rebalancer, the only component that
# writes, is only ever pointed at $TMPROOT.
#
# Usage: bash tests/run-hygiene-tests.sh   (exit 0 = all pass, 1 = any fail)

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0
TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/dreaming-hygiene-tests.XXXXXX")
trap 'rm -rf "$TMPROOT"' EXIT

HYGIENE="$REPO/core/memory-hygiene.sh"
REBALANCE="$REPO/core/memory-rebalance.py"

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

# ── fixture helpers ─────────────────────────────────
# days_ago_stamp <n> → touch -t stamp for n days back (BSD then GNU date)
days_ago_stamp() {
    date -v-"$1"d +%Y%m%d%H%M 2>/dev/null || date -d "$1 days ago" +%Y%m%d%H%M
}

# new_root <name> → prints a fresh projects-root path containing one project
new_root() {
    local root="$TMPROOT/$1"
    mkdir -p "$root/proj-a/memory"
    printf '%s' "$root"
}

# manifest <dir> → content+layout fingerprint, for the never-mutates check
manifest() {
    find "$1" -type f -print0 2>/dev/null | sort -z | xargs -0 shasum 2>/dev/null
}

# run_hygiene <root> [args...] → sets HYG_OUT + HYG_EXIT.
# Deliberately NOT a command-substitution helper: `out=$(run_hygiene ...)` would
# run the body in a subshell and the exit code would never reach the caller,
# which silently turns every exit-code assertion into a no-op.
HYG_OUT=""
HYG_EXIT=0
run_hygiene() {
    local root="$1"; shift
    HYG_OUT=$(DREAMING_MEMORY_ROOT="$root" bash "$HYGIENE" "$@" 2>&1)
    HYG_EXIT=$?
}

# ════════════════════════════════════════════════════
# memory-hygiene.sh
# ════════════════════════════════════════════════════
echo "memory-hygiene.sh"

# ── clean dir → exit 0, no findings ──
CLEAN=$(new_root clean)
cat > "$CLEAN/proj-a/memory/MEMORY.md" <<'EOF'
# Project Memory [INDEX]

## Notes

- [Alpha](reference_alpha.md) - one-line pointer
EOF
cat > "$CLEAN/proj-a/memory/reference_alpha.md" <<'EOF'
---
type: reference
---
# Alpha
EOF
run_hygiene "$CLEAN"
assert_eq "clean memory dir exits 0" "0" "$HYG_EXIT"
assert_eq "clean memory dir reports nothing" "" "$HYG_OUT"

# ── ORPHAN ──
ORPH=$(new_root orphan)
cp "$CLEAN/proj-a/memory/MEMORY.md" "$ORPH/proj-a/memory/MEMORY.md"
cp "$CLEAN/proj-a/memory/reference_alpha.md" "$ORPH/proj-a/memory/reference_alpha.md"
cat > "$ORPH/proj-a/memory/project_unindexed.md" <<'EOF'
---
type: project
---
# Written but never indexed
EOF
run_hygiene "$ORPH"
assert_eq      "orphan trips a hard failure (exit 1)" "1" "$HYG_EXIT"
assert_contains "orphan is named in the report" "$HYG_OUT" "ORPHAN: project_unindexed.md"

# ── ORPHAN exemptions: index sub-files and _-prefixed working artifacts ──
ORPHX=$(new_root orphan-exempt)
cp "$CLEAN/proj-a/memory/MEMORY.md" "$ORPHX/proj-a/memory/MEMORY.md"
cp "$CLEAN/proj-a/memory/reference_alpha.md" "$ORPHX/proj-a/memory/reference_alpha.md"
echo '# extended' > "$ORPHX/proj-a/memory/MEMORY-extended.md"
echo '# scratch'  > "$ORPHX/proj-a/memory/_scratch.md"
run_hygiene "$ORPHX"
assert_eq "MEMORY-*.md and _*.md are not orphans" "0" "$HYG_EXIT"

# ── BROKEN LINK ──
BROKEN=$(new_root broken)
cat > "$BROKEN/proj-a/memory/MEMORY.md" <<'EOF'
# Project Memory [INDEX]

- [Alpha](reference_alpha.md) - fine
- [Ghost](reference_ghost.md) - target does not exist
EOF
cp "$CLEAN/proj-a/memory/reference_alpha.md" "$BROKEN/proj-a/memory/reference_alpha.md"
run_hygiene "$BROKEN"
assert_eq      "broken link trips a hard failure (exit 1)" "1" "$HYG_EXIT"
assert_contains "broken link names the missing target" "$HYG_OUT" "BROKEN LINK: (reference_ghost.md)"

# ── SIZE ──
SIZE=$(new_root size)
{
    echo "# Project Memory [INDEX]"
    echo ""
    echo "## Notes"
    echo ""
    awk 'BEGIN { for (i = 0; i < 800; i++) printf "- entry %04d - a short one-line index pointer\n", i }'
} > "$SIZE/proj-a/memory/MEMORY.md"
run_hygiene "$SIZE"
assert_eq      "oversized index trips a hard failure (exit 1)" "1" "$HYG_EXIT"
assert_contains "oversized index reports SIZE" "$HYG_OUT" "SIZE: MEMORY.md is"

# ── SIZE NEARING (advisory: printed, but exit stays 0) ──
NEAR=$(new_root nearing)
{
    echo "# Project Memory [INDEX]"
    awk 'BEGIN { for (i = 0; i < 200; i++) printf "- entry %04d - a short one-line index pointer\n", i }'
} > "$NEAR/proj-a/memory/MEMORY.md"
HYG_OUT=$(DREAMING_MEMORY_ROOT="$NEAR" DREAMING_INDEX_BUDGET_BYTES=10000 bash "$HYGIENE" 2>&1)
HYG_EXIT=$?
assert_eq      "size-nearing is advisory only (exit 0)" "0" "$HYG_EXIT"
assert_contains "size-nearing is reported" "$HYG_OUT" "SIZE NEARING"

# ── LONGLINE ──
LONG=$(new_root longline)
{
    echo "# Project Memory [INDEX]"
    awk 'BEGIN { printf "- [Alpha](reference_alpha.md) - "; for (i = 0; i < 320; i++) printf "x"; printf "\n" }'
} > "$LONG/proj-a/memory/MEMORY.md"
cp "$CLEAN/proj-a/memory/reference_alpha.md" "$LONG/proj-a/memory/reference_alpha.md"
run_hygiene "$LONG"
assert_eq      "over-long index line trips a hard failure (exit 1)" "1" "$HYG_EXIT"
assert_contains "over-long line is reported" "$HYG_OUT" "LONG LINES: 1 index entries"

# ── RETIRE: positive control + the feedback/user exemption ──
# Both topic files are stale and both carry a "done" marker. Only the
# non-directive one may be offered for retirement.
RET=$(new_root retire)
cat > "$RET/proj-a/memory/MEMORY.md" <<'EOF'
# Project Memory [INDEX]

- [Old migration](project_old_migration.md) - shipped, completed
- [Standing directive](feedback_standing.md) - shipped, completed
- [User preference](user_preference.md) - shipped, completed
EOF
cat > "$RET/proj-a/memory/project_old_migration.md" <<'EOF'
---
type: project
---
# Old migration
EOF
cat > "$RET/proj-a/memory/feedback_standing.md" <<'EOF'
---
type: feedback
---
# Standing directive
EOF
cat > "$RET/proj-a/memory/user_preference.md" <<'EOF'
---
type: user
---
# User preference
EOF
STAMP=$(days_ago_stamp 60)
touch -t "$STAMP" "$RET/proj-a/memory/project_old_migration.md" \
                  "$RET/proj-a/memory/feedback_standing.md" \
                  "$RET/proj-a/memory/user_preference.md"
run_hygiene "$RET"
assert_eq          "retire candidates are advisory only (exit 0)" "0" "$HYG_EXIT"
assert_contains    "stale project-type file IS offered for retirement" "$HYG_OUT" "RETIRE-CANDIDATE: project_old_migration.md"
assert_not_contains "stale feedback-type file is NEVER offered (standing directive)" "$HYG_OUT" "feedback_standing.md"
assert_not_contains "stale user-type file is NEVER offered (standing directive)" "$HYG_OUT" "user_preference.md"

# ── RETIRE keep-guard: a live-knowledge marker suppresses the candidate ──
KEEP=$(new_root retire-keepguard)
cat > "$KEEP/proj-a/memory/MEMORY.md" <<'EOF'
# Project Memory [INDEX]

- [Old migration](project_old_migration.md) - shipped, but canonical - do not remove
EOF
cat > "$KEEP/proj-a/memory/project_old_migration.md" <<'EOF'
---
type: project
---
# Old migration
EOF
touch -t "$STAMP" "$KEEP/proj-a/memory/project_old_migration.md"
run_hygiene "$KEEP"
assert_not_contains "keep-guard suppresses retirement of still-live knowledge" "$HYG_OUT" "RETIRE-CANDIDATE"

# ── ROT: a reference-type file citing a dead absolute path ──
ROT=$(new_root rot)
cat > "$ROT/proj-a/memory/MEMORY.md" <<'EOF'
# Project Memory [INDEX]

- [Alpha](reference_alpha.md) - cites a path
EOF
cat > "$ROT/proj-a/memory/reference_alpha.md" <<EOF
---
type: reference
---
# Alpha
The handler lives at $HOME/definitely-not-a-real-path-9f3a/handler.ts
EOF
run_hygiene "$ROT"
assert_eq      "reference rot is advisory only (exit 0)" "0" "$HYG_EXIT"
assert_contains "dead cited path is reported" "$HYG_OUT" "ROT: reference_alpha.md cites missing path"

# ── --project filter ──
MULTI=$(new_root multi)
mkdir -p "$MULTI/proj-b/memory"
cp "$ORPH/proj-a/memory/MEMORY.md"            "$MULTI/proj-a/memory/MEMORY.md"
cp "$ORPH/proj-a/memory/reference_alpha.md"   "$MULTI/proj-a/memory/reference_alpha.md"
cp "$ORPH/proj-a/memory/project_unindexed.md" "$MULTI/proj-a/memory/project_unindexed.md"
cp "$CLEAN/proj-a/memory/MEMORY.md"           "$MULTI/proj-b/memory/MEMORY.md"
cp "$CLEAN/proj-a/memory/reference_alpha.md"  "$MULTI/proj-b/memory/reference_alpha.md"
run_hygiene "$MULTI" --project proj-b
assert_eq "--project scopes the sweep to a clean project (exit 0)" "0" "$HYG_EXIT"
run_hygiene "$MULTI" --project PROJ-A
assert_eq "--project match is case-insensitive" "1" "$HYG_EXIT"

# ── the linter NEVER mutates ──
# Run against a dirty tree so every check (including the advisory ones that
# read topic files) actually executes, then compare the fingerprint.
MUT=$(new_root nomutate)
cp "$RET/proj-a/memory/"*.md "$MUT/proj-a/memory/"
cp "$ORPH/proj-a/memory/project_unindexed.md" "$MUT/proj-a/memory/"
cat >> "$MUT/proj-a/memory/MEMORY.md" <<'EOF'
- [Ghost](reference_ghost.md) - missing target
EOF
touch -t "$STAMP" "$MUT/proj-a/memory/project_old_migration.md"
BEFORE=$(manifest "$MUT")
run_hygiene "$MUT"
AFTER=$(manifest "$MUT")
assert_eq "dirty fixture really does trip the linter (exit 1)" "1" "$HYG_EXIT"
assert_eq "linter never mutates the memory dir" "$BEFORE" "$AFTER"

# ── missing memory root is a no-op, not a crash ──
run_hygiene "$TMPROOT/does-not-exist"
assert_eq      "missing memory root exits 0" "0" "$HYG_EXIT"
assert_contains "missing memory root says so" "$HYG_OUT" "no memory root at"

# ════════════════════════════════════════════════════
# memory-rebalance.py
# ════════════════════════════════════════════════════
echo ""
echo "memory-rebalance.py"

# Builds an index with three "## " sections plus the pinned pointer section.
# entries_per_section is tuned so the file lands well over the test budget.
make_index() { # <path> <entries-per-section>
    local path="$1" n="$2"
    {
        echo "# Project Memory [INDEX]"
        echo ""
        for sect in "Standing Directives" "Feature Work" "Old Experiments"; do
            echo "## $sect"
            echo ""
            awk -v n="$n" -v s="$sect" 'BEGIN {
                for (i = 0; i < n; i++)
                    printf "- [%s %03d](topic_%s_%03d.md) - a one-line pointer with some body text\n", s, i, s, i
            }'
            echo ""
        done
        echo "## More memory (load on demand)"
        echo ""
        echo "- Everything else -> MEMORY-extended.md"
    } > "$path"
}

# Fixture sizing (measured): with 40 entries each the sections are ~4145 /
# ~3578 / ~3821 bytes, preamble + pinned ~99. A 8000 B budget therefore keeps
# exactly two sections and moves one, which is what makes the priority-order
# assertions below meaningful. A budget smaller than any single section would
# move everything and the assertions would pass vacuously.
RB_BUDGET=8000
RB="$TMPROOT/rebalance/memory"
mkdir -p "$RB"
make_index "$RB/MEMORY.md" 40
TOTAL_ENTRIES=$(grep -c '^- ' "$RB/MEMORY.md")

# ── under budget → no-op ──
rb_out=$(DREAMING_REBALANCE_TARGET_BYTES=999999 python3 "$REBALANCE" --dir "$RB" 2>&1)
rb_exit=$?
assert_eq      "under budget exits 0" "0" "$rb_exit"
assert_contains "under budget is a no-op" "$rb_out" "healthy, no-op"

# ── over budget, dry-run → reports but does not write ──
RB_BEFORE=$(manifest "$TMPROOT/rebalance")
rb_out=$(DREAMING_REBALANCE_TARGET_BYTES=$RB_BUDGET python3 "$REBALANCE" --dir "$RB" 2>&1)
rb_exit=$?
RB_AFTER=$(manifest "$TMPROOT/rebalance")
assert_eq      "dry-run exits 0" "0" "$rb_exit"
assert_contains "dry-run says it is a dry-run" "$rb_out" "(dry-run"
assert_contains "dry-run names the sections it would move" "$rb_out" "moved sections:"
assert_eq      "dry-run writes nothing" "$RB_BEFORE" "$RB_AFTER"

# ── over budget, --apply → moves sections, conserves entries, backs up ──
rb_out=$(DREAMING_REBALANCE_TARGET_BYTES=$RB_BUDGET python3 "$REBALANCE" --dir "$RB" --apply 2>&1)
rb_exit=$?
assert_eq      "apply exits 0" "0" "$rb_exit"
assert_contains "apply reports it wrote" "$rb_out" "APPLIED"
if [ -f "$RB/MEMORY.md.bak-rebalance" ]; then ok "apply backs up the core index"
else bad "apply backs up the core index"; fi
if [ -f "$RB/MEMORY-extended.md" ]; then ok "apply creates the extended index"
else bad "apply creates the extended index"; fi

CORE_ENTRIES=$(grep -c '^- ' "$RB/MEMORY.md")
EXT_ENTRIES=$(grep -c '^- ' "$RB/MEMORY-extended.md")
assert_eq "no entry is lost in the move" "$TOTAL_ENTRIES" "$((CORE_ENTRIES + EXT_ENTRIES))"

# The move must be real, not a rename: something has to land in extended.
if [ "$EXT_ENTRIES" -gt 0 ]; then ok "entries actually moved to the extended index"
else bad "entries actually moved to the extended index" "extended has 0 entries"; fi

NEW_BYTES=$(wc -c < "$RB/MEMORY.md" | tr -d ' ')
if [ "$NEW_BYTES" -le "$RB_BUDGET" ]; then ok "core index is under budget after the move"
else bad "core index is under budget after the move" "still $NEW_BYTES bytes"; fi

assert_contains "highest-priority section stays in core" "$(cat "$RB/MEMORY.md")" "## Standing Directives"
assert_contains "pinned section stays in core" "$(cat "$RB/MEMORY.md")" "## More memory"
assert_eq "pinned section is last in core" "## More memory (load on demand)" \
          "$(grep '^## ' "$RB/MEMORY.md" | tail -1)"
assert_contains "the demoted section landed in extended" "$(cat "$RB/MEMORY-extended.md")" "## Old Experiments"

# ── idempotent: a second apply is a no-op ──
rb_out=$(DREAMING_REBALANCE_TARGET_BYTES=$RB_BUDGET python3 "$REBALANCE" --dir "$RB" --apply 2>&1)
assert_contains "second apply is a no-op" "$rb_out" "healthy, no-op"

# ── DREAMING_CORE_SECTIONS reorders what survives in core ──
RB2="$TMPROOT/rebalance2/memory"
mkdir -p "$RB2"
make_index "$RB2/MEMORY.md" 40
rb_out=$(DREAMING_REBALANCE_TARGET_BYTES=$RB_BUDGET \
      DREAMING_CORE_SECTIONS="Old Experiments,Feature Work" \
      python3 "$REBALANCE" --dir "$RB2" --apply 2>&1)
assert_contains "DREAMING_CORE_SECTIONS keeps the configured section" "$(cat "$RB2/MEMORY.md")" "## Old Experiments"
assert_not_contains "DREAMING_CORE_SECTIONS demotes an unlisted section" "$(cat "$RB2/MEMORY.md")" "## Standing Directives"

# ── oversized but unsectioned → honest failure, no write ──
RB3="$TMPROOT/rebalance3/memory"
mkdir -p "$RB3"
{
    echo "# Project Memory [INDEX]"
    awk 'BEGIN { for (i = 0; i < 400; i++) printf "- entry %04d with no section header anywhere in the file\n", i }'
} > "$RB3/MEMORY.md"
RB3_BEFORE=$(manifest "$TMPROOT/rebalance3")
rb_out=$(DREAMING_REBALANCE_TARGET_BYTES=$RB_BUDGET python3 "$REBALANCE" --dir "$RB3" --apply 2>&1)
rb_exit=$?
RB3_AFTER=$(manifest "$TMPROOT/rebalance3")
assert_eq      "unfixable index exits 2 (cannot auto-fix)" "2" "$rb_exit"
assert_contains "unfixable index says archiving is needed" "$rb_out" "needs manual archiving"
assert_eq      "unfixable index is left untouched" "$RB3_BEFORE" "$RB3_AFTER"

# ── no target directory → usage error, not a guess at the real memory root ──
rb_out=$(python3 "$REBALANCE" 2>&1)
rb_exit=$?
assert_eq      "missing --dir exits 1" "1" "$rb_exit"
assert_contains "missing --dir explains itself" "$rb_out" "no target directory"

# ── summary ──
echo ""
echo "─────────────────────────────────"
printf "  passed: %d   failed: %d\n" "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
    echo "  VERDICT: FAIL"
    exit 1
fi
echo "  VERDICT: PASS"
