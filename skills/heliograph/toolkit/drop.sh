#!/usr/bin/env bash
# =============================================================================
#  drop.sh - the operator's side of the pigeonhole
# =============================================================================
#
#  pigeonhole.sh runs inside the estate and cannot be reached. This is what talks
#  to it: it writes the request, ships the agent's own code, and reads the logs
#  back. Neither side can reach the other; both reach the storage account.
#
#      ./drop.sh bundle                 build and upload the agent's code
#      ./drop.sh send <id> <step> [env] queue a step for the agent to run
#      ./drop.sh status                 what is the agent doing right now
#      ./drop.sh logs                   what has come back
#      ./drop.sh get <blob>             download one log and print it
#      ./drop.sh watch                  poll until the run finishes, then print
#      ./drop.sh stop                   tell the agent to exit cleanly
#
#  AUTHENTICATION IS NOT SYMMETRIC, and that is the point of the whole design.
#  This side uses Entra (`--auth-mode login`) because it has internet and can
#  reach login.microsoftonline.com. The agent cannot, so it uses a SAS. Neither
#  credential works on the other side.
#
#  Environment
#    PIGEONHOLE_ACCOUNT  storage account. Read from terraform output if unset.
#    PIGEONHOLE_LANE     which request to write. Default: default
#    PIGEONHOLE_GROUP    the agent's container group, for the restart hint only.
#    PIGEONHOLE_RG       its resource group, likewise.
#    TF_DIR              a terraform directory whose output names the account.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LANE="${PIGEONHOLE_LANE:-default}"

die() { echo "drop: $*" >&2; exit 1; }

# The account name is discovered rather than hardcoded, because a storage
# account name is globally unique and therefore usually carries a random
# suffix. Writing one into this file would mean editing the file every time the
# stack is rebuilt - and this file ships into every transport repo, so it must
# not know anything about any particular estate.
#
# TF_DIR has no default on purpose. A guessed path that happens to contain a
# terraform state is worse than no path at all: it would read an account name
# from the wrong stack and then write a request into somebody else's drop.
account() {
  if [ -n "${PIGEONHOLE_ACCOUNT:-}" ]; then
    printf '%s' "$PIGEONHOLE_ACCOUNT"
    return 0
  fi
  if [ -n "${TF_DIR:-}" ]; then
    local name
    name="$(cd "$TF_DIR" 2>/dev/null && terraform output -raw transport_account_name 2>/dev/null)"
    if [ -n "$name" ]; then printf '%s' "$name"; return 0; fi
    die "TF_DIR is set to '$TF_DIR' but 'terraform output -raw transport_account_name' produced nothing there"
  fi
  die "set PIGEONHOLE_ACCOUNT to the storage account name, or TF_DIR to a terraform directory whose 'transport_account_name' output names it"
}

# Only ever printed as a hint, never called. Left blank when unset rather than
# guessed: a wrong resource name in a suggested command is worse than no
# suggestion, because somebody runs it.
restart_hint() {
  if [ -n "${PIGEONHOLE_RG:-}" ] && [ -n "${PIGEONHOLE_GROUP:-}" ]; then
    echo "  az container restart -g ${PIGEONHOLE_RG} -n ${PIGEONHOLE_GROUP}"
  else
    echo "  restart the agent however it is hosted - for Azure Container"
    echo "  Instances: az container restart -g <rg> -n <container-group>"
    echo "  (set PIGEONHOLE_RG and PIGEONHOLE_GROUP to print the exact command)"
  fi
}

cmd="${1:-}"; shift 2>/dev/null || true

# Usage before account resolution, deliberately. Every command below needs the
# account, but somebody typing `./drop.sh` to find out what it does should get
# the answer, not "cannot find the account" - which reads like a broken tool
# rather than a missing argument.
case "$cmd" in
  ""|-h|--help|help)
    sed -n '2,28p' "$0" | sed 's/^# \{0,2\}//'
    exit 2
    ;;
esac

ACCOUNT="$(account)" || exit 1

blob_up() {   # blob_up <container> <name> <file>
  az storage blob upload --account-name "$ACCOUNT" --auth-mode login --only-show-errors \
     --container-name "$1" --name "$2" --file "$3" --overwrite --output none
}
blob_down() { # blob_down <container> <name> <file>
  az storage blob download --account-name "$ACCOUNT" --auth-mode login --only-show-errors \
     --container-name "$1" --name "$2" --file "$3" --output none 2>/dev/null
}

case "$cmd" in

# --- the agent's own code ----------------------------------------------------
# Everything pigeonhole.sh needs at runtime, in one artifact. The container has
# no way to clone the repo, so this IS how the agent is deployed - and why
# updating it is an upload rather than a redeploy of the container group.
bundle)
  tmp="$(mktemp -d)"
  # Only what the agent runs. start.sh, agent.sh and the git machinery stay
  # behind deliberately: they belong to the pipeline runner, and shipping a
  # second transport into the container is how a runner ends up answering a
  # request on a path nobody expected.
  #
  # lib/ IS NOT OPTIONAL, and leaving it out does not fail loudly. Every step
  # sources lib/probe.sh for probe, probe_opt, sec, have and probe_summary;
  # without it the step still runs, every helper reports "command not found",
  # and the log fills with lines like "curl -- not installed --" on a host
  # where curl is installed. A log that reports confident falsehoods is worse
  # than one that fails - measured 2026-08-26, the first real run through the
  # pigeonhole.
  tar czf "$tmp/bundle.tgz" -C "$HERE" \
      pigeonhole.sh caplib.sh run.sh steps/ lib/ \
      || die "could not build the bundle"
  blob_up agent bundle.tgz "$tmp/bundle.tgz" || die "upload failed"
  echo "bundle uploaded: $(du -h "$tmp/bundle.tgz" | cut -f1)  -> ${ACCOUNT}/agent/bundle.tgz"
  echo "The agent picks it up on its next restart. To force one now:"
  restart_hint
  rm -rf "$tmp"
  ;;

