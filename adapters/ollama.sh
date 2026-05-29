#!/bin/bash
# Ollama (local LLM) adapter for dreaming. Drives adapters/lib/openai_tool_loop.py
# against Ollama's OpenAI-compatible endpoint (http://localhost:11434/v1).
#
# No API key, no cloud — runs entirely on your machine.
#
# CAVEAT — model capability. The dream loop does merge-vs-trim classification,
# cross-project supersession detection, and structured tool use. Small local
# models (≤8B) will produce rule-violating output that fails the fitness check.
# Use a 70B-class model with solid tool-calling (e.g. llama-3.3-70b, qwen-2.5-72b).
# Set DREAMING_MODEL to the exact `ollama list` tag.
#
# Sandbox: best-effort (Python shim — see openai_tool_loop.py header).

dreaming_preflight() {
    command -v ollama >/dev/null 2>&1 || {
        echo "dreaming/ollama: ollama not found in PATH" >&2
        echo "  install: https://ollama.ai" >&2
        return 1
    }
    command -v python3 >/dev/null 2>&1 || { echo "dreaming/ollama: python3 required" >&2; return 1; }
    # Daemon must be up to serve the OpenAI-compatible API.
    curl -sf http://localhost:11434/api/tags >/dev/null 2>&1 || {
        echo "dreaming/ollama: daemon not reachable at localhost:11434 — run 'ollama serve'" >&2
        return 1
    }
    if [ -z "${DREAMING_MODEL:-}" ]; then
        echo "dreaming/ollama: set DREAMING_MODEL to an installed model tag (see 'ollama list')" >&2
        echo "  recommend a 70B-class model — smaller ones fail the dream contract" >&2
        return 1
    fi
    return 0
}

dreaming_invoke_llm() {
    local prompt_file="$1"
    local timeout_seconds="$2"
    local workspace="${DREAMING_HOME:-$HOME/.dreaming}"
    local model="${DREAMING_MODEL}"   # required (enforced in preflight)
    local shim
    shim="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/openai_tool_loop.py"

    DREAM_RUN_ID="${DREAM_RUN_ID:-$(date +%s)-$$}" \
    timeout "$timeout_seconds" \
    python3 "$shim" \
        --workspace "$workspace" \
        --prompt-file "$prompt_file" \
        --base-url "http://localhost:11434/v1" \
        --model "$model" \
        2>&1
    return $?
}
