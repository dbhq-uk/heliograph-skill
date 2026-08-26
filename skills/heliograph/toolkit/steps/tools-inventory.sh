#!/usr/bin/env bash
# =============================================================================
#  steps/tools-inventory.sh - what can this runner actually do?
# =============================================================================
#  Read-only. Answers one question: what can this host actually do?
#
#  WHY THIS EXISTS SEPARATELY FROM `env`. The env step checks a fixed list of
#  ten tools chosen for a general control node, and its silence is ambiguous: a
#  tool it does not name is not absent, it is unchecked. This names everything
#  worth having and reports each one either way, so "not listed" stops being a
#  category. Grouped by what the tools are FOR, because a group with nothing in
#  it is a capability this host does not have.
#
#  IT IS MOST USEFUL WHERE NOTHING CAN BE INSTALLED. On a locked-down host the
#  package manager cannot reach a repository, so the only way to add a tool is
#  to rebuild the image or ship a static binary - and both need to know what is
#  already there first. That is why it also reports the package manager and its
#  configured repos: an image build needs to know what base it starts from.
#
#  It is worth running on an ordinary control node too. "Which of these does
#  this machine have" is a question every investigation eventually asks.
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/../lib/probe.sh"

echo "STEP: which tools exist on this runner, and what would an image need to add"

# --- what the host is --------------------------------------------------------
sec "host"
probe_opt "os" sh -c 'cat /etc/os-release 2>/dev/null | head -5'
probe_opt "kernel" uname -a
probe_opt "user" id

# --- the tools ---------------------------------------------------------------
# Reported one per line, present or not, with a version where the tool offers
# one cheaply. Grouped by what they are FOR rather than alphabetically: the
# question behind this step is "what can this runner diagnose", and a group with
# nothing in it is a capability we do not have.
report() {
  # report <group> <tool> [version-args...]
  local tool="$1"; shift
  if command -v "$tool" >/dev/null 2>&1; then
    local v=""
    if [ "$#" -gt 0 ]; then
      v="$("$tool" "$@" 2>&1 | head -1)"
    fi
    printf '  %-14s %s\n' "$tool" "${v:-present}"
  else
    printf '  %-14s -- MISSING --\n' "$tool"
  fi
}

sec "shell and core"
for t in bash sh awk sed grep find xargs wc head tail sort tr cut; do report "$t"; done

sec "archive and transfer"
report tar --version
report gzip --version
report unzip -v
report curl --version
report wget --version

sec "network diagnostics"
report ping -V
report ip -V
report ss --version
report netstat --version
report nc -h
report ncat --version
report telnet
report traceroute --version
report tracepath
report getent
report dig -v
report nslookup -version
report host -V
report openssl version

sec "process and system"
report hostname --version
report uptime --version
report free --version
report ps --version
report top -v
report lsof -v
report dmesg --version

sec "data and scripting"
report python3 --version
report jq --version
report yq --version
report git --version

sec "azure and database"
report az version
report sqlcmd -?
report bcp -v
report isql --version
report odbcinst --version

sec "package manager (for the image build, NOT for installing here)"
report tdnf --version
report rpm --version
probe_opt "repos configured" sh -c 'ls /etc/yum.repos.d/ 2>/dev/null'

# --- python, which is the most extensible thing here -------------------------
# Python is present because az is a Python application, so it is the cheapest
# route to a capability we lack. Which modules are already importable decides
# whether a step can be written today or needs an image change first.
sec "python modules"
if command -v python3 >/dev/null 2>&1; then
  for m in ssl socket json sqlite3 urllib.request http.client tarfile zipfile \
           hashlib base64 datetime subprocess pyodbc httpx paramiko jwt \
           azure.identity azure.storage.blob azure.keyvault.secrets requests; do
    if python3 -c "import $m" >/dev/null 2>&1; then
      printf '  %-28s importable\n' "$m"
    else
      printf '  %-28s -- MISSING --\n' "$m"
    fi
  done
else
  echo "  (python3 not present - skipped)"
fi

# --- ODBC --------------------------------------------------------------------
# Its own section because "the database is reachable but there is no client" is
# a common and confusing state: the network probe passes, the query does not
# run, and the two look unrelated. This says whether what is missing is the
# driver, the tools, or both.
sec "odbc drivers"
probe_opt "odbcinst -j" sh -c 'odbcinst -j 2>/dev/null'
probe_opt "installed drivers" sh -c 'odbcinst -q -d 2>/dev/null'
probe_opt "driver files" sh -c 'ls -1 /opt/microsoft/msodbcsql*/lib64/ 2>/dev/null; ls -1 /usr/lib*/libodbc* 2>/dev/null'

# --- the control -------------------------------------------------------------
# OPTIONAL, AND OFF UNLESS ASKED. Set CONTROL_HOSTS to somewhere this runner is
# expected to reach, as host:port pairs:
#
#     CONTROL_HOSTS="10.0.0.4:443 db.internal:1433" ./run.sh tools
#
# It exists so a reader can tell "this runner cannot do X" from "this runner
# could not test X". An inventory with no control says which tools are present
# and nothing about whether the host can use them for anything.
#
# There is no default, because a default would be a guess about somebody else's
# network, and a guessed control that fails looks exactly like a real finding.
if [ -n "${CONTROL_HOSTS:-}" ]; then
  sec "control: can this runner still reach what it is meant to"
  for hp in $CONTROL_HOSTS; do
    h="${hp%:*}"; p="${hp##*:}"
    probe_opt "tcp ${h}:${p}" bash -c "exec 3<>/dev/tcp/${h}/${p} && echo OPEN"
  done
else
  sec "control"
  echo "  (none set - CONTROL_HOSTS=\"host:port ...\" adds one)"
fi

probe_summary
