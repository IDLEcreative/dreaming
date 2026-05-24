# dreaming

**Long-term memory for LLM agents.** A four-phase pipeline that captures, consolidates, and curates what your AI assistant learns — across sessions, across projects, across LLMs.

Works with **any LLM** that has a CLI with file-edit + bash tools. Ships with a working Claude adapter and stub adapters for Codex, Gemini, Ollama, and raw OpenAI.

---

## Why

Most agent setups have a memory problem. They append to a `MEMORY.md`, drift accumulates, files get stale, duplicates pile up, and the agent eventually loses the thread of what it knows. The fix isn't "bigger context" — it's **scheduled consolidation**, the way humans dream.

`dreaming` runs four loops:

| Loop | Cadence | What it does |
|---|---|---|
| **capture** | every session | Sessions write learnings to project memory dirs. No action needed — your existing agent setup already does this. |
| **self-learn** | weekly | Scans recent session transcripts, drafts new memory files, stages them for review. Promotion-only — no merging or trimming. |
| **dream** | monthly | Deep consolidation. Reads all memory, merges duplicates, trims stale, synthesises principles, surfaces skill gaps. Snapshot before, full rollback. |
| **promote** | manual | Review-and-adopt step. Stages → live with explicit confirmation. Default mode is dry-run; `--commit` to actually apply. |

Plus a **fitness function** (`dreaming health`) that mechanically verifies every dream run followed the contract, catching prompt drift before it corrupts memory.

## Quick start

```bash
git clone https://github.com/<your-handle>/dreaming.git ~/Projects/dreaming
~/Projects/dreaming/bin/dreaming init                # creates ~/.dreaming/
~/Projects/dreaming/bin/dreaming adapters            # see what's installed
DRY_RUN=1 ~/Projects/dreaming/bin/dreaming dream     # smoke-test (no LLM call)
~/Projects/dreaming/bin/dreaming dream               # real run (uses ~$1-3 in LLM credits)
~/Projects/dreaming/bin/dreaming health              # was the run clean?
```

Add `~/Projects/dreaming/bin` to your PATH and `dreaming` becomes a top-level command.

## LLM adapters

| Adapter | Status | Setup |
|---|---|---|
| `claude` | ✅ working | Install the [Claude Code CLI](https://docs.anthropic.com/claude-code) |
| `codex` | 🟡 stub | Install [OpenAI Codex CLI](https://github.com/openai/codex), implement `adapters/codex.sh` |
| `gemini` | 🟡 stub | Install [Gemini CLI](https://github.com/google/gemini-cli), implement `adapters/gemini.sh` |
| `ollama` | 🟡 stub | Install [Ollama](https://ollama.ai); needs a tool-calling shim (non-trivial) |
| `openai` | 🟡 stub | Set `OPENAI_API_KEY`; needs a Python harness to do the tool-call loop |

Pick your LLM with `DREAMING_ADAPTER=<name>`. Adding a new one is one bash file implementing one function — see `adapters/_interface.md`.

## Architecture

```
dreaming/
├── bin/dreaming               # dispatcher (one command, many subcommands)
├── core/                      # LLM-agnostic pipeline scripts
│   ├── dream.sh               # the monthly deep loop
│   ├── self-learn.sh          # weekly promotion loop
│   ├── promote-dream.sh       # review-and-adopt (pure file ops — no LLM call)
│   ├── dream-quality-check.sh # fitness function
│   └── init.sh                # first-run setup
├── adapters/                  # LLM drivers — one file each, one function
│   ├── _interface.md          # the contract
│   ├── claude.sh              # ✅ working
│   ├── codex.sh               # 🟡 stub
│   ├── gemini.sh              # 🟡 stub
│   ├── ollama.sh              # 🟡 stub
│   └── openai.sh              # 🟡 stub
├── prompts/                   # the LLM instructions (LLM-agnostic markdown)
│   ├── dream.md               # the monthly deep prompt
│   └── self-learn.md          # the weekly promotion prompt
├── hooks/
│   └── pending-review-reminder.sh   # surfaces aged proposals (Claude Code Stop hook)
├── claude-plugin/             # optional: register as a Claude Code plugin
│   ├── plugin.json
│   └── skills/                # /dream, /dream-health, /learn-now, /promote-dream
├── launchd/                   # macOS cron templates
├── systemd/                   # Linux cron templates
└── docs/                      # design notes, post-mortems, fitness-check rules
```

Data layer (separate from code, never overwritten by `git pull`):

```
~/.dreaming/                   # $DREAMING_HOME — your memory + state
├── projects/<project>/memory/ # per-project memory files (markdown + frontmatter)
│   ├── MEMORY.md              # index — what's in this dir
│   ├── feedback_*.md          # captured learnings
│   ├── reference_*.md         # reusable references
│   ├── principle_*.md         # synthesised principles (from dream)
│   ├── _pending_review/       # staged proposals awaiting promote
│   └── _archive/              # trimmed-out files (recoverable)
├── dream-logs/                # per-run logs + snapshots
├── dream-history.md           # human-readable run history
├── dream-quality-history.jsonl # one JSON line per run, score trend
└── .dream-last-run            # epoch sentinel for "did dream run recently?"
```

## Safety

- **Snapshot before every run.** Every project memory dir copies to `dream-logs/snapshots/<timestamp>/` before the LLM touches it. Rollback is `rm -rf live && cp -R snapshot live`.
- **Mutex coordination.** Dream, self-learn, and promote share locks via `mkdir` (atomic on BSD/Linux). Concurrent writes are impossible by design.
- **Tool allowlist.** Each adapter constrains the LLM to file ops + bash. No web, no MCP, no agent spawning — closes the exfiltration surface against prompt injection in memory files.
- **Dry-run default for adoption.** `promote adopt <run-id>` is dry-run unless you pass `--commit`.
- **Hash-at-stage.** Every staged proposal gets a `.sha256` sentinel at staging time. Adoption verifies the hash — tampering between stage and adopt fails closed.
- **Fitness function as guardrail.** `dreaming health` runs after every dream and surfaces contract violations. The score lands in `dream-quality-history.jsonl` whether anyone looks or not — drift can't accumulate silently.

## Status

- **v1.0** — ✅ Adapter pattern, core dream loop, fitness check, Claude adapter working.
- **v1.1** — ✅ self-learn.sh + promote-dream.sh ported. All four subcommands now route through the LLM-agnostic core. Claude users get full backward compatibility (DREAMING_HOME falls back to ~/.claude if no ~/.dreaming exists).
- **v2.0** (vision) — Codex / Gemini / OpenAI / Ollama adapters implemented and tested. Cross-LLM benchmark: which model is best at the dream task at what cost?

Contributions welcome — especially adapter implementations.

## Credit

Built on the long-term-memory pipeline originally developed inside `~/.claude/scripts/` over several months. The fitness function (`dream-quality-check.sh`) emerged from a 2026-05-24 session that exposed how much silent contract drift was happening between dream runs. Packaging this as `dreaming` makes it portable, installable, and LLM-portable — instead of a Claude-Code-only convention that lived in one person's home directory.
