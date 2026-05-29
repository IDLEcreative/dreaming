#!/bin/bash
# OpenAI adapter for dreaming. Drives adapters/lib/openai_tool_loop.py against
# api.openai.com. For users who want OpenAI models without the Codex CLI.
#
# Sandbox: best-effort (Python shim — see openai_tool_loop.py header). For hard
# OS-level isolation prefer the codex adapter.
#
# Model: defaults to gpt-5.4. Override via DREAMING_MODEL.

dreaming_preflight() {
    [ -n "${OPENAI_API_KEY:-}" ] || {
        echo "dreaming/openai: OPENAI_API_KEY not set" >&2
        return 1
    }
    command -v python3 >/dev/null 2>&1 || { echo "dreaming/openai: python3 required" >&2; return 1; }
    return 0
}

dreaming_invoke_llm() {
    local prompt_file="$1"
    local timeout_seconds="$2"
    local workspace="${DREAMING_HOME:-$HOME/.dreaming}"
    local model="${DREAMING_MODEL:-gpt-5.4}"
    local shim
    shim="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/openai_tool_loop.py"

    DREAM_RUN_ID="${DREAM_RUN_ID:-$(date +%s)-$$}" \
    timeout "$timeout_seconds" \
    python3 "$shim" \
        --workspace "$workspace" \
        --prompt-file "$prompt_file" \
        --base-url "https://api.openai.com/v1" \
        --model "$model" \
        --api-key-env OPENAI_API_KEY \
        2>&1
    return $?
}
