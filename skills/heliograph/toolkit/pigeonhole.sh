#!/usr/bin/env bash
# =============================================================================
#  pigeonhole.sh - the agent loop, over blob storage instead of git
# =============================================================================
#
#  Same contract as agent.sh: watch a request, run the step it names, ship the
#  captured log back. The only difference is the transport.
#
#  USE THIS WHEN THE CONTROL NODE CANNOT REACH THE GIT HOST. Not when it is
#  awkward - when it genuinely cannot. A host inside a locked-down subnet may
#  have no route off it at all, and git is then not a transport but a
#  dependency that cannot be met. Every other heliograph property is worth
#  keeping in that situation, so this replaces the poll source and the publish
#  sink and changes nothing else.
#
#  The shape is a dead letter drop: you cannot reach the far side, the far side
#  cannot reach you, and both can reach one agreed place. Azure Blob Storage
#  behind a private endpoint is that place, because traffic to a private
#  endpoint is VNet-local and never touches the route that is blocking
#  everything else. See references/pigeonhole.md.
#
#  WHY A SEPARATE FILE AND NOT A FLAG ON agent.sh. Wherever this is needed, a
#  git runner is usually still working somewhere else in the same estate. Two
#  transports in one loop would mean every future change to either has to be
#  reasoned about twice, and the failure mode of getting that wrong is a runner
#  answering a request it should never have seen. This file owns blob; agent.sh
#  owns git; neither knows about the other.
#
#  Everything BETWEEN the request and the log is shared: LOG_DIR and PUSH=0
#  hand run.sh's own capture back to us untouched, so timestamps, ANSI
#  stripping, redaction and the header/footer blocks are identical to a git
#  run. Only the poll source and the publish sink differ.
#
#  -------------------------------------------------------------------------
#  ENVIRONMENT
#
#    PIGEONHOLE_ACCOUNT   required. Azure Storage account name.
#    PIGEONHOLE_SAS       required. SAS token. Leading '?' optional.
#    PIGEONHOLE_LANE      which request this runner answers. Default: default
#    PIGEONHOLE_POLL      seconds between polls. Default: 10
#    PIGEONHOLE_PROGRESS  seconds between partial-log uploads. Default: 60
#    PIGEONHOLE_ONCE      set to 1 to answer one request and exit
#    PIGEONHOLE_ALLOW_ACTIONS
#                         set to 1 to permit steps that declare themselves
#                         actions. Default 0: this runner is read-only unless
#                         the operator says otherwise when starting it.
#    PIGEONHOLE_NO_ACTIONS
#                         the old spelling of the default. Still honoured.
#
#  It expects four containers on the account: requests, logs, status and agent.
#
#  THE LANE IS THIS TRANSPORT'S BRANCH BINDING. Two runners must never answer
#  one request - a heliograph log's whole value is that it says what ONE
#  machine saw, and two logs seconds apart from two hosts is a failure that
#  looks like success. Git got that from branch binding. There are no branches
#  here, so the lane is the blob path: a runner reads requests/<lane>.txt and
#  nothing else, and no two runners may share a lane.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=caplib.sh disable=SC1091
. "$HERE/caplib.sh"

LANE="${PIGEONHOLE_LANE:-default}"
POLL="${PIGEONHOLE_POLL:-10}"
PROGRESS_EVERY="${PIGEONHOLE_PROGRESS:-60}"
ACCOUNT="${PIGEONHOLE_ACCOUNT:-}"
SAS="${PIGEONHOLE_SAS:-}"

