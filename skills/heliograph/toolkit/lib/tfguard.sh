#!/usr/bin/env bash
# =============================================================================
#  lib/tfguard.sh - running terragrunt against someone else's repo, safely
# =============================================================================
# Two things that have gone wrong twice each, now in one place instead of
# copy-pasted into every step that touches Terraform.
#
# 1. `terraform init -upgrade` is not "fetch the new module ref".
#    It re-resolves PROVIDERS to latest, ignoring .terraform.lock.hcl. In one
#    estate that meant azurerm 5.0.1 over a locked 3.x, which broke
#    azurerm_private_dns_a_record, azurerm_private_dns_zone_virtual_network_link
#    and azurerm_linux_virtual_machine in modules nothing had touched - and the
#    resulting errors point at files the change never went near.
#
#    A changed module `?ref=` is re-fetched by a PLAIN init anyway: module
#    installation is not governed by the lock file. So -upgrade is only ever
#    wanted when deliberately moving providers, and then only with a pin.
#
# 2. `.terraform.lock.hcl` is usually a TRACKED file.
#    An accidental upgrade therefore leaves the next person a slice pinned to a
#    provider that breaks on init. Restoring it is not tidiness, it is undoing
#    damage - and it has to happen before terragrunt runs, not after.
#
# Usage:
#     . "$HERE/../lib/tfguard.sh"
#     tf_lock_guard "$REPO" path/to/slice
#     TG_SLICE="$REPO/path/to/slice"; tg plan -input=false
# =============================================================================

# tf_lock_guard <repo-root> <slice-path-relative-to-repo>
# Restores the slice's tracked provider lock to HEAD if something moved it, and
# reports the azurerm version in force either way. Loud on purpose: a silently
# restored lock is as confusing as a silently upgraded one.
tf_lock_guard() {
  local repo="$1" slice="$2" lock="$1/$2/.terraform.lock.hcl"
  echo "--- provider lock: $slice/.terraform.lock.hcl"
  if [ ! -f "$lock" ]; then
    echo "    (no tracked lock file in this slice)"
    return 0
  fi
  if git -C "$repo" ls-files --error-unmatch "$slice/.terraform.lock.hcl" >/dev/null 2>&1; then
    if git -C "$repo" diff --quiet -- "$slice/.terraform.lock.hcl" 2>/dev/null; then
      echo "    clean - matches HEAD"
    else
      echo "    MODIFIED relative to HEAD - restoring. What is being reverted:"
      git -C "$repo" diff --stat -- "$slice/.terraform.lock.hcl" | sed 's/^/      /'
      git -C "$repo" checkout -- "$slice/.terraform.lock.hcl" \
        && echo "    restored to HEAD" \
        || echo "    RESTORE FAILED - do not apply; the provider pins are wrong"
    fi
  else
    echo "    (untracked - nothing to restore against)"
  fi
  printf '    azurerm in force: '
  grep -A2 'provider .*azurerm' "$lock" 2>/dev/null | sed -n 's/.*version *= *"\(.*\)".*/\1/p' | head -1 \
    || echo "(could not read)"
}

# tg <terragrunt-args...> - run terragrunt in $TG_SLICE.
# Retries ONLY when terragrunt rejected the subcommand name (it was renamed
# between versions). Retrying on any non-zero re-runs a plan that failed on its
# merits, which has happened here and doubles the wait for no information.
#
# Output STREAMS and is also kept, rather than being captured into a variable and
# echoed at the end. That distinction is load-bearing: the runner stamps each
# line as it arrives, so a buffered block would land with one identical timestamp
# and a terragrunt that hangs for six minutes would look instantaneous. A plan is
# exactly the long-running thing you need the timestamp column to describe.
tg() {
  local rc tmp
  tmp="$(mktemp)"
  ( cd "$TG_SLICE" && terragrunt "$@" -no-color 2>&1 ) | tee "$tmp"
  rc="${PIPESTATUS[0]}"
  if [ "$rc" -ne 0 ] && grep -qiE 'unknown command|invalid command|unrecognized|did you mean' "$tmp"; then
    echo "--- terragrunt rejected the subcommand '$1'; retrying via 'terragrunt run -- $1' ---"
    ( cd "$TG_SLICE" && terragrunt run -- "$@" -no-color ) ; rc=$?
  fi
  rm -f "$tmp"
  return "$rc"
}
