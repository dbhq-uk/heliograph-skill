#!/usr/bin/env bash
# =============================================================================
#  test-container.sh - the properties the image has to guarantee
# =============================================================================
# Everything PR 3 ships, in one file, in the order it was built:
#   1. THE IMAGE itself - what start.sh's own preflight would find on this
#      machine before it ever gets a chance to clone anything.
#   2. THE ENTRYPOINT - clone, refuse what must be refused, hand over to the
#      cloned repo's own start.sh.
#   3. heliograph.sh - the wrapper that turns a `docker run` into one line,
#      including the shapes in which it must NOT throw a captured log away.
# The sections are labelled below; each states what it is responsible for and,
# just as importantly, what it deliberately leaves to the section or the test
# file that already owns it.
#
# Every value asserted below is READ BACK FROM A RUNNING CONTAINER. None of it
# is a fixture this file already knows the answer to: that "echoes its own
# input back" shape is the recurring defect named in this PR's plan, and the
# only defence against writing it by accident is to make the container itself
# do the comparison (bash's own `if`, not this file's) wherever that is
# possible, and to read the container's own stdout everywhere else.
#
# Built ONCE for the whole file. A per-assertion build would make this suite
# unusable within minutes and buys nothing: nothing here depends on a fresh
# image between assertions.
#
# --- the skip -----------------------------------------------------------------
# A container runtime is not guaranteed on the machine running this suite.
# Docker Desktop is not always installed, a CI runner's daemon can be down, a
# sandboxed dev box may have no runtime at all. Silently skipping in that case
# would let a scrollback read as though every property below was checked, when
# none of them were - the exact defect shape PR 2 refused to allow for a
# skipped checksum. So: no runtime means this file says so loudly, on stdout,
# and still exits 0 so the rest of ./tests/run-tests.sh keeps going. It does
# NOT call t_summary in that case. "test-container.sh: 0 passed, 0 failed"
# reads exactly like a trivially clean run to anyone scanning summary lines,
# which is the one thing a loud skip must never look like. Task 4 makes CI run
# these unskipped; that is not this file's job to enforce, only not to make
# impossible.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
DOCKERFILE="$ROOT/skills/heliograph/toolkit/docker/Dockerfile"
DOCKER_DIR="$(dirname "$DOCKERFILE")"
IMAGE="heliograph-toolkit-test:local"

# HOST_UID - measured, never assumed, and used to build $IMAGE below. Every
# "happy path" fixture past this point bind-mounts a directory this SCRIPT
# creates (owned by whoever is running it) into a container running as
# $IMAGE's own user. Building $IMAGE at the Dockerfile's bare default
# (HELIOGRAPH_UID=1000) only matched that on a machine whose own uid happens
# to be 1000, and this repo's development machine's uid IS 1000 - a
# coincidence, not a property. GitHub Actions' runner user is uid 1001, so
# every one of those fixtures hit the same dubious-ownership refusal
# (CVE-2022-24765) entrypoint.sh is deliberately supposed to raise for a
# GENUINE mismatch, and the whole "clone + handover succeeds" shape of
# assertion failed there - not because the product is wrong (it is not;
# that refusal is the fix for an earlier Critical, and stays), but because
# these fixtures never matched this script's own uid to the image's. This is
# exactly the pattern --ssh already uses for the identical reason (see
# heliograph.sh's own SSH FORWARDING comment): build the image AT the uid
# that is actually going to own the bind-mounted files, rather than assume a
# fixed number. It does NOT touch the DELIBERATE mismatch fixtures further
# down this file (MISMATCH_TAG, BAD_TAG) - those build at an arbitrary,
# unrelated uid on purpose, to construct the very refusal this script's own
# uid must never accidentally trigger nor accidentally suppress.
HOST_UID="$(id -u)"

RUNTIME=""
for candidate in docker podman; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" info >/dev/null 2>&1; then
    RUNTIME="$candidate"
    break
  fi
done

if [ -z "$RUNTIME" ]; then
  cat <<'EOF'
SKIP  test-container.sh: no container runtime is reachable on this machine
      (checked: docker, podman - neither is on PATH with a daemon that
      answers `info`). NONE of the image's properties were checked by this
      run: not bash's version, not sed -u, not base64 -w0, not the presence
      of sha256sum/date/git/setsid, not the unprivileged user, not
      passwordless sudo, not the writable working directory. This is a SKIP,
      not a pass - rerun on a machine with a container runtime, or see this
      run in CI, where task 4 does not allow this file to skip.
EOF
  exit 0
fi

# shellcheck source=assert.sh disable=SC1091
. "$HERE/assert.sh"

# --- build once ----------------------------------------------------------------
# --build-arg HELIOGRAPH_UID=$HOST_UID: see HOST_UID's own comment above. This
# is the one build every "happy path" fixture below reuses, so building it at
# this script's own uid is what makes every bind-mounted fixture's ownership
# match the container's user, on ANY host, rather than only on one whose uid
# happens to already be 1000.
echo "building $IMAGE from $DOCKERFILE with $RUNTIME (HELIOGRAPH_UID=$HOST_UID) ..."
BUILD_OUT="$("$RUNTIME" build -f "$DOCKERFILE" -t "$IMAGE" --build-arg "HELIOGRAPH_UID=$HOST_UID" "$DOCKER_DIR" 2>&1)"
BUILD_RC=$?
if [ "$BUILD_RC" -ne 0 ]; then
  printf '%s\n' "$BUILD_OUT"
  t_no "the image builds from $DOCKERFILE"
  t_summary
  exit $?
fi
t_ok "the image builds from $DOCKERFILE"

# run_in <cmd> [args...] - runs in a fresh, disposable container, STDOUT only.
# A fresh container per call rather than one long-lived one: nothing here
# needs state to survive between assertions, and a fresh container is the only
# way to be sure one assertion's command cannot leave something behind that
# makes a later assertion pass for the wrong reason.
#
# --entrypoint overrides task 2's ENTRYPOINT, added below this point in the
# file. Without it, `docker run $IMAGE bash -c '...'` would hand "bash" to
# entrypoint.sh as a repository URL rather than running it directly - these
# assertions are about the image's raw properties, not about the clone-and-
# handover contract, so they need the plain command, not the entrypoint.
run_in() {
  local cmd="$1"; shift
  "$RUNTIME" run --rm --entrypoint "$cmd" "$IMAGE" "$@"
}

# --- the image's own user genuinely runs at THIS SCRIPT's own uid --------------
# The regression this guards against: a future edit that drops
# --build-arg HELIOGRAPH_UID=$HOST_UID above, or hardcodes some other number
# in its place. That regression shipped once already, and it is INVISIBLE on
# a development machine whose own uid happens to be 1000 - the Dockerfile's
# bare default - which is exactly this repo's dev machine and exactly why it
# went uncaught here and only failed in CI (runner uid 1001). Comparing the
# CONTAINER's own measured uid against THIS SCRIPT's own measured uid - never
# a literal number on either side - is what makes the guard fail on ANY host
# where they diverge, including this one, rather than only on a host that
# happens not to be 1000.
out="$(run_in id -u)"
assert_eq "the image's own user runs at this host's own uid, not a hardcoded one" "$HOST_UID" "$out"

# --- bash is 4 or newer --------------------------------------------------------
# The comparison runs INSIDE the container, against that container's own
# BASH_VERSINFO, and only the resulting word crosses back out. Asserting on a
# version STRING captured from --version would tie this to whatever bookworm
# happens to ship today; asserting on the property is what start.sh itself
# checks, and it is what actually matters.
out="$(run_in bash -c 'if [ "${BASH_VERSINFO[0]}" -ge 4 ]; then echo yes; else echo no; fi')"
assert_eq "bash is version 4 or newer" "yes" "$out"

# --- sed -u is honoured ---------------------------------------------------------
# Lifted directly from start.sh's own preflight (the "THE load-bearing check"
# comment there): a busybox sed rejects -u outright, so this fails loudly
# rather than the silent-buffering failure mode start.sh's comment warns
# about.
out="$(run_in bash -c "printf 'x\\n' | sed -u 's/x/y/' 2>/dev/null")"
assert_eq "sed -u is honoured" "y" "$out"

# --- base64 -w0 produces unwrapped output ---------------------------------------
# start.sh's own check only proves the FLAG is accepted (a 1-byte input can
# never wrap regardless). That is not the same property as "output stays
# unwrapped", so this feeds base64 something well past the 76-column MIME
# default and asserts there is no embedded newline in what comes back - the
# property cap_git's HTTPS auth header actually depends on.
out="$(run_in bash -c "printf '%080d' 1 | base64 -w0 | wc -l")"
assert_eq "base64 -w0 output has no embedded newline" "0" "$out"

# --- sha256sum, git, setsid and ssh are all present ------------------------------
# start.sh treats a missing sha256sum and setsid as warnings, not failures -
# but this image's job is to not make an operator read either warning, so
# presence is asserted here regardless of what start.sh would tolerate.
#
# ssh is here because references/transport.md's stated preference is SSH
# with a forwarded agent key, over an HTTPS token, which it treats as the
# fallback. An image with no ssh binary at all would make that preferred
# path impossible rather than merely unconfigured, so presence is a
# guarantee of this image, not just a nice-to-have.
for tool in sha256sum git setsid ssh; do
  out="$(run_in bash -c "command -v $tool >/dev/null 2>&1 && echo present || echo absent")"
  assert_eq "$tool is present" "present" "$out"
done

# --- date -u produces a real UTC stamp ------------------------------------------
# start.sh only checks the command exits 0. This goes one step further and
# shape-checks what came back, so a `date` that accepts -u but mangles the
# format cannot pass here by accident.
out="$(run_in date -u +%Y-%m-%dT%H:%M:%SZ)"
case "$out" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z)
    t_ok "date -u produces a UTC stamp in the expected shape" ;;
  *)
    t_no "date -u produces a UTC stamp in the expected shape"
    printf '     got: [%s]\n' "$out" ;;
esac

# --- the default user is not root -----------------------------------------------
out="$(run_in bash -c 'if [ "$(whoami)" != root ]; then echo ok; else echo root; fi')"
assert_eq "the container does not run as root by default" "ok" "$out"

# --- sudo -n true succeeds for that user ----------------------------------------
out="$(run_in bash -c 'sudo -n true 2>/dev/null && echo ok || echo fail')"
assert_eq "sudo -n true succeeds for the default user" "ok" "$out"

# --- the working directory is writable by that user ------------------------------
# This is where task 2's entrypoint will clone the transport repo into, so
# "exists and is writable" is the property that matters, not any particular
# path.
out="$(run_in bash -c 'test -w "$(pwd)" && echo ok || echo fail')"
assert_eq "the working directory is writable by the default user" "ok" "$out"

# =============================================================================
#  PR 3 task 2 - the entrypoint: clone, then hand over to start.sh
# =============================================================================
# The contract: given a repo URL and a credential, the entrypoint clones,
# cds in, and execs the cloned repo's OWN start.sh. Everything past the clone
# (the preflight, the credential table, the branch checkout, the handover to
# agent.sh) is start.sh's job, proved here by PASSING THROUGH to it and
# reading ITS output, never by re-asserting what test-start.sh already
# covers directly.
#
# Three fixtures, host-side, addressed from inside the container by
# bind-mounting them and using a file:// URL - no network dependency, and the
# same local-bare-repo technique test-start.sh already uses for the same
# reason.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
GIT="git -c user.email=ci@example.com -c user.name=ci"

# make_transport_repo <bare-path> - a bare repo whose default branch carries
# the REAL bootstrapped toolkit, so a container that clones it runs
# start.sh's real preflight for real, not a stand-in for it.
make_transport_repo() {
  local bare="$1" work="$1.work"
  "$ROOT/skills/heliograph/scripts/bootstrap.sh" "$work" >/dev/null 2>&1
  git init -q --bare "$bare"
  ( cd "$work" && git init -q && git remote add origin "$bare" \
      && $GIT add -A && $GIT commit -qm init && $GIT push -q -u origin HEAD ) >/dev/null 2>&1
}

# make_stub_repo <bare-path> <start.sh body> - a bare repo whose start.sh is
# a stub that reports its own pid and argv. Used only to pin the exec/
# passthrough mechanics in isolation from the real preflight, the same
# separation test-start.sh's own "the handover" block draws with its stub
# agent.sh.
make_stub_repo() {
  local bare="$1" work="$1.work" body="$2"
  mkdir -p "$work"
  printf '%s\n' "$body" > "$work/start.sh"
  chmod +x "$work/start.sh"
  git init -q --bare "$bare"
  ( cd "$work" && git init -q && git remote add origin "$bare" \
      && $GIT add -A && $GIT commit -qm init && $GIT push -q -u origin HEAD ) >/dev/null 2>&1
}

# run_entry [docker args...] - runs the image's real entrypoint, combined
# output, bounded so a defect that hangs (rather than fails) cannot wedge the
# whole suite. Sets RC/OUT.
run_entry() {
  RC=0
  OUT="$(timeout 30 "$RUNTIME" run --rm "$@" 2>&1)" || RC=$?
}

TOKEN="heliograph-fixture-token-9f2c8a"
EXPECTED_HDR_B64="$(printf ':%s' "$TOKEN" | base64 -w0)"

