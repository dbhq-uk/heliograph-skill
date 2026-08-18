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

# run_in <cmd...> - runs in a fresh, disposable container, STDOUT only.
# A fresh container per call rather than one long-lived one: nothing here
# needs state to survive between assertions, and a fresh container is the only
# way to be sure one assertion's command cannot leave something behind that
# makes a later assertion pass for the wrong reason.
run_in() {
  "$RUNTIME" run --rm "$IMAGE" "$@"
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

t_summary
