#!/usr/bin/env python3
"""Detect what changed on the authenticated user's open pull requests.

One pass, one GraphQL call, and no output at all when nothing changed -- so this can
drive a Monitor for hours without waking anyone on a quiet tick.

Events, tab separated:  kind  repo  pr  author  assoc  id  detail

  COMMENT     a new issue comment or review-thread comment
  REVIEW      a submitted review (CHANGES_REQUESTED / APPROVED / COMMENTED)
  CI_FAIL     checks went from not-failing to failing
  CI_RECOVER  checks went from failing to green

Trust is deliberately NOT decided here. `assoc` carries GitHub's authorAssociation so
the caller can triage cheaply, and trust.sh is the authoritative check before a push.

The user is whoever `gh` is authenticated as. Nothing is hardcoded.
"""
import argparse
import json
import os
import pathlib
import subprocess
import sys
from datetime import datetime, timezone

MARKER = "<!-- pr-follow -->"  # our own comments carry this; never react to them
TRUSTED_ASSOC = {"OWNER", "MEMBER", "COLLABORATOR"}

QUERY = """
query($q: String!) {
  search(query: $q, type: ISSUE, first: 50) {
    nodes {
      ... on PullRequest {
        number title url isDraft baseRefName headRefName
        repository { nameWithOwner isArchived defaultBranchRef { name } }
        comments(last: 40) {
          nodes { fullDatabaseId createdAt body authorAssociation author { login } }
        }
        reviews(last: 20) {
          nodes { fullDatabaseId state submittedAt body authorAssociation author { login } }
        }
        reviewThreads(last: 40) {
          nodes {
            isResolved
            comments(last: 15) {
              nodes { fullDatabaseId createdAt body path authorAssociation author { login } }
            }
          }
        }
        commits(last: 1) {
          nodes { commit { oid statusCheckRollup { state
            contexts(last: 100) { nodes {
              ... on CheckRun { name conclusion status detailsUrl }
              ... on StatusContext { context state targetUrl }
            } } } } }
        }
      }
    }
  }
}
"""


def gh_graphql(query, **variables):
    cmd = ["gh", "api", "graphql", "-f", f"query={query}"]
    for key, value in variables.items():
        cmd += ["-f", f"{key}={value}"]
    out = subprocess.run(cmd, capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit(f"poll.py: gh api graphql failed: {out.stderr.strip()[:400]}")
    return json.loads(out.stdout)


def default_state_path():
    base = os.environ.get("PR_FOLLOW_STATE")
    if base:
        return pathlib.Path(base).expanduser()
    root = os.environ.get("XDG_STATE_HOME", "~/.local/state")
    return pathlib.Path(root).expanduser() / "pr-follow" / "state.json"


def load_state(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return {"version": 1, "prs": {}}


def save_state(path, state):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, indent=2, sort_keys=True))
    tmp.replace(path)  # atomic: a crash mid-write cannot truncate the real file


def one_line(text, limit=160):
    flat = " ".join((text or "").split())
    return flat[:limit] + ("..." if len(flat) > limit else "")


def failing_checks(rollup):
    """Names of the checks that are actually red, for the event detail."""
    bad = []
    for node in (rollup or {}).get("contexts", {}).get("nodes", []) or []:
        if not node:
            continue
        if node.get("conclusion") in ("FAILURE", "TIMED_OUT", "CANCELLED", "STARTUP_FAILURE"):
            bad.append(node.get("name") or "?")
        elif node.get("state") in ("FAILURE", "ERROR"):
            bad.append(node.get("context") or "?")
    return bad


def collect_comments(pr):
    """Every comment on the PR, flattened, ours filtered out."""
    items = []
    for node in pr.get("comments", {}).get("nodes", []) or []:
        items.append((node, None))
    for thread in pr.get("reviewThreads", {}).get("nodes", []) or []:
        for node in thread.get("comments", {}).get("nodes", []) or []:
            items.append((node, thread))

    out = []
    for node, thread in items:
        if not node or MARKER in (node.get("body") or ""):
            continue  # our own comment: reacting to it would loop forever
        out.append({
            "id": str(node.get("fullDatabaseId")),
            "author": ((node.get("author") or {}).get("login")) or "ghost",
            "assoc": node.get("authorAssociation") or "NONE",
            "body": node.get("body") or "",
            "path": node.get("path"),
            "resolved": bool(thread.get("isResolved")) if thread else False,
        })
    return out


