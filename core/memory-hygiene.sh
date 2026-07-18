#!/bin/bash
# memory-hygiene.sh: current-state health sweep of every project memory index.
#
# Checks, per <memory-root>/*/memory/ that contains a MEMORY.md:
#   1. ORPHANS  - topic .md files not referenced in MEMORY.md or any MEMORY-*.md  (hard, exit 1)
#   2. BROKEN   - (file.md) links in any index whose target doesn't exist         (hard, exit 1)
#   3. SIZE     - MEMORY.md over byte budget (loads truncated -> lost recall)     (hard, exit 1)
#               (only the auto-loaded MEMORY.md counts; MEMORY-*.md sub-indexes are on-demand)
#   4. LONGLINE - index entries over per-line char budget                         (hard, exit 1)
#   5. NEARING  - MEMORY.md over the warn threshold (drift warning BEFORE truncation) (advisory)
#   6. RETIRE   - stale + "done"-marked entries that should move to _archive/     (advisory)
#               (skips topic files whose declared frontmatter `type:` is `feedback`
#                or `user`; standing directives never age out, regardless of markers)
#   7. ROT      - `reference`-type topic files citing an absolute path that no     (advisory)
#               longer exists on disk (dead file/dir reference)
#
# Hard checks are loud + exit 1. Advisory checks print but DO NOT change the exit code
# (so exit 0 still means "healthy"). The script NEVER mutates. RETIRE only REPORTS
# candidates; the agent does the judgement-based move into _archive/ during a dream run.
#
# Usage:
#   bash core/memory-hygiene.sh                      # sweep every project
#   bash core/memory-hygiene.sh --project <substring> # one project (case-insensitive)
#
# Env:
#   DREAMING_MEMORY_ROOT           - memory root override (default $DREAMING_HOME/projects)
#   DREAMING_INDEX_BUDGET_BYTES    - hard size ceiling for MEMORY.md (default 32768)
#   DREAMING_INDEX_WARN_PCT        - warn at this % of the ceiling (default 80)
#   DREAMING_INDEX_LINE_BUDGET     - max chars per index entry (default 300)
#   DREAMING_RETIRE_AGE_DAYS       - staleness threshold for retire candidates (default 45)
#
# Wired into: `dreaming hygiene`, dream step 0, and the memory-index-drift hook.

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=core/lib/memory-paths.sh
. "$REPO/core/lib/memory-paths.sh"

FILTER=""
while [ $# -gt 0 ]; do
    case "$1" in
        --project) FILTER="${2:-}"; shift 2 ;;
        -h|--help)
            sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "unknown flag: $1" >&2; exit 1 ;;
    esac
done

MEMORY_ROOT="$(dreaming_memory_root)"
SIZE_BUDGET_BYTES="$DREAMING_INDEX_BUDGET_BYTES"
SIZE_WARN_BYTES=$(( SIZE_BUDGET_BYTES * DREAMING_INDEX_WARN_PCT / 100 ))
LINE_BUDGET_CHARS="$DREAMING_INDEX_LINE_BUDGET"
RETIRE_AGE_DAYS="$DREAMING_RETIRE_AGE_DAYS"

if [ ! -d "$MEMORY_ROOT" ]; then
    echo "memory-hygiene: no memory root at $MEMORY_ROOT, nothing to sweep"
    exit 0
fi

# Absolute-path pattern for the ROT check, derived from $HOME rather than hardcoded.
# Escape the ERE metacharacters that can legally appear in a home path.
HOME_PATH_PATTERN="${DREAMING_HOME_PATH_PATTERN:-$HOME}"
HOME_PATH_ESCAPED=$(printf '%s' "$HOME_PATH_PATTERN" | sed -e 's/[][\.^$*+?(){}|]/\\&/g')
ABS_PATH_RE="($HOME_PATH_ESCAPED|~)/[A-Za-z0-9._/*<>-]+"

ISSUES=0
ADVISORIES=0
PROJECT=""
PROJECT_HEADER_SHOWN=0

