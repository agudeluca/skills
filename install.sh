#!/bin/bash
# Wire this repo into both Claude config dirs (clauder -> ~/.claude, claudepr -> ~/.claude-personal).
# Skills and CLAUDE.md are symlinked so edits here are live; settings are copied only when missing,
# since Claude rewrites settings.json itself.
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
SKILLS=(active brainstorming clean-worktrees easy-approve engage parallel)

for cfg in "$HOME/.claude" "$HOME/.claude-personal"; do
  mkdir -p "$cfg/skills"
  for skill in "${SKILLS[@]}"; do
    rm -rf "${cfg:?}/skills/$skill"
    ln -sfn "$REPO/$skill" "$cfg/skills/$skill"
  done
  ln -sfn "$REPO/claude-config/CLAUDE.md" "$cfg/CLAUDE.md"
done

[ -e "$HOME/.claude/settings.json" ] || cp "$REPO/claude-config/settings.work.json" "$HOME/.claude/settings.json"
[ -e "$HOME/.claude/settings.local.json" ] || cp "$REPO/claude-config/settings.work.local.json" "$HOME/.claude/settings.local.json"
[ -e "$HOME/.claude-personal/settings.json" ] || cp "$REPO/claude-config/settings.personal.json" "$HOME/.claude-personal/settings.json"

# Separate repo.
[ -d "$HOME/.claude/skills/parallel-plan" ] || git clone git@github.com:agudeluca/parallel-plan-skill.git "$HOME/.claude/skills/parallel-plan"

echo "Done. Third-party skills (skills.sh), install separately:"
echo "  npx skills add margelo/react-native-skills        # api-design, build-nitro-modules, kotlin, swift"
echo "  npx skills add callstackincubator/react-native-harness"
echo "  npx skills add mattpocock/skills --skill grill-me"
echo "  npx skills add vercel-labs/skills --skill find-skills"
