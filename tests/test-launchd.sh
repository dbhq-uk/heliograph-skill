#!/usr/bin/env bash
# =============================================================================
#  test-launchd.sh - a LaunchAgent, loaded, running, and stoppable
# =============================================================================
# test-service.sh checks the launchd path by RE-RENDERING the plist inside the
# test and asserting on the result. Its own comment admits the weakness: "a
# divergence between the two would make this test assert a document service.sh
# does not produce". It also cannot check what launchd does with the document,
# which is the only thing anybody cares about.
#
# So this loads a real one, on a real Mac, and asks launchctl.
#
# THE ASSERTION THAT EARNS THE RUNNER
#
# `stop: yes` in station/request is how the far side ends a loop it can no
# longer reach, and station.sh honours it by exiting 0. Under an unconditional
# KeepAlive, launchd restarts it, it reads the same stop flag, exits again, and
# round it goes - every cycle a commit pushed to the transport repo.
#
# That exact loop was observed on systemd and is why the unit uses
# Restart=on-failure. The plist carries the launchd equivalent,
# KeepAlive/SuccessfulExit=false, and until now nothing had ever checked that
# launchd agrees with our reading of it. A string in a plist is a belief about
# somebody else's software.
#
# It SKIPS LOUDLY without launchctl, so a Linux run says so rather than
# reporting a clean pass over nothing.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=assert.sh disable=SC1091
. "$HERE/assert.sh"
REPO="$HERE/.."

if ! command -v launchctl >/dev/null 2>&1; then
  t_skip "no launchctl: this needs macOS. The launchd path was NOT exercised."
  t_summary
  exit 0
fi

WORK="$(mktemp -d)"
# A name of its own. Without it this would install, stop and uninstall an agent
# called heliograph - and if whoever runs this has a real one looking after a
# real investigation, the test would quietly take it away from them.
export HELIOGRAPH_SERVICE_NAME="heliograph-selftest-$$"
LABEL="uk.dbhq.heliograph.${HELIOGRAPH_SERVICE_NAME}"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"

