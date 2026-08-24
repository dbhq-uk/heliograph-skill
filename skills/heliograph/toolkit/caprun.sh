#!/usr/bin/env bash
# =============================================================================
#  caprun.sh - run ANY command, with full capture + git push
# =============================================================================
# The escape hatch: when the thing you need to run isn't (yet) a step in run.sh,
# wrap it in this and you still get the timestamped, pushed log.
#
#   ./caprun.sh <label> <command> [args...]
#   ./caprun.sh <label> -- <command> [args...]      # -- if the cmd takes flags
#
# Examples
#   ./caprun.sh tf-plan -- terraform plan -no-color -input=false
#   ./caprun.sh ansible-ping -- ansible -i inv.ini all -m win_ping
#   ./caprun.sh disk -- ssh appserver01 df -h
#   PUSH=0 ./caprun.sh quicklook -- systemctl status nginx     # capture only
#   SUDO=1 ./caprun.sh mount -- ./some-script-that-escalates.sh
#
# Environment knobs
#   PUSH=0        capture to ops-logs/ but do NOT commit/push (default: push)
#   SUDO=1        pre-cache sudo up front (default off). Use for commands that
#                 escalate on the control node, so they cannot hang silently on
#                 a sudo password prompt.
#   REDACT=0      disable best-effort secret masking in the log
#   LOG_DIR=path  where to write the log (default: <repo>/ops-logs)
#   NO_COLOUR=1   plain banners
#
# Exit code is the wrapped command's real exit code, so this is safe to chain.
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=caplib.sh disable=SC1091
. "$REPO_ROOT/caplib.sh"

if [ "$#" -lt 2 ]; then
  cat >&2 <<USAGE
usage: $0 <label> [--] <command> [args...]
  Runs the command, capturing a timestamped log to ops-logs/<label>-<UTC>.txt
  and pushing it (PUSH=0 to skip). See the header of this file for knobs.
USAGE
  exit 2
fi

LABEL="$(printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '-')"; shift
[ "${1:-}" = "--" ] && shift
if [ "$#" -lt 1 ]; then echo "$0: no command given after label" >&2; exit 2; fi

# Resolved before the cd below, and made absolute: a relative LOG_DIR would
# otherwise be created next to the caller's cwd and then written next to the
# repo root, putting the log somewhere nobody thinks to look for it.
LOG_DIR="${LOG_DIR:-$REPO_ROOT/ops-logs}"
mkdir -p "$LOG_DIR" || exit 1
LOG_DIR="$(cd "$LOG_DIR" && pwd)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="$LOG_DIR/${LABEL}-${STAMP}.txt"

cd "$REPO_ROOT" || exit 1

cap_banner "caprun: $LABEL"
cap_banner "command: $*"

# Only pre-cache sudo when asked - read-only commands should never prompt.
if [ "${SUDO:-0}" != "0" ]; then
  cap_sudo_precache || exit 1
fi

cap_header "$OUT" "CAPTURED RUN: $LABEL" "command: $*"
cap_run "$OUT" "$@"; RC=$?
cap_footer "$OUT" "$RC"
# ***NO_CI*** - see the matching comment in run.sh. A log push must not be able
# to re-trigger the pipeline that produced it.
cap_push "$OUT" "run: $LABEL ($STAMP) exit=$RC ***NO_CI***"

cap_result "$LABEL" "$RC" "$OUT"
exit "$RC"
