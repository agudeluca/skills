# Agent registry — design

Date: 2026-10-06

A shared, fast-to-read record of every Claude agent running on this machine: who is alive,
where, what they are doing, and which resources they hold. Readable by both config dirs
(`clauder` → `~/.claude`, `claudepr` → `~/.claude-personal`), which otherwise share nothing.

## Problem

The two aliases are separate installs. They do not share settings, memory, or `projects/`, so a
session under one alias cannot see a session under the other. In practice several agents run at
once across different repos and collide over machine-wide resources.

Measured on 2026-10-06 while writing this spec:

- 7 live `claude` processes across 5 projects (`expenses`, `humand`, `frequencyinvest`,
  `humand-mobile` ×2), all launched by cmux.
- 4 node dev servers listening: `5174`, `5175`, `5185`, `5186`. The `expenses` session had been
  holding `5185`/`5186` for 13 hours with `vite --port 5186 --strictPort` — a strict port does not
  degrade when taken, it fails the boot.
- No hooks configured in either config dir; `~/.claude-shared` did not exist.

The collisions are over ports, the iOS simulator, Metro bundler instances, and local test
databases. Nothing on the machine tracks who holds what.

## Decisions

1. **One registry, carrying both status and resources** — a single record per session holds identity,
   intent, and leases. Not two systems.
2. **Informs, does not exclude** — the registry answers "what is happening on this machine". An
   agent reads it and picks something else. There is no claim negotiation and no locking.
3. **Hybrid writes** — hooks write the base record automatically; the agent enriches it with intent
   and leases when relevant. If the agent never enriches anything, the base record is still useful.
   The two mechanisms fail in opposite ways, so together they degrade gracefully.
4. **Derive what can be derived; store only the rest.** Liveness comes from the kernel, port
   ownership from the process tree. Only intent and process-less resources are stored.
5. **PID is the source of truth for liveness; the 2h TTL is the backstop.** A dead PID is detected
   in microseconds. The TTL only covers what a PID cannot: reboots and recycled PIDs.

## Non-goals

- No locking, leases with teeth, or claim negotiation between processes.
- No port reservation. Ports are read from `lsof` at the moment of use, never reserved ahead.
- No cross-machine coordination. This is one machine's `~/.claude-shared`.
- No history or metrics. The registry describes the present; dead records are deleted, not archived.
- Hooks never block, slow, or fail a session. Any registry failure is silent.

## Architecture

### Store

`~/.claude-shared/agents/<session-id>.json` — one file per session.

One file per session rather than a shared JSON: with ~7 concurrent writers and no lock manager, a
single file would eventually be corrupted by interleaved read-modify-write. One file per session
makes each write atomic on its own (write `.tmp`, then `rename()`, which is atomic on APFS), and
removing a dead session is `rm` rather than a rewrite of shared state.

`CLAUDE_SHARED_DIR` overrides the location, so tests run against a temp dir.

`rename()` protects a *reader* from seeing a half-written record, but it does not stop two
concurrent `claim` calls on the same record from losing one of the two leases — both would read the
same `leases[]` and the second write would overwrite the first. So `claim` and `release`, the only
read-modify-write operations, serialize per record: acquire `<session-id>.lock` with `mkdir` (atomic
and, unlike a lockfile, self-evident when stale), retry briefly, and proceed without the lock after
a short timeout rather than blocking a turn. Hook writes need none of this — `start` and `end`
replace or delete the whole file, and `touch` rewrites a single field whose last writer wins by
definition.

### Record

```json
{
  "session_id": "77060a64-d992-4c90-bf2e-e58cbe14950d",
  "pid": 73491,
  "config_dir": "/Users/agustindeluca/.claude-personal",
  "alias": "claudepr",
  "cwd": "/Users/agustindeluca/projects/humand-mobile",
  "repo": "humand-mobile",
  "branch": "feature/permissions",
  "started_at": "2026-10-06T09:35:00Z",
  "updated_at": "2026-10-06T11:20:00Z",
  "intent": "HU-1234 — document module permissions",
  "leases": [
    { "kind": "ios-simulator", "id": "A1B2C3D4-…", "note": "iPhone 16 Pro", "since": "2026-10-06T10:02:00Z" },
    { "kind": "metro", "id": "8081", "since": "2026-10-06T10:02:00Z" }
  ]
}
```

`alias` is derived from `config_dir` (`~/.claude` → `clauder`, `~/.claude-personal` → `claudepr`)
so a reader can tell the two installs apart. `intent` and `leases` are the only agent-written
fields; everything else is written by hooks.

How long a resource has been held is derived, not stored: `now - lease.since` for a lease,
`now - started_at` for the session itself. `list` renders both as a duration, which is what makes
"this session has been sitting on 5186 for 13 hours" visible at a glance.

Absent by design: no port list (derived), no status field (derived), no CPU/memory (not actionable —
knowing an agent uses 1.8% RAM changes no decision).

### Resolving the session's own PID

Hooks run as a subprocess of the `claude` process, so `$PPID` points at the hook's shell, not at
Claude. The script walks the parent chain upward until it finds a process whose command is `claude`
and records that PID. If the walk reaches PID 1 without a match, it writes no PID and the record is
governed by the TTL alone.

### Liveness ladder

