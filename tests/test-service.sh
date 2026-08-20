#!/usr/bin/env bash
# =============================================================================
#  test-service.sh - the loop outliving the session that started it
# =============================================================================
# The bug first, because everything here follows from it: sshd sends SIGHUP to
# the session's process group when a connection closes, agent.sh traps INT and
# TERM but not HUP, and the default action for HUP is to die. `./agent.sh` said
# "run this ONCE and walk away" and did not survive walking away.
#
# service.sh fixes it with one of two mechanisms, and the assertions below care
# which one was used only insofar as the loop is still there afterwards.
#
# --- what is asserted against what -------------------------------------------
# The detachment assertions read the PROCESS TABLE, not this file's idea of what
# should have happened: a detached process has a different session id from the
# shell that started it, and that is asked of ps rather than assumed. The refusal
# assertions read service.sh's exit code and its stderr.
#
# --- the skip ----------------------------------------------------------------
# The systemd path needs a user manager, which a CI runner or a container may
# not have. Where it is missing this file says so LOUDLY and still exercises the
# setsid + nohup fallback, which is the mechanism service.sh would pick there
# anyway. It never reports a clean run for assertions that did not execute.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=assert.sh disable=SC1091
. "$HERE/assert.sh"
REPO="$(cd "$HERE/.." && pwd)"

WORK="$(mktemp -d)"
cleanup_all() {
  # Never leave a detached loop behind: it would outlive this test file, which
  # is the one thing the feature under test is good at.
  if [ -s "$WORK/tr/.agent-service.pid" ]; then
    pid="$(cat "$WORK/tr/.agent-service.pid" 2>/dev/null)"
    [ -n "$pid" ] && { kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null; }
  fi
  pkill -f "$WORK/tr/start.sh" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup_all EXIT

TR="$WORK/tr"
mkdir -p "$TR"
git -C "$TR" init -q .
git -C "$TR" config user.email test@example.invalid
git -C "$TR" config user.name test
bash "$REPO/skills/heliograph/scripts/bootstrap.sh" "$TR" >/dev/null 2>&1

# A UNIT NAME OF ITS OWN. Without this the suite would install, stop and then
# uninstall a unit called heliograph.service - and if the person running the
# tests has a real one of those looking after a real investigation, this file
# would quietly take it away from them.
export HELIOGRAPH_SERVICE_NAME="heliograph-selftest"

# =============================================================================
#  1. it ships, and its runtime state does not get committed
# =============================================================================
if [ -x "$TR/service.sh" ]; then
  t_ok "service.sh ships into a transport repo, executable"
else
  t_no "service.sh missing or not executable in a bootstrapped repo"
fi

# The pid and log files sit at the repo root next to .agent.lock. agent/ holds
# request and status, which ARE committed - that directory is the transport - so
# a pid file there would be pushed to the far side on every start.
for f in .agent-service.pid .agent-service.log; do
  if git -C "$TR" check-ignore -q "$f"; then
    t_ok "$f is ignored, so the service's runtime state is never committed"
  else
    t_no "$f is NOT ignored and would be pushed to the transport repo"
  fi
done

# =============================================================================
#  2. it refuses to install a loop that cannot push
# =============================================================================
# This is the expensive failure: a detached process inherits no environment, so
# a credential that lives in the operator's shell does not reach the service.
# The loop starts perfectly, polls happily, and cannot push a single log -
# discovered hours later by whoever is waiting on the far side.
out="$( cd "$TR" && ./service.sh install 2>&1 )"; rc=$?
assert_eq "installing with no remote and no credential exits non-zero" "1" "$rc"
assert_contains "and says what is wrong" "no origin remote" "$out"

git -C "$TR" remote add origin https://example.invalid/repo.git
out="$( cd "$TR" && ./service.sh install 2>&1 )"; rc=$?
assert_eq "an https remote with no credential is refused" "1" "$rc"
assert_contains "and names the missing credential" "no credential found" "$out"

out="$( cd "$TR" && GIT_TOKEN=abcdef1234 ./service.sh install 2>&1 )"; rc=$?
assert_eq "a credential that lives only in the shell is refused" "1" "$rc"
assert_contains "and explains that a detached process inherits no environment" \
  "will not reach the service" "$out"
assert_contains "and names the fix rather than only the problem" ".git-token" "$out"

# A refusal that cannot be overridden is a different defect, so the escape hatch
# is checked too. It must NOT be the default.
out="$( cd "$TR" && GIT_TOKEN=abcdef1234 timeout 30 ./service.sh install --force 2>&1 )"
assert_contains "--force installs anyway and says so" "installing anyway" "$out"
( cd "$TR" && ./service.sh uninstall >/dev/null 2>&1 )

# =============================================================================
#  3. a remote that needs no credential is not refused
# =============================================================================
# The first version of the check only special-cased ssh and let everything else
# fall through to the token chain, so it refused to install against a local path
# remote - a remote git needs no credential for at all. Its own test caught it.
BARE="$WORK/origin.git"
git init -q --bare "$BARE"
git -C "$TR" remote set-url origin "$BARE"
git -C "$TR" add -A >/dev/null 2>&1
git -C "$TR" commit -qm init >/dev/null 2>&1
git -C "$TR" branch -M main >/dev/null 2>&1
git -C "$TR" push -q -u origin main >/dev/null 2>&1

out="$( cd "$TR" && ./service.sh install 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ]; then
  t_ok "a local path remote installs without demanding a token"
else
  t_no "a local path remote was refused, but git needs no credential for one: [$out]"
fi

# =============================================================================
#  4. it is actually detached
# =============================================================================
# The property that matters, asked of ps rather than assumed. A process that
# survives logout has left the starting shell's session; one that has not will
# take SIGHUP with the rest of the session and die.
mech="$(printf '%s' "$out" | grep -oE 'systemd --user|setsid \+ nohup' | head -1)"
say_mech="${mech:-unknown}"
t_ok "install reported its mechanism: $say_mech"

if [ "$say_mech" = "unknown" ]; then
  t_no "install did not say which mechanism it used, so nobody can tell what they are relying on"
fi

pid=""
if [ "$say_mech" = "systemd --user" ]; then
  pid="$(XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" \
         systemctl --user show "$HELIOGRAPH_SERVICE_NAME.service" -p MainPID --value 2>/dev/null)"
