#!/usr/bin/env bash
# =============================================================================
#  test-pigeonhole.sh - the blob transport, driven against a fake blob store
# =============================================================================
# A fake `curl` on PATH backs the drop with a temp directory, so the real
# pigeonhole.sh loop runs end to end with no network and no Azure. That is the
# only way to assert the properties that matter here, because every one of them
# is about what the agent does BETWEEN reading a request and writing a log.
#
# The env-line case is the reason this file exists. `env $ENV_EXTRA` unquoted
# looks like it handles `HOSTS="a b"` and does not: parameter expansion splits
# on spaces and performs no quote removal, so env is handed HOSTS="a and then
# treats b" as a command. It fails with exit 127 BEFORE run.sh starts, so there
# is no log at all - the worst shape a failure can take across a gap, because
# an unanswered request is indistinguishable from a step still running.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=assert.sh disable=SC1091
. "$HERE/assert.sh"
TOOLKIT="$(cd "$HERE/../skills/heliograph/toolkit" && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- a fake curl, backed by a directory ---------------------------------------
# It understands only the two calls pigeonhole.sh makes: a GET that writes a
# body to -o and prints an HTTP code, and a PUT that stores --data-binary. The
# URL's path after the host maps onto $STORE, and the query string is recorded
# so the SAS can be asserted on.
make_fake_curl() {
  local bin="$1" store="$2"
  mkdir -p "$bin"
  cat > "$bin/curl" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
STORE="${FAKE_STORE:?}"
out=""; method="GET"; data=""; url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -X) method="$2"; shift 2 ;;
    --data-binary) data="${2#@}"; shift 2 ;;
    -H) shift 2 ;;
    -w) shift 2 ;;
    -sS|-fsS|-s|-S|-f) shift ;;
    https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
path="${url#https://*.blob.core.windows.net/}"
query="${path#*\?}"; path="${path%%\?*}"
printf '%s\n' "$query" >> "$STORE/.queries"
target="$STORE/$path"
if [ "$method" = "PUT" ]; then
  mkdir -p "$(dirname "$target")"
  cp "$data" "$target"
  printf '201'
else
  if [ -f "$target" ]; then
    [ -n "$out" ] && cp "$target" "$out"
    printf '200'
  else
    printf '404'
  fi
fi
FAKE
  chmod +x "$bin/curl"
}

# --- a transport repo the agent can actually run ------------------------------
# A copy of the toolkit plus one step that prints the environment it was given,
# which is what the env-line assertions read.
make_repo() {
  local repo="$1"
  mkdir -p "$repo/steps" "$repo/lib" "$repo/ops-logs"
  cp "$TOOLKIT/pigeonhole.sh" "$TOOLKIT/caplib.sh" "$TOOLKIT/run.sh" "$repo/"
  cp "$TOOLKIT/lib/probe.sh" "$repo/lib/" 2>/dev/null || true
  chmod +x "$repo/pigeonhole.sh" "$repo/run.sh"
  cat > "$repo/steps/echo-env.sh" <<'STEP'
#!/usr/bin/env bash
set -uo pipefail
echo "HOSTS=[${HOSTS:-}]"
echo "PORTS=[${PORTS:-}]"
echo "CONFIRM=[${CONFIRM:-}]"
STEP
  chmod +x "$repo/steps/echo-env.sh"
  # Register it. A test branch adding a step is exactly what run.sh's own
  # comment invites, and doing it with sed keeps the shipped table untouched.
  sed -i 's|^  env)  CMD=(./steps/env-snapshot.sh) ;;|  env)  CMD=(./steps/env-snapshot.sh) ;;\n  echo-env) CMD=(./steps/echo-env.sh) ;;|' "$repo/run.sh"
}

# A glob, not `ls | grep`. Shellcheck refuses the latter (SC2010) and is right
# to: a filename with a newline in it would be counted twice. Nothing here
# generates such a name, but the CI gate is on shellcheck being clean, and a
# test file arguing for an exception is a bad look in a repo whose whole point
# is not trusting the plausible.
count_matching() {  # count_matching <dir> <glob>
  local dir="$1" pat="$2" n=0 f
  for f in "$dir"/$pat; do [ -e "$f" ] && n=$((n + 1)); done
  printf '%s' "$n"
}

write_request() {  # write_request <store> <lane> <body...>
  local store="$1" lane="$2"; shift 2
  mkdir -p "$store/requests"
  printf '%s\n' "$@" > "$store/requests/${lane}.txt"
}

# TIMEOUT, NOT PIGEONHOLE_ONCE ALONE. `once` exits after a run COMPLETES, so a
# drop with no request - or one whose id has not changed - correctly loops
# forever waiting for work. Several properties below are exactly that state, so
# the harness bounds the wait instead of relying on the agent to stop.
# Assignments after "$@" would win, so the defaults go first and a caller can
# override any of them.
run_agent() {  # run_agent <repo> <store> <bin> [VAR=VAL ...]
  local repo="$1" store="$2" bin="$3"; shift 3
  ( cd "$repo" && timeout 15 env PATH="$bin:$PATH" FAKE_STORE="$store" \
      PIGEONHOLE_ACCOUNT=testacct PIGEONHOLE_SAS='sv=2021&sig=abc' \
      PIGEONHOLE_ONCE=1 PIGEONHOLE_POLL=1 "$@" \
      ./pigeonhole.sh >"$store/.console" 2>&1 )
  return 0
}

