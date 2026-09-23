---
name: easy-approve
description: >
  Walk every open pull request on a repository's board and give each one a status with its
  evidence, separating the ones safe to approve now from the ones that need a real review.
  Reproduces each candidate's bug and its fix — with unit tests when the PR ships them, a local
  run wherever one is possible, and a booted iOS simulator when the change is visible.
  Reports, and leaves one before/after evidence comment on each PR it reproduced on the simulator;
  never approves or merges. Use when the user says things like "revisá el board", "easy approve",
  "which PRs can I approve", "triage the open PRs", or "/easy-approve".
argument-hint: '[pr numbers…] [--no-sim] [--repo owner/name]'
---

## What this does

Walks the open-PR board and answers one question per PR: **can this be approved right now, and what
is the evidence?** A PR earns "easy approve" only when its claimed bug was reproduced and its fix was
watched to fix it — not when CI is green and the diff reads fine.

**Every open PR gets its own line in the report.** Not a bucket summarised in aggregate, not "the
other 29 need a real read" — each one, with the specific reason it landed where it did. A bucket is
the skill's guess at how much work a PR needs; it is never a substitute for saying something about
that PR. The report reconciles against the board count, so nothing can quietly go missing.

**Hard rule: this skill never approves, never merges, never pushes.** It produces a list and stops.
Approving is the user's call and lands under their name; if they say "approve these", that is a
separate instruction they give after reading the report.

**The one thing it does write to a PR is evidence.** A PR whose change was reproduced on the
simulator gets exactly one comment: the before/after pair, what to look at, and one line on what the
pair proves (Phase 3). Nothing else is ever posted — no verdicts, no "LGTM", no review requests, no
comment on a PR that was validated by tests alone or not validated at all. Re-running the skill
updates that comment in place; it never adds a second one.

## Phase 0 — Preconditions

1. **The working tree must be clean.** Refuse to start otherwise: this skill checks out other
   people's code into the user's repo. `git status --short` must be empty.
2. **Record the starting branch** (`git rev-parse --abbrev-ref HEAD`). Phase 5 returns to it, whatever
   happens in between.
3. `git fetch origin <base>` — a stale local `develop` will silently invalidate every comparison. (A
   backport of a fix that "isn't on develop" is usually just a develop that is a few hours old.)
4. If the simulator will be used: confirm a booted device (`xcrun simctl list devices | grep Booted`)
   and that **Metro is serving this checkout** — not just that something holds port 8081:

   ```bash
   for PID in $(lsof -ti :8081); do
     echo "$PID -> $(lsof -a -p "$PID" -d cwd -Fn | sed -n 's/^n//p')"
   done
   ```

   Loop over the PIDs — port 8081 routinely has more than one (Metro plus a
   helper whose cwd is `/`), so a bare `lsof -p "$(lsof -ti :8081)"` is handed two
   PIDs at once and silently reports nothing useful.

   A Metro started from a **worktree** answers on the same port and looks identical, but fast
   refresh then follows *that* tree, so every file you apply in the main checkout is invisible to
   the running app and the before/after shots are of the wrong code. If the cwd is not this repo,
   either run with `--no-sim` and say so in the report, or ask the user before restarting Metro —
   a worktree with unpushed commits is somebody's live session, and that is their call, not yours.

## Phase 1 — Triage

```bash
python3 <skill-dir>/scripts/triage.py --me <github-user> --json board.json
```

It prints a table and buckets every open PR, then a count line the report must reconcile against:

| bucket | meaning | what Phase 2 does with it |
| --- | --- | --- |
| `blocked` | reading the diff cannot change what happens next | name the state, do not review the code |
| `validatable` | app code, no native/deps, ≤150 lines changed | reproduce bug + fix |
| `zero-risk` | only `e2e/`, `scripts/`, docs — or a ≤2-file bot backport | read the diff, verify the claim, no reproduction |
| `needs-real-review` | big, native, or dependency-touching | read it enough to say *why*, per PR |

**The state gate runs first, and it is the highest-yield step in the skill.** On a real board a
large share of what looks like a review backlog is nothing of the kind: a PR carrying an `On Hold`
label, one that conflicts with its base, one whose author owes an answer to a rejection, one already
approved by you, one whose diff is empty because it already merged. Every minute spent reading those
diffs is a minute not spent on a PR that could actually be approved. `blocked_reason()` retires them
before size or paths are consulted at all.

