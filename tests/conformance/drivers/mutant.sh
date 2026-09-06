#!/usr/bin/env bash
# =============================================================================
#  drivers/mutant.sh - a deliberately broken capture, which MUST fail
# =============================================================================
# A conformance suite that cannot fail is decoration. Nothing else in this
# repository can tell the difference between a suite that checks the capture
# and a suite that has quietly stopped checking anything, because both report
# a clean run. This driver is that difference.
#
# It breaks the capture the three ways a real port breaks it:
#
#   p1, p2   buffered. One timestamp taken up front and applied to every line,
#            which is exactly what a `sed` without -u does on busybox. The log
#            reads perfectly and a hang becomes invisible.
#   p3       the step's exit code swallowed and reported as 0, which is what
#            happens the moment PIPESTATUS is forgotten. Note that a bare
#            `return $?` here is NOT enough to break it: conformance.sh sets
#            `pipefail`, the driver is sourced into that shell, and the
#            pipeline then reports 42 on its own. The swallow has to be
#            explicit, which is itself worth knowing before writing a port.
#   p4       no footer, so a failed run ends mid-air with no exit code and no
#            RESULT line.
#
# test-conformance.sh asserts this driver FAILS. If it ever passes, the suite
# has stopped checking and the next real implementation will sail through it.
#
# Do not fix this driver. It is supposed to be wrong.
# =============================================================================

_M_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_M_TOOLKIT="$(cd "$_M_HERE/../../../skills/heliograph/toolkit" && pwd)"
export _M_TOOLKIT   # referenced only so the path is validated, never sourced

drv_name() { printf 'MUTANT - deliberately broken, must fail'; }

drv_supports() {
  case "$1" in
    capture) return 0 ;;
    *) return 1 ;;
  esac
}

drv_capture() {
  local out="$1" script="$2" ts l
  ts="$(date -u +%H:%M:%S)"
  {
    echo "============================================================"
    echo " mutant"
    echo "============================================================"
    echo
  } > "$out"
  # One stamp for the whole block. No redaction. No footer.
  "$script" 2>&1 | while IFS= read -r l; do
    printf '%s | %s\n' "$ts" "$l"
  done >> "$out"
  # The exit code, swallowed. Every failed run now publishes as a success.
  return 0
}

drv_bootstrap()  { return 1; }
drv_step()       { return 1; }
drv_capture_bg() { return 1; }
