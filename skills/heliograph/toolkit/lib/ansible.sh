#!/usr/bin/env bash
# =============================================================================
#  lib/ansible.sh - Ansible probes
# =============================================================================
# For ad-hoc Ansible run from THIS repo. If the playbook lives in a repo with
# its own entrypoint (one that resolves the environment and fetches the real
# inventory, say), don't reimplement that here - run the real entrypoint
# through caprun.sh instead:
#
#     ./caprun.sh dbplay -- ../ops-repo/run-playbook.sh prod cluster.yml inv.json
#
# INVENTORY selects the inventory (default: ./inventory.ini on this branch).
# =============================================================================

INVENTORY="${INVENTORY:-./inventory.ini}"
AN_BIN="${AN_BIN:-ansible}"
AN_PLAYBOOK_BIN="${AN_PLAYBOOK_BIN:-ansible-playbook}"

# Never buffer, never colour: the runner strips ANSI anyway, and unbuffered
# output is what makes a hang visible as a gap in the timestamps.
export ANSIBLE_FORCE_COLOR=0
export PYTHONUNBUFFERED=1

an_version() { "$AN_PLAYBOOK_BIN" --version; }

# an_ping <pattern> - Linux reachability.
an_ping() { "$AN_BIN" -i "$INVENTORY" "$1" -m ping; }

# an_win_ping <pattern> - Windows reachability (different module, same idea).
an_win_ping() { "$AN_BIN" -i "$INVENTORY" "$1" -m win_ping; }

# an_facts <pattern> [subset] - the baseline snapshot to take BEFORE theorising
# about a host. Cheap, and it settles most "is it even the machine I think it
# is" questions on the spot.
an_facts() {
  "$AN_BIN" -i "$INVENTORY" "$1" -m setup ${2:+-a "gather_subset=$2"}
}

# an_play <playbook> [extra ansible-playbook args...]
an_play() { local pb="$1"; shift; "$AN_PLAYBOOK_BIN" -i "$INVENTORY" "$pb" "$@"; }

# an_check <playbook> [args...] - dry run first. Note --check is honest about
# very little on Windows plays that shell out; treat a clean check as weak
# evidence, not proof.
an_check() { local pb="$1"; shift; "$AN_PLAYBOOK_BIN" -i "$INVENTORY" "$pb" --check --diff "$@"; }

# an_list <playbook> - which hosts and tasks would actually run.
an_list() { "$AN_PLAYBOOK_BIN" -i "$INVENTORY" "$1" --list-hosts --list-tasks; }

# an_inventory - resolved inventory as Ansible sees it, not as you think it is.
an_inventory() { ansible-inventory -i "$INVENTORY" --list --yaml; }
