#!/usr/bin/env bash
# =============================================================================
#  run.sh - the step runner.  ONE command for the operator to remember.
# =============================================================================
#
#     git pull && ./run.sh            # runs whatever step is currently set
#     git pull && ./run.sh <step>     # or name one explicitly
#     ./run.sh --list                 # what steps exist on this branch
#
#  ...then say it's done. That's the whole workflow. Claude sets DEFAULT_STEP
#  below and pushes; you pull and run; the log is captured and pushed back.
#  You never need to remember host names, inventory files or extra-vars.
#
#  ON main THIS TABLE IS A SKELETON - the two generic steps below work
#  anywhere and are the right first move on any new investigation. Real work
#  belongs on a task branch: see CLAUDE.md.
# =============================================================================
set -uo pipefail

# ==============================================================
#  CURRENT STEP - Claude edits this line; the operator just pulls & runs
# ==============================================================
DEFAULT_STEP="env"
# ==============================================================
#  Steps on this branch:
#    DIAGNOSTICS (read-only, safe to repeat)
#      env    control-node snapshot: OS, tools, auth, proxy, DNS, git   [default]
#      net    connectivity matrix to HOSTS on PORTS: DNS, ICMP, TCP
#    ACTIONS (change something - name them explicitly, never make one default)
#      (none on main)
# ==============================================================

STEP="${1:-$DEFAULT_STEP}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=caplib.sh disable=SC1091
. "$REPO_ROOT/caplib.sh"
cd "$REPO_ROOT" || exit 1

if [ "$STEP" = "--list" ] || [ "$STEP" = "-l" ]; then
  sed -n '/^#  *Steps on this branch:/,/^# ===/p' "$0" | sed 's/^# \{0,2\}//' | grep -v '^=\+$'
  exit 0
fi

# --- pick the command (validate the step BEFORE any side effect) -------------
# Every step is an argv array. Keep them one line each so the table stays a
# readable index of what this branch can do.
case "$STEP" in
  env)  CMD=(./steps/env-snapshot.sh) ;;
  net)  CMD=(./steps/net-probe.sh) ;;

  # -- add task steps here (task branches only) -----------------------------
  # tfplan)  CMD=(./steps/tf-plan.sh) ;;
  # deploy)  CMD=(./steps/deploy.sh) ;;      # ACTION - never the default step

  *)
    echo "unknown step: $STEP" >&2
    echo "run '$0 --list' to see the steps on this branch." >&2
    exit 2 ;;
esac

# --- destructive steps must opt in ------------------------------------------
# Add a step name here when it changes state. The operator then has to type
# CONFIRM=yes, so a stale DEFAULT_STEP can never silently destroy anything.
case "$STEP" in
  reset|destroy|apply|deploy)
    if [ "${CONFIRM:-}" != "yes" ]; then
      echo "step '$STEP' changes state. Re-run with: CONFIRM=yes ./run.sh $STEP" >&2
      exit 3
    fi ;;
esac

OUT_DIR="${LOG_DIR:-$REPO_ROOT/ops-logs}"
mkdir -p "$OUT_DIR"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="$OUT_DIR/${STEP}-${STAMP}.txt"

cap_banner "STEP: $STEP"
cap_header "$OUT" "STEP: $STEP" "command: ${CMD[*]}"

# SUDO=1 for steps that escalate on the control node.
if [ "${SUDO:-0}" != "0" ]; then
  cap_sudo_precache || exit 1
fi

cap_run "$OUT" "${CMD[@]}"; RC=$?
cap_footer "$OUT" "$RC"
cap_push "$OUT" "step: $STEP ($STAMP) exit=$RC"

cap_result "step $STEP" "$RC" "$OUT"
exit "$RC"
