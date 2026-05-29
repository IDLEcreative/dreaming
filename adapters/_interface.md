# Adapter Interface — How to plug a new LLM into dreaming

An adapter is a single bash file that exposes one function: `dreaming_invoke_llm`. The core pipeline (snapshot → invoke → diff → quality-check) calls this function and is otherwise LLM-agnostic.

## Contract

```bash
# Required function. Source the adapter and call this from core/dream.sh.
dreaming_invoke_llm() {
    local prompt_file="$1"    # path to a markdown prompt; pass its contents to the LLM
    local timeout_seconds="$2" # hard wall-clock limit
    local log_file="$3"        # append stdout+stderr here (one line: CLI exec line)

    # MUST:
    #   - read prompt_file
    #   - run the LLM with file-edit + bash tools enabled
    #   - constrain the LLM to read-write inside $DREAMING_HOME (no internet, no MCP, no spawning agents)
    #   - return the LLM's exit code
    #   - write transcript to stdout (will be captured to log_file by the caller)

    # MUST NOT:
    #   - call out to a different LLM
    #   - allow web access (no WebFetch, no WebSearch, no curl in tool allowlist)
    #   - allow remote agent spawning
}

# Optional function. If defined, core will call it before invoke_llm to verify
# the LLM CLI is installed and authenticated. Should print a diagnostic on stderr
# and return non-zero if not ready.
dreaming_preflight() {
    command -v <my-llm-cli> >/dev/null 2>&1 || {
        echo "dreaming: <my-llm-cli> not found in PATH" >&2
        return 1
    }
    return 0
}
```

## Environment variables the adapter MAY read

- `DREAMING_HOME` — root data dir (default `~/.dreaming/`). The LLM must be sandboxed to this.
- `DREAMING_MODEL` — model identifier override (e.g. `claude-sonnet-4-6`, `gpt-5.4`, `gemini-2.5-pro`). Adapter chooses a sensible default if unset.
- `DREAMING_VERBOSE` — if `1`, emit per-step diagnostics to stderr.

## Prompt is pre-rendered before it reaches you

By the time the core calls `dreaming_invoke_llm`, the prompt template's `${...}`
path placeholders have already been substituted to absolute paths by
`core/lib/render-prompt.sh`. Your adapter just reads the file and passes its
contents to the LLM — no path handling needed.

If your LLM's on-disk layout differs from Claude Code's (where `CLAUDE.md` and
`commands/` live under `~/.claude`), set these before the core renders:

- `DREAMING_AGENT_CONFIG` — dir holding the global instructions file + command
  defs. Defaults to `~/.claude`. Set empty/elsewhere if your LLM has no equivalent.
- `DREAMING_CROSS_PROJECT_ROOT` — the cross-project memory layer. Defaults to
  `$DREAMING_HOME/projects/-Users-<whoami>`.

Most adapters need neither — the defaults work whenever `$DREAMING_HOME/projects`
holds the memory tree.

## Why these constraints

The dreaming pipeline mutates your memory dirs. The adapter is the trust boundary. If the LLM gets internet access or can spawn arbitrary agents, a prompt-injected memory file could exfiltrate your other memory files or modify them with adversarial content. The interface enforces the safety contract that the core pipeline depends on.

## Adapters in this repo

| Adapter | Status | LLM |
|---|---|---|
| `claude.sh` | working | Anthropic Claude via the `claude` CLI |
| `codex.sh` | stub | OpenAI Codex CLI |
| `gemini.sh` | stub | Google Gemini CLI |
| `ollama.sh` | stub | Local models via Ollama |
| `openai.sh` | stub | OpenAI raw API via custom shim |

To add another LLM: copy `claude.sh`, rename, and implement `dreaming_invoke_llm` against your LLM's CLI. The rest of the pipeline doesn't care.
