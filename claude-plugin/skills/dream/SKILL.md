---
name: dream
description: Run the monthly deep memory consolidation loop. Use when the user types /dream, asks to consolidate memory, or asks to merge/trim accumulated learnings. Spawns a constrained Claude subprocess that snapshots all memory dirs, then merges/trims/synthesises with full rollback safety.
---

You are invoking the dreaming pipeline's monthly consolidation loop.

## What to do

Run this command:
```bash
bash ${CLAUDE_PLUGIN_ROOT}/../bin/dreaming dream
```

This will:
1. Acquire a mutex (blocks if self-learn or promote-dream is running)
2. Snapshot every project's memory dir to `$DREAMING_HOME/dream-logs/snapshots/`
3. Invoke the configured LLM adapter (default: claude) with the dream prompt and constrained tools
4. Stage proposals to each project's `memory/_pending_review/<run-id>/`
5. Run the fitness check and append the score to `dream-quality-history.jsonl`
6. Notify when complete

## Then

After the run finishes, tell the user:
- The score (e.g. "7/7 PASS")
- Where proposals are waiting (`memory/_pending_review/<run-id>/`)
- That they can review with `/promote-dream` (or `dreaming promote`)

If the fitness check failed, read the log and explain which rules broke. Do not auto-fix without asking.
