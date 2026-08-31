#!/usr/bin/env bash
# =============================================================================
#  agent.sh - run this ONCE on the control node and walk away
# =============================================================================
#     ./agent.sh                    # poll, run, push, repeat - READ-ONLY
#     ./agent.sh --once             # do one requested run, then exit
#     ./agent.sh --interval 15      # seconds between polls (default 5)
#     ./agent.sh --allow-actions    # also run steps that declare themselves actions
#     ./agent.sh --allow-root       # permit running as root (see SAFETY below)
#     ./agent.sh --pin              # approve the current steps, for REQUIRE_PIN=1
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
#  WATCHING: while a step runs the agent pushes the partial log every
#  PROGRESS_EVERY seconds (default 60, 0 disables) with a line count and the last
#  real line, so a long run can be followed instead of waited out.
#
#  CANCELLING: `cancel: yes` kills the step that is running right now; `cancel:
#  <id>` kills it only if that id is the one running, so a stale cancel cannot
#  reap a later run. The step runs in its own process group in the background and
#  the loop keeps polling while it works - an hour-long step no longer makes the
#  agent deaf for an hour. A cancelled run publishes state `cancelled` and leaves
#  whatever the log had reached, which is usually the evidence you wanted anyway.
#
#  SAFETY, and this loop's whole posture is in this paragraph.
#
#  READ-ONLY BY DEFAULT. A step says what it is in its own file
#  (`# heliograph-mode: read-only` or `action`); this asks run.sh --mode and
#  refuses an action outright unless started with --allow-actions. The refusal
#  is PUBLISHED to agent/status within one poll, so the far side learns in
#  seconds rather than waiting out a round trip - which is what makes a safe
#  default affordable. An action that is allowed still has to carry CONFIRM=yes
#  in the request's `env:` and get past run.sh's own gate. ACTION_ENV catches
#  the case a declaration cannot see: `env: APPLY=1` turning a read-only step
#  into a writing one.
#
#  NOT AS ROOT. The account this runs as IS the blast radius - there are no
#  other credentials in this toolkit - so running it as root makes that radius
#  the whole machine. Refused unless --allow-root (or ALLOW_ROOT=1) says the
#  estate has no other option.
#
#  REQUIRE_PIN=1 refuses any step whose file hash the operator has not approved
#  with `./agent.sh --pin`. Off by default: it makes every new step wait for the
#  operator, which is the relaying this loop exists to remove. It is here for an
#  estate that wants "runs only what I approved" and knows what it costs.
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
PIN_ONLY=0
# 1 = the agent may run steps that change state, when the request asks for one.
#
# DEFAULT 0. This was 1 for a while and the reason was a real one: the flag is
# typed once at agent start, often days before the request it gates, and a
# forgotten one surfaced as a silent "refused" long after the push - wasting
# exactly the round trip this tooling exists to save.
#
# What retired that argument was publish_status "refused": the refusal now
# reaches the far side, with its reason and the flag that would allow it, within
# one poll interval. The cost of a safe default fell from a wasted day to a few
# seconds, and an unattended loop that can change infrastructure because a file
# changed is not a default anything should ship.
ALLOW_ACTIONS="${ALLOW_ACTIONS:-0}"
# Running as root makes the blast radius the whole machine - see SAFETY above.
ALLOW_ROOT="${ALLOW_ROOT:-0}"
# 1 = refuse any step whose file hash is not in .agent-approved.
REQUIRE_PIN="${REQUIRE_PIN:-0}"

REQUEST="agent/request"
STATUS="agent/status"
STATE_FILE=".agent-state"        # gitignored: the last id we ran
APPROVED=".agent-approved"       # gitignored: hashes the operator has approved
LOCK=".agent.lock"

while [ $# -gt 0 ]; do
  case "$1" in
    --once)          ONCE=1 ;;
    --interval)      INTERVAL="$2"; shift ;;
    --allow-actions) ALLOW_ACTIONS=1 ;;
    --no-actions)    ALLOW_ACTIONS=0 ;;   # the default; kept so old invocations still work
    --allow-root)    ALLOW_ROOT=1 ;;
    --pin)           PIN_ONLY=1 ;;
    -h|--help)       sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