# --- queue a step ------------------------------------------------------------
# THE TRIGGER IS THE id. The agent runs when this value CHANGES, so rewriting
# the request with the same id - to fix a note or a typo - sets nothing going.
send)
  id="${1:-}"; step="${2:-}"; shift 2 2>/dev/null || true
  [ -n "$id" ] || die "usage: drop.sh send <id> <step> [ENV=val ...]"
  tmp="$(mktemp)"
  {
    printf 'id: %s\n' "$id"
    printf 'step: %s\n' "$step"
    printf 'env: %s\n' "$*"
    printf 'cancel:\n'
    printf 'stop:\n'
    printf 'note: sent %s by %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(whoami)"
  } > "$tmp"
  blob_up requests "${LANE}.txt" "$tmp" || die "could not write the request"
  echo "sent: id=${id} step=${step:-<default>} lane=${LANE}"
  [ -n "$*" ] && echo "env: $*"
  rm -f "$tmp"
  ;;

# --- what is it doing --------------------------------------------------------
status)
  tmp="$(mktemp)"
  if blob_down status "${LANE}.txt" "$tmp"; then
    cat "$tmp"
  else
    echo "no status blob for lane '${LANE}'."
    echo "The agent has never started, or started and cannot write. Those are"
    echo "different faults: the first is the host, the second is the SAS."
    if [ -n "${PIGEONHOLE_RG:-}" ] && [ -n "${PIGEONHOLE_GROUP:-}" ]; then
      echo "  az container show -g ${PIGEONHOLE_RG} -n ${PIGEONHOLE_GROUP} \\"
      echo "    --query 'containers[0].instanceView.{state:currentState.state,restarts:restartCount,events:events[].message}'"
    else
      echo "Check the host's own state and events. On Azure Container Instances"
      echo "a crash-looping VNet-injected group returns NO logs, so read its"
      echo "events rather than az container logs."
    fi
  fi
  rm -f "$tmp"
  ;;

# --- what has come back ------------------------------------------------------
logs)
  az storage blob list --account-name "$ACCOUNT" --auth-mode login --only-show-errors \
     --container-name logs --query "reverse(sort_by([].{name:name,size:properties.contentLength,modified:properties.lastModified}, &modified))" \
     -o table
  ;;

get)
  name="${1:-}"; [ -n "$name" ] || die "usage: drop.sh get <blob-name>"
  name="${name#logs/}"
  tmp="$(mktemp)"
  blob_down logs "$name" "$tmp" || die "no such log: $name"
  cat "$tmp"
  rm -f "$tmp"
  ;;

# --- wait for the run to finish ---------------------------------------------
# A run is finished when the status blob's id matches what we sent AND its
# state is no longer 'running'. Polling the log container instead would race:
# the partial log appears long before the run is over.
watch)
  want="${1:-}"
  echo "watching lane '${LANE}'${want:+ for id ${want}}. Ctrl-C to stop."
  last=""
  while :; do
    tmp="$(mktemp)"
    if blob_down status "${LANE}.txt" "$tmp"; then
      state="$(sed -n 's/^state:[[:space:]]*//p' "$tmp" | head -1)"
      id="$(sed -n 's/^id:[[:space:]]*//p' "$tmp" | head -1)"
      line="${state} ${id}"
      if [ "$line" != "$last" ]; then
        printf '%s  %s\n' "$(date -u +%H:%M:%SZ)" "$(tr '\n' ' ' < "$tmp")"
        last="$line"
      fi
      if [ "$state" != "running" ] && [ "$state" != "starting" ]; then
        if [ -z "$want" ] || [ "$id" = "$want" ]; then
          log="$(sed -n 's/^log:[[:space:]]*//p' "$tmp" | head -1)"
          if [ -n "$log" ] && [ "$log" != "(none produced)" ]; then
            echo
            "$0" get "$log"
          fi
          rm -f "$tmp"
          exit 0
        fi
      fi
    fi
    rm -f "$tmp"
    sleep 10
  done
  ;;

# --- shut it down ------------------------------------------------------------
# A clean exit, not a kill. The container group's restart policy is OnFailure,
# so an agent that exits 0 stays stopped rather than coming straight back.
stop)
  tmp="$(mktemp)"
  {
    printf 'id: %s\n' "$(date -u +%Y%m%dT%H%M%SZ)-stop"
    printf 'step:\n'
    printf 'env:\n'
    printf 'cancel:\n'
    printf 'stop: yes\n'
    printf 'note: stopped %s by %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(whoami)"
  } > "$tmp"
  blob_up requests "${LANE}.txt" "$tmp" || die "could not write the request"
  echo "stop sent to lane '${LANE}'. The agent exits after its current step."
  rm -f "$tmp"
  ;;

*)
  sed -n '2,28p' "$0" | sed 's/^# \{0,2\}//'
  exit 2
  ;;
esac
