#!/bin/bash
# dream.sh — deep memory consolidation loop, LLM-agnostic.
#
# Manual: bash core/dream.sh
# Dry run: DRY_RUN=1 bash core/dream.sh
# Different LLM: DREAMING_ADAPTER=codex bash core/dream.sh

set -uo pipefail
IFS=$' \t\n'

: "${HOME:?HOME must be set}"

# ── Configuration ───────────────────────────────────
# DREAMING_HOME is the data root (memory dirs, logs, snapshots).
# DREAMING_REPO is where this script lives + adapters + prompts.
DREAMING_HOME="${DREAMING_HOME:-$HOME/.dreaming}"
DREAMING_REPO="${DREAMING_REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
DREAMING_ADAPTER="${DREAMING_ADAPTER:-claude}"

LOG_DIR="$DREAMING_HOME/dream-logs"
HISTORY_FILE="$DREAMING_HOME/dream-history.md"
PROMPT_FILE="$DREAMING_REPO/prompts/dream.md"
LAST_RUN_FILE="$DREAMING_HOME/dream-last-run"
LAST_STARTED_FILE="$DREAMING_HOME/dream-last-started"
KILL_SWITCH="$DREAMING_HOME/.dream-disabled"
LOCK_DIR="$DREAMING_HOME/.dream.lock.d"
PROMOTE_LOCK="$DREAMING_HOME/.promote.lock.d"
SELF_LEARN_LOCK="$DREAMING_HOME/.self-learn.lock.d"
TIMESTAMP=$(date +"%Y-%m-%dT%H-%M-%S")
LOG_FILE="$LOG_DIR/run-$TIMESTAMP-$$.log"
SNAPSHOT_DIR="$LOG_DIR/snapshots/$TIMESTAMP-$$"
DREAM_TIMEOUT_SECONDS="${DREAM_TIMEOUT_SECONDS:-2700}"  # 45 min default

mkdir -p "$LOG_DIR" "$SNAPSHOT_DIR" "$DREAMING_HOME" || { echo "FATAL: cannot create data dirs" >&2; exit 1; }

# ── Load adapter ─────────────────────────────────────
ADAPTER_FILE="$DREAMING_REPO/adapters/${DREAMING_ADAPTER}.sh"
if [ ! -f "$ADAPTER_FILE" ]; then
    echo "FATAL: adapter $DREAMING_ADAPTER not found at $ADAPTER_FILE" >&2
    echo "Available adapters: $(ls "$DREAMING_REPO/adapters/" | grep -v '^_' | sed 's/\.sh$//' | xargs)" >&2
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
if ! declare -F dreaming_invoke_llm >/dev/null 2>&1; then
    echo "FATAL: adapter $DREAMING_ADAPTER does not define dreaming_invoke_llm" >&2
    exit 1
fi

# ── Kill switch ─────────────────────────────────────
if [ -f "$KILL_SWITCH" ]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Dream disabled via $KILL_SWITCH — exiting" >> "$LOG_DIR/aborted.log"
  exit 0
fi

# ── Mutex (mkdir is atomic on BSD/macOS) ────────────
acquire_lock() {
  if [ -d "$PROMOTE_LOCK" ] || [ -d "$SELF_LEARN_LOCK" ]; then
    return 1
  fi
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "$$" > "$LOCK_DIR/pid" 2>/dev/null || true
    return 0
  fi
  local lock_age
  lock_age=$(( $(date +%s) - $(stat -f %m "$LOCK_DIR" 2>/dev/null || echo 0) ))
  if [ "$lock_age" -gt 7200 ]; then
    rm -rf "$LOCK_DIR" 2>/dev/null
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      echo "$$" > "$LOCK_DIR/pid" 2>/dev/null || true
      return 0
    fi
  fi
  return 1
}

if ! acquire_lock; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Another dream run in progress (lock held) — exiting" >> "$LOG_DIR/skipped.log"
  exit 0
fi