[ -n "$BRANCH" ] && [ "$BRANCH" != "HEAD" ] || { echo "agent: not on a branch - checkout the task branch first" >&2; exit 2; }

# One agent per checkout. Two would double-run every request and race on push.
#
# --pin takes no lock, deliberately: approving a new step is exactly the thing
# an operator does WHILE the loop is running, and a pin that refused because the
# agent was up would be useless at the only moment it is wanted.
if [ "$PIN_ONLY" = "0" ]; then
  if [ -e "$LOCK" ]; then
    pid="$(cat "$LOCK" 2>/dev/null || echo)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      echo "agent: already running here as pid $pid (remove $LOCK if that is wrong)" >&2; exit 3
    fi
    echo "agent: clearing a stale lock from pid ${pid:-?}"
  fi
  echo $$ > "$LOCK"
fi

say() { printf '%s  %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }

# Start a step in the background, in its OWN process group, so the cancel path
# can signal the whole tree - run.sh, the step, and whatever those invoke.
# Killing the child alone would orphan its grandchildren.
#
# `setsid` is util-linux and is not on a stock macOS, which this toolkit is meant
# to run on. `set -m` is the portable equivalent: with job control on, each
# background job gets its own process group. Preferring setsid keeps the common
# case free of job-control notices on stderr.
if command -v setsid >/dev/null 2>&1; then
  run_detached() { setsid "$@" & }
else
  set -m
  run_detached() { "$@" & }
fi

RUNNING=0
CHILD=""
cleanup() {
  # Only if this process took it. A --pin run holds no lock, and removing one it
  # never owned would unlock a real agent that is mid-run.
  [ "$PIN_ONLY" = "0" ] && rm -f "$LOCK"
  # The step runs in its own session now, so Ctrl-C on the agent no longer
  # reaches it. Signal the group explicitly: an operator who interrupts the
  # agent expects the run to stop, not to carry on detached and push a log
  # afterwards with nothing watching it.
  if [ "$RUNNING" = "1" ] && [ -n "$CHILD" ]; then
    say "interrupted mid-run - signalling the step, the log may not have been pushed"
    kill -TERM -- "-$CHILD" 2>/dev/null || kill -TERM "$CHILD" 2>/dev/null
  fi
  say "stopped"
  exit 0
}
trap cleanup INT TERM

# --- request parsing ---------------------------------------------------------
# Deliberately dumb key: value. No YAML parser, nothing to install, and the file
# stays readable by whoever opens it next.
field() { sed -n "s/^${1}:[[:space:]]*//p" "$REQUEST" 2>/dev/null | head -1; }

# A step is an action if its OWN FILE says so, or if the request's env turns it
# into one.
#
# The declaration is read through `run.sh --mode` rather than by parsing the
# step table here. The mapping from a step name to a file belongs to run.sh, and
# a second copy of it would drift the first time somebody registered a step that
# takes arguments - drift that shows up as a writing step being waved through.
#
# The name-based list this replaced had a plainer hole: `cleanup-disk` matched
# nothing in `apply deploy destroy reset` and ran as a diagnostic.
#
# ACTION_ENV is a substring match against the request's env line, and stays
# because a declaration cannot see it: a step that plans is read-only until
# `env: APPLY=1` makes it apply. Add whatever does that on your branch.
ACTION_ENV="${ACTION_ENV:-APPLY=1 CONFIRM=yes DESTROY=1 FORCE=1 WRITE=1}"
step_mode() { ./run.sh --mode "$1" 2>/dev/null | head -1; }
step_file() { ./run.sh --file "$1" 2>/dev/null | head -1; }
is_action_step() {
  local s="$1" a
  [ "$(step_mode "$s")" = "action" ] && return 0
  for a in $ACTION_ENV; do
    case "${ENVLINE:-}" in *"$a"*) return 0 ;; esac
  done
  return 1
}

