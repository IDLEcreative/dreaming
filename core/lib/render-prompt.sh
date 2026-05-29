#!/bin/bash
# render-prompt.sh — substitute path template variables into a prompt before
# handing it to an LLM adapter. Sourced by dream.sh and self-learn.sh.
#
# The prompts use ${VAR} placeholders for the four distinct path roots so the
# same prompt drives any adapter against any $DREAMING_HOME. The LLM's own
# runtime references (e.g. $DREAM_RUN_ID, $jsonl) use the brace-less $VAR form
# and are deliberately NOT substituted here.
#
# Variables substituted:
#   ${MEMORY_ROOT}         → $DREAMING_HOME/projects   (memory dirs + session files)
#   ${CROSS_PROJECT_ROOT}  → cross-project memory layer (default: <memory>/-Users-<whoami>)
#   ${AGENT_CONFIG_HOME}   → where CLAUDE.md + commands live (default: ~/.claude; Claude-only)
#   ${DREAMING_HOME}       → pipeline state root (history files, sentinels)
#
# Override CROSS_PROJECT_ROOT / AGENT_CONFIG_HOME via DREAMING_CROSS_PROJECT_ROOT
# and DREAMING_AGENT_CONFIG when an adapter's layout differs from Claude Code's.

dreaming_render_prompt() {
    local template="$1"
    local output="$2"

    if [ ! -f "$template" ]; then
        echo "dreaming: prompt template missing at $template" >&2
        return 1
    fi

    local memory_root="${DREAMING_HOME}/projects"
    local agent_config_home="${DREAMING_AGENT_CONFIG:-$HOME/.claude}"
    local cross_project_root="${DREAMING_CROSS_PROJECT_ROOT:-${memory_root}/-Users-$(whoami)}"

    # `|` delimiter — paths contain `/` but never `|`. Each ${NAME} is a distinct
    # full token, so substitution order doesn't matter (no partial overlap).
    sed \
        -e "s|\${MEMORY_ROOT}|${memory_root}|g" \
        -e "s|\${CROSS_PROJECT_ROOT}|${cross_project_root}|g" \
        -e "s|\${AGENT_CONFIG_HOME}|${agent_config_home}|g" \
        -e "s|\${DREAMING_HOME}|${DREAMING_HOME}|g" \
        "$template" > "$output"
}
