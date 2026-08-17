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

# --- the bare userinfo form, which has no colon at all -------------------------
# The rule above REQUIRES a colon, so `https://ghp_...@github.com/org/repo.git` -
# the commonest GitHub PAT clone URL there is - went through it untouched and into
# a log that is committed and pushed permanently.
assert_eq "a bare token in an https clone URL is masked" \
  "Cloning into 'x' from https://***REDACTED***@github.com/org/transport.git" \
  "$(red "Cloning into 'x' from https://ghp_SUPERSECRETTOKEN@github.com/org/transport.git")"

assert_eq "the bare token itself never survives either" "" \
  "$(red "remote add origin https://ghp_SUPERSECRETTOKEN@github.com/o/r.git" | grep -o ghp_SUPERSECRETTOKEN)"

assert_eq "http, not only https, for the bare form too" \
  "http://***REDACTED***@host/x.git" \
  "$(red "http://tok@host/x.git")"

assert_eq "two bare-userinfo URLs on one line are both masked" \
  "two: https://***REDACTED***@h1/x and https://***REDACTED***@h2/y" \
  "$(red "two: https://t1@h1/x and https://t2@h2/y")"

# DELIBERATE, and worth stating rather than discovering: `https://ci-user@host/x`
# is a legitimate, non-secret form and this masks the username as well. Nothing in
# a line of text can tell a username from a token in that position. Hiding a
# username costs a name the reader can find elsewhere in seconds; missing a token
# costs a live PAT in a history that cannot be unpublished.
assert_eq "a legitimate username in that position is masked too, deliberately" \
  "https://***REDACTED***@git.invalid/x.git" \
  "$(red "https://ci-user@git.invalid/x.git")"

# Order: the colon rule runs first, so the bare rule only ever sees a span with a
# colon already in it and cannot re-match. Masking must therefore be idempotent -
# an already-masked URL echoed back by a later command comes out identical rather
# than gaining a second layer.
assert_eq "an already-masked bare URL is not masked a second time" \
  "https://***REDACTED***@github.com/org/repo.git" \
  "$(red "https://***REDACTED***@github.com/org/repo.git")"

assert_eq "an already-masked user:password URL is not masked a second time" \
  "https://ci-user:***REDACTED***@git.invalid/p/t.git" \
  "$(red "https://ci-user:***REDACTED***@git.invalid/p/t.git")"

assert_eq "the two rules never both fire on one URL" "1" \
  "$(red "https://ghp_SUPERSECRETTOKEN@github.com/o/r.git" | grep -c REDACTED)"

assert_eq "and the colon form is not then re-masked as a bare one" \
  "https://u:***REDACTED***@h/x.git" \
  "$(red "https://u:pw@h/x.git")"

# --- left alone ---------------------------------------------------------------
# The ssh case stays here on purpose now that bare userinfo is masked for http and
# https: a bare userinfo on ssh:// is a LOGIN NAME, it carries no secret, and
# `ssh://git@host:2222/...` is the form this skill recommends. Masking it would
# delete evidence from every log for no gain. `ssh://user:pass@host` is still
# caught, by the colon rule, which stays scheme-neutral.
for keep in \
  "plain https://git.invalid/private/transport.git" \
  "scp form git@github.com:owner/repo.git" \
  "ssh form ssh://git@host:2222/owner/repo.git" \
  "local path /srv/git/x.git" \
  "port only https://host:8443/x.git" \
  "an address in a path https://api.host/users/foo@bar.com" \
  "prose: connecting to https://host and then user:pass@other thing"
do
  assert_eq "left alone: $keep" "$keep" "$(red "$keep")"
done

# --- the anchoring itself, not just the intent --------------------------------
# Every case above passes against a DELIBERATELY LOOSER pattern - one allowing `/`
# in both character classes - so on its own that list documents the intent without
# guarding it. These do not. With `/` allowed, the colon rule runs past a path
# segment, swallows `host/a` as the "username" and `b/c` as the "password", and
# masks an `@` that belongs to the path. Losing evidence out of a log is the
# expensive mistake here, and caplib.sh's comment says so; this is the assertion
# that holds the comment to it.
#
# To mutation-test: widen both classes in cap_redact's colon rule to
# `[^@[:space:]]` and these two must FAIL while everything above still passes.
assert_eq "the colon rule stops at the first path segment" \
  "https://host/a:b/c@d" \
  "$(red "https://host/a:b/c@d")"

# The same shape as it really arrives: an ISO timestamp puts colons in a path, and
# an `@` in a filename is ordinary.
assert_eq "a colon in a path and an @ in a filename survive together" \
  "GET https://store.invalid/logs/2026-08-17T12:00:00Z/run@42.txt" \
  "$(red "GET https://store.invalid/logs/2026-08-17T12:00:00Z/run@42.txt")"

# The bare rule needs the same guard. "an address in a path" above is one; a
# scoped npm package URL is the other, and it is the shape a step really prints.
# With `/` allowed in the class, the rule swallows the host and everything up to
# the `@` that starts the scope, and the log says
# `https://***REDACTED***@scope/pkg/...` with no host in it at all.
assert_eq "the bare rule stops at the first path segment too" \
  "fetching https://registry.invalid/@scope/pkg/-/pkg-1.0.0.tgz" \
  "$(red "fetching https://registry.invalid/@scope/pkg/-/pkg-1.0.0.tgz")"

# REDACT=0 is the documented escape hatch for when masking hides what you need.
assert_eq "REDACT=0 disables it, as documented" \
  "https://u:tok@h/x.git" \
  "$(REDACT=0 red "https://u:tok@h/x.git")"

t_summary