elif [ -s "$TR/.agent-service.pid" ]; then
  pid="$(cat "$TR/.agent-service.pid")"
fi

if [ -n "$pid" ] && [ "$pid" != "0" ] && kill -0 "$pid" 2>/dev/null; then
  t_ok "the loop is running as pid $pid"

  their_sess="$(ps -o sess= -p "$pid" 2>/dev/null | tr -d ' ')"
  my_sess="$(ps -o sess= -p $$ 2>/dev/null | tr -d ' ')"
  if [ -n "$their_sess" ] && [ "$their_sess" != "$my_sess" ]; then
    t_ok "it is in its own session ($their_sess, not $my_sess), so SIGHUP to this one cannot reach it"
  else
    t_no "it shares this shell's session ($their_sess), so it would die with the connection"
  fi

  # THE SIGHUP TEST IS ONLY MEANINGFUL FOR THE FALLBACK, and pretending otherwise
  # would assert systemd's signal policy rather than anything this toolkit does.
  #
  # systemd treats SIGHUP, SIGINT, SIGTERM and SIGPIPE as CLEAN terminations, so
  # Restart=on-failure deliberately does not bring the unit back after one. That
  # is correct here: a systemd-managed process has no controlling terminal, so a
  # closing ssh session can never send it SIGHUP in the first place. What
  # protects it is the detachment asserted just above, not a restart policy.
  #
  # Restart=always would "pass" a direct-SIGHUP test and cost far more: it also
  # undoes `stop: yes`, which is checked below.
  if [ "$say_mech" = "systemd --user" ]; then
    st="$(XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" \
          systemctl --user is-active "$HELIOGRAPH_SERVICE_NAME.service" 2>/dev/null)"
    if [ "$st" = "active" ]; then
      t_ok "the unit is active, and its detachment above is what makes a closing session harmless"
    else
      t_no "the unit is $st when it should be running"
    fi
  else
    kill -HUP "$pid" 2>/dev/null
    sleep 3
    still_up=no
    kill -0 "$pid" 2>/dev/null && still_up=yes
    if [ "$still_up" = yes ]; then
      t_ok "SIGHUP does not end it: still running as pid $pid"
    else
      t_no "the detached loop died on SIGHUP, which is the bug it exists to fix"
    fi
  fi
