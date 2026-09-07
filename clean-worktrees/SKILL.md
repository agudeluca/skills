---
name: clean-worktrees
description: >
  Find every git worktree in every repository under ~/projects (or the directories given), classify
  each one by how safe it is to delete — clean and pushed, unpushed commits, uncommitted changes,
  locked, or already gone — and remove the safe ones after the user confirms. Never deletes work
  that exists nowhere else. Use when the user says things like "clean worktrees", "limpiá los
  worktrees", "limpiar worktrees", "clean all worktrees", "worktrees sucios", "borrá los worktrees",
  or "/clean-worktrees".
argument-hint: '[dir…] [--yes] [--branches] [--fetch]'
---

## What this does

Walks every git repository it can find, lists their **linked worktrees** (never the main checkout),
and answers one question per worktree: **does anything in here exist nowhere else?** Only worktrees
where the answer is a confident *no* get removed by default. Everything else is shown to the user
with the reason it was kept.

**Hard rules**

- Never run `git worktree remove --force`, `git branch -D`, or `rm -rf` on a worktree unless the user
  names that specific worktree and confirms after seeing what is in it.
- Never remove the worktree the current session is running in (`pwd`).
- Never delete a branch that is not fully merged (`git branch -d` only; it refuses on its own).
- Never `git push`, `git stash`, `git commit`, or checkout anything. This skill only deletes copies.

Respond in the language the user is using.

## Arguments

| argument | effect |
| --- | --- |
| `dir…` | roots to scan instead of `~/projects`. Several may be given. |
| `--yes` | skip the confirmation for CLEAN and PRUNABLE worktrees. Never extends to DIRTY, UNPUSHED or LOCKED. |
| `--branches` | after removing a CLEAN worktree, also `git branch -d` its branch (refuses if unmerged; report and move on). |
| `--fetch` | run `git fetch --all --prune` in each repo before classifying, so "ahead of upstream" counts are exact. Off by default because it hits the network once per repo. |

## Step 1 — Inventory

```bash
bash <skill-dir>/scripts/scan.sh [dir…]
```

It is read-only and prints one TSV line per linked worktree: `repo  worktree  branch  status  detail`.
Present it as a table grouped by repo, with the legend:

| status | meaning | default action |
| --- | --- | --- |
| 🟢 `CLEAN` | no local changes; every commit is on the remote or already in the default branch | remove |
| ⚫ `PRUNABLE` | git still lists it but the directory is gone | `git worktree prune` |
| 🟡 `UNPUSHED` | no local changes, but commits that exist nowhere else | keep; show the count |
| 🔴 `DIRTY` | uncommitted or untracked files | keep; show the file count |
| 🔒 `LOCKED` | `git worktree lock` is set | keep; mention `git worktree unlock` |

If the scan finds no linked worktrees at all, say so and stop — there is nothing to clean.

If `--fetch` was passed, run `git -C <repo> fetch --all --prune` for each repo **before** the scan
(fetching is safe; it only updates remote-tracking refs).

## Step 2 — Propose

State exactly what will happen, per worktree, before doing anything:

- CLEAN → `git -C <repo> worktree remove <path>`
- PRUNABLE → `git -C <repo> worktree prune`
- everything else → kept, with the reason from the `detail` column

Then confirm with a structured prompt (AskUserQuestion) that lists the removal set. `--yes` skips
this prompt for CLEAN and PRUNABLE only.

If the user asks to also remove a DIRTY or UNPUSHED worktree, first show them what they would lose
(`git -C <wt> status --short` for DIRTY; `git -C <wt> log --oneline <upstream-or-base>..HEAD` for
UNPUSHED), then ask again naming that worktree. Only then use `git worktree remove --force`.

## Step 3 — Execute

Run the commands one worktree at a time so a failure in one does not hide the rest. `git worktree
remove` without `--force` refuses if anything changed since the scan — treat that as a kept
worktree, not an error to work around.

After the removals in a repo:

1. `git -C <repo> worktree prune` — clears any leftover registration.
2. If `<repo>/.worktrees/` exists and is now empty, `rmdir` it (this is the layout the user's
   CLAUDE.md prescribes for worktrees, so an empty one is just litter).
3. With `--branches`: `git -C <repo> branch -d <branch>` for each removed CLEAN worktree. If git
   refuses (unmerged), report the branch name and leave it.

## Step 4 — Report

One line per worktree: what happened (`removed`, `pruned`, `kept — 3 unpushed commits`,
`kept — 12 dirty files`, `kept — locked`, `branch deleted`, `branch kept — unmerged`). End with the
totals and the disk space freed if it is easy to get (`du -sh` before removal).

## Edge cases

- **The scan is slow.** It runs `git status` in every worktree; big repos take a few seconds each.
  Say what it is doing rather than going quiet.
- **A repo has no `origin`.** Branches without an upstream and without a default branch to compare
  against are reported as UNPUSHED with that reason. Do not guess.
- **Nested repos.** A repo inside another repo is scanned on its own. Submodules are not (their
  `.git` is a file, so the scan never sees them as main repos).
- **Worktree outside the repo.** `git worktree list` knows about them wherever they live, including
  `/tmp`; they are handled like any other.
