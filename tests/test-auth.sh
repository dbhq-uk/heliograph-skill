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

t_summary
