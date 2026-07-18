#!/bin/bash
# memory-index-drift.sh: PostToolUse hook (matcher: Write).
# When the agent writes a NEW memory file, checks whether the basename is linked
# in the project's MEMORY.md index. If not, it tells the session immediately and
# appends a line to $DREAMING_HOME/index-drift.log.
#
# WHY live rather than at sweep time: an unindexed memory is an unrecallable
# memory. The session that wrote it is the only one that still has the context
# to write a good one-line pointer, and it is about to end. memory-hygiene.sh
# catches the same drift later, but "later" means the pointer gets written by
# someone reconstructing intent from a filename.
#
# Invariants:
#   - ALWAYS exits 0. Never blocks tool use. Never mutates MEMORY.md.
#   - Fast: one jq parse + one grep. Exits silently if jq is unavailable.
#   - Observational only: surfacing drift, not fixing it.
#
# Env:
#   DREAMING_MEMORY_ROOT         memory root override
#   DREAMING_INDEX_BUDGET_BYTES  hard size ceiling for MEMORY.md
#   DREAMING_INDEX_WARN_PCT      warn at this % of the ceiling
#   DREAMING_INDEX_LINE_BUDGET   max chars per index entry
#
# Kill switch: touch $DREAMING_HOME/.memory-index-drift-disabled

set -uo pipefail
IFS=$' \t\n'

: "${HOME:?HOME must be set}"

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=core/lib/memory-paths.sh
. "$HOOK_DIR/../core/lib/memory-paths.sh"

STATE_ROOT="$(dreaming_state_root)"
MEMORY_ROOT="$(dreaming_memory_root)"
DRIFT_LOG="$STATE_ROOT/index-drift.log"
WARN_BYTES=$(( DREAMING_INDEX_BUDGET_BYTES * DREAMING_INDEX_WARN_PCT / 100 ))

# ── Kill switch ──────────────────────────────────────────────────────────────
[ -f "$STATE_ROOT/.memory-index-drift-disabled" ] && exit 0

# ── Read hook payload from stdin ─────────────────────────────────────────────
PAYLOAD=$(cat 2>/dev/null || true)
[ -z "$PAYLOAD" ] && exit 0

# ── Extract file_path via jq ─────────────────────────────────────────────────
command -v jq >/dev/null 2>&1 || exit 0
FILE_PATH=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)
[ -z "$FILE_PATH" ] && exit 0

# ── Filter: must match <memory-root>/*/memory/*.md ───────────────────────────
case "$FILE_PATH" in
  "$MEMORY_ROOT"/*/memory/*.md) : ;;  # matches, continue
  *) exit 0 ;;                        # not a memory file, skip
esac

# ── MEMORY.md itself → index health check (size + line budget), then done ────
BASENAME=$(basename "$FILE_PATH")
if [ "$BASENAME" = "MEMORY.md" ]; then
  BYTES=$(wc -c < "$FILE_PATH" 2>/dev/null | tr -d ' ' || echo 0)
  if [ "$BYTES" -gt "$WARN_BYTES" ]; then
    echo "memory-index-drift: MEMORY.md is ${BYTES} bytes, past ${DREAMING_INDEX_WARN_PCT}% of the ${DREAMING_INDEX_BUDGET_BYTES}B load budget. When the index truncates, the tail (often the standing directives) silently stops loading. The fix is not more compression but moving sections to MEMORY-extended.md. Run: dreaming rebalance --dir $(dirname "$FILE_PATH") (add --apply; backs up + reversible). Sweep: dreaming hygiene"
  fi
  LONG=$(awk -v max="$DREAMING_INDEX_LINE_BUDGET" 'length > max {c++} END {print c+0}' "$FILE_PATH" 2>/dev/null || echo 0)
  if [ "$LONG" -gt 3 ]; then
    echo "memory-index-drift: $LONG MEMORY.md entries exceed ${DREAMING_INDEX_LINE_BUDGET} chars. Compress them; detail belongs in the topic file."
  fi
  exit 0
fi

# ── Exclude _archive/ and _pending_review/ ───────────────────────────────────
DIRNAME=$(dirname "$FILE_PATH")
case "$DIRNAME" in
  */_archive | */_archive/* | */_pending_review | */_pending_review/*) exit 0 ;;
esac

# ── Locate this project's MEMORY.md ──────────────────────────────────────────
MEMORY_MD="$DIRNAME/MEMORY.md"
[ ! -f "$MEMORY_MD" ] && exit 0  # no index to check against, skip silently

# ── Check whether basename appears in MEMORY.md ──────────────────────────────
if grep -qF "$BASENAME" "$MEMORY_MD" 2>/dev/null; then
  exit 0  # already linked, all good
fi

# ── Tell the SESSION (stdout reaches the model) + keep the audit log ─────────
echo "memory-index-drift: $BASENAME is not referenced in MEMORY.md. Add a one-line index pointer now ('- [Title]($BASENAME) - hook') or the memory is unrecallable."

mkdir -p "$(dirname "$DRIFT_LOG")" 2>/dev/null || true

TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ')
printf '%s\n' "[$TIMESTAMP] orphan: $FILE_PATH (not in MEMORY.md)" >> "$DRIFT_LOG" 2>/dev/null || true

# ── Auto-rotate: if log exceeds 1000 lines, tail to 500 ──────────────────────
LINE_COUNT=$(wc -l < "$DRIFT_LOG" 2>/dev/null | tr -d ' ' || echo 0)
if [ "$LINE_COUNT" -gt 1000 ]; then
  TRIMMED=$(tail -500 "$DRIFT_LOG" 2>/dev/null || true)
  printf '%s\n' "$TRIMMED" > "$DRIFT_LOG" 2>/dev/null || true
fi

exit 0
