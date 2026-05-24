---
name: learn-now
description: Run the weekly self-learn promotion loop. Use when the user types /learn-now or asks to consolidate recent session learnings without doing the full monthly dream loop. Lighter than dream — promotes high-confidence single-session learnings, doesn't merge or trim.
---

You are invoking the dreaming pipeline's weekly self-learn loop.

## What to do

Run:
```bash
bash ${CLAUDE_PLUGIN_ROOT}/../bin/dreaming learn
```

## Difference from /dream

- self-learn (weekly) = promotion only. Scans recent session JSONLs, drafts new memory files, stages to `_pending_review/`. No merging, no trimming.
- dream (monthly) = deep consolidation. Reads ALL memory, merges duplicates, trims stale, synthesises principles, surfaces skill gaps.

Use self-learn when the user has been active for a week and wants to capture what they learned. Use dream when accumulated memory feels noisy and needs pruning.

## Then

Tell the user how many proposals were staged and where (`memory/_pending_review/`). Suggest `/promote-dream` to review.
