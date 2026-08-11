#!/usr/bin/env bash
# =============================================================================
#  agent.sh - run this ONCE on the control node and walk away
# =============================================================================
#     ./agent.sh                    # poll, run, push, repeat
#     ./agent.sh --once             # do one requested run, then exit
#     ./agent.sh --interval 15      # seconds between polls (default 5)
#
#  It watches this branch for a new request, runs the step, and pushes the log
#  back - so the loop stops needing a human to relay each run:
#
#     Claude   edits agent/request (new id), pushes ─────────────▶ repo
#     agent    sees it within seconds, runs ./run.sh
#              pushes agent/status "running" ────────────────────▶ repo
#              run.sh pushes ops-logs/<step>-<UTC>.txt ──────────▶ repo
#              pushes agent/status "idle exit=N" ────────────────▶ repo
#     Claude   polls, reads the log, decides the next step ◀──────
#
#  The operator types one command, once. Everything after that is git.
#
#  THE TRIGGER IS `id`, NOT "a new commit". Documentation and step edits land in
#  this branch constantly; if any commit triggered a run, the agent would fire on
#  all of them. It runs only when the `id:` line in agent/request changes, so a
#  run is always something someone asked for on purpose.
#
#  STOPPING: `stop: yes` in agent/request, or Ctrl-C. The stop flag is honoured
#  from the far side precisely because nobody is sitting at this terminal.
#
#  SAFETY: agent/request names the step. ALLOW_ACTIONS controls whether the agent
#  will run one that changes state - see below. Nothing here overrides run.sh's
#  own CONFIRM gate; if a step is gated there, the request must pass CONFIRM=yes
#  in `env:` and ALLOW_ACTIONS must be on.
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT" || exit 1
# shellcheck source=caplib.sh disable=SC1091
. "$REPO_ROOT/caplib.sh"

# Kept so the agent can re-exec itself into a newer version of this file - see
# the self-update check in the loop. The option parser below consumes "$@".
ORIG_ARGS=("$@")
SELF_HASH="$(sha256sum "$REPO_ROOT/agent.sh" 2>/dev/null | cut -d' ' -f1)"

INTERVAL="${INTERVAL:-5}"
ONCE=0
# 1 = the agent may run steps that change state, when the request asks for one.
# On main this defaults to 0: an unattended loop that can apply infrastructure
# because a file changed is a different risk from one that only reads. A task
# branch can turn it on deliberately.
ALLOW_ACTIONS="${ALLOW_ACTIONS:-0}"
# Steps that change something. Kept in step with run.sh's own gate list.
ACTION_STEPS="${ACTION_STEPS:-apply deploy destroy reset}"

REQUEST="agent/request"
STATUS="agent/status"
STATE_FILE=".agent-state"        # gitignored: the last id we ran
LOCK=".agent.lock"

while [ $# -gt 0 ]; do
  case "$1" in
    --once)          ONCE=1 ;;
    --interval)      INTERVAL="$2"; shift ;;
    --allow-actions) ALLOW_ACTIONS=1 ;;
    -h|--help)       sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
[ -n "$BRANCH" ] && [ "$BRANCH" != "HEAD" ] || { echo "agent: not on a branch - checkout the task branch first" >&2; exit 2; }

# One agent per checkout. Two would double-run every request and race on push.
if [ -e "$LOCK" ]; then
  pid="$(cat "$LOCK" 2>/dev/null || echo)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    echo "agent: already running here as pid $pid (remove $LOCK if that is wrong)" >&2; exit 3
  fi
  echo "agent: clearing a stale lock from pid ${pid:-?}"
fi
echo $$ > "$LOCK"

