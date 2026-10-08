#!/bin/bash
# Checkout discipline for the acting half of pr-follow.
#
# Every subcommand refuses rather than improvises. The invariants it exists to hold:
# never touch a checkout with uncommitted work in it, never leave the user on a branch
# they did not choose, never push to a default branch, and never force-push anything.
#
#   act.sh guard   <repo-path>                  -> SAFE <branch> | BLOCKED <reason>
#   act.sh enter   <repo-path> <owner/repo> <pr>-> checks the PR branch out, prints head sha
#   act.sh restore <repo-path> <branch>         -> puts the checkout back
#   act.sh push    <repo-path>                  -> plain push, with the refusals below
set -uo pipefail

die() { echo "BLOCKED $*" >&2; exit 1; }

# Returns every name that must never be pushed to. origin/HEAD is often unset on a
# fresh clone, and a lookup that silently returns nothing would disarm the check that
# depends on it -- so main and master are always in the set, and over-refusing is the
# only acceptable direction to be wrong in.
protected_branches() {
  local head
  head=$(git -C "$1" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null \
           | sed 's#^origin/##')
  printf '%s\n' "$head" main master | grep -v '^$' | sort -u
}

is_protected() {
  protected_branches "$1" | grep -qxF "$2"
}

cmd_guard() {
  local repo="${1:-}"
  [ -d "$repo/.git" ] || [ -f "$repo/.git" ] || die "not a git checkout: $repo"
  # Uncommitted work is the user's. We skip the PR rather than stash, reset or commit it.
  [ -z "$(git -C "$repo" status --porcelain)" ] || die "working tree is dirty: $repo"
  echo "SAFE $(git -C "$repo" rev-parse --abbrev-ref HEAD)"
}

cmd_enter() {
  local repo="${1:-}" slug="${2:-}" pr="${3:-}"
  cmd_guard "$repo" >/dev/null || exit 1
  git -C "$repo" fetch --quiet origin || die "fetch failed in $repo"
  GH_REPO="$slug" gh pr checkout "$pr" --repo "$slug" >/dev/null 2>&1 \
    || die "gh pr checkout $pr failed in $slug"

  local branch; branch=$(git -C "$repo" rev-parse --abbrev-ref HEAD)
  ! is_protected "$repo" "$branch" || die "PR #$pr resolves to a protected branch ($branch)"
  # If the branch moved between poll and checkout, the review comment may describe code
  # that no longer exists. Report the sha and let the caller compare.
  echo "HEAD $(git -C "$repo" rev-parse HEAD) $branch"
}

cmd_restore() {
  local repo="${1:-}" branch="${2:-}"
  [ -n "$branch" ] || die "no branch to restore"
  git -C "$repo" checkout --quiet "$branch" 2>/dev/null \
    || { echo "WARNING could not return $repo to $branch" >&2; exit 1; }
  echo "RESTORED $branch"
}

cmd_push() {
  local repo="${1:-}"
  local branch; branch=$(git -C "$repo" rev-parse --abbrev-ref HEAD)
  [ "$branch" != "HEAD" ] || die "detached HEAD, refusing to push"
  ! is_protected "$repo" "$branch" || die "refusing to push a protected branch ($branch)"

  # Upstream first: the workflow check below diffs against it, and a check that cannot
  # run must block the push rather than be skipped over.
  git -C "$repo" rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1 \
    || die "no upstream for $branch"

  # A workflow change can rewrite what CI runs, which is how an automation escalates its
  # own permissions. It is out of scope here, always, regardless of who asked.
  if git -C "$repo" diff --name-only '@{upstream}'..HEAD | grep -q '^\.github/workflows/'; then
    die "commit touches .github/workflows/, which pr-follow never pushes"
  fi

  # Plain push only. A rejection means the remote moved and a human should look.
  git -C "$repo" push 2>&1 || die "push rejected for $branch (remote moved?)"
  echo "PUSHED $branch $(git -C "$repo" rev-parse --short HEAD)"
}

case "${1:-}" in
  guard)   shift; cmd_guard   "$@" ;;
  enter)   shift; cmd_enter   "$@" ;;
  restore) shift; cmd_restore "$@" ;;
  push)    shift; cmd_push    "$@" ;;
  *) echo "usage: act.sh {guard|enter|restore|push} ..." >&2; exit 2 ;;
esac
