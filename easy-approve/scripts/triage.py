#!/usr/bin/env python3
"""Pull an open-PR board and bucket it by how much review each PR actually needs.

Does the mechanical half of /easy-approve: one GraphQL page per 50 PRs for the
metadata, files, review state and CI rollup, then a compare call per candidate to
learn how far its branch has drifted from the base branch. Everything that needs
judgment — picking what to reproduce, driving the simulator, reading a diff — is
left to the agent.

    triage.py                       # whole board, markdown table on stdout
    triage.py 9215 9199             # only these PRs
    triage.py --json board.json     # also dump the structured rows
    triage.py --repo owner/name --me myuser --base main
"""

import argparse
import json
import subprocess
import sys
from collections import Counter
from concurrent.futures import ThreadPoolExecutor

# A PR this size or smaller is one an agent can hold in its head and reproduce in
# a single pass. Above it, reviewing is the point and there are no shortcuts.
VALIDATABLE_MAX_LINES = 150

# A PR wearing one of these is parked by its author. No amount of reading the
# diff changes that, so the state gate below retires it before the size
# heuristic ever runs. Matched case-insensitively as a substring, so "🚧 On Hold"
# and "blocked: waiting on backend" both land.
ON_HOLD_LABEL_HINTS = ("on hold", "blocked", "wip", "do not merge", "draft")

BOARD_QUERY = """
query($owner:String!, $name:String!, $cursor:String) {
  repository(owner:$owner, name:$name) {
    pullRequests(states:OPEN, first:50, after:$cursor,
                 orderBy:{field:CREATED_AT, direction:DESC}) {
      pageInfo { hasNextPage endCursor }
      nodes {
        number title url isDraft additions deletions changedFiles
        baseRefName headRefName reviewDecision mergeable updatedAt
        author { login }
        labels(first:20) { nodes { name } }
        files(first:100) { nodes { path } }
        reviews(last:30) { nodes { state author { login } submittedAt } }
        commits(last:1) {
          nodes { commit { committedDate statusCheckRollup { state } } }
        }
      }
    }
  }
}
"""


def gh(*args: str) -> str:
    out = subprocess.run(
        ["gh", *args], capture_output=True, text=True, check=False
    )
    if out.returncode != 0:
        raise RuntimeError(f"gh {' '.join(args)} failed: {out.stderr.strip()}")
    return out.stdout


def fetch_board(owner: str, name: str) -> list[dict]:
    nodes, cursor = [], None
    while True:
        args = [
            "api", "graphql",
            "-f", f"query={BOARD_QUERY}",
            "-F", f"owner={owner}", "-F", f"name={name}",
        ]
        if cursor:
            args += ["-F", f"cursor={cursor}"]
        page = json.loads(gh(*args))["data"]["repository"]["pullRequests"]
        nodes += page["nodes"]
        if not page["pageInfo"]["hasNextPage"]:
            return nodes
        cursor = page["pageInfo"]["endCursor"]


MERGEABLE_QUERY = """
query($owner:String!, $name:String!, $number:Int!) {
  repository(owner:$owner, name:$name) {
    pullRequest(number:$number) { mergeable }
  }
}
"""


def resolve_mergeable(owner: str, name: str, board: list[dict]) -> None:
    """Turn `mergeable: UNKNOWN` into a real answer, in place.

    GitHub computes mergeability lazily: the first query returns UNKNOWN *and*
    kicks off the background merge, so a second one gets the verdict. Treating
    UNKNOWN as "fine" is therefore wrong in the one direction that costs the most
    — on a real board it hides PRs that cannot be merged at all, and sends the
    agent off to review code whose only problem is that it needs a rebase.
    """
    pending = [pr for pr in board if pr["mergeable"] == "UNKNOWN"]
    if not pending:
        return

    def ask(pr: dict) -> str:
        try:
            data = json.loads(gh(
                "api", "graphql",
                "-f", f"query={MERGEABLE_QUERY}",
                "-F", f"owner={owner}", "-F", f"name={name}",
                "-F", f"number={pr['number']}",
            ))
            return data["data"]["repository"]["pullRequest"]["mergeable"]
        except (RuntimeError, KeyError, json.JSONDecodeError):
            return "UNKNOWN"

    with ThreadPoolExecutor(max_workers=8) as pool:
        for pr, value in zip(pending, pool.map(ask, pending)):
            pr["mergeable"] = value


