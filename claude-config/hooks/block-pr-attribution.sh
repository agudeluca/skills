#!/bin/bash
# Blocks gh pr create/edit/comment (and gh api PR edits) whose body carries Claude attribution.
input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
# Only when gh is invoked as a command (line start, after ; & | ( or $( ), not when quoted in text
printf '%s' "$cmd" | grep -qE '(^|[;&|(])[[:space:]]*gh (pr (create|edit|comment)|api)( |$)' || exit 0
text="$cmd"
# Include the contents of any --body-file / -F file referenced by the command
for f in $(printf '%s' "$cmd" | grep -oE '(--body-file|-F)[= ]+[^ ]+' | sed -E 's/^(--body-file|-F)[= ]+//; s/^["'\'']//; s/["'\'']$//'); do
  [ -f "$f" ] && text="$text$(cat "$f")"
done
if printf '%s' "$text" | grep -qE 'Generated with \[?Claude Code|claude\.ai/code/session_'; then
  echo "Blocked: PR body contains Claude attribution ('Generated with Claude Code' footer or claude.ai/code/session_ link). Remove it and retry — the user's CLAUDE.md forbids it." >&2
  exit 2
fi
exit 0
