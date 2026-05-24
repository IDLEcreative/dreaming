#!/bin/bash
# OpenAI Codex CLI adapter for dreaming. STUB — implementation pending.
#
# Codex CLI documented at https://github.com/openai/codex (or wherever OpenAI ships it).
# Verified working pattern from sibling projects: `codex exec -s workspace-write "<prompt>"`
# Reference: ~/.claude/projects/-Users-jamesguy/memory/reference_codex_cli.md if you have it.
#
# To implement:
#   1. Verify `codex` binary is in PATH (preflight).
#   2. Pipe prompt_file contents into `codex exec` with workspace-write scope.
#   3. Constrain to $DREAMING_HOME — codex's workspace-write defaults to cwd, so `cd "$DREAMING_HOME"` before invoking.
#   4. Pass --no-network or equivalent flag if available (forbid internet).
#   5. Return codex's exit code unchanged.
#
# Reasoning effort: `reasoning: { effort: 'minimal' }` for codex is appropriate here —
# dreaming is mostly file IO + classification, not deep reasoning. Don't burn output tokens on CoT.

dreaming_preflight() {
    command -v codex >/dev/null 2>&1 || {
        echo "dreaming/codex: codex CLI not found in PATH" >&2
        echo "  install: see https://github.com/openai/codex" >&2
        return 1
    }
    return 0
}

dreaming_invoke_llm() {
    echo "dreaming/codex: adapter not implemented yet" >&2
    echo "  see adapters/codex.sh for the spec — PRs welcome" >&2
    return 99
}
