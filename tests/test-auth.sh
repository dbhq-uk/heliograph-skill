#!/usr/bin/env bash
# =============================================================================
#  test-auth.sh - what _cap_auth_header does today, pinned
# =============================================================================
# These exist so the refactor in the next task can be shown to change nothing.
# Every case runs under `env -i` in its own directory: _cap_auth_header reads
# both the environment and the cwd (./.git-token), so a developer's real
# GIT_TOKEN would otherwise make these pass or fail by accident.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=assert.sh disable=SC1091
. "$HERE/assert.sh"
TOOLKIT="$(cd "$HERE/../skills/heliograph/toolkit" && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# hdr <workdir> [VAR=VAL ...] - _cap_auth_header in a clean environment
hdr() {
  local wd="$1"; shift
  ( cd "$wd" && env -i HOME="$wd" PATH="$PATH" "$@" \
      bash -c ". \"$TOOLKIT/caplib.sh\"; _cap_auth_header" )
}

basic() { printf 'Authorization: Basic %s' "$(printf '%s:%s' "$1" "$2" | base64 -w0)"; }

mkdir -p "$TMP/empty"
assert_eq "nothing set prints nothing, so git is used unmodified" \
  "" "$(hdr "$TMP/empty")"

assert_eq "GIT_AUTH_HEADER is used verbatim" \
  "Authorization: Bearer abc123" \
  "$(hdr "$TMP/empty" GIT_AUTH_HEADER="Bearer abc123")"

assert_eq "GIT_TOKEN becomes Basic with an empty username, which is what Azure DevOps wants" \
  "$(basic "" tok)" \
  "$(hdr "$TMP/empty" GIT_TOKEN=tok)"

assert_eq "GIT_TOKEN_USER sets the Basic username" \
  "$(basic x-access-token tok)" \
  "$(hdr "$TMP/empty" GIT_TOKEN_USER=x-access-token GIT_TOKEN=tok)"

assert_eq "GIT_AUTH_HEADER beats GIT_TOKEN" \
  "Authorization: Bearer wins" \
  "$(hdr "$TMP/empty" GIT_AUTH_HEADER="Bearer wins" GIT_TOKEN=loses)"

mkdir -p "$TMP/dotfile"
printf 'from-cwd\nsecond line\n' > "$TMP/dotfile/.git-token"
assert_eq "./.git-token is read when no env token is set" \
  "$(basic "" from-cwd)" \
  "$(hdr "$TMP/dotfile")"

assert_eq "GIT_TOKEN beats ./.git-token" \
  "$(basic "" from-env)" \
  "$(hdr "$TMP/dotfile" GIT_TOKEN=from-env)"

printf 'from-named\n' > "$TMP/dotfile/named-token"
assert_eq "GIT_TOKEN_FILE beats ./.git-token" \
  "$(basic "" from-named)" \
  "$(hdr "$TMP/dotfile" GIT_TOKEN_FILE="$TMP/dotfile/named-token")"

mkdir -p "$TMP/homefile"
printf 'from-home\n' > "$TMP/homefile/.git-token"
mkdir -p "$TMP/homefile/work"
# shellcheck disable=SC2088 # this ~ is inside a label string, not a path - never expanded
assert_eq "~/.git-token is the last resort" \
  "$(basic "" from-home)" \
  "$( cd "$TMP/homefile/work" && env -i HOME="$TMP/homefile" PATH="$PATH" \
        bash -c ". \"$TOOLKIT/caplib.sh\"; _cap_auth_header" )"

# Both present and different, which the cases above cannot distinguish because
# hdr() points HOME at the same directory it runs in. This is the link Task 2's
# refactor is most likely to get wrong.
mkdir -p "$TMP/both/work"
printf 'from-home\n' > "$TMP/both/.git-token"
printf 'from-cwd\n'  > "$TMP/both/work/.git-token"
assert_eq "./.git-token beats ~/.git-token when both exist and differ" \
  "$(basic "" from-cwd)" \
  "$( cd "$TMP/both/work" && env -i HOME="$TMP/both" PATH="$PATH" \
        bash -c ". \"$TOOLKIT/caplib.sh\"; _cap_auth_header" )"

