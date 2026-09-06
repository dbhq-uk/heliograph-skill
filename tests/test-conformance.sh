#!/usr/bin/env bash
# =============================================================================
#  test-conformance.sh - run the conformance suite against every driver
# =============================================================================
# The real driver must pass. The mutant driver must FAIL, and the second half
# is not ceremony: nothing else in this repository can tell a suite that checks
# the capture apart from a suite that has quietly stopped checking anything,
# because both report a clean run.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=assert.sh disable=SC1091
. "$HERE/assert.sh"

if "$HERE/conformance/conformance.sh" "$HERE/conformance/drivers/bash.sh"; then
  t_ok "the bash toolkit passes the conformance suite"
else
  t_no "the bash toolkit FAILS the conformance suite"
fi

if "$HERE/conformance/mutant-check.sh"; then
  t_ok "the mutant driver fails the suite, so the suite has teeth"
else
  t_no "the mutant driver PASSED the suite - the suite is not checking"
fi

t_summary
