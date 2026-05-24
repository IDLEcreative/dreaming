#!/bin/bash
# Ollama (local LLM) adapter for dreaming. STUB — implementation pending.
#
# Ollama runs models locally with no API key. https://ollama.ai
# Pattern: `ollama run <model> < prompt-file`
#
# CAVEAT — local models are mostly NOT capable enough for the dream prompt today.
# The dream loop does merge-vs-trim classification, cross-project supersession detection,
# and 7-section structured output. Small local models (8B and under) will produce
# rule-violating output that fails the fitness check. Use 70B+ models or expect failures.
#
# Tested OK for self-learn (simpler promotion-only loop) on llama-3.1-70b at 4-bit.
# Untested for dream — likely needs llama-3.3-70b or qwen-2.5-72b minimum.
#
# To implement:
#   1. Verify ollama is running (curl localhost:11434).
#   2. Verify the chosen model is pulled (ollama list).
#   3. Wrap ollama with a shim that gives it Read/Write/Bash tool access
#      — ollama itself doesn't have tool-calling; you'd need a separate harness
#      like ollama-functions or a custom MCP server.
#
# This is the highest-effort adapter. Recommend punting until at least one cloud LLM works.

dreaming_preflight() {
    command -v ollama >/dev/null 2>&1 || {
        echo "dreaming/ollama: ollama not found in PATH" >&2
        echo "  install: https://ollama.ai" >&2
        return 1
    }
    # Check that ollama daemon is running
    curl -sf http://localhost:11434/api/tags >/dev/null 2>&1 || {
        echo "dreaming/ollama: ollama daemon not running (curl localhost:11434 failed)" >&2
        echo "  start with: ollama serve" >&2
        return 1
    }
    return 0
}

dreaming_invoke_llm() {
    echo "dreaming/ollama: adapter not implemented yet" >&2
    echo "  local LLMs need a tool-calling harness — see adapters/ollama.sh notes" >&2
    return 99
}
