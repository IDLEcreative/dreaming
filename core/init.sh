#!/bin/bash
# dreaming init — first-run setup.
# Creates $DREAMING_HOME, optionally imports existing claude memory dirs.

set -uo pipefail

DREAMING_HOME="${DREAMING_HOME:-$HOME/.dreaming}"
CLAUDE_HOME="$HOME/.claude"

echo "dreaming init"
echo "  data root: $DREAMING_HOME"
echo ""

if [ -d "$DREAMING_HOME" ]; then
    echo "  $DREAMING_HOME exists — nothing to do"
    echo "  (delete it and rerun if you want a clean start)"
    exit 0
fi

mkdir -p "$DREAMING_HOME"/{projects,dream-logs/snapshots}
echo "  created $DREAMING_HOME/{projects,dream-logs}"

# If there's an existing Claude Code installation with memory dirs, offer to import.
if [ -d "$CLAUDE_HOME/projects" ] && [ -n "$(find "$CLAUDE_HOME/projects" -maxdepth 2 -name memory -type d -print -quit 2>/dev/null)" ]; then
    echo ""
    echo "  Detected existing Claude Code memory at $CLAUDE_HOME/projects/"
    echo "  Import options:"
    echo "    1) Symlink (recommended) — $DREAMING_HOME/projects → $CLAUDE_HOME/projects"
    echo "       Both Claude Code and dreaming see the same data. Zero migration cost."
    echo "    2) Copy — duplicate everything. Two copies, kept in sync by you."
    echo "    3) Skip — start fresh, ignore existing memory."
    echo ""
    echo "  Set DREAMING_INIT_MODE=symlink|copy|skip to choose non-interactively."
    mode="${DREAMING_INIT_MODE:-}"
    if [ -z "$mode" ]; then
        printf "  Choice [symlink/copy/skip]: "
        read -r mode
    fi
    case "$mode" in
        symlink)
            rm -rf "$DREAMING_HOME/projects"
            ln -s "$CLAUDE_HOME/projects" "$DREAMING_HOME/projects"
            echo "  ✓ symlinked $DREAMING_HOME/projects → $CLAUDE_HOME/projects"
            ;;
        copy)
            cp -R "$CLAUDE_HOME/projects/." "$DREAMING_HOME/projects/"
            echo "  ✓ copied $CLAUDE_HOME/projects/ → $DREAMING_HOME/projects/"
            ;;
        skip|*)
            echo "  ✓ left $DREAMING_HOME/projects empty (no import)"
            ;;
    esac
fi

echo ""
echo "Next steps:"
echo "  1. Choose an adapter:    dreaming adapters"
echo "  2. Smoke-test the loop:  DRY_RUN=1 dreaming dream"
echo "  3. Run for real:         dreaming dream"
echo "  4. (Optional) Cron:      see launchd/ or systemd/ templates"
