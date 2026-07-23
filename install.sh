#!/usr/bin/env bash
# Symlink every skill in this repo into a Claude Code skills directory.
#
#   ./install.sh                       -> ~/.claude/skills
#   ./install.sh --project /path/repo  -> /path/repo/.claude/skills
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${HOME}/.claude/skills"

if [ "${1:-}" = "--project" ]; then
    [ -n "${2:-}" ] || { echo "--project needs a path" >&2; exit 1; }
    DEST="$2/.claude/skills"
fi

mkdir -p "$DEST"

for skill in "$SRC"/*/; do
    name="$(basename "$skill")"
    [ -f "$skill/SKILL.md" ] || continue
    ln -sfn "${skill%/}" "$DEST/$name"
    echo "linked $name -> $DEST/$name"
done

echo
echo "Done. Restart Claude Code (or /doctor) to pick up new skills."
