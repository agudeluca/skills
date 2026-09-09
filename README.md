# skills

Personal Claude Code skills.

| skill | what it does |
| --- | --- |
| [`easy-approve`](easy-approve/) | Triages a repo's open PRs into *easy approve* / *approve with a note* / *needs a real review*, reproducing each candidate's bug and fix — unit tests when the PR ships them, iOS simulator when the change is visible. Reports only; never approves. |
| [`clean-worktrees`](clean-worktrees/) | Finds every git worktree in every repo under `~/projects`, classifies each as clean / unpushed / dirty / locked / gone, and removes only the ones whose contents exist somewhere else — after confirmation. Never force-removes, never deletes unmerged branches. |
| [`parallel`](parallel/) | Max mode. Decomposes a task into sub-plans that provably cannot collide, then runs them concurrently through the `Workflow` tool — one agent implementing each, an independent agent trying to prove it wrong, one repair attempt — and converges with the full suite over the integrated tree. Never commits or pushes. |

## Using them

Two config dirs are in play — the shell aliases pick which one Claude reads:

| alias | `CLAUDE_CONFIG_DIR` |
| --- | --- |
| `clauder` | `~/.claude` |
| `claudepr` | `~/.claude-personal` |

A skill only exists for the alias whose `skills/` directory contains it, so install into **both**.
Symlink instead of copying, so edits here are live:

```bash
for cfg in ~/.claude ~/.claude-personal; do
  for skill in easy-approve clean-worktrees parallel; do
    ln -sfn ~/projects/skills/"$skill" "$cfg"/skills/"$skill"
  done
done
```

Skills are read at startup — a new symlink shows up in the next session, not the running one.
