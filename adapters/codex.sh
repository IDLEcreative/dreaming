#!/bin/bash
# OpenAI Codex CLI adapter for dreaming.
#
# Tested against codex-cli 0.128.0 (May 2026).
# Invocation pattern: `codex exec -s workspace-write -C $DREAMING_HOME ...`
#
# Safety constraints enforced:
#   • Sandbox: workspace-write — file ops constrained to -C dir + --add-dir entries
#   • Network: explicitly disabled via sandbox_workspace_write.network_access=false
#   • Session persistence: --ephemeral (no sidecar files in ~/.codex/sessions/)
#   • Git check: bypassed via --skip-git-repo-check (DREAMING_HOME isn't a git repo)
#
# Model: defaults to gpt-5-codex. Override via DREAMING_MODEL.
# Reasoning effort: dreaming is mostly file IO + classification. Don't burn output
# tokens on chain-of-thought; the LLM should act, not deliberate.

dreaming_preflight() {
    command -v codex >/dev/null 2>&1 || {
        echo "dreaming/codex: codex CLI not found in PATH" >&2
        echo "  install: see https://github.com/openai/codex" >&2
        return 1
    }
    # Confirm login state — codex exec will fail with auth errors otherwise.
    # `codex` prints a usage banner even when logged out, so we probe via a config read.
    if ! codex --help >/dev/null 2>&1; then
        echo "dreaming/codex: codex CLI installed but failing to invoke" >&2
        return 1
    fi
    return 0
}

dreaming_invoke_llm() {
    local prompt_file="$1"
    local timeout_seconds="$2"

    if [ ! -f "$prompt_file" ]; then
        echo "dreaming/codex: prompt file missing at $prompt_file" >&2
        return 2
    fi

    local workspace="${DREAMING_HOME:-$HOME/.dreaming}"

    # Model selection: ChatGPT-account auth restricts the model set (e.g. 'gpt-5-codex'
    # returns 400 for ChatGPT users). When DREAMING_MODEL is unset, let codex pick its
    # config default — whatever the user's auth type allows. Only override when explicit.
    local model_args=()
    if [ -n "${DREAMING_MODEL:-}" ]; then
        model_args=(--model "$DREAMING_MODEL")
    fi

    # IMPORTANT: codex exec runs the prompt within -C as its workspace root.
    # workspace-write sandbox restricts file ops; we add network=false explicitly
    # so the LLM cannot exfil memory content via curl / fetch.
    DREAM_RUN_ID="${DREAM_RUN_ID:-$(date +%s)-$$}" \
    timeout "$timeout_seconds" \
    codex exec \
        --sandbox workspace-write \
        --cd "$workspace" \
        --skip-git-repo-check \
        --ephemeral \
        "${model_args[@]+"${model_args[@]}"}" \
        -c 'sandbox_workspace_write.network_access=false' \
        "$(cat "$prompt_file")" \
        2>&1
    return $?
}
