#!/usr/bin/env bash
# =============================================================================
#  test-redact.sh - cap_redact masks a credential carried in a URL
# =============================================================================
# Every captured log is committed and pushed, so anything a command echoes is in
# that history permanently. `scheme://user:password@host` is the shape that got
# through: it is neither key=value nor a Bearer/Basic header, and steps print git
# and registry URLs constantly.
#
# Over-masking is the other failure, and it is not free: these logs are the only
# evidence anybody gets. So the untouched cases are asserted as carefully as the
# masked ones.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=assert.sh disable=SC1091
. "$HERE/assert.sh"
TOOLKIT="$(cd "$HERE/../skills/heliograph/toolkit" && pwd)"

# shellcheck source=../skills/heliograph/toolkit/caplib.sh disable=SC1091
. "$TOOLKIT/caplib.sh"

red() { printf '%s\n' "$1" | cap_redact; }

# --- masked -------------------------------------------------------------------
assert_eq "a token in an https clone URL is masked" \
  "Cloning into 'x' from https://ci-user:***REDACTED***@git.invalid/private/transport.git" \
  "$(red "Cloning into 'x' from https://ci-user:glpat-SUPERSECRETTOKEN@git.invalid/private/transport.git")"

assert_eq "the token itself never survives" "" \
  "$(red "remote add origin https://u:glpat-SUPERSECRETTOKEN@h/x.git" | grep -o glpat-SUPERSECRETTOKEN)"

assert_eq "an empty username still masks the password" \
  "https://:***REDACTED***@host/x.git" \
  "$(red "https://:glpat-abc@host/x.git")"

assert_eq "two URLs on one line are both masked" \
  "two: https://a:***REDACTED***@h1/x and https://c:***REDACTED***@h2/y" \
  "$(red "two: https://a:b@h1/x and https://c:d@h2/y")"

assert_eq "http, not only https" \
  "http://user:***REDACTED***@host/x.git" \
  "$(red "http://user:pw@host/x.git")"

# --- left alone ---------------------------------------------------------------
for keep in \
  "plain https://git.invalid/private/transport.git" \
  "user only https://ci-user@git.invalid/x.git" \
  "scp form git@github.com:owner/repo.git" \
  "ssh form ssh://git@host:2222/owner/repo.git" \
  "local path /srv/git/x.git" \
  "port only https://host:8443/x.git" \
  "an address in a path https://api.host/users/foo@bar.com" \
  "prose: connecting to https://host and then user:pass@other thing"
do
  assert_eq "left alone: $keep" "$keep" "$(red "$keep")"
done

# REDACT=0 is the documented escape hatch for when masking hides what you need.
assert_eq "REDACT=0 disables it, as documented" \
  "https://u:tok@h/x.git" \
  "$(REDACT=0 red "https://u:tok@h/x.git")"

t_summary
