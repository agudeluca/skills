#!/usr/bin/env bash
# agent-registry/scripts/test_registry.sh — exercises registry.sh against a throwaway store.
#
# Every case runs with CLAUDE_SHARED_DIR pointed at a temp directory, so the real
# ~/.claude-shared is never read or written.
#
# Faking a session's process: macOS reports the *executable path* in `ps -o comm=` (not argv[0],
# so `exec -a` does not help; not the script name, so a shebang file named "claude" reports its
# interpreter) and the kernel SIGKILLs copies of platform binaries. A process genuinely named
# "claude" therefore cannot be created, so the suite sets CLAUDE_REGISTRY_PROC_NAME=sh and uses
# `/bin/sh -c '… & wait'` as the stand-in agent — a real process, with real children, that stays
# alive. The ladder logic is name-agnostic, so this exercises it exactly.
#
# That the real binary does report "claude" was verified directly against a live session
# (pid 72680 -> /Users/agustindeluca/.local/bin/claude) and is not re-checked here.
#
# Compatible with the bash 3.2 that ships with macOS.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REG_SH="$HERE/registry.sh"
export CLAUDE_REGISTRY_PROC_NAME=sh
PASS=0; FAIL=0

ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }
has()  { if printf '%s' "$2" | grep -q -- "$3"; then ok "$1"; else bad "$1" "[$3] not in: $(printf '%s' "$2" | head -3)"; fi; }
hasnt(){ if printf '%s' "$2" | grep -q -- "$3"; then bad "$1" "[$3] unexpectedly present"; else ok "$1"; fi; }

iso_ago() { date -u -v-"$1" +%Y-%m-%dT%H:%M:%SZ; }
count_records() { ls "$STORE/agents"/*.json 2>/dev/null | grep -c . || true; }

# record SID PID UPDATED_AGO [LEASES_JSON] — written straight to the store, no hook involved.
record() {
  mkdir -p "$STORE/agents"
  jq -n --arg sid "$1" --arg pid "$2" --arg up "$(iso_ago "$3")" \
        --arg st "$(iso_ago 4H)" --argjson leases "${4:-[]}" '
    { session_id: $sid, pid: ($pid | tonumber), config_dir: "", alias: "test",
      cwd: "/tmp", repo: ("repo-" + $sid), branch: "main",
      started_at: $st, updated_at: $up, intent: ("intent-" + $sid), leases: $leases }' \
    > "$STORE/agents/$1.json"
}

setup() {
  STORE=$(mktemp -d -t arstore)
  export CLAUDE_SHARED_DIR="$STORE"
  mkdir -p "$STORE/agents" "$STORE/nojq"
  # Everything on PATH except jq, so "jq is missing" is the only difference. A bare empty PATH
  # would instead break `#!/usr/bin/env bash` itself and exit 127 for the wrong reason.
  local f b
  for f in /bin/* /usr/bin/*; do
    b=${f##*/}
    [ "$b" = jq ] && continue
    ln -sf "$f" "$STORE/nojq/$b" 2>/dev/null
  done
  # Helper the stand-in agent runs to register itself with its own PID.
  cat > "$STORE/selfreg.sh" <<'INNER'
#!/bin/sh
# selfreg.sh STORE SID — write a record for the calling process.
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
jq -n --arg sid "$2" --arg pid "$PPID" --arg now "$now" \
  '{ session_id: $sid, pid: ($pid | tonumber), config_dir: "", alias: "test",
     cwd: "/tmp", repo: ("repo-" + $sid), branch: "main",
     started_at: $now, updated_at: $now, intent: null, leases: [] }' > "$1/agents/$2.json"
INNER
  chmod +x "$STORE/selfreg.sh"
}
teardown() {
  [ -n "${FAKE_PID:-}" ] && kill "$FAKE_PID" 2>/dev/null
  [ -n "${STORE:-}" ] && rm -rf "$STORE"
  FAKE_PID=""
}

# Start a stand-in agent that stays alive and runs $1 as a shell snippet inside itself.
spawn_agent() { /bin/sh -c "$1" & FAKE_PID=$!; disown "$FAKE_PID" 2>/dev/null; sleep 0.4; }

