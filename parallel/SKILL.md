---
name: parallel
description: >
  Max mode: fan out a task across subagents and verify every result adversarially before believing it.
  Two modes — build (decompose into non-colliding sub-plans, implement each, re-run its acceptance
  criteria in a separate agent) and research (sweep a question from independent angles, try to refute
  every finding, ask what was missed). Use when the user says things like "/parallel", "max mode",
  "modo max", "en paralelo", "paralelizá esto", "fan out", "ultracode local", "dale con varios agentes",
  "investigá a fondo", "exploratorio", "research", or hands over a task or question too big for one
  sequential pass.
argument-hint: '[task or question] [--research] [--build] [--agents N] [--verify N] [--isolated] [--plan-only] [--yes]'
---

## What this does

Runs one task across a fleet of subagents and then tries to prove the fleet wrong. Invoking this skill
**is** the opt-in for the `Workflow` tool — the user does not need to type "ultracode".

The value is never "more agents". It is that nothing enters the final report on an agent's say-so.
An agent that fabricates a passing test and an agent that fabricates a `file:line` citation fail the
same way: the output reads exactly like the truth. Every phase below exists to make that expensive.

## Two modes

| | `build` | `research` |
| --- | --- | --- |
| input | a task with a deliverable | a question |
| split by | files (no two agents write the same one) | angles (subsystem, symptom, entity, git history, external docs) |
| hard invariant | **no file collisions** | **coverage** — no gap; overlap is fine, reading collides with nothing |
| verification | a second agent re-runs the acceptance criteria | 2 agents per finding try to **refute** it, each through a different lens |
| deliverable | a diff in the working tree | `.claude/research/<ts>-<slug>/report.md` |
| extra hard rule | never commits, pushes, merges or opens PRs | **read-only** — no agent edits anything |

Pick by the shape of the ask: a question ("why is X slow", "how does Y work", "what would break if Z")
is `research`; anything with a deliverable diff is `build`. `--research` / `--build` force it. If the
task is genuinely both ("find out why it's slow **and** fix it"), run `research` first, show the
report, and let the user decide what to build — do not chain them silently.

## Sizing

Default **5 agents wide** (`--agents N`), which is the concurrency cap either way. Width is not total:
`build` costs roughly `sub-plans × 2` agents plus repairs; `research` costs `angles + findings ×
refuters + 1 critic` per round. Refuters default to 2 (`--verify N`; `--verify 0` disables
verification and must be reported in the output as unverified).

Phase 3 shows the projected total before anything launches. Never launch a fleet whose size the user
has not seen.

## Phase 0 — Preconditions

- `build`: `git status --short` must be clean, or list what is dirty and ask. Record the baseline SHA
  (`git rev-parse HEAD`) — every diff in the report is taken against it.
- `research`: nothing to check. Read-only work does not care about the tree state.

## Phase 1 — Recon (sequential, cheap, both modes)

`$ARGUMENTS` is the task if given, otherwise infer from the conversation. If the scope is genuinely
ambiguous, ask **one** question.

Then map the ground yourself before splitting it — `Explore`, `grep`, `find`, `git log`. For `build`,
which files and layers are in play and where the seams are. For `research`, what the subsystems are
and which angles are even available, so the split is not five agents grepping the same directory.

Do not skip this. A decomposition written without reading the layout is a guess, and Phase 2's
verification table will be a fiction built on it.

## Phase 2 — Decomposition

Write to disk before showing anything in chat — agents read files, not conversations. `build` writes
`<repo>/.claude/plans/<YYYYMMDD-HHMM>-<slug>/`, `research` writes `<repo>/.claude/research/<same>/`.
The first time either directory is created, suggest adding it to `.gitignore` (do not edit it
yourself). `--plan-only` stops at the end of this phase.

### `build`: sub-plans

3–5 sub-plans. Fewer and bigger beats many and tiny — agent startup, context re-derivation and merge
cost dominate below ~15 minutes of work. Each `sub-plan-N.md`:

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

`meta.md` carries the overview, prerequisites, the sub-plan list, convergence steps, and **the
independence table**: one row per file path mentioned anywhere, one column of sub-plans touching it.
Any row with two sub-plans means the decomposition is broken — merge those sub-plans, extract the
shared piece into a sequential prerequisite, or fall back to `--isolated`. Reading the same file from
two sub-plans is fine; writing it is not.

### `research`: angles

3–5 angles, each a genuinely different **way of looking**, not a different folder. The point is that
each agent is blind to what the others will surface:

| angle | asks |
| --- | --- |
| by subsystem | what does this layer do about the question |
| by symptom | reproduce or measure the thing being asked about |
| by entity | follow one type / table / endpoint / user action end to end |
| by history | `git log -S`, blame, PRs — when did this change and why |
| by outside | docs, changelogs, issue trackers, the library's own source |

