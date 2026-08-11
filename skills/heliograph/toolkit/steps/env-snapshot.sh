#!/usr/bin/env bash
# =============================================================================
#  steps/env-snapshot.sh - what is this control node, really?
# =============================================================================
# The correct first step of ANY investigation on a box you can't log into.
# It answers the questions that otherwise get assumed and turn out to be wrong:
# which host, which user, which tool versions, is there a proxy in the way, what
# does DNS look like, and what commit of this repo is actually checked out.
#
# Read-only. Never prompts. Safe to run repeatedly.
#
#     ./run.sh env          # captured + pushed
#     ./steps/env-snapshot.sh   # straight to the terminal
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/../lib/probe.sh"

echo "ENV SNAPSHOT - control node baseline"

# --- identity ----------------------------------------------------------------
probe "host"        sh -c 'hostname -f 2>/dev/null || hostname'
# The whole of os-release, not the first few lines: VARIANT_ID and the support
# URLs sit at the bottom and are exactly what identifies a derivative or a
# vendor-patched image. Truncating this is the rule in method.md being broken in
# the very first probe of the very first step.
probe "os"          sh -c 'cat /etc/os-release 2>/dev/null; uname -a'
probe "uptime"      uptime
probe "clock (UTC - check for skew against your own)" date -u +%Y-%m-%dT%H:%M:%SZ
probe "user"        sh -c 'whoami; id'

# Non-prompting sudo check. `sudo -n` never blocks, so this can't hang the log;
# a "password required" answer here predicts the classic silent hang later.
probe_opt "sudo (non-interactive)" sh -c \
  'if sudo -n true 2>/dev/null; then echo "sudo: available WITHOUT a password"; \
   else echo "sudo: needs a password - runs that escalate must use SUDO=1"; fi'

# --- resources ---------------------------------------------------------------
probe "disk"        df -h
probe "memory"      free -h

# --- tooling -----------------------------------------------------------------
# Versions, not just presence. A floated tool version is a recurring cause of
# "the playbook that worked last month" - record it every run so the log itself
# proves what was installed at the time.
sec "tool versions"
# Not every tool answers to --version: ssh wants -V and prints to stderr, kubectl
# and helm want a subcommand, and az leads with an upgrade warning. Ask each one
# the way it expects, or the log records an error message where a version should
# be - which is worse than useless, because it looks like a finding.
tool_version() {
  case "$1" in
    ssh)     ssh -V 2>&1 | head -1 ;;
    kubectl) kubectl version --client 2>&1 | grep -i version | head -1 ;;
    helm)    helm version --short 2>&1 | head -1 ;;
    az)      az version --query '"azure-cli"' -o tsv 2>/dev/null | head -1 ;;
    *)       "$1" --version 2>&1 | head -1 ;;
  esac
}
for t in bash git curl python3 jq yq az ansible ansible-playbook terraform ssh kubectl docker helm; do
  if have "$t"; then
    printf '%-18s %s\n' "$t" "$(tool_version "$t")"
  else
    printf '%-18s -- not installed --\n' "$t"
  fi
done

# --- network path ------------------------------------------------------------
# Proxy variables are the usual explanation for "CONNECT tunnel failed 503" and
# for internal hostnames failing to resolve: internal traffic being sent through
# a proxy that cannot see internal DNS. Record them before theorising.
sec "proxy environment"
env | grep -Ei '^(http_proxy|https_proxy|ftp_proxy|no_proxy|HTTP_PROXY|HTTPS_PROXY|NO_PROXY)=' || echo "(no proxy variables set)"

probe_opt "resolv.conf" cat /etc/resolv.conf
probe_opt "default route" sh -c 'ip route show default 2>/dev/null || route -n 2>/dev/null'
probe_opt "addresses" sh -c 'ip -br addr 2>/dev/null || ifconfig -a 2>/dev/null'

# --- cloud auth --------------------------------------------------------------
# `az account show` prints subscription/tenant, no tokens. If this fails, every
# downstream az/terraform step will fail too, and it will fail less legibly.
if have az; then
  probe_opt "az account" az account show --output table
else
  sec "az account"; echo "(az not installed)"
fi

# --- this repo ---------------------------------------------------------------
# Which commit the operator actually ran matters more than which commit you
# pushed. Divergence here explains "but I fixed that" more often than anything.
probe "repo: branch + head" sh -c 'git rev-parse --abbrev-ref HEAD; git log --oneline -5'
probe "repo: remote"        git remote -v
probe "repo: status"        git status --short --branch

probe_summary