say() { printf '%s  %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }

# --- preflight ---------------------------------------------------------------
# Checked here rather than at first use. A container that starts, waits, and
# only fails when a request finally arrives is the worst shape this can take:
# nobody is watching the console, and the operator sees an unanswered request
# with no way in to find out why.
for v in ACCOUNT SAS; do
  if [ -z "${!v}" ]; then
    echo "pigeonhole: PIGEONHOLE_$v is not set. Cannot reach the drop." >&2
    exit 2
  fi
done
command -v curl >/dev/null 2>&1 || { echo "pigeonhole: curl is not installed." >&2; exit 2; }

# A SAS pasted from the portal carries a leading '?'; one from `az storage
# account generate-sas -o tsv` does not. Accept either rather than producing a
# URL with '??' in it, which fails as AuthenticationFailed and reads like a bad
# token rather than a bad string join.
SAS="${SAS#\?}"

BASE="https://${ACCOUNT}.blob.core.windows.net"
API_VERSION="2021-08-06"

# --- the drop ----------------------------------------------------------------
# Blob REST directly, not the SDK and not `az`. Two reasons, and neither is
# preference.
#
# THE CREDENTIAL. A SAS is validated by the storage service itself with no
# token round trip. Every Entra path needs a network call first - a managed
# identity needs IMDS, a service principal needs login.microsoftonline.com -
# and a host with no egress has neither. On a VNet-injected Azure Container
# Instance there is no IMDS at all, so managed identity is not merely
# unreachable, it is unavailable. A SAS is the only credential that works.
#
# THE CLIENT. curl is the one HTTP client that can be relied on. An image
# minimal enough to be worth deploying may have no `az` and no Python SDK, and
# nothing can be installed at runtime on a host that cannot reach a package
# repository. See references/pigeonhole.md.

drop_get() {
  # drop_get <container/path> [outfile]  -> 0 found, 1 absent, 2 error
  local path="$1" out="${2:-/dev/stdout}" code
  code="$(curl -sS -o "$out" -w '%{http_code}' \
            -H "x-ms-version: ${API_VERSION}" \
            "${BASE}/${path}?${SAS}" 2>/dev/null)" || return 2
  case "$code" in
    200) return 0 ;;
    404) return 1 ;;
    *)   say "drop_get ${path}: HTTP ${code}"; return 2 ;;
  esac
}

drop_put() {
  # drop_put <container/path> <file>
  local path="$1" file="$2" code
  code="$(curl -sS -o /dev/null -w '%{http_code}' -X PUT \
            -H "x-ms-version: ${API_VERSION}" \
            -H "x-ms-blob-type: BlockBlob" \
            -H "Content-Type: text/plain; charset=utf-8" \
            --data-binary "@${file}" \
            "${BASE}/${path}?${SAS}" 2>/dev/null)" || return 1
  case "$code" in
    201) return 0 ;;
    *)   say "drop_put ${path}: HTTP ${code}"; return 1 ;;
  esac
}

# --- request parsing ---------------------------------------------------------
# Same key: value shape as agent/request, deliberately. The format is what the
# operator and Claude both already read, and changing it alongside the
# transport would mean two things to relearn instead of one.
REQ_FILE=""
field() { sed -n "s/^${1}:[[:space:]]*//p" "$REQ_FILE" 2>/dev/null | head -1; }

# WHICH MACHINE SAW THIS is the one thing a heliograph log is for, so the host
# name is worth four fallbacks rather than one. `hostname` is NOT present in
# every image - measured 2026-08-26, the azure-cli image has no hostname and no
# tar - and an unguarded $(hostname) leaves the field empty and writes "command
# not found" to stderr, which is the least useful possible outcome for the one
# field that identifies the runner.
host_name() {
  if command -v hostname >/dev/null 2>&1; then
    hostname 2>/dev/null && return 0
  fi
  if [ -r /etc/hostname ]; then
    head -1 /etc/hostname 2>/dev/null && return 0
  fi
  printf '%s' "${HOSTNAME:-unknown}"
}

# --- status ------------------------------------------------------------------
# Published so the far side can see what is happening. Written to its own
# container so that polling "what is it doing" never lists a container that
# grows without bound.
publish_status() {
  local state="$1" id="$2" step="$3" extra="${4:-}"
  local tmp; tmp="$(mktemp)"
  {
    printf 'state:    %s\n' "$state"
    printf 'id:       %s\n' "$id"
    printf 'step:     %s\n' "$step"
    printf 'lane:     %s\n' "$LANE"
    printf 'host:     %s\n' "$(host_name)"
    printf 'utc:      %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    [ -n "$extra" ] && printf '%s\n' "$extra"
  } > "$tmp"
  drop_put "status/${LANE}.txt" "$tmp" || true
  rm -f "$tmp"
}

