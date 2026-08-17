#!/usr/bin/env bash
# =============================================================================
#  test-start.sh - start.sh refuses a machine that cannot capture properly
# =============================================================================
# Be honest about the limit of these: they exercise the checks and the exit
# codes against a local bare repo, and prove nothing about whether a real
# token authenticates against a real git host. That is the one thing that
# matters most and no test here asserts it.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=assert.sh disable=SC1091
. "$HERE/assert.sh"
ROOT="$(cd "$HERE/.." && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

GIT="git -c user.email=ci@example.com -c user.name=ci"

# A transport repo with a real, pushable origin. A bare repo on disk is enough
# to exercise ls-remote and push --dry-run for real.
make_repo() {
  local d="$1"
  "$ROOT/skills/heliograph/scripts/bootstrap.sh" "$d" >/dev/null 2>&1
  git init -q --bare "$d.origin.git"
  ( cd "$d" \
      && git init -q \
      && git remote add origin "$d.origin.git" \
      && $GIT add -A \
      && $GIT commit -qm init \
      && $GIT push -q -u origin HEAD ) >/dev/null 2>&1
}

run_start() {  # run_start <repodir> [args...] - prints output, sets RC
  local d="$1"; shift
  RC=0
  OUT="$( cd "$d" && ./start.sh "$@" 2>&1 )" || RC=$?
}

# --- the happy path ----------------------------------------------------------
make_repo "$TMP/good"
run_start "$TMP/good" --check
assert_eq "--check exits 0 on a sound machine" "0" "$RC"
assert_contains "--check says the preflight is clear" "preflight: clear" "$OUT"
assert_contains "it reports the sed -u result" "sed -u" "$OUT"
assert_contains "it reports base64 -w0" "base64 -w0" "$OUT"
assert_contains "it proves read access rather than assuming it" "git read" "$OUT"
assert_contains "it proves write access rather than assuming it" "git write" "$OUT"

# --check must not touch the working tree: it is what an operator runs to answer
# "will this work here", often on a node where they are not allowed to change
# anything yet.
before="$( cd "$TMP/good" && git status --porcelain && git rev-parse HEAD )"
run_start "$TMP/good" --check
after="$( cd "$TMP/good" && git status --porcelain && git rev-parse HEAD )"
assert_eq "--check leaves the working tree and HEAD alone" "$before" "$after"

# --- usage -------------------------------------------------------------------
run_start "$TMP/good" --nonsense
assert_eq "an unknown option exits 2" "2" "$RC"

run_start "$TMP/good" --help
assert_eq "--help exits 0" "0" "$RC"
assert_contains "--help shows the usage" "start.sh" "$OUT"

# --- a sed without -u is the failure this check exists for --------------------
# busybox sed has no -u, and the damage is silent: every captured line gets the
# same timestamp, which reads like a working log.
mkdir -p "$TMP/badbin"
real_sed="$(command -v sed)"
cat > "$TMP/badbin/sed" <<EOF
#!/bin/sh
for a in "\$@"; do
  [ "\$a" = "-u" ] && { echo "sed: unrecognized option: u" >&2; exit 1; }
done
exec "$real_sed" "\$@"
EOF
chmod +x "$TMP/badbin/sed"

make_repo "$TMP/badsed"
RC=0
OUT="$( cd "$TMP/badsed" && PATH="$TMP/badbin:$PATH" ./start.sh --check 2>&1 )" || RC=$?
assert_eq "a sed without -u is a blocking failure" "1" "$RC"
assert_contains "and it names the problem" "sed -u" "$OUT"
assert_contains "and it says what to do about it" "GNU sed" "$OUT"

# --- detached HEAD -----------------------------------------------------------
make_repo "$TMP/detached"
( cd "$TMP/detached" && git checkout -q --detach HEAD ) >/dev/null 2>&1
run_start "$TMP/detached" --check
assert_eq "a detached HEAD blocks, because agent.sh would refuse to start" "1" "$RC"
assert_contains "and it says so in those terms" "detached HEAD" "$OUT"