# THE REQUEST HAS TO CHANGE WHILE ONE AGENT IS RUNNING. Writing a new id and
# then starting a fresh agent does not test anything: to that process the id is
# simply what was in the drop at startup, which it deliberately absorbs without
# running - the property that stops a restarting host re-running its last step
# forever. So this starts the agent, waits until it is demonstrably polling,
# and only then drops the request in.
run_agent_then_send() {  # run_agent_then_send <repo> <store> <bin> <lane> <line...>
  local repo="$1" store="$2" bin="$3" lane="$4"; shift 4
  ( cd "$repo" && timeout 20 env PATH="$bin:$PATH" FAKE_STORE="$store" \
      PIGEONHOLE_ACCOUNT=testacct PIGEONHOLE_SAS='sv=2021&sig=abc' \
      PIGEONHOLE_LANE="$lane" PIGEONHOLE_ONCE=1 PIGEONHOLE_POLL=1 \
      ./pigeonhole.sh >"$store/.console" 2>&1 ) &
  local agent=$!

  # Wait for the first status write, which is proof it has started polling
  # rather than a guess at how long that takes.
  local waited=0
  while [ ! -f "$store/status/${lane}.txt" ] && [ "$waited" -lt 100 ]; do
    sleep 0.1; waited=$((waited + 1))
  done

  write_request "$store" "$lane" "$@"

  # ONCE=1 means it exits after the run. If it does not, the timeout above
  # ends it and the assertions report what is actually in the drop.
  wait "$agent" 2>/dev/null
  return 0
}

# =============================================================================
#  Preflight - it must refuse before it waits, not after
# =============================================================================
# A runner that starts, waits, and only fails when a request finally arrives is
# the worst shape: nobody is watching the console, and the far side sees an
# unanswered request with no way in to find out why.
out="$( PIGEONHOLE_SAS=x "$TOOLKIT/pigeonhole.sh" 2>&1 )"
rc="$( PIGEONHOLE_SAS=x "$TOOLKIT/pigeonhole.sh" >/dev/null 2>&1; echo $? )"
assert_eq "no account is refused with exit 2" "2" "$rc"
assert_contains "and says which variable is missing" "PIGEONHOLE_ACCOUNT" "$out"

rc="$( PIGEONHOLE_ACCOUNT=x "$TOOLKIT/pigeonhole.sh" >/dev/null 2>&1; echo $? )"
assert_eq "no SAS is refused with exit 2" "2" "$rc"

# =============================================================================
#  A request runs, and the log comes back
# =============================================================================
STORE="$TMP/s1"; REPO="$TMP/r1"; BIN="$TMP/b1"
mkdir -p "$STORE"; make_fake_curl "$BIN" "$STORE"; make_repo "$REPO"
write_request "$STORE" default "id: run-1" "step: echo-env" "env:" "cancel:" "stop:"

# The id is already present at startup, and that must NOT trigger a run: a host
# whose restart policy brings it back would otherwise re-run the last step
# every time, unwatched, with the reruns indistinguishable from real ones.
run_agent "$REPO" "$STORE" "$BIN"
assert_eq "an id present at startup does not run" "0" \
  "$(count_matching "$STORE/logs" '*')"
assert_contains "and says so on the console" "already present" "$(cat "$STORE/.console")"

# Now change it while the agent is up. THE TRIGGER IS THE id.
STORE="$TMP/s1b"; REPO="$TMP/r1b"; BIN="$TMP/b1b"
mkdir -p "$STORE"; make_fake_curl "$BIN" "$STORE"; make_repo "$REPO"
run_agent_then_send "$REPO" "$STORE" "$BIN" default \
  "id: run-2" "step: echo-env" "env:" "cancel:" "stop:"
assert_eq "a changed id runs the step exactly once" "1" \
  "$(count_matching "$STORE/logs" 'echo-env-*.txt')"
assert_contains "the status reports the log it wrote" "log:      logs/echo-env-" \
  "$(cat "$STORE/status/default.txt")"
assert_contains "and reports the exit code" "exit:     0" \
  "$(cat "$STORE/status/default.txt")"

# =============================================================================
#  The env line - the regression this file exists for
# =============================================================================
STORE="$TMP/s2"; REPO="$TMP/r2"; BIN="$TMP/b2"
mkdir -p "$STORE"; make_fake_curl "$BIN" "$STORE"; make_repo "$REPO"
run_agent_then_send "$REPO" "$STORE" "$BIN" default \
  "id: quoted" "step: echo-env" \
  'env: HOSTS="alpha beta" PORTS="443 1433" CONFIRM=yes' "cancel:" "stop:"