# --- progress ----------------------------------------------------------------
# A long run is not a black box. The partial log is uploaded on a timer while
# the step is still running, so the far side can see where it has got to
# instead of guessing between "slow" and "hung" - which an untimed log cannot
# distinguish, and which is the single most expensive ambiguity in this whole
# tool.
#
# One background job does both halves, because the first half has to finish
# before the second can start: run.sh names its log <step>-<UTC>.txt inside
# LOG_DIR and we do not know the stamp it chose. So this waits for the single
# file to appear in the run directory, then uploads it on the timer.
progress_pid=""
start_progress() {
  local rundir="$1" id="$2" step="$3"
  (
    local logfile=""
    while [ -z "$logfile" ]; do
      logfile="$(find "$rundir" -maxdepth 1 -type f -name '*.txt' 2>/dev/null | head -1)"
      [ -n "$logfile" ] && break
      sleep 1
    done
    while sleep "$PROGRESS_EVERY"; do
      [ -f "$logfile" ] || continue
      drop_put "logs/$(basename "${logfile%.txt}").partial.txt" "$logfile" || true
      publish_status "running" "$id" "$step" \
        "lines:    $(wc -l < "$logfile" 2>/dev/null || echo 0)"
    done
  ) &
  progress_pid=$!
}
stop_progress() {
  [ -n "$progress_pid" ] || return 0
  kill "$progress_pid" 2>/dev/null || true
  wait "$progress_pid" 2>/dev/null || true
  progress_pid=""
}

cleanup() { stop_progress; }

# A SIGNAL TRAP THAT ONLY TIDIES UP AND RETURNS DOES NOT STOP ANYTHING. Bash
# runs the handler and then resumes exactly where it was, so `trap cleanup EXIT
# INT TERM` left this loop polling forever through a SIGTERM. On a container
# platform that is the difference between a clean shutdown and being SIGKILLed
# when the grace period runs out - and a SIGKILLed agent writes no final status,
# so the far side is left with a heartbeat that simply stops.
#
# The exit codes are the shell's own convention, 128 + signal number, so a
# supervisor can tell a deliberate stop from a crash.
cleanup_and_exit() {
  local code="$1" name="$2"
  say "received SIG${name} - stopping"
  cleanup
  publish_status "stopped" "${LAST_ID:-}" "" "reason:   SIG${name}" || true
  trap - EXIT
  exit "$code"
}
trap cleanup EXIT
trap 'cleanup_and_exit 143 TERM' TERM
trap 'cleanup_and_exit 130 INT' INT

# --- action gate -------------------------------------------------------------
# Same rule as agent.sh, and for the same reason: this runner is unattended, so
# it is READ-ONLY unless the operator said otherwise when starting it.
#
# The step's own file says what it is (`# heliograph-mode: action`), read
# through run.sh --mode so the step table has one owner. The prefix convention
# this replaced - apply-*, deploy-*, fix-*, restart-* - could only ever see the
# steps whose authors happened to follow it.
#
# PIGEONHOLE_NO_ACTIONS=1 is kept, and is now the default. It stays because it
# is in the shipped container and pipeline templates, and a runner that starts
# refusing to start over a variable it used to accept helps nobody.
ACTION_ENV="${ACTION_ENV:-APPLY=1 CONFIRM=yes DESTROY=1 FORCE=1 WRITE=1}"
ALLOW_ACTIONS="${PIGEONHOLE_ALLOW_ACTIONS:-0}"
[ "${PIGEONHOLE_NO_ACTIONS:-0}" = "1" ] && ALLOW_ACTIONS=0
is_action_step() {
  local a
  [ "$("$HERE/run.sh" --mode "$1" 2>/dev/null | head -1)" = "action" ] && return 0
  for a in $ACTION_ENV; do
    case "${ENV_EXTRA:-}" in *"$a"*) return 0 ;; esac
  done
  return 1
}

# The account this runs as is the whole blast radius - see caplib.sh - and an
# unattended runner in a container is the last place to discover that late.
cap_refuse_root || exit 5

# =============================================================================
#  Main loop
# =============================================================================
say "pigeonhole starting"
say "  account : ${ACCOUNT}"
say "  lane    : ${LANE}   (requests/${LANE}.txt)"
say "  poll    : ${POLL}s"
say "  actions : $([ "$ALLOW_ACTIONS" = "1" ] && echo allowed || echo 'refused (the default)')"

# Proves the SAS and the network before anything depends on them, and leaves a
# record that this runner is alive even if no request ever arrives.
publish_status "starting" "" ""

LAST_ID=""
FIRST_POLL=1

