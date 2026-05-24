#!/bin/bash
# Claude adapter for dreaming. Invokes `claude` CLI with constrained tools.
# Source this file, then call dreaming_invoke_llm.

dreaming_preflight() {
    local bin="${CLAUDE_BIN:-$HOME/.local/bin/claude}"
    if [ ! -x "$bin" ]; then
        # Try PATH fallback
        if command -v claude >/dev/null 2>&1; then
            CLAUDE_BIN=$(command -v claude)
            export CLAUDE_BIN
            return 0
        fi
        echo "dreaming: claude CLI not found (checked $bin and PATH)" >&2
        echo "  install: https://docs.anthropic.com/claude-code" >&2
        return 1
    fi
    CLAUDE_BIN="$bin"
    export CLAUDE_BIN
    return 0
}

dreaming_invoke_llm() {
    local prompt_file="$1"
    local timeout_seconds="$2"
    # log_file is the caller's redirection target; we just write to stdout.

    if [ ! -f "$prompt_file" ]; then
        echo "dreaming/claude: prompt file missing at $prompt_file" >&2
        return 2
    fi

    # Tool allowlist: file ops + bash for find/jq/grep on JSONLs.
    # NO WebFetch, NO WebSearch, NO Task (no agent spawning), NO MCP.
    # These are the exfiltration vectors the contract forbids.
    CLAUDE_DREAM_RUNNING=1 \
    DREAM_RUN_ID="${DREAM_RUN_ID:-$(date +%s)-$$}" \
    timeout "$timeout_seconds" \
    "$CLAUDE_BIN" \
        -p "$(cat "$prompt_file")" \
        --allowed-tools "Read,Glob,Grep,Edit,Write,Bash" \
        --disallowed-tools "WebFetch,WebSearch,Task,mcp__*" \
        --dangerously-skip-permissions \
        2>&1
    return $?
}
