#!/usr/bin/env bash
# =============================================================================
#  conformance.sh - the executable form of the capture contract
# =============================================================================
# AGENTS.md constraint 3 says there is one implementation of the capture
# pattern. That is becoming one *specification* with several implementations:
# bash today, PowerShell after A8, and the same properties across every
# transport after A6. This file is that specification.
#
# It asserts properties, never internals. A driver supplies the implementation.
# Nothing here may reference caplib.sh, run.sh or any path inside the toolkit:
# the moment it does, it stops being a specification and becomes a second copy
# of one implementation.
#
# Usage: conformance.sh <driver.sh>
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../assert.sh disable=SC1091
. "$HERE/../assert.sh"

DRIVER="${1:?usage: conformance.sh <driver.sh>}"
[ -f "$DRIVER" ] || { printf 'no such driver: %s\n' "$DRIVER" >&2; exit 2; }
# shellcheck disable=SC1090
. "$DRIVER"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

printf '\n--- conformance: %s ---\n' "$(drv_name)"

# Timestamps are HH:MM:SS. Converted to seconds since midnight so gaps can be
# measured. Midnight rollover is handled by the caller adding 86400 when the
# second value is smaller than the first.
secs_of() {
  local t="$1" h m s
  h="${t%%:*}"; t="${t#*:}"; m="${t%%:*}"; s="${t#*:}"
  # 10# forces base 10, or 08 and 09 are read as invalid octal.
  printf '%s' "$(( 10#$h * 3600 + 10#$m * 60 + 10#$s ))"
}

# The timestamp column of a captured log: the field before the first " | ".
# Header and footer lines carry no such separator and are skipped.
stamps_of() { grep ' | ' "$1" | sed 's/ | .*//'; }

# --- property 1: every captured line carries a DISTINCT UTC timestamp ---------
# This is the busybox failure, and it is the reason the whole suite exists. A
# `sed` without -u buffers, every line of the block is stamped when the buffer
# flushes, and the log reads perfectly while being useless: a hang and slow
# progress become indistinguishable, which is the single property these logs
# exist for.
if drv_supports capture; then
  cat > "$WORK/three-slow.sh" <<'EOS'
#!/usr/bin/env bash
echo first; sleep 1.1; echo second; sleep 1.1; echo third
EOS
  chmod +x "$WORK/three-slow.sh"
  drv_capture "$WORK/p1.log" "$WORK/three-slow.sh" >/dev/null 2>&1

  p1_all="$(stamps_of "$WORK/p1.log" | wc -l | tr -d ' ')"
  p1_uniq="$(stamps_of "$WORK/p1.log" | sort -u | wc -l | tr -d ' ')"

  assert_eq "p1: three captured lines" "3" "$p1_all"
  assert_eq "p1: three DISTINCT timestamps, so the capture is unbuffered" \
    "3" "$p1_uniq"
else
  t_skip "p1: driver does not support capture"
fi

t_summary