# --- no URL given --------------------------------------------------------------
run_entry "$IMAGE"
assert_eq "no URL at all is a usage error, not a hang" "2" "$RC"
assert_contains "and it names the problem" "no repository URL" "$OUT"

# --- a credential embedded in the URL is refused, not cloned -------------------
# This is the leak the whole design exists to avoid: the URL becomes an
# argument to git clone, and /proc/<pid>/cmdline is world-readable. Refused
# before any clone is attempted, rather than masked-and-allowed.
run_entry "$IMAGE" "https://ci-user:$TOKEN@example.invalid/x.git"
assert_eq "a credentialed URL is refused rather than cloned" "2" "$RC"
assert_contains "and it names the reason" "embeds a credential" "$OUT"
assert_eq "the token itself is never printed" "" "$(printf '%s' "$OUT" | grep -o "$TOKEN")"
assert_contains "and it names the fix" "GIT_TOKEN" "$OUT"
# PR 3 whole-PR review, Finding 2. The refusal used to reason only about
# /proc/<pid>/cmdline INSIDE this container - the LAST place that string went.
# By the time it fires the same URL has already been in the host's process
# table (docker run's own argv) and in `docker inspect` .Config.Cmd, neither of
# which anything in here can withdraw, so "pass the credential separately" on
# its own tells an operator to keep using a token that is already exposed.
assert_contains "and it says the credential is already spent, not merely mis-passed" \
  "ROTATE THAT CREDENTIAL" "$OUT"
assert_contains "naming where it has already gone that this container cannot reach" \
  ".Config.Cmd" "$OUT"

# Confirm by hand that the fixture token really WOULD end up in .git/config if
# this refusal did not exist - the same mechanism a real `git clone
# <credentialed-url>` uses to write remote.origin.url. Host git, not the
# container: this is a property of git itself (it stores whatever URL string
# it was given, verbatim), which is exactly why the refusal above exists
# rather than relying on git to redact it.
rm -rf "$TMP/leakcheck" "$TMP/leakcheck.git"
git init -q --bare "$TMP/leakcheck.git"
git clone -q "file://ci-user:$TOKEN@$TMP/leakcheck.git" "$TMP/leakcheck" >/dev/null 2>&1
assert_contains "confirmed by hand: an embedded credential DOES reach .git/config unprotected" \
  "$TOKEN" "$(cat "$TMP/leakcheck/.git/config" 2>/dev/null)"

# --- REPO_URL and a positional argument together is refused --------------------
# This used to let REPO_URL win and treat the positional argument as opaque
# passthrough to start.sh, so it was NEVER checked by url_has_credential
# above. `docker run -e REPO_URL=<real url> image <credentialed url>` cloned
# the real url and handed the credentialed one to start.sh untouched, whose
# own arg parser echoes an unrecognised option verbatim - the token reaching
# stdout in full. Refusing outright, before either value is used, closes it.
#
# REPO_URL points at a REAL, clonable bare repo here - deliberately, not a
# nonexistent path. A bogus REPO_URL would make the clone itself fail first,
# so the credentialed positional argument would never even reach the
# passthrough this finding is about, and "the token never reaches output"
# would pass for the wrong reason (the clone failing) rather than the right
# one (the ambiguity being refused before any clone is attempted). Confirmed
# by mutation: with a bogus REPO_URL, bypassing the refusal still left that
# assertion green; with a real one, it goes red exactly as expected.
make_transport_repo "$TMP/repourl-ambiguity.git"
run_entry -e "REPO_URL=file:///srv/repo.git" -v "$TMP/repourl-ambiguity.git:/srv/repo.git" \
  "$IMAGE" "https://ci-user:$TOKEN@example.invalid/x.git"
assert_eq "REPO_URL plus a positional argument is refused rather than one silently winning" \
  "2" "$RC"
assert_contains "and it names the ambiguity" "both REPO_URL and a command-line argument" "$OUT"
assert_eq "the credential in the ignored positional argument never reaches output either" "" \
  "$(printf '%s' "$OUT" | grep -o "$TOKEN")"

# --- a URL it cannot reach ------------------------------------------------------
run_entry "$IMAGE" "https://example.invalid/nope.git"
assert_eq "an unreachable URL fails rather than hanging" "1" "$RC"
assert_contains "and it names the problem" "git clone failed" "$OUT"

# --- GIT_TOKEN never reaches the container's own output -------------------------
run_entry -e "GIT_TOKEN=$TOKEN" "$IMAGE" "https://example.invalid/nope.git"
assert_eq "GIT_TOKEN is never printed, even while cloning fails" "" \
  "$(printf '%s' "$OUT" | grep -o "$TOKEN")"
assert_contains "the MECHANISM is still named, per cap_auth_describe's own discipline" \
  "GIT_TOKEN from the environment" "$OUT"
assert_contains "and its length, not its value" "(${#TOKEN} chars)" "$OUT"

# --- an unreadable GIT_TOKEN_FILE is named, not denied as "none" ---------------
# Root-owned, mode 0400 is exactly how Docker and Kubernetes hand a secret
# mount to a non-root process - the very shape this file's own usage text
# recommends for keeping a token out of `docker inspect`. Reporting that as
# a flat "none" denies a variable the operator did set, and on an https
# remote the clone fails outright before start.sh/cap_auth_describe ever
# gets a chance to name it more precisely a few seconds later - so this has
# to be right here, not merely eventually. Skipped under root, where mode
# 000 is still readable and the state cannot be built (test-start.sh's own
# equivalent test skips for the same reason).
if [ "$(id -u)" != "0" ]; then
  printf '%s\n' "$TOKEN" > "$TMP/unreadable-token"
  chmod 000 "$TMP/unreadable-token"
  run_entry -e GIT_TOKEN_FILE=/run/secrets/git-token \
    -v "$TMP/unreadable-token:/run/secrets/git-token:ro" \
    "$IMAGE" "https://example.invalid/x.git"
  assert_eq "an unreadable token file's contents are still never printed" "" \
    "$(printf '%s' "$OUT" | grep -o "$TOKEN")"
  assert_contains "and it names the path and the permissions problem" \
    "/run/secrets/git-token exists but is not readable" "$OUT"
  assert_eq "rather than flatly denying a variable the operator did set" "" \
    "$(printf '%s' "$OUT" | grep -o 'credential: none')"
  chmod 644 "$TMP/unreadable-token"
else
  t_skip 'the unreadable GIT_TOKEN_FILE test: running as root, where mode 000 is still readable'
fi

# --- a GIT_TOKEN_FILE that is readable but yields nothing ----------------------
# PR 3 whole-PR review, Finding 4. `[ -r ]` is TRUE for a directory, and
# GIT_TOKEN_FILE=/run/secrets - the secrets mount point rather than the file
# inside it - is the mistake an operator actually makes. sed then reads
# nothing, entrypoint_auth_header sends no header, the clone goes out
# unauthenticated, and the one line printed about the credential used to say
# "<path> (0 chars)": the token reported as in force at the moment git is
# running with none. caplib.sh's cap_auth_describe documents having fixed
# exactly this and prints "unreadable or its first line is empty, so no header
# is sent"; the entrypoint claims the same precedence, so it has to agree.
# No root needed and nothing to skip: a directory is readable by anyone.
mkdir -p "$TMP/secretsdir"
printf '%s\n' "$TOKEN" > "$TMP/secretsdir/git-token"
run_entry -e GIT_TOKEN_FILE=/run/secrets \
  -v "$TMP/secretsdir:/run/secrets:ro" \
  "$IMAGE" "https://example.invalid/x.git"
assert_contains "a GIT_TOKEN_FILE naming a directory reports that no header is sent" \
  "/run/secrets is unreadable or its first line is empty, so no header is sent" "$OUT"
assert_eq "never as '(0 chars)', which would claim a token is in force when none is" "" \
  "$(printf '%s' "$OUT" | grep -o '(0 chars)')"
assert_eq "and nothing from the file inside that directory is printed either" "" \
  "$(printf '%s' "$OUT" | grep -o "$TOKEN")"

# --- the happy path: clone, then genuinely hand over to start.sh ---------------
make_transport_repo "$TMP/happy.git"
run_entry -v "$TMP/happy.git:/srv/repo.git" "$IMAGE" "file:///srv/repo.git" --check
assert_eq "clone + handover to a real start.sh --check succeeds" "0" "$RC"
assert_contains "start.sh's own preflight really ran" "preflight: clear" "$OUT"
assert_contains "and its own git read/write checks ran" "git write" "$OUT"

# --- a branch that does not exist: start.sh's own message, not a copy ----------
# --check exits before the branch checkout runs (see start.sh), so this omits
# it deliberately - the checkout has to be reached for its failure to fire.
make_transport_repo "$TMP/branchfail.git"
run_entry -v "$TMP/branchfail.git:/srv/repo.git" "$IMAGE" "file:///srv/repo.git" --branch does-not-exist
assert_eq "a branch that does not exist blocks" "1" "$RC"
assert_contains "start.sh's own checkout failure message survives the passthrough" \
  "cannot check out 'does-not-exist'" "$OUT"

# --- arguments pass all the way through, and the handover is a real exec -------
make_stub_repo "$TMP/stub.git" '#!/usr/bin/env bash
echo "STUB START pid=$$ args=$*"'
run_entry -v "$TMP/stub.git:/srv/repo.git" "$IMAGE" "file:///srv/repo.git" --branch foo -- --once --interval 15
assert_contains "every argument after the URL reaches start.sh, in order" \
  "args=--branch foo -- --once --interval 15" "$OUT"
assert_contains "start.sh runs as this container's pid 1: entrypoint execs, it does not fork" \
  "pid=1" "$OUT"

# --- an already-cloned repo (persistent volume) is pulled, not re-cloned -------
make_transport_repo "$TMP/restart.git"
mkdir -p "$TMP/vol"
run_entry -v "$TMP/restart.git:/srv/repo.git" -v "$TMP/vol:/home/heliograph/repo" \
  "$IMAGE" "file:///srv/repo.git" --check
assert_eq "first run against the volume clones and passes --check" "0" "$RC"
echo "evidence of an unpushed run" > "$TMP/vol/UNCOMMITTED_MARKER"
run_entry -v "$TMP/restart.git:/srv/repo.git" -v "$TMP/vol:/home/heliograph/repo" \
  "$IMAGE" "file:///srv/repo.git" --check
assert_eq "second run (restart) still succeeds" "0" "$RC"
assert_contains "and it says it reused the checkout rather than re-cloning" \
  "already holds a clone" "$OUT"
assert_eq "the marker a re-clone would have destroyed survives" \
  "yes" "$([ -f "$TMP/vol/UNCOMMITTED_MARKER" ] && echo yes || echo no)"

# --- a restart against a DIFFERENT repo on the same volume is refused ----------
# Reproduced exactly as reported: two real repos, one volume. Without this
# check, run 2 against beta.git still had alpha checked out and alpha as its
# remote, and everything start.sh/agent.sh do next - including pushing
# captured logs - happened against the wrong transport repo. Refused, not
# merely warned: an operator skimming scrollback would miss a warning.
make_transport_repo "$TMP/alpha.git"
make_transport_repo "$TMP/beta.git"
mkdir -p "$TMP/mismatchvol"
run_entry -v "$TMP/alpha.git:/srv/alpha.git" -v "$TMP/mismatchvol:/home/heliograph/repo" \
  "$IMAGE" "file:///srv/alpha.git" --check
assert_eq "first run clones alpha and passes --check" "0" "$RC"
run_entry -v "$TMP/beta.git:/srv/beta.git" -v "$TMP/mismatchvol:/home/heliograph/repo" \
  "$IMAGE" "file:///srv/beta.git" --check
assert_eq "a restart against a different repo on the same volume is refused" "1" "$RC"
assert_contains "and it names the repo the volume actually holds" \
  "already holds a clone of file:///srv/alpha.git" "$OUT"
assert_contains "and the one this run was given" "file:///srv/beta.git" "$OUT"
assert_eq "the old checkout's remote is left exactly as it was, not silently repointed" \
  "file:///srv/alpha.git" "$(cd "$TMP/mismatchvol" && git remote get-url origin 2>/dev/null)"
# DISCRIMINATION, not just a refusal. This path and the two UNIDENTIFIED
# paths below all end in "exit 1", which is exactly the shape the plan warns
# about - an assertion whose subject is reachable by more than one path. The
# exit code alone cannot tell them apart, so each path asserts on the
# MESSAGE, and each asserts the OTHER path's message is absent. Here: this is
# a repository the entrypoint genuinely READ and identified, so it must not
# be dressed up as the ownership failure below.
assert_eq "a genuinely different repo is NOT misreported as an ownership problem" "" \
  "$(printf '%s' "$OUT" | grep -o 'OWNERSHIP MISMATCH')"
assert_eq "nor as a directory whose contents could not be identified" "" \
  "$(printf '%s' "$OUT" | grep -o 'cannot identify what')"

