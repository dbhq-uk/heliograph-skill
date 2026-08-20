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
# A Windows host running OpenSSH defaults its shell to cmd unless someone has
# set DefaultShell, and everything awkward here follows from that one fact.
# Measured against Windows Server 2022 with OpenSSH and PowerShell 5.1.
#
# WHY NOT PLAIN -Command. ssh joins its arguments into one command line and
# hands it to cmd, so cmd parses it BEFORE powershell ever sees it. Any cmd
# metacharacter in the script is therefore eaten, and the pipe is the one that
# matters because a PowerShell diagnostic without a pipe is barely PowerShell:
#
#     rt_ps host 'Get-Service sshd | Select-Object Name,Status'
#     'Select-Object' is not recognized as an internal or external command
#
# cmd took the pipe and tried to run Select-Object as a program. The same goes
# for & < > and ^.
#
# WHY -EncodedCommand, despite what this comment used to say. Base64 of UTF-16LE
# has no metacharacters at all, so cmd cannot corrupt it. The old warning that it
# "breaks through this path" was describing a real symptom with the wrong cause:
# PowerShell decides it is not attached to a console and serialises its non-stdout
# streams as CLIXML, so the log fills with
#
#     #< CLIXML
#     <Objs Version="1.1.0.1" ...><S S="Error">Get-Service : Cannot find ...
#
# That is worst exactly when it hurts most, because a remote ERROR is the thing
# you are usually reading the log for. Two settings fix it rather than avoiding
# the flag: silencing $ProgressPreference stops the progress records, and merging
# the streams INSIDE PowerShell with 2>&1 | Out-String -Stream renders errors as
# the text a person expects before anything can serialise them. Measured: CLIXML
# occurrences drop to 0, and the error reads
#
#     Get-Service : Cannot find any service with service name 'no-such-service'
#
# ENCODING. The remote console is IBM437 out of the box, so non-ASCII is mangled
# on the way out and some of it is destroyed outright: a euro sign came back as
# "?". Forcing UTF-8 fixes it, verified by round-tripping e-acute, u-umlaut and
# a euro sign back as valid UTF-8. This is not exotic on a localised Windows
# estate, where service descriptions and error text are non-ASCII as a matter of
# course.
#
# LINE ENDINGS are NOT handled here. PowerShell emits CRLF and ssh carries it
# through verbatim, but cap_run strips the trailing CR for every step, so fixing
# it a second time here would be a second place to keep in step with the first.
_rt_ps_encode() {
  local script="$1"
  if command -v iconv >/dev/null 2>&1; then
    printf '%s' "$script" | iconv -f utf-8 -t utf-16le | base64 -w0
    return 0
  fi
  # iconv lives in glibc and is present on every host this has run on, including
  # the container image. The fallback exists so a missing one degrades to a clear
  # refusal rather than a corrupted command: widening each ASCII byte with a NUL
  # is exactly UTF-16LE, verified byte-identical to iconv, but only for ASCII.
  if printf '%s' "$script" | LC_ALL=C grep -q '[^[:print:][:space:]]'; then
    echo "rt_ps: this script contains non-ASCII and iconv is not installed, so it cannot be encoded for the remote host. Install iconv, or keep the script ASCII and let the REMOTE output be non-ASCII, which is handled." >&2
    return 1
  fi
  printf '%s' "$script" | sed 's/./&\x00/g' | base64 -w0
}

# rt_ps <target> <powershell-script>
# Pass the script as ONE plain string. Pipes, quotes and ampersands are safe.
rt_ps() {
  local target="$1"; shift
  local wrapped b64
  # $Error is what restores the exit code. Merging the streams with 2>&1 defeats
  # PowerShell's own "did an error happen" tracking, because the error becomes an
  # object in a pipeline that then succeeds. Measured against a real host:
  # `Get-Service no-such-service` returned 1 before this rewrite and 0 after it,
  # which would have quietly stopped a step noticing that a remote probe failed.
  # Clearing $Error first and testing it last puts that back, and an explicit
  # `exit N` inside the script still wins because it never reaches this line.
  wrapped='$ProgressPreference = "SilentlyContinue"
$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$Error.Clear()
& {
'"$*"'
} 2>&1 | Out-String -Stream | ForEach-Object { [Console]::Out.WriteLine($_) }
exit $(if ($Error.Count) { 1 } else { 0 })'
  b64="$(_rt_ps_encode "$wrapped")" || return 1
  rt_ssh "$target" powershell -NoProfile -NonInteractive -EncodedCommand "$b64"
}

# rt_win_info <target> - quick "is this box alive and who am I on it".
# Single quotes are deliberate: $env: must reach PowerShell unexpanded.
# shellcheck disable=SC2016
rt_win_info() {
  rt_ps "$1" '$env:COMPUTERNAME; whoami; (Get-CimInstance Win32_OperatingSystem).Caption; Get-Date -Format o'
}
