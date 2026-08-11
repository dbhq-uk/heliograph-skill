#!/usr/bin/env bash
# =============================================================================
#  lib/probe.sh - helpers for STEP SCRIPTS
# =============================================================================
# Step scripts print to stdout and nothing else. The runner (run.sh / caprun.sh)
# owns the log file, the timestamps and the push. That separation is what lets
# you run any step standalone while you're developing it:
#
#     ./steps/net-probe.sh          # straight to the terminal, no log, no push
#     ./run.sh net                  # same thing, captured and pushed
#
# Usage inside a step script:
#     . "$(dirname "${BASH_SOURCE[0]}")/../lib/probe.sh"
#     sec "what I am about to check"
#     probe "hostname" hostname -f
#     probe_summary; exit $?
# =============================================================================

PROBE_FAILURES=0
PROBE_TOTAL=0

# sec <title...> - a labelled divider so a long log stays skimmable.
sec() { printf '\n---------- %s ----------\n' "$*"; }

# probe <label> <cmd> [args...]
# Runs the command, prints its output, and records a failure WITHOUT aborting.
# A diagnostic step wants the whole picture, not just the first thing that
# breaks - so never `set -e` in a step script and never short-circuit here.
probe() {
  local label="$1"; shift
  PROBE_TOTAL=$((PROBE_TOTAL + 1))
  sec "$label"
  "$@" 2>&1
  local rc=${PIPESTATUS[0]}
  if [ "$rc" -ne 0 ]; then
    PROBE_FAILURES=$((PROBE_FAILURES + 1))
    printf '   ^ FAILED: exit %s  (%s)\n' "$rc" "$label"
  fi
  return "$rc"
}

# probe_opt <label> <cmd> [args...]
# Same, but a missing tool / non-zero exit is expected and not counted - for
# things that are informational (`which terraform`) rather than assertions.
probe_opt() {
  local label="$1"; shift
  sec "$label"
  "$@" 2>&1 || printf '   (not available / non-zero - informational only)\n'
  return 0
}

# probe_summary - print the tally; returns 1 if anything failed.
probe_summary() {
  printf '\n---------- summary ----------\n'
  printf 'probes: %s   failed: %s\n' "$PROBE_TOTAL" "$PROBE_FAILURES"
  [ "$PROBE_FAILURES" -eq 0 ]
}

# have <tool> - quiet "is this on PATH".
have() { command -v "$1" >/dev/null 2>&1; }