# =============================================================================
#  a checkout that cannot be READ is UNIDENTIFIED, not "a different repo"
# =============================================================================
# PR 3 whole-PR review, Finding 1 (Critical). `git remote get-url origin` has
# THREE outcomes, and two of them used to be one branch: the read succeeding
# with a different URL, and the read FAILING, both landed in the same message.
# `2>/dev/null` swallowed git's error and `${existing_url:-<no origin remote>}`
# rendered the failure as a positive claim - "already holds a clone of <no
# origin remote>" - which then advised emptying the directory by hand.
#
# The trigger is an ownership mismatch: git refuses to read a repository owned
# by a different uid than the process reading it (CVE-2022-24765). Reproduced
# under PLAIN DOCKER, not only under rootless podman's known uid remapping.
# That directory is the OPERATOR'S checkout and may hold a captured log
# committed but never pushed - the one copy of the evidence this whole toolkit
# exists to carry off a machine nobody can reach - so an operator following
# the old advice destroyed it.
#
# The mismatch is built WITHOUT ROOT, by building the image for a different
# uid rather than chowning the volume: git refuses in either direction, and
# needing sudo would make this assertion skippable on exactly the machines
# most likely to hit the bug. The same technique the --ssh contrast test
# further down already uses.
MISMATCH_UID=13345
MISMATCH_TAG="heliograph-toolkit-test:local-ownermismatch"
if ! "$RUNTIME" build -f "$DOCKERFILE" -t "$MISMATCH_TAG" \
     --build-arg "HELIOGRAPH_UID=$MISMATCH_UID" "$DOCKER_DIR" >/dev/null 2>&1; then
  t_skip "the ownership-mismatch tests: could not build an image at uid $MISMATCH_UID here"
else
  make_transport_repo "$TMP/ownership.git"
  mkdir -p "$TMP/ownvol"
  # A uid-MATCHED first run, so the volume genuinely holds a correct checkout
  # OF THE SAME URL the second run is given. That is what makes the second
  # run's old diagnosis ("a clone of a different repository") demonstrably
  # false rather than merely unhelpful.
  run_entry -v "$TMP/ownership.git:/srv/repo.git" -v "$TMP/ownvol:/home/heliograph/repo" \
    "$IMAGE" "file:///srv/repo.git" --check
  assert_eq "the uid-matched first run clones into the volume normally" "0" "$RC"
  assert_eq "and the volume really is a clone of the very URL the next run is given" \
    "file:///srv/repo.git" "$(cd "$TMP/ownvol" && git remote get-url origin 2>/dev/null)"

  # The evidence the old advice destroyed: present before, asserted present
  # after.
  mkdir -p "$TMP/ownvol/ops-logs"
  printf 'the only copy of a captured log\n' > "$TMP/ownvol/ops-logs/UNPUSHED_EVIDENCE"

  run_entry -v "$TMP/ownership.git:/srv/repo.git" -v "$TMP/ownvol:/home/heliograph/repo" \
    "$MISMATCH_TAG" "file:///srv/repo.git" --check
  assert_eq "a checkout this container's user cannot read is refused, not reused" "1" "$RC"
  assert_contains "and it is named as an ownership mismatch, not as a different repository" \
    "The cause is an OWNERSHIP MISMATCH, not a different repository" "$OUT"
  # BOTH uids, each MEASURED rather than assumed: the directory's real owner
  # (this test user's own uid, whatever it is on this machine) and the uid the
  # container genuinely runs as. A message that hardcoded either, or dropped
  # one side, goes red here on any host.
  assert_contains "naming the uid that actually owns the directory" \
    "/home/heliograph/repo is owned by uid $(id -u)" "$OUT"
  assert_contains "and the uid this container actually runs as" \
    "this container runs as uid $MISMATCH_UID" "$OUT"
  # NOT SWALLOWED. git's own stderr was discarded before this fix, which is
  # what left the entrypoint with nothing to diagnose from.
  #
  # This asserted on the substring "dubious ownership" at first, and that
  # assertion COULD NOT FAIL: entrypoint.sh's own prose above it contains the
  # phrase too ("git refuses to read a repository owned by another user
  # (CVE-2022-24765, \"dubious ownership\")"), so the subject was reachable by
  # two paths and the hardcoded one always satisfied it. Found by mutation -
  # restoring `2>/dev/null` left it green. Anchored now on the "git said:"
  # label, which is printed ONLY when stderr was genuinely captured, and on
  # git's own wording, which appears nowhere in this script's prose.
  assert_contains "git's own error is quoted rather than discarded" "git said:" "$OUT"
  assert_contains "and it really is git's own wording, not this script's paraphrase of it" \
    "detected dubious ownership in repository at" "$OUT"
  # The claim the old message made, which was false: this directory IS a clone
  # of the URL this run was given.
  assert_eq "it never claims the directory holds some other repository" "" \
    "$(printf '%s' "$OUT" | grep -o 'already holds a clone of')"
  # THE SAFETY PROPERTY, asserted directly. The old remedy was "empty
  # /home/heliograph/repo by hand"; nothing on a path that could not identify
  # the directory may say that again.
  assert_eq "and it never advises emptying a directory whose contents it could not identify" "" \
    "$(printf '%s' "$OUT" | grep -o 'empty /home/heliograph/repo by hand')"
  assert_contains "it says the opposite, explicitly" "DO NOT empty or delete" "$OUT"
  assert_contains "and gives a remedy that keeps the checkout" \
    "--build-arg HELIOGRAPH_UID=$(id -u)" "$OUT"
  assert_eq "the evidence an operator following the old advice would have destroyed survives" \
    "the only copy of a captured log" "$(cat "$TMP/ownvol/ops-logs/UNPUSHED_EVIDENCE" 2>/dev/null)"

  # ---------------------------------------------------------------------------
  # THE SHAPE THAT ESCAPED THE DIAGNOSIS ENTIRELY - whole-PR review, Finding 3
  # ---------------------------------------------------------------------------
  # A foreign-owned checkout at mode 0700. Every test the entrypoint made
  # before reaching the branch above answers identically to EACCES and to
  # "nothing here": `[ -e "$WORKDIR/.git" ]` is false, `[ -x
  # "$WORKDIR/start.sh" ]` is false, and `[ -n "$(ls -A "$WORKDIR"
  # 2>/dev/null)" ]` is an empty string with a discarded exit status. So this
  # fell all the way through to the CLONE, git printed its own accurate
  # permission error, and the entrypoint then contradicted it by blaming the
  # URL or the credential - with the entire ownership diagnosis above,
  # including its DO-NOT-EMPTY rule, never reached on the one shape most
  # likely to need it.
  #
  # Same uid-mismatched image as above, so no root and no chown is required to
  # build the state: the directory belongs to this test user, mode 0700, and
  # the container runs as someone else.
  mkdir -p "$TMP/unreadablevol"
  ( cd "$TMP/unreadablevol" && git init -q \
      && printf '#!/usr/bin/env bash\necho UNREADABLE\n' > start.sh && chmod +x start.sh \
      && git remote add origin "file:///srv/repo.git" \
      && $GIT add -A && $GIT commit -qm init ) >/dev/null 2>&1
  printf 'an unpushed log lives here too\n' > "$TMP/unreadablevol/UNPUSHED_EVIDENCE"
  chmod 700 "$TMP/unreadablevol"
  run_entry -v "$TMP/unreadablevol:/home/heliograph/repo" \
    "$MISMATCH_TAG" "file:///srv/repo.git" --check
  assert_eq "a checkout this container cannot even list is refused, not cloned over" "1" "$RC"
  assert_contains "and it lands in the UNIDENTIFIED branch, where the diagnosis lives" \
    "cannot identify what /home/heliograph/repo holds" "$OUT"
  assert_contains "naming the real cause rather than the URL or the credential" \
    "The cause is an OWNERSHIP MISMATCH, not a different repository" "$OUT"
  assert_contains "with the uid that owns it" \
    "/home/heliograph/repo is owned by uid $(id -u)" "$OUT"
  # DISCRIMINATION: the three branches this could have taken all exit 1, so
  # each of the other two messages is asserted ABSENT. "git clone failed" is
  # the one it actually reached before this fix.
  assert_eq "never as a clone failure blamed on the URL or the credential" "" \
    "$(printf '%s' "$OUT" | grep -o 'git clone failed')"
  assert_eq "nor as a foreign non-empty directory, which is a different fact" "" \
    "$(printf '%s' "$OUT" | grep -o 'not a heliograph checkout')"
  assert_contains "and the DO-NOT-EMPTY rule reaches this path too" \
    "DO NOT empty or delete" "$OUT"
  chmod 755 "$TMP/unreadablevol"
  assert_eq "the checkout is still there, untouched" "an unpushed log lives here too" \
    "$(cat "$TMP/unreadablevol/UNPUSHED_EVIDENCE" 2>/dev/null)"

  "$RUNTIME" image rm -f "$MISMATCH_TAG" >/dev/null 2>&1
fi

# --- the OTHER unidentified shape: a checkout with no origin remote at all ----
# Same "the read failed" branch, different cause, and no ownership mismatch
# involved - so it proves the branch is about the READ FAILING rather than
# about ownership specifically. Under the old code this printed the single
# most misleading sentence of the three: "already holds a clone of <no origin
# remote>", a rendered-empty-string presented as a repository name.
mkdir -p "$TMP/noremote"
( cd "$TMP/noremote" && git init -q \
    && printf '#!/usr/bin/env bash\necho NOREMOTE\n' > start.sh && chmod +x start.sh \
    && $GIT add -A && $GIT commit -qm init ) >/dev/null 2>&1
run_entry -v "$TMP/noremote:/home/heliograph/repo" "$IMAGE" "file:///srv/repo.git"
assert_eq "a checkout with no origin remote is refused" "1" "$RC"
assert_contains "as a directory this run could not identify" \
  "cannot identify what /home/heliograph/repo holds" "$OUT"
assert_eq "never as 'a clone of <no origin remote>' - an empty read is not a repository name" "" \
  "$(printf '%s' "$OUT" | grep -o 'already holds a clone of')"
assert_contains "git's own reason is shown here too" "No such remote" "$OUT"
assert_eq "and this path does not advise emptying it either" "" \
  "$(printf '%s' "$OUT" | grep -o 'by hand')"
assert_contains "it points at a different, empty location instead" \
  "Point HELIOGRAPH_WORKDIR at a different, empty location" "$OUT"
# The refusal is worth nothing if the directory is cleared on the way out, and
# THIS fixture is the one that can prove it: the container's user owns it, so
# a `rm -rf $WORKDIR` on this path genuinely would succeed. The ownership
# fixture above cannot prove the same thing - a uid-mismatched container is
# refused the delete by the kernel regardless of what the script asks for -
# which is exactly what a mutation showed by surviving there and dying here.
assert_eq "and the checkout is still on disk, not cleared to get past the refusal" "yes" \
  "$([ -d "$TMP/noremote/.git" ] && echo yes || echo no)"

# --- a non-empty directory that is not a checkout is refused, not overwritten --
mkdir -p "$TMP/foreign"
echo "not a git repo" > "$TMP/foreign/unrelated-file.txt"
run_entry -v "$TMP/foreign:/home/heliograph/repo" "$IMAGE" "https://example.invalid/x.git"
assert_eq "a foreign non-empty directory blocks rather than being cloned into" "1" "$RC"
assert_contains "and says why" "not a heliograph checkout" "$OUT"
assert_eq "and it is left untouched" "not a git repo" "$(cat "$TMP/foreign/unrelated-file.txt")"
# With no .git at all, "empty it by hand" is safe advice and stays: there is
# nothing here that could be a repository holding an unpushed commit.
assert_contains "with no .git, emptying it by hand is still offered - nothing here can be a repo" \
  "empty the" "$OUT"

# The SAME branch with a .git present: the one other place this script
# reached for "empty the directory by hand". A checkout whose ./start.sh
# merely lost its executable bit lands here, and it can be a real transport
# repo holding commits that were never pushed - so this branch does not say
# that either. Same rule as the unidentified paths above, different branch.
mkdir -p "$TMP/noexec"
( cd "$TMP/noexec" && git init -q \
    && printf '#!/usr/bin/env bash\necho NOEXEC\n' > start.sh && chmod -x start.sh \
    && $GIT add -A && $GIT commit -qm init ) >/dev/null 2>&1
run_entry -v "$TMP/noexec:/home/heliograph/repo" "$IMAGE" "https://example.invalid/x.git"
assert_eq "a git repo whose start.sh is not executable blocks too" "1" "$RC"
assert_contains "naming that it IS a repository, so its contents are not disposable" \
  "It has a .git, so it IS a git repository" "$OUT"
assert_eq "and here 'empty it by hand' is NOT offered - it could hold an unpushed commit" "" \
  "$(printf '%s' "$OUT" | grep -o 'empty the directory by hand')"
assert_contains "it names the likely cause and a fix that keeps the repo instead" \
  "chmod +x it" "$OUT"
assert_eq "and the repository is still there afterwards" "yes" \
  "$([ -d "$TMP/noexec/.git" ] && echo yes || echo no)"

# --- the credential never ends up in the cloned repo's .git/config -------------
make_transport_repo "$TMP/config.git"
mkdir -p "$TMP/configvol"
run_entry -e "GIT_TOKEN=$TOKEN" -v "$TMP/config.git:/srv/repo.git" \
  -v "$TMP/configvol:/home/heliograph/repo" "$IMAGE" "file:///srv/repo.git" --check
assert_eq ".git/config in the cloned repo never carries the token" "" \
  "$(grep -o "$TOKEN" "$TMP/configvol/.git/config" 2>/dev/null)"
assert_contains "the remote stays the plain URL that was given" \
  "url = file:///srv/repo.git" "$(cat "$TMP/configvol/.git/config" 2>/dev/null)"

