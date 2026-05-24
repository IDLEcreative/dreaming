#!/bin/bash
# bench-adapter.sh — A/B-style benchmark a dreaming adapter against an isolated
# copy of the live memory tree.
#
# Usage:
#   bash tests/bench-adapter.sh <adapter-name> [timeout-seconds]
#
# Examples:
#   bash tests/bench-adapter.sh codex 1800   # codex, 30-min cap
#   bash tests/bench-adapter.sh claude 2700  # claude, 45-min cap (default for dream)
#
# What it does:
#   1. Creates $BENCH_HOME with a fresh copy of every project's memory/ subtree
#   2. Runs `dreaming dream` with the chosen adapter against $BENCH_HOME
#   3. Runs the fitness check against the resulting log
#   4. Prints a one-line summary (adapter, exit, score, verdict, runtime)
#
# What it does NOT do:
#   - Touch live data under ~/.claude/projects or ~/.dreaming
#   - Persist results — wipe with: rm -rf ~/.dreaming-bench-<adapter>
#
# Use this to:
#   - Verify a new adapter passes the rules contract
#   - Compare two adapters on the same input
#   - Smoke-test prompt changes without risking real memory

set -uo pipefail

ADAPTER="${1:?usage: bench-adapter.sh <adapter> [timeout-sec]}"
TIMEOUT="${2:-1800}"

DREAMING_REPO="${DREAMING_REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
BENCH_HOME="${BENCH_HOME:-$HOME/.dreaming-bench-${ADAPTER}}"
SOURCE_MEMORY="${SOURCE_MEMORY:-$HOME/.claude/projects}"

if [ ! -d "$SOURCE_MEMORY" ]; then
    echo "FATAL: source memory not found at $SOURCE_MEMORY" >&2
    echo "  set SOURCE_MEMORY to your live memory root" >&2
    exit 1
fi

echo "═══ dreaming adapter bench ═══"
echo "  adapter:  $ADAPTER"
echo "  timeout:  ${TIMEOUT}s"
echo "  source:   $SOURCE_MEMORY"
echo "  bench:    $BENCH_HOME"
echo ""

# 1. Fresh bench env (no leakage from previous runs)
echo "[1/4] preparing bench env..."
rm -rf "$BENCH_HOME"
mkdir -p "$BENCH_HOME/dream-logs" "$BENCH_HOME/projects"
n_copied=0
for proj_dir in "$SOURCE_MEMORY"/*/; do
    proj=$(basename "$proj_dir")
    if [ -d "$proj_dir/memory" ]; then
        mkdir -p "$BENCH_HOME/projects/$proj"
        # -Rp preserves mtimes — without it, R6 would treat every file as
        # 'modified <7d' and surface ALL pre-existing wiki-link issues, not
        # just ones the bench run actually introduced.
        cp -Rp "$proj_dir/memory" "$BENCH_HOME/projects/$proj/memory"
        n_copied=$((n_copied + 1))
    fi
done
n_files=$(find "$BENCH_HOME/projects" -name '*.md' -type f | wc -l | tr -d ' ')
echo "      $n_copied projects, $n_files markdown files copied"

# 2. Run dream with the chosen adapter
echo "[2/4] running dream (this may take up to ${TIMEOUT}s)..."
start=$(date +%s)
DREAMING_HOME="$BENCH_HOME" \
DREAMING_ADAPTER="$ADAPTER" \
DREAM_TIMEOUT_SECONDS="$TIMEOUT" \
    bash "$DREAMING_REPO/bin/dreaming" dream >/dev/null 2>&1
dream_exit=$?
runtime=$(( $(date +%s) - start ))
echo "      exit=$dream_exit, runtime=${runtime}s"

# 3. Score with the fitness function
echo "[3/4] running fitness check..."
latest_log=$(find "$BENCH_HOME/dream-logs" -maxdepth 1 -name 'run-*.log' -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | head -1)
if [ -z "$latest_log" ]; then
    echo "      FATAL: no log produced — dream invocation failed before any output" >&2
    exit 2
fi
quality_json=$(DREAMING_HOME="$BENCH_HOME" bash "$DREAMING_REPO/core/dream-quality-check.sh" --log "$latest_log" --json 2>/dev/null || echo '{"verdict":"error","score":"?/?"}')
score=$(printf '%s' "$quality_json" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("score","?/?"))')
verdict=$(printf '%s' "$quality_json" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("verdict","?"))')

# 4. Summary
echo "[4/4] result"
echo ""
printf "  adapter=%-8s  exit=%-3s  score=%-5s  verdict=%-6s  runtime=%ss\n" \
    "$ADAPTER" "$dream_exit" "$score" "$verdict" "$runtime"
echo ""
echo "  log:     $latest_log"
echo "  details: bash $DREAMING_REPO/core/dream-quality-check.sh --log $latest_log --verbose"
echo "  cleanup: rm -rf $BENCH_HOME"
