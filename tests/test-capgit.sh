#!/usr/bin/env bash
# =============================================================================
#  test-capgit.sh - the token must not reach git's command line
# =============================================================================
# /proc/<pid>/cmdline is world readable (mode 444) and /proc/<pid>/environ is
# not (400), so a credential passed with `git -c` is readable by any other user
# on the control node via ps. These tests pin the mechanism that avoids that,
# the fallback for a git too old to support it, that an ambient GIT_CONFIG_*
# the operator already set is composed with rather than overwritten, and the
# version gate's behaviour at its edges.
#
# A fake git on PATH reports how it was invoked. That is the only way to assert
# this property: nothing about the resulting header is observable otherwise.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=assert.sh disable=SC1091
. "$HERE/assert.sh"
TOOLKIT="$(cd "$HERE/../skills/heliograph/toolkit" && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# fake_git <dir> <version> - a git that prints its argv and the config env vars
# it received: COUNT + KEY_0/VALUE_0 (used by every test below) and KEY_1/VALUE_1
# (used only by the ambient-config test, which appends at index 1). Static
# indices, not a loop over GIT_CONFIG_COUNT: a loop would need `eval` to build
# variable names dynamically inside this generated /bin/sh script, and getting
# that indirection through this heredoc's own escaping correctly is a second
# source of bugs this test does not need to take on.
fake_git() {
  mkdir -p "$1"
  cat > "$1/git" <<EOF
#!/bin/sh
if [ "\$1" = "--version" ]; then echo "git version $2"; exit 0; fi
echo "ARGV: \$*"
echo "COUNT: \${GIT_CONFIG_COUNT:-unset}"
echo "KEY_0: \${GIT_CONFIG_KEY_0:-unset}"
echo "VALUE_0: \${GIT_CONFIG_VALUE_0:-unset}"
echo "KEY_1: \${GIT_CONFIG_KEY_1:-unset}"
echo "VALUE_1: \${GIT_CONFIG_VALUE_1:-unset}"
EOF
  chmod +x "$1/git"
}

run_cap_git() {  # run_cap_git <fakebindir> [VAR=VAL ...]
  local bin="$1"; shift
  ( cd "$TMP" && env -i HOME="$TMP" PATH="$bin:$PATH" "$@" \
      bash -c ". \"$TOOLKIT/caplib.sh\"; cap_git ls-remote origin" )
}

TOKEN=s3cr3t-token-value
EXPECTED_HDR="Authorization: Basic $(printf ':%s' "$TOKEN" | base64 -w0)"

# --- a modern git: the header travels in the environment ----------------------
fake_git "$TMP/new" 2.43.0
out="$(run_cap_git "$TMP/new" GIT_TOKEN="$TOKEN")"

assert_eq "modern git: the token is NOT in argv" \
  "" "$(printf '%s\n' "$out" | sed -n 's/^ARGV: //p' | grep -o "$TOKEN")"
# The property this whole task exists to guard is "no auth header reaches argv
# AT ALL", not just "the raw token substring is absent" - base64(":$TOKEN")
# never contains the plaintext token even when `-c http.extraHeader=...` is
# used, so the assertion above alone would still pass under a cap_git that sets
# the env route AND leaves the old `-c` in place. Assert on the marker that
# WOULD be in argv under that regression instead.
assert_eq "modern git: no -c http.extraHeader reaches argv either" \
  "" "$(printf '%s\n' "$out" | sed -n 's/^ARGV: //p' | grep -o 'extraHeader')"
assert_contains "modern git: argv still carries the real git command" \
  "ls-remote origin" "$(printf '%s\n' "$out" | sed -n 's/^ARGV: //p')"
assert_eq "modern git: GIT_CONFIG_COUNT is set to 1" \
  "1" "$(printf '%s\n' "$out" | sed -n 's/^COUNT: //p')"
assert_eq "modern git: the key is http.extraHeader" \
  "http.extraHeader" "$(printf '%s\n' "$out" | sed -n 's/^KEY_0: //p')"
assert_eq "modern git: the header travels in the environment" \
  "$EXPECTED_HDR" "$(printf '%s\n' "$out" | sed -n 's/^VALUE_0: //p')"