# --- docker inspect: the vector this script cannot close -----------------------
# `docker create` (no run needed - Config.Env is set at creation) with the
# token passed the obvious way, `-e`, and inspected the way anyone who can
# talk to this daemon could. Asserted as a POSITIVE match: this is the
# leak vector's reality being confirmed, not a defect in entrypoint.sh - there
# is nothing a script running INSIDE the container can do about what the
# daemon records about how it was started.
# The container is never run, only created - `docker create` alone is enough
# to populate Config.Env, and running it would add nothing this assertion
# needs. That means, unlike every other assertion in this file, NOTHING in
# entrypoint.sh's own logic can turn either check below red - so both guard
# explicitly against `docker create` itself failing (cid empty, "$RUNTIME
# inspect ''" would print nothing and a plain absence check would pass
# vacuously) and assert something POSITIVE first, so each has an observable
# subject rather than resting entirely on an absence that a broken create
# would satisfy for free.
cid="$("$RUNTIME" create -e "GIT_TOKEN=$TOKEN" "$IMAGE" "https://example.invalid/x.git" 2>/dev/null)"
assert_eq "docker create for the -e GIT_TOKEN case actually produced a container id" "" \
  "$([ -z "$cid" ] && echo EMPTY-CID)"
assert_contains "confirmed: -e is visible in docker inspect (a Docker property, not this script's)" \
  "$TOKEN" "$("$RUNTIME" inspect "$cid" 2>/dev/null)"
"$RUNTIME" rm -f "$cid" >/dev/null 2>&1

# Contrast: GIT_TOKEN_FILE naming a mounted file. inspect shows the PATH
# (Config.Env necessarily records the -e GIT_TOKEN_FILE=... assignment
# itself), never the file's contents.
printf '%s\n' "$TOKEN" > "$TMP/token-file"
cid="$("$RUNTIME" create -e GIT_TOKEN_FILE=/run/secrets/git-token \
        -v "$TMP/token-file:/run/secrets/git-token:ro" \
        "$IMAGE" "https://example.invalid/x.git" 2>/dev/null)"
assert_eq "docker create for the GIT_TOKEN_FILE case actually produced a container id" "" \
  "$([ -z "$cid" ] && echo EMPTY-CID)"
inspect_out="$("$RUNTIME" inspect "$cid" 2>/dev/null)"
assert_contains "docker inspect really did capture this container's config (subject is observable)" \
  "/run/secrets/git-token" "$inspect_out"
assert_eq "GIT_TOKEN_FILE keeps the token itself out of docker inspect" "" \
  "$(printf '%s' "$inspect_out" | grep -o "$TOKEN")"
"$RUNTIME" rm -f "$cid" >/dev/null 2>&1

# --- the process table: the header travels via env, never argv -----------------
# A fake `git` shadowing PATH that reports its own argv AND its own
# /proc/self/cmdline (the property that actually matters - PR 1's cap_git
# tests prove the same property for cap_git the same way, by making the fake
# git self-report rather than racing a real process's lifetime), then execs
# the real git so the clone genuinely completes against the bind-mounted bare
# repo. Reports KEY_1/VALUE_1 too (Finding 2, the ambient-config test below)
# and GIT_TERMINAL_PROMPT (the never-prompt fix).
#
# fakegit_clone_block <report-file> - every git invocation inside a run gets
# logged (start.sh's own cap_git calls ls-remote and push --dry-run too, and
# both share this same PATH once it is exec'd into), and the very first
# version of this file's argv/header assertions grepped the WHOLE report -
# which is exactly why they could not fail: neutering entrypoint_auth_header
# so the CLONE goes out with no credential at all left every assertion here
# green, because cap_git's OWN later ls-remote/push calls (a completely
# different property, already test-capgit.sh's) still carried the header and
# satisfied the grep. Anchored to the block that starts at the line whose
# ARGV begins "clone " and ends at its own GIT_CONFIG report line, so these
# assertions can only be satisfied by the CLONE's own invocation.
fakegit_clone_block() {
  awk '
    /^ARGV: clone / { capture=1 }
    capture { print }
    capture && /^GIT_CONFIG_COUNT=/ { capture=0 }
  ' "$1"
}

mkdir -p "$TMP/fakebin" "$TMP/report"
cat > "$TMP/fakebin/git" <<'EOF'
#!/bin/sh
{
  printf 'ARGV: %s\n' "$*"
  printf 'CMDLINE: '; tr '\0' ' ' < /proc/self/cmdline; printf '\n'
  printf 'GIT_TERMINAL_PROMPT=%s\n' "${GIT_TERMINAL_PROMPT:-unset}"
  printf 'GIT_CONFIG_COUNT=%s GIT_CONFIG_KEY_0=%s GIT_CONFIG_VALUE_0=%s GIT_CONFIG_KEY_1=%s GIT_CONFIG_VALUE_1=%s\n' \
    "${GIT_CONFIG_COUNT:-unset}" "${GIT_CONFIG_KEY_0:-unset}" "${GIT_CONFIG_VALUE_0:-unset}" \
    "${GIT_CONFIG_KEY_1:-unset}" "${GIT_CONFIG_VALUE_1:-unset}"
} >> /report/log 2>&1
exec /usr/bin/git "$@"
EOF
chmod +x "$TMP/fakebin/git"
make_transport_repo "$TMP/argv.git"
run_entry -e "GIT_TOKEN=$TOKEN" -e "PATH=/fakebin:/usr/bin:/bin" \
  -v "$TMP/fakebin:/fakebin:ro" -v "$TMP/report:/report" \
  -v "$TMP/argv.git:/srv/repo.git" "$IMAGE" "file:///srv/repo.git" --check
assert_eq "the clone under the fake git still succeeds" "0" "$RC"
clone_block="$(fakegit_clone_block "$TMP/report/log")"
assert_contains "the CLONE's own invocation was captured (subject is observable)" \
  "clone" "$clone_block"
assert_eq "the token never reaches the CLONE's argv" "" \
  "$(printf '%s\n' "$clone_block" | grep '^ARGV:' | grep -o "$TOKEN")"
assert_eq "nor /proc/self/cmdline of the git process that did the cloning" "" \
  "$(printf '%s\n' "$clone_block" | grep '^CMDLINE:' | grep -o "$TOKEN")"
assert_eq "GIT_TERMINAL_PROMPT=0 reaches the clone, so an auth prompt cannot hang it" \
  "GIT_TERMINAL_PROMPT=0" "$(printf '%s\n' "$clone_block" | grep '^GIT_TERMINAL_PROMPT=')"
# The property is "no auth header reaches argv AT ALL", not just "the raw
# token substring is absent" - test-capgit.sh's own comment names this
# exactly: base64(":$TOKEN") never contains the plaintext token even when
# `-c http.extraHeader=...` is used, so the two assertions above alone would
# still pass under an entrypoint.sh that took the env route AND left a `-c`
# fallback reachable when it should not be. Confirmed by mutation: forcing
# the old-git `-c` fallback unconditionally left the two assertions above
# GREEN (the base64 blob it puts in argv never contains "9f2c8a" et al.
# verbatim) while this one goes red. Assert on the marker that WOULD be in
# argv under that regression instead, exactly as test-capgit.sh does.
assert_eq "and no -c http.extraHeader reaches the CLONE's argv either (base64 is not secrecy)" "" \
  "$(printf '%s\n' "$clone_block" | grep '^ARGV:' | grep -o extraHeader)"
assert_contains "the CLONE's own invocation carries the header, through GIT_CONFIG_VALUE_0 (env, mode 400), not argv" \
  "GIT_CONFIG_VALUE_0=Authorization: Basic $EXPECTED_HDR_B64" "$clone_block"

# --- an ambient GIT_CONFIG_* survives: append, never overwrite -----------------
# This used to hard-code GIT_CONFIG_COUNT=1/KEY_0/VALUE_0 for the clone,
# which is the exact mistake cap_git's own append-at-next-free-index logic
# exists to avoid: an operator on a locked-down estate may already inject
# their own GIT_CONFIG_COUNT/KEY_0/VALUE_0 into this container's environment
# (an ambient http.proxy, sslCAInfo, safe.directory). Slot 0 silently
# overwrote and truncated it off the list - and only on the AUTHENTICATED
# path, since the header-less branch never touches GIT_CONFIG_* at all, so
# the failure appeared only once a token was added, on the one path that is
# actually deployed.
mkdir -p "$TMP/report2"
make_transport_repo "$TMP/ambient.git"
run_entry -e "GIT_TOKEN=$TOKEN" -e "PATH=/fakebin:/usr/bin:/bin" \
  -e "GIT_CONFIG_COUNT=1" -e "GIT_CONFIG_KEY_0=http.proxy" -e "GIT_CONFIG_VALUE_0=http://corp:3128" \
  -v "$TMP/fakebin:/fakebin:ro" -v "$TMP/report2:/report" \
  -v "$TMP/ambient.git:/srv/repo.git" "$IMAGE" "file:///srv/repo.git" --check
assert_eq "the clone still succeeds with an ambient GIT_CONFIG_* already set" "0" "$RC"
ambient_block="$(fakegit_clone_block "$TMP/report2/log")"
assert_contains "the operator's own ambient config survives at slot 0, COUNT becomes 2 not reset to 1" \
  "GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=http.proxy GIT_CONFIG_VALUE_0=http://corp:3128" "$ambient_block"
assert_contains "and this clone's own header is appended at slot 1, not overwriting slot 0" \
  "GIT_CONFIG_KEY_1=http.extraHeader GIT_CONFIG_VALUE_1=Authorization: Basic $EXPECTED_HDR_B64" "$ambient_block"

# --- a clone that succeeds but is not a transport repo cleans up after itself --
# Without this, the NEXT run of the same container against the same volume
# lands in the "not a heliograph checkout" refusal instead of retrying the
# clone - a less accurate diagnosis of what actually happened.
mkdir -p "$TMP/nostartsh.work"
printf 'not a transport repo\n' > "$TMP/nostartsh.work/README.md"
git init -q --bare "$TMP/nostartsh.git"
( cd "$TMP/nostartsh.work" && git init -q && git remote add origin "$TMP/nostartsh.git" \
    && $GIT add -A && $GIT commit -qm init && $GIT push -q -u origin HEAD ) >/dev/null 2>&1
mkdir -p "$TMP/nostartshvol"
run_entry -v "$TMP/nostartsh.git:/srv/repo.git" -v "$TMP/nostartshvol:/home/heliograph/repo" \
  "$IMAGE" "file:///srv/repo.git"
assert_eq "a clone with no start.sh fails" "1" "$RC"
assert_contains "and names the problem" "no executable" "$OUT"
assert_eq "and it does not leave the partial checkout behind" "" \
  "$(ls -A "$TMP/nostartshvol" 2>/dev/null)"

# =============================================================================
#  PR 3 task 3 - heliograph.sh: the docker run, as one line
# =============================================================================
# This wraps entrypoint.sh, unchanged - it never re-checks a credentialed URL,
# never re-decides whether to reuse a checkout, never adds a second copy of
# any refusal entrypoint.sh already owns. So the assertions below are about
# what THIS FILE is actually responsible for: runtime detection, the
# build-or-refuse decision, foreground-vs-detach, which mounts appear (and
# which do not) and how a credential reaches the container without ever
# landing on this script's own command line - never a re-proof of what
# tests/test-container.sh already established about entrypoint.sh itself
# further up this file.
WRAP="$ROOT/skills/heliograph/toolkit/docker/heliograph.sh"

# wrap <args...> - runs the real wrapper, combined output, bounded at 30s so a
# defect that hangs cannot wedge the suite. Sets RC/OUT.
wrap() {
  RC=0
  OUT="$(timeout 30 "$WRAP" "$@" 2>&1)" || RC=$?
}

# composed_cmd - just the `docker run ...`/`podman run ...` line out of a
# --print run's output. heliograph.sh now prints advice on stderr alongside it
# (what to do if the push fails, which variable it left behind), and that prose
# NAMES the flags it is talking about - so an assertion that greps the whole
# capture for "--rm" is satisfied by a sentence explaining --rm. The composed
# command is one line and always starts with the runtime's own name.
composed_cmd() {
  printf '%s\n' "$1" | grep -E '^(docker|podman) run' | tail -1
}

# wrap_bounded <seconds> <args...> - same, with a caller-chosen bound. Used to
# prove foreground genuinely blocks (a bound shorter than the stub's own
# runtime has to fire) and that --detach genuinely returns before it would.
wrap_bounded() {
  local t="$1"; shift
  RC=0
  OUT="$(timeout "$t" "$WRAP" "$@" 2>&1)" || RC=$?
}

# --- heliograph.sh never calls the runtime by a hardcoded name -----------------
# "must work with podman unchanged" only means something if nothing in here
# ever calls `docker` directly outside of prose (comments, --help text, the
# tag names of images this file builds/tags itself). Every real invocation
# goes through "$RUNTIME". Comment lines (leading #) are excluded first, then
# what remains is checked for "docker" used as a COMMAND WORD - at the start
# of a line/statement, or straight after a shell operator - rather than
# merely appearing in a backtick-quoted sentence.
hardcoded="$(grep -vE '^\s*#' "$WRAP" \
  | grep -nE '(^|[|&;(]|\bexec[[:space:]])[[:space:]]*"?docker"?[[:space:]]+(run|build|create|image)\b')"
assert_eq "heliograph.sh never invokes 'docker' directly - only through \$RUNTIME" "" "$hardcoded"