_ensure_header() {
    if [ "$PROJECT_HEADER_SHOWN" -eq 0 ]; then echo "## $PROJECT"; PROJECT_HEADER_SHOWN=1; fi
}
report() {            # hard issue: flips exit code to 1
    _ensure_header
    ISSUES=$((ISSUES + 1))
    echo "  $1"
}
advise() {            # advisory: printed, but never changes the exit code
    _ensure_header
    ADVISORIES=$((ADVISORIES + 1))
    echo "  $1"
}

for MEM_DIR in "$MEMORY_ROOT"/*/memory; do
  [ -d "$MEM_DIR" ] || continue
  INDEX="$MEM_DIR/MEMORY.md"
  [ -f "$INDEX" ] || continue
  PROJECT=$(basename "$(dirname "$MEM_DIR")")
  PROJECT_HEADER_SHOWN=0
  # case-insensitive filter match (on-disk slug case varies between platforms)
  if [ -n "$FILTER" ]; then
    PROJECT_LC=$(printf '%s' "$PROJECT" | tr '[:upper:]' '[:lower:]')
    FILTER_LC=$(printf '%s' "$FILTER" | tr '[:upper:]' '[:lower:]')
    [[ "$PROJECT_LC" != *"$FILTER_LC"* ]] && continue
  fi

  INDEX_CONTENT=$(cat "$MEM_DIR"/MEMORY*.md 2>/dev/null)   # core + any on-demand sub-indexes (MEMORY-*.md)

  # 1. Orphans: skip MEMORY.md itself, _archive/, _pending_review/
  for f in "$MEM_DIR"/*.md; do
    [ -e "$f" ] || continue
    base=$(basename "$f")
    case "$base" in MEMORY.md|MEMORY-*.md) continue ;; esac  # index files, not memories
    case "$base" in _*) continue ;; esac  # _-prefixed = loop working artifact, not a memory
    if [[ "$INDEX_CONTENT" != *"$base"* ]]; then
      report "ORPHAN: $base is not indexed; add a one-line pointer or archive it"
    fi
  done

  # 2. Broken links: (something.md) references with no file on disk
  while IFS= read -r target; do
    [ -z "$target" ] && continue
    if [ ! -f "$MEM_DIR/$target" ]; then
      report "BROKEN LINK: ($target) referenced in an index but file missing"
    fi
  done < <(grep -ho '([A-Za-z0-9_-][A-Za-z0-9_.-]*\.md)' "$MEM_DIR"/MEMORY*.md 2>/dev/null | tr -d '()' | sort -u)

  # 3. Size budget (hard over the ceiling, advisory over the warn threshold)
  BYTES=$(wc -c < "$INDEX" | tr -d ' ')
  if [ "$BYTES" -gt "$SIZE_BUDGET_BYTES" ]; then
    report "SIZE: MEMORY.md is ${BYTES} bytes (budget ${SIZE_BUDGET_BYTES}). Loads may truncate; run \`dreaming rebalance\` or archive shipped/done entries to _archive/"
  elif [ "$BYTES" -gt "$SIZE_WARN_BYTES" ]; then
    advise "SIZE NEARING: MEMORY.md is ${BYTES} bytes (>${DREAMING_INDEX_WARN_PCT}% of ${SIZE_BUDGET_BYTES}). Archive 'done' entries now, before it truncates (see RETIRE candidates below)"
  fi

  # 4. Overlong lines
  LONG=$(awk -v max="$LINE_BUDGET_CHARS" 'length > max {c++} END {print c+0}' "$MEM_DIR"/MEMORY*.md)
  if [ "$LONG" -gt 0 ]; then
    report "LONG LINES: $LONG index entries over ${LINE_BUDGET_CHARS} chars. Compress; detail belongs in the topic file"
  fi

  # 5/6. Retirement candidates: ADVISORY ONLY (reports, never moves).
  #   Flags a pointer line when its topic file has been untouched > RETIRE_AGE_DAYS
  #   AND the hook reads "finished", MINUS a keep-guard for still-live operational
  #   knowledge (a "done"-looking note can encode a recurring constraint). The agent
  #   applies final judgement + does the move into _archive/ during a dream run.
  while IFS= read -r line; do
    target=$(printf '%s' "$line" | grep -o '([A-Za-z0-9_-][A-Za-z0-9_.-]*\.md)' | head -1 | tr -d '()')
    [ -z "$target" ] && continue
    tf="$MEM_DIR/$target"
    [ -f "$tf" ] || continue
    # type-guard: feedback/user types are standing directives, never propose retirement
    ftype=$(head -12 "$tf" | grep -m1 -E '^[[:space:]]*type:' | sed 's/.*type:[[:space:]]*//' | tr -d '[:space:]')
    case "$ftype" in feedback|user) continue ;; esac
    # keep-guard: never propose retiring still-live knowledge regardless of age/markers
    if printf '%s' "$line" | grep -qiE 'do not remove|not dead|do not delete|never remove|pending|not yet armed|canonical|source of truth|mandatory|live=|LIVE in prod|do NOT'; then
      continue
    fi
    # completion markers that imply the work is finished
    if printf '%s' "$line" | grep -qiE 'shipped|completed|\bcomplete\b|incident|postmortem|post-mortem|\bremoved\b|retired|\bkilled\b|deprecated|superseded|\bdeleted\b'; then
      if [ -n "$(find "$tf" -mtime "+${RETIRE_AGE_DAYS}" 2>/dev/null)" ]; then
        advise "RETIRE-CANDIDATE: $target (topic untouched >${RETIRE_AGE_DAYS}d + 'done' marker); review for _archive/ during the next dream run"
      fi
    fi
  done < <(grep -hE '^- \[.*\]\([A-Za-z0-9_-][A-Za-z0-9_.-]*\.md\)' "$MEM_DIR"/MEMORY*.md 2>/dev/null)

  # 7. Reference rot: ADVISORY ONLY. `reference`-type topic files often cite absolute
  #    paths as their whole point (a table, a handler, a canonical file). If that path
  #    no longer exists, the memory is citing a ghost, so flag it for a human to re-check.
  ROT_COUNT=0
  for tf in "$MEM_DIR"/*.md; do
    [ -e "$tf" ] || continue
    base=$(basename "$tf")
    case "$base" in MEMORY.md|MEMORY-*.md) continue ;; esac
    case "$base" in _*) continue ;; esac
    ftype=$(head -12 "$tf" | grep -m1 -E '^[[:space:]]*type:' | sed 's/.*type:[[:space:]]*//' | tr -d '[:space:]')
    [ "$ftype" = "reference" ] || continue
    while IFS= read -r rawpath; do
      [ -z "$rawpath" ] && continue
      # strip trailing punctuation that grep's greedy path match tends to pick up
      p=$(printf '%s' "$rawpath" | sed -E 's/[.,:;]+$//')
      [ -z "$p" ] && continue
      # skip globs, shell vars, placeholder/example paths, and ephemeral locations
      case "$p" in
        *'*'*|*'$'*|*'<'*|*XXXX*|*/tmp/*|*/worktrees/*|*_archive/*) continue ;;
        */YYYY*|*/MM/*|*/DD*) continue ;;  # date-template shorthand, not a literal path
      esac
      # expand a leading ~ to $HOME
      case "$p" in
        '~'/*) p="$HOME${p#\~}" ;;
        '~') p="$HOME" ;;
      esac
      [ -e "$p" ] && continue
      ROT_COUNT=$((ROT_COUNT + 1))
      if [ "$ROT_COUNT" -le 8 ]; then
        advise "ROT: $base cites missing path $p"
      fi
    done < <(head -200 "$tf" | grep -ohE "$ABS_PATH_RE" | sort -u)
  done
  if [ "$ROT_COUNT" -gt 8 ]; then
    advise "ROT: +$((ROT_COUNT - 8)) more dead paths in this project"
  fi
done

if [ "$ISSUES" -gt 0 ]; then
  echo ""
  echo "memory-hygiene: $ISSUES issue(s). Fix by adding index lines, removing dead links, or moving detail into topic files."
  [ "$ADVISORIES" -gt 0 ] && echo "                 + $ADVISORIES advisory note(s) above (size-nearing / retire candidates)."
  exit 1
fi
if [ "$ADVISORIES" -gt 0 ]; then
  echo ""
  echo "memory-hygiene: healthy (no hard issues), $ADVISORIES advisory note(s) above. Archive 'done' entries during the next dream run to keep the live index small."
fi
exit 0