# --- an old git: fall back to -c rather than send an unauthenticated request --
# git below 2.31 ignores GIT_CONFIG_COUNT silently. Silently is the problem:
# the push would go out with no credential and fail as an auth error.
fake_git "$TMP/old" 2.30.2
out="$(run_cap_git "$TMP/old" GIT_TOKEN="$TOKEN")"

assert_contains "old git: falls back to -c http.extraHeader" \
  "-c http.extraHeader=$EXPECTED_HDR" "$(printf '%s\n' "$out" | sed -n 's/^ARGV: //p')"
assert_eq "old git: the environment is not used" \
  "unset" "$(printf '%s\n' "$out" | sed -n 's/^COUNT: //p')"

# --- no credential configured: git is used completely unmodified --------------
fake_git "$TMP/plain" 2.43.0
out="$(run_cap_git "$TMP/plain")"
assert_eq "no credential: argv is just the git command" \
  "ls-remote origin" "$(printf '%s\n' "$out" | sed -n 's/^ARGV: //p')"
assert_eq "no credential: no config env var is set" \
  "unset" "$(printf '%s\n' "$out" | sed -n 's/^COUNT: //p')"

# --- an ambient GIT_CONFIG_* survives: append, don't overwrite ----------------
# An operator on a locked-down control node may already export their own
# GIT_CONFIG_COUNT/KEY_0/VALUE_0 this same way (an ambient http.proxy,
# sslCAInfo, safe.directory). cap_git must add its own entry at the next free
# index rather than hard-coding slot 0 - overwriting slot 0 would silently
# truncate the operator's config off the list, and every authenticated push
# would start failing with a network error on a machine nobody can log into to
# diagnose it.
fake_git "$TMP/ambient" 2.43.0
out="$(run_cap_git "$TMP/ambient" GIT_TOKEN="$TOKEN" \
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.proxy GIT_CONFIG_VALUE_0=http://corp:3128)"

assert_eq "ambient config: COUNT becomes 2, not reset to 1" \
  "2" "$(printf '%s\n' "$out" | sed -n 's/^COUNT: //p')"
assert_eq "ambient config: the operator's own key survives at slot 0" \
  "http.proxy" "$(printf '%s\n' "$out" | sed -n 's/^KEY_0: //p')"
assert_eq "ambient config: and its value survives too" \
  "http://corp:3128" "$(printf '%s\n' "$out" | sed -n 's/^VALUE_0: //p')"
assert_eq "ambient config: ours is appended at slot 1" \
  "http.extraHeader" "$(printf '%s\n' "$out" | sed -n 's/^KEY_1: //p')"
assert_eq "ambient config: with the real header value" \
  "$EXPECTED_HDR" "$(printf '%s\n' "$out" | sed -n 's/^VALUE_1: //p')"

# --- version gate, pinned at its edges -----------------------------------------
# git 2.9.5 matters most here: it pins a NUMERIC comparison. A future refactor
# to something like `[[ "$v" > "2.31" ]]` would compare as strings, under which
# "2.9" sorts ABOVE "2.31" (9 > 3 lexically) and this case would wrongly take
# the environment route on a git that silently ignores it - sending an
# unauthenticated request that fails as a bare auth error. This test would
# catch that refactor breaking loudly, in CI, rather than on a control node.
fake_git "$TMP/v295" 2.9.5
out="$(run_cap_git "$TMP/v295" GIT_TOKEN="$TOKEN")"
assert_eq "2.9.5: below 2.31, the environment is not used" \
  "unset" "$(printf '%s\n' "$out" | sed -n 's/^COUNT: //p')"
assert_contains "2.9.5: falls back to -c http.extraHeader" \
  "-c http.extraHeader=$EXPECTED_HDR" "$(printf '%s\n' "$out" | sed -n 's/^ARGV: //p')"

fake_git "$TMP/v2310" 2.31.0
out="$(run_cap_git "$TMP/v2310" GIT_TOKEN="$TOKEN")"
assert_eq "2.31.0 exactly: the environment route is used" \
  "1" "$(printf '%s\n' "$out" | sed -n 's/^COUNT: //p')"

fake_git "$TMP/vapple" "2.39.5 (Apple Git-154)"
out="$(run_cap_git "$TMP/vapple" GIT_TOKEN="$TOKEN")"
assert_eq "2.39.5 (Apple Git-154): the environment route is used" \
  "1" "$(printf '%s\n' "$out" | sed -n 's/^COUNT: //p')"

t_summary
