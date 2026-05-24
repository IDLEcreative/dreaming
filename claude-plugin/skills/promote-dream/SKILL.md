---
name: promote-dream
description: Review and adopt (or discard) staged proposals from the dream/self-learn pipeline. Use when the user types /promote-dream, asks to review pending memory proposals, or wants to apply staged learnings. Default mode is dry-run — adoption requires explicit --commit.
---

You are invoking the dreaming pipeline's review-and-adopt step.

## What to do

For listing what's pending:
```bash
bash ${CLAUDE_PLUGIN_ROOT}/../bin/dreaming promote list
```

For showing a specific run:
```bash
bash ${CLAUDE_PLUGIN_ROOT}/../bin/dreaming promote show <run-id>
```

For adopting (dry-run by default, --commit to actually apply):
```bash
bash ${CLAUDE_PLUGIN_ROOT}/../bin/dreaming promote adopt <run-id> --commit
```

For discarding:
```bash
bash ${CLAUDE_PLUGIN_ROOT}/../bin/dreaming promote discard <run-id>
```

## Workflow

1. Run `list` first — show all pending across projects, sorted by age
2. For each aged proposal, run `show <run-id>` to surface the contents
3. Ask the user per-run whether to adopt or discard (or `--auto-adopt-trivial` for routine additions)
4. Run `adopt --commit` only after explicit user confirmation
5. After adoption, verify with `dreaming health` to confirm no wiki-link rot

## Safety

- Adoption snapshots the live memory dir BEFORE applying. Rollback is `git`-style: snapshot at `$DREAMING_HOME/dream-logs/snapshots/<timestamp>/`.
- Hash-at-stage sentinels (`.sha256` files) detect tampering between staging and adoption.
- Wiki-links are auto-rewritten during adoption (e.g. `[[silent-catch-family]]` → `[[feedback_silent_catch_family]]`) but this is defence-in-depth, not the primary contract.
