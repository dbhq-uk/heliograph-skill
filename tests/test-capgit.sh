#!/usr/bin/env bash
# =============================================================================
#  test-capgit.sh - the token must not reach git's command line
# =============================================================================
# /proc/<pid>/cmdline is world readable (mode 444) and /proc/<pid>/environ is
# not (400), so a credential passed with `git -c` is readable by any other user
# on the control node via ps. These tests pin the mechanism that avoids that,
# and the fallback for a git too old to support it.
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
fake_git() {
  mkdir -p "$1"
  cat > "$1/git" <<EOF
#!/bin/sh
if [ "\$1" = "--version" ]; then echo "git version $2"; exit 0; fi
echo "ARGV: \$*"
echo "COUNT: \${GIT_CONFIG_COUNT:-unset}"
echo "KEY: \${GIT_CONFIG_KEY_0:-unset}"
echo "VALUE: \${GIT_CONFIG_VALUE_0:-unset}"
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
assert_contains "modern git: argv still carries the real git command" \
  "ls-remote origin" "$(printf '%s\n' "$out" | sed -n 's/^ARGV: //p')"
assert_eq "modern git: GIT_CONFIG_COUNT is set to 1" \
  "1" "$(printf '%s\n' "$out" | sed -n 's/^COUNT: //p')"
assert_eq "modern git: the key is http.extraHeader" \
  "http.extraHeader" "$(printf '%s\n' "$out" | sed -n 's/^KEY: //p')"
assert_eq "modern git: the header travels in the environment" \
  "$EXPECTED_HDR" "$(printf '%s\n' "$out" | sed -n 's/^VALUE: //p')"

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

t_summary
