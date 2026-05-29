#!/bin/bash
# Google Gemini CLI adapter for dreaming.
#
# Verified against gemini-cli 0.37.1 (May 2026).
# Invocation: `gemini -p "<prompt>" --approval-mode yolo --sandbox`
#
# Safety constraints:
#   • Workspace: the LLM operates in cwd, which dream.sh sets to $DREAMING_HOME
#     before calling the adapter.
#   • Sandbox: --sandbox runs tool calls under macOS Seatbelt / Docker, isolating
#     the filesystem + network. (Seatbelt is used automatically on macOS — no
#     Docker required.)
#   • Approval: --approval-mode yolo auto-approves tool calls (required for an
#     unattended run); the sandbox is what bounds what those tools can touch.
#
# Model: defaults to the CLI's configured default. Override via DREAMING_MODEL.

dreaming_preflight() {
    command -v gemini >/dev/null 2>&1 || {
        echo "dreaming/gemini: gemini CLI not found in PATH" >&2
        echo "  install: https://github.com/google-gemini/gemini-cli" >&2
        return 1
    }
    return 0
}

dreaming_invoke_llm() {
    local prompt_file="$1"
    local timeout_seconds="$2"

    if [ ! -f "$prompt_file" ]; then
        echo "dreaming/gemini: prompt file missing at $prompt_file" >&2
        return 2
    fi

    local model_args=()
    if [ -n "${DREAMING_MODEL:-}" ]; then
        model_args=(-m "$DREAMING_MODEL")
    fi

    # gemini operates in cwd; dream.sh has already cd'd to $DREAMING_HOME.
    # --sandbox bounds filesystem + network; --approval-mode yolo runs unattended.
    DREAM_RUN_ID="${DREAM_RUN_ID:-$(date +%s)-$$}" \
    timeout "$timeout_seconds" \
    gemini \
        -p "$(cat "$prompt_file")" \
        --approval-mode yolo \
        --sandbox \
        "${model_args[@]+"${model_args[@]}"}" \
        2>&1
    return $?
}
