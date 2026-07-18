#!/bin/bash
# memory-paths.sh: shared resolution of the memory root and the index budgets.
#
# Sourced by core/memory-hygiene.sh and the hooks/memory-*.sh trio so they can
# never disagree about where memory lives or what "too big" means.
#
# Resolution order for the memory root (first hit wins):
#   1. $DREAMING_MEMORY_ROOT          - explicit override
#   2. $DREAMING_HOME/projects        - the normal layout
#   3. ~/.claude/projects             - backward compat, same as the other hooks
#
# Every budget below is an env var with a default. Defaults are starting points,
# not physics: the byte ceiling in particular depends on the harness loading the
# index, so measure yours before trusting the number.

# Projects root: the directory holding <project>/memory/ dirs.
dreaming_memory_root() {
    if [ -n "${DREAMING_MEMORY_ROOT:-}" ]; then
        printf '%s' "$DREAMING_MEMORY_ROOT"
        return 0
    fi
    local root="${DREAMING_HOME:-$HOME/.dreaming}/projects"
    if [ ! -d "$root" ] && [ -d "$HOME/.claude/projects" ]; then
        root="$HOME/.claude/projects"
    fi
    printf '%s' "$root"
}

# State root: where the hooks append their logs.
dreaming_state_root() {
    printf '%s' "${DREAMING_HOME:-$HOME/.dreaming}"
}

# Hard ceiling for the auto-loaded MEMORY.md. Over this, the index load
# truncates and the tail of the file silently stops reaching the agent.
DREAMING_INDEX_BUDGET_BYTES="${DREAMING_INDEX_BUDGET_BYTES:-32768}"

# Warn at this percentage of the ceiling, so drift surfaces before truncation.
DREAMING_INDEX_WARN_PCT="${DREAMING_INDEX_WARN_PCT:-80}"

# Index entries are one-line pointers, not content. Over this, compress.
DREAMING_INDEX_LINE_BUDGET="${DREAMING_INDEX_LINE_BUDGET:-300}"

# A topic file untouched this long, with a "done" marker, is a retire candidate.
DREAMING_RETIRE_AGE_DAYS="${DREAMING_RETIRE_AGE_DAYS:-45}"

# The size memory-rebalance trims a bloated core index down to. Lower than the
# hard ceiling on purpose: rebalancing back to the exact limit just means you
# rebalance again next week.
DREAMING_REBALANCE_TARGET_BYTES="${DREAMING_REBALANCE_TARGET_BYTES:-24000}"

export DREAMING_INDEX_BUDGET_BYTES DREAMING_INDEX_WARN_PCT \
       DREAMING_INDEX_LINE_BUDGET DREAMING_RETIRE_AGE_DAYS \
       DREAMING_REBALANCE_TARGET_BYTES