# --- --help --------------------------------------------------------------------
wrap --help
assert_eq "--help exits 0" "0" "$RC"
assert_contains "and describes the wrapper's own contract" "usage: heliograph.sh" "$OUT"

# --- no URL at all: passed straight through to entrypoint.sh -------------------
# Proves the wrapper does NOT re-validate anything entrypoint.sh already
# refuses - it is entrypoint.sh's own usage error (exit 2, same message) that
# should surface here, not a wrapper-invented one.
wrap --image "$IMAGE" --dockerfile "$DOCKERFILE"
assert_eq "no URL at all surfaces entrypoint.sh's own usage error, unchanged" "2" "$RC"
assert_contains "and it is entrypoint.sh's own message, not a wrapper rewrite of it" \
  "no repository URL" "$OUT"

# =============================================================================
#  wrapper option validation - PR 3 review, Findings 1 and 2, and a Minor
# =============================================================================
# Three of this wrapper's own flags take a value that gets composed into a
# specific shape (a bind mount's host side, an image reference, a Dockerfile
# path) rather than passed through opaque - so a value that does not fit is
# caught HERE, named as this wrapper's own flag, instead of reaching
# docker/podman and surfacing as THEIR generic complaint ("invalid mode",
# "invalid reference format"), which names neither the flag nor the value at
# fault. None of this reaches into entrypoint.sh's own territory (the URL,
# any start.sh argument) - only this wrapper's own options, per this file's
# standing rule.

# --- --volume rejects a host:target pair (Finding 1) ---------------------------
# --volume is documented as taking a HOST DIRECTORY only - the container-side
# target is fixed by this script (WORKDIR_CONTAINER), never chosen by the
# caller. Before this fix, a host:target pair composed straight into
# "-v host:target:/home/heliograph/repo" (a three-field mount), and
# docker/podman's own "invalid mode: /home/heliograph/repo" surfaced instead -
# naming neither --volume nor the value at fault. Confirmed by hand before
# this fix existed; see the task report.
wrap --volume /tmp/does-not-matter:/tmp/also-does-not-matter "https://example.invalid/x.git"
assert_eq "--volume with a host:target pair is refused before any mount is composed" "2" "$RC"
assert_contains "and it names the flag and what it actually takes" \
  "--volume takes a single host directory, not a host:target pair" "$OUT"

# --- --image rejects a malformed reference (Finding 2) -------------------------
# Uppercase is the shape an operator actually mistypes - docker/podman
# repository names are lowercase-only. A bare non-empty check let this reach
# "$RUNTIME build"/"run" and come back as their own "invalid reference
# format", naming nothing about which flag caused it.
wrap --image "MyImage:Latest" "https://example.invalid/x.git"
assert_eq "--image with uppercase is refused before it ever reaches the runtime" "2" "$RC"
assert_contains "and it names the flag and the expected shape" \
  "does not look like a valid image reference" "$OUT"

# A value that is otherwise well-formed - lowercase, built only from the
# characters a real reference uses, including a registry host:port and a
# multi-segment path - is NOT rejected, so this stays a narrow typo-catcher
# rather than a parser that could reject something valid.
wrap --print --image "registry.example.invalid:5000/my-team/heliograph:v1.2.3" "https://example.invalid/x.git"
assert_eq "a well-formed multi-segment reference with a registry port is accepted" "0" "$RC"

# =============================================================================
#  an option value that looks like a flag - PR 3 whole-PR review, Finding 2
# =============================================================================
# `heliograph.sh --image --help` exited 0 HAVING RUN NOTHING. "--help" passes
# --image's own shape check above (every character in it is one a real image
# reference is built from), so it became the image name, reached `image
# inspect --help` - which prints help and exits 0, so the image "existed" and
# nothing was built - and then reached `run ... --help ...`, where the runtime
# parsed it as ITS OWN flag, printed usage and exited 0. A clean exit code for
# a run that never happened is the worst available outcome for a toolkit whose
# whole point is that a round trip through an operator is expensive.
#
# The exit code alone is a real discriminator here (the defect's own exit code
# was 0), but it is not asserted alone: a DIFFERENT refusal - the shape check
# above, say - also exits 2, so the message is asserted too, and so is the
# absence of the runtime's own usage banner, which is the actual symptom.
wrap --image --help "https://example.invalid/x.git"
assert_eq "an option value that looks like a flag is refused, not silently run as nothing" \
  "2" "$RC"
assert_contains "and it names the flag, the value, and why the value cannot be one" \
  "--image expects a tag, but got '--help', which begins with a dash" "$OUT"
# The symptom itself: the runtime's own help text, from a run that did nothing.
# Both docker's and podman's `run` usage carry this fragment.
assert_eq "and the runtime's own usage banner never appears - it was never reached" "" \
  "$(printf '%s' "$OUT" | grep -o 'IMAGE \[COMMAND')"

# Every value-taking wrapper option goes through the same gate, not just the
# one the finding happened to name. --name is checked separately because it
# has no shape check of its own at all, so nothing else would catch it.
wrap --name --detach "https://example.invalid/x.git"
assert_eq "--name with a flag-shaped value is refused too" "2" "$RC"
assert_contains "naming that flag and value, not --image's" \
  "--name expects a container name, but got '--detach'" "$OUT"

# An option with its value simply MISSING (nothing after it at all) still
# refuses on the empty check, in the same voice - the two are different
# mistakes and neither may fall through.
wrap --image
assert_eq "an option with no value at all still refuses" "2" "$RC"
assert_contains "in the same voice" "--image requires a tag" "$OUT"

# `--` before the image in the composed command: belt and braces behind the
# check above, so a dash-leading value arriving by some route it does not
# cover is still positional to the runtime rather than one of its flags.
wrap --print --image "$IMAGE" "https://example.invalid/x.git"
assert_contains "the composed run command ends the runtime's own flag parsing before the image" \
  "-- $IMAGE" "$OUT"

# --- --dockerfile rejects a path that does not exist (Minor) -------------------
# Previously reached ensure_image unchecked, so a typo'd path failed only
# after a wasted build attempt, in docker's own voice. Caught at parse time,
# the same way --token-file's existing existence check works.
wrap --dockerfile /no/such/Dockerfile-anywhere "https://example.invalid/x.git"
assert_eq "--dockerfile naming a path that does not exist is refused immediately" "1" "$RC"
assert_contains "and it names the flag and the missing path" \
  "--dockerfile /no/such/Dockerfile-anywhere does not exist" "$OUT"

# --- a relative mount source becomes a NAMED VOLUME - Finding 5 ----------------
# docker and podman read a `-v` source that does not begin with / as a named
# volume rather than a path, and CREATE it empty rather than refusing. So
# `--token-file mytoken` composed `-v mytoken:/run/heliograph/git-token:ro`,
# mounted a brand new empty volume where the credential should have been, and
# the clone went out unauthenticated with nothing but a "no header is sent"
# line to show for it. `--volume somedir` is the same trap with a worse
# ending: the checkout the operator meant to keep is not the one the container
# used, so the persistence the flag exists for silently did not happen - and,
# since Finding 1, that is also the copy of a failed run's log.
#
# --token-file's fixture exists here on purpose: the existence check it
# already had passes for a relative path that is really there, so the refusal
# has to be about the SHAPE of the value, not about the file being missing.
# Fixture names carry a prefix of their own so the "was a named volume
# created" assertion below can clear its own leftovers first without any risk
# of removing a volume that belongs to whoever is running this suite. Under
# the defect (and under a mutation that restores it) the runtime really does
# create these, and a leftover from one run would otherwise leave the
# assertion red on every later one.
REL_TOKEN="heliograph-fixture-reltoken"
REL_DIR="heliograph-fixture-reldir"
"$RUNTIME" volume rm "$REL_TOKEN" "$REL_DIR" >/dev/null 2>&1
( cd "$TMP" && printf 'tok\n' > "$REL_TOKEN" && mkdir -p "$REL_DIR" )
( cd "$TMP" && "$WRAP" --token-file "$REL_TOKEN" "https://example.invalid/x.git" >/dev/null 2>&1 )
rel_rc=$?
assert_eq "--token-file with a relative path is refused even though the file exists" "2" "$rel_rc"
OUT="$( cd "$TMP" && "$WRAP" --token-file "$REL_TOKEN" "https://example.invalid/x.git" 2>&1 )"
assert_contains "and it names the flag, the value and the named-volume trap" \
  "--token-file expects an ABSOLUTE path to the token file, but got '$REL_TOKEN'" "$OUT"
assert_contains "explaining what the runtime would have done with it instead" \
  "NAMED VOLUME" "$OUT"
assert_contains "and offering the absolute form of the very value that was given" \
  "$TMP/$REL_TOKEN" "$OUT"

OUT="$( cd "$TMP" && "$WRAP" --volume "$REL_DIR" "https://example.invalid/x.git" 2>&1 )"
rel_rc=$?
assert_eq "--volume with a relative path is refused too" "2" "$rel_rc"
assert_contains "in the same voice, naming --volume rather than --token-file" \
  "--volume expects an ABSOLUTE path to the host directory, but got '$REL_DIR'" "$OUT"
# And nothing was created behind the operator's back while finding that out.
assert_eq "and no named volume was created for either refusal" "" \
  "$("$RUNTIME" volume ls --format '{{.Name}}' 2>/dev/null | grep -x "$REL_TOKEN\|$REL_DIR")"

# --- a credentialed URL is refused HERE too - Finding 2 ------------------------
# entrypoint.sh already refuses this, and that refusal is asserted further up
# this file. It is not enough on its own: by the time it runs, the wrapper has
# already composed that string into `docker run`'s argv, which puts it in the
# HOST's process table and in `docker inspect .Config.Cmd` for the container's
# whole life - neither of which anything inside the container can undo. The
# only place the host-side half can be prevented is before the exec, so it is
# refused here as well, and the message says the part entrypoint.sh cannot
# know: the credential is already exposed and has to be rotated.
WRAP_TOKEN="heliograph-wrapper-url-fixture-5b1e"
wrap --image "$IMAGE" "https://ci-user:$WRAP_TOKEN@example.invalid/x.git"
assert_eq "a credentialed URL is refused by the wrapper, before any runtime command is composed" \
  "2" "$RC"
assert_eq "and the wrapper never prints the token itself" "" \
  "$(printf '%s' "$OUT" | grep -o "$WRAP_TOKEN")"
assert_contains "it quotes the URL masked, so the operator can see which one it means" \
  "https://ci-user:***@example.invalid/x.git" "$OUT"
assert_contains "and says the credential is already spent, not merely mis-passed" \
  "TREAT THAT CREDENTIAL AS COMPROMISED AND ROTATE IT" "$OUT"
assert_contains "naming the host-side exposure entrypoint.sh cannot reach" \
  ".Config.Cmd" "$OUT"
# DISCRIMINATION: the refusal has to be the WRAPPER's, made before the runtime
# was reached at all - not entrypoint.sh's, surfacing through a container that
# was started with the credential already on its command line.
assert_eq "it is the wrapper's own refusal - no container was started to produce it" "" \
  "$(printf '%s' "$OUT" | grep -o 'entrypoint: the repository URL embeds a credential')"
# The same refusal for a credentialed URL arriving as a start.sh argument
# rather than as the URL, which leaks identically.
REPO_URL="file:///srv/repo.git" wrap --print --image "$IMAGE" -- --branch "https://x:$WRAP_TOKEN@example.invalid/y.git"
assert_eq "a credentialed value anywhere in the passthrough is refused, not just the first token" \
  "2" "$RC"
# NOT REFUSED: an ssh URL's git@ is a username, not a secret, and rejecting it
# would break the transport references/transport.md actually prefers. This is
# the boundary of the check, asserted so it cannot quietly widen.
wrap --print --image "$IMAGE" "ssh://git@example.invalid/x.git"
assert_eq "an ssh URL's git@ username is not mistaken for a credential" "0" "$RC"
assert_contains "and the URL reaches the composed command untouched" \
  "ssh://git@example.invalid/x.git" "$OUT"

# --- a registry-qualified --image is pulled, never built - Finding 6 -----------
# `--image ghcr.io/org/heliograph-toolkit:v9.9.9` used to BUILD the local
# Dockerfile and tag the result with the published name. references/container.md
# presents pulling and building as the two distinct paths, and the publish
# workflow's whole argument is that the image at a tag can only be what that
# tag's commit produced; a consumer-side build tagged with the published name
# undoes that in the one place nobody would look.
REG_TAG="registry.invalid/example/heliograph-toolkit:v9.9.9"
wrap --no-build --image "$REG_TAG" "https://example.invalid/x.git"
assert_eq "--no-build against a registry tag refuses" "1" "$RC"
assert_contains "and says to PULL it, not to build it - the advice the old message got wrong" \
  "names a registry, so the thing to do is pull it, not build it" "$OUT"
# The default path: no --no-build, so the old code would have built it here.
# registry.invalid cannot resolve, so the pull fails fast and deterministically
# whether or not this machine has a network.
wrap --image "$REG_TAG" "https://example.invalid/x.git"
assert_eq "the default path pulls, and a failed pull is a refusal" "1" "$RC"
assert_contains "naming the pull as what failed" "pull of $REG_TAG failed" "$OUT"
assert_contains "and refusing to fabricate a published name from a local build" \
  "Refusing to build the local Dockerfile and tag the result" "$OUT"