def main():
    ap = argparse.ArgumentParser(description="Detect new activity on your open PRs.")
    ap.add_argument("--state", type=pathlib.Path, default=default_state_path())
    ap.add_argument("--repo", action="append", default=[],
                    help="limit to this owner/name (repeatable)")
    ap.add_argument("--dry-run", action="store_true",
                    help="report events but do not remember them, so the next run repeats them")
    ap.add_argument("--baseline", action="store_true",
                    help="mark everything current as seen and emit nothing")
    ap.add_argument("--json", action="store_true", help="emit JSON objects instead of TSV")
    args = ap.parse_args()

    who = subprocess.run(["gh", "api", "user", "--jq", ".login"],
                         capture_output=True, text=True)
    if who.returncode != 0:
        sys.exit("poll.py: not authenticated -- run `gh auth login`")
    login = who.stdout.strip()

    data = gh_graphql(QUERY, q=f"is:pr is:open author:{login}")
    prs = [n for n in data["data"]["search"]["nodes"] if n]
    if args.repo:
        wanted = set(args.repo)
        prs = [p for p in prs if p["repository"]["nameWithOwner"] in wanted]

    state = load_state(args.state)
    state["login"] = login
    state["last_poll"] = datetime.now(timezone.utc).isoformat(timespec="seconds")
    events = []

    for pr in prs:
        repo = pr["repository"]["nameWithOwner"]
        archived = bool(pr["repository"].get("isArchived"))
        key = f"{repo}#{pr['number']}"
        entry = state["prs"].setdefault(key, {})
        first_sight = "seen" not in entry
        seen = set(entry.get("seen", []))

        head = (pr.get("commits", {}).get("nodes") or [{}])[0].get("commit") or {}
        rollup = head.get("statusCheckRollup") or {}
        ci = rollup.get("state") or "NONE"

        comments = collect_comments(pr)
        reviews = []
        for node in pr.get("reviews", {}).get("nodes", []) or []:
            if not node or MARKER in (node.get("body") or ""):
                continue
            reviews.append({
                "id": str(node.get("fullDatabaseId")),
                "author": ((node.get("author") or {}).get("login")) or "ghost",
                "assoc": node.get("authorAssociation") or "NONE",
                "state": node.get("state") or "",
                "body": node.get("body") or "",
            })

        current_ids = {c["id"] for c in comments} | {r["id"] for r in reviews}

        # A PR we have never polled is baselined, not replayed: acting on a month of
        # old review comments the moment the monitor starts would be indefensible.
        if first_sight or args.baseline:
            entry["seen"] = sorted(current_ids)
            entry["ci"] = ci
            entry["head"] = head.get("oid")
            entry.setdefault("acted", {})
            entry.setdefault("reruns", {})
            if first_sight and not args.baseline:
                print(f"# baseline {key}: {len(current_ids)} existing item(s), "
                      f"ci={ci}", file=sys.stderr)
            continue

        for c in comments:
            if c["id"] in seen or c["resolved"]:
                continue
            events.append({
                "kind": "COMMENT", "repo": repo, "pr": pr["number"],
                "author": c["author"], "assoc": c["assoc"], "id": c["id"],
                "detail": (f"[{c['path']}] " if c["path"] else "") + one_line(c["body"]),
                "url": pr["url"], "trusted": c["assoc"] in TRUSTED_ASSOC,
                "archived": archived, "draft": bool(pr.get("isDraft")),
            })
        for r in reviews:
            if r["id"] in seen:
                continue
            events.append({
                "kind": "REVIEW", "repo": repo, "pr": pr["number"],
                "author": r["author"], "assoc": r["assoc"], "id": r["id"],
                "detail": f"{r['state']}: {one_line(r['body'])}",
                "url": pr["url"], "trusted": r["assoc"] in TRUSTED_ASSOC,
                "archived": archived, "draft": bool(pr.get("isDraft")),
            })

        was = entry.get("ci", "NONE")
        red = {"FAILURE", "ERROR"}
        if ci in red and was not in red:
            events.append({
                "kind": "CI_FAIL", "repo": repo, "pr": pr["number"],
                "author": "ci", "assoc": "BOT", "id": head.get("oid", "")[:12],
                "detail": "failing: " + (", ".join(failing_checks(rollup)) or "unknown"),
                "url": pr["url"], "trusted": False,
                "archived": archived, "draft": bool(pr.get("isDraft")),
            })
        elif ci == "SUCCESS" and was in red:
            events.append({
                "kind": "CI_RECOVER", "repo": repo, "pr": pr["number"],
                "author": "ci", "assoc": "BOT", "id": head.get("oid", "")[:12],
                "detail": "all checks green", "url": pr["url"], "trusted": False,
                "archived": archived, "draft": bool(pr.get("isDraft")),
            })

        entry["seen"] = sorted(current_ids)
        entry["ci"] = ci
        entry["head"] = head.get("oid")

    # Drop PRs that closed, so the state file does not grow forever.
    live = {f"{p['repository']['nameWithOwner']}#{p['number']}" for p in prs}
    if not args.repo:
        for gone in [k for k in state["prs"] if k not in live]:
            del state["prs"][gone]

    for e in events:
        if args.json:
            print(json.dumps(e, sort_keys=True))
        else:
            detail = e["detail"]
            if e.get("archived"):
                detail = "(archived repo, read-only) " + detail
            print("\t".join([e["kind"], e["repo"], str(e["pr"]), e["author"],
                             e["assoc"], e["id"], detail]))

    if not args.dry_run and not args.baseline:
        save_state(args.state, state)
    elif args.baseline:
        save_state(args.state, state)

    print(f"# poll.py: {len(prs)} open PR(s), {len(events)} new event(s)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
