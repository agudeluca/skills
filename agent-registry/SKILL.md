---
name: agent-registry
description: >
  Shared status of every Claude agent running on this machine — who is alive, in which repo and
  branch, what they are working on, and which machine-wide resources they hold (iOS simulator,
  Metro, a test database, a worktree). Readable by both config dirs, which otherwise share
  nothing, so sessions stop colliding over ports and devices. Use when the user says things like
  "qué agents hay corriendo", "quién está usando el simulador", "what else is running",
  "está libre el 8081", "agents status", "por qué me explota el puerto", or "/agent-registry" —
  and whenever you are about to take a machine-wide resource.
argument-hint: '[list | digest | ports | claim KIND ID [NOTE] | release KIND ID | intent TEXT]'
---

## What this is

A JSON record per live session under `~/.claude-shared/agents/`, written by hooks and enriched by
the agent. `clauder` (`~/.claude`) and `claudepr` (`~/.claude-personal`) are separate installs that
share no settings, memory or state, so this directory is the only place they can see each other.

```bash
bash <skill-dir>/scripts/registry.sh list      # or just `agents` from a terminal
```

**Hard rules**

- **Run `lsof -nP -iTCP -sTCP:LISTEN` before binding a port. Never decide from the digest.** The
  digest describes the machine as it was when this session started; by the time you boot a dev
  server it is fiction. `lsof` costs 200ms and cannot be wrong.
- Never kill, signal or `pkill` another agent's process, and never free a resource another session
  holds. Report the conflict and pick something else.
- Never edit another session's record. `claim`, `release` and `intent` only ever touch your own.
- The registry informs, it does not grant. Finding no lease on a resource is not permission to
  assume nobody is using it — verify the resource itself when you can.

Respond in the language the user is using.

## Reading it

| command | use |
| --- | --- |
| `registry.sh list` | the full picture: every session, its status, uptime, idle time, leases, and the ports agents own |
| `registry.sh digest` | the compact form the `SessionStart` hook injects into a session's context |
| `registry.sh ports` | every listening port with the agent that owns it, or `-` when no agent does |

`ports` needs no cooperation from anyone: it reads listening sockets from `lsof`, walks each
holder's parent chain, and attributes the port to the first registered session it finds. A dev
server you start through the Bash tool is a descendant of your own session, so it is attributed to
you automatically — there is nothing to declare and nothing that can go stale.

## Status, and what the 2h means

| status | meaning |
| --- | --- |
| `live` | the session's process is running and it reported in within the last 2h |
| `stale` | the process is running but has been idle for more than 2h |

A record whose process is gone, or whose PID now belongs to something else, is deleted on the next
read — no daemon, no cron.

**`stale` expires the lease, not the session.** A session idle for three hours is usually waiting
on the user, so it still appears and must not be disturbed. What becomes available is its *claim*
on the simulator or the test database, because a claim nobody has touched in two hours is more
likely forgotten than in use.

## Declaring your own work

Hooks already record your PID, repo, branch and timings. Two things only you know:

```bash
registry.sh intent "HU-1234 — permissions on the documents module"
registry.sh claim ios-simulator A1B2C3D4 "iPhone 16 Pro"
registry.sh release ios-simulator A1B2C3D4
```

Set `intent` when you start on something another session would care about — a ticket, a migration,
a repo-wide refactor. Skip it for a one-off question.

**Claim only resources that have no process of their own to point at.** Good: an iOS simulator, a
booted Android emulator, a shared test database, a worktree, a device on a cable. Bad: a port or a
dev server — those are already derived from the process tree, and storing them just creates a
second answer that can disagree with the first.

Release when you are done. If you forget, the 2h idle rule frees the claim for you.

## When you hit a conflict

1. `registry.sh ports` or `registry.sh list` to see who holds it.
2. If a **live** session holds it, pick something else — another port, another simulator. Say in one
   line what is holding it and what you picked instead.
3. If a **stale** session holds it, the lease is free; take the resource, but still leave that
   session's processes alone.
4. If nothing in the registry holds it, the holder is outside Claude entirely (a server the user
   started, `adb`, ControlCenter). Tell the user rather than working around it silently.

## Failure is silent by design

The registry is an optimisation, never a dependency. Every subcommand exits 0, a missing `jq`
disables it entirely, and a corrupt record is skipped rather than breaking the rest. If it returns
nothing, carry on — do not debug it mid-task and do not treat an empty registry as "the machine is
idle".

## Testing

```bash
bash <skill-dir>/scripts/test_registry.sh
```

Runs against a temp store, never the real `~/.claude-shared`.
