#!/bin/bash
# self-learn.sh — weekly cross-project promotion loop, LLM-agnostic.
#
# Lighter than dream: scans recent sessions and promotes single-session
# learnings up to the cross-project root. No merge, no trim, no synthesis.
# Dream (monthly) does the deep work.
#
# Manual: bash core/self-learn.sh
# Dry run: DRY_RUN=1 bash core/self-learn.sh
# Different LLM: DREAMING_ADAPTER=codex bash core/self-learn.sh

set -uo pipefail
IFS=$' \t\n'

: "${HOME:?HOME must be set}"

# ── Configuration ───────────────────────────────────
DREAMING_HOME="${DREAMING_HOME:-$HOME/.dreaming}"
DREAMING_REPO="${DREAMING_REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
DREAMING_ADAPTER="${DREAMING_ADAPTER:-claude}"

# Cross-project memory root — the dir self-learn promotes INTO.
# Default convention: `<projects>/_root/memory/`, but most existing setups have
# `<projects>/-Users-<user>/memory/` (Claude Code's path-encoded user dir). The env
# var lets you point this at whatever your setup uses.
ROOT_MEMORY_DIR="${DREAMING_ROOT_MEMORY:-$DREAMING_HOME/projects/-Users-$(whoami)/memory}"

# Optional: a "global instructions" file to snapshot before runs (Claude users
# have ~/.claude/CLAUDE.md). Other LLMs may not have an equivalent — skip if absent.
GLOBAL_INSTRUCTIONS_FILE="${DREAMING_GLOBAL_INSTRUCTIONS:-$HOME/.claude/CLAUDE.md}"

LOG_DIR="$DREAMING_HOME/self-learn-logs"
HISTORY_FILE="$DREAMING_HOME/self-learn-history.md"
PROMPT_FILE="$DREAMING_REPO/prompts/self-learn.md"
TIMESTAMP=$(date +"%Y-%m-%dT%H-%M-%S")
LOG_FILE="$LOG_DIR/run-$TIMESTAMP.log"
SNAPSHOT_DIR="$LOG_DIR/snapshots/$TIMESTAMP"
TIMEOUT_SECONDS="${SELF_LEARN_TIMEOUT_SECONDS:-1200}"  # 20 min default

# ── Load adapter ─────────────────────────────────────
ADAPTER_FILE="$DREAMING_REPO/adapters/${DREAMING_ADAPTER}.sh"
if [ ! -f "$ADAPTER_FILE" ]; then
    echo "FATAL: adapter $DREAMING_ADAPTER not found at $ADAPTER_FILE" >&2
    exit 1
fi
# shellcheck source=/dev/null
. "$ADAPTER_FILE"

# Prompt renderer (substitutes ${MEMORY_ROOT} etc. before invoking the LLM)
# shellcheck source=/dev/null
. "$DREAMING_REPO/core/lib/render-prompt.sh"

if declare -F dreaming_preflight >/dev/null 2>&1; then
    if ! dreaming_preflight; then
        echo "FATAL: adapter preflight failed" >&2
        exit 1
    fi
fi

# ── Shared mutex with dream + promote ────────────────
DREAM_LOCK="$DREAMING_HOME/.dream.lock.d"
PROMOTE_LOCK="$DREAMING_HOME/.promote.lock.d"
SELF_LEARN_LOCK="$DREAMING_HOME/.self-learn.lock.d"

mkdir -p "$LOG_DIR" "$SNAPSHOT_DIR"

if [ -d "$DREAM_LOCK" ] || [ -d "$PROMOTE_LOCK" ]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] dream or promote-dream is running — skipping self-learn" \
    >> "$LOG_DIR/skipped.log"
  exit 0
fi

if ! mkdir "$SELF_LEARN_LOCK" 2>/dev/null; then
  lock_age=$(( $(date +%s) - $(stat -f %m "$SELF_LEARN_LOCK" 2>/dev/null || echo 0) ))
  if [ "$lock_age" -gt 7200 ]; then
    rm -rf "$SELF_LEARN_LOCK" 2>/dev/null
    mkdir "$SELF_LEARN_LOCK" 2>/dev/null || exit 0
  else
    exit 0
  fi
fi
trap 'rm -rf "$SELF_LEARN_LOCK" 2>/dev/null' EXIT INT TERM

