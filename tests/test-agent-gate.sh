#!/usr/bin/env bash
# =============================================================================
#  test-agent-gate.sh - what the unattended loop will and will not run
# =============================================================================
# The agent is the part of this toolkit that runs without anyone watching, so
# its default posture is the thing most worth asserting. It is read-only by
# default: a step that declares itself an action is refused unless the operator
# started the loop with --allow-actions.
#
# That default was the other way round for a while, for a real reason - a flag
# typed once at agent start, days before the request it gated, surfaced as a
# silent refusal and wasted the round trip this tooling exists to save. The
# refusal now reaches the far side through agent/status within one poll, which
# is what makes a safe default affordable again. So the assertions below check
# the refusal is PUBLISHED, not just that it happened.
#
# Every agent invocation is wrapped in `timeout`: the loop is designed to poll
# forever, and a test that hangs teaches nobody anything.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=assert.sh disable=SC1091
. "$HERE/assert.sh"
ROOT="$(cd "$HERE/.." && pwd)"

TMP="$(mktemp -d)"
trap 'pkill -f "$TMP/tr/agent.sh" 2>/dev/null; rm -rf "$TMP"' EXIT

TR="$TMP/tr"
GIT="git -c user.email=ci@example.invalid -c user.name=ci"

"$ROOT/skills/heliograph/scripts/bootstrap.sh" "$TR" >/dev/null 2>&1
git init -q --bare "$TMP/origin.git"
( cd "$TR" \
    && git init -q \
    && git remote add origin "$TMP/origin.git" \
    && $GIT add -A \
    && $GIT commit -qm init \
    && $GIT push -q -u origin HEAD ) >/dev/null 2>&1

# Two steps that differ only in what they declare, so every assertion below is
# about the declaration and nothing else.
add_step() {  # add_step <name> <mode>
  cat > "$TR/steps/$1.sh" <<EOF
#!/usr/bin/env bash
# heliograph-mode: $2
echo "ran $1"
EOF
  chmod +x "$TR/steps/$1.sh"
  ( cd "$TR" && sed -i "s|^  # -- add task steps here.*|  $1)  CMD=(./steps/$1.sh) ;;\n&|" run.sh )
}
add_step reader read-only
add_step writer action
( cd "$TR" && $GIT add -A && $GIT commit -qm steps && $GIT push -q ) >/dev/null 2>&1

request() {  # request <id> <step> [envline]
  { echo "id: $1"; echo "step: $2"; [ -n "${3:-}" ] && echo "env: $3"; } > "$TR/agent/request"
  ( cd "$TR" && $GIT add -A && $GIT commit -qm "request $1" && $GIT push -q ) >/dev/null 2>&1
}

agent() {  # agent [args...] - one pass, output in OUT, exit code in RC
  RC=0
  OUT="$( cd "$TR" && timeout 60 ./agent.sh --once --interval 1 "$@" 2>&1 )" || RC=$?
}

status_field() { sed -n "s/^$1:[[:space:]]*//p" "$TR/agent/status" | head -1; }
logs_for() { ls "$TR/ops-logs/$1"-*.txt 2>/dev/null | wc -l; }

# --- the default posture ------------------------------------------------------
# The shipped request has an empty `id`, so a fresh agent starts up and waits.
# Five seconds is plenty to read its banner and nothing is lost by killing it.
banner() { OUT="$( cd "$TR" && timeout 5 ./agent.sh --interval 1 "$@" 2>&1 )"; }
banner
assert_contains "the agent says at startup that actions are blocked" "BLOCKED" "$OUT"

request r1 reader
agent
assert_eq "a read-only step runs on a default agent" "1" "$(logs_for reader)"
assert_eq "and the status says it finished" "idle" "$(status_field state)"

request w1 writer "CONFIRM=yes"
agent
assert_eq "an action step is refused on a default agent" "0" "$(logs_for writer)"
assert_contains "and the refusal is said out loud" "REFUSED" "$OUT"
assert_eq "and PUBLISHED, which is what makes the safe default affordable" \
  "refused" "$(status_field state)"
