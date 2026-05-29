#!/bin/bash
# Dream/promote-dream fitness function — checks whether the latest
# consolidation run + adopted artefacts followed the contractual rules
# locked into prompts/dream.md and core/promote-dream.sh.
#
# NOT an eval — doesn't judge quality of decisions. Just verifies the rules
# are still being followed mechanically. Catches silent regressions where
# dream's prompt drifts or promote-dream's safety net erodes.
#
# Exit codes:
#   0  = all checks pass
#   1  = one or more checks failed (degradation)
#   2  = no data to check (no dream run in last 24h)
#
# Usage:
#   bash core/dream-quality-check.sh           # check latest run
#   bash core/dream-quality-check.sh --verbose # show passing checks too
#   bash core/dream-quality-check.sh --json    # machine-readable output
#
# Env:
#   DREAMING_HOME — data root (default ~/.dreaming)

set -uo pipefail

VERBOSE=0
JSON=0
LOG_OVERRIDE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --verbose|-v) VERBOSE=1; shift ;;
        --json)       JSON=1; shift ;;
        --log)        LOG_OVERRIDE="${2:-}"; shift 2 ;;
        *) echo "unknown flag: $1" >&2; exit 1 ;;
    esac
done

LOG_DIR="${DREAMING_HOME:-$HOME/.dreaming}/dream-logs"
PROJECTS="${DREAMING_HOME:-$HOME/.dreaming}/projects"

# Resolve which log to check. Explicit --log overrides; default is most recent.
if [ -n "$LOG_OVERRIDE" ]; then
    if [ ! -f "$LOG_OVERRIDE" ]; then
        echo "log file not found: $LOG_OVERRIDE" >&2
        exit 1
    fi
    LATEST_LOG="$LOG_OVERRIDE"
else
    LATEST_LOG=$(find "$LOG_DIR" -maxdepth 1 -name "run-*.log" -type f -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | head -1)
    if [ -z "$LATEST_LOG" ]; then
        echo "no dream runs found in $LOG_DIR — nothing to check"
        exit 2
    fi
fi

# Refuse to check a log older than 30 days — it's archaeology, not signal.
LOG_AGE_DAYS=$(( ( $(date +%s) - $(stat -f %m "$LATEST_LOG" 2>/dev/null || echo 0) ) / 86400 ))
if [ "$LOG_AGE_DAYS" -gt 30 ]; then
    echo "latest dream run is ${LOG_AGE_DAYS} days old (>30d) — skipping check, run /dream first"
    exit 2
fi

declare -a FAILURES=()
declare -a PASSES=()

# ── Rule 1: NO ★ Insight ─── blocks in the run summary ─────────────────
# Counts ACTUAL emitted insight blocks, not substring mentions. A real box
# OPENS the line ("★ Insight ─────"); a mention has the phrase mid-line inside
# prose or backticks ("do not emit `★ Insight ───` blocks"). Anchoring at
# line-start distinguishes them — and avoids matching the multibyte box-drawing
# char with an interval, which BSD awk on macOS gets wrong.
INSIGHT_COUNT=$(grep -cE '^[[:space:]]*★ Insight' "$LATEST_LOG" 2>/dev/null || true)
INSIGHT_COUNT="${INSIGHT_COUNT:-0}"
if [ "$INSIGHT_COUNT" -gt 0 ]; then
    FAILURES+=("R1: $INSIGHT_COUNT insight-box(es) in dream output (rule: zero)")
else
    PASSES+=("R1: no insight-boxes in run summary")
fi

# ── Rule 2: Audited line shows cross-project vs project-local breakdown ──
# Accept either canonical form:
#   "Audited: 252 files / 7 projects / split: 35 cross-project + ..."
# OR the natural-prose breakdown the model often emits:
#   "Audited: 252 markdown files... (Omniops 98 / art-and-algorithms 86 / cross-project 35 / ...)"
# The signature is: the word "cross-project" appearing in the audited summary,
# with a per-project count nearby. Both forms convey the same information.
AUDITED_LINE=$(grep -m1 -A1 "Audited:" "$LATEST_LOG" 2>/dev/null || true)
if echo "$AUDITED_LINE" | grep -qE "(split:.*cross-project|cross-project[^a-z])"; then
    PASSES+=("R2: audited line includes cross-project breakdown")
elif grep -q "Caps hit:.*none\|RUN COMPLETE" "$LATEST_LOG"; then
    FAILURES+=("R2: audited line missing cross-project vs project-local breakdown")
