# skills

Personal Claude Code skills.

| skill | what it does |
| --- | --- |
| [`easy-approve`](easy-approve/) | Walks a repo's **whole** open-PR board and gives every PR a status with its evidence. Retires the parked / conflicting / already-approved ones on state before reading any code, then reproduces each remaining candidate's bug and fix — unit tests when the PR ships them, `npm pack` + changelog for dependency bumps, iOS simulator when the change is visible. Reconciles its sections against the board count, so no PR goes unmentioned. Leaves one before/after evidence comment on each PR it reproduced on the simulator (`scripts/post_evidence.sh`, edited in place on re-runs); never approves. |
| [`clean-worktrees`](clean-worktrees/) | Finds every git worktree in every repo under `~/projects`, classifies each as clean / unpushed / dirty / locked / gone, and removes only the ones whose contents exist somewhere else — after confirmation. Never force-removes, never deletes unmerged branches. |
| [`parallel`](parallel/) | Max mode, two flavours. **build**: decomposes a task into sub-plans that provably cannot collide, implements each in its own agent, and has a *different* agent re-run the acceptance criteria. **research**: sweeps a question from independent angles, then makes 2 agents per finding try to refute it — unanimous survival or it is cut — and a critic name what the sweep missed. Prints the projected agent count before launching. Never commits; research never writes at all. |

## Using them

Two config dirs are in play — the shell aliases pick which one Claude reads:

| alias | `CLAUDE_CONFIG_DIR` |
| --- | --- |
| `clauder` | `~/.claude` |
| `claudepr` | `~/.claude-personal` |

A skill only exists for the alias whose `skills/` directory contains it, so install into **both**.
`install.sh` symlinks every skill here (and `claude-config/CLAUDE.md`) into both config dirs, so edits
here are live, and seeds `settings.json` from `claude-config/` where none exists yet:

```bash
./install.sh
```

Skills are read at startup — a new symlink shows up in the next session, not the running one.

## Also here

| path | what it is |
| --- | --- |
| [`active`](active/) | Keeps the user shown as online by jiggling the mouse 1px via `cliclick`. |
| [`engage`](engage/) | Retries commands that failed on the network (never real failures, never money-moving calls) and watches the connection. |
| [`brainstorming`](brainstorming/) | Local fork of [obra/superpowers](https://github.com/obra/superpowers)' brainstorming skill (MIT). |
| [`claude-config/CLAUDE.md`](claude-config/CLAUDE.md) | Global rules shared by both aliases ("fixeame el git", worktree policy, "clean metros"). |
| `claude-config/settings.*.json` | `settings.json` for each alias, as a starting point on a new machine. |

Installed from elsewhere, not copied here: `parallel-plan` ([agudeluca/parallel-plan-skill](https://github.com/agudeluca/parallel-plan-skill)),
and skills.sh packages listed at the end of `install.sh`.
