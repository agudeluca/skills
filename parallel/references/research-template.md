# Research workflow template

For `--research`. Adapt it — do not paste it blind. Pass it as the `script` input of the `Workflow`
tool **inline** (never Write it to a file first), with `args`:

```json
{ "question": "why does the feed re-render on every keystroke?",
  "angles": ["/abs/.claude/research/20260909-1500-feed/angle-1.md", "..."],
  "refuters": 2,
  "rounds": 2 }
```

`refuters: 0` disables verification — the report must then say every finding is unverified.

```js
export const meta = {
  name: 'parallel-research',
  description: 'Sweep a question from independent angles, refute every finding, report what survives',
  phases: [
    { title: 'Sweep', detail: 'one agent per angle' },
    { title: 'Verify', detail: 'independent refuters, one lens each' },
    { title: 'Critique', detail: 'what the sweep missed' },
  ],
}

const QUESTION = args.question
const REFUTERS = args.refuters === 0 ? 0 : args.refuters || 2
const MAX_ROUNDS = args.rounds || 2
const WIDTH = args.width || 5

// Distinct lenses, not N copies of one skeptic. Redundancy catches lies; diversity catches
// the different ways a finding can be wrong.
const LENSES = [
  'Re-open the citation. Does the cited line actually say what the finding claims, or is the claim an inference layered on top of it?',
  'The finding asserts a cause. Is that justified, or is it two things that merely live in the same file? Look for the mechanism.',
  'Find one code path, config value, platform or version where this finding is false. If you find it, the finding is refuted as stated.',
]

const FINDINGS = {
  type: 'object',
  properties: {
    findings: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          claim: { type: 'string' },
          citation: { type: 'string' },
          detail: { type: 'string' },
        },
        required: ['claim', 'citation'],
      },
    },
    dead_ends: { type: 'array', items: { type: 'string' } },
  },
  required: ['findings'],
}

const VERDICT = {
  type: 'object',
  properties: {
    refuted: { type: 'boolean' },
    why: { type: 'string' },
    checked: { type: 'string' },
  },
  required: ['refuted', 'why'],
}

const GAPS = {
  type: 'object',
  properties: {
    done: { type: 'boolean' },
    gaps: { type: 'array', items: { type: 'string' } },
  },
  required: ['done', 'gaps'],
}

const READONLY = `You are READ-ONLY. Do not edit, create or delete any file. Do not run any command
that mutates state (no git checkout/commit/stash/reset, no installs, no migrations, no writes).
Reading, grepping, and running existing read-only commands is what you are here for.`

const sweepPrompt = (path) => `Read ${path} and execute it. It is self-contained: it states the
question, your angle on it, where to start, and what counts as evidence.

${READONLY}

Every finding must carry a citation a stranger can re-open on their own: file:line, a command with
its real output, a commit SHA, or a URL. A finding you cannot cite is not a finding — put it in
dead_ends with what you looked at, which is genuinely useful to the next round.

Do not pad. Three cited findings beat nine hedged ones. Returning an empty findings list with honest
dead_ends is a valid, useful result.`

const refutePrompt = (f, lens) => `Try to REFUTE this finding about: ${QUESTION}

Claim: ${f.claim}
Citation: ${f.citation}
Detail: ${f.detail || '(none given)'}

Your lens: ${lens}

${READONLY}

You are not grading effort or asking whether it is interesting — you are asking whether it is TRUE as
stated. Go look yourself; do not reason about it from the text above. Set refuted:true if the
evidence does not support the claim, if the claim overreaches what the evidence shows, or if you
cannot verify it at all. Uncertainty is refutation: a finding nobody could confirm does not belong in
a report. In "checked", say exactly what you opened or ran.`

const criticPrompt = (found) => `The question: ${QUESTION}

Findings that survived refutation so far:
${found.length ? found.map((f) => `- ${f.claim} [${f.citation}]`).join('\n') : '(none — every finding was refuted, or nothing was found)'}

${READONLY}

What is MISSING? Name concrete gaps only: a subsystem nobody read, a source nobody checked, a claim
nobody could verify, an angle the question needs that nobody took. For each gap, write it as an
instruction a fresh agent could execute without any of this context.