say() { printf '%s  %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }

RUNNING=0
cleanup() {
  rm -f "$LOCK"
  [ "$RUNNING" = "1" ] && say "interrupted mid-run - the log may not have been pushed"
  say "stopped"
  exit 0
}
trap cleanup INT TERM

# --- request parsing ---------------------------------------------------------
# Deliberately dumb key: value. No YAML parser, nothing to install, and the file
# stays readable by whoever opens it next.
field() { sed -n "s/^${1}:[[:space:]]*//p" "$REQUEST" 2>/dev/null | head -1; }

# A step is an action if its NAME says so, or if the request's env turns it into
# one. The name-only version had a hole: a step named for a diagnostic that
# plans is read-only until `env: APPLY=1` makes it apply, and it then sailed
# straight through the gate while a step called `apply` was refused. Gating on
# the name alone cannot see that, so the env is checked too.
#
# ACTION_ENV is a substring match against the request's env line. Add whatever
# turns a read-only step into a writing one on your branch.
ACTION_ENV="${ACTION_ENV:-APPLY=1 CONFIRM=yes DESTROY=1 FORCE=1 WRITE=1}"
is_action_step() {
  local s="$1" a
  for a in $ACTION_STEPS; do [ "$s" = "$a" ] && return 0; done
  for a in $ACTION_ENV; do
    case "${ENVLINE:-}" in *"$a"*) return 0 ;; esac
  done
  return 1
}

# --- status, pushed so the far side can see what is happening ----------------
# Two extra commits per run. Worth it: without the "running" one, a long step is
# indistinguishable from an agent that never woke up.
publish_status() {
  local state="$1" id="$2" step="$3" extra="${4:-}"
  mkdir -p agent
  {
    echo "state:    $state"
    echo "id:       $id"
    echo "step:     $step"
    echo "host:     $(hostname -f 2>/dev/null || hostname)"
    echo "branch:   $BRANCH"
    echo "utc:      $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    [ -n "$extra" ] && echo "$extra"
  } > "$STATUS"
  git add -f "$STATUS" >/dev/null 2>&1
  git diff --cached --quiet -- "$STATUS" >/dev/null 2>&1 && return 0
  git -c user.name="${GIT_AUTHOR_NAME:-agent}" \
      -c user.email="${GIT_AUTHOR_EMAIL:-agent@$(hostname)}" \
      commit -q -m "agent: $state ($id)" -- "$STATUS" 2>/dev/null
  cap_git pull --rebase --quiet >/dev/null 2>&1
  cap_git push --quiet >/dev/null 2>&1 || cap_git push --quiet -u origin HEAD >/dev/null 2>&1 || \
    say "status push failed (will retry on the next transition)"
}

say "agent up on $BRANCH at $(hostname -f 2>/dev/null || hostname), polling every ${INTERVAL}s"
if [ "$ALLOW_ACTIONS" = "1" ]; then
  say "state-changing steps: ALLOWED ($ACTION_STEPS)"
else
  say "state-changing steps: BLOCKED - start with --allow-actions to permit them"
fi
say "request 'stop: yes' or Ctrl-C to finish"
LAST_ID="$(cat "$STATE_FILE" 2>/dev/null || echo)"
[ -n "$LAST_ID" ] && say "last request handled here: $LAST_ID"

