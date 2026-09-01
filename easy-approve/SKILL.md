---
name: easy-approve
description: >
  Triage a repository's open pull requests and separate the ones that are safe to approve now
  from the ones that need a real review, reproducing each candidate's bug and its fix — with unit
  tests when the PR ships them, and on a booted iOS simulator when the change is visible.
  Reports; never approves, comments or merges. Use when the user says things like "revisá el board",
  "easy approve", "which PRs can I approve", "triage the open PRs", or "/easy-approve".
argument-hint: '[pr numbers…] [--no-sim] [--repo owner/name]'
---

## What this does

Walks the open-PR board and answers one question per PR: **can this be approved right now, and what
is the evidence?** A PR earns "easy approve" only when its claimed bug was reproduced and its fix was
watched to fix it — not when CI is green and the diff reads fine.

**Hard rule: this skill never approves, never comments on a PR, never merges, never pushes.** It
produces a list and stops. Approving is the user's call and lands under their name; if they say
"approve these", that is a separate instruction they give after reading the report.

## Phase 0 — Preconditions

1. **The working tree must be clean.** Refuse to start otherwise: this skill checks out other
   people's code into the user's repo. `git status --short` must be empty.
2. **Record the starting branch** (`git rev-parse --abbrev-ref HEAD`). Phase 4 returns to it, whatever
   happens in between.
3. `git fetch origin <base>` — a stale local `develop` will silently invalidate every comparison. (A
   backport of a fix that "isn't on develop" is usually just a develop that is a few hours old.)
4. If the simulator will be used: confirm a booted device (`xcrun simctl list devices | grep Booted`)
   and that **Metro is running from this repo** (`lsof -i :8081`). Fast refresh follows the git tree,
   which is the whole trick in Phase 2. Without either, run with `--no-sim` and say so in the report.

## Phase 1 — Triage

```bash
python3 <skill-dir>/scripts/triage.py --me <github-user> --json board.json
```

It prints a table and buckets every open PR:

| bucket | meaning | what Phase 2 does with it |
| --- | --- | --- |
| `validatable` | app code, no native/deps, ≤150 lines changed | reproduce bug + fix |
| `zero-risk` | only `e2e/`, `scripts/`, docs — or a ≤2-file bot backport | read the diff, verify the claim, no reproduction |
| `needs-real-review` | big, native, or dependency-touching | list it, do not pretend to have validated it |

Read the flags it prints. `stacked on <branch>` means the PR's base is another PR — those merge in
stack order and are usually best validated once, at the tip. `drift` is `-behind/+ahead` against the
base branch; a branch tens of commits behind is the single most common reason a PR looks broken
locally when it is fine.

## Phase 2 — Validation

### The core recipe: apply onto base, don't check out the branch

Do **not** `git checkout <pr-branch>`. Branches are routinely 50–90 commits behind, and their tests
then run against today's `node_modules` and fail on dependencies that no longer exist — a failure
that says nothing about the PR. Instead, put the PR's diff on top of a fresh base:

```bash
git checkout -q origin/<base>
for f in $(gh pr view <N> --json files -q '.files[].path'); do
  git checkout origin/<head-branch> -- "$f"
done
```

Then **prove you reproduced the PR, not a mix of the PR and stale files** — a file the PR touches may
have moved on in the base since the branch forked:

```bash
git diff --cached --stat                    # what you applied
gh pr diff <N> | git apply --stat           # what the PR claims
```

If the two stats differ, restore the drifted files from the base and note it; the PR needs a merge
with the base before it can land either way.

### If the PR ships tests — reproduce the bug

Running the new test and watching it pass proves nothing on its own; it has to fail without the fix.

```bash
npx jest <test path> --modulePathIgnorePatterns "<rootDir>/.worktrees/"   # passes, with the fix
git checkout origin/<base> -- <production file(s)>                        # keep the test, drop the fix
npx jest <test path> --modulePathIgnorePatterns "<rootDir>/.worktrees/"   # must now fail
```

The `--modulePathIgnorePatterns` guard is not optional in a repo with `.worktrees/`: a worktree's
`__mocks__` wins the haste-map race and shadows the root ones, so tests fail locally and pass in CI.

For a refactor with no behaviour change, the equivalent evidence is the whole module's suite plus a
type-check on the applied tree — say which, and give the counts.

### If the change is visible — reproduce it on the simulator

Metro serves whatever is on disk, so the git tree *is* the toggle. No rebuild, no reinstall:

1. Navigate to the affected screen on the clean base tree and screenshot it — that is the BEFORE, and
   it must actually show the bug. If it doesn't, the PR's premise is unconfirmed; say that instead of
   inventing a repro.
2. Apply the PR's files (recipe above), wait ~10s for fast refresh, screenshot again.
3. Compare by cropping the region, not by eye:

```python
from PIL import Image
box = (x0, y0, x1, y1)
Image.open("before.png").crop(box)  # stack them into one image and look at it
```

Notes that cost time when forgotten:

- Fast refresh sometimes kills the app. Relaunch (`xcrun simctl launch <udid> <bundle-id>`) and
  navigate again — it is not evidence of a crash in the PR unless it reproduces on a clean launch.
- Reverting a layout fix often does **not** restore the broken layout, because the component's
  measured state is already correct. Capture BEFORE first, on the clean tree.
- **Check the instance's theme before declaring a colour change didn't apply.** Sample a primary
  button: on the `hu` QA instance `brand[500]` is grey `(79,79,79)`, so "brand-coloured" text looks
  like plain dark text and a brand-coloured keyline is invisible.
- Prefer `tapOn: point: "x%,y%"` when a text selector fails — card rows are single accessibility
  nodes and nested text often isn't tappable by its label.
- Screenshots go to the session scratchpad, never into the repo.

### Cheap cross-checks worth doing on every candidate

- Do the symbols and i18n keys the PR introduces already exist on the base? (A `weight="semiBold"`
  or a `t('some.new.key')` that resolves nowhere is a real defect the type-check won't catch.)
- Does a bot backport match what actually merged? Diff the touched lines against the base.
- For an `e2e/`-only PR: if it adds a nested flow that is *not* invoked from an already-registered
  root flow, it needs its own entry in `e2e/config.yml`.

### What you cannot validate

Say so, per PR, with the reason. Android-only fixes cannot be checked on an iOS simulator. A screen
whose data doesn't exist in the test instance cannot be reached. That belongs in the report — an
unvalidated PR listed as validated is worse than one listed as untested.

## Phase 3 — Report

Three sections, in this order, each PR carrying its evidence in one or two lines:

1. **Easy approve** — bug reproduced, fix verified. Say exactly how (which test flipped, what the
   before/after showed, which suites and counts ran).
2. **Approve with a note** — works, but with a caveat the reviewer should carry: only one of several
   surfaces exercised, branch far behind base, a design question the PR itself raised.
3. **Not easy** — needs QA, design sign-off, another platform, or simply a real read. One line on why.

Close by offering to approve them, and wait. Do not approve as part of this skill.

## Phase 4 — Cleanup

Always, including on failure:

```bash
git reset -q --hard && git checkout -q <starting branch>
git status --short   # must be empty
```

Leaving a colleague's half-applied diff in the user's working tree is the worst possible outcome of
a review pass.
