#!/usr/bin/env bash
# =============================================================================
#  run.sh - the step runner.  ONE command for the operator to remember.
# =============================================================================
#
#     git pull && ./run.sh            # runs whatever step is currently set
#     git pull && ./run.sh <step>     # or name one explicitly
#     ./run.sh --list                 # what steps exist on this branch
#     ./run.sh --mode <step>          # what that step DECLARES itself to be
#     ./run.sh --file <step>          # which file that declaration came from
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
#      tools  what this host can do: every tool, python module and ODBC driver
#    ACTIONS (change something - never make one the default step)
#      (none on main)
#
#    Which of the two a step is comes from the step's OWN FILE, not from this
#    table and not from its name: `# heliograph-mode: read-only` or `action` in
#    its first 30 lines. A step declaring neither will not run.
# ==============================================================

# --mode <step> answers what a step declares itself to be; --file <step> answers
# which file that declaration was read from. Both exit having touched nothing.
# agent.sh asks through here rather than reading the step table itself, so the
# mapping from a step name to a file stays in ONE place - two copies of it would
# drift the first time somebody registered a step that takes arguments.
QUERY=""
case "${1:-}" in
  --mode) QUERY="mode"; shift ;;
  --file) QUERY="file"; shift ;;
esac
MODE_QUERY=0
[ -n "$QUERY" ] && MODE_QUERY=1

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
  # Before the interpreter hunt, deliberately: --mode has to be answerable on a
  # machine with no PowerShell on it at all, and the declaration lives in the
  # .ps1 file rather than in whatever runs it.
  STEP_FILE="$script"
  [ "$MODE_QUERY" = "1" ] && return 0
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
#
# STEP_FILE is the script whose header declares the step's mode. It defaults to
# CMD[0], which is right for every ordinary step; set it explicitly in an arm
# whose CMD[0] is an interpreter rather than the step itself.
STEP_FILE=""
case "$STEP" in
  env)  CMD=(./steps/env-snapshot.sh) ;;
  net)  CMD=(./steps/net-probe.sh) ;;
  win)  ps_step ./steps/win-snapshot.ps1 ;;
  tools) CMD=(./steps/tools-inventory.sh) ;;

  # -- add task steps here (task branches only) -----------------------------
  # tfplan)  CMD=(./steps/tf-plan.sh) ;;
  # winev)   ps_step ./steps/win-events.ps1 ;;
  # deploy)  CMD=(./steps/deploy.sh) ;;      # declares 'action' - never the default step

  *)
    echo "unknown step: $STEP" >&2
    echo "run '$0 --list' to see the steps on this branch." >&2
    exit 2 ;;
esac

# --- a step declares what it is, and an undeclared step does not run ----------
# This gate used to be a list of step NAMES - `reset|destroy|apply|deploy`. The
# hole in that was not subtle: `cleanup-disk` matches none of them and was waved
# through as a diagnostic, while a read-only step that happened to be called
# `deploy` was gated for its spelling. A filename is not evidence about
# behaviour.
#
# So every step file carries, in its first 30 lines:
#
#     # heliograph-mode: read-only        (or: action)
#
# and the runner reads it from the file it is about to execute. Missing or
# unrecognised REFUSES - fail closed, because the alternative is inferring
# authority from a step that never claimed any.
#
# What this does NOT do, and the documentation says so too: stop an author
# declaring read-only and then writing `rm -rf`. Nothing in a shell runner can.
# It makes the classification an explicit statement in the file being run,
# checked at the boundary, instead of a guess made from its name.
STEP_FILE="${STEP_FILE:-${CMD[0]-}}"
MODE="$(sed -n '1,30{s/^#[[:space:]]*heliograph-mode:[[:space:]]*\([A-Za-z-]*\).*/\1/p;}' "$STEP_FILE" 2>/dev/null | head -1)"

if [ "$MODE_QUERY" = "1" ]; then
  case "$QUERY" in
    mode) printf '%s\n' "${MODE:-undeclared}" ;;
    file) printf '%s\n' "$STEP_FILE" ;;
  esac
  case "$MODE" in read-only|action) exit 0 ;; *) exit 3 ;; esac
fi

case "$MODE" in
  read-only) ;;
  action)
    if [ "${CONFIRM:-}" != "yes" ]; then
      echo "step '$STEP' declares 'heliograph-mode: action' - it changes state." >&2
      echo "Re-run with: CONFIRM=yes ./run.sh $STEP" >&2
      exit 3
    fi ;;
  "")
    echo "step '$STEP' ($STEP_FILE) declares no mode, so it will not run." >&2
    echo "Add one of these to the file, in its first 30 lines:" >&2
    echo "    # heliograph-mode: read-only     # measures, changes nothing" >&2
    echo "    # heliograph-mode: action        # changes state; needs CONFIRM=yes" >&2
    exit 3 ;;
  *)
    echo "step '$STEP' ($STEP_FILE) declares 'heliograph-mode: $MODE', which is not a mode." >&2
    echo "The two accepted values are 'read-only' and 'action'. Nothing else is guessed at." >&2
    exit 3 ;;
esac

# The account is the blast radius, so it is checked before anything is captured
# and after the step has been validated - an unknown step should still say it is
# unknown, whoever is asking.
cap_refuse_root || exit 5

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
# ***NO_CI*** is not decoration. When the runner is a build agent, this push is
# a commit to the same repo the pipeline watches, so without a marker the log
# push re-triggers the pipeline, which pushes a log, which re-triggers it.
# GitHub Actions refuses to trigger on a GITHUB_TOKEN push and needs no help;
# Azure DevOps has no equivalent, so this is the only guard that travels with
# the commit rather than living in one host's trigger configuration.
cap_push "$OUT" "step: $STEP ($STAMP) exit=$RC ***NO_CI***"

cap_result "step $STEP" "$RC" "$OUT"
exit "$RC"