# --- pinning: run only what the operator approved -----------------------------
# The hashes live in a LOCAL, gitignored file. Recorded in the transport repo
# they could be edited from the far side, which is the only side a pin exists to
# distrust - the approval would then travel with the change it is supposed to
# catch.
#
# The pinned set is everything a request can cause to execute: the step itself,
# the runner, the capture library and the helpers a step sources. Hashing rather
# than listing names is the point - an edit to an approved step is a different
# step, and the pin notices.
#
# It does NOT cover agent.sh, which self-updates on pull. Say so in the docs
# rather than implying a boundary that is not there.
pin_hash() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }
pin_write() {
  local f n=0
  : > "$APPROVED"
  for f in run.sh caplib.sh lib/*.sh steps/*; do
    [ -f "$f" ] || continue
    printf '%s  %s\n' "$(pin_hash "$f")" "$f" >> "$APPROVED"
    n=$((n + 1))
  done
  say "approved $n files into $APPROVED"
  say "re-run ./agent.sh --pin after any step changes, or the loop will refuse them"
}
pin_check() {  # pin_check <stepfile>; prints the first unapproved path
  local f
  # `./steps/x.sh` and `steps/x.sh` are the same file and hash identically, but
  # the approval is matched as a whole line, so the spelling has to agree.
  # run.sh's step table writes the `./` form; pin_write's glob does not.
  set -- "${1#./}"
  for f in run.sh caplib.sh lib/*.sh "$1"; do
    [ -f "$f" ] || continue
    grep -qxF "$(pin_hash "$f")  $f" "$APPROVED" 2>/dev/null || { printf '%s\n' "$f"; return 1; }
  done
  return 0
}

if [ "$PIN_ONLY" = "1" ]; then
  pin_write
  exit 0
fi

# The account is the blast radius, and an unattended loop is the worst place to
# find that out afterwards. Checked once at startup rather than per run: this
# process does not change uid, and a loop that would refuse every request should
# say so before the operator walks away rather than a day later in a status file.
cap_refuse_root || { rm -f "$LOCK"; exit 5; }

# --- status, pushed so the far side can see what is happening ----------------
# Two extra commits per run. Worth it: without the "running" one, a long step is
# indistinguishable from an agent that never woke up.
publish_status() {
  local state="$1" id="$2" step="$3" extra="${4:-}" alsofile="${5:-}"
  mkdir -p agent
  # A killed step leaves its log modified in the working tree, and progress
  # pushes have made that file TRACKED - so unless it is committed here, every
  # later `pull --rebase` refuses on a dirty tree and the agent wedges with the
  # cancellation never reaching the far side. Found by cancelling a run that had
  # been publishing progress.
  [ -n "$alsofile" ] && [ -f "$alsofile" ] || alsofile=""
  {
    echo "state:    $state"
    echo "id:       $id"
    echo "step:     $step"
    echo "host:     $(hostname -f 2>/dev/null || hostname)"
    echo "branch:   $BRANCH"
    echo "utc:      $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    [ -n "$extra" ] && echo "$extra"
  } > "$STATUS"
  git add -f "$STATUS" ${alsofile:+"$alsofile"} >/dev/null 2>&1
  git diff --cached --quiet -- "$STATUS" ${alsofile:+"$alsofile"} >/dev/null 2>&1 && return 0
  git -c user.name="${GIT_AUTHOR_NAME:-agent}" \
      -c user.email="${GIT_AUTHOR_EMAIL:-agent@$(hostname)}" \
      commit -q -m "agent: $state ($id) ***NO_CI***" -- "$STATUS" ${alsofile:+"$alsofile"} 2>/dev/null
  cap_git pull --rebase --quiet >/dev/null 2>&1
  cap_git push --quiet >/dev/null 2>&1 || cap_git push --quiet -u origin HEAD >/dev/null 2>&1 || \
    say "status push failed (will retry on the next transition)"
}

# --- progress, pushed WHILE a step runs --------------------------------------
# A long step used to be a black box: nothing reached the repo until it finished,
# so "running for forty minutes" and "wedged" looked identical from the far side.
# This pushes the partial log periodically so the run can be watched as it goes.
#
# NO PULL, NO REBASE, DELIBERATELY. The step is appending to that log through an
# open file descriptor; a rebase would rewrite the file underneath it and the
# appends would carry on at a stale offset, corrupting the very evidence we are
# trying to publish. So this only ever pushes, and a rejected push is simply
# retried next time - run.sh's own cap_push reconciles properly at the end.
#
# The runner still owns the log. This publishes a snapshot of it and never writes
# to it, so the ownership rule the whole toolkit rests on is intact.
PROGRESS_EVERY="${PROGRESS_EVERY:-60}"      # seconds; 0 disables
publish_progress() {
  local id="$1" step="$2" started="$3" logfile="$4"
  [ -n "$logfile" ] && [ -f "$logfile" ] || return 0
  local lines last
  lines="$(wc -l < "$logfile" 2>/dev/null || echo 0)"
  # The last non-blank, non-divider line says more about where a step is than a
  # line count does - it is usually the probe currently in flight.
  last="$(grep -vE '^[[:space:]]*$|^-{5,}|^={5,}' "$logfile" 2>/dev/null | tail -1 | cut -c1-160)"
  mkdir -p agent
  {
    echo "state:    running"
    echo "id:       $id"
    echo "step:     $step"
    echo "host:     $(hostname -f 2>/dev/null || hostname)"
    echo "branch:   $BRANCH"
    echo "utc:      $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "started:  $started"
    echo "progress: ${lines} lines"
    echo "log:      $logfile"
    [ -n "$last" ] && echo "last:     $last"
  } > "$STATUS"
  git add -f "$STATUS" "$logfile" >/dev/null 2>&1
  git diff --cached --quiet -- "$STATUS" "$logfile" >/dev/null 2>&1 && return 0
  git -c user.name="${GIT_AUTHOR_NAME:-agent}" \
      -c user.email="${GIT_AUTHOR_EMAIL:-agent@$(hostname)}" \
      commit -q -m "agent: progress ($id) ${lines} lines ***NO_CI***" -- "$STATUS" "$logfile" 2>/dev/null
  cap_git push --quiet >/dev/null 2>&1 ||
    say "progress push rejected (remote moved) - will retry; the final push reconciles"
}

say "agent up on $BRANCH at $(hostname -f 2>/dev/null || hostname), polling every ${INTERVAL}s"
if [ "$ALLOW_ACTIONS" = "1" ]; then
  say "state-changing steps: ALLOWED - started with --allow-actions, still gated by CONFIRM in the request"
else
  say "state-changing steps: BLOCKED (the default) - a step declaring 'action' is refused"
fi
if [ "$REQUIRE_PIN" = "1" ]; then
  if [ -f "$APPROVED" ]; then
    say "pinning: ON - only the $(wc -l < "$APPROVED") files approved in $APPROVED will run"
  else
    say "pinning: ON, nothing approved yet - every request is refused until ./agent.sh --pin"
  fi
fi
say "request 'stop: yes' or Ctrl-C to finish, 'cancel: yes' to kill a running step"
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
      # Bare git: abort touches no network, so cap_git would put the auth header
      # in this process's argv for nothing.
      git rebase --abort >/dev/null 2>&1
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

  # Every refusal below takes the same shape: say it here, PUBLISH it with a
  # reason the far side can act on, and record the id so the same request is not
  # re-refused every poll. The publishing is the part that matters - a refusal
  # nobody can see is indistinguishable from an agent that died.
  refuse() {  # refuse <reason for the status file> <what to say locally>
    say "REFUSED: $2"
    publish_status "refused" "$ID" "$STEP" "reason:   $1"
    LAST_ID="$ID"
    echo "$ID" > "$STATE_FILE"
    [ "$ONCE" = "1" ] && cleanup
  }

  MODE="$(step_mode "$STEP")"
  case "$MODE" in
    read-only|action) ;;
    *)
      # run.sh would refuse this too, and its message is better. Catching it
      # here means the far side gets a status rather than an exit code buried in
      # a log it has to go and find.
      refuse "step '$STEP' declares no usable mode ($MODE) - see run.sh --mode" \
             "'$STEP' does not declare 'heliograph-mode: read-only' or 'action', so it will not run"
      sleep "$INTERVAL"; continue ;;
  esac

  if is_action_step "$STEP" && [ "$ALLOW_ACTIONS" != "1" ]; then
    refuse "step changes state; restart the agent with --allow-actions to permit it" \
           "'$STEP'${ENVLINE:+ with env '$ENVLINE'} changes state, and this agent is read-only (the default)"
    sleep "$INTERVAL"; continue
  fi

  if [ "$REQUIRE_PIN" = "1" ]; then
    if ! UNPINNED="$(pin_check "$(step_file "$STEP")")"; then
      refuse "'$UNPINNED' is not approved in $APPROVED - the operator runs ./agent.sh --pin to approve it" \
             "'$STEP' is not approved: $UNPINNED is new or has changed since the last --pin"
      sleep "$INTERVAL"; continue
    fi
  fi

  publish_status "running" "$ID" "$STEP"
  RUNNING=1
  START="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # run.sh owns the log, the timestamps and the log push. The agent only decides
  # WHEN it runs - that separation is the same one steps and runners already have.
  #
  # THE STEP RUNS IN ITS OWN SESSION, IN THE BACKGROUND, so this loop stays
  # responsive while it works. Before this, a step that took an hour made the
  # agent deaf for an hour: `cancel` could not be heard, and every later request
  # queued behind a run nobody wanted any more. run_detached (above) gives the
  # step its own process group, so the whole tree - run.sh, the step, and
  # whatever those invoke - can be signalled together; killing just the child
  # would orphan whatever it spawned.
  if [ -n "$ENVLINE" ]; then
    # `env: CONFIRM=yes FOO=bar` has to split into separate assignments, so this
    # cannot simply be quoted. Plain word-splitting cannot be the whole answer
    # either: `env: HOSTS="a b" PORTS=443` then reaches env as four words, the
    # first assignment and three commands, and the step dies with
    #     env: 'b': No such file or directory        exit 127
    # which reads as a broken step rather than as a malformed request. A value
    # with a space in it is not exotic - HOSTS is the toolkit's own documented
    # example of one.
    #
    # So: split the line the way a shell would, honouring quotes, but refuse
    # anything that could DO something rather than assign something. The
    # request file is already a trusted control channel - it names the step to
    # run - but "trusted" is not a reason to hand it a subshell, and a refusal
    # naming the character costs one round trip less than a surprise.
    case "$ENVLINE" in
      *'$'* | *'`'* | *';'* | *'&'* | *'|'* | *'<'* | *'>'* | *'('* )
        say "REFUSED: env line contains a shell metacharacter, which this does not evaluate"
        say "  env: $ENVLINE"
        say "  Use plain NAME=value pairs; quote a value that contains spaces."
        publish_status "refused" "$ID" "$STEP" "reason:   env line contains a shell metacharacter"
        LAST_ID="$ID"; echo "$ID" > "$STATE_FILE"
        [ "$ONCE" = "1" ] && cleanup
        continue ;;
    esac
    eval "ENVARR=($ENVLINE)" 2>/dev/null || {
      say "REFUSED: env line is not parseable as NAME=value pairs"
      say "  env: $ENVLINE"
      publish_status "refused" "$ID" "$STEP" "reason:   env line is not parseable"
      LAST_ID="$ID"; echo "$ID" > "$STATE_FILE"
      [ "$ONCE" = "1" ] && cleanup
      continue
    }
    run_detached env "${ENVARR[@]}" ./run.sh "$STEP"
  else
    run_detached ./run.sh "$STEP"
  fi
  CHILD=$!
  CANCELLED=0
  # What `cancel:` said when this run started. A cancel that was ALREADY in the
  # file cannot have been meant for a run that had not begun, and acting on it
  # would reap the next request the moment it starts: seen in testing as a step
  # that finished cleanly and was still published as cancelled, because the
  # `cancel: yes` that stopped its predecessor was still sitting in the file.
  # Only a CHANGE is an instruction.
  CANCEL_AT_START="$(field cancel)"

  LAST_PROGRESS=0
  while kill -0 "$CHILD" 2>/dev/null; do
    sleep "$INTERVAL"

    # Publish the partial log on a slower clock than the poll: every INTERVAL
    # would be a commit every five seconds and an unreadable history.
    if [ "$PROGRESS_EVERY" != "0" ]; then
      NOW="$(date +%s)"
      if [ $((NOW - LAST_PROGRESS)) -ge "$PROGRESS_EVERY" ]; then
        # shellcheck disable=SC2012
        RUNNING_LOG="$(ls -t ops-logs/"${STEP}"-*.txt 2>/dev/null | head -1)"
        publish_progress "$ID" "$STEP" "$START" "$RUNNING_LOG"
        LAST_PROGRESS="$NOW"
      fi
    fi

    # Read the request from the REMOTE ref, never by pulling: the step is writing
    # to this working tree right now, and a rebase underneath a running step is
    # how you corrupt a run you were only trying to observe.
    cap_git fetch --quiet origin "$BRANCH" 2>/dev/null || continue
    REMOTE_REQ="$(git show "origin/$BRANCH:$REQUEST" 2>/dev/null)" || continue
    WANT_CANCEL="$(printf '%s\n' "$REMOTE_REQ" | sed -n 's/^cancel:[[:space:]]*//p' | head -1)"
    NEW_ID="$(printf '%s\n' "$REMOTE_REQ" | sed -n 's/^id:[[:space:]]*//p' | head -1)"

    # `cancel: yes` stops whatever is running. `cancel: <id>` stops it only if
    # that is the id running - so a stale cancel left in the file cannot kill a
    # later, wanted run. An unchanged value is stale by definition: it was in the
    # file before this step started, so it was not asking for this one to stop.
    if [ "$WANT_CANCEL" = "$CANCEL_AT_START" ]; then
      DO_CANCEL=0
    else
      case "$WANT_CANCEL" in
        yes|YES|true) DO_CANCEL=1 ;;
        "")           DO_CANCEL=0; CANCEL_AT_START="" ;;   # cleared: a later `yes` is a fresh instruction
        "$ID")        DO_CANCEL=1 ;;
        *)            DO_CANCEL=0 ;;
      esac
    fi

    if [ "$DO_CANCEL" = "1" ]; then
      say "CANCEL requested for '$STEP' ($ID) - signalling the process group"
      # TERM first so the step can finish its current line and flush; KILL only
      # if it ignores that. A log that stops mid-sentence is still evidence.
      kill -TERM -- "-$CHILD" 2>/dev/null || kill -TERM "$CHILD" 2>/dev/null
      for _ in 1 2 3 4 5; do
        kill -0 "$CHILD" 2>/dev/null || break
        sleep 1
      done
      kill -KILL -- "-$CHILD" 2>/dev/null || kill -KILL "$CHILD" 2>/dev/null
      CANCELLED=1
      break
    fi

    # A NEW id while this one runs does NOT cancel: an in-flight step may be
    # halfway through changing something, and inferring "they want this dead"
    # from a queued request would be guessing. It waits its turn.
    [ -n "$NEW_ID" ] && [ "$NEW_ID" != "$ID" ] && [ "$NEW_ID" != "$LAST_ID" ] &&
      say "note: request $NEW_ID is queued behind the running step"
  done

  wait "$CHILD" 2>/dev/null
  RC=$?
  [ "$CANCELLED" = "1" ] && RC=130
  CHILD=""
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
  if [ "$CANCELLED" = "1" ]; then
    say "step '$STEP' CANCELLED${LOGFILE:+  (partial log: $LOGFILE)}"
    # The log goes in this commit too: the step was killed, so run.sh's cap_push
    # never ran, and this is the only thing that will carry the partial evidence
    # out - as well as what leaves the tree clean enough to keep polling.
    publish_status "cancelled" "$ID" "$STEP" "$(printf 'started:  %s\ncancelled:%s\nexit:     %s\nlog:      %s\nnote:     partial - the step was signalled, so the log stops where it stopped' \
        "$START" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$RC" "${LOGFILE:-<none>}")" "$LOGFILE"
  else
    say "step '$STEP' finished exit=$RC${LOGFILE:+  ($LOGFILE)}"
    publish_status "idle" "$ID" "$STEP" "$(printf 'started:  %s\nfinished: %s\nexit:     %s\nlog:      %s' \
        "$START" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$RC" "${LOGFILE:-<none>}")"
  fi

  [ "$ONCE" = "1" ] && cleanup
  sleep "$INTERVAL"
done
