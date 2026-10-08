# pr-follow — design

A monitor over every open pull request authored by the git user the machine is authenticated
as. It follows up on new comments from anyone, new reviews, and CI going red or green:
mechanical work it fixes and pushes itself, logic it prepares and hands back, and anything
from a non-collaborator it only reports.

## Why this shape

The request was a closed loop — comment from anyone → local review → code change → push,
unattended, every five minutes. Taken literally that hands anyone who can comment on a PR
the ability to cause code to be written and pushed, and six of the eight live PRs are in
work repos (`HumandDev`, `iPlayMe2`, `frequency-invest`). The loop is worth building; the
authority it runs on has to be narrower than "whoever commented".

Two separations carry the design:

**Detecting is cheap, acting is expensive.** Checking eight PRs is one API call. Fixing one
needs a working copy, and the `humand-mobile` checkout is 27 GB. So detection never checks
anything out, and a working copy is materialised only for the PR actually being acted on.

**Reading is not authorisation.** Every comment is read and reported, whoever wrote it.
Only a collaborator's comment can cause a change, and no comment at all can cause a command
to run. A comment is a change request about the diff, never an instruction to the machine.

## Components

| file | job |
| --- | --- |
| `pr-follow/SKILL.md` | the workflow: triage, tiers, acting procedure, never-list |
| `pr-follow/scripts/poll.py` | detection. One GraphQL call, silent when nothing changed |
| `pr-follow/scripts/trust.sh` | authoritative permission check, run only before a push |
| `pr-follow/scripts/act.sh` | checkout discipline and the push refusals |

Judgment lives in `SKILL.md`, not in the scripts. The scripts answer closed questions —
*what changed*, *may this person direct a change*, *is this checkout safe to touch* — and
refuse rather than improvise. Classifying a comment needs to read the comment, and that is
the model's job.

### Detection

One GraphQL query returns every open PR with its comments, review threads, reviews and
check rollup: one call per tick instead of ~40 REST calls, and it leaves plenty of room
under the 5000/hour budget at a 5-minute cadence.

An event is a **transition**, not a state: `CI_FAIL` fires when checks go from not-failing
to failing, so the same red build is not re-reported every five minutes.

State at `$XDG_STATE_HOME/pr-follow/state.json` records seen comment ids, CI state and head
sha per PR, written through a temp file so a crash cannot truncate it. Closed PRs are
dropped so it does not grow forever.

Three properties worth stating, because each prevents a specific failure:

- **Baselining.** A PR seen for the first time has its existing comments recorded as seen
  and emits nothing. Without this, starting the monitor would replay months of old review
  comments and act on them.
- **Self-ignore.** Every comment the skill posts carries `<!-- pr-follow -->`, and the
  poller skips any comment containing it. Since it comments as the user's own account, its
  own output would otherwise look exactly like a trusted instruction — forever.
- **Archived repos are included, not filtered.** An earlier `archived:false` in the query
  silently dropped a live PR. A monitor that hides a PR is broken, so archived repos are
  reported and flagged read-only instead.

### Trust

`authorAssociation` comes free in the detection query and is enough to triage. The
permission endpoint is then asked directly before anything is pushed, so a stale or
generous association is never the only thing between a drive-by comment and a commit.

`admin`, `maintain` and `write` are trusted. **`read` is not**: a public repo grants `read`
to every GitHub account that exists — verified against this repo, where an unrelated account
resolves to `read`. Bots are never a source of instructions, though their failures are
facts worth acting on.

### Tiers

- **A — fix, commit, push, comment.** Trusted author, change confined to files the PR
  already touches, ≤5 files and ≤100 lines, and one of: formatter/linter autofix, a typo the
  reviewer quoted verbatim, an exact rename with both names given, deleting a file flagged as
  committed by mistake, or a CI rerun for an infrastructure failure with no code change.
- **B — fix locally, commit, do not push.** Logic, control flow, test assertions, dependency
  versions, a real test failure, an ambiguous comment, or anything past the Tier A caps.
- **C — report only.** Untrusted author, architectural or scope asks, sensitive paths
  (`.github/workflows/**`, CI config, `fastlane/`, keystores, auth, crypto, payments,
  `Dangerfile`), archived repos, diverged branches, dirty working trees.

The caps are deliberately arbitrary. They are a ceiling on blast radius, not a measure of
correctness, and they can move once the thing has run for a while.

### Acting

The existing clone is reused rather than a fresh worktree, because a worktree per PR means
a dependency install per PR — minutes and gigabytes on the mobile repos. The cost is that
the user's checkout is borrowed, so: refuse on a dirty tree, record the branch, always
restore it even when the fix fails.

`act.sh push` refuses a protected branch, a detached HEAD, a missing upstream, and any
commit touching `.github/workflows/**`. All six refusals are covered by throwaway-repo
tests. One of them exists because the first implementation was wrong: `default_branch()`
returned empty when `origin/HEAD` was unset, because `cmd | sed || echo main` takes the
pipeline's exit status, and an empty answer disarmed the check that depended on it. It now
returns a set that always contains `main` and `master`, so the failure mode is
over-refusing.

## Rejected

**A full agent pass every 5 minutes** (`/loop 5m`) needs no state file, since each pass sees
everything. It also burns 288 passes a day to discover that nothing happened.

**Webhooks** would be real-time with no polling, but need a tunnel and repo admin, which
the user does not have on the `HumandDev` repos.

**A worktree per PR** never borrows the user's checkout, but pays a full dependency install
per PR. Rejected on cost; a 27 GB worktree had just been deleted from this machine.

## Verification

First pass is `--once --dry-run` against the real board: it shows the events it sees and the
tier it would assign, without touching anything. Detection was tested by removing an id from
the state file and confirming the event reappears, and by forcing a CI state to prove
`CI_RECOVER` fires. The push refusals were tested in throwaway repos.