# The property, not just the message: nothing was built under that name.
assert_eq "and nothing was built under the published name" "1" \
  "$("$RUNTIME" image inspect "$REG_TAG" >/dev/null 2>&1; echo $?)"
# A local tag with a slash but no registry-looking first segment is NOT
# treated as a registry reference - so this stays a narrow rule rather than
# "anything with a slash in it".
wrap --print --image "my-team/heliograph:local" "https://example.invalid/x.git"
assert_eq "a plain namespaced local tag is unaffected by the registry rule" "0" "$RC"

# --- REPO_URL is not forwarded when a URL was typed - Finding 7 ----------------
# entrypoint.sh refuses REPO_URL and a positional argument together. The
# wrapper forwarded an exported REPO_URL unconditionally, so a plain
# `REPO_URL=... heliograph.sh <url>` died on a refusal naming a variable the
# operator had not put on that command line, telling them to "drop REPO_URL" -
# which the wrapper itself had added.
REPO_URL="https://example.invalid/env-repo-url.git" wrap --print --image "$IMAGE" \
  "https://example.invalid/typed.git"
assert_eq "REPO_URL is NOT forwarded when a URL was also given on the command line" "" \
  "$(printf '%s' "$OUT" | grep -o -- '-e REPO_URL')"
assert_contains "and the wrapper says which one it dropped, rather than doing it silently" \
  "REPO_URL is exported in this shell, and a URL was also given" "$OUT"
assert_contains "the typed URL is what reaches the container" \
  "https://example.invalid/typed.git" "$OUT"

# End to end, against the real entrypoint: the shape that used to die does not.
REPO_URL="file:///srv/does-not-matter.git" wrap --image "$IMAGE" --dockerfile "$DOCKERFILE" \
  "https://example.invalid/nope.git"
assert_eq "so the run reaches the clone rather than entrypoint.sh's both-were-given refusal" "" \
  "$(printf '%s' "$OUT" | grep -o 'both REPO_URL and a command-line argument')"
assert_contains "and fails on the URL it was actually given" "git clone failed" "$OUT"

# =============================================================================
#  the runtime-reachability guard (detect_runtime) - PR 3 review, Finding 3
# =============================================================================
# detect_runtime distinguishes "the binary is on PATH" from "its daemon/store
# actually answers info" - two DIFFERENT checks (command -v, then a real
# invocation), each with its own refusal and its own message. Every
# assertion above this point that reaches detect_runtime at all does so
# against a real docker or podman that is genuinely reachable on THIS
# machine, so none of them exercises the "on PATH but not reachable"
# branches - a guard disabled entirely still leaves every one of them green
# here, which is exactly how this hole shipped uncaught. A fake runtime
# script, put on PATH, whose own "info" subcommand fails deliberately, is
# the only way to make "on PATH" and "reachable" come apart under test,
# regardless of what is actually installed on the machine running this file.
mkdir -p "$TMP/fakeruntime"
cat > "$TMP/fakeruntime/heliograph-fake-runtime" <<'EOF'
#!/bin/sh
# On PATH (this directory is on it), but 'info' always fails - proving the
# guard checks more than command -v alone.
[ "$1" = "info" ] && exit 1
exit 0
EOF
chmod +x "$TMP/fakeruntime/heliograph-fake-runtime"

# --- --runtime naming something not on PATH at all ------------------------------
wrap --runtime heliograph-runtime-does-not-exist-anywhere "https://example.invalid/x.git"
assert_eq "--runtime naming a binary that is not on PATH refuses" "1" "$RC"
assert_contains "and it names the runtime and says so" \
  "--runtime heliograph-runtime-does-not-exist-anywhere was given but it is not on PATH" "$OUT"

# --- --runtime naming something ON PATH whose 'info' does not answer -----------
# The property this finding is about: a real, executable binary, genuinely on
# PATH (so command -v alone would accept it), that is not actually a usable
# container runtime. PATH is PREPENDED, not replaced - GIT_TOKEN="$X" wrap ...
# above already established that a variable assignment ahead of a function
# call applies only for that one call - so bash/timeout/coreutils, everything
# heliograph.sh and wrap() itself need, are still found afterward.
PATH="$TMP/fakeruntime:$PATH" wrap --runtime heliograph-fake-runtime "https://example.invalid/x.git"
assert_eq "a runtime that is on PATH but whose 'info' fails still refuses" "1" "$RC"
assert_contains "and the message distinguishes PATH presence from actual reachability" \
  "heliograph-fake-runtime is on PATH but 'info' did not answer" "$OUT"

# --- the same distinction in the auto-detect loop, not just --runtime ----------
# detect_runtime's un-forced path is a SEPARATE loop over docker/podman, not
# the lines the two assertions above exercise. Shadowing BOTH names with the
# identical broken fake proves that loop also checks reachability, not just
# presence - real docker/podman being installed elsewhere cannot rescue it,
# because the two names it actually looks for resolve to the broken fakes
# first.
mkdir -p "$TMP/fakebin-norun"
cp "$TMP/fakeruntime/heliograph-fake-runtime" "$TMP/fakebin-norun/docker"
cp "$TMP/fakeruntime/heliograph-fake-runtime" "$TMP/fakebin-norun/podman"
PATH="$TMP/fakebin-norun:$PATH" wrap "https://example.invalid/x.git"
assert_eq "auto-detect with both candidate names present but unreachable still refuses" "1" "$RC"
assert_contains "naming both candidates it checked and that neither answered" \
  "no container runtime is reachable (checked: docker, podman" "$OUT"

# =============================================================================
#  decision 1: build the image if it is absent
# =============================================================================
# A tag distinct from $IMAGE, so these assertions genuinely start from "the
# image does not exist yet" without disturbing $IMAGE, which the rest of this
# file (both above and below this block) depends on staying built.
WRAP_TAG="heliograph-wraptest:local"
"$RUNTIME" image rm -f "$WRAP_TAG" >/dev/null 2>&1

wrap --image "$WRAP_TAG" --dockerfile "$DOCKERFILE" "https://example.invalid/x.git"
assert_contains "a missing image is built automatically, announced as such" \
  "no image tagged $WRAP_TAG - building it now" "$OUT"
assert_eq "and it genuinely exists afterward" "0" \
  "$("$RUNTIME" image inspect "$WRAP_TAG" >/dev/null 2>&1; echo $?)"

wrap --image "$WRAP_TAG" --dockerfile "$DOCKERFILE" "https://example.invalid/x.git"
# Neither build-announcing message, not just the "missing" one - a mutation
# that always rebuilds still prints the OTHER message (the --build one,
# "rebuilding ... (--build was given)") on this path, which a grep for only
# "building it now" would miss entirely. Found by mutation; see the report.
assert_eq "a second run against the same tag does NOT rebuild it" "" \
  "$(printf '%s' "$OUT" | grep -E 'no image tagged|rebuilding')"

# --no-build: refuse rather than build, and genuinely build nothing
"$RUNTIME" image rm -f "$WRAP_TAG" >/dev/null 2>&1
wrap --image "$WRAP_TAG" --dockerfile "$DOCKERFILE" --no-build "https://example.invalid/x.git"
assert_eq "--no-build refuses rather than building when the image is missing" "1" "$RC"
# The RC check alone is not a real discriminator here: a refusal that fell
# through to building anyway would still exit 1, coincidentally, once the
# bogus fixture URL's clone failed a few seconds later inside the container -
# found by mutation (see the task report). "no image tagged $WRAP_TAG" alone
# is not one either: that fragment is a PREFIX shared with the auto-build
# message ("... - building it now"), so it stayed green under the same
# mutation. Only the full, refuse-specific sentence discriminates.
assert_contains "and names the missing tag and --no-build as the reason together" \
  "no image tagged $WRAP_TAG, and --no-build was given" "$OUT"
assert_eq "and nothing was actually built" "1" \
  "$("$RUNTIME" image inspect "$WRAP_TAG" >/dev/null 2>&1; echo $?)"

# --build: rebuild even though the tag already exists
wrap --image "$WRAP_TAG" --dockerfile "$DOCKERFILE" "https://example.invalid/x.git" >/dev/null 2>&1
wrap --image "$WRAP_TAG" --dockerfile "$DOCKERFILE" --build "https://example.invalid/x.git"
assert_contains "--build rebuilds even though the tag already exists" \
  "rebuilding $WRAP_TAG (--build was given)" "$OUT"

"$RUNTIME" image rm -f "$WRAP_TAG" >/dev/null 2>&1

# --print/--dry-run: never builds, never runs - only shows the command
wrap --print --image "heliograph-does-not-exist-anywhere:local" "https://example.invalid/x.git"
assert_eq "--print never tries to build a missing image" "0" "$RC"
assert_contains "and shows the command it would have run" \
  "heliograph-does-not-exist-anywhere:local" "$OUT"

# =============================================================================
#  decision 2: foreground by default, --detach opts into the background
# =============================================================================
# A pre-populated volume rather than a bind-mounted bare repo: heliograph.sh
# has no generic pass-through mount of its own (by design - see decision 4),
# so these use the SAME already-cloned/reuse path entrypoint.sh's own tests
# rely on (a working tree whose origin matches the URL this run is given).
# The stub start.sh sleeps, standing in for a long agent-loop run for exactly
# as long as it takes to prove which of foreground/detach genuinely blocks.
mkdir -p "$TMP/fgvol" "$TMP/bgvol"
for v in fgvol bgvol; do
  ( cd "$TMP/$v" && git init -q \
      && printf '#!/usr/bin/env bash\nsleep 20\necho STUB-SLEEP-DONE\n' > start.sh && chmod +x start.sh \
      && git remote add origin "file:///srv/repo.git" && $GIT add -A && $GIT commit -qm init ) >/dev/null 2>&1
done

FG_NAME="heliograph-wraptest-fg-$$"
"$RUNTIME" rm -f "$FG_NAME" >/dev/null 2>&1
wrap_bounded 8 --image "$IMAGE" --dockerfile "$DOCKERFILE" --volume "$TMP/fgvol" --name "$FG_NAME" \
  "file:///srv/repo.git"
assert_eq "foreground (the default) genuinely blocks - an 8s bound fires while the 20s stub is still running" \
  "124" "$RC"
"$RUNTIME" rm -f "$FG_NAME" >/dev/null 2>&1

BG_NAME="heliograph-wraptest-bg-$$"
"$RUNTIME" rm -f "$BG_NAME" >/dev/null 2>&1
wrap_bounded 8 --image "$IMAGE" --dockerfile "$DOCKERFILE" --volume "$TMP/bgvol" --detach --name "$BG_NAME" \
  "file:///srv/repo.git"
assert_eq "--detach returns well inside the same 8s bound rather than blocking" "0" "$RC"
assert_eq "and the daemon confirms a container by that name genuinely exists" "0" \
  "$("$RUNTIME" inspect "$BG_NAME" >/dev/null 2>&1; echo $?)"
assert_eq "and it is genuinely still running the 20s stub, not finished and coincidentally fast" \
  "true" "$("$RUNTIME" inspect --format '{{.State.Running}}' "$BG_NAME" 2>/dev/null)"
"$RUNTIME" rm -f "$BG_NAME" >/dev/null 2>&1

# =============================================================================
#  decision 3: a failed push must not lose the log - whole-PR review, Finding 1
# =============================================================================
# THE DEFECT, in the words of the thing that prints it: cap_push, when it
# cannot push, commits the captured log locally and says "PUSH FAILED - run
# 'git push' manually. The file is committed locally: <path>". In this
# wrapper's DEFAULT shape - foreground, no --volume - that path is inside the
# container, and `--rm` was added to every foreground run, so the container and
# the only copy of the log were deleted the instant the process exited. The
# remedy printed at that moment named a checkout that no longer existed.
#
# The triggers are ordinary: --once, `stop: yes`, Ctrl-C on the first
# foreground run the docs recommend, `docker stop`, a reboot. AGENTS.md
# constraint 2 - "a failed run still ships, and a failed push never loses a
# log" - is what makes this data loss rather than untidiness.
#
# THE FIXTURE IS A REAL FAILED PUSH, not a stub that prints the words. A real
# bare transport repo, seeded, then given a pre-receive hook that refuses every
# push. `git push --dry-run` (start.sh's own write check) does NOT invoke that
# hook, so the preflight passes exactly as it would against a healthy remote
# and the failure lands where it does in the field: on the real push, after the
# step has run and the log has been captured and committed. Confirmed by hand
# before this test was written; see the fix report.
make_pushfail_repo() {
  local bare="$1" work="$1.work"
  "$ROOT/skills/heliograph/scripts/bootstrap.sh" "$work" >/dev/null 2>&1
  printf 'id: fail-push-1\nstep: env\nenv:\ncancel:\nstop:\nnote:\n' > "$work/agent/request"
  git init -q --bare "$bare"
  ( cd "$work" && git init -q && git remote add origin "$bare" \
      && $GIT add -A && $GIT commit -qm init && $GIT push -q -u origin HEAD ) >/dev/null 2>&1
  # Installed AFTER the seed push, so the repo has a branch to clone and only
  # the container's own push is refused.
  printf '#!/bin/sh\necho "policy: this branch is protected - push refused" >&2\nexit 1\n' \
    > "$bare/hooks/pre-receive"
  chmod +x "$bare/hooks/pre-receive"
}

