# Workflow template

Adapt this — do not paste it blind. Pass it as the `script` input of the `Workflow` tool **inline**
(never Write it to a file first), with `args` set to:

```json
{ "plans": ["/abs/path/.claude/plans/20260909-1430-slug/sub-plan-1.md", "..."],
  "worktrees": null,
  "base": "<baseline sha>" }
```

`worktrees` is `null` in the default shared-checkout mode, or an array of absolute worktree paths
parallel to `plans` under `--isolated`. Pass real JSON values, not a JSON-encoded string.

```js
export const meta = {
  name: 'parallel-execute',
  description: 'Implement N independent sub-plans concurrently, verify each one adversarially',
  phases: [
    { title: 'Implement', detail: 'one agent per sub-plan' },
    { title: 'Verify', detail: 'independent agent re-runs the acceptance criteria' },
    { title: 'Repair', detail: 'one targeted fix attempt per failed sub-plan' },
  ],
}

const PLANS = args.plans
const WORKTREES = args.worktrees || null
const BASE = args.base

const IMPL = {
  type: 'object',
  properties: {
    files_changed: { type: 'array', items: { type: 'string' } },
    commands_run: { type: 'array', items: { type: 'string' } },
    summary: { type: 'string' },
    blocked: { type: 'boolean' },
    blocked_reason: { type: 'string' },
  },
  required: ['files_changed', 'summary', 'blocked'],
}

const VERDICT = {
  type: 'object',
  properties: {
    ok: { type: 'boolean' },
    failures: { type: 'array', items: { type: 'string' } },
    evidence: { type: 'string' },
    out_of_scope_files: { type: 'array', items: { type: 'string' } },
  },
  required: ['ok', 'failures', 'evidence'],
}

const where = (i) =>
  WORKTREES ? `Work inside the git worktree at ${WORKTREES[i]} — cd there first and stay there.` : ''

const implPrompt = (path, i) => `Read ${path} and execute it. It is self-contained: follow its scope,
steps and acceptance criteria exactly.

${where(i)}

Hard constraints:
- Edit ONLY the files listed under "Files in scope". Other sub-plans are editing other files right
  now; touching a file outside your scope corrupts their work. If the sub-plan cannot be completed
  without editing a file outside scope, STOP and return blocked:true with the reason.
- Run the acceptance-criteria commands yourself before returning.
- Do not commit, push, or run git checkout/stash/reset.

Return files_changed as the paths you actually edited (verify with git status), not the ones you
planned to edit.`

const verifyPrompt = (path, i) => `You are verifying, adversarially, work another agent claims to have
finished. Assume it is wrong until the commands say otherwise.

${where(i)}

1. Read ${path} — the sub-plan it was supposed to execute.
2. Run every command under "Acceptance criteria" yourself. Paste the real output as evidence. A
   command you did not run is a failure, not a pass.
3. Check each non-command acceptance criterion against the actual diff (git diff ${BASE} -- <files>),
   not against any summary.
4. Report in out_of_scope_files any file changed that the sub-plan does not list in "Files in scope".

Do not fix anything. Report only. ok:true requires every criterion verified by output you saw.`

const repairPrompt = (path, i, verdict) => `The sub-plan at ${path} was implemented and FAILED
verification. Fix it.

${where(i)}

Failures:
${verdict.failures.map((f) => `- ${f}`).join('\n')}

Evidence:
${verdict.evidence}

Stay strictly inside that sub-plan's "Files in scope". Fix the cause, not the symptom — do not delete,
skip or weaken a failing test to make it pass. Re-run the acceptance criteria before returning. If the
failure cannot be fixed within scope, return blocked:true and say why.`

const results = await pipeline(
  PLANS,
  (path, _item, i) =>
    agent(implPrompt(path, i), { label: `impl:${i + 1}`, phase: 'Implement', schema: IMPL }),

  async (impl, path, i) => {
    if (!impl) return { path, status: 'lost', impl: null, verdict: null }
    if (impl.blocked) return { path, status: 'blocked', impl, verdict: null }

    let verdict = await agent(verifyPrompt(path, i), {
      label: `verify:${i + 1}`, phase: 'Verify', schema: VERDICT,
    })
    if (!verdict) return { path, status: 'unverified', impl, verdict: null }
    if (verdict.ok) return { path, status: 'ok', impl, verdict }

    log(`sub-plan ${i + 1} failed verification, one repair attempt`)
    const repair = await agent(repairPrompt(path, i, verdict), {
      label: `repair:${i + 1}`, phase: 'Repair', schema: IMPL,
    })
    if (!repair || repair.blocked) return { path, status: 'failed', impl: repair || impl, verdict }

    const reverdict = await agent(verifyPrompt(path, i), {
      label: `reverify:${i + 1}`, phase: 'Verify', schema: VERDICT,
    })
    return {
      path,
      status: reverdict && reverdict.ok ? 'repaired' : 'failed',
      impl: repair,
      verdict: reverdict || verdict,
    }
  },
)

return results.filter(Boolean)
```

## Why this shape

- **`pipeline`, not `parallel`.** Sub-plan 2's verifier starts the moment sub-plan 2's implementer
  lands, without waiting for sub-plan 5. A barrier would only be justified if a stage needed all
  prior results at once — nothing here does.
- **Repair lives inside stage 2**, so a slow repair on one sub-plan never blocks another's verify.
- **Separate verifier agent.** Self-verification by the implementer is the failure this design is
  built to avoid: the agent that wrote the bug is the one least able to see it.
- **`status` distinguishes `blocked` / `lost` / `unverified` / `failed`.** `agent()` returns `null`
  when the user skips it or it dies after retries — collapsing that into "failed" hides the
  difference between "the code is wrong" and "nobody looked".

## Environment constraints

Scripts are plain JavaScript, not TypeScript — no type annotations, interfaces or generics.
`Date.now()`, `new Date()` and `Math.random()` throw (they would break resume): pass timestamps
through `args` and vary anything random by index. There is no filesystem or Node API in the script
itself — only the agents touch disk. `meta` must be a pure literal.