cleanup() {
  local exit_code=$?
  rm -rf "$LOCK_DIR" 2>/dev/null || true
  if [ "$exit_code" -ne 0 ]; then
    echo "=== Aborted (exit=$exit_code): $(date) ===" >> "$LOG_FILE" 2>/dev/null || true
    echo "$TIMESTAMP exit=$exit_code" >> "$DREAMING_HOME/.dream-last-failed" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

# ── Pre-flight ──────────────────────────────────────
if [ ! -f "$PROMPT_FILE" ]; then
  echo "FATAL: prompt file missing at $PROMPT_FILE" >&2
  exit 1
fi

date +%s > "$LAST_STARTED_FILE"

# ── Snapshot all project memory dirs (FAIL-FAST) ────
snapshot_failed=0
PROJECTS_DIR="$DREAMING_HOME/projects"
mkdir -p "$PROJECTS_DIR"
for dir in "$PROJECTS_DIR"/*/memory; do
  [ -d "$dir" ] || continue
  proj_name=$(basename "$(dirname "$dir")")
  case "$proj_name" in
    *[!a-zA-Z0-9._-]* | "" )
      echo "WARN: skipping malformed project name: $proj_name" >> "$LOG_FILE"
      continue ;;
  esac
  if [ -z "$(find "$dir" -maxdepth 1 -name '*.md' -type f -print -quit 2>/dev/null)" ]; then
    continue
  fi
  if ! cp -R "$dir" "$SNAPSHOT_DIR/$proj_name.before"; then
    echo "FATAL: snapshot failed for $dir" >&2
    snapshot_failed=1
    break
  fi
done

if [ "$snapshot_failed" -eq 1 ]; then
  echo "FATAL: snapshot phase failed; refusing to invoke LLM (no rollback path)" >&2
  exit 2
fi

# Read-only on snapshot content (dirs stay writable for rm -rf later)
find "$SNAPSHOT_DIR" -type f -exec chmod a-w {} + 2>/dev/null || true

# ── Run the LLM via the adapter ─────────────────────
{
  echo "=== Dream Run: $TIMESTAMP (pid=$$) ==="
  echo "Adapter: $DREAMING_ADAPTER"
  echo "Model:   ${DREAMING_MODEL:-(adapter default)}"
  echo "Mode:    ${DRY_RUN:+DRY RUN — }live"
  echo "Snapshot: $SNAPSHOT_DIR"
  echo "Home:    $DREAMING_HOME"
  echo ""

  if [ "${DRY_RUN:-}" = "1" ]; then
    echo "(DRY_RUN=1 — skipping LLM invocation)"
    llm_exit=0
  else
    cd "$DREAMING_HOME" || exit 1
    # Render the prompt template — substitute ${MEMORY_ROOT} etc. so the LLM
    # gets absolute paths for THIS adapter/env, not literal ~/.claude refs.
    RENDERED_PROMPT="$SNAPSHOT_DIR/rendered-prompt.md"
    if ! dreaming_render_prompt "$PROMPT_FILE" "$RENDERED_PROMPT"; then
      echo "FATAL: prompt render failed" >&2
      llm_exit=3
    else
      DREAM_RUN_ID="$TIMESTAMP-$$" \
        dreaming_invoke_llm "$RENDERED_PROMPT" "$DREAM_TIMEOUT_SECONDS"
      llm_exit=$?
    fi
    if [ "$llm_exit" -ne 0 ]; then
      echo "LLM_EXIT_CODE=$llm_exit"
    fi
  fi

  echo ""
  echo "=== Diff summary ==="
  for snap in "$SNAPSHOT_DIR"/*.before; do
    [ -d "$snap" ] || continue
    proj_name=$(basename "$snap" .before)
    live_dir="$PROJECTS_DIR/$proj_name/memory"
    if [ ! -d "$live_dir" ]; then
      echo "$proj_name: live memory dir missing (skipping diff)"
      continue
    fi
    if ! diff -qr "$snap" "$live_dir" >/dev/null 2>&1; then
      changed_count=$(diff -qr "$snap" "$live_dir" 2>/dev/null | wc -l | tr -d ' ')
      echo "$proj_name: CHANGED ($changed_count entries)"
      diff -qr "$snap" "$live_dir" 2>/dev/null | head -50
      [ "$changed_count" -gt 50 ] && echo "  ... ($((changed_count - 50)) more)"
    else
      echo "$proj_name: unchanged"
    fi
  done

  echo ""
  echo "=== Complete: $(date), llm_exit=${llm_exit:-?} ==="
} > "$LOG_FILE" 2>&1

# ── History + sentinels on success ──────────────────
if [ "${llm_exit:-1}" -eq 0 ]; then
  if [ ! -f "$HISTORY_FILE" ]; then
    printf "# Dream History\n\nAuto-generated log of deep memory consolidation runs.\n\n" > "$HISTORY_FILE"
  fi
  if ! grep -qE "^## ${TIMESTAMP}( |\$)" "$HISTORY_FILE" 2>/dev/null; then
    printf "\n## %s\n- Adapter: \`%s\`\n- Log: \`dream-logs/run-%s-%s.log\`\n- Snapshot: \`dream-logs/snapshots/%s-%s/\`\n" \
      "$TIMESTAMP" "$DREAMING_ADAPTER" "$TIMESTAMP" "$$" "$TIMESTAMP" "$$" >> "$HISTORY_FILE"
  fi
  date +%s > "$LAST_RUN_FILE.tmp" && mv "$LAST_RUN_FILE.tmp" "$LAST_RUN_FILE"

  # Hash-at-stage sentinels
  for proj_dir in "$PROJECTS_DIR"/*/; do
    pending_dir="$proj_dir/memory/_pending_review"
    [ -d "$pending_dir" ] || continue
    find "$pending_dir" -type f -name '*.md' -newer "$LAST_STARTED_FILE" 2>/dev/null | \
      while IFS= read -r f; do
        [ -f "$f.sha256" ] && continue
        shasum -a 256 "$f" 2>/dev/null > "$f.sha256.tmp" && mv "$f.sha256.tmp" "$f.sha256"
      done
  done

  # Best-effort notify (macOS)
  if command -v osascript >/dev/null 2>&1; then
    osascript -e 'display notification "Memory consolidation complete" with title "Dreaming"' 2>/dev/null || true
  fi

  # Post-run fitness check (skipped for dry runs)
  QUALITY_SCRIPT="$DREAMING_REPO/core/dream-quality-check.sh"
  QUALITY_HISTORY="$DREAMING_HOME/dream-quality-history.jsonl"
  if [ "${DRY_RUN:-}" != "1" ] && [ -f "$QUALITY_SCRIPT" ]; then
    quality_json=$(DREAMING_HOME="$DREAMING_HOME" bash "$QUALITY_SCRIPT" --json 2>/dev/null || echo '{"verdict":"error","score":"?/?"}')
    score=$(printf '%s' "$quality_json" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("score","?/?"))' 2>/dev/null || echo "?/?")
    verdict=$(printf '%s' "$quality_json" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("verdict","?"))' 2>/dev/null || echo "?")
    printf '{"timestamp":"%s","adapter":"%s","score":"%s","verdict":"%s","log":"%s"}\n' \
      "$TIMESTAMP" "$DREAMING_ADAPTER" "$score" "$verdict" "run-$TIMESTAMP-$$.log" >> "$QUALITY_HISTORY"
    if [ "$verdict" = "fail" ]; then
      {
        echo ""
        echo "=== QUALITY CHECK: FAIL ($score) ==="
        printf '%s' "$quality_json"
        echo ""
        echo "Run \`bash $QUALITY_SCRIPT --verbose\` for detail."
      } >> "$LOG_FILE"
    fi
  fi
fi

# ── Retention ──
find "$LOG_DIR/snapshots" -mindepth 1 -maxdepth 1 -type d -mtime +90 -exec rm -rf {} + 2>/dev/null || true
find "$LOG_DIR" -maxdepth 1 -name "run-*.log" -mtime +90 -delete 2>/dev/null || true

echo "Dream run logged to $LOG_FILE (adapter=$DREAMING_ADAPTER, exit=${llm_exit:-?})"

# Propagate the LLM's exit status as our own. Without this the script's last
# command is the echo above (always 0), so launchd records LastExitStatus=0
# even when the run failed (e.g. Claude weekly-limit exit=1 on 2026-06-01),
# the cleanup trap never writes .dream-last-failed, and the failure is silent.
exit "${llm_exit:-1}"