while :; do
  REQ_FILE="$(mktemp)"
  if drop_get "requests/${LANE}.txt" "$REQ_FILE"; then
    ID="$(field id)"
    STEP="$(field step)"
    ENV_EXTRA="$(field env)"
    STOP="$(field stop)"
    CANCEL="$(field cancel)"

    if [ "$FIRST_POLL" = "1" ]; then
      # An id already in the drop at startup is not a trigger. A host whose
      # restart policy brings it back would otherwise re-run the last step
      # every time it came back, with nobody watching and no way to tell the
      # reruns apart.
      LAST_ID="$ID"
      FIRST_POLL=0
      [ -n "$ID" ] && say "startup: id '${ID}' already present, not re-running it"
      publish_status "idle" "$ID" "$STEP"
      rm -f "$REQ_FILE"; sleep "$POLL"; continue
    fi

    # CANCEL IS NOT IMPLEMENTED HERE, AND SAYS SO RATHER THAN DOING NOTHING.
    # agent.sh can cancel because it runs the step detached and stays
    # responsive; this loop runs the step in the foreground and is deaf until
    # it returns. Accepting the field silently would be the worst outcome:
    # somebody writes `cancel: yes` to stop a wrong run, sees no error, and
    # believes the run was reaped when it is still going.
    if [ -n "$CANCEL" ]; then
      say "NOTE: 'cancel' is set, and this transport does not implement it."
      say "      The step runs in the foreground, so the loop cannot hear a"
      say "      cancel while one is in flight. Stop the host to end a run."
    fi

    if [ "$STOP" = "yes" ]; then
      say "stop requested - exiting cleanly"
      publish_status "stopped" "$ID" "$STEP"
      rm -f "$REQ_FILE"
      exit 0
    fi

    # THE TRIGGER IS THE id, NOT A CHANGED BLOB. The request blob is
    # overwritten for all sorts of reasons - a note, a corrected env line, a
    # typo fixed - and none of those should set a step running.
    if [ -n "$ID" ] && [ "$ID" != "$LAST_ID" ]; then
      STEP="${STEP:-}"
      say "request ${ID}: step '${STEP:-<default>}'"

      if [ -n "$STEP" ] && is_action_step "$STEP" && [ "$ALLOW_ACTIONS" != "1" ]; then
        say "refusing '${STEP}': it changes state and this runner is read-only (the default)"
        publish_status "refused" "$ID" "$STEP" "reason:   step changes state; restart with PIGEONHOLE_ALLOW_ACTIONS=1 to permit it"
        LAST_ID="$ID"
        rm -f "$REQ_FILE"
        # A refusal is an answer, as below: a --once runner that has published
        # one has done its job and must not sit polling over a question it has
        # already responded to.
        if [ "${PIGEONHOLE_ONCE:-0}" = "1" ]; then
          say "PIGEONHOLE_ONCE=1 - request refused, exiting"
          exit 0
        fi
        sleep "$POLL"; continue
      fi

      # A fresh directory per run, so the log this run produced is the only
      # file in it. Scanning ops-logs/ by timestamp instead would pick up a
      # previous run's file whenever a step produced none.
      RUN_DIR="$(mktemp -d)"
      publish_status "running" "$ID" "$STEP"

      start_progress "$RUN_DIR" "$ID" "${STEP:-default}"

      # PUSH=0 stops caplib committing anything: there is no repo to commit to
      # on this runner, and cap_push would fail loudly at the end of every
      # otherwise-successful run. LOG_DIR hands us the file instead.
      #
      # THE ENV LINE IS SPLIT THE WAY A SHELL WOULD, not word-split, and the
      # difference is not cosmetic. `env $ENV_EXTRA` unquoted looks like it
      # handles `HOSTS="a b" PORTS=443`, and it does not: parameter expansion
      # splits on spaces but performs NO quote removal, so env receives
      # HOSTS="a and then treats b" as the command to run. That fails with
      # exit 127 and NO LOG AT ALL, because run.sh never starts - measured
      # 2026-08-26 on the first net request through the pigeonhole.
      #
      # The guard comes first, and it is the part worth keeping. The request is
      # already a trusted control channel - it names the step to run - but
      # trusted is not a reason to hand it a subshell, and the eval below
      # assigns an ARRAY rather than running a command line, so a value that
      # got past the guard still could not execute. Two locks, because the
      # blast radius is a host nobody can log into to clean up.
      #
      # A refusal naming the character costs one round trip less than a
      # surprise. Same treatment as agent.sh, deliberately: one bug, one shape.
      REFUSE=""
      case "$ENV_EXTRA" in
        *'$'* | *'`'* | *';'* | *'&'* | *'|'* | *'<'* | *'>'* | *'('* )
          REFUSE="env line contains a shell metacharacter, which this does not evaluate" ;;
      esac
      if [ -z "$REFUSE" ] && [ -n "$ENV_EXTRA" ]; then
        eval "ENVARR=($ENV_EXTRA)" 2>/dev/null || \
          REFUSE="env line is not parseable as NAME=value pairs"
      else
        ENVARR=()
      fi
      if [ -n "$REFUSE" ]; then
        say "REFUSED: ${REFUSE}"
        say "  env: ${ENV_EXTRA}"
        say "  Use plain NAME=value pairs; quote a value that contains spaces."
        stop_progress
        publish_status "refused" "$ID" "$STEP" "reason:   ${REFUSE}"
        rm -rf "$RUN_DIR"
        LAST_ID="$ID"
        rm -f "$REQ_FILE"
        # A REFUSAL IS AN ANSWER. `once` means answer one request and exit, and
        # a request that was refused has been answered - the far side has a
        # status saying so. Carrying on would leave a --once runner polling
        # forever over a question it has already responded to.
        if [ "${PIGEONHOLE_ONCE:-0}" = "1" ]; then
          say "PIGEONHOLE_ONCE=1 - request refused, exiting"
          exit 0
        fi
        sleep "$POLL"; continue
      fi

      [ -n "$ENV_EXTRA" ] && say "env: ${ENV_EXTRA}"
      if [ "${#ENVARR[@]}" -gt 0 ]; then
        LOG_DIR="$RUN_DIR" PUSH=0 env "${ENVARR[@]}" "$HERE/run.sh" ${STEP:+"$STEP"}
      else
        LOG_DIR="$RUN_DIR" PUSH=0 "$HERE/run.sh" ${STEP:+"$STEP"}
      fi
      RC=$?

      stop_progress

      LOG_FILE="$(find "$RUN_DIR" -maxdepth 1 -type f -name '*.txt' 2>/dev/null | head -1)"
      if [ -n "$LOG_FILE" ] && [ -f "$LOG_FILE" ]; then
        BLOB="logs/$(basename "$LOG_FILE")"
        if drop_put "$BLOB" "$LOG_FILE"; then
          say "log delivered: ${BLOB}  exit=${RC}"
          publish_status "idle" "$ID" "$STEP" \
            "$(printf 'exit:     %s\nlog:      %s\nlines:    %s' \
                 "$RC" "$BLOB" "$(wc -l < "$LOG_FILE")")"
        else
          # The log exists and cannot be shipped. Say so in the status, which
          # goes to a different blob and may still get through - otherwise the
          # far side sees a request that was picked up and never answered, and
          # cannot tell that from a hung step.
          say "LOG CAPTURED BUT NOT DELIVERED: ${LOG_FILE}"
          publish_status "undelivered" "$ID" "$STEP" \
            "$(printf 'exit:     %s\nreason:   blob PUT failed - SAS expired or write permission missing' "$RC")"
        fi
      else
        say "step produced no log file"
        publish_status "idle" "$ID" "$STEP" \
          "$(printf 'exit:     %s\nlog:      (none produced)' "$RC")"
      fi

      rm -rf "$RUN_DIR"
      LAST_ID="$ID"

      if [ "${PIGEONHOLE_ONCE:-0}" = "1" ]; then
        say "PIGEONHOLE_ONCE=1 - one request answered, exiting"
        rm -f "$REQ_FILE"
        exit 0
      fi
    fi
  else
    # No request blob yet is the normal resting state of a freshly created
    # drop, not an error. Say it once rather than every poll.
    if [ "$FIRST_POLL" = "1" ]; then
      say "no request at requests/${LANE}.txt yet - waiting"
      publish_status "idle" "" ""
      FIRST_POLL=0
    fi
  fi

  rm -f "$REQ_FILE"
  sleep "$POLL"
done
