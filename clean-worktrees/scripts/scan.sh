#!/usr/bin/env bash
# clean-worktrees/scripts/scan.sh — inventory every linked git worktree under the given roots.
#
# READ-ONLY. Never prunes, removes, fetches or touches anything.
#
# Usage:   scan.sh [ROOT ...]              default ROOT: ~/projects
# Output:  one TSV line per linked worktree (the main checkout of each repo is never listed):
#          repo <TAB> worktree <TAB> branch <TAB> status <TAB> detail
#
#   status    meaning                                                  safe to remove?
#   --------  -------------------------------------------------------  ------------------------------
#   CLEAN     no local changes; every commit is on the remote or        yes
#             already contained in the default branch
#   UNPUSHED  no local changes, but commits that exist nowhere else     only if the user says so
#   DIRTY     uncommitted or untracked files                            never without explicit confirmation
#   LOCKED    `git worktree lock` is set                                no — someone asked git to keep it
#   PRUNABLE  registered in git but the directory is gone               yes, via `git worktree prune`
#
# Compatible with the bash 3.2 that ships with macOS.
set -uo pipefail

roots=("$@")
[ ${#roots[@]} -eq 0 ] && roots=("$HOME/projects")

# Directory names that are never a repo we care about and are slow to walk.
prune_names=(node_modules .worktrees Pods .build vendor .venv venv .gradle DerivedData Library .Trash)
prune_expr=( -name "${prune_names[0]}" )
for n in "${prune_names[@]:1}"; do prune_expr+=( -o -name "$n" ); done

# A main checkout has a .git DIRECTORY; linked worktrees have a .git FILE, so this only finds main repos.
find_repos() {
  local root=$1
  [ -d "$root" ] || { echo "scan.sh: skipping, not a directory: $root" >&2; return 0; }
  find "$root" -maxdepth 6 \( "${prune_expr[@]}" \) -prune -o -type d -name .git -print -prune 2>/dev/null \
    | sed 's#/\.git$##'
}

# origin/HEAD if git knows it, else the first of origin/main|master|develop that exists.
default_branch() {
  local repo=$1 ref c
  ref=$(git -C "$repo" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null) && { echo "$ref"; return; }
  for c in origin/main origin/master origin/develop; do
    git -C "$repo" show-ref -q --verify "refs/remotes/$c" && { echo "$c"; return; }
  done
  echo ""
}

classify() {
  local repo=$1 wt=$2 head=$3 branch=$4 locked=$5 prunable=$6 base=$7
  local status detail changes upstream ahead
  if [ -n "$prunable" ] || [ ! -d "$wt" ]; then
    status=PRUNABLE; detail="directory is gone; git worktree prune"
  elif [ -n "$locked" ]; then
    status=LOCKED; detail="locked; git worktree unlock first"
  else
    changes=$(git -C "$wt" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    if [ "${changes:-0}" -gt 0 ]; then
      status=DIRTY; detail="$changes changed/untracked file(s)"
    else
      upstream=$(git -C "$wt" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)
      if [ -n "$upstream" ] && git -C "$wt" rev-parse -q --verify "$upstream" >/dev/null 2>&1; then
        ahead=$(git -C "$wt" rev-list --count "$upstream..HEAD" 2>/dev/null || echo "?")
        if [ "$ahead" = "0" ]; then status=CLEAN; detail="in sync with $upstream"
        else status=UNPUSHED; detail="$ahead commit(s) ahead of $upstream"; fi
      elif [ -n "$base" ]; then
        if git -C "$repo" merge-base --is-ancestor "$head" "$base" 2>/dev/null; then
          status=CLEAN; detail="no upstream, but HEAD is already in $base"
        else
          ahead=$(git -C "$repo" rev-list --count "$base..$head" 2>/dev/null || echo "?")
          status=UNPUSHED; detail="no upstream; $ahead commit(s) not in $base"
        fi
      else
        status=UNPUSHED; detail="no upstream and no default branch to compare against"
      fi
    fi
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$repo" "$wt" "$branch" "$status" "$detail"
}

scan_repo() {
  local repo=$1 base
  base=$(default_branch "$repo")
  local wt="" head="" branch="" locked="" prunable="" first=1 line
  # `worktree list --porcelain` prints blank-line-separated blocks; the extra echo flushes the last one.
  { git -C "$repo" worktree list --porcelain 2>/dev/null; echo; } | while IFS= read -r line; do
    case "$line" in
      "worktree "*) wt=${line#worktree } ;;
      "HEAD "*)     head=${line#HEAD } ;;
      "branch "*)   branch=${line#branch refs/heads/} ;;
      detached)     branch="(detached)" ;;
      locked*)      locked=1 ;;
      prunable*)    prunable=1 ;;
      "")
        if [ -n "$wt" ]; then
          if [ $first -eq 1 ]; then first=0          # first block is the main checkout: never listed
          else classify "$repo" "$wt" "$head" "$branch" "$locked" "$prunable" "$base"; fi
        fi
        wt="" head="" branch="" locked="" prunable=""
        ;;
    esac
  done
}

repos=()
while IFS= read -r r; do [ -n "$r" ] && repos+=("$r"); done < <(
  for root in "${roots[@]}"; do find_repos "$root"; done | sort -u
)

found=0
if [ ${#repos[@]} -gt 0 ]; then
  for repo in "${repos[@]}"; do
    while IFS= read -r line; do printf '%s\n' "$line"; found=$((found + 1)); done < <(scan_repo "$repo")
  done
fi
echo "scan.sh: ${#repos[@]} repo(s) scanned under: ${roots[*]} — ${found} linked worktree(s) found" >&2
