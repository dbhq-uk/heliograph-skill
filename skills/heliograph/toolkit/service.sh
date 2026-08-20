#!/usr/bin/env bash
# =============================================================================
#  service.sh - make the loop outlive the session that started it
# =============================================================================
#     ./service.sh install     # survive logout, and start now
#     ./service.sh status      # is it running, and where are the logs
#     ./service.sh logs        # follow them
#     ./service.sh stop
#     ./service.sh uninstall
#
#  WHY THIS EXISTS. agent.sh says "run this ONCE on the control node and walk
#  away" and that was not true. sshd sends SIGHUP to the session's process group
#  when the connection closes, agent.sh traps INT and TERM but not HUP, and the
#  default action for HUP is to die. Measured: the shell reports
#
#      Hangup    PUSH=0 ./agent.sh --interval 3
#
#  and the loop is gone. Every host added since - the container, the Azure four,
#  AKS, the pipelines - gets this free from a restart policy, which is exactly
#  why it went unnoticed for so long. The plainest case, somebody with a shell on
#  a box who wants to close the laptop, was the one still broken.
#
#  THE DIVISION OF LABOUR is unchanged. start.sh decides WHERE, agent.sh decides
#  WHEN, run.sh owns the log. This decides only HOW THE LOOP OUTLIVES THE
#  SESSION, and it starts start.sh rather than agent.sh so the preflight still
#  runs. It reimplements none of them.
#
#  TWO MECHANISMS, and the first is much better:
#
#    systemd --user plus lingering. No root, restarts on failure, survives
#    reboot, and journalctl already knows how to show you the logs.
#
#    setsid + nohup. Works anywhere, survives logout, and does NOT survive a
#    reboot. Used only when there is no user systemd to talk to, and it says so
#    rather than pretending the two are equivalent.
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT" || exit 1

# The unit name is overridable, and that is not only for the tests. Two
# transport repos on one control node is an ordinary situation - one per
# investigation - and a fixed name would mean the second install silently
# replaced the first. It also stops ./tests/run-tests.sh from uninstalling a
# real service somebody is relying on.
SERVICE_NAME="${HELIOGRAPH_SERVICE_NAME:-heliograph}"
UNIT_NAME="$SERVICE_NAME.service"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
UNIT_PATH="$UNIT_DIR/$UNIT_NAME"
PID_FILE="$REPO_ROOT/.agent-service.pid"
LOG_FILE="$REPO_ROOT/.agent-service.log"

say()  { printf '%s\n' "$*"; }
warn() { printf 'warn  %s\n' "$*" >&2; }
die()  { printf 'error %s\n' "$*" >&2; exit 1; }

# --- systemd, and the variable that decides whether you can reach it ----------
# `systemctl --user` talks to a per-user bus under XDG_RUNTIME_DIR. That variable
# is set for a login shell and is routinely UNSET in the shells this toolkit
# actually runs in: `ssh host command`, a sudo session, a cron job. Without it
# systemctl fails with
#
#     Failed to connect to bus: No medium found
#
# which names neither systemd nor the variable, and sends the reader looking for
# a broken unit that was never written. The directory is there regardless, so
# point at it rather than give up.
ensure_xdg() {
  [ -n "${XDG_RUNTIME_DIR:-}" ] && return 0
  local d
  d="/run/user/$(id -u)"
  [ -d "$d" ] || return 1
  export XDG_RUNTIME_DIR="$d"
  return 0
}

systemd_user_ok() {
  command -v systemctl >/dev/null 2>&1 || return 1
  ensure_xdg || return 1
  systemctl --user show-environment >/dev/null 2>&1
}

