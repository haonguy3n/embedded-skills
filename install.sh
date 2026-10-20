#!/usr/bin/env bash
# Symlink every skill in this repo, and the team-lead agents, into a Claude Code directory.
#
#   ./install.sh                       -> ~/.claude/{skills,agents,team-lead.md}
#   ./install.sh --project /path/repo  -> /path/repo/.claude/{skills,agents,team-lead.md}
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="${HOME}/.claude"
IMPORT="@~/.claude/team-lead.md"

if [ "${1:-}" = "--project" ]; then
    [ -n "${2:-}" ] || { echo "--project needs a path" >&2; exit 1; }
    BASE="$2/.claude"
    IMPORT="@.claude/team-lead.md"
fi

# Link $1 at $2, but never replace a real file or folder someone made there.
link() {
    if [ -e "$2" ] && [ ! -L "$2" ]; then
        echo "skipped $2: a file that is not our link is there" >&2
        return
    fi
    ln -sfn "$1" "$2"
    echo "linked $(basename "$2") -> $2"
}

mkdir -p "$BASE/skills" "$BASE/agents"

for skill in "$SRC"/*/; do
    name="$(basename "$skill")"
    [ -f "$skill/SKILL.md" ] || continue
    link "${skill%/}" "$BASE/skills/$name"
done

for agent in "$SRC"/team-lead/agents/*.md; do
    link "$agent" "$BASE/agents/$(basename "$agent")"
done

link "$SRC/team-lead/TEAM-LEAD.md" "$BASE/team-lead.md"

echo
echo "Done. Restart Claude Code (or /doctor) to pick up new skills and agents."
echo "To turn the team-lead protocol on, add this line to the CLAUDE.md that should use it:"
echo "  $IMPORT"