else
    PASSES+=("R2: skipped (run didn't reach summary phase)")
fi

# ── Rule 3: Memory delta line present ──────────────────────────────────
# Format: "Memory delta vs last dream run (<ts>): <N files added / M trimmed / Δ KB>"
if grep -q "Memory delta vs last dream run" "$LATEST_LOG"; then
    PASSES+=("R3: memory delta line present")
elif grep -q "RUN COMPLETE" "$LATEST_LOG"; then
    FAILURES+=("R3: memory delta line missing from completed run")
else
    PASSES+=("R3: skipped (run didn't reach summary phase)")
fi

# ── Rule 4: Deferred items have re-triggers ────────────────────────────
# Every line under "**Deferred:**" must include "Re-trigger:" or "re-trigger:"
# in the same item. Tolerates "**Deferred:** none." as a passing case.
DEFERRED_SECTION=$(awk '/^\*\*Deferred:\*\*/{p=1; next} /^\*\*[A-Z]/{p=0} p' "$LATEST_LOG" 2>/dev/null)
if [ -z "$DEFERRED_SECTION" ] || echo "$DEFERRED_SECTION" | grep -qiE "^- none|^$"; then
    PASSES+=("R4: deferred section empty or 'none' (rule vacuously satisfied)")
else
    DEFERRED_ITEMS=$(echo "$DEFERRED_SECTION" | grep -cE "^- " 2>/dev/null || true)
    DEFERRED_ITEMS="${DEFERRED_ITEMS:-0}"
    DEFERRED_WITH_TRIGGER=$(echo "$DEFERRED_SECTION" | grep -ciE "re-trigger:" 2>/dev/null || true)
    DEFERRED_WITH_TRIGGER="${DEFERRED_WITH_TRIGGER:-0}"
    if [ "$DEFERRED_ITEMS" -eq "$DEFERRED_WITH_TRIGGER" ] && [ "$DEFERRED_ITEMS" -gt 0 ]; then
        PASSES+=("R4: all $DEFERRED_ITEMS deferred items have re-triggers")
    else
        FAILURES+=("R4: $((DEFERRED_ITEMS - DEFERRED_WITH_TRIGGER))/$DEFERRED_ITEMS deferred items missing re-trigger")
    fi
fi

# ── Rule 5: Examined-but-rejected clusters cite files by name ──────────
# Each "Cluster `<theme>`:" line must include a [file_a.md, …] bracketed list.
EXAMINED_SECTION=$(awk '/^\*\*Examined but did not merge:\*\*/{p=1; next} /^\*\*[A-Z]/{p=0} p' "$LATEST_LOG" 2>/dev/null)
if [ -z "$EXAMINED_SECTION" ]; then
    PASSES+=("R5: no examined-but-rejected clusters (rule vacuously satisfied)")
else
    EXAMINED_ITEMS=$(echo "$EXAMINED_SECTION" | grep -cE "^- " 2>/dev/null || true)
    EXAMINED_ITEMS="${EXAMINED_ITEMS:-0}"
    # Accept either bracketed list "[a.md, b.md]" OR backtick-cited paths "`path/file.md`"
    EXAMINED_WITH_FILES=$(echo "$EXAMINED_SECTION" | grep -cE "(\[.*\.md.*\]|\`[^\`]+\.md)" 2>/dev/null || true)
    EXAMINED_WITH_FILES="${EXAMINED_WITH_FILES:-0}"
    if [ "$EXAMINED_ITEMS" -eq "$EXAMINED_WITH_FILES" ] && [ "$EXAMINED_ITEMS" -gt 0 ]; then
        PASSES+=("R5: all $EXAMINED_ITEMS examined clusters cite files by name")
    else
        FAILURES+=("R5: $((EXAMINED_ITEMS - EXAMINED_WITH_FILES))/$EXAMINED_ITEMS examined clusters missing filename citations")
    fi
fi