FAILS=0
while :; do
  # A fetch failure is a blip, not a reason to die - this loop is meant to
  # outlive a flapping link. Report it, back off a little, carry on.
  if ! cap_git fetch --quiet origin "$BRANCH" 2>/dev/null; then
    FAILS=$((FAILS + 1))
    [ $((FAILS % 12)) = 1 ] && say "fetch failed (${FAILS}x) - still trying"
    sleep "$INTERVAL"; continue
  fi
  [ "$FAILS" != "0" ] && { say "fetch recovered"; FAILS=0; }

  LOCAL="$(git rev-parse HEAD 2>/dev/null)"
  REMOTE="$(git rev-parse "origin/$BRANCH" 2>/dev/null)"
  if [ "$LOCAL" != "$REMOTE" ]; then
    if cap_git pull --rebase --quiet 2>/dev/null; then
      say "pulled $(git log --oneline -1)"
    else
      say "pull --rebase failed - working tree may be dirty; leaving it alone"
      cap_git rebase --abort >/dev/null 2>&1
      sleep "$INTERVAL"; continue
    fi

    # Self-update. Without this, a fix to agent.sh cannot take effect while the
    # agent is running it, and the operator has to be told to restart - which
    # defeats the point of them starting it once and walking away. Worse, bash
    # reads a script incrementally, so editing this file underneath a running
    # loop can corrupt execution outright.
    #
    # Re-exec at this exact point, immediately after a clean pull and never
    # mid-run, so the replacement starts from a known state. exec keeps the PID,
    # so the lock has to go first or the new process refuses to start seeing
    # "another agent" that is really itself.
    NEW_HASH="$(sha256sum "$REPO_ROOT/agent.sh" 2>/dev/null | cut -d' ' -f1)"
    if [ -n "$NEW_HASH" ] && [ "$NEW_HASH" != "$SELF_HASH" ]; then
      say "agent.sh changed - restarting into the new version"
      rm -f "$LOCK"
      exec "$REPO_ROOT/agent.sh" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
    fi
  fi

  [ -f "$REQUEST" ] || { sleep "$INTERVAL"; continue; }

  if [ "$(field stop)" = "yes" ]; then
    say "stop requested in $REQUEST"
    publish_status "stopped" "$(field id)" "" ""
    cleanup
  fi

  ID="$(field id)"
  [ -n "$ID" ] || { sleep "$INTERVAL"; continue; }
  [ "$ID" = "$LAST_ID" ] && { sleep "$INTERVAL"; continue; }

  STEP="$(field step)"
  ENVLINE="$(field env)"
  [ -n "$STEP" ] || STEP="$(sed -n 's/^DEFAULT_STEP="\(.*\)"/\1/p' run.sh | head -1)"

  say "request $ID -> step '$STEP'${ENVLINE:+  env: $ENVLINE}"

  if is_action_step "$STEP" && [ "$ALLOW_ACTIONS" != "1" ]; then
    say "REFUSED: '$STEP'${ENVLINE:+ with env '$ENVLINE'} changes state, and this agent was started without --allow-actions"
    publish_status "refused" "$ID" "$STEP" "reason:   step changes state; agent started without --allow-actions"
    LAST_ID="$ID"                       # don't re-refuse the same request every 5s
    echo "$ID" > "$STATE_FILE"
    [ "$ONCE" = "1" ] && cleanup
    sleep "$INTERVAL"; continue
  fi

  publish_status "running" "$ID" "$STEP"
  RUNNING=1
  START="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # run.sh owns the log, the timestamps and the log push. The agent only decides
  # WHEN it runs - that separation is the same one steps and runners already have.
  if [ -n "$ENVLINE" ]; then
    # Unquoted on purpose: `env: CONFIRM=yes FOO=bar` must split into separate
    # assignments. It comes from a file only Claude writes, in this repo.
    # shellcheck disable=SC2086
    env $ENVLINE ./run.sh "$STEP"
  else
    ./run.sh "$STEP"
  fi
  RC=$?
  RUNNING=0
  # BOTH of these, and this is not belt-and-braces. LAST_ID is what the loop
  # compares against; STATE_FILE is only read at startup. Writing the file alone
  # left LAST_ID at its startup value, so the same request matched "new" on every
  # poll and the agent re-ran it every few seconds until it was stopped.
  LAST_ID="$ID"
  echo "$ID" > "$STATE_FILE"

  # Newest log for this step. Step names are [a-z-] by convention, so the glob is
  # safe; `ls -t` is the simplest thing that sorts by mtime.
  # shellcheck disable=SC2012
  LOGFILE="$(ls -t ops-logs/"${STEP}"-*.txt 2>/dev/null | head -1)"
  say "step '$STEP' finished exit=$RC${LOGFILE:+  ($LOGFILE)}"
  publish_status "idle" "$ID" "$STEP" "$(printf 'started:  %s\nfinished: %s\nexit:     %s\nlog:      %s' \
      "$START" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$RC" "${LOGFILE:-<none>}")"

  [ "$ONCE" = "1" ] && cleanup
  sleep "$INTERVAL"
done
