#!/usr/bin/env bash
# =============================================================================
#  test-container.sh - the properties the image has to guarantee
# =============================================================================
# This is PR 3 task 1: the image only. There is no entrypoint yet (task 2 adds
# it), so every assertion here is about the image itself - what start.sh's own
# preflight would find on this machine before it ever gets a chance to clone
# anything.
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
echo "building $IMAGE from $DOCKERFILE with $RUNTIME ..."
BUILD_OUT="$("$RUNTIME" build -f "$DOCKERFILE" -t "$IMAGE" "$DOCKER_DIR" 2>&1)"
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

# --- a non-empty directory that is not a checkout is refused, not overwritten --
mkdir -p "$TMP/foreign"
echo "not a git repo" > "$TMP/foreign/unrelated-file.txt"
run_entry -v "$TMP/foreign:/home/heliograph/repo" "$IMAGE" "https://example.invalid/x.git"
assert_eq "a foreign non-empty directory blocks rather than being cloned into" "1" "$RC"
assert_contains "and says why" "not a heliograph checkout" "$OUT"
assert_eq "and it is left untouched" "not a git repo" "$(cat "$TMP/foreign/unrelated-file.txt")"

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
cid="$("$RUNTIME" create -e "GIT_TOKEN=$TOKEN" "$IMAGE" "https://example.invalid/x.git" 2>/dev/null)"
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
assert_eq "GIT_TOKEN_FILE keeps the token itself out of docker inspect" "" \
  "$("$RUNTIME" inspect "$cid" 2>/dev/null | grep -o "$TOKEN")"
"$RUNTIME" rm -f "$cid" >/dev/null 2>&1

# --- the process table: the header travels via env, never argv -----------------
# A fake `git` shadowing PATH that reports its own argv AND its own
# /proc/self/cmdline (the property that actually matters - PR 1's cap_git
# tests prove the same property for cap_git the same way, by making the fake
# git self-report rather than racing a real process's lifetime), then execs
# the real git so the clone genuinely completes against the bind-mounted bare
# repo.
mkdir -p "$TMP/fakebin" "$TMP/report"
cat > "$TMP/fakebin/git" <<'EOF'
#!/bin/sh
{
  printf 'ARGV: %s\n' "$*"
  printf 'CMDLINE: '; tr '\0' ' ' < /proc/self/cmdline; printf '\n'
  printf 'GIT_CONFIG_COUNT=%s GIT_CONFIG_KEY_0=%s GIT_CONFIG_VALUE_0=%s\n' \
    "${GIT_CONFIG_COUNT:-unset}" "${GIT_CONFIG_KEY_0:-unset}" "${GIT_CONFIG_VALUE_0:-unset}"
} >> /report/log 2>&1
exec /usr/bin/git "$@"
EOF
chmod +x "$TMP/fakebin/git"
make_transport_repo "$TMP/argv.git"
run_entry -e "GIT_TOKEN=$TOKEN" -e "PATH=/fakebin:/usr/bin:/bin" \
  -v "$TMP/fakebin:/fakebin:ro" -v "$TMP/report:/report" \
  -v "$TMP/argv.git:/srv/repo.git" "$IMAGE" "file:///srv/repo.git" --check
assert_eq "the clone under the fake git still succeeds" "0" "$RC"
report="$(cat "$TMP/report/log" 2>/dev/null)"
assert_contains "the fake git really was invoked for the clone (subject is observable)" \
  "clone" "$report"
assert_eq "the token never reaches argv" "" \
  "$(printf '%s\n' "$report" | grep '^ARGV:' | grep -o "$TOKEN")"
assert_eq "nor /proc/self/cmdline of the git process that did the cloning" "" \
  "$(printf '%s\n' "$report" | grep '^CMDLINE:' | grep -o "$TOKEN")"
EXPECTED_HDR_B64="$(printf ':%s' "$TOKEN" | base64 -w0)"
assert_contains "the header DOES travel, through GIT_CONFIG_VALUE_0 (env, mode 400), not argv" \
  "GIT_CONFIG_VALUE_0=Authorization: Basic $EXPECTED_HDR_B64" "$report"

t_summary