def path_buckets(paths: list[str]) -> set[str]:
    """Group touched paths into the few kinds that change how a PR is reviewed."""
    buckets = set()
    for path in paths:
        if path.startswith("e2e/"):
            buckets.add("e2e")
        elif path.startswith(("ios/", "android/", ".yarn/patches/")) or path.endswith(
            (".swift", ".m", ".mm", ".h", ".kt", ".java", ".podspec")
        ):
            buckets.add("native")
        elif path in ("package.json", "yarn.lock") or path.startswith("nitro-modules/"):
            buckets.add("deps")
        elif path.startswith(("scripts/", "docs/", ".github/", ".cursor/")) or path.endswith(".md"):
            buckets.add("tooling")
        elif path.startswith("app/"):
            buckets.add("app")
        else:
            buckets.add("other")
    return buckets


def ci_state(pr: dict) -> str:
    commits = pr["commits"]["nodes"]
    if not commits:
        return "none"
    rollup = commits[0]["commit"]["statusCheckRollup"]
    return rollup["state"].lower() if rollup else "none"


def blocked_reason(pr: dict, me: str) -> str:
    """Why reading this PR's diff cannot change what happens to it, or "".

    Checked before anything about size or paths, because state outranks content:
    a 6-line PR that is parked, conflicting or already approved needs an author,
    a rebase or nothing at all — never a reviewer. Skipping this gate is how a
    board report spends its effort on the PRs least able to use it.
    """
    if pr["changedFiles"] == 0:
        return "empty diff — already on base, close it"

    for label in (node["name"] for node in pr["labels"]["nodes"]):
        lowered = label.lower()
        for hint in ON_HOLD_LABEL_HINTS:
            if hint in lowered:
                return f"parked by its author: {label}"

    if pr["mergeable"] == "CONFLICTING":
        return "conflicts with base — rebase before reviewing"

    my_reviews = [
        r for r in pr["reviews"]["nodes"]
        if me and r["author"] and r["author"]["login"] == me
        and r["state"] in ("APPROVED", "CHANGES_REQUESTED")
    ]
    if my_reviews and my_reviews[-1]["state"] == "APPROVED":
        return "already approved by you"

    if pr["reviewDecision"] == "CHANGES_REQUESTED":
        # A push after the rejection may have answered it — the agent still has
        # to look, but it is a different question from "review this fresh".
        requested = [
            r["submittedAt"] for r in pr["reviews"]["nodes"]
            if r["state"] == "CHANGES_REQUESTED" and r["submittedAt"]
        ]
        commits = pr["commits"]["nodes"]
        pushed = commits[0]["commit"]["committedDate"] if commits else ""
        if requested and pushed and pushed > max(requested):
            return "changes requested — pushed since, check if addressed"
        return "changes requested — the author owns it"

    return ""


def classify(pr: dict, buckets: set[str], blocked: str) -> str:
    """blocked / zero-risk / validatable / needs-real-review — never 'approve'.

    zero-risk means the change cannot reach the shipped app: test flows, dev
    scripts, docs, or a bot backport of an already-merged commit. It still has to
    be read; it just cannot be reproduced, because there is nothing to reproduce.
    """
    if blocked:
        return "blocked"
    bot = pr["author"]["login"].startswith("app/")
    if buckets and buckets <= {"e2e", "tooling"}:
        return "zero-risk"
    if bot and pr["changedFiles"] <= 2:
        return "zero-risk"
    if "app" in buckets and not (buckets & {"native", "deps"}):
        if pr["additions"] + pr["deletions"] <= VALIDATABLE_MAX_LINES:
            return "validatable"
    return "needs-real-review"