# --- the credential, which is where an unattended loop actually fails ---------
# A detached process does not inherit the shell's environment. GIT_TOKEN typed
# before ./agent.sh reaches agent.sh; GIT_TOKEN typed before ./service.sh install
# does NOT reach the service. The loop then starts perfectly, polls happily, and
# cannot push a single log - which is the expensive failure this toolkit exists
# to prevent, discovered hours later by somebody waiting on the far side.
#
# So it is checked BEFORE anything is installed, and named precisely. caplib owns
# the credential chain and this only asks it what it found: no second resolver,
# per the spec.
#
# WHICH credential is even relevant is decided by the remote's scheme, and the
# same three-way split start.sh uses is repeated here rather than a new rule of
# its own. An earlier version checked only for ssh and let everything else fall
# through to the token chain, which refused to install against a local path
# remote - a remote that needs no credential at all. Its own test caught it.
credential_check() {
  local src url scheme
  # shellcheck source=caplib.sh disable=SC1091
  . "$REPO_ROOT/caplib.sh" 2>/dev/null || { warn "could not read caplib.sh, skipping the credential check"; return 0; }
  src="$(_cap_token_source 2>/dev/null)"
  url="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null)"

  case "$url" in
    git@*|ssh://*)      scheme=ssh ;;
    https://*|http://*) scheme=https ;;
    "")                 scheme=none ;;
    *)                  scheme=other ;;
  esac

  case "$scheme" in
    none)
      warn "there is no origin remote. Git is the transport, so there is nowhere to push a log."
      return 1 ;;
    ssh)
      if [ -n "${SSH_AUTH_SOCK:-}" ]; then
        warn "origin is an SSH remote and this shell has an ssh-agent, which the service will NOT inherit."
        warn "  Give the service a key it can read without an agent: put one at ~/.ssh/id_ed25519,"
        warn "  or name it in ~/.ssh/config for this host. Otherwise every push will fail."
      fi
      return 0 ;;
    other)
      # A local path or a filesystem URL. git needs no credential for one, and
      # refusing here would block a perfectly good setup: bootstrap.sh's own
      # tests, a bind-mounted repo in a container, a bare repo on a share.
      return 0 ;;
  esac

  case "$src" in
    env:*|header:*)
      warn "the credential is ${src%%:*}:${src#*:}, which lives in THIS shell and will not reach the service."
      warn "  A detached process inherits no environment, so the loop would run and never push."
      warn "  Write it to a file the service can read instead:"
      warn "      printf '%%s' \"\$GIT_TOKEN\" > ~/.git-token && chmod 600 ~/.git-token"
      warn "  caplib reads ~/.git-token already, so nothing else has to change."
      return 1 ;;
    none)
      warn "no credential found at all. The loop will start and be unable to push."
      warn "  See references/transport.md, then re-run this."
      return 1 ;;
    unreadable:*)
      warn "a credential exists at ${src#unreadable:} but is not readable by $(id -un)."
      return 1 ;;
  esac
  return 0
}

# --- install -----------------------------------------------------------------
write_unit() {
  mkdir -p "$UNIT_DIR"
  # StartLimit* sit in [Unit], not [Service], on systemd 229 and newer.
  #
  # Restart=always with a limit, deliberately. Always, because the whole point is
  # a loop that is still there tomorrow and a transient network failure must not
  # end it. Limited, because start.sh runs a preflight that refuses to start on a
  # bad credential or a detached HEAD, and an unlimited restart would retry that
  # every ten seconds forever, filling the journal with the same refusal instead
  # of leaving it somewhere a person will read it.
  cat > "$UNIT_PATH" <<EOF
[Unit]
Description=heliograph agent loop ($REPO_ROOT)
Documentation=https://github.com/dbhq-uk/heliograph-skill
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=simple
WorkingDirectory=$REPO_ROOT
ExecStart=/usr/bin/env bash $REPO_ROOT/start.sh
Restart=always
RestartSec=10

# The loop is a diagnostic tool, not a service worth pre-empting real work for.
Nice=5

[Install]
WantedBy=default.target
EOF
}