Applied in order to each record on every read:

| # | Check | Verdict |
| --- | --- | --- |
| 1 | `kill -0 $pid` fails | dead — reap the record |
| 2 | PID alive but its command is not `claude` | recycled PID — dead, reap |
| 3 | alive, is `claude`, `updated_at` older than 2h | **stale** — show the session, treat its leases as free |
| 4 | otherwise | live |

Rule 3 is the refinement of "not updated in 2h means free": what expires is the *lease*, not the
session. An agent idle for three hours waiting on the user still exists and still appears; it just
stops holding a claim on the simulator.

### Deriving port ownership

Confirmed on the live machine:

```
node(:5186) → node → npm exec concurrently → zsh → claude(72680) → zsh → login → cmux
```

A dev server started through an agent's Bash tool is a descendant of that agent's `claude` process.
So `ports` lists every listening socket from `lsof -iTCP -sTCP:LISTEN -P -n`, walks each PID's
parent chain, and attributes the port to the first registered `claude` ancestor it finds. Ports with
no registered ancestor are reported as unowned (ControlCenter on 5000, `adb` on 5037, a server the
user started by hand).

This needs no cooperation from any agent and cannot go stale.

## Components

### `scripts/registry.sh`

| subcommand | caller | what it does |
| --- | --- | --- |
| `start` | `SessionStart` hook | resolve PID, write the base record, print the digest |
| `touch` | `Stop` hook | refresh `updated_at` only |
| `end` | `SessionEnd` hook | remove this session's record |
| `digest` | hook / agent | 4–6 compact lines: live agents, taken ports, held leases |
| `list` | `agents` CLI | full table for a human, including stale sessions and their reason |
| `claim <kind> <id> [note]` | agent | append a lease to this session's record |
| `release <kind> <id>` | agent | remove a lease |
| `ports` | agent / CLI | listening ports with their owning agent, derived |
| `reap` | any read path | delete records failing ladder rules 1–2 |

Every read path reaps first, so the registry self-cleans without a daemon or a cron job.

### Hooks

Merged into both `settings.json`:

- `SessionStart` → `registry.sh start`. Its stdout is injected into the session's context, so one
  hook both registers the session and tells the agent what else is running.
- `Stop` → `registry.sh touch`, async, so it never adds latency to a turn.
- `SessionEnd` → `registry.sh end`, timeout 1s.

cmux injects its own hooks through `--settings`, a separate layer that merges with `settings.json`.
Neither config dir has hooks today, so nothing is overwritten. The merge behaviour itself is assumed
from how Claude Code layers settings and is verified during implementation, not before.

### `SKILL.md`

The agent-facing contract, following the repo's existing skill format (frontmatter with
`name`/`description`/`argument-hint`, bilingual triggers, hard rules). It covers how to read the
registry, when to `claim` and `release`, and the one hard rule that matters:

> **Run `lsof` before binding a port.** Never trust the digest for this. The digest tells you what
> the machine looked like at session start; `lsof` tells you the truth now, in 200ms.

The digest gives awareness. `lsof` gives permission. Keeping those separate is what stops the
registry from becoming a file that confidently lies.

### `agents` CLI

`install.sh` symlinks `registry.sh` to `~/.local/bin/agents` (already in `PATH`), so the user runs
`agents` for the full picture and `agents ports` for port ownership.

## Installation

`install.sh` currently copies `settings.json` only when absent, which will not help here — both
already exist. It gains two steps:

1. Add `agent-registry` to the `SKILLS` array, so it is symlinked into both config dirs.
2. Merge the three hooks into each live `settings.json` with `jq`, idempotently: skip any hook whose
   command is already present, write via `.tmp` + `rename()`, and back the file up first. The same
   hooks are added to the `claude-config/settings.*.json` templates for a fresh machine.

Dependencies: `jq` (present at `/usr/bin/jq`, 1.7.1), `lsof`, `ps`. All stock macOS except `jq`;
the script checks for it and degrades to a no-op rather than failing a session start.

## Error handling

The registry is an optimisation. It must never be the reason a session fails to start.

- Every hook invocation is wrapped so a non-zero exit cannot propagate; `SessionStart` prints
  nothing rather than a partial digest.
- A corrupt or half-written record is skipped, not fatal: `jq` failing on one file must not break
  the digest for the others.
- A missing `~/.claude-shared/agents/` is created on demand.
- A missing `jq` disables the registry silently.
- `rename()` on the same filesystem keeps a reader from ever seeing a partial record.

## Testing

`CLAUDE_SHARED_DIR` points at a temp dir, and fixture records cover the ladder:

| case | expected |
| --- | --- |
| record with a dead PID | reaped |
| PID alive but command is not `claude` | reaped as recycled |
| live PID, `updated_at` 3h old | listed as stale, leases reported free |
| live PID, fresh timestamp, two leases | listed live with both leases |
| truncated / invalid JSON record | skipped, other records still listed |
| empty registry directory | digest prints nothing, exit 0 |
| `jq` unavailable (`PATH` stripped) | all subcommands exit 0, no output |
| two concurrent `claim` calls on one record | both leases survive |

Port derivation is tested against a real process: start `nc -l` on a free port from a shell whose
ancestor is a registered fake record, and assert `ports` attributes it to that session.
