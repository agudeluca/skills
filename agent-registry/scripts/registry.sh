#!/usr/bin/env bash
# agent-registry/scripts/registry.sh — shared status of every Claude agent on this machine.
#
# One JSON record per live session under $CLAUDE_SHARED_DIR/agents/, readable by both config dirs
# (clauder -> ~/.claude, claudepr -> ~/.claude-personal) which otherwise share nothing.
#
# Stores only what cannot be derived. Liveness comes from the kernel (kill -0 on the session's
# claude PID), port ownership from walking a listening socket's parent chain to its registered
# claude ancestor. The 2h TTL is a backstop for reboots and recycled PIDs, not the first check,
# and what it expires is a lease, never the session.
#
# Usage:
#   registry.sh start                     SessionStart hook: register this session, print the digest
#   registry.sh touch                     Stop hook: refresh updated_at
#   registry.sh end                       SessionEnd hook: drop this session's record
#   registry.sh digest                    compact view of the OTHER agents, for a session's context
#   registry.sh list                      full table, for a human
#   registry.sh claim KIND ID [NOTE]      take a lease on a process-less resource
#   registry.sh release KIND ID           give it back
#   registry.sh ports                     listening ports with the agent that owns them, derived
#   registry.sh reap                      drop records whose process is gone
#
# This is an optimisation, never a dependency: every path exits 0, and a missing jq disables it
# silently rather than failing a session start.
#
# Compatible with the bash 3.2 that ships with macOS.
set -uo pipefail

REG_ROOT="${CLAUDE_SHARED_DIR:-$HOME/.claude-shared}"
REG_DIR="$REG_ROOT/agents"
TTL_SECONDS="${CLAUDE_REGISTRY_TTL:-7200}"   # 2h — after this a session's LEASES are free, not the session
LOCK_STALE_SECONDS=60

# The executable name a session's process is expected to have. Overridable only so the test suite
# can stand in a process it is allowed to spawn: macOS reports the executable path in `ps -o comm=`
# and kills copies of platform binaries, so a process genuinely named "claude" cannot be faked.
PROC_NAME="${CLAUDE_REGISTRY_PROC_NAME:-claude}"

# ---------------------------------------------------------------- primitives

have_jq() { command -v jq >/dev/null 2>&1; }

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ISO-8601 Zulu -> epoch seconds. Empty on anything unparseable.
iso_epoch() {
  [ -n "${1:-}" ] || return 1
  date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null
}

human_dur() {
  local s="${1:-0}"
  [ "$s" -lt 0 ] 2>/dev/null && s=0
  if   [ "$s" -lt 60 ];    then printf '%ds' "$s"
  elif [ "$s" -lt 3600 ];  then printf '%dm' $((s / 60))
  elif [ "$s" -lt 86400 ]; then printf '%dh %dm' $((s / 3600)) $(((s % 3600) / 60))
  else                          printf '%dd %dh' $((s / 86400)) $(((s % 86400) / 3600))
  fi
}

# Basename of a PID's executable, first word only. macOS `ps -o comm=` sometimes returns the
# whole command line, so take field 1 before stripping the path.
proc_name() {
  local c
  c=$(ps -o comm= -p "${1:-0}" 2>/dev/null) || return 1
  [ -n "$c" ] || return 1
  c=${c%% *}
  printf '%s\n' "${c##*/}"
}

parent_of() { ps -o ppid= -p "${1:-0}" 2>/dev/null | tr -d ' '; }

is_claude() { [ "$(proc_name "${1:-0}" 2>/dev/null)" = "$PROC_NAME" ]; }

# Walk up from this script to the claude process that owns the session. Empty if there is none,
# which is what happens when a human runs the CLI from their own shell.
resolve_claude_pid() {
  local pid=$$ hops=0
  while [ -n "$pid" ] && [ "$pid" != "0" ] && [ "$pid" != "1" ] && [ "$hops" -lt 40 ]; do
    if is_claude "$pid"; then printf '%s\n' "$pid"; return 0; fi
    pid=$(parent_of "$pid")
    hops=$((hops + 1))
  done
  return 1
}

# Write stdin to $1 through a temp file in the same directory, so a reader never sees a partial
# record. rename() is atomic on APFS.
atomic_write() {
  local dest="$1" tmp rc
  tmp="$dest.tmp.$$"
  if ! cat > "$tmp" 2>/dev/null; then rm -f "$tmp" 2>/dev/null; return 1; fi
  mv -f "$tmp" "$dest" 2>/dev/null
  rc=$?
  [ "$rc" -eq 0 ] || rm -f "$tmp" 2>/dev/null
  return "$rc"
}