assert_contains "and the reason names the flag that would allow it" \
  "allow-actions" "$(cat "$TR/agent/status")"

# --- the operator opting in ---------------------------------------------------
request w2 writer "CONFIRM=yes"
agent --allow-actions
assert_eq "--allow-actions lets the same request through" "1" "$(logs_for writer)"
banner --allow-actions
assert_contains "and the startup banner says so" "ALLOWED" "$OUT"

# CONFIRM is still required by run.sh itself. Two gates, and --allow-actions is
# only the outer one: an action step pushed WITHOUT CONFIRM must still fail.
request w3 writer
agent --allow-actions
assert_eq "without CONFIRM in the request, run.sh still refuses it" "1" "$(logs_for writer)"
assert_eq "and the exit code reaches the status as a failure" "3" "$(status_field exit)"

# --- env promotion: a read-only step turned into a writing one ----------------
# The declaration cannot see this. `env: APPLY=1` is how a plan becomes an apply
# in every wrapper anyone writes, so ACTION_ENV stays as a second recogniser.
request p1 reader "APPLY=1"
agent
assert_eq "a read-only step carrying APPLY=1 is refused by default" "refused" "$(status_field state)"

request p2 reader "APPLY=1"
agent --allow-actions
assert_eq "and allowed when the operator opted in" "2" "$(logs_for reader)"

# --- pinning: opt-in, and off by default --------------------------------------
# REQUIRE_PIN=1 is for an estate that wants "runs only what I approved". It
# costs the thing the unattended loop exists for - a new step now waits for the
# operator - so it is off unless asked for.
assert_eq "pinning is off by default: an unpinned step still runs" "2" "$(logs_for reader)"

request r2 reader
RC=0
OUT="$( cd "$TR" && REQUIRE_PIN=1 timeout 60 ./agent.sh --once --interval 1 2>&1 )" || RC=$?
assert_eq "with REQUIRE_PIN=1 and nothing approved, the step is refused" \
  "refused" "$(status_field state)"
assert_contains "and the reason says it is not approved" "not approved" "$(cat "$TR/agent/status")"
assert_eq "and it captured nothing" "2" "$(logs_for reader)"

( cd "$TR" && ./agent.sh --pin >/dev/null 2>&1 )
assert_eq "--pin writes the approvals locally" "1" \
  "$( [ -f "$TR/.agent-approved" ] && echo 1 || echo 0 )"

# Local, and gitignored: an approval recorded in the transport repo could be
# edited from the far side, which is the only side the pin exists to distrust.
assert_eq ".agent-approved is gitignored, because trust must not be pushable" "0" \
  "$( cd "$TR" && git check-ignore -q .agent-approved && echo 0 || echo 1 )"

request r3 reader
RC=0
OUT="$( cd "$TR" && REQUIRE_PIN=1 timeout 60 ./agent.sh --once --interval 1 2>&1 )" || RC=$?
assert_eq "after --pin, the approved step runs" "3" "$(logs_for reader)"

# The point of hashing rather than listing names: an EDIT to an approved step is
# a different step, and the pin must notice.
printf 'echo "changed after approval"\n' >> "$TR/steps/reader.sh"
( cd "$TR" && $GIT add -A && $GIT commit -qm edit && $GIT push -q ) >/dev/null 2>&1
request r4 reader
RC=0
OUT="$( cd "$TR" && REQUIRE_PIN=1 timeout 60 ./agent.sh --once --interval 1 2>&1 )" || RC=$?
assert_eq "an approved step that has since changed is refused" "refused" "$(status_field state)"
assert_eq "and did not run" "3" "$(logs_for reader)"
# A refusal is an answer: --once has answered its one request and must exit
# cleanly rather than sitting there polling over a question it has responded to.
assert_eq "and --once exits 0, because a refusal is an answer" "0" "$RC"

t_summary
