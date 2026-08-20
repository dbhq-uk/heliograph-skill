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
#      win    Windows control-node snapshot: OS, hotfixes, services, events
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

# --- a PowerShell step -------------------------------------------------------
# A step is an argv array, so the runner does not care what language it is in:
# caplib sees a process that prints to stdout, and that is the whole contract.
# A Windows step wants Get-WinEvent rather than a bash reimplementation of it.
#
# ps_step sets CMD for a .ps1 step. It exists so the table below stays one
# readable line per step, and so the two things that make PowerShell output
# unreadable in a captured log get fixed in ONE place instead of in every step
# by every author who remembers:
#
#  Every number below was measured on Windows Server 2022 with PowerShell
#  5.1.20348 and on Linux with pwsh 7.6.5, not reasoned about.
#
#   LINE ENDINGS. `powershell.exe -File` emits CRLF: CR=8 LF=8 for an eight
#   line script, whether redirected to a file or through a pipe. A stray CR on
#   every captured line is invisible in a terminal, wrong in the file, and
#   quietly breaks any later grep anchored with $. Out-String -Stream renders
#   each object the way the console would, and rewriting each line with an
#   explicit LF pins the ending: CR drops to 0. pwsh on Linux already emits LF,
#   so this only earns its keep on a Windows control node.
#
#   COLOUR, and it is NOT the colour that needs this. cap_run already strips
#   ANSI with 's/\x1b\[[0-9;]*[mGKHF]//g', which covers everything pwsh 7 emits
#   for Format-Table: 8 ESC bytes in, 0 out. Removing NO_COLOR changes nothing
#   for those, and an assertion written against a colour-only step cannot fail.
#
#   The gap is OSC 8 HYPERLINKS. pwsh emits them as ESC]8;;<url>, and that sed
#   only matches ESC[ sequences, so they go straight through into the log:
#   measured 4 ESC bytes surviving cap_run for a step calling
#   $PSStyle.FormatHyperlink, and 0 with NO_COLOR set. NO_COLOR is what earns
#   its place here; PlainText in the parent does not, and is kept only because
#   it costs nothing. Windows PowerShell 5.1 has no $PSStyle and emits no ANSI
#   at all, so this is pwsh 7 insurance rather than a Windows fix.
#
#   ENCODING. Forcing UTF-8 is about the OEM codepage mangling non-ASCII, NOT
#   about UTF-16: the redirected stream measured NUL=0, so the widely repeated
#   "PowerShell redirects as UTF-16" does not apply to this path.
#
#   EXIT CODES, and this is the one that would have shipped a wrong answer.
#   Running the step in-process as `& './step.ps1'` leaves $LASTEXITCODE
#   holding whatever the last NATIVE command inside it returned. win-snapshot
#   ends by probing `git config --get core.autocrlf`, which exits 1 when the key
#   is unset, so a perfectly good snapshot reported failure. Invoking the step
#   as a child with -File fixes it: measured 0 for a clean run, 3 for a genuine
#   `exit 3`, and 0 for a run whose internal native command exited 7. The extra
#   process is worth it to stop a diagnostic lying about whether it worked.
ps_step() {
  local script="$1" sh
  for sh in pwsh powershell.exe powershell; do
    command -v "$sh" >/dev/null 2>&1 || continue
    CMD=(env NO_COLOR=1 TERM=dumb "$sh" -NoProfile -NonInteractive -Command "
      \$ErrorActionPreference = 'Continue'
      [Console]::OutputEncoding = New-Object Text.UTF8Encoding \$false
      if (\$PSStyle) { \$PSStyle.OutputRendering = 'PlainText' }
      & $sh -NoProfile -NonInteractive -File '$script' 2>&1 | Out-String -Stream | ForEach-Object {
        [Console]::Out.Write(\$_ + [char]10)
      }
      exit \$LASTEXITCODE")
    return 0
  done
  echo "step '$STEP' is PowerShell, and neither pwsh nor powershell.exe is on PATH." >&2
  echo "Install PowerShell 7 (https://aka.ms/powershell), or run this step on a Windows control node." >&2
  exit 4
}

# --- pick the command (validate the step BEFORE any side effect) -------------
# Every step is an argv array. Keep them one line each so the table stays a
# readable index of what this branch can do.
case "$STEP" in
  env)  CMD=(./steps/env-snapshot.sh) ;;
  net)  CMD=(./steps/net-probe.sh) ;;
  win)  ps_step ./steps/win-snapshot.ps1 ;;

  # -- add task steps here (task branches only) -----------------------------
  # tfplan)  CMD=(./steps/tf-plan.sh) ;;
  # winev)   ps_step ./steps/win-events.ps1 ;;
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
