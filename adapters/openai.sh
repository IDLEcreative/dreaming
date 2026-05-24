#!/bin/bash
# OpenAI raw-API adapter for dreaming. STUB — implementation pending.
#
# For OpenAI users who don't want Codex CLI specifically. Hits the Responses API
# (https://platform.openai.com/docs/api-reference/responses) with a custom shim
# that provides file_read/file_write/shell tools.
#
# This is materially more work than the codex.sh adapter because you have to
# implement the tool-use loop yourself in bash + curl + jq:
#   1. POST prompt + tool defs to /v1/responses
#   2. Parse response — if tool_call, execute the tool (jq + bash), send result back
#   3. Loop until response.completed
#
# A python shim (`adapters/lib/openai_loop.py`) would be cleaner. Recommend that
# route if you're going to implement.
#
# Models: gpt-5.4 for the dream loop; gpt-5.4-mini for self-learn.

dreaming_preflight() {
    [ -n "${OPENAI_API_KEY:-}" ] || {
        echo "dreaming/openai: OPENAI_API_KEY not set" >&2
        return 1
    }
    command -v curl >/dev/null 2>&1 || { echo "dreaming/openai: curl required" >&2; return 1; }
    command -v jq   >/dev/null 2>&1 || { echo "dreaming/openai: jq required (brew install jq)" >&2; return 1; }
    return 0
}

dreaming_invoke_llm() {
    echo "dreaming/openai: adapter not implemented yet" >&2
    echo "  see adapters/openai.sh for the spec — recommend implementing as a Python shim" >&2
    return 99
}
