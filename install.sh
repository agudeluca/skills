#!/bin/bash
# Wire this repo into both Claude config dirs (clauder -> ~/.claude, claudepr -> ~/.claude-personal).
# Skills and CLAUDE.md are symlinked so edits here are live; settings are copied only when missing,
# since Claude rewrites settings.json itself, and agent-registry's hooks are then merged into them.
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
SKILLS=(agent-registry brainstorming clean-worktrees easy-approve engage parallel stock-review)

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

# agent-registry needs three hooks in each live settings.json. They are merged rather than copied,
# because on this machine those files already exist and Claude rewrites them itself: each hook is
# added only when its exact command is absent, every other key and any foreign hook is left alone,
# and the file is replaced through a temp file so a crash mid-write cannot truncate it. Re-running
# this is a no-op. It runs after the templates above are seeded, so a fresh machine gets the hooks
# in the same pass rather than needing a second run.
REGISTRY="$REPO/agent-registry/scripts/registry.sh"
merge_registry_hooks() {
  local settings="$1"
  [ -e "$settings" ] || return 0
  command -v jq >/dev/null 2>&1 || { echo "  ! jq not found, skipping hooks in $settings"; return 0; }
  cp "$settings" "$settings.bak"
  if jq --arg sh "$REGISTRY" '
        def ensure($event; $cmd; $extra):
          .hooks[$event] = ((.hooks[$event] // [])
            | if any(.[]?.hooks[]?; .command == $cmd) then .
              else . + [ { matcher: "", hooks: [ ({ type: "command", command: $cmd } + $extra) ] } ] end);
          ensure("SessionStart"; ($sh + " start"); { timeout: 10 })
        | ensure("Stop";         ($sh + " touch"); { timeout: 5, async: true })
        | ensure("SessionEnd";   ($sh + " end");   { timeout: 1 })
      ' "$settings" > "$settings.tmp" 2>/dev/null; then
    mv -f "$settings.tmp" "$settings"
    echo "  hooks ok: $settings  (backup at $settings.bak)"
  else
    rm -f "$settings.tmp"
    echo "  ! could not merge hooks into $settings, left untouched"
  fi
}
merge_registry_hooks "$HOME/.claude/settings.json"
merge_registry_hooks "$HOME/.claude-personal/settings.json"

# `agents` on PATH, for reading the registry from a terminal.
mkdir -p "$HOME/.local/bin"
ln -sfn "$REGISTRY" "$HOME/.local/bin/agents"

# Separate repo.
[ -d "$HOME/.claude/skills/parallel-plan" ] || git clone git@github.com:agudeluca/parallel-plan-skill.git "$HOME/.claude/skills/parallel-plan"

echo "Done. \`agents\` lists every Claude session on this machine (new hooks apply to the NEXT session)."
echo "Third-party skills (skills.sh), install separately:"
echo "  npx skills add margelo/react-native-skills        # api-design, build-nitro-modules, kotlin, swift"
echo "  npx skills add callstackincubator/react-native-harness"
echo "  npx skills add mattpocock/skills --skill grill-me"
echo "  npx skills add vercel-labs/skills --skill find-skills"
