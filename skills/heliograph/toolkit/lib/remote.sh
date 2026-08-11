#!/usr/bin/env bash
# =============================================================================
#  lib/remote.sh - reaching other machines (Linux + Windows over SSH)
# =============================================================================
# Sourced by step scripts. Every function is non-interactive and time-bounded:
# a probe that hangs waiting on a password or a host-key prompt is worse than a
# probe that fails, because the log just stops with no explanation.
# =============================================================================

RT_TIMEOUT="${RT_TIMEOUT:-10}"

# --- name resolution ---------------------------------------------------------
# rt_dns <host> - resolve without depending on dig/nslookup being installed.
# An IP literal needs no resolution: report that plainly instead of a "cannot
# resolve" failure, which would read as a finding when nothing is wrong. A
# reverse lookup is attempted but is informational only - no PTR record is
# normal here and must not count against the probe.
rt_dns() {
  local h="$1"
  if printf '%s' "$h" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$|:'; then
    echo "DNS: $h is an IP literal - no resolution needed"
    getent hosts "$h" 2>/dev/null || echo "     (no reverse/PTR entry - informational)"
    return 0
  fi
  if getent hosts "$h"; then return 0; fi
  echo "DNS: cannot resolve $h"
  return 1
}

# --- ICMP --------------------------------------------------------------------
# rt_ping <host> [count]
# Worth probing separately from TCP: Windows failover clustering needs ICMP
# between nodes, and a host that answers on every TCP port can still fail to
# cluster because ICMP is filtered. Test both directions before concluding.
rt_ping() {
  local h="$1" n="${2:-3}"
  ping -c "$n" -W 2 "$h"
}

# --- TCP ---------------------------------------------------------------------
# rt_tcp <host> <port> [timeout] - no nc dependency; pure bash + timeout(1).
rt_tcp() {
  local h="$1" p="$2" t="${3:-$RT_TIMEOUT}"
  if timeout "$t" bash -c ": >/dev/tcp/$h/$p" 2>/dev/null; then
    printf 'OPEN    %s:%s\n' "$h" "$p"; return 0
  else
    printf 'closed  %s:%s  (no answer in %ss)\n' "$h" "$p" "$t"; return 1
  fi
}

# rt_matrix "<hosts>" "<ports>"
# The "run it in all directions" probe: every host against every port, one line
# each, in a table you can diff between runs. Returns 1 if anything is closed.
rt_matrix() {
  local hosts="$1" ports="$2" h p rc=0
  for h in $hosts; do
    for p in $ports; do
      rt_tcp "$h" "$p" || rc=1
    done
  done
  return "$rc"
}

# --- SSH ---------------------------------------------------------------------
# rt_ssh <target> <cmd> [args...]   target = host or user@host
#
# BatchMode so it fails instead of prompting: an interactive password or
# host-key question through the capture pipeline is invisible, and the run just
# hangs with no output at all.
#
# HOST-KEY CHECKING IS OFF BY DEFAULT, and that is a real trade-off rather than
# an oversight. A locked-down control node is routinely provisioned with no
# known_hosts, so strict checking turns every first connection into exactly the
# silent hang BatchMode exists to prevent. The cost is that these probes do not
# detect a man-in-the-middle, so treat what they return as diagnostic evidence
# and not as an authenticated channel - and never send a secret over one.
#
# Set RT_SSH_STRICT=1 where known_hosts IS provisioned, which is the safer
# setting and should be preferred whenever the estate allows it.
rt_ssh() {
  local target="$1"; shift
  if [ "${RT_SSH_STRICT:-0}" = "1" ]; then
    ssh -o BatchMode=yes \
        -o StrictHostKeyChecking=yes \
        -o LogLevel=ERROR \
        -o ConnectTimeout="$RT_TIMEOUT" \
        "$target" "$@"
  else
    ssh -o BatchMode=yes \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -o ConnectTimeout="$RT_TIMEOUT" \
        "$target" "$@"
  fi
}

# --- Windows over SSH --------------------------------------------------------
# rt_ps <target> <powershell-script>
# A Windows host running OpenSSH commonly defaults its shell to cmd, so
# PowerShell has to be invoked explicitly. Pass the script as ONE plain string:
# -EncodedCommand is known to break through this path, so don't reach for it.
rt_ps() {
  local target="$1"; shift
  rt_ssh "$target" powershell -NoProfile -NonInteractive -Command "$*"
}

# rt_win_info <target> - quick "is this box alive and who am I on it".
# Single quotes are deliberate: $env: must reach PowerShell unexpanded.
# shellcheck disable=SC2016
rt_win_info() {
  rt_ps "$1" '$env:COMPUTERNAME; whoami; (Get-CimInstance Win32_OperatingSystem).Caption; Get-Date -Format o'
}
