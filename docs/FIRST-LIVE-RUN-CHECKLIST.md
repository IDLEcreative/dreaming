# First Live Run — Verification Checklist

**Why this exists:** as of 2026-05-29 the dreaming pipeline was cut over to the
portable, LLM-agnostic code (`~/Projects/dreaming/bin/dreaming`) driven by the
templated prompts. Every prior 7/7 was a *manual bench* in an isolated
`$DREAMING_HOME`. The scheduled launchd jobs have **never fired on the portable
code yet**. These first two unattended runs are the real production test.

## The two firsts (self-learn fires BEFORE dream)

| Run | Job | First live fire | Fitness-gated? |
|---|---|---|---|
| **self-learn** (weekly) | `com.example.dreaming-self-learn` | **Sun 2026-05-31, 03:00 BST** | No (writes its own history only) |
| **dream** (monthly) | `com.example.dreaming-dream` | **Mon 2026-06-01, 03:30 BST** | Yes (R1–R7 score appended) |

Both run as: `/bin/bash ~/Projects/dreaming/bin/dreaming {learn|dream}` with
`DREAMING_HOME=$HOME/.dreaming` (projects symlinked → `~/.claude/projects`).

---

## After self-learn (check any time after Sun 31 May 03:00)

```bash
# 1. Did it run + complete cleanly?
ls -lt ~/.dreaming/self-learn-logs/run-*.log | head -1
tail -30 "$(ls -t ~/.dreaming/self-learn-logs/run-*.log | head -1)"
#   → expect a "SELF-LEARN RUN COMPLETE — promoted N / edited M / ..." marker line

# 2. launchd-level errors (env/path problems show here, not in the run log)
cat ~/.dreaming/self-learn-logs/launchd-stderr.log 2>/dev/null
#   → expect empty / no "command not found" / no "HOME must be set"

# 3. Did it stage anything for review?
~/Projects/dreaming/bin/dreaming promote list
#   → review with `dreaming promote show <run-id>` before adopting
```

**Pass:** log ends with the COMPLETE marker, no launchd-stderr errors, diff summary
shows either "unchanged" or sane promotions.
**Fail signature:** empty/short log, `launchd-stderr.log` shows `claude: command not
found` or `HOME must be set` → the launchd env block is wrong (see Rollback).

---

## After dream (check any time after Mon 1 Jun 03:30)

```bash
# 1. The headline — fitness score for the first live monthly run
cat ~/.dreaming/dream-quality-history.jsonl | tail -1
#   → expect {"timestamp":"2026-06-01...","adapter":"claude","score":"7/7","verdict":"pass",...}
#   NOTE: this file is currently EMPTY — the first live run creates the first entry.

# 2. Full verdict + which rules (if any) failed
~/Projects/dreaming/bin/dreaming health --verbose

# 3. Read the run itself
tail -40 "$(ls -t ~/.dreaming/dream-logs/run-*.log | head -1)"
#   → expect the "## RUN SUMMARY" block with Audited-split + Memory-delta lines,
#     ending in "DREAM RUN COMPLETE — merged N / trimmed N / ..."
#   → a "=== QUALITY CHECK: FAIL ===" banner appears here ONLY if it scored <7/7

# 4. launchd-level errors
cat ~/.dreaming/dream-logs/launchd-stderr.log 2>/dev/null

# 5. Anything staged?
~/Projects/dreaming/bin/dreaming promote list
```

**Pass:** `verdict":"pass"`, score 7/7, no FAIL banner, no launchd-stderr errors.
**Partial:** score 4–6/7 = the run completed but drifted. NOT an emergency — proposals
are staged in `_pending_review/`, nothing was force-applied. Read which R failed:
- R1 (insight boxes) / R2 (audited split) / R3 (memory delta) → prompt-adherence drift
- R6 (broken wiki-links) → a recent memory file has a bad `[[link]]`; fix the link
- R7 (stale pending-review) → run `dreaming promote` to clear the backlog

---

## If a run FAILED to execute at all (launchd env problem)

Most likely cause: launchd's stripped environment. The plists set `HOME`, `PATH`,
`DREAMING_HOME`, `DREAMING_ADAPTER` — if any run shows `command not found` or
`HOME must be set`, the env block regressed.

Rollback to the legacy claude-only cron (reversible, ~10s):
```bash
UID=$(id -u)
launchctl bootout gui/$UID ~/Library/LaunchAgents/com.example.dreaming-dream.plist
launchctl bootout gui/$UID ~/Library/LaunchAgents/com.example.dreaming-self-learn.plist
mv ~/Library/LaunchAgents/com.example.claude-dream.plist.bak ~/Library/LaunchAgents/com.example.claude-dream.plist
mv ~/Library/LaunchAgents/com.example.claude-self-learn.plist.bak ~/Library/LaunchAgents/com.example.claude-self-learn.plist
launchctl bootstrap gui/$UID ~/Library/LaunchAgents/com.example.claude-dream.plist
launchctl bootstrap gui/$UID ~/Library/LaunchAgents/com.example.claude-self-learn.plist
```
The legacy scripts are preserved at `~/.claude/scripts/_legacy_pre_dreaming/`.

## Don't want to wait for the cron? Force a run now

```bash
# Real run (uses ~$1–3 of LLM credits, ~7–9 min). Safe — snapshots before touching memory.
DREAMING_HOME=~/.dreaming ~/Projects/dreaming/bin/dreaming dream
# Or kick the launchd job directly (exercises the exact scheduled path + env):
launchctl kickstart -k gui/$(id -u)/com.example.dreaming-dream
```

## Snapshot of state at handoff (2026-05-29)

- Repo: github.com/IDLEcreative/dreaming (public), HEAD `4a5d37c`, clean + synced.
- 5 adapters all "ready": claude, codex (both full-dream 7/7), gemini, openai, ollama.
- Test suite: `bash tests/run-tests.sh` → 19/19 green.
- Memory corpus: 0 broken wiki-links (full sweep), 4 legacy ones fixed.
- `~/.dreaming/dream-quality-history.jsonl`: empty (first live run seeds it).
