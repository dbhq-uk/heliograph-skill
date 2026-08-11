#!/usr/bin/env bash
# =============================================================================
#  steps/_template.sh - copy this to start a new step
# =============================================================================
#   cp steps/_template.sh steps/my-step.sh && chmod +x steps/my-step.sh
#   then add   my-step)  CMD=(./steps/my-step.sh) ;;   to run.sh
#   and list it in the step table comment at the top of run.sh
#
# Contract for a step script:
#   - print to stdout; the runner owns the log, the timestamps and the push
#   - NO `set -e` - a diagnostic wants every probe's result, not the first fail
#   - never prompt for anything (no interactive sudo, no host-key questions)
#   - name the step for what it ANSWERS, not for what it runs
#   - state-changing steps: say so at the top, and gate them in run.sh
#
# TRAPS THAT HAVE COST ROUND TRIPS. Each of these produced a log that looked
# like a finding about the estate and was actually a bug in the step. Across an
# air gap that costs a full cycle, so they are worth knowing by heart:
#
#   - BACKTICKS INSIDE DOUBLE QUOTES EXECUTE.  probe "check the `service` key"
#     runs `service` and substitutes its output. Use single quotes for a label
#     containing backticks. (Bit us four times in one investigation.)
#
#   - /bin/sh IS dash HERE, NOT bash.  No process substitution `<(...)`, no
#     ANSI-C quoting `$'\t'`. Both fail in ways that look like data problems - #     `IFS=$'\t'` silently splits on the letter "t". Use `bash -c` for anything
#     beyond plain POSIX.
#
#   - `| head` CAN KILL THE SCRIPT.  Under `set -euo pipefail`, head closing the
#     pipe gives the producer SIGPIPE, pipefail propagates 141 and set -e exits.
#     It is timing-dependent, so it passes the dry run and fails the real one.
#     Use `awk 'NR<=N'`, which reads to the end.
#
#   - AN EXPANDED `case` PATTERN IS A LITERAL.  `case $x in $pat)` with
#     pat='*a*|*b*' matches a literal pipe, not alternation, and silently
#     matches nothing. Use `[[ $x =~ $re ]]`.
#
#   - `"${VAR:-${ARRAY[@]}}"` COLLAPSES TO ONE WORD.  Build the list with an
#     explicit if/else or the loop runs once.
#
#   - A DIAGNOSTIC MUST NEVER ABORT THE OPERATION IT DESCRIBES.  Put `|| true`
#     behind anything that only exists to make the log readable.
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/../lib/probe.sh"
# . "$HERE/../lib/remote.sh"      # rt_ssh / rt_ps / rt_tcp / rt_matrix
# . "$HERE/../lib/terraform.sh"   # tf_plan / tf_state_list / tf_workspace
# . "$HERE/../lib/ansible.sh"     # an_play / an_ping / an_facts

# --- what this step is trying to settle --------------------------------------
# One sentence. If you can't write it, the step is doing too much - split it.
echo "STEP: <question this answers>"

# --- the control -------------------------------------------------------------
# Where possible, measure something KNOWN-GOOD in the same run. A result with
# nothing to compare against is an anecdote; the same probe against a working
# host in the same log is evidence.
# probe "control: same check against <known-good>" true

# --- the probes --------------------------------------------------------------
probe "example" echo "replace me"

probe_summary
