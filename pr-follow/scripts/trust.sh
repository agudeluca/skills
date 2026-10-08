#!/bin/bash
# Authoritative answer to "may this person's comment cause a push?".
#
# poll.py already reports GitHub's authorAssociation, which is enough to triage. This is
# the check run immediately before acting: it asks the permission endpoint directly, so a
# stale or generous association cannot be the only thing standing between a drive-by
# comment and a commit. Defense in depth, one API call, only on the path that writes.
#
#   trust.sh check <owner/repo> <login>   -> prints TRUSTED|UNTRUSTED <permission>, exit 0|1
#   trust.sh clear                        -> drops the cache
set -uo pipefail

CACHE="${PR_FOLLOW_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/pr-follow}/trust"
TTL_SECONDS=${PR_FOLLOW_TRUST_TTL:-3600}

# Permissions that may direct a change. "read" and "none" may not: a reader can comment
# on a public repo, and that must never be the same thing as authorizing a commit.
is_trusted_permission() {
  case "$1" in admin|maintain|write) return 0 ;; *) return 1 ;; esac
}

cmd_check() {
  local repo="$1" login="$2"
  [ -n "$repo" ] && [ -n "$login" ] || { echo "usage: trust.sh check <owner/repo> <login>" >&2; return 2; }

  # Bots never direct changes, whatever their permission says. A failing check is a fact
  # to act on; the text a bot writes is not an instruction.
  case "$login" in
    *"[bot]"|github-actions|dependabot|renovate|sonarcloud|codecov|coderabbitai)
      echo "UNTRUSTED bot"; return 1 ;;
  esac

  mkdir -p "$CACHE"
  local key="$CACHE/$(echo "$repo/$login" | tr '/' '_')"
  if [ -f "$key" ]; then
    local age=$(( $(date +%s) - $(stat -f %m "$key" 2>/dev/null || stat -c %Y "$key") ))
    if [ "$age" -lt "$TTL_SECONDS" ]; then cat "$key"; grep -q '^TRUSTED' "$key"; return $?; fi
  fi

  local permission
  permission=$(gh api "repos/$repo/collaborators/$login/permission" \
                 --jq '.permission' 2>/dev/null)
  # A 404 here means "not a collaborator", which is a real answer, not a failure.
  [ -n "$permission" ] || permission="none"

  local verdict
  if is_trusted_permission "$permission"; then verdict="TRUSTED $permission"
  else verdict="UNTRUSTED $permission"; fi

  printf '%s\n' "$verdict" | tee "$key"
  is_trusted_permission "$permission"
}

case "${1:-}" in
  check) shift; cmd_check "${1:-}" "${2:-}" ;;
  clear) rm -rf "$CACHE" && echo "trust cache cleared" ;;
  *) echo "usage: trust.sh {check <owner/repo> <login>|clear}" >&2; exit 2 ;;
esac