def drift(repo: str, base: str, head: str) -> str:
    """How far the PR branch has fallen behind its base.

    A branch dozens of commits behind is the trap that makes a PR look broken
    locally: its tests run against today's node_modules and fail on dependencies
    that no longer exist. Worth knowing before blaming the diff.
    """
    try:
        data = json.loads(gh("api", f"repos/{repo}/compare/{base}...{head}"))
        return f"-{data['behind_by']}/+{data['ahead_by']}"
    except (RuntimeError, KeyError, json.JSONDecodeError):
        return "?"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("numbers", nargs="*", type=int, help="only these PR numbers")
    ap.add_argument("--repo", default="HumandDev/humand-mobile")
    ap.add_argument("--base", default="develop")
    ap.add_argument("--me", default="", help="skip this author's own PRs")
    ap.add_argument("--json", dest="json_out", default="")
    ap.add_argument("--include-drafts", action="store_true")
    args = ap.parse_args()

    owner, name = args.repo.split("/")
    board = fetch_board(owner, name)
    resolve_mergeable(owner, name, board)
    wanted = set(args.numbers)

    rows = []
    for pr in board:
        if wanted and pr["number"] not in wanted:
            continue
        if not wanted:
            if pr["isDraft"] and not args.include_drafts:
                continue
            if args.me and pr["author"]["login"] == args.me:
                continue
        paths = [f["path"] for f in pr["files"]["nodes"]]
        buckets = path_buckets(paths)
        blocked = blocked_reason(pr, args.me)
        rows.append(
            {
                "number": pr["number"],
                "title": pr["title"].strip(),
                "url": pr["url"],
                "author": pr["author"]["login"],
                "draft": pr["isDraft"],
                "lines": pr["additions"] + pr["deletions"],
                "files": pr["changedFiles"],
                "files_truncated": pr["changedFiles"] > len(paths),
                "paths": paths,
                "buckets": sorted(buckets),
                "base": pr["baseRefName"],
                "head": pr["headRefName"],
                "stacked": pr["baseRefName"] != args.base,
                "review_decision": pr["reviewDecision"] or "PENDING",
                "reviewed_by_me": any(
                    r["author"] and r["author"]["login"] == args.me
                    for r in pr["reviews"]["nodes"]
                )
                if args.me
                else False,
                "ci": ci_state(pr),
                "labels": [n["name"] for n in pr["labels"]["nodes"]],
                "mergeable": pr["mergeable"],
                "updated": pr["updatedAt"][:10],
                "blocked_reason": blocked,
                "touches_e2e_config": "e2e/config.yml" in paths,
                "bucket": classify(pr, buckets, blocked),
            }
        )

    # Drift costs an API call each, so only ask for the PRs that will be acted on.
    candidates = [
        r for r in rows if r["bucket"] not in ("needs-real-review", "blocked")
    ]
    with ThreadPoolExecutor(max_workers=8) as pool:
        for row, value in zip(
            candidates,
            pool.map(lambda r: drift(args.repo, r["base"], r["head"]), candidates),
        ):
            row["drift"] = value

    order = {"validatable": 0, "zero-risk": 1, "needs-real-review": 2, "blocked": 3}
    rows.sort(key=lambda r: (order[r["bucket"]], r["number"]))

    if args.json_out:
        with open(args.json_out, "w") as fh:
            json.dump(rows, fh, indent=2)

    print("| # | bucket | paths | lines | CI | drift | updated | author | title |")
    print("|---|---|---|---|---|---|---|---|---|")
    for r in rows:
        flags = []
        if r["blocked_reason"]:
            flags.append(r["blocked_reason"])
        if r["stacked"]:
            flags.append(f"stacked on {r['base']}")
        if r["reviewed_by_me"]:
            flags.append("already reviewed by you")
        if r["files_truncated"]:
            flags.append("file list truncated")
        # Titles here are routinely "Module | Thing", which would split the cell.
        title = r["title"][:58].replace("|", "\\|") + (" …" if len(r["title"]) > 58 else "")
        if flags:
            title += f" _({'; '.join(flags)})_"
        print(
            f"| {r['number']} | {r['bucket']} | {'+'.join(r['buckets'])} | "
            f"{r['lines']} | {r['ci']} | {r.get('drift', '-')} | {r['updated']} | "
            f"{r['author']} | {title} |"
        )

    counts = Counter(r["bucket"] for r in rows)
    print(
        f"\n{len(rows)} open PRs: "
        + ", ".join(f"{counts[b]} {b}" for b in order if counts[b])
        + "\n\nEvery one of these gets a line in the report. The counts above are"
        " what it has to reconcile against."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
