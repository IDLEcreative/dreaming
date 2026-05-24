#!/bin/bash
# Google Gemini CLI adapter for dreaming. STUB — implementation pending.
#
# Gemini CLI: `gemini-cli` from Google (https://github.com/google/gemini-cli)
# Pattern: `gemini --prompt "$(cat <prompt-file>)" --tools file_read,file_write,shell`
#
# To implement:
#   1. Verify `gemini` (or `gemini-cli`) binary is in PATH.
#   2. Read prompt_file contents.
#   3. Invoke gemini with file + shell tools enabled, sandboxed to $DREAMING_HOME.
#   4. Use --no-internet / --sandbox flags if Gemini CLI exposes them.
#   5. Return exit code.
#
# Model recommendation: gemini-2.5-pro for the dream prompt's complexity; flash for self-learn.

dreaming_preflight() {
    if ! command -v gemini >/dev/null 2>&1 && ! command -v gemini-cli >/dev/null 2>&1; then
        echo "dreaming/gemini: gemini CLI not found in PATH" >&2
        echo "  install: see https://github.com/google/gemini-cli" >&2
        return 1
    fi
    return 0
}

dreaming_invoke_llm() {
    echo "dreaming/gemini: adapter not implemented yet" >&2
    echo "  see adapters/gemini.sh for the spec — PRs welcome" >&2
    return 99
}