else
  t_no "no running loop found after install, mechanism $say_mech"
fi

# =============================================================================
#  4b. arguments reach start.sh
# =============================================================================
# The first version hardcoded start.sh with no arguments, so a service-managed
# loop could not be put on a task branch - and branch per task is how this whole
# skill works. It also ruled out --interval and anything after --. Nothing in the
# suite noticed; running a real investigation through it did.
( cd "$TR" && ./service.sh stop >/dev/null 2>&1; ./service.sh uninstall >/dev/null 2>&1 )
git -C "$TR" checkout -q -b task/argtest 2>/dev/null
git -C "$TR" push -q -u origin task/argtest >/dev/null 2>&1
git -C "$TR" checkout -q main 2>/dev/null

out="$( cd "$TR" && ./service.sh install --branch task/argtest 2>&1 )"
assert_contains "install reports the arguments it was given" "--branch task/argtest" "$out"

sleep 4
# Asked of the checkout itself, not of the message that claimed it: start.sh
# checks the branch out, so the repo is on it or the argument went nowhere.
onbranch="$(git -C "$TR" rev-parse --abbrev-ref HEAD 2>/dev/null)"
if [ "$onbranch" = "task/argtest" ]; then
  t_ok "the loop actually moved to the task branch, so the argument reached start.sh"
else
  t_no "the repo is on '$onbranch', so --branch did not reach start.sh"
fi

st="$( cd "$TR" && ./service.sh status 2>&1 )"
assert_contains "status shows which branch it is on, so nobody has to guess" "task/argtest" "$st"

( cd "$TR" && ./service.sh stop >/dev/null 2>&1; ./service.sh uninstall >/dev/null 2>&1 )
git -C "$TR" checkout -q main 2>/dev/null
out="$( cd "$TR" && ./service.sh install 2>&1 )"
pid="$(cat "$TR/.agent-service.pid" 2>/dev/null || true)"

# =============================================================================
#  4c. a deliberate stop must stick
# =============================================================================
# `stop: yes` in agent/request is how the far side ends a loop it can no longer
# reach, and agent.sh honours it by exiting 0. Under Restart=always systemd
# started it straight back up, it read the same stop flag, exited again, and
# round it went: four "agent: stopped" commits in eighty seconds, each one
# PUSHED TO THE TRANSPORT REPO, until StartLimitBurst tripped and left the unit
# `failed` - which reads like a breakage when the agent had done as it was told.
#
# Only a real run found this. The unit file was read in review and looked fine.
if [ "$say_mech" = "systemd --user" ]; then
  unit="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/$HELIOGRAPH_SERVICE_NAME.service"
  if [ -f "$unit" ]; then
    restart="$(grep -m1 '^Restart=' "$unit" | cut -d= -f2)"
    assert_eq "the unit restarts on failure only, so a deliberate stop is not undone"       "on-failure" "$restart"
  else
    t_no "no unit file at $unit to check the restart policy in"
  fi
fi

