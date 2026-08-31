#!/usr/bin/env bash
# =============================================================================
#  test-root-refusal.sh - the account is the blast radius, so it is checked
# =============================================================================
# This toolkit carries no credentials: no cloud auth, no API keys, nothing but
# the git remote. So the only honest answer to "what could a step do to this
# estate" is "whatever the account running it could do" - and that answer is
# only worth anything if the account is not root.
#
# Refused rather than warned about, because a warning in a captured log is read
# after the run, by which time the run has happened.
#
# The refusal is exercised with a fake `id` on PATH rather than by running the
# suite as root. Same code path, no privileged CI.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=assert.sh disable=SC1091
. "$HERE/assert.sh"
ROOT="$(cd "$HERE/.." && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

TR="$TMP/tr"
GIT="git -c user.email=ci@example.invalid -c user.name=ci"
"$ROOT/skills/heliograph/scripts/bootstrap.sh" "$TR" >/dev/null 2>&1
( cd "$TR" && git init -q && $GIT add -A && $GIT commit -qm init ) >/dev/null 2>&1

# A fake `id` that answers 0 to `id -u` and defers to the real one otherwise, so
# nothing else in the run starts behaving oddly.
mkdir -p "$TMP/bin"
real_id="$(command -v id)"
cat > "$TMP/bin/id" <<EOF
#!/bin/sh
[ "\$1" = "-u" ] && { echo 0; exit 0; }
exec "$real_id" "\$@"
EOF
chmod +x "$TMP/bin/id"
as_root() { ( cd "$TR" && PATH="$TMP/bin:$PATH" PUSH=0 "$@" 2>&1 ); }

# --- run.sh -------------------------------------------------------------------
RC=0; OUT="$(as_root ./run.sh env)" || RC=$?
assert_eq "run.sh refuses to run as root" "5" "$RC"
assert_contains "and says why, in terms of blast radius" "blast radius" "$OUT"
assert_contains "and says what to do instead" "unprivileged" "$OUT"
assert_eq "and captured nothing on the way out" "0" \
  "$(ls "$TR"/ops-logs/env-*.txt 2>/dev/null | wc -l)"

RC=0; OUT="$(as_root env ALLOW_ROOT=1 ./run.sh env)" || RC=$?
assert_eq "ALLOW_ROOT=1 is the documented way out, for an image with no other user" "0" "$RC"
assert_eq "and it really ran" "1" "$(ls "$TR"/ops-logs/env-*.txt 2>/dev/null | wc -l)"

# An unknown step must still say it is unknown, whoever is asking: the root
# check sits AFTER validation so a typo does not come back as a lecture about
# privilege.
RC=0; OUT="$(as_root ./run.sh nosuchstep)" || RC=$?
assert_eq "an unknown step is still reported as unknown, even as root" "2" "$RC"

# --- caprun.sh ----------------------------------------------------------------
RC=0; OUT="$(as_root ./caprun.sh label -- echo hello)" || RC=$?
assert_eq "caprun.sh refuses too - it is the same capture, without the step table" "5" "$RC"

# --- agent.sh -----------------------------------------------------------------
# The worst place to discover this is an unattended loop, so the agent checks at
# startup rather than per request: a loop that would refuse everything should
# say so before the operator walks away.
RC=0; OUT="$(as_root ./agent.sh --once --interval 1)" || RC=$?
assert_eq "the agent refuses at startup" "5" "$RC"
assert_contains "and names the override rather than leaving it to be guessed" "ALLOW_ROOT=1" "$OUT"
assert_eq "and leaves no lock behind, so the next run is not blocked by a corpse" "0" \
  "$( [ -e "$TR/.agent.lock" ] && echo 1 || echo 0 )"

t_summary