cleanup() {
  ( cd "$WORK/tr" 2>/dev/null && ./service.sh uninstall >/dev/null 2>&1 )
  launchctl unload "$PLIST" >/dev/null 2>&1
  rm -f "$PLIST"
  pkill -f "$WORK/tr/start.sh" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

# --- a transport repo with a remote that needs no credential -----------------
TR="$WORK/tr"
BARE="$WORK/origin.git"
mkdir -p "$TR"
git -C "$TR" init -q .
git -C "$TR" config user.email test@example.invalid
git -C "$TR" config user.name test
bash "$REPO/skills/heliograph/scripts/bootstrap.sh" "$TR" >/dev/null 2>&1
git init -q --bare "$BARE"
git -C "$TR" remote add origin "$BARE"
git -C "$TR" add -A >/dev/null 2>&1
git -C "$TR" commit -qm init >/dev/null 2>&1
git -C "$TR" branch -M main >/dev/null 2>&1
git -C "$TR" push -q -u origin main >/dev/null 2>&1

# --- install ------------------------------------------------------------------
out="$( cd "$TR" && ./service.sh install 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ]; then
  t_ok "service.sh install succeeded on macOS"
else
  t_no "service.sh install failed: [$out]"
  t_summary
  exit 1
fi

assert_contains "it chose launchd, not the setsid fallback" "launchd" "$out"

if [ -f "$PLIST" ]; then
  t_ok "the plist is in ~/Library/LaunchAgents, where a Mac looks for one"
else
  t_no "no plist at $PLIST"
fi

# Asked of launchctl rather than of the file. A plist on disk that launchd
# rejected is the failure mode a file check cannot see.
if launchctl list "$LABEL" >/dev/null 2>&1; then
  t_ok "launchctl knows the label, so the document was accepted"
else
  t_no "launchctl does not know $LABEL: the plist was written but not loaded"
fi

# --- it is actually running ---------------------------------------------------
# Asked fresh each time rather than captured once and checked later. The first
# version read a pid, then asserted it was alive - and CI caught it: launchd had
# already replaced that incarnation, so `kill -0` on the old pid failed while a
# loop was running perfectly well under a new one. The question is "is a loop
# running now", not "is that particular process still there".
live_pid() {
  launchctl list "$LABEL" 2>/dev/null |
    sed -n 's/^[[:space:]]*"PID"[[:space:]]*=[[:space:]]*\([0-9]*\).*/\1/p'
}

pid=""
for _ in $(seq 1 20); do
  p="$(live_pid)"
  if [ -n "$p" ] && [ "$p" != "0" ] && kill -0 "$p" 2>/dev/null; then
    pid="$p"
    break
  fi
  sleep 1
done

if [ -n "$pid" ]; then
  t_ok "the loop is running as pid $pid, started by launchd"
else
  t_no "launchd loaded the agent but no loop is running"
  printf '     launchctl list said: %s\n' "$(launchctl list "$LABEL" 2>&1 | tr '\n' ' ')"
  # The station's own log says WHY, and without it this failure is a guess.
  # A crash loop and a slow start look identical from launchctl alone.
  for f in "$TR/.station-service.log" "$TR/.agent-service.log"; do
    [ -f "$f" ] || continue
    printf '     --- %s ---\n' "$f"
    tail -30 "$f" | sed 's/^/     /'
  done
fi

# --- THE ONE THAT MATTERS: stop: yes sticks ----------------------------------
# Write the stop flag the way the far side does, then watch. Under a correct
# KeepAlive the loop exits 0 and launchd leaves it alone. Under an
# unconditional one it comes straight back, and the test sees a new pid.
if [ -n "$pid" ]; then
  req="$TR/station/request"
  mkdir -p "$(dirname "$req")"
  printf 'version: 1\nid: stop-test\nstop: yes\n' > "$req"

  # Waiting for launchd to report NO pid, not for one process to disappear.
  # Under a wrong KeepAlive the loop exits and is restarted, so watching a
  # single pid would see it "stop" and call that a pass.
  gone=no
  for _ in $(seq 1 40); do
    p="$(live_pid)"
    if [ -z "$p" ] || [ "$p" = "0" ]; then gone=yes; break; fi
    sleep 1
  done

  if [ "$gone" = yes ]; then
    t_ok "the loop honoured 'stop: yes' and exited"

    # Now the real question. Give launchd time to restart it if it intends to.
    sleep 8
    newpid="$(live_pid)"
    if [ -z "$newpid" ] || [ "$newpid" = "0" ]; then
      t_ok "launchd did NOT restart it: 'stop: yes' sticks, and the restart loop cannot happen"
    else
      t_no "launchd restarted the loop as pid $newpid after a clean exit"
      printf '     This is the systemd Restart=always bug on a Mac. Every cycle is a\n'
      printf '     commit pushed to the transport repo, and it only ends when a rate\n'
      printf '     limit trips and leaves the agent looking broken.\n'
    fi
  else
    t_no "the loop ignored 'stop: yes' and is still running as $pid"
  fi
fi

# --- status reports what is true ---------------------------------------------
st="$( cd "$TR" && ./service.sh status 2>&1 )"
assert_contains "status names the LaunchAgent" "$LABEL" "$st"

# --- uninstall leaves nothing behind ------------------------------------------
( cd "$TR" && ./service.sh uninstall >/dev/null 2>&1 )
if [ -f "$PLIST" ]; then
  t_no "uninstall left the plist at $PLIST"
else
  t_ok "uninstall removed the plist"
fi
if launchctl list "$LABEL" >/dev/null 2>&1; then
  t_no "uninstall left the agent loaded in launchd"
else
  t_ok "uninstall unloaded the agent"
fi

t_summary