# And the behaviour, not just the setting. A clean exit must leave it stopped.
( cd "$TR" && ./service.sh stop >/dev/null 2>&1; ./service.sh uninstall >/dev/null 2>&1 )
git -C "$TR" checkout -q main 2>/dev/null
printf 'id: stoptest\nstop: yes\n' > "$TR/agent/request"
git -C "$TR" add agent/request >/dev/null 2>&1
git -C "$TR" commit -qm "request: stop" >/dev/null 2>&1
git -C "$TR" push -q origin main >/dev/null 2>&1

( cd "$TR" && ./service.sh install >/dev/null 2>&1 )
sleep 12
still=""
if [ "$say_mech" = "systemd --user" ]; then
  still="$(XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" \
           systemctl --user is-active "$HELIOGRAPH_SERVICE_NAME.service" 2>/dev/null)"
  case "$still" in
    active|activating)
      t_no "the agent was told to stop and systemd keeps restarting it ($still), which pushes a commit every time" ;;
    *)
      t_ok "a deliberate stop sticks: the unit is $still rather than being restarted into the same stop flag" ;;
  esac
else
  p2="$(cat "$TR/.agent-service.pid" 2>/dev/null || true)"
  if [ -n "$p2" ] && kill -0 "$p2" 2>/dev/null; then
    t_no "the agent was told to stop but is still running as $p2"
  else
    t_ok "a deliberate stop sticks under the fallback too"
  fi
fi
( cd "$TR" && ./service.sh stop >/dev/null 2>&1; ./service.sh uninstall >/dev/null 2>&1 )
# Clear the stop flag and leave a running service behind, because section 5 is
# about stopping one and there would otherwise be nothing there to stop.
printf 'id:\nstep:\n' > "$TR/agent/request"
git -C "$TR" add agent/request >/dev/null 2>&1
git -C "$TR" commit -qm "request: clear" >/dev/null 2>&1
git -C "$TR" push -q origin main >/dev/null 2>&1
( cd "$TR" && ./service.sh install >/dev/null 2>&1 )
sleep 3
pid="$(XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" \
       systemctl --user show "$HELIOGRAPH_SERVICE_NAME.service" -p MainPID --value 2>/dev/null)"
[ -n "$pid" ] && [ "$pid" != "0" ] || pid="$(cat "$TR/.agent-service.pid" 2>/dev/null || true)"

# =============================================================================
#  5. and it can be stopped and removed again
# =============================================================================
out="$( cd "$TR" && ./service.sh stop 2>&1 )"
if printf '%s' "$out" | grep -qiE 'stopped'; then
  t_ok "stop reports what it stopped"
else
  t_no "stop said nothing useful: [$out]"
fi

sleep 2
if [ -n "$pid" ] && [ "$pid" != "0" ] && kill -0 "$pid" 2>/dev/null; then
  t_no "the loop is still running as pid $pid after stop"
else
  t_ok "the loop is gone after stop"
fi

out="$( cd "$TR" && ./service.sh uninstall 2>&1 )"
assert_contains "uninstall says lingering is left alone, being a property of the user" \
  "Lingering is left enabled" "$out"

out="$( cd "$TR" && ./service.sh status 2>&1 )"
assert_contains "status after uninstall says it is not installed" "not installed" "$out"

# =============================================================================
#  6. usage
# =============================================================================
out="$( cd "$TR" && ./service.sh 2>&1 )"; rc=$?
assert_eq "no subcommand is a usage error, not a silent success" "2" "$rc"
assert_contains "and prints the subcommands" "install" "$out"

# --- what did not run --------------------------------------------------------
if [ "$say_mech" != "systemd --user" ]; then
  echo
  echo "NOTE: there is no systemd user manager here, so the systemd path was NOT"
  echo "exercised. What ran was the setsid + nohup fallback, which is what"
  echo "service.sh would choose on this machine anyway. NOT CHECKED here:"
  echo "  - the unit file's contents and its restart limit"
  echo "  - lingering, which is the thing that makes a user unit survive logout"
  echo "  - survival across a reboot, which the fallback does not do at all"
  echo
fi

t_summary