Five agents each grepping the same directory with different words is one angle, not five.

`meta.md` carries the question stated precisely, the angles, what is explicitly **out** of scope, and
**the coverage table**: one row per subsystem or source that could hold an answer, one column of
angles that will look at it. A row nobody covers is a gap — either add an angle or record it in the
report as deliberately not looked at. Unlike `build`, two angles in one row is fine and often good.

Sub-plan files here are `angle-N.md`, each self-contained: the question, this angle's lens, where to
start, what counts as evidence, and the rule that every finding must cite something a stranger can
re-open — `file:line`, a command with its output, a commit SHA, a URL. **"It seems like" is not a
finding.**

## Phase 3 — Gate

Show in chat: the question or task in one paragraph, the sub-plan/angle list, **the verification
table** (independence or coverage), prerequisites, and the projected agent total with its arithmetic
(`5 angles + ~8 findings × 2 refuters + 1 critic ≈ 22`). Never paste full sub-plan bodies — they are
on disk.

Then ask for confirmation. `--yes` skips the ask. Run any sequential prerequisites yourself, in the
main session, before launching.

## Phase 4 — Execution (the `Workflow` call)

Call the `Workflow` tool with an inline `script` adapted from the matching template — read it before
writing the script, it carries the schemas and the constraints of the scripting environment:

- `build` → [`references/workflow-template.md`](references/workflow-template.md)
- `research` → [`references/research-template.md`](references/research-template.md)

Both use `pipeline`, not `parallel`: an item moves to verification the moment it lands, without
waiting for its slowest sibling. A barrier is only correct when a stage needs every prior result at
once — neither template does, except the research critic, which by definition does.

The workflow runs in the background and notifies on completion. If the script needs a fix mid-run,
edit the persisted script file the tool result points at and relaunch with `{scriptPath,
resumeFromRunId}` — the unchanged prefix of agents returns from cache instead of re-running.

## Phase 5 — Convergence

### `build`

1. `git status --short` and `git diff --stat <baseline-sha>` — what actually changed.
2. **Check the invariant held:** every changed file must appear in exactly one sub-plan's scope. A
   file changed by an agent that did not own it is the failure mode this skill exists to prevent —
   report it loudly, it is not a footnote.
3. Run the full suite, typecheck and lint over the integrated tree. Per-sub-plan green does not imply
   green together; that is the entire point of this phase.
4. Report per sub-plan: ok / repaired / failed / blocked, with the verifier's evidence.

### `research`

1. Write `report.md`: the answer first, then the findings that support it, each with its citation and
   how many refuters it survived. Then **what was not looked at** — uncovered rows from the coverage
   table, angles that returned nothing, findings killed in verification and why. A research report
   without its own negative space is a sales pitch.
2. **Spot-check two surviving findings yourself**, in the main session, by opening the citation. The
   verifiers are agents too. If a citation does not say what the finding claims, that is not one bad
   finding — treat the whole run as suspect and say so.
3. Summarize in chat: the answer, the confidence, the gaps. Link the report; do not paste it whole.

Answer the question that was asked. Fifteen verified findings that never resolve the question are a
failed run, not a thorough one.

## `--isolated` (`build` only)

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

Say so and work sequentially instead:

- One agent can hold the whole thing in context and finish in one pass. Orchestration overhead is real.
- (`build`) Every change lands in the same file, or in a shared type / barrel / migration.
- (`build`) Ordering is the whole task — a migration whose steps must run in sequence.
- (`research`) The question has one obvious place to look. Five angles onto a two-file answer is
  theatre, and the synthesis step will invent structure to justify itself.
- The user asked a question you can answer from what is already in context.

## Anti-patterns

- **Fake parallelism.** Declaring sub-plans independent when they are not, because the user asked for
  parallel. The conflicts arrive later and cost more.
- **Fake angles.** Five agents running the same search with different words, then a synthesis that
  presents the same finding five times as convergent evidence.
- **Splitting too fine.** Eight 5-minute sub-plans lose to three 20-minute ones.
- **Hidden context.** Sub-plans that say "as discussed above". Fresh agents have no above.
- **Trusting the agent's report.** `files_changed` is a claim, `git diff` is evidence. A citation is a
  claim, the line at that citation is evidence.
- **Consensus as truth.** Agents sharing a codebase and a prompt share a bias; three agreeing is not
  three confirmations. Refutation is the check, not a vote.
- **Silent truncation.** If you cap the fan-out, drop an angle, or skip verification with
  `--verify 0`, `log()` it and put it in the report. Omission reads as full coverage.

## Output language

Match the user's language — plans, report, and questions. Spanish in, Spanish out.