mkdir -p "$TMP/emptyfile"
: > "$TMP/emptyfile/.git-token"
assert_eq "an empty token file yields no header rather than an empty Basic value" \
  "" "$(hdr "$TMP/emptyfile")"

# --- the single precedence list, and the report built from it ----------------

src() {
  local wd="$1"; shift
  ( cd "$wd" && env -i HOME="$wd" PATH="$PATH" "$@" \
      bash -c ". \"$TOOLKIT/caplib.sh\"; _cap_token_source" )
}
desc() {
  local wd="$1"; shift
  ( cd "$wd" && env -i HOME="$wd" PATH="$PATH" "$@" \
      bash -c ". \"$TOOLKIT/caplib.sh\"; cap_auth_describe" )
}

assert_eq "source: nothing set" "none" "$(src "$TMP/empty")"
assert_eq "source: GIT_AUTH_HEADER" "header:GIT_AUTH_HEADER" \
  "$(src "$TMP/empty" GIT_AUTH_HEADER="Bearer x")"
assert_eq "source: GIT_TOKEN" "env:GIT_TOKEN" "$(src "$TMP/empty" GIT_TOKEN=tok)"
assert_eq "source: ./.git-token" "file:./.git-token" "$(src "$TMP/dotfile")"
assert_eq "source: GIT_TOKEN_FILE beats ./.git-token" \
  "file:$TMP/dotfile/named-token" \
  "$(src "$TMP/dotfile" GIT_TOKEN_FILE="$TMP/dotfile/named-token")"

# The description names the mechanism and the length. The length is included
# because a token truncated by an ARM template parameter or a stray newline is a
# real failure mode and this settles it; the value is never printed, because this
# output is read aloud, pasted into tickets, and sits above a log that gets
# committed.
# Deliberately NOT "the SSH case". cap_auth_describe cannot see the remote, so it
# names what it looked for and leaves the conclusion to the caller: it used to
# assert "correct for an SSH remote", which on an https remote with no token put an
# `ok` claiming the credential was right directly above a FAIL telling the reader
# to check the credential. start.sh knows the scheme and adds the advice.
assert_contains "describe: no credential names what was looked for, without opining on the scheme" \
  "none: no readable GIT_AUTH_HEADER, GIT_TOKEN, GIT_TOKEN_FILE or .git-token" \
  "$(desc "$TMP/empty")"
assert_eq "describe: and does not claim a scheme it cannot see" "" \
  "$(desc "$TMP/empty" | grep -o 'SSH remote')"
assert_contains "describe: names GIT_TOKEN" \
  "GIT_TOKEN" "$(desc "$TMP/empty" GIT_TOKEN=abcd)"
assert_contains "describe: reports the length" \
  "4 chars" "$(desc "$TMP/empty" GIT_TOKEN=abcd)"
assert_eq "describe: never prints the token itself" \
  "" "$(desc "$TMP/empty" GIT_TOKEN=sup3rs3cr3t | grep -o sup3rs3cr3t)"
assert_contains "describe: names the file it read" \
  ".git-token" "$(desc "$TMP/dotfile")"

# --- fix: a trailing newline in a GIT_TOKEN_FILE path must survive -----------
# Regression test for a review finding: a bare $(_cap_token_source) lets command
# substitution strip a trailing newline that is part of the file's own name,
# silently turning a valid file: source into no header at all - a push that
# should be authenticated goes out bare instead.
#
# (A direct check of _cap_token_source's raw stdout can't observe this: the
# test's own "$(...)" capture strips a trailing newline exactly the way the
# bug did, so it would pass whether or not the fix is in place. The end-to-end
# check below is the one that actually distinguishes fixed from broken - the
# broken form builds the wrong path, sed can't find it, and the header comes
# back empty instead of Basic.)
mkdir -p "$TMP/trailingnl"
nlfile="$TMP/trailingnl/token"$'\n'
printf 'from-nl-path\n' > "$nlfile"
assert_eq "GIT_TOKEN_FILE with a trailing newline in its name still authenticates" \
  "$(basic "" from-nl-path)" \
  "$(hdr "$TMP/empty" GIT_TOKEN_FILE="$nlfile")"