# --- no origin ---------------------------------------------------------------
make_repo "$TMP/noremote"
( cd "$TMP/noremote" && git remote remove origin ) >/dev/null 2>&1
run_start "$TMP/noremote" --check
assert_eq "no origin blocks: git is the transport" "1" "$RC"
assert_contains "and it says which remote is missing" "origin" "$OUT"

# --- an unreachable https remote exercises the token branch ------------------
make_repo "$TMP/https"
( cd "$TMP/https" && git remote set-url origin https://example.invalid/x.git ) >/dev/null 2>&1
RC=0
OUT="$( cd "$TMP/https" && GIT_TOKEN=abcd ./start.sh --check 2>&1 )" || RC=$?
assert_eq "an unreachable remote blocks rather than starting the agent" "1" "$RC"
assert_contains "the token mechanism is named" "GIT_TOKEN" "$OUT"
assert_contains "the token length is reported" "4 chars" "$OUT"
assert_eq "the token value is never printed" "" "$(printf '%s' "$OUT" | grep -o abcd)"

# --- the handover ------------------------------------------------------------
# start.sh must exec agent.sh rather than run it as a child, so that the
# operator's Ctrl-C reaches the agent and its cleanup trap fires. A stub agent
# that reports its own pid is how that gets proved.
make_repo "$TMP/handover"
cat > "$TMP/handover/agent.sh" <<'EOF'
#!/usr/bin/env bash
echo "STUB AGENT pid=$$ args=$*"
EOF
chmod +x "$TMP/handover/agent.sh"

RC=0
OUT="$( cd "$TMP/handover" && ./start.sh 2>&1 )" || RC=$?
assert_eq "without --check it runs the agent" "0" "$RC"
assert_contains "and the agent actually ran" "STUB AGENT" "$OUT"

RC=0
OUT="$( cd "$TMP/handover" && ./start.sh -- --once --interval 15 2>&1 )" || RC=$?
assert_contains "args after -- reach agent.sh" "args=--once --interval 15" "$OUT"

# exec, not a subshell: the agent must end up with start.sh's own pid.
RC=0
OUT="$( cd "$TMP/handover" && bash -c 'echo "SHELL pid=$$"; exec ./start.sh' 2>&1 )" || RC=$?
shell_pid="$(printf '%s\n' "$OUT" | sed -n 's/^SHELL pid=//p')"
agent_pid="$(printf '%s\n' "$OUT" | sed -n 's/.*STUB AGENT pid=\([0-9]*\).*/\1/p')"
assert_eq "agent.sh is exec'd, so Ctrl-C reaches it" "$shell_pid" "$agent_pid"

# --check must still not reach the agent.
RC=0
OUT="$( cd "$TMP/handover" && ./start.sh --check 2>&1 )" || RC=$?
assert_eq "--check does not run the agent" "" "$(printf '%s' "$OUT" | grep -o 'STUB AGENT')"

# --- --branch ----------------------------------------------------------------
make_repo "$TMP/branchy"
cp "$TMP/handover/agent.sh" "$TMP/branchy/agent.sh"
( cd "$TMP/branchy" && $GIT checkout -q -b task/probe && $GIT push -q -u origin task/probe \
    && git checkout -q - ) >/dev/null 2>&1
RC=0
OUT="$( cd "$TMP/branchy" && ./start.sh --branch task/probe 2>&1 )" || RC=$?
assert_eq "--branch checks the branch out" "task/probe" \
  "$( cd "$TMP/branchy" && git rev-parse --abbrev-ref HEAD )"
assert_contains "and says it did" "task/probe" "$OUT"

RC=0
OUT="$( cd "$TMP/branchy" && ./start.sh --branch task/nope 2>&1 )" || RC=$?
assert_eq "a branch that does not exist blocks" "1" "$RC"
assert_contains "and names it" "task/nope" "$OUT"

# --- --branch validation -------------------------------------------------------
# Harmless while WANT_BRANCH was inert; once the sync acts on it, a missing or
# empty value must not silently become a no-op checkout.
RC=0
OUT="$( cd "$TMP/good" && ./start.sh --branch 2>&1 )" || RC=$?
assert_eq "--branch with no value is a usage error" "2" "$RC"
assert_contains "and it names the problem" "--branch" "$OUT"

t_summary