log="$(cat "$STORE/logs/"echo-env-*.txt 2>/dev/null)"
assert_contains "a quoted value with a space survives whole" "HOSTS=[alpha beta]" "$log"
assert_contains "a second quoted value survives too" "PORTS=[443 1433]" "$log"
assert_contains "an unquoted value still works" "CONFIRM=[yes]" "$log"

# The failure being guarded is silent: word-splitting made env run `beta"` as a
# command, which exits 127 before run.sh writes anything. Assert the log exists
# at all, because "no log" is what the bug actually looked like.
assert_eq "a log was produced at all" "1" \
  "$(count_matching "$STORE/logs" 'echo-env-*.txt')"

# =============================================================================
#  The env line is split, not evaluated
# =============================================================================
# Honouring quotes is only half of it. The other half is refusing anything that
# could DO something: the eval assigns an ARRAY, and a guard rejects shell
# metacharacters before it gets that far. A refusal that names the character
# costs one round trip less than a surprise on a host nobody can log into.
STORE="$TMP/s2b"; REPO="$TMP/r2b"; BIN="$TMP/b2b"
mkdir -p "$STORE"; make_fake_curl "$BIN" "$STORE"; make_repo "$REPO"
CANARY="$TMP/canary-should-not-exist"
run_agent_then_send "$REPO" "$STORE" "$BIN" default \
  "id: injected" "step: echo-env" \
  "env: HOSTS=\$(touch $CANARY)" "cancel:" "stop:"

assert_eq "nothing was executed" "0" \
  "$([ -e "$CANARY" ] && echo 1 || echo 0)"
assert_eq "and no step ran" "0" \
  "$(count_matching "$STORE/logs" 'echo-env-*.txt')"
assert_contains "the status says why, not just that it refused" \
  "reason:   env line contains a shell metacharacter" \
  "$(cat "$STORE/status/default.txt" 2>/dev/null)"
assert_contains "and the console quotes the line back" 'HOSTS=$(touch' \
  "$(cat "$STORE/.console" 2>/dev/null)"

# =============================================================================
#  The lane is the binding, and two runners must never share one
# =============================================================================
STORE="$TMP/s3"; REPO="$TMP/r3"; BIN="$TMP/b3"
mkdir -p "$STORE"; make_fake_curl "$BIN" "$STORE"; make_repo "$REPO"
write_request "$STORE" alpha "id: a-1" "step: echo-env" "env:" "cancel:" "stop:"
write_request "$STORE" beta  "id: b-1" "step: echo-env" "env:" "cancel:" "stop:"

run_agent "$REPO" "$STORE" "$BIN" PIGEONHOLE_LANE=alpha
assert_eq "a runner writes status only to its own lane" "1" \
  "$(count_matching "$STORE/status" 'alpha.txt')"
assert_eq "and never touches another lane's status" "0" \
  "$(count_matching "$STORE/status" 'beta.txt')"
assert_contains "the status names the lane it answered" "lane:     alpha" \
  "$(cat "$STORE/status/alpha.txt")"

# =============================================================================
#  The SAS is normalised, not concatenated blindly
# =============================================================================
# A SAS from the portal carries a leading '?'; one from `az ... -o tsv` does
# not. Joined without care the URL gets '??' and fails as AuthenticationFailed,
# which reads like a bad token rather than a bad string join.
STORE="$TMP/s4"; REPO="$TMP/r4"; BIN="$TMP/b4"
mkdir -p "$STORE"; make_fake_curl "$BIN" "$STORE"; make_repo "$REPO"
run_agent "$REPO" "$STORE" "$BIN" PIGEONHOLE_SAS='?sv=2021&sig=abc'
assert_eq "a leading ? on the SAS is stripped" "0" \
  "$(grep -c '^?' "$STORE/.queries" 2>/dev/null | tr -d ' ')"
assert_contains "and the query still carries the token" "sig=abc" \
  "$(head -1 "$STORE/.queries")"

# =============================================================================
#  No request at all is the resting state, not an error
# =============================================================================
STORE="$TMP/s5"; REPO="$TMP/r5"; BIN="$TMP/b5"
mkdir -p "$STORE"; make_fake_curl "$BIN" "$STORE"; make_repo "$REPO"
run_agent "$REPO" "$STORE" "$BIN"
assert_contains "an empty drop is reported, not treated as a fault" "no request at" \
  "$(cat "$STORE/.console")"
# It announces itself before it has anything to do, so an operator can tell a
# runner that is up and idle from one that never started. The final state here
# is "stopped" because the harness ends it with SIGTERM - which is the other
# property worth having: a signalled agent writes a last status rather than
# vanishing, so its heartbeat ends with a reason instead of just stopping.
assert_contains "it announces itself before any work arrives" "lane:     default" \
  "$(cat "$STORE/status/default.txt" 2>/dev/null)"
assert_contains "and a signalled agent records why it stopped" "reason:   SIGTERM" \
  "$(cat "$STORE/status/default.txt" 2>/dev/null)"

t_summary "test-pigeonhole.sh"
