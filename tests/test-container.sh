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
  printf 'skip unreadable GIT_TOKEN_FILE test: running as root, where mode 000 is still readable\n'
fi

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

t_summary
