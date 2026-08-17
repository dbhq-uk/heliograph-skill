#!/usr/bin/env bash
# =============================================================================
#  run-tests.sh - every test-*.sh in this directory
# =============================================================================
# Runs them all and reports every failure rather than stopping at the first, for
# the same reason `probe` does not abort: a diagnostic wants every result.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rc=0

for t in "$HERE"/test-*.sh; do
  [ -f "$t" ] || continue
  printf '\n=== %s ===\n' "${t##*/}"
  "$t" || rc=1
done

exit "$rc"
