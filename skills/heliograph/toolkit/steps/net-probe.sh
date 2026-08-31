#!/usr/bin/env bash
# =============================================================================
#  steps/net-probe.sh - can this box reach those boxes, on those ports?
# =============================================================================
# heliograph-mode: read-only
# Resolve, ping, then TCP-connect every host against every port, one line each,
# in a table you can diff between runs.
#
# ICMP is probed separately and deliberately: "all TCP ports open" is not the
# same as "reachable". Windows failover clustering, for one, will not form with
# ICMP filtered even when every port it needs is open - so a green TCP matrix on
# its own does not clear the network.
#
# Set the targets by editing the two lines below on your task branch, or pass
# them in for a one-off:
#
#     HOSTS="a b" PORTS="22 443" ./run.sh net
#
# Read-only. Safe to run repeatedly.
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/../lib/probe.sh"
. "$HERE/../lib/remote.sh"

# ==============================================================
#  TARGETS - Claude edits these two lines on a task branch
# ==============================================================
HOSTS="${HOSTS:-}"
PORTS="${PORTS:-22 445 3389 5985 5986 1433 443}"
# ==============================================================

if [ -z "$HOSTS" ]; then
  cat >&2 <<'MSG'
net-probe: no HOSTS set.

Set them for this branch by editing the HOSTS line in steps/net-probe.sh, or
pass them for a one-off run:

    HOSTS="dbnode01 dbnode02" ./run.sh net

MSG
  exit 2
fi

echo "NET PROBE"
echo "hosts: $HOSTS"
echo "ports: $PORTS"

# --- name resolution first ---------------------------------------------------
# A failure here makes every later result meaningless, so it is worth reading
# before anything else: an unresolvable name and a filtered port look identical
# from a TCP probe alone.
for h in $HOSTS; do
  probe "resolve $h" rt_dns "$h"
done

# --- ICMP --------------------------------------------------------------------
for h in $HOSTS; do
  probe "ping $h" rt_ping "$h" 3
done

# --- TCP matrix --------------------------------------------------------------
# Not a `probe` - one closed port shouldn't mask the rest of the table. The
# whole matrix is the finding; read it as a shape, not as pass/fail.
sec "TCP matrix ($(echo "$HOSTS" | wc -w) hosts x $(echo "$PORTS" | wc -w) ports)"
rt_matrix "$HOSTS" "$PORTS"
MATRIX_RC=$?
[ "$MATRIX_RC" -ne 0 ] && echo "(some ports did not answer - that may be expected; compare against a known-good host)"

# --- the return path ---------------------------------------------------------
# Reachability is directional. If you can SSH to a host, ask it about the others
# from where it sits: the fault is frequently in the direction you didn't test.
if [ -n "${SSH_FROM:-}" ]; then
  for h in $HOSTS; do
    [ "$h" = "$SSH_FROM" ] && continue
    probe "from $SSH_FROM -> $h (reverse direction)" \
      rt_ssh "$SSH_FROM" "for p in $PORTS; do timeout 5 bash -c \": >/dev/tcp/$h/\$p\" 2>/dev/null && echo \"OPEN    $h:\$p\" || echo \"closed  $h:\$p\"; done"
  done
else
  sec "reverse direction"
  echo "(skipped - set SSH_FROM=<host you can ssh to> to probe from the far side)"
fi

probe_summary
