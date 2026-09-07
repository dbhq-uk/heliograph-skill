#!/usr/bin/env bash
# =============================================================================
#  run-tests.sh - every test-*.sh in this directory
# =============================================================================
# Runs them all and reports every failure rather than stopping at the first, for
# the same reason `probe` does not abort: a diagnostic wants every result.
#
# IT ALSO WATCHES FOR LEAKED STATE, and that needs explaining.
#
# A full local run once produced three failures - two in test-container.sh, one
# in test-service.sh reporting "no running loop found after install" - that did
# not reproduce when either test was run alone, and never happened in CI. The
# obvious explanation was state left behind by an earlier test: a systemd user
# unit, a container, a stray loop.
#
# It has not been seen since, and a fix for a fault nobody can reproduce is a
# guess with a commit message. So instead of guessing, this names the culprit if
# it happens again: after each file it counts the things a test might leave
# behind, and says which test left them.
#
# That turns "the suite is flaky" - which is where a suite goes to be ignored -
# into "test-X left a container running", which is a bug report.
#
# The leak report NEVER fails the run. A leak is not a failed assertion, and a
# suite that goes red for tidiness teaches people to skip it, which costs more
# than the leak.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rc=0

# Counted, not listed: the numbers are what a change between tests looks like,
# and the detail only matters once one of them moves.
leak_counts() {
  local units=0 procs=0 ctrs=0 clusters=0
  units="$(systemctl --user list-units --all 2>/dev/null | grep -c heliograph || true)"
  procs="$(pgrep -fc 'start\.sh|station\.sh|caprun\.sh' 2>/dev/null || true)"
  if command -v docker >/dev/null 2>&1; then
    ctrs="$(docker ps -q --filter 'name=heliograph' 2>/dev/null | wc -l || true)"
  elif command -v podman >/dev/null 2>&1; then
    ctrs="$(podman ps -q --filter 'name=heliograph' 2>/dev/null | wc -l || true)"
  fi
  if command -v kind >/dev/null 2>&1; then
    clusters="$(kind get clusters 2>/dev/null | grep -c heliograph || true)"
  fi
  printf '%s %s %s %s' "${units:-0}" "${procs:-0}" "${ctrs:-0}" "${clusters:-0}"
}

before="$(leak_counts)"
baseline="$before"
leaked_by=""

for t in "$HERE"/test-*.sh; do
  [ -f "$t" ] || continue
  name="${t##*/}"
  printf '\n=== %s ===\n' "$name"
  "$t" || rc=1

  after="$(leak_counts)"
  if [ "$after" != "$before" ]; then
    # shellcheck disable=SC2086
    set -- $before; b_u=$1 b_p=$2 b_c=$3 b_k=$4
    # shellcheck disable=SC2086
    set -- $after;  a_u=$1 a_p=$2 a_c=$3 a_k=$4
    printf 'note: %s changed the machine around it:' "$name"
    [ "$a_u" != "$b_u" ] && printf ' systemd user units %s->%s' "$b_u" "$a_u"
    [ "$a_p" != "$b_p" ] && printf ' loop processes %s->%s' "$b_p" "$a_p"
    [ "$a_c" != "$b_c" ] && printf ' containers %s->%s' "$b_c" "$a_c"
    [ "$a_k" != "$b_k" ] && printf ' kind clusters %s->%s' "$b_k" "$a_k"
    printf '\n'
    leaked_by="$leaked_by $name"
    before="$after"
  fi
done

final="$(leak_counts)"
if [ "$final" != "$baseline" ]; then
  printf '\n----------------------------------------------------------------\n'
  printf 'The machine did not come back to how it started.\n'
  printf '  before: units/processes/containers/clusters = %s\n' "$baseline"
  printf '  after : units/processes/containers/clusters = %s\n' "$final"
  printf 'Left by:%s\n' "$leaked_by"
  printf 'This does not fail the run. It is here so that if the suite starts\n'
  printf 'failing in ways a single test does not, the culprit has a name.\n'
  printf 'See dbhq-uk/heliograph-skill#41.\n'
  printf -- '----------------------------------------------------------------\n'
fi

exit "$rc"