# --- what the wrapper composes, first ------------------------------------------
# The default shape must not carry --rm at all. --print, so this is the
# composed command itself rather than an inference from a run's behaviour.
wrap --print --image "$IMAGE" "https://example.invalid/x.git"
assert_eq "the default shape composes NO --rm - the checkout is the only copy of a failed run's log" "" \
  "$(composed_cmd "$OUT" | grep -o -- '--rm')"
assert_contains "and the container is named, so what is kept can be addressed" \
  "--name heliograph-" "$(composed_cmd "$OUT")"
# The advice has to arrive BEFORE the run: the moment it is needed, the run is
# over, cap_push's own message has scrolled past, and an operator who did not
# know the container was kept has already typed `docker rm`.
assert_contains "the recovery command is printed up front, naming this run's container" \
  "cp heliograph-" "$OUT"
assert_contains "and it names the directory the log is committed into" \
  "/home/heliograph/repo/ops-logs/" "$OUT"

# --volume: the checkout is on the host, so removing the container loses
# nothing and --rm comes back.
wrap --print --image "$IMAGE" --volume "$TMP/plainvol-rm" "https://example.invalid/x.git"
assert_contains "--volume restores --rm: the log survives on the host either way" \
  "--rm" "$(composed_cmd "$OUT")"
assert_eq "and no recovery advice is printed for a shape that does not need it" "" \
  "$(printf '%s' "$OUT" | grep -o 'NOT removed when it exits')"

# --rm as an explicit opt-in, with the cost stated rather than implied.
wrap --print --image "$IMAGE" --rm "https://example.invalid/x.git"
assert_contains "--rm still removes the container when asked for explicitly" \
  "--rm" "$(composed_cmd "$OUT")"
assert_contains "and says plainly what that costs on a failed push" \
  "captured log is committed in that checkout and nowhere else" "$OUT"

# --- and then the property itself, end to end ----------------------------------
# THE RUNTIME IS INVOKED DIRECTLY HERE, deliberately, in exactly the shape the
# assertions above just proved the wrapper composes (no --rm, --name given, no
# --volume). The reason is mechanical: this fixture is a bare repo on the host
# addressed by file://, which needs a bind mount, and heliograph.sh has no
# general-purpose mount flag by design (decision 4). Going through the wrapper
# would mean adding one just to test it. So the wrapper's own composition is
# asserted above, and the consequence of that composition is asserted here.
make_pushfail_repo "$TMP/pushfail.git"
F1_NAME="heliograph-wraptest-pushfail-$$"
"$RUNTIME" rm -f "$F1_NAME" >/dev/null 2>&1
# THE COMMAND IS THE WRAPPER'S OWN, not a hand-written imitation of it: taken
# from --print, with only the fixture's bind mount inserted before the `--`
# that ends the runtime's flags. So a change to what heliograph.sh composes -
# putting --rm back, say - genuinely changes what runs here, and this
# assertion goes red with it rather than passing against a shape the wrapper
# no longer produces. print_cmd %q-quotes every argument, which is what makes
# the line safe to hand back to a shell.
wrap --print --image "$IMAGE" --name "$F1_NAME" "file:///srv/repo.git" -- --once
f1_cmd="$(composed_cmd "$OUT")"
f1_cmd="${f1_cmd/ -- $IMAGE/ -v $TMP/pushfail.git:/srv/repo.git -- $IMAGE}"
assert_contains "the fixture mount really was inserted into the wrapper's own command" \
  "$TMP/pushfail.git:/srv/repo.git" "$f1_cmd"
f1_out="$(timeout 240 bash -c "$f1_cmd" 2>&1)"
assert_contains "the run really does reach cap_push's failed-push branch" \
  "PUSH FAILED" "$f1_out"
assert_contains "and says the log is committed locally, inside this container" \
  "/home/heliograph/repo/ops-logs/" "$f1_out"
assert_eq "the container still exists after the run has exited" "0" \
  "$("$RUNTIME" inspect "$F1_NAME" >/dev/null 2>&1; echo $?)"
# The recovery the wrapper printed, run for real against the container that
# just failed to push.
rm -rf "$TMP/f1-recovered"; mkdir -p "$TMP/f1-recovered"
( cd "$TMP/f1-recovered" && "$RUNTIME" cp "$F1_NAME:/home/heliograph/repo/ops-logs/" . ) >/dev/null 2>&1
recovered=0
for f in "$TMP/f1-recovered"/ops-logs/env-*.txt; do
  [ -f "$f" ] && recovered=$((recovered + 1))
done
assert_eq "and the captured log is recoverable from it with the printed cp command" "1" "$recovered"
assert_contains "the recovered file really is the captured log, not an empty placeholder" \
  "STEP: env" "$(cat "$TMP/f1-recovered"/ops-logs/env-*.txt 2>/dev/null)"
# THE COUNTERFACTUAL, which is what --rm did on every foreground run: remove
# the container and the same command recovers nothing at all.
"$RUNTIME" rm -f "$F1_NAME" >/dev/null 2>&1
rm -rf "$TMP/f1-after"
( "$RUNTIME" cp "$F1_NAME:/home/heliograph/repo/ops-logs/" "$TMP/f1-after" ) >/dev/null 2>&1
assert_eq "once the container is gone the log is gone with it - which is what --rm did by default" \
  "gone" "$([ -d "$TMP/f1-after" ] && echo present || echo gone)"

# =============================================================================
#  decision 4: no mounts by default - each opt-in mount states its own reason
# =============================================================================
NOMOUNT_NAME="heliograph-wraptest-nomount-$$"
"$RUNTIME" rm -f "$NOMOUNT_NAME" >/dev/null 2>&1
wrap --image "$IMAGE" --dockerfile "$DOCKERFILE" --detach --name "$NOMOUNT_NAME" "https://example.invalid/x.git"
assert_eq "a detached run with none of --volume/--token-file/--ssh returns 0" "0" "$RC"
assert_eq "and produces a container with NO mounts at all" "[]" \
  "$("$RUNTIME" inspect --format '{{json .Mounts}}' "$NOMOUNT_NAME" 2>/dev/null)"
"$RUNTIME" rm -f "$NOMOUNT_NAME" >/dev/null 2>&1

# --volume: the one stated reason is restart reuse (decision 3's mechanism)
mkdir -p "$TMP/plainvol"
VOL_NAME="heliograph-wraptest-vol-$$"
"$RUNTIME" rm -f "$VOL_NAME" >/dev/null 2>&1
wrap --image "$IMAGE" --dockerfile "$DOCKERFILE" --detach --name "$VOL_NAME" --volume "$TMP/plainvol" \
  "https://example.invalid/x.git"
vol_mounts="$("$RUNTIME" inspect --format '{{json .Mounts}}' "$VOL_NAME" 2>/dev/null)"
assert_contains "--volume mounts exactly the given host directory" "$TMP/plainvol" "$vol_mounts"
assert_contains "onto the working directory entrypoint.sh actually reads (HELIOGRAPH_WORKDIR)" \
  "/home/heliograph/repo" "$vol_mounts"
"$RUNTIME" rm -f "$VOL_NAME" >/dev/null 2>&1

# The MOUNT TARGET alone happens to equal today's Dockerfile's own default
# ($HOME/repo, with HOME=/home/heliograph) - dropping the explicit env var
# entirely is invisible against the CURRENT image, found by mutation. This
# checks the WIRING itself, independent of that coincidence, the same way
# the --ssh tag-selection assertion above does not rely on this host's own
# uid happening to match the default.
wrap --print --image "$IMAGE" --volume "$TMP/plainvol" "https://example.invalid/x.git"
assert_contains "--volume also sets HELIOGRAPH_WORKDIR explicitly, not relying on \$HOME matching by luck" \
  "-e HELIOGRAPH_WORKDIR=/home/heliograph/repo" "$OUT"

# --token-file: mounted read-only, and wired to GIT_TOKEN_FILE end to end
TOKFILE_TOKEN="heliograph-wrapper-fixture-tok-4e9a1c"
printf '%s\n' "$TOKFILE_TOKEN" > "$TMP/wraptoken"
TOK_NAME="heliograph-wraptest-tok-$$"
"$RUNTIME" rm -f "$TOK_NAME" >/dev/null 2>&1
wrap --image "$IMAGE" --dockerfile "$DOCKERFILE" --detach --name "$TOK_NAME" --token-file "$TMP/wraptoken" \
  "https://example.invalid/x.git"
tok_mounts="$("$RUNTIME" inspect --format '{{json .Mounts}}' "$TOK_NAME" 2>/dev/null)"
assert_contains "--token-file mounts the given file" "$TMP/wraptoken" "$tok_mounts"
assert_contains "read-only, not read-write" '"RW":false' "$tok_mounts"
full_inspect="$("$RUNTIME" inspect "$TOK_NAME" 2>/dev/null)"
assert_eq "and the token's VALUE never appears in inspect - only the mounted path does" "" \
  "$(printf '%s' "$full_inspect" | grep -o "$TOKFILE_TOKEN")"
"$RUNTIME" rm -f "$TOK_NAME" >/dev/null 2>&1

# end to end: the wired GIT_TOKEN_FILE is what entrypoint.sh actually reports
wrap --image "$IMAGE" --dockerfile "$DOCKERFILE" --token-file "$TMP/wraptoken" "https://example.invalid/x.git"
assert_eq "the fixture token is never printed, even while the clone fails" "" \
  "$(printf '%s' "$OUT" | grep -o "$TOKFILE_TOKEN")"
assert_contains "and entrypoint.sh names the in-container path this flag mounted it at" \
  "/run/heliograph/git-token" "$OUT"
assert_contains "and its length, not its value (proves the CONTENT reached entrypoint.sh)" \
  "(${#TOKFILE_TOKEN} chars)" "$OUT"

# =============================================================================
#  credential handling: never on this script's own command line
# =============================================================================
# GIT_TOKEN already exported in the CALLING shell - proves bare `-e NAME`
# passthrough (the value read by the runtime from ITS OWN environment) rather
# than `-e NAME=value` (the value literally in this script's argv). --print
# makes the constructed command directly observable without needing to catch
# a live process's argv mid-flight.
ENV_TOKEN="heliograph-wrapper-env-fixture-77d2"
GIT_TOKEN="$ENV_TOKEN" wrap --print --image "$IMAGE" "https://example.invalid/x.git"
assert_contains "GIT_TOKEN already in the environment is forwarded by bare name" "-e GIT_TOKEN" "$OUT"
assert_eq "and its VALUE never appears in the printed command line" "" \
  "$(printf '%s' "$OUT" | grep -o "$ENV_TOKEN")"

REPO_URL="https://example.invalid/env-repo-url.git" wrap --print --image "$IMAGE" -- --check
# "-e REPO_URL" alone CANNOT FAIL for the property it names: it is a prefix of
# "-e REPO_URL=<value>", so the very shape this assertion exists to forbid
# satisfies it. Anchored on the token that follows instead - the next thing on
# the composed line is another flag, never an "=" - and paired with a direct
# assertion that no "-e REPO_URL=" appears at all.
assert_contains "REPO_URL already in the environment is forwarded by bare name too" \
  "-e REPO_URL " "$(composed_cmd "$OUT")"
assert_eq "and never as -e REPO_URL=<value>, which would put the URL in this script's argv" "" \
  "$(printf '%s' "$OUT" | grep -o -- '-e REPO_URL=')"
assert_eq "so its value is nowhere on the composed command line" "" \
  "$(printf '%s' "$OUT" | grep -o 'env-repo-url.git')"

# =============================================================================
#  podman: --userns=keep-id, found in this task's own testing
# =============================================================================
# Not in the brief - found by hand while proving --volume/--ssh work under
# both runtimes. Rootless podman's DEFAULT user namespace remaps every non-
# root container uid to an unrelated host uid, so a bind-mounted file
# genuinely owned by the invoking host user showed up owned by something
# else entirely inside the container - confirmed directly: `stat -c '%U %u'`
# on a bind-mounted, host-owned directory read "root 0" from inside a
# rootless podman container running as heliograph (uid 1000), and git's own
# dubious-ownership refusal (CVE-2022-24765) then broke the --volume reuse
# path - silently at the time, because entrypoint.sh's own `git remote
# get-url origin` discarded stderr and reported the failure as a clone of a
# different repository. That misdiagnosis is fixed and asserted separately
# further up this file; this flag is what stops the mismatch arising at all
# under podman. The identical scenario needs nothing extra under Docker,
# which does not remap uids by default. Skipped loudly, the same way the
# whole file skips when no runtime at all is reachable, if podman
# specifically is not present here.
if ! command -v podman >/dev/null 2>&1 || ! podman info >/dev/null 2>&1; then
  t_skip 'the podman --userns=keep-id tests: podman is not reachable on this machine'