# mkdir is an atomic mutex and, unlike a lockfile, obviously stale when its holder dies. We give
# up after ~2.5s and proceed unlocked: losing a concurrent lease beats hanging a turn.
with_lock() {
  local lock="$1"; shift
  local i=0 held=0
  if [ -d "$lock" ] && [ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
    rm -rf "$lock" 2>/dev/null
  fi
  while [ "$i" -lt 50 ]; do
    if mkdir "$lock" 2>/dev/null; then held=1; break; fi
    i=$((i + 1))
    sleep 0.05
  done
  "$@"
  local rc=$?
  [ "$held" -eq 1 ] && rm -rf "$lock" 2>/dev/null
  return "$rc"
}

ensure_dir() { mkdir -p "$REG_DIR" 2>/dev/null; }

alias_for() {
  case "${1:-}" in
    "$HOME/.claude")          printf 'clauder\n' ;;
    "$HOME/.claude-personal") printf 'claudepr\n' ;;
    "")                       printf '?\n' ;;
    *)                        printf '%s\n' "$(basename "${1}")" ;;
  esac
}

# ---------------------------------------------------------------- snapshot

# The liveness ladder, applied to every record on every read:
#   1. kill -0 fails                      -> dead, reap
#   2. PID alive but not claude           -> recycled PID, reap
#   3. alive, claude, updated_at > TTL    -> stale: session shown, leases treated as free
#   4. otherwise                          -> live
#
# Reaps as it goes, so the registry self-cleans without a daemon. Corrupt records are skipped,
# never fatal.
#
# Fields are joined with \x1f rather than a tab: bash treats tab as whitespace in IFS and collapses
# runs of it, so an empty field (a session with no branch or no intent) would silently shift every
# later column left. \x1f is not whitespace, so empty fields survive. Agent-written text also has
# its newlines flattened, since the output is read a line at a time.
#
# Prints: session_id pid alias repo branch status started_age updated_age intent leases_json
SEP=$'\x1f'
snapshot() {
  ensure_dir
  local f rec sid pid al repo br started updated intent leases status now age uage
  now=$(date -u +%s)
  for f in "$REG_DIR"/*.json; do
    [ -e "$f" ] || continue
    rec=$(jq -r '
      def flat: tostring | gsub("[\n\r\u001f]"; " ");
      [ (.session_id // ""), ((.pid // "") | tostring), (.alias // ""), (.repo // ""),
        (.branch // ""), (.started_at // ""), (.updated_at // ""), ((.intent // "") | flat),
        ((.leases // []) | tojson) ] | join("\u001f")' "$f" 2>/dev/null) || continue
    [ -n "$rec" ] || continue
    IFS="$SEP" read -r sid pid al repo br started updated intent leases <<<"$rec"
    [ -n "${sid:-}" ] || continue

    if [ -n "${pid:-}" ] && [ "$pid" != "null" ]; then
      if ! kill -0 "$pid" 2>/dev/null; then
        rm -f "$f" 2>/dev/null; continue                       # rule 1
      fi
      if ! is_claude "$pid"; then
        rm -f "$f" 2>/dev/null; continue                       # rule 2
      fi
    fi

    uage=$(( now - $(iso_epoch "$updated" 2>/dev/null || echo "$now") ))
    age=$(( now - $(iso_epoch "$started" 2>/dev/null || echo "$now") ))
    if [ "$uage" -gt "$TTL_SECONDS" ]; then status=stale; else status=live; fi

    printf '%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s\n' \
      "$sid" "$SEP" "${pid:-}" "$SEP" "${al:-?}" "$SEP" "${repo:-?}" "$SEP" "${br:-}" "$SEP" \
      "$status" "$SEP" "$age" "$SEP" "$uage" "$SEP" "${intent:-}" "$SEP" "${leases:-[]}"
  done
}

# Path of this session's own record, found by matching our claude PID against the records rather
# than by guessing a session id — the agent's Bash tool is a descendant of its own claude process.
own_record() {
  local mypid f p
  mypid=$(resolve_claude_pid) || return 1
  ensure_dir
  for f in "$REG_DIR"/*.json; do
    [ -e "$f" ] || continue
    p=$(jq -r '.pid // empty' "$f" 2>/dev/null) || continue
    if [ "$p" = "$mypid" ]; then printf '%s\n' "$f"; return 0; fi
  done
  return 1
}

# ---------------------------------------------------------------- derived ports

# Every listening socket, attributed to the agent whose claude process is an ancestor of the
# process holding it. Needs no cooperation from any agent and cannot go stale.
# Prints TSV: port owner   (owner is "-" when no registered agent is in the chain)
ports_tsv() {
  local tmp_ps tmp_own tmp_sock
  tmp_ps=$(mktemp -t ar_ps) || return 0
  tmp_own=$(mktemp -t ar_own) || { rm -f "$tmp_ps"; return 0; }
  tmp_sock=$(mktemp -t ar_sock) || { rm -f "$tmp_ps" "$tmp_own"; return 0; }

  ps -eo pid=,ppid=,comm= > "$tmp_ps" 2>/dev/null
  snapshot | awk -F"$SEP" '$2 != "" { printf "%s\t%s/%s\n", $2, $3, $4 }' > "$tmp_own" 2>/dev/null
  lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null \
    | awk 'NR > 1 { n = $9; sub(/.*:/, "", n); if (n ~ /^[0-9]+$/) print $2 "\t" n }' > "$tmp_sock" 2>/dev/null

  awk -v psf="$tmp_ps" -v ownf="$tmp_own" -v sockf="$tmp_sock" '
    BEGIN {
      while ((getline l < psf)   > 0) { split(l, a, " ");  if (a[1] != "") parent[a[1]] = a[2] }
      while ((getline l < ownf)  > 0) { split(l, b, "\t"); if (b[1] != "") owner[b[1]]  = b[2] }
      while ((getline l < sockf) > 0) {
        split(l, c, "\t"); pid = c[1]; port = c[2]
        p = pid; hops = 0; own = ""
        while (p != "" && p != "0" && p != "1" && hops < 40) {
          if (p in owner) { own = owner[p]; break }
          p = parent[p]; hops++
        }
        if (own == "") own = "-"
        key = port "|" own
        if (!(key in seen)) { seen[key] = 1; print port "\t" own }
      }
    }
  ' 2>/dev/null | sort -n -u

  rm -f "$tmp_ps" "$tmp_own" "$tmp_sock" 2>/dev/null
}

# ---------------------------------------------------------------- write side

cmd_start() {
  have_jq || return 0
  ensure_dir
  local hook sid cwd pid cfg al repo br top prev started intent leases rec

  hook=$(read_hook_json)
  sid=$(printf '%s' "$hook"  | jq -r '.session_id // empty' 2>/dev/null)
  cwd=$(printf '%s' "$hook"  | jq -r '.cwd // empty' 2>/dev/null)
  [ -n "$cwd" ] || cwd="$PWD"
  pid=$(resolve_claude_pid || true)
  [ -n "$sid" ] || sid="pid-${pid:-$$}"

  cfg="${CLAUDE_CONFIG_DIR:-}"
  al=$(alias_for "$cfg")
  top=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)
  if [ -n "$top" ]; then repo=$(basename "$top"); else repo=$(basename "$cwd"); fi
  br=$(git -C "$cwd" branch --show-current 2>/dev/null)

  # SessionStart also fires on resume, clear and compact, so carry over what the agent wrote.
  rec="$REG_DIR/$sid.json"
  started=""; intent=""; leases="[]"
  if [ -f "$rec" ]; then
    prev=$(cat "$rec" 2>/dev/null)
    started=$(printf '%s' "$prev" | jq -r  '.started_at // empty' 2>/dev/null)
    intent=$(printf  '%s' "$prev" | jq -r  '.intent // empty'     2>/dev/null)
    leases=$(printf  '%s' "$prev" | jq -c  '.leases // []'        2>/dev/null)
    [ -n "$leases" ] || leases="[]"
  fi
  [ -n "$started" ] || started=$(now_iso)

  jq -n --arg sid "$sid" --arg pid "${pid:-}" --arg cfg "$cfg" --arg al "$al" \
        --arg cwd "$cwd" --arg repo "$repo" --arg br "$br" \
        --arg started "$started" --arg now "$(now_iso)" --arg intent "$intent" \
        --argjson leases "$leases" '
    { session_id: $sid,
      pid:        (if $pid == "" then null else ($pid | tonumber) end),
      config_dir: $cfg,
      alias:      $al,
      cwd:        $cwd,
      repo:       $repo,
      branch:     (if $br == "" then null else $br end),
      started_at: $started,
      updated_at: $now,
      intent:     (if $intent == "" then null else $intent end),
      leases:     $leases }' 2>/dev/null | atomic_write "$rec"

  cmd_digest
}

cmd_touch() {
  have_jq || return 0
  local hook sid rec
  hook=$(read_hook_json)
  sid=$(printf '%s' "$hook" | jq -r '.session_id // empty' 2>/dev/null)
  if [ -n "$sid" ] && [ -f "$REG_DIR/$sid.json" ]; then
    rec="$REG_DIR/$sid.json"
  else
    rec=$(own_record) || return 0
  fi
  jq --arg now "$(now_iso)" '.updated_at = $now' "$rec" 2>/dev/null | atomic_write "$rec"
  return 0
}

cmd_end() {
  have_jq || return 0
  local hook sid rec
  hook=$(read_hook_json)
  sid=$(printf '%s' "$hook" | jq -r '.session_id // empty' 2>/dev/null)
  if [ -n "$sid" ] && [ -f "$REG_DIR/$sid.json" ]; then
    rm -f "$REG_DIR/$sid.json" 2>/dev/null
  else
    rec=$(own_record) && rm -f "$rec" 2>/dev/null
  fi
  return 0
}

# Hooks deliver their payload as JSON on stdin. The same script is run by hand from a terminal,
# where reading stdin would hang, so only read it when something is actually piped in.
read_hook_json() {
  if [ -t 0 ]; then printf '{}'; return 0; fi
  local j
  j=$(cat 2>/dev/null)
  if [ -n "$j" ]; then printf '%s' "$j"; else printf '{}'; fi
}

_write_lease() {
  local rec="$1" kind="$2" id="$3" note="$4"
  jq --arg k "$kind" --arg i "$id" --arg n "$note" --arg now "$(now_iso)" '
    .leases = ((.leases // []) | map(select(.kind != $k or .id != $i)))
            + [ { kind: $k, id: $i, note: (if $n == "" then null else $n end), since: $now } ]
    | .updated_at = $now' "$rec" 2>/dev/null | atomic_write "$rec"
}

_drop_lease() {
  local rec="$1" kind="$2" id="$3"
  jq --arg k "$kind" --arg i "$id" --arg now "$(now_iso)" '
    .leases = ((.leases // []) | map(select(.kind != $k or .id != $i)))
    | .updated_at = $now' "$rec" 2>/dev/null | atomic_write "$rec"
}

# Self-heals: a session that started before the hooks were installed has no record, so make a
# minimal one keyed by PID rather than silently dropping the lease.
_own_or_create() {
  local rec pid
  if rec=$(own_record); then printf '%s\n' "$rec"; return 0; fi
  pid=$(resolve_claude_pid) || return 1
  ensure_dir
  rec="$REG_DIR/pid-$pid.json"
  jq -n --arg pid "$pid" --arg al "$(alias_for "${CLAUDE_CONFIG_DIR:-}")" --arg cwd "$PWD" \
        --arg repo "$(basename "$PWD")" --arg now "$(now_iso)" '
    { session_id: ("pid-" + $pid), pid: ($pid | tonumber), config_dir: "", alias: $al,
      cwd: $cwd, repo: $repo, branch: null, started_at: $now, updated_at: $now,
      intent: null, leases: [] }' 2>/dev/null | atomic_write "$rec" || return 1
  printf '%s\n' "$rec"
}

cmd_claim() {
  have_jq || return 0
  local kind="${1:-}" id="${2:-}" note="${3:-}" rec
  if [ -z "$kind" ] || [ -z "$id" ]; then
    echo "usage: registry.sh claim KIND ID [NOTE]" >&2; return 0
  fi
  rec=$(_own_or_create) || { echo "registry: no session record to claim against" >&2; return 0; }
  with_lock "$rec.lock" _write_lease "$rec" "$kind" "$id" "$note"
  printf 'claimed %s %s\n' "$kind" "$id"
}

cmd_release() {
  have_jq || return 0
  local kind="${1:-}" id="${2:-}" rec
  if [ -z "$kind" ] || [ -z "$id" ]; then
    echo "usage: registry.sh release KIND ID" >&2; return 0
  fi
  rec=$(own_record) || return 0
  with_lock "$rec.lock" _drop_lease "$rec" "$kind" "$id"
  printf 'released %s %s\n' "$kind" "$id"
}

cmd_intent() {
  have_jq || return 0
  local text="$*" rec
  rec=$(_own_or_create) || return 0
  jq --arg t "$text" --arg now "$(now_iso)" \
     '.intent = (if $t == "" then null else $t end) | .updated_at = $now' "$rec" 2>/dev/null \
     | atomic_write "$rec"
  return 0
}

# ---------------------------------------------------------------- read side

cmd_reap() { have_jq || return 0; snapshot >/dev/null; return 0; }

# Compact view of the OTHER agents, written to a session's context by the SessionStart hook.
# Silent when this machine has nothing else running — an empty registry prints nothing.
cmd_digest() {
  have_jq || return 0
  local mypid snap others nlive nstale
  mypid=$(resolve_claude_pid || true)
  snap=$(snapshot)
  [ -n "$snap" ] || return 0

  others=$(printf '%s\n' "$snap" | awk -F"$SEP" -v me="${mypid:-none}" '$2 != me')
  [ -n "$others" ] || return 0

  nlive=$(printf  '%s\n' "$others" | awk -F"$SEP" '$6 == "live"'  | grep -c . || true)
  nstale=$(printf '%s\n' "$others" | awk -F"$SEP" '$6 == "stale"' | grep -c . || true)

  printf 'Other Claude agents on this machine: %s live, %s stale (>2h idle).\n' "$nlive" "$nstale"
  printf '%s\n' "$others" | while IFS="$SEP" read -r sid pid al repo br st age uage intent leases; do
    printf '  %-9s %-22s %-24s %-8s %s%s\n' \
      "$al" "$repo" "${br:--}" "$(human_dur "$age")" \
      "$([ "$st" = stale ] && printf '[stale] ' || true)" "${intent:-}"
  done

  local owned
  owned=$(ports_tsv | awk -F'\t' '$2 != "-" { printf "%s(%s) ", $1, $2 }')
  [ -n "$owned" ] && printf 'Ports held by agents: %s\n' "$owned"

  local held
  held=$(printf '%s\n' "$others" | awk -F"$SEP" '$6 == "live" && $10 != "[]" { print $3"/"$4"\t"$10 }' \
         | while IFS=$'\t' read -r who js; do
             printf '%s' "$js" | jq -j --arg w "$who" '.[] | "\($w):\(.kind)=\(.id) "' 2>/dev/null
           done)
  [ -n "$held" ] && printf 'Leases held: %s\n' "$held"

  printf 'Before binding a port, run `lsof -nP -iTCP -sTCP:LISTEN` — this digest is a snapshot, not permission.\n'
  return 0
}

cmd_list() {
  have_jq || return 0
  local snap
  snap=$(snapshot)
  if [ -z "$snap" ]; then echo "No Claude agents registered."; return 0; fi

  printf '%-9s %-20s %-22s %-7s %-9s %-9s %s\n' ALIAS REPO BRANCH STATUS UP IDLE INTENT
  printf '%s\n' "$snap" | while IFS="$SEP" read -r sid pid al repo br st age uage intent leases; do
    printf '%-9s %-20s %-22s %-7s %-9s %-9s %s\n' \
      "$al" "$repo" "${br:--}" "$st" "$(human_dur "$age")" "$(human_dur "$uage")" "${intent:-}"
    printf '%s' "$leases" | jq -r --arg ttl "$st" '
      .[] | "            lease \(.kind)=\(.id)\(if .note then " (" + .note + ")" else "" end)"
            + (if $ttl == "stale" then "  [free — session idle >2h]" else "" end)' 2>/dev/null
  done

  local owned nother
  owned=$(ports_tsv | awk -F'\t' '$2 != "-"')
  nother=$(ports_tsv | awk -F'\t' '$2 == "-"' | grep -c . || true)
  echo
  if [ -n "$owned" ]; then
    printf '%-7s %s\n' PORT OWNER
    printf '%s\n' "$owned" | while IFS=$'\t' read -r port owner; do printf '%-7s %s\n' "$port" "$owner"; done
  else
    echo "No listening port belongs to a registered agent."
  fi
  printf '(%s more listening port(s) on this machine belong to no agent — `%s ports` lists them all)\n' \
    "$nother" "$(basename "$0")"
  return 0
}

cmd_ports() {
  have_jq || return 0
  printf '%-7s %s\n' PORT OWNER
  ports_tsv | while IFS=$'\t' read -r port owner; do printf '%-7s %s\n' "$port" "$owner"; done
  return 0
}

# ---------------------------------------------------------------- entry

main() {
  local cmd="${1:-list}"
  [ "$#" -gt 0 ] && shift
  case "$cmd" in
    start)    cmd_start ;;
    touch)    cmd_touch ;;
    end)      cmd_end ;;
    digest)   cmd_digest ;;
    list|"")  cmd_list ;;
    claim)    cmd_claim "$@" ;;
    release)  cmd_release "$@" ;;
    intent)   cmd_intent "$@" ;;
    ports)    cmd_ports ;;
    reap)     cmd_reap ;;
    -h|--help|help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//' ;;
    *)        echo "registry.sh: unknown command '$cmd' (try --help)" >&2 ;;
  esac
  return 0
}

main "$@"
exit 0
