#!/bin/bash
# memory-usage-tally.sh: PostToolUse(Read) hook, tallies every read of a memory topic file.
#
# WHY: the retire step in a dream run, and memory-hygiene's RETIRE check, both
# degrade memories by AGE, because nothing records which memories are actually
# recalled. Age is a poor proxy: a file untouched for six months may be the one
# that saves the next session, and a file written last week may never be read
# again. This hook turns every Read of a memory file into one JSONL line, so
# retirement can be evidence-based (read counts) instead of guesswork.
#
# Wire-up: PostToolUse hook, matcher "Read".
# Log:     $DREAMING_HOME/memory-usage.jsonl  (append-only; atomic small appends)
# Report:  bash hooks/memory-usage-tally.sh --report   <- dream step 0 consumes this
#
# Env:
#   DREAMING_MEMORY_ROOT   memory root override
#
# Always exits 0. A tally must never block or slow a session.

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=core/lib/memory-paths.sh
. "$HOOK_DIR/../core/lib/memory-paths.sh"

LOG="$(dreaming_state_root)/memory-usage.jsonl"
MEMORY_ROOT="$(dreaming_memory_root)"
export MEMORY_ROOT

if [ "${1:-}" = "--report" ]; then
  python3 - "$LOG" <<'PY'
import json, os, sys, glob, collections, signal

signal.signal(signal.SIGPIPE, signal.SIG_DFL)  # quiet exit when piped into head
log = sys.argv[1]
root = os.environ["MEMORY_ROOT"].rstrip("/")
counts = collections.Counter()
first_ts = None
if os.path.exists(log):
    with open(log) as f:
        for line in f:
            try:
                e = json.loads(line)
            except Exception:
                continue
            if first_ts is None:
                first_ts = e.get("ts")
            counts[e.get("file", "")] += 1

if first_ts:
    print(f"Tallying since: {first_ts}  ({sum(counts.values())} reads, {len(counts)} distinct files)\n")
else:
    print("No reads tallied yet.\n")

print("== Most-read memories ==")
for path, n in counts.most_common(25):
    print(f"{n:5}  {path.replace(root + '/', '')}")

print("\n== Never-read topic files (per project; excludes indexes, _archive, backups) ==")
print("NOTE: only meaningful once the tally has run for a few weeks.")
for mem_dir in sorted(glob.glob(os.path.join(root, "*", "memory"))):
    project = os.path.basename(os.path.dirname(mem_dir))
    never = []
    for f in sorted(glob.glob(os.path.join(mem_dir, "*.md"))):
        base = os.path.basename(f)
        if base.startswith("MEMORY"):
            continue  # indexes load via the harness, not Read, so absence here is not "unused"
        if counts.get(f, 0) == 0:
            never.append(base)
    if never:
        print(f"\n{project}  ({len(never)} never read)")
        for b in never:
            print(f"       {b}")
PY
  exit 0
fi

# Hook mode: read the PostToolUse JSON from stdin, tally if it's a memory file.
# (Capture stdin FIRST: the python heredoc below consumes fd 0 for the program.)
HOOK_JSON="$(cat 2>/dev/null)"
export HOOK_JSON
python3 - "$LOG" <<'PY'
import json, sys, os, datetime

log = sys.argv[1]
try:
    data = json.loads(os.environ.get("HOOK_JSON", ""))
except Exception:
    sys.exit(0)

path = (data.get("tool_input") or {}).get("file_path") or ""
root = os.environ["MEMORY_ROOT"].rstrip("/") + "/"
if not path.startswith(root) or "/memory/" not in path or not path.endswith(".md"):
    sys.exit(0)

entry = {"ts": datetime.datetime.now().strftime("%Y-%m-%dT%H:%M:%S"), "file": path}
try:
    os.makedirs(os.path.dirname(log), exist_ok=True)
    with open(log, "a") as f:
        f.write(json.dumps(entry) + "\n")
except Exception:
    pass  # never fail the session over a tally
PY
exit 0