`mergeable: UNKNOWN` is the trap inside that gate. It does not mean "merges fine" — it means GitHub
has not computed it yet, and the act of asking starts the computation. The script therefore asks a
second time for exactly those PRs; treating the first answer as final hides PRs that cannot merge at
all behind a bucket that says "go read this".

Read the flags it prints. `stacked on <branch>` means the PR's base is another PR — those merge in
stack order and are usually best validated once, at the tip. `drift` is `-behind/+ahead` against the
base branch; a branch tens of commits behind is the single most common reason a PR looks broken
locally when it is fine. `updated` is the last activity date: a PR untouched for weeks is a fact
about the PR, and is usually how an empty or abandoned one gives itself away.

## Phase 2 — Validation

### How deep to go, per PR

Every PR gets **at least tier 1**. The tiers bound the cost of "one by one" — they are not
permission to skip anyone.

| tier | who gets it | what it costs |
| --- | --- | --- |
| 0 | `blocked` | seconds — name the state, move on |
| 1 | **everyone else, without exception** | read the PR body and `--stat`; for anything you can hold in your head, read the diff. The deliverable is one specific sentence about *this* PR |
| 2 | `validatable`, `zero-risk`, and any `needs-real-review` that turns out to be tractable | the apply-onto-base recipe, plus a local run: the test reproduction, the module suite, a type-check |
| 3 | tier 2 PRs whose change is visible | the simulator |

A tier-1 line has to be about the PR in front of you. "Too big to review" is not a finding —
*"+9370 across 112 files bumping the Stream SDKs; needs calls QA on both platforms"* is. If a PR is
genuinely unreadable at tier 1, the line says what it would take to review it and who should.

**Promote freely.** The bucket is a heuristic over size and paths, and it is wrong in the useful
direction often enough to check: a `deps` PR is bucketed `needs-real-review` for touching
`yarn.lock`, and can still be fully validated in ten minutes (see below). When a tier-1 read shows a
PR is tractable, validate it and say so.

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
3. Compare by cropping the region, not by eye — and keep the crops, they are what gets posted:

```python
from PIL import Image
box = (x0, y0, x1, y1)                       # same box for both, or the pair proves nothing
for name in ("before", "after"):
    Image.open(f"{name}.png").crop(box).save(f"{name}-crop.png")
```

**The evidence pack.** Each PR that reaches this step leaves these in `<scratchpad>/<N>/`, and
Phase 3 posts from them; a PR missing any of the five gets no comment:

| file / field | what it is |
| --- | --- |
| `before.png`, `after.png` | full screenshots, base tree and applied tree, same screen and state |
| `before-crop.png`, `after-crop.png` | the same `box` out of each — the pair a reader compares |
| caption | one sentence: which region, what changes in it |
| evidence | one sentence: what the pair proves, and what it does not (surfaces not exercised) |
| base | the `origin/<base>` sha the BEFORE was taken on |

Crop to the region under test. Full screenshots carry names, avatars and instance data from the test
account; the crop is what a reader needs, and it is what goes on a PR everyone with repo access can
see. When the region itself shows a real person's data, mask it before saving the crop.

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

### If the PR bumps a dependency — read the changelog, don't shrug

A version bump is bucketed `needs-real-review` because it touches `yarn.lock`, but it is one of the
most validatable things on the board, and CI is close to worthless on it: Jest runs under Node, so a
green suite says nothing about how the package behaves inside Metro's bundle on a device.

```bash
npm view <pkg>@<new> peerDependencies dependencies      # a peer bump is a hard break
cd <scratchpad> && npm pack <pkg>@<new> --silent && tar xzf <pkg>-<new>.tgz
curl -sL https://cdn.jsdelivr.net/npm/<pkg>@<new>/CHANGELOG.md   # entries BETWEEN old and new
```

Then, for each breaking change the changelog lists, answer one question: **does this app's usage hit
it?** Find the call site and check. That turns "major bump, scary" into a specific yes or no.

Two traps worth naming, because both pass CI:

- **Top-level await.** A package that adds TLA breaks the Metro bundle while working fine in Jest.
  Grep the published build (`grep -nE '^\s*await |^\s*(const|let|var)\s+\w+\s*=\s*await ' package/esm/*.js`)
  rather than trusting a changelog line, which may describe a version since fixed.
- **React Native already has the globals.** A new `cross-fetch`-style dependency is often reached
  only when `global.fetch` / `global.XMLHttpRequest` are missing — which on RN they are not. Read
  the resolution logic before counting it as new surface.

