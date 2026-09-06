#!/usr/bin/env bash
# =============================================================================
#  mutant-check.sh - exits 0 when the mutant driver FAILS the suite
# =============================================================================
# The inversion is the point, so it is done here rather than inline in
# test-conformance.sh where a reader would have to hold it in their head.
#
# The mutant's output is discarded deliberately. It contains SKIP lines, and
# CI greps run-tests.sh output for `^SKIP` to catch a silently unverified run.
# A deliberately broken driver skipping the gate properties is not that, and
# letting it reach the log would train people to ignore the real signal.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if "$HERE/conformance.sh" "$HERE/drivers/mutant.sh" >/dev/null 2>&1; then
  exit 1   # the mutant PASSED, which means the suite checks nothing
else
  exit 0   # the mutant failed, as it must
fi