# Poll for a file the agent touches, so a case never depends on a fixed sleep being long enough.
await_file() { local i=0; while [ ! -f "$1" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done; }

echo "registry.sh"

# ---- 1. a dead PID is reaped
setup
sleep 60 & dead=$!; disown "$dead" 2>/dev/null; kill "$dead" 2>/dev/null
record dead "$dead" 1M
"$REG_SH" reap >/dev/null
check "a record whose PID is gone is reaped" "$(count_records)" "0"
teardown

# ---- 2. a live PID running something else is reaped as a recycled PID
setup
sleep 60 & FAKE_PID=$!; disown "$FAKE_PID" 2>/dev/null   # comm=sleep, not the expected name
record recycled "$FAKE_PID" 1M
"$REG_SH" reap >/dev/null
check "a PID alive but not an agent is reaped as recycled" "$(count_records)" "0"
teardown

# ---- 3. a live agent idle past the TTL is stale, and its leases read as free
setup
spawn_agent 'sleep 60 & wait'
record idle "$FAKE_PID" 3H '[{"kind":"ios-simulator","id":"ABC","note":null,"since":"2026-10-06T07:00:00Z"}]'
out=$("$REG_SH" list)
check "a session idle past the TTL survives the reap" "$(count_records)" "1"
has   "it is listed as stale"                          "$out" "stale"
has   "its lease is reported free"                     "$out" "free — session idle >2h"
teardown

# ---- 4. a live agent with a fresh timestamp keeps both leases
setup
spawn_agent 'sleep 60 & wait'
record fresh "$FAKE_PID" 1M '[{"kind":"metro","id":"8081","note":null,"since":"2026-10-06T10:00:00Z"},{"kind":"ios-simulator","id":"XYZ","note":"iPhone 16","since":"2026-10-06T10:00:00Z"}]'
out=$("$REG_SH" list)
has   "a fresh session is listed live"              "$out" "live"
has   "its first lease is listed"                   "$out" "metro=8081"
has   "its second lease is listed"                  "$out" "ios-simulator=XYZ"
hasnt "a live session's leases are not marked free" "$out" "free — session idle"
teardown

# ---- 5. a corrupt record is skipped without hiding the others
setup
spawn_agent 'sleep 60 & wait'
record good "$FAKE_PID" 1M
printf '{"session_id": "trunc", "pid": 12' > "$STORE/agents/trunc.json"
out=$("$REG_SH" list); rc=$?
has   "a valid record is listed next to a corrupt one" "$out" "repo-good"
check "list exits 0 despite a corrupt record"          "$rc" "0"
teardown

# ---- 6. an empty registry prints nothing and exits 0
setup
out=$("$REG_SH" digest); rc=$?
check "digest on an empty registry exits 0"   "$rc" "0"
check "digest on an empty registry is silent" "$out" ""
teardown

# ---- 7. without jq every subcommand is a silent no-op
setup
spawn_agent 'sleep 60 & wait'
record present "$FAKE_PID" 1M
while read -r c; do
  [ -n "$c" ] || continue
  out=$(env PATH="$STORE/nojq" "$REG_SH" $c 2>/dev/null </dev/null); rc=$?
  check "jq missing: '$c' exits 0"   "$rc" "0"
  check "jq missing: '$c' is silent" "$out" ""
done <<'CMDS'
start
touch
end
digest
list
ports
reap
claim metro 8081
release metro 8081
CMDS
check "jq missing: the record is left untouched" "$(count_records)" "1"
teardown

# ---- 8. two concurrent claims on one record keep both leases
setup
spawn_agent "\"$STORE/selfreg.sh\" \"$STORE\" conc; \
  { \"$REG_SH\" claim metro 8081 >/dev/null & \"$REG_SH\" claim ios-simulator XYZ >/dev/null & wait; }; \
  touch \"$STORE/done\"; sleep 20"
await_file "$STORE/done"
leases=$(jq -c '.leases | map(.kind) | sort' "$STORE/agents/conc.json" 2>/dev/null)
check "two concurrent claims both survive" "$leases" '["ios-simulator","metro"]'
teardown

# ---- 9. release removes what claim added
# Both run inside the same stand-in agent: release finds its record by walking up to its own
# process, so a second agent with a different PID would not resolve to this record at all.
setup
spawn_agent "\"$STORE/selfreg.sh\" \"$STORE\" rel; \
  \"$REG_SH\" claim metro 8081 >/dev/null; cp \"$STORE/agents/rel.json\" \"$STORE/after-claim.json\"; \
  \"$REG_SH\" release metro 8081 >/dev/null; touch \"$STORE/done\"; sleep 20"
await_file "$STORE/done"
check "claim records the lease"    "$(jq -c '.leases | map(.kind)' "$STORE/after-claim.json" 2>/dev/null)" '["metro"]'
check "release removes the lease"  "$(jq -c '.leases' "$STORE/agents/rel.json" 2>/dev/null)" '[]'
teardown

# ---- 10. a listening port is attributed to the agent that owns the process holding it
setup
port=$(jot -r 1 42000 42999 2>/dev/null || echo 42123)
spawn_agent "\"$STORE/selfreg.sh\" \"$STORE\" owner; nc -l 127.0.0.1 $port >/dev/null 2>&1 & sleep 20"
sleep 1.0
out=$("$REG_SH" ports)
has "a listening port is attributed to its owning agent" "$out" "^$port.*test/repo-owner"
teardown

# ---- 11. a port with no agent in its chain is reported unowned
setup
port=$(jot -r 1 43000 43999 2>/dev/null || echo 43123)
nc -l 127.0.0.1 "$port" >/dev/null 2>&1 & FAKE_PID=$!; disown "$FAKE_PID" 2>/dev/null
sleep 0.8
out=$("$REG_SH" ports)
has "a port held outside any agent is reported unowned" "$out" "^$port[[:space:]]*-"
teardown

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