# --- fix: describe must not claim a header that _cap_auth_header will not send
# Regression test for a review finding: the two functions agree on WHICH
# mechanism is selected but, before this fix, not on whether a header is
# actually emitted. An empty first line makes _cap_auth_header send nothing;
# describe must say so rather than reporting "(0 chars)", which reads as "the
# token is in force" to an operator staring at a failed push.
assert_contains "describe: empty token file says no header is sent, not a fake length" \
  "no header is sent" "$(desc "$TMP/emptyfile")"
assert_eq "describe: empty token file never claims a (0 chars) token is in force" \
  "" "$(desc "$TMP/emptyfile" | grep -o '(0 chars)')"

# --- fix: a GIT_TOKEN_FILE pointing at a DIRECTORY must print no sed noise ------
# GIT_TOKEN_FILE=/run/secrets - the mounted secrets DIRECTORY rather than a file
# inside it - is the realistic mistake once this runs in a container. sed was
# unsilenced, so "sed: read error on /run/secrets: Is a directory" landed in the
# middle of the preflight table, which then explained it as an empty first line.
mkdir -p "$TMP/secretsdir"
both() {  # both <workdir> [VAR=VAL ...] - cap_auth_describe, stdout AND stderr
  local wd="$1"; shift
  ( cd "$wd" && env -i HOME="$wd" PATH="$PATH" "$@" \
      bash -c ". \"$TOOLKIT/caplib.sh\"; cap_auth_describe" 2>&1 )
}
assert_eq "a directory as GIT_TOKEN_FILE prints no sed noise" "" \
  "$(both "$TMP/empty" GIT_TOKEN_FILE="$TMP/secretsdir" | grep -o 'read error')"
assert_contains "and the wording covers unreadable as well as empty" \
  "is unreadable or its first line is empty, so no header is sent" \
  "$(both "$TMP/empty" GIT_TOKEN_FILE="$TMP/secretsdir")"
# --- fix: the enumeration must not deny a variable the operator did set ---------
# _cap_token_source gates the file candidates on [ -r ], so a GIT_TOKEN_FILE that
# exists but cannot be READ - a root-owned mounted secret seen by a non-root
# container process, the realistic case in PRs 3 and 4 - is skipped and falls
# through to the "none" branch. "no GIT_TOKEN_FILE" there flatly denies a variable
# that is set, and sends the operator looking for something they already provided.
# One word closes it without duplicating the precedence list.
#
# Skipped under root, where mode 000 is still readable and the state cannot be
# built. That is not hypothetical: PR 3's container runs as root, so someone will
# run this suite there.
printf 'a-real-token\n' > "$TMP/unreadable"
chmod 000 "$TMP/unreadable"
if [ "$(id -u)" != "0" ]; then
  assert_contains "an unreadable GIT_TOKEN_FILE does not get flatly denied" \
    "no readable GIT_AUTH_HEADER, GIT_TOKEN, GIT_TOKEN_FILE or .git-token" \
    "$(desc "$TMP/empty" GIT_TOKEN_FILE="$TMP/unreadable")"
  assert_eq "and its contents are still never printed" "" \
    "$(both "$TMP/empty" GIT_TOKEN_FILE="$TMP/unreadable" | grep -o a-real-token)"
else
  printf 'skip unreadable GIT_TOKEN_FILE: running as root, where mode 000 is still readable\n'
fi
chmod 644 "$TMP/unreadable"

assert_eq "_cap_auth_header sends no header for it, and prints no noise either" "" \
  "$( cd "$TMP/empty" && env -i HOME="$TMP/empty" PATH="$PATH" \
        GIT_TOKEN_FILE="$TMP/secretsdir" \
        bash -c ". \"$TOOLKIT/caplib.sh\"; _cap_auth_header" 2>&1 )"

t_summary