# ── Pre-flight ──────────────────────────────────────
if [ ! -f "$PROMPT_FILE" ]; then
  echo "FATAL: prompt file missing at $PROMPT_FILE" >&2
  exit 1
fi
if [ ! -d "$ROOT_MEMORY_DIR" ]; then
  echo "WARN: root memory dir not found at $ROOT_MEMORY_DIR — creating empty" >&2
  mkdir -p "$ROOT_MEMORY_DIR"
fi

# ── Snapshot (optional global instructions + root memory) ──
[ -f "$GLOBAL_INSTRUCTIONS_FILE" ] && cp "$GLOBAL_INSTRUCTIONS_FILE" "$SNAPSHOT_DIR/global-instructions.before" 2>/dev/null || true
cp -R "$ROOT_MEMORY_DIR" "$SNAPSHOT_DIR/memory.before" 2>/dev/null || true

# ── Run the LLM via adapter ─────────────────────────
{
  echo "=== Self-Learn Run: $TIMESTAMP ==="
  echo "Adapter:        $DREAMING_ADAPTER"
  echo "Mode:           ${DRY_RUN:+DRY RUN — }live"
  echo "Root memory:    $ROOT_MEMORY_DIR"
  echo "Global instrs:  $([ -f "$GLOBAL_INSTRUCTIONS_FILE" ] && echo "$GLOBAL_INSTRUCTIONS_FILE" || echo "(none)")"
  echo ""

  if [ "${DRY_RUN:-}" = "1" ]; then
    echo "(DRY_RUN=1 — skipping LLM invocation)"
    llm_exit=0
  else
    cd "$DREAMING_HOME"
    RENDERED_PROMPT="$SNAPSHOT_DIR/rendered-prompt.md"
    if ! dreaming_render_prompt "$PROMPT_FILE" "$RENDERED_PROMPT"; then
      echo "FATAL: prompt render failed" >&2
      llm_exit=3
    else
      DREAM_RUN_ID="$TIMESTAMP-$$" \
        dreaming_invoke_llm "$RENDERED_PROMPT" "$TIMEOUT_SECONDS"
      llm_exit=$?
    fi
  fi

  echo ""
  echo "=== Diff summary ==="
  if [ -f "$SNAPSHOT_DIR/global-instructions.before" ] && [ -f "$GLOBAL_INSTRUCTIONS_FILE" ]; then
    if ! diff -q "$SNAPSHOT_DIR/global-instructions.before" "$GLOBAL_INSTRUCTIONS_FILE" >/dev/null 2>&1; then
      echo "Global instructions: CHANGED"
      diff -u "$SNAPSHOT_DIR/global-instructions.before" "$GLOBAL_INSTRUCTIONS_FILE" | head -200
    else
      echo "Global instructions: unchanged"
    fi
  fi
  echo ""
  if ! diff -qr "$SNAPSHOT_DIR/memory.before" "$ROOT_MEMORY_DIR" >/dev/null 2>&1; then
    echo "Root memory: CHANGED"
    diff -qr "$SNAPSHOT_DIR/memory.before" "$ROOT_MEMORY_DIR"
  else
    echo "Root memory: unchanged"
  fi

  echo ""
  echo "=== Complete: $(date), exit=${llm_exit:-?} ==="
} > "$LOG_FILE" 2>&1

# ── History ─────────────────────────────────────────
if [ ! -f "$HISTORY_FILE" ]; then
  printf "# Self-Learn History\n\nAuto-generated log of weekly promotion runs.\n\n" > "$HISTORY_FILE"
fi
if ! grep -q "$TIMESTAMP" "$HISTORY_FILE" 2>/dev/null; then
  printf "\n## %s\n- Adapter: \`%s\`\n- Log: \`self-learn-logs/run-%s.log\`\n- Snapshot: \`self-learn-logs/snapshots/%s/\`\n" \
    "$TIMESTAMP" "$DREAMING_ADAPTER" "$TIMESTAMP" "$TIMESTAMP" >> "$HISTORY_FILE"
fi

# ── Retention ──
find "$LOG_DIR/snapshots" -mindepth 1 -maxdepth 1 -type d -mtime +90 -exec rm -rf {} + 2>/dev/null || true
find "$LOG_DIR" -maxdepth 1 -name "run-*.log" -mtime +90 -delete 2>/dev/null || true

echo "Self-learn run logged to $LOG_FILE (adapter=$DREAMING_ADAPTER, exit=${llm_exit:-?})"
