#!/bin/bash
# memory-dupe-check.sh: PostToolUse(Write) hook. warn when a NEWLY created memory
# file looks like a near-duplicate of an existing one in the same project.
#
# WHY: bloat is a producer problem. A session under time pressure skips the
# "does this memory already exist?" check and appends a new file instead of
# updating the one that already holds the fact. This hook makes the check
# mechanical. Every catch is ALSO logged as a recall-miss (the session had the
# knowledge and failed to find it), and that log is the evidence base for
# deciding whether the corpus has outgrown filename-and-title matching.
# (Companions: memory-usage-tally.sh, memory-index-drift.sh, core/memory-hygiene.sh.)
#
# Behaviour:
#   - Fires only on Writes to <memory-root>/*/memory/*.md
#   - Skips index files (MEMORY*.md), _archive/_pending dirs, and UPDATES to
#     existing files (only files born in the last 10 minutes are checked,
#     updating an existing memory is exactly the right behaviour, never warned).
#   - Similarity = word overlap (Jaccard) of filename+description tokens vs
#     every sibling topic file.
#   - On match: exit 2 with a note on stderr -> the session sees "similar memory
#     exists, merge instead", and the pair is appended to
#     $DREAMING_HOME/memory-dupe-log.jsonl (recall-miss evidence).
#
# Env:
#   DREAMING_MEMORY_ROOT     memory root override
#   MEMORY_DUPE_THRESHOLD    similarity threshold 0-1 (default 0.45)
#
# Tuning: bash hooks/memory-dupe-check.sh --scan <memory-dir> [threshold]
#         prints all existing pairs above threshold (calibration only, no log).

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=core/lib/memory-paths.sh
. "$HOOK_DIR/../core/lib/memory-paths.sh"

DUPE_LIB="$HOOK_DIR/lib/memory_dupe_lib.py"
LOG="$(dreaming_state_root)/memory-dupe-log.jsonl"
THRESHOLD="${MEMORY_DUPE_THRESHOLD:-0.45}"
MEMORY_ROOT="$(dreaming_memory_root)"

if [ "${1:-}" = "--scan" ]; then
  SCAN_DIR="${2:?usage: --scan <memory-dir> [threshold]}" \
  SCAN_THRESH="${3:-$THRESHOLD}" \
  DUPE_LIB="$DUPE_LIB" python3 - <<'PY'
import os, glob, itertools
exec(open(os.environ["DUPE_LIB"]).read())
d = os.environ["SCAN_DIR"]; t = float(os.environ["SCAN_THRESH"])
files = [f for f in glob.glob(os.path.join(d, "*.md"))
         if not os.path.basename(f).startswith(("MEMORY", "_"))]
sigs = {f: signature(f) for f in files}
pairs = []
for a, b in itertools.combinations(files, 2):
    s = jaccard(sigs[a], sigs[b])
    if s >= t:
        pairs.append((s, os.path.basename(a), os.path.basename(b)))
for s, a, b in sorted(pairs, reverse=True):
    print(f"{s:.2f}  {a}  <->  {b}")
print(f"\n{len(pairs)} pair(s) >= {t} across {len(files)} files")
PY
  exit 0
fi

# Hook mode: capture stdin BEFORE any heredoc consumes fd 0.
HOOK_JSON="$(cat 2>/dev/null)"
export HOOK_JSON THRESHOLD LOG MEMORY_ROOT DUPE_LIB
python3 - <<'PY'
import json, os, sys, glob, time, datetime

exec(open(os.environ["DUPE_LIB"]).read())

try:
    data = json.loads(os.environ.get("HOOK_JSON", ""))
except Exception:
    sys.exit(0)

path = (data.get("tool_input") or {}).get("file_path") or ""
root = os.environ["MEMORY_ROOT"].rstrip("/") + "/"
if not path.startswith(root) or "/memory/" not in path or not path.endswith(".md"):
    sys.exit(0)
base = os.path.basename(path)
if base.startswith(("MEMORY", "_")) or "/_" in path.split("/memory/")[-1]:
    sys.exit(0)
if not os.path.exists(path):
    sys.exit(0)

# Only newly created files. Updating an existing memory is correct, never warn.
try:
    born = os.stat(path).st_birthtime
except AttributeError:
    born = os.stat(path).st_mtime  # non-macOS fallback
if time.time() - born > 600:
    sys.exit(0)

new_sig = signature(path)
mem_dir = os.path.dirname(path)
hits = []
for f in glob.glob(os.path.join(mem_dir, "*.md")):
    if os.path.abspath(f) == os.path.abspath(path):
        continue
    if os.path.basename(f).startswith(("MEMORY", "_")):
        continue
    s = jaccard(new_sig, signature(f))
    if s >= float(os.environ["THRESHOLD"]):
        hits.append((s, os.path.basename(f)))

if not hits:
    sys.exit(0)

hits.sort(reverse=True)
log = os.environ["LOG"]
try:
    os.makedirs(os.path.dirname(log), exist_ok=True)
    with open(log, "a") as fh:
        fh.write(json.dumps({
            "ts": datetime.datetime.now().strftime("%Y-%m-%dT%H:%M:%S"),
            "new_file": path,
            "matches": [{"file": f, "score": round(s, 2)} for s, f in hits[:3]],
        }) + "\n")
except Exception:
    pass

names = ", ".join(f"{f} ({s:.0%})" for s, f in hits[:3])
sys.stderr.write(
    f"MEMORY DUPE WARNING: the new memory '{base}' overlaps existing: {names}. "
    "Read the existing file(s). If this is the same fact, DELETE the new file and "
    f"update the existing one instead (one fact, one home). Logged as a recall-miss in {log}.\n"
)
sys.exit(2)  # PostToolUse exit 2 = feed stderr back to the session (non-destructive; write already happened)
PY
