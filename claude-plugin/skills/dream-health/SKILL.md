---
name: dream-health
description: Run the fitness check on the most recent dream run and report the score + diagnosis. Use when the user types /dream-health, asks "is dream OK?", asks for the memory-pipeline health status, or wants to know whether the most recent consolidation followed the contract.
---

You are reporting the health of the dreaming pipeline.

## What to do

Run:
```bash
bash ${CLAUDE_PLUGIN_ROOT}/../bin/dreaming health --json
```

Parse the JSON output. The trend lives at `$DREAMING_HOME/dream-quality-history.jsonl` — read the last 5 lines for context.

## Format for the user

```
Latest run: <timestamp> → <score> <PASS|FAIL> (age <N>h)
Trend (last 5): <pass count>/<total> passes, last <consecutive-pass-count> in a row
Last failure: <timestamp> (<failed-rules>)
[If currently failing] Likely cause: <interpretation>
[If currently failing] Next: <one specific action>
```

## Then

Don't auto-fix anything. If R6 is failing (broken wiki-links), offer to investigate but wait for confirmation — fixing wiki-links is editing memory files, which the user owns.

If R7 is failing (stale pending-review queue), suggest `/promote-dream`.

If R1-R5 are failing, the dream prompt may have drifted — surface the failure but don't try to rewrite the prompt without explicit ask.