else
  wrap --print --runtime podman --image "$IMAGE" "https://example.invalid/x.git"
  assert_contains "podman gets --userns=keep-id, so a bind-mounted file's ownership survives" \
    "--userns=keep-id" "$OUT"

  wrap --print --runtime docker --image "$IMAGE" "https://example.invalid/x.git"
  assert_eq "docker is never given it - it has no such flag and does not need one" "" \
    "$(printf '%s' "$OUT" | grep -o -- '--userns=keep-id')"

  # Positive, end to end, under a REAL rootless podman container - not
  # merely the flag being present. A host directory genuinely owned by the
  # invoking user, reused through decision 3's own already-tested code path.
  mkdir -p "$TMP/podmanvol"
  ( cd "$TMP/podmanvol" && git init -q -b main \
      && printf '#!/usr/bin/env bash\necho REUSE-OK\n' > start.sh && chmod +x start.sh \
      && $GIT add -A && $GIT commit -qm init \
      && git remote add origin "file:///srv/repo.git" ) >/dev/null 2>&1
  # --build, DELIBERATELY: $IMAGE is built with $RUNTIME at the top of this file
  # (docker, when both are installed), and podman keeps a separate store. Without
  # this, podman reused whatever image of that name its store already held - on
  # this machine, one built before the entrypoint fixes below were written, so
  # every podman assertion here was quietly checking a stale image. Found exactly
  # that way: the .git-only ownership test came back with the OLD message.
  wrap --build --runtime podman --image "$IMAGE" --dockerfile "$DOCKERFILE" --volume "$TMP/podmanvol" \
    "file:///srv/repo.git"
  assert_eq "the reuse path genuinely succeeds under a real rootless podman container" "0" "$RC"
  assert_contains "recognising the checkout, rather than a silent dubious-ownership refusal" \
    "already holds a clone" "$OUT"

  # ---------------------------------------------------------------------------
  # THE .git-ONLY OWNERSHIP SPLIT - whole-PR review, Finding 10
  # ---------------------------------------------------------------------------
  # foreign_owners loops over BOTH "$dir" and "$dir/.git" because git refuses
  # on either one. Nothing asserted the second half: the ownership fixture
  # further up this file makes the WORKTREE and the .git foreign together, so
  # replacing `for p in "$dir" "$dir/.git"` with `for p in "$dir"` left the
  # whole suite green - an unasserted guard on a Critical fix, in a project
  # that has already shipped fourteen assertions that could not fail.
  #
  # The split is built WITHOUT ROOT: `podman unshare` runs in this user's own
  # namespace, where chowning to 4242 is permitted and shows up as a
  # subordinate uid on the host. Under --userns=keep-id the worktree (this
  # user's own) maps to the container's uid and MATCHES, while .git does not -
  # which is exactly the state that has to be diagnosed and could not be built
  # any other way here.
  mkdir -p "$TMP/splitvol"
  ( cd "$TMP/splitvol" && git init -q -b main \
      && printf '#!/usr/bin/env bash\necho SPLIT-OK\n' > start.sh && chmod +x start.sh \
      && $GIT add -A && $GIT commit -qm init \
      && git remote add origin "file:///srv/repo.git" ) >/dev/null 2>&1
  if ! podman unshare chown 4242 "$TMP/splitvol/.git" >/dev/null 2>&1; then
    t_skip 'the .git-only ownership split: podman unshare could not chown a path here'
  else
    wrap --runtime podman --image "$IMAGE" --dockerfile "$DOCKERFILE" --volume "$TMP/splitvol" \
      "file:///srv/repo.git"
    assert_eq "a checkout whose .git alone is foreign-owned is refused, not reused" "1" "$RC"
    assert_contains "and it is diagnosed as an ownership mismatch" \
      "The cause is an OWNERSHIP MISMATCH, not a different repository" "$OUT"
    # THE SPLIT ITSELF: the .git line must be there, and the worktree line must
    # NOT - the worktree genuinely matches, and claiming otherwise would be a
    # false statement about the operator's own directory. This pair is what
    # dies if the .git half of foreign_owners' loop is ever dropped.
    assert_contains "naming the .git directory as the foreign-owned path" \
      "/home/heliograph/repo/.git is owned by uid" "$OUT"
    assert_eq "and NOT the working tree, which this container's user really does own" "" \
      "$(printf '%s' "$OUT" | grep -o '/home/heliograph/repo is owned by uid')"
    assert_contains "git's own error is quoted here too, not inferred" \
      "detected dubious ownership in repository at" "$OUT"
    assert_contains "and the checkout is protected, not offered up for deletion" \
      "DO NOT empty or delete" "$OUT"
    # Restore ownership so the EXIT trap can actually remove $TMP: a .git owned
    # by a subordinate uid cannot be unlinked into by this user.
    podman unshare chown -R 0 "$TMP/splitvol" >/dev/null 2>&1
  fi
fi

# =============================================================================
#  SSH forwarding - not optional, and the ownership problem
# =============================================================================
if ! command -v ssh-agent >/dev/null 2>&1 || ! command -v ssh-keygen >/dev/null 2>&1; then
  t_skip 'the --ssh end-to-end tests: no ssh-agent/ssh-keygen on this machine to build a fixture'
else
  # --ssh without SSH_AUTH_SOCK set at all: refuse, rather than silently
  # mounting nothing and leaving the operator to discover that later.
  SAVED_AUTH_SOCK="${SSH_AUTH_SOCK:-}"
  unset SSH_AUTH_SOCK
  wrap --image "$IMAGE" --dockerfile "$DOCKERFILE" --ssh "https://example.invalid/x.git"
  assert_eq "--ssh with no SSH_AUTH_SOCK set refuses" "1" "$RC"
  assert_contains "and names the problem" "SSH_AUTH_SOCK is not set" "$OUT"
  [ -n "$SAVED_AUTH_SOCK" ] && export SSH_AUTH_SOCK="$SAVED_AUTH_SOCK"

  # A real, disposable agent and key - not a stand-in. socket ownership is
  # exactly what this section proves, so it needs a socket that really is
  # owned the way a forwarded operator's agent would be.
  eval "$(ssh-agent -s)" >/dev/null

  # The MECHANISM, not just the end-to-end symptom - --print, so no build is
  # needed. Deliberately independent of this test host's own uid: on a
  # machine whose uid happens to be 1000 (the image's own default), removing
  # the uid-matching logic entirely still "works" by coincidence, which is
  # exactly what happened here on first mutation - see the task report. This
  # asserts the TAG heliograph.sh actually selects tracks the SOCKET's own
  # measured owner, not the fact that forwarding merely succeeds.
  sockuid_expect="$(stat -c %u "$SSH_AUTH_SOCK" 2>/dev/null || id -u)"
  wrap --print --image "$IMAGE" --ssh "https://example.invalid/x.git"
  assert_contains "--ssh resolves its image tag from the SOCKET's own measured owning uid" \
    "$IMAGE-uid$sockuid_expect" "$OUT"
  # THAT ASSERTION ALONE STILL CANNOT DISCRIMINATE, and saying so is cheaper
  # than pretending otherwise: this fixture's agent is started by this test
  # user, so `stat -c %u` on its socket is always `id -u`, and a wrapper that
  # ignored the socket entirely and used `id -u` would satisfy it exactly.
  # A socket owned by SOMEONE ELSE is what tells the two apart, and building
  # one needs no root: `podman unshare chown` gives the socket to a
  # subordinate uid, which `stat` on the host reads back as a number that is
  # NOT this user's. Skipped, counted, where podman is not available.
  if ! command -v podman >/dev/null 2>&1 || ! podman info >/dev/null 2>&1; then
    t_skip 'the --ssh foreign-socket tag discrimination: podman unshare is needed to build a socket this user does not own'
  else
    mkdir -p "$TMP/foreignsock"
    FOREIGN_SOCK="$TMP/foreignsock/agent.sock"
    FOREIGN_AGENT="$(ssh-agent -a "$FOREIGN_SOCK" -s 2>/dev/null)"
    FOREIGN_PID="$(printf '%s' "$FOREIGN_AGENT" | sed -n 's/.*SSH_AGENT_PID=\([0-9]*\).*/\1/p')"
    if [ ! -S "$FOREIGN_SOCK" ] || ! podman unshare chown 4242 "$FOREIGN_SOCK" >/dev/null 2>&1; then
      t_skip 'the --ssh foreign-socket tag discrimination: could not build a foreign-owned agent socket here'
    else
      foreign_uid="$(stat -c %u "$FOREIGN_SOCK" 2>/dev/null)"
      # The fixture is only worth anything if it really is a uid this user is
      # not - asserted, not assumed, so a podman that silently did nothing
      # cannot leave the real assertion passing for the wrong reason.
      assert_eq "the fixture socket really is owned by a uid this user is not" "different" \
        "$([ -n "$foreign_uid" ] && [ "$foreign_uid" != "$(id -u)" ] && echo different || echo same)"
      SSH_AUTH_SOCK="$FOREIGN_SOCK" wrap --print --image "$IMAGE" --ssh "https://example.invalid/x.git"
      assert_contains "the tag tracks THAT uid, not this shell's own - the measurement is load-bearing" \
        "$IMAGE-uid$foreign_uid" "$OUT"
      assert_eq "and specifically not this user's uid, which is what a dropped measurement would give" "" \
        "$(printf '%s' "$OUT" | grep -o -- "-uid$(id -u) ")"
      podman unshare chown -R 0 "$TMP/foreignsock" >/dev/null 2>&1
    fi
    [ -n "$FOREIGN_PID" ] && kill "$FOREIGN_PID" >/dev/null 2>&1
  fi

  ssh-keygen -q -t ed25519 -N '' -f "$TMP/sshtestkey"
  ssh-add "$TMP/sshtestkey" >/dev/null 2>&1
  HOST_FP="$(ssh-add -l 2>/dev/null | awk '{print $2}')"

  mkdir -p "$TMP/sshvol"
  ( cd "$TMP/sshvol" && git init -q \
      && printf '#!/usr/bin/env bash\nprintf "AGENT_KEYS: "\nssh-add -l\n' > start.sh && chmod +x start.sh \
      && git remote add origin "file:///srv/repo.git" && $GIT add -A && $GIT commit -qm init ) >/dev/null 2>&1

  if [ -z "$HOST_FP" ]; then
    t_skip 'the --ssh positive/contrast tests: could not add a fixture key to a local ssh-agent'
  else
    wrap --image "$IMAGE" --dockerfile "$DOCKERFILE" --ssh --volume "$TMP/sshvol" "file:///srv/repo.git"
    assert_contains "the forwarded, uid-matched socket is usable as the heliograph user inside the container" \
      "$HOST_FP" "$OUT"

    # Contrast, bypassing the wrapper entirely: an image built for a
    # deliberately WRONG uid, given the exact same bind-mounted socket. If
    # this also worked, the positive result above would be an accident of
    # this host's own uid rather than proof the matching step does anything.
    WRONG_UID=13345
    BAD_TAG="heliograph-wraptest:local-baduid"
    if "$RUNTIME" build -f "$DOCKERFILE" -t "$BAD_TAG" --build-arg "HELIOGRAPH_UID=$WRONG_UID" "$DOCKER_DIR" \
        >/dev/null 2>&1; then
      badout="$(timeout 20 "$RUNTIME" run --rm \
        -v "$SSH_AUTH_SOCK:/run/heliograph/ssh-agent.sock" -e SSH_AUTH_SOCK=/run/heliograph/ssh-agent.sock \
        -v "$TMP/sshvol:/home/heliograph/repo" -e HELIOGRAPH_WORKDIR=/home/heliograph/repo \
        "$BAD_TAG" "file:///srv/repo.git" 2>&1)"
      assert_eq "a uid-MISMATCHED image cannot use the same forwarded socket - the matching step is load-bearing" \
        "" "$(printf '%s' "$badout" | grep -o "$HOST_FP")"
      "$RUNTIME" image rm -f "$BAD_TAG" >/dev/null 2>&1
    else
      t_skip "the uid-mismatch contrast: could not build an image at uid $WRONG_UID on this machine"
    fi
  fi

  ssh-agent -k >/dev/null 2>&1
  unset SSH_AUTH_SOCK SSH_AGENT_PID
fi

"$RUNTIME" image rm -f "$IMAGE-uid$(id -u)" >/dev/null 2>&1
# The podman --userns=keep-id section above builds its own uid-tagged image
# directly through the wrapper with --runtime podman, independent of
# whichever runtime this file's own $RUNTIME auto-detected (docker, if both
# are present) - so it needs its own cleanup line, not just the one above.
if command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; then
  podman image rm -f "$IMAGE-uid$(id -u)" >/dev/null 2>&1
fi

# --- the containers this file's own runs leave behind ---------------------------
# NEW SINCE Finding 1: heliograph.sh no longer adds --rm to a foreground run
# with no --volume, deliberately, because that is how a failed push's log
# survives. Correct in the field and untidy in a test suite, which starts
# dozens of such runs - so they are cleaned up here, by ANCESTOR IMAGE rather
# than by name. Filtering on the "heliograph-" name prefix the wrapper now
# defaults to would risk removing a real operator's kept container on a
# developer's own machine, which is precisely the thing that fix exists to
# stop. Every image named here is one this file built itself.
for stale_image in "$IMAGE" "$IMAGE-uid$(id -u)" "heliograph-wraptest:local" \
                   "heliograph-toolkit-test:local-ownermismatch" "my-team/heliograph:local"; do
  for stale_runtime in "$RUNTIME" podman docker; do
    command -v "$stale_runtime" >/dev/null 2>&1 || continue
    "$stale_runtime" info >/dev/null 2>&1 || continue
    stale_ids="$("$stale_runtime" ps -aq --filter "ancestor=$stale_image" 2>/dev/null)"
    [ -n "$stale_ids" ] && "$stale_runtime" rm -f $stale_ids >/dev/null 2>&1
  done
done

t_summary
