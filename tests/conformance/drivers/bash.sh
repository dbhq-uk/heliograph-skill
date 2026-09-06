#!/usr/bin/env bash
# =============================================================================
#  drivers/bash.sh - the current bash toolkit, under the conformance contract
# =============================================================================
# Sourced by conformance.sh. Implements drv_* and nothing else. All knowledge
# of caplib.sh, run.sh and bootstrap.sh lives here, so the suite itself stays a
# specification rather than a second copy of this implementation.
# =============================================================================

_D_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_D_TOOLKIT="$(cd "$_D_HERE/../../../skills/heliograph/toolkit" && pwd)"
_D_BOOTSTRAP="$(cd "$_D_HERE/../../../skills/heliograph/scripts" && pwd)/bootstrap.sh"

drv_name() { printf 'bash toolkit (caplib.sh, run.sh)'; }

drv_supports() {
  case "$1" in
    capture|gates|cancel) return 0 ;;
    *) return 1 ;;
  esac
}

# Capture in a subshell so caplib's globals never leak between properties.
drv_capture() {
  local out="$1" script="$2"
  (
    # shellcheck disable=SC1091
    . "$_D_TOOLKIT/caplib.sh"
    cap_header "$out" "conformance"
    cap_run "$out" "$script"
    rc=$?
    cap_footer "$out" "$rc"
    exit "$rc"
  ) >/dev/null 2>&1
}

drv_bootstrap() {
  local dir="$1"
  "$_D_BOOTSTRAP" "$dir" >/dev/null 2>&1 || return 1
  (
    cd "$dir" || exit 1
    git init -q .
    git -c user.email=ci@example.invalid -c user.name=ci add -A
    git -c user.email=ci@example.invalid -c user.name=ci commit -qm init
  ) >/dev/null 2>&1
}

drv_step() {
  local dir="$1" step="$2"
  ( cd "$dir" && PUSH=0 ./run.sh "$step" ) >/dev/null 2>&1
}

# Start a capture in its own process group, so a cancel can signal the whole
# group the way agent.sh does rather than only the wrapper. Echoes the pid,
# which is also the process group id because setsid made it a leader.
drv_capture_bg() {
  local out="$1" script="$2"
  setsid bash -c '
    # shellcheck disable=SC1091
    . "$1/caplib.sh"
    cap_header "$2" "conformance-cancel"
    cap_run "$2" "$3"
    cap_footer "$2" $?
  ' _ "$_D_TOOLKIT" "$out" "$script" >/dev/null 2>&1 &
  printf '%s' "$!"
}
