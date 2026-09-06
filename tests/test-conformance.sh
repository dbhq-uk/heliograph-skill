#!/usr/bin/env bash
# =============================================================================
#  test-conformance.sh - run the conformance suite against every driver
# =============================================================================
# The real driver must pass. The mutant driver must FAIL, and that assertion is
# the point: a conformance suite that cannot fail is decoration. The mutant is
# added in Task 8; until then only the real driver is run.
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

t_summary
