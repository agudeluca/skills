---
name: parallel
description: >
  Max mode: decompose a task into independent sub-plans and actually execute them in parallel with a
  fan-out of subagents, verifying each one adversarially before calling it done. Plans, runs, verifies
  and converges — it does not just plan. Use when the user says things like "/parallel", "max mode",
  "modo max", "en paralelo", "paralelizá esto", "fan out", "ultracode local", "dale con varios agentes",
  or hands over a task big enough that one sequential pass would take too long.
argument-hint: '[task] [--agents N] [--isolated] [--plan-only] [--yes]'
---

## What this does

Takes one task, splits it into sub-plans that cannot collide, and runs them **concurrently through the
`Workflow` tool** — one agent implementing each sub-plan, a second agent trying to prove that agent
wrong, and one repair attempt when it does. Then it converges: full test suite, typecheck, lint over
the integrated tree, and a report.

Invoking this skill **is** the opt-in for `Workflow`. The user does not need to type "ultracode".

The value is not "more agents". It is the two invariants below. An agent fleet with a bad
decomposition is slower than one sequential agent, because you pay for the work twice: once to write
the conflicts and once to untangle them.

## Hard rules

- **Never commits, pushes, merges to a shared branch, or opens PRs.** Changes are left in the working
  tree with a report. "Max" is about agents, not about permissions.
- **No file is touched by two sub-plans.** Verified with a table before a single agent is launched
  (Phase 2). If the table has a collision that cannot be factored out, the work is not parallelizable
  — say so and stop.
- **Every sub-plan is self-contained on disk.** Subagents get a prompt and nothing else — no memory of
  this conversation. They are handed a file path, so the file must carry the why, the scope, the
  constraints and the acceptance criteria.
- **Verification is adversarial and independent.** The agent that verifies a sub-plan is never the
  agent that implemented it, and it re-runs the acceptance criteria itself rather than believing the
  implementer's summary.

## Phase 0 — Preconditions

1. `git status --short` — a dirty tree makes it impossible to tell agent output from pre-existing
   work at convergence. If dirty: list what is dirty and ask whether to proceed anyway or stash.
2. Record the starting branch and `git rev-parse HEAD`. That SHA is the baseline every diff in the
   report is taken against.
3. If not in a git repo, `--isolated` is unavailable and convergence has no diff to show. Say so.

## Phase 1 — Recon (sequential, cheap)

Understand the task and map the surface before splitting it. `$ARGUMENTS` is the task if given,
otherwise infer it from the conversation; if the scope is genuinely ambiguous, ask **one** question.

Use `Explore` or `grep`/`find` to answer: which files, modules and layers are in play, what the
natural seams are (per-module, per-screen, per-endpoint, per-test-suite, frontend vs backend), and
whether anything cross-cutting (shared types, barrel exports, a migration, a config key) must happen
before or after the fan-out.

Do not skip this. A decomposition written without reading the layout is a guess, and Phase 2's table
will be a fiction built on it.

## Phase 2 — Decomposition

Split into **N sub-plans, default 3–5** (`--agents N` overrides). Fewer, bigger sub-plans beat many
tiny ones: agent startup, context re-derivation and merge cost dominate below ~15 minutes of work.

Write them to `<repo>/.claude/plans/<YYYYMMDD-HHMM>-<slug>/` before showing anything in chat — agents
read files, not chat. Create the directory if needed, and the first time, suggest adding
`.claude/plans/` to `.gitignore` (do not edit it yourself).

Each `sub-plan-N.md`:

```markdown
### Sub-plan N: <title>

**Scope:** <one sentence>

**Files in scope:**
- path/to/a.ts (edit)
- path/to/b.ts (create)

**Context:** <why this exists, conventions from CLAUDE.md, what NOT to touch>

**Steps:**
1. ...

**Acceptance criteria:**
- <observable check>
- Tests pass: `<exact command>`
- Typecheck passes: `<exact command>`
```

Acceptance criteria with no runnable command are not acceptance criteria — the verifier has nothing
to run and will rubber-stamp. If a sub-plan genuinely has no automated check, say which one and why.

`meta.md` carries the overview, prerequisites, the sub-plan list, the convergence steps, and:

**The independence table** — one row per file path mentioned anywhere, one column of sub-plans
touching it. Any row with two sub-plans means the decomposition is broken. Fix it by merging those
sub-plans, extracting the shared piece into a sequential prerequisite, or falling back to `--isolated`.
Reading the same file from two sub-plans is fine; writing it is not.

`--plan-only` stops here.

## Phase 3 — Gate

Show, in chat: the one-paragraph overview, the sub-plan list with file paths, **the independence
table**, prerequisites, and the agent count. Never paste full sub-plan bodies — they are on disk.

Then ask for confirmation. `--yes` skips the ask. Run any sequential prerequisites yourself, in the
main session, before launching.

## Phase 4 — Execution (the `Workflow` call)

Call the `Workflow` tool with an inline `script` built from
[`references/workflow-template.md`](references/workflow-template.md), passing the absolute sub-plan
paths through `args`. Read that file before writing the script — it carries the pipeline shape, the
schemas, and the constraints of the scripting environment.

The shape is `pipeline(subplans, implement, verifyThenRepair)`: each sub-plan is verified the moment
its implementation lands, without waiting for the other implementers. Not `parallel()` — there is no
cross-sub-plan dependency, so a barrier here would just idle the fast agents.

Concurrency is capped around 10 agents at a time regardless of how many items you pass; the workflow
runs in the background and notifies on completion. If the script needs a fix mid-run, edit the
persisted script file the tool result points at and relaunch with `{scriptPath, resumeFromRunId}` —
the unchanged prefix of agents returns from cache instead of re-running.

## Phase 5 — Convergence (sequential, main session)

1. `git status --short` and `git diff --stat <baseline-sha>` — what actually changed.
2. **Check the invariant held:** every changed file must appear in exactly one sub-plan's scope. A
   file changed by an agent that did not own it is the failure mode this whole skill exists to
   prevent — report it loudly, it is not a footnote.
3. Run the full suite, typecheck and lint over the integrated tree. Per-sub-plan green does not imply
   green together; that is the entire point of this phase.
4. Report per sub-plan: ok / repaired / failed / blocked, with the verifier's evidence. Say plainly
   what is not done. A failed sub-plan is a result, not something to quietly retry forever.

## `--isolated`

For when the decomposition cannot avoid overlap and the user accepts merge cost.

Do **not** use the workflow's `isolation: 'worktree'` option: it puts worktrees where the harness
chooses (violating the `<repo>/.worktrees/` rule) and gives *every* agent a fresh one, so the verifier
would never see what the implementer wrote.

Instead, in the main session, after confirming with the user:

```bash
git -C <repo> worktree add .worktrees/parallel-<slug>-<n> -b parallel/<slug>-<n>
grep -qxF '.worktrees/' .git/info/exclude || echo '.worktrees/' >> .git/info/exclude
```

Pass each worktree path in that sub-plan's prompt; implementer and verifier both work there, so the
handoff survives. Convergence then merges `parallel/<slug>-<n>` into the starting branch one at a
time, stopping at the first conflict and handing it to the user. Leave the worktrees in place — the
`clean-worktrees` skill removes them once merged.

## When NOT to use this

Say so and do the work sequentially instead:

- The task fits in one agent's context and one pass. Orchestration overhead is real.
- Every change lands in the same file, or in a shared type/barrel/migration.
- The work is exploratory ("figure out why X is slow") — you cannot write acceptance criteria for a
  question, and sub-plans without acceptance criteria are unverifiable.
- Ordering is the whole task (a migration whose steps must run in sequence).

## Anti-patterns

- **Fake parallelism.** Declaring sub-plans independent when they are not, because the user asked for
  parallel. The conflicts arrive later and cost more.
- **Splitting too fine.** Eight 5-minute sub-plans lose to three 20-minute ones.
- **Hidden context.** Sub-plans that say "as discussed above". Fresh agents have no above.
- **Trusting the implementer's report.** `files_changed` is a claim; `git diff` is evidence.
- **Silent truncation.** If you cap the fan-out or drop a sub-plan, `log()` it. A report that omits
  what was skipped reads as full coverage.

## Output language

Match the user's language — plans, report and questions. Spanish in, Spanish out.