cmd_install() {
  [ -f "$REPO_ROOT/start.sh" ] || die "no start.sh beside this script. Run it from inside a transport repo."

  if ! credential_check; then
    warn ""
    warn "Refusing to install a loop that cannot push. Fix the above, or pass --force"
    warn "if you know better than this check."
    [ "${1:-}" = "--force" ] || exit 1
    warn "--force given, installing anyway."
  fi

  if systemd_user_ok; then
    # LINGERING IS THE WHOLE TRICK. Without it the user manager is torn down at
    # logout and takes every --user unit with it, so the service would look
    # perfectly installed and still die exactly when it was supposed to survive.
    local linger
    linger="$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null)"
    if [ "$linger" != "yes" ]; then
      say "enabling lingering so the unit survives logout"
      if ! loginctl enable-linger "$(id -un)" 2>/dev/null; then
        sudo -n loginctl enable-linger "$(id -un)" 2>/dev/null || true
      fi
      linger="$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null)"
    fi

    write_unit
    systemctl --user daemon-reload
    systemctl --user enable --now "$UNIT_NAME" >/dev/null 2>&1 || {
      systemctl --user status "$UNIT_NAME" --no-pager 2>&1 | head -20
      die "the unit was written to $UNIT_PATH but would not start. Its status is above."
    }

    say ""
    say "installed: $UNIT_PATH"
    say "mechanism: systemd --user, restarts on failure, survives reboot"
    if [ "$linger" = "yes" ]; then
      say "lingering: enabled, so it survives logout"
    else
      warn "lingering: NOT enabled, and this is the one thing that matters here."
      warn "  The unit will run until you log out and then die with the user manager,"
      warn "  which is exactly what this was meant to prevent. Ask an administrator for:"
      warn "      sudo loginctl enable-linger $(id -un)"
    fi
    say ""
    say "  ./service.sh status     what it is doing"
    say "  ./service.sh logs       follow the journal"
    return 0
  fi

  # --- fallback ---------------------------------------------------------------
  say "no user systemd here, falling back to setsid + nohup"
  if [ -s "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    die "already running as pid $(cat "$PID_FILE"). Stop it first: ./service.sh stop"
  fi
  # setsid detaches from the controlling terminal so SIGHUP never arrives, and
  # the redirects matter as much: a process whose stdout is a closed pty gets
  # EIO on the next write and dies anyway, having survived the signal.
  setsid nohup bash "$REPO_ROOT/start.sh" >>"$LOG_FILE" 2>&1 </dev/null &
  local pid=$!
  sleep 2
  if ! kill -0 "$pid" 2>/dev/null; then
    say "--- last of $LOG_FILE ---"
    tail -20 "$LOG_FILE" 2>/dev/null
    die "it exited immediately. Its output is above."
  fi
  printf '%s\n' "$pid" > "$PID_FILE"
  say ""
  say "running  : pid $pid"
  say "log      : $LOG_FILE"
  say "mechanism: setsid + nohup. Survives logout. Does NOT survive a reboot -"
  say "           after one, run this again."
}

# --- the others ---------------------------------------------------------------
cmd_status() {
  if systemd_user_ok && [ -f "$UNIT_PATH" ]; then
    say "mechanism: systemd --user ($UNIT_PATH)"
    say "lingering: $(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null)"
    systemctl --user status "$UNIT_NAME" --no-pager 2>&1 | head -15
    return 0
  fi
  if [ -s "$PID_FILE" ]; then
    local pid; pid="$(cat "$PID_FILE")"
    if kill -0 "$pid" 2>/dev/null; then
      say "mechanism: setsid + nohup"
      say "running  : pid $pid"
      say "log      : $LOG_FILE"
    else
      say "not running. A stale pid file says $pid; the process is gone."
      say "log      : $LOG_FILE"
    fi
    return 0
  fi
  say "not installed. Run: ./service.sh install"
}

cmd_logs() {
  if systemd_user_ok && [ -f "$UNIT_PATH" ]; then
    exec journalctl --user -u "$UNIT_NAME" -f -n 50
  fi
  [ -f "$LOG_FILE" ] || die "no log yet at $LOG_FILE, and no systemd unit installed."
  exec tail -f -n 50 "$LOG_FILE"
}

cmd_stop() {
  local stopped=0
  if systemd_user_ok && [ -f "$UNIT_PATH" ]; then
    systemctl --user stop "$UNIT_NAME" 2>/dev/null && { say "stopped the unit"; stopped=1; }
  fi
  if [ -s "$PID_FILE" ]; then
    local pid; pid="$(cat "$PID_FILE")"
    if kill -0 "$pid" 2>/dev/null; then
      # TERM the whole process group: setsid gave it its own, and agent.sh's own
      # cleanup trap handles the rest.
      kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
      say "stopped pid $pid"
      stopped=1
    fi
    rm -f "$PID_FILE"
  fi
  [ "$stopped" = "1" ] || say "nothing was running"
}

cmd_uninstall() {
  cmd_stop
  if [ -f "$UNIT_PATH" ]; then
    systemd_user_ok && systemctl --user disable "$UNIT_NAME" >/dev/null 2>&1
    rm -f "$UNIT_PATH"
    systemd_user_ok && systemctl --user daemon-reload
    say "removed $UNIT_PATH"
  fi
  rm -f "$PID_FILE"
  say "uninstalled. Lingering is left enabled: it is a property of the user, not"
  say "of this repo, and other things may rely on it."
}

case "${1:-}" in
  install)   shift; cmd_install "$@" ;;
  status)    cmd_status ;;
  logs)      cmd_logs ;;
  stop)      cmd_stop ;;
  uninstall) cmd_uninstall ;;
  *)
    sed -n '2,9p' "$0" | sed 's/^#\{1,\} \{0,2\}//'
    exit 2 ;;
esac
