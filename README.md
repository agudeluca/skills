# skills

Personal Claude Code skills.

| skill | what it does |
| --- | --- |
| [`easy-approve`](easy-approve/) | Triages a repo's open PRs into *easy approve* / *approve with a note* / *needs a real review*, reproducing each candidate's bug and fix — unit tests when the PR ships them, iOS simulator when the change is visible. Reports only; never approves. |

## Using them

Skills are picked up from `~/.claude/skills/`. Symlink instead of copying, so edits here are live:

```bash
ln -s ~/projects/skills/easy-approve ~/.claude/skills/easy-approve
```