# ── Rule 6: Broken wiki-links in recently-adopted files ────────────────
# Scans every file modified in the last 7 days under any memory/ dir for
# [[X]] wiki-link references where X.md doesn't exist in the same dir.
# Skips matches inside code spans/fences — Next.js dynamic-route syntax
# like `[slug]/[[...path]]/route.ts` reads as a wiki-link to a naive grep
# but is just a filename literal inside a code span.
BROKEN_LINKS_COUNT=$(PROJECTS_ROOT="$PROJECTS" python3 - <<'PY' 2>/dev/null
import os, re, time
broken = 0
now = time.time()
projects_root = os.environ.get("PROJECTS_ROOT", os.path.expanduser("~/.dreaming/projects"))

def strip_code_regions(text):
    # Drop fenced code blocks first (``` ... ```), then inline code spans (` ... `).
    text = re.sub(r'```[\s\S]*?```', '', text)
    text = re.sub(r'`[^`\n]*`', '', text)
    return text

for root, dirs, files in os.walk(projects_root):
    # Skip _archive and _pending_review subtrees
    dirs[:] = [d for d in dirs if d not in ("_archive", "_pending_review")]
    if "memory" not in root: continue
    for fname in files:
        if not fname.endswith(".md"): continue
        fpath = os.path.join(root, fname)
        try:
            if now - os.path.getmtime(fpath) > 7 * 86400: continue
        except OSError:
            continue
        try:
            body = open(fpath, encoding="utf-8", errors="ignore").read()
        except OSError:
            continue
        body = strip_code_regions(body)
        for link in re.findall(r'\[\[([^\]]+)\]\]', body):
            link_path_md = os.path.join(root, link + ".md")
            link_path_raw = os.path.join(root, link)
            if not (os.path.exists(link_path_md) or os.path.exists(link_path_raw)):
                broken += 1
print(broken)
PY
)
BROKEN_LINKS_COUNT="${BROKEN_LINKS_COUNT:-0}"
if [ "$BROKEN_LINKS_COUNT" -eq 0 ]; then
    PASSES+=("R6: no broken wiki-links in files modified <7d")
else
    FAILURES+=("R6: $BROKEN_LINKS_COUNT broken wiki-link(s) in recently-modified memory files")
fi

# ── Rule 7: Pending review queue not stale ─────────────────────────────
# Counts proposals older than 7 days. The Stop-hook reminder warns at >3
# days; this fitness check escalates to fail at >7 (clearly being ignored).
STALE_PENDING=$(find "$PROJECTS"/*/memory/_pending_review -maxdepth 1 -mindepth 1 -type d -mtime +7 2>/dev/null | wc -l | tr -d ' ')
if [ "$STALE_PENDING" -eq 0 ]; then
    PASSES+=("R7: no pending-review proposals aged >7d")
else
    FAILURES+=("R7: $STALE_PENDING pending-review proposal(s) aged >7d — backlog ignored")
fi

# ── Output ──
if [ "$JSON" -eq 1 ]; then
    # Each pass/failure goes as a separate argv element so python can keep them
    # discrete — earlier attempt joined with ${PASSES[*]} (space) and split on '|'
    # which collapsed all entries into one string. Sentinels mark the boundary.
    python3 - "$LATEST_LOG" \
        "--passes--" "${PASSES[@]+"${PASSES[@]}"}" \
        "--failures--" "${FAILURES[@]+"${FAILURES[@]}"}" <<'PY'
import json, sys
log = sys.argv[1]
passes, failures, mode = [], [], None
for a in sys.argv[2:]:
    if a == "--passes--":   mode = "p"; continue
    if a == "--failures--": mode = "f"; continue
    if mode == "p": passes.append(a)
    elif mode == "f": failures.append(a)
print(json.dumps({
    "log": log,
    "passes": passes,
    "failures": failures,
    "score": f"{len(passes)}/{len(passes)+len(failures)}",
    "verdict": "pass" if not failures else "fail",
}, indent=2))
PY
else
    echo "═══ dream quality check ═══"
    echo "  log: $LATEST_LOG"
    echo "  age: ${LOG_AGE_DAYS}d"
    echo ""
    if [ "$VERBOSE" -eq 1 ] || [ "${#FAILURES[@]}" -eq 0 ]; then
        for p in "${PASSES[@]+"${PASSES[@]}"}"; do echo "  ✓ $p"; done
    fi
    if [ "${#FAILURES[@]}" -gt 0 ]; then
        echo ""
        echo "  FAILURES:"
        for f in "${FAILURES[@]}"; do echo "  ✗ $f"; done
        echo ""
        echo "  score: ${#PASSES[@]}/$((${#PASSES[@]} + ${#FAILURES[@]}))  VERDICT: FAIL"
        exit 1
    fi
    echo "  score: ${#PASSES[@]}/${#PASSES[@]}  VERDICT: PASS"
fi
exit 0