Also say whether the bump is *worth taking*: a release that closes a GHSA advisory is a reason to
prioritise it, and belongs in the report next to the risk.

### Cheap cross-checks worth doing on every candidate

- Do the symbols and i18n keys the PR introduces already exist on the base? (A `weight="semiBold"`
  or a `t('some.new.key')` that resolves nowhere is a real defect the type-check won't catch.)
- Does a bot backport match what actually merged? Diff the touched lines against the base.
- For an `e2e/`-only PR: if it adds a nested flow that is *not* invoked from an already-registered
  root flow, it needs its own entry in `e2e/config.yml`.
- **Did a repo rule land after the PR did?** Compare the PR's `updated` date against the base's
  `CLAUDE.md`:

  ```bash
  git log --format='%h %ad %s' --date=short -S '<rule phrase>' -- CLAUDE.md
  ```

  A requirement added last week is still binding on a PR opened the week before, but it is policy
  drift rather than author error — say which, so the note reads as "this is now owed" and not "you
  got this wrong".
- **Does the PR delete something that was added deliberately?** Run `git log -S` on the removed
  lines. A guard introduced by a security or incident fix a few weeks ago is not dead code, and
  removing it needs that owner's sign-off however sound the diff looks.
- **Is this PR part of a cluster?** When several open PRs touch the same subsystem — a startup path,
  one module's store — reviewing them one at a time understates the combined risk. Say they should
  be read as a set, and name them.

### What you cannot validate

Say so, per PR, with the reason. Android-only fixes cannot be checked on an iOS simulator. A screen
whose data doesn't exist in the test instance cannot be reached. That belongs in the report — an
unvalidated PR listed as validated is worse than one listed as untested.

## Phase 3 — Post the evidence

For every PR with a complete evidence pack, and only those:

```bash
<skill-dir>/scripts/post_evidence.sh <owner/repo> <N> \
  <scratchpad>/<N>/before-crop.png <scratchpad>/<N>/after-crop.png \
  --caption "<caption>" --evidence "<evidence>" --base <sha> --device "<simulator, instance>"
```

The script uploads both crops with the `gh` user token (no browser, no session; the assets inherit
the repo's visibility and never enter a commit), writes the comment as a side-by-side
`Before | After` table with the caption and the evidence line, and prints the comment URL. It looks
for its own hidden marker first: if this skill already commented on that PR, the comment is edited
in place. Run it with `--dry-run` first when the caption or evidence text is in doubt — it prints
the body and touches nothing.

What the comment must not become: a verdict. It says what was seen, not whether to approve.
The verdict lives in the report, for the user, and in whatever they choose to post afterwards.

Keep each comment URL — the report links it.

## Phase 4 — Report

Four sections, in this order, each PR carrying its evidence in one or two lines:

1. **Easy approve** — bug reproduced, fix verified. Say exactly how (which test flipped, what the
   before/after showed, which suites and counts ran). A PR with a posted evidence comment links it.
2. **Approve with a note** — works, but with a caveat the reviewer should carry: only one of several
   surfaces exercised, branch far behind base, a design question the PR itself raised, a merge-order
   dependency on another repo.
3. **Blocked on state** — parked, conflicting, rejected, already approved, empty. A table is the
   right shape here: number, reason, and whose move it is. These need an author, a rebase or a
   label — never a reviewer.
4. **Needs a real read** — one line *per PR*, naming what specifically makes it hard and what it
   would take: which platform's QA, whose design sign-off, which data the test instance lacks.

**Reconcile the count.** End with the arithmetic against the board total the script printed —
`39 open: 1 easy · 5 with a note · 16 blocked · 17 need a read`. If the sections do not add up, a PR
was dropped, and dropping one silently is the failure this skill exists to avoid. A reader must be
able to look up any open PR number and find what you said about it.

**Report the gaps as gaps.** A PR validated only on source, with no local run or simulator pass, is
not "verified" — say which evidence you have and which you do not. An unvalidated PR listed as
validated is worse than one listed as untested.

Close by offering to approve them, and wait. Do not approve as part of this skill.

## Phase 5 — Cleanup

Always, including on failure:

```bash
git reset -q --hard && git checkout -q <starting branch>
git status --short   # must be empty
```

Leaving a colleague's half-applied diff in the user's working tree is the worst possible outcome of
a review pass.