Judge against the question, not against volume. If these findings answer the question and the
remaining gaps would not change the answer, set done:true and return an empty gaps list — that is
the expected outcome of a good sweep, not a failure.`

const keyOf = (f) => `${f.citation}|${f.claim}`.toLowerCase().replace(/\s+/g, ' ').slice(0, 160)

const seen = new Set()
const confirmed = []
const killed = []
let angles = args.angles.map((p, i) => ({ key: `angle-${i + 1}`, prompt: sweepPrompt(p) }))
let roundsRun = 0

for (let round = 0; round < MAX_ROUNDS; round++) {
  roundsRun = round + 1

  const batches = await pipeline(
    angles,
    (a) => agent(a.prompt, { label: `sweep:${a.key}`, phase: 'Sweep', schema: FINDINGS }),

    async (res, a) => {
      if (!res || !res.findings) return []

      // Dedup against everything ever seen, not against what survived: otherwise a finding the
      // refuters killed comes back every round and the loop never converges.
      const fresh = res.findings.filter((f) => {
        const k = keyOf(f)
        if (seen.has(k)) return false
        seen.add(k)
        return true
      })
      if (!fresh.length) return []
      if (!REFUTERS) return fresh.map((f) => ({ ...f, refuters: 0, survived: 0 }))

      const judged = await parallel(
        fresh.map((f) => () =>
          parallel(
            LENSES.slice(0, REFUTERS).map((lens) => () =>
              agent(refutePrompt(f, lens), { label: `refute:${a.key}`, phase: 'Verify', schema: VERDICT }),
            ),
          ).then((vs) => {
            const votes = vs.filter(Boolean)
            const stands = votes.filter((v) => !v.refuted)
            // Unanimous, deliberately: with two refuters, one refutation kills the finding. In a
            // report, a false positive costs more than a missed finding — the reader acts on it.
            if (votes.length && stands.length === votes.length) {
              return { ...f, refuters: votes.length, survived: stands.length }
            }
            killed.push({
              claim: f.claim,
              citation: f.citation,
              why: votes.filter((v) => v.refuted).map((v) => v.why).join(' | ') || 'no refuter returned a verdict',
            })
            return null
          }),
        ),
      )
      return judged.filter(Boolean)
    },
  )

  confirmed.push(...batches.filter(Boolean).flat())
  log(`round ${roundsRun}: ${confirmed.length} finding(s) standing, ${killed.length} refuted`)

  if (round === MAX_ROUNDS - 1) break

  const critic = await agent(criticPrompt(confirmed), { label: 'critic', phase: 'Critique', schema: GAPS })
  if (!critic || critic.done || !critic.gaps || !critic.gaps.length) {
    log('critic found no gaps worth another round')
    break
  }
  if (critic.gaps.length > WIDTH) {
    log(`critic raised ${critic.gaps.length} gaps, taking the first ${WIDTH} — the rest go in the report as not looked at`)
  }
  angles = critic.gaps.slice(0, WIDTH).map((g, i) => ({
    key: `gap-${roundsRun}-${i + 1}`,
    prompt: `${g}\n\nThe question being answered: ${QUESTION}\n\n${READONLY}\n\nEvery finding needs a citation a stranger can re-open: file:line, a command with output, a commit SHA, or a URL.`,
  }))
  log(`round ${roundsRun + 1}: ${angles.length} gap angle(s) from the critic`)
}

return { question: QUESTION, confirmed, killed, rounds: roundsRun, verified: REFUTERS > 0 }
```

## Why this shape

- **Refutation, not voting.** Agents that share a codebase and a prompt share a bias, so three
  agreeing is not three confirmations. Each refuter is told to break the finding, and each gets a
  different lens — re-read the citation, attack the causal step, hunt for a counterexample.
- **Unanimous survival.** One refutation kills. In a report a false positive is worse than a miss:
  the reader acts on it, and the citation makes it look checked.
- **Dedup against `seen`, never against `confirmed`.** Dedup against survivors and every refuted
  finding returns next round forever.
- **`killed` is an output, not a log line.** "We considered X and it was wrong because Y" is often
  the most useful part of a research report, and it is what stops the next person redoing the sweep.
- **The critic runs after a barrier**, which is correct here and nowhere else in this file: it needs
  every finding at once to say what is missing.

## Environment constraints

Plain JavaScript, not TypeScript — no type annotations, interfaces or generics. `Date.now()`,
`new Date()` and `Math.random()` throw (they would break resume): pass timestamps through `args` and
vary anything random by index. The script itself has no filesystem or Node API — only agents touch
disk. `meta` must be a pure literal.
