#!/usr/bin/env bash
# =============================================================================
#  heliograph.sh - the docker run, turned into one line an operator can be given
# =============================================================================
#     heliograph.sh [wrapper options] <repo-url> [-- start.sh args...]
#     REPO_URL=<repo-url> heliograph.sh [wrapper options] [-- start.sh args...]
#
#  This wraps entrypoint.sh's own contract, unchanged - it does not add a URL
#  argument of its own, does not check for a credential embedded in it, does
#  not decide whether an existing checkout should be reused. All of that is
#  entrypoint.sh's job (task 2), which this file never re-implements: past its
#  own flags, everything on the command line is passed straight through to
#  `$RUNTIME run ... $IMAGE <that>`, opaque to this script.
#
#  RUNTIME: docker or podman, whichever is on PATH with a daemon/store that
#  answers `info` - the same probe tests/test-container.sh already uses.
#  Nothing below reaches for a flag one of the two lacks: `run`, `build`,
#  `create`, `image inspect`, `-d`, `-v`, `-e`, `--build-arg`, `--name` and
#  `--rm` are all part of the CLI surface podman deliberately mirrors from
#  docker. Confirmed by hand against a real podman 4.9.3 (rootless) install,
#  not assumed - see the task report for exactly what was run.
#
#  FOUR DECISIONS THIS FILE MAKES, each with its reasoning kept next to the
#  code that implements it rather than only here:
#
#    1. BUILD THE IMAGE IF IT IS MISSING (see ensure_image). The Dockerfile
#       ships in this same directory, so building it is not a guess the way
#       reusing an unknown checkout would be - there is only one Dockerfile
#       this script would ever build. --no-build switches to the refuse-and-
#       say-so behaviour, for a caller that wants tight control over when a
#       build happens (CI, a shared box); --build forces a rebuild even when
#       the tag already exists, so a Dockerfile change is not silently stuck
#       behind a stale cached tag with the same name.
#
#    2. FOREGROUND BY DEFAULT (see the RUN_ARGS assembly below). The
#       likeliest first-run failures - a bad credential, an unreachable URL,
#       a branch that does not exist - happen inside entrypoint.sh's and
#       start.sh's own preflight, in the first few seconds, and this whole
#       toolkit's standing style is to fail loud rather than let a failure
#       sit unnoticed (GIT_TERMINAL_PROMPT=0's own comment: "fails in about
#       three seconds" rather than hanging silently). A detached container
#       that fails at startup is invisible until an operator thinks to run
#       `docker logs`. --detach/-d opts into the background long-running
#       shape once an operator has confirmed a run is healthy.
#
#    3. NOTHING BESPOKE FOR THE LOG DIRECTORY. ops-logs/ already has an escape
#       mechanism that has nothing to do with this wrapper: run.sh commits and
#       pushes it (references/runner.md - "the log is the deliverable, and
#       committing it is how it gets out of an environment you cannot reach").
#       A container that is removed on exit does not lose anything that
#       matters, because what matters already left over git before that
#       happened. Persisting the WHOLE working tree (ops-logs/ included)
#       across restarts is exactly what --volume is for, reusing
#       entrypoint.sh's already-tested reuse/pull behaviour rather than
#       inventing a second, narrower mechanism for one subdirectory of it.
#
#    4. NO MOUNTS BY DEFAULT. The spec's principle is that the container
#       clones rather than mounts, and a plain run with none of --volume,
#       --token-file or --ssh below produces a container with an empty Mounts
#       list - confirmed in tests/test-container.sh, not asserted on trust.
#       Each of the three opt-in mounts states its own reason at its own
#       flag, rather than being bundled into a single generic --mount:
#         --volume HOSTDIR   persistence across a restart (decision 3, above)
#         --token-file PATH  the credential mitigation docker inspect cannot
#                             see (see CREDENTIAL HANDLING below)
#         --ssh              the agent socket transport.md prefers (see SSH
#                             FORWARDING below) - the one mount this file does
#                             not treat as optional, because Dockerfile task 1
#                             ships openssh-client on the stated understanding
#                             that offering the socket is this wrapper's job.
#
#  CREDENTIAL HANDLING. `docker inspect`/`podman inspect` shows every `-e`
#  value to anyone who can talk to the daemon - entrypoint.sh's own usage text
#  says so, and tests/test-container.sh proves it both ways. This file never
#  makes that worse by putting a credential's VALUE on ITS OWN command line
#  either: REPO_URL, GIT_TOKEN, GIT_AUTH_HEADER and GIT_TOKEN_USER, if already
#  exported in the operator's shell, are forwarded with bare `-e NAME` (no
#  `=value`) - the runtime reads the value from this process's own
#  environment, so it is never typed, logged in shell history, or present in
#  this script's own argv. --token-file is the safer path made easy: one flag
#  bind-mounts a file read-only and points GIT_TOKEN_FILE at it, which is the
#  one credential mechanism that does NOT appear in `docker inspect` (only the
#  path does - a path is not a secret). Nothing here composes a `-e
#  GIT_TOKEN=<value>` for the operator; that shape is not offered by design,
#  not merely undocumented.
#
#  SSH FORWARDING, and the ownership problem. `ssh-agent`'s own socket is
#  created mode 0600, owned by whoever ran it - `connect()` to it is refused
#  to any other uid, directory traversal included. Bind-mounting it unchanged
#  into a container whose `heliograph` user is a fixed uid 1000 (Dockerfile's
#  default) only helps when the operator's own uid happens to be 1000 too.
#  --ssh instead resolves the SOCKET'S OWNING UID (via `stat`, falling back to
#  this shell's own uid if that fails) and builds - or reuses a cached build
#  of - the image with `--build-arg HELIOGRAPH_UID=<that-uid>`, tagged
#  distinctly (IMAGE-uid<N>), so the in-container `heliograph` user genuinely
#  owns the same uid the socket was created under. This runs through the same
#  ensure_image build-or-refuse logic as decision 1, not a special case: a
#  missing uid-tagged image is built (or refused, under --no-build) exactly
#  like a missing default one is. Proved end to end against a real ssh-agent
#  and a real key, and proved BROKEN when the uid does not match - see the
#  task report for both transcripts.
#
#  A LIMIT THIS FILE DOES NOT SOLVE: --volume has the identical ownership
#  problem (uid 1000 needs write access to whatever host directory is given)
#  and this file does not extend the uid-matching machinery to it. --ssh's
#  requirement was stated as not-optional; --volume's was not, and solving it
#  automatically would mean guessing which of two possibly-different uids
#  (the volume directory's owner, the ssh socket's owner) a combined
#  `--volume --ssh` run should build for. An operator who needs both: build
#  for the uid that matters with `--image` naming a tag of their own and
#  `docker build --build-arg HELIOGRAPH_UID=...` by hand, or chown the host
#  directory once. Documented here rather than silently unsolved.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RUNTIME=""
FORCE_RUNTIME=""
IMAGE="heliograph-toolkit:local"
DOCKERFILE="$HERE/Dockerfile"
BUILD_MODE="auto"   # auto | force | refuse
DETACH=0
NAME=""
VOLUME_HOST=""
TOKEN_FILE=""
FORWARD_SSH=0
DRY_RUN=0

# Fixed, wrapper-chosen in-container paths - never derived from the host's
# own paths, so nothing about the operator's filesystem layout leaks into the
# container's environment beyond what each flag explicitly opts into.
WORKDIR_CONTAINER="/home/heliograph/repo"
SSH_SOCK_CONTAINER="/run/heliograph/ssh-agent.sock"
TOKEN_FILE_CONTAINER="/run/heliograph/git-token"

usage() {
  cat <<'USAGE'
usage: heliograph.sh [options] <repo-url> [-- start.sh args...]
   or: REPO_URL=<repo-url> heliograph.sh [options] [-- start.sh args...]

Wraps `docker run`/`podman run` for the heliograph toolkit image: everything
past this script's own options is passed to entrypoint.sh untouched, exactly
as if it had been given directly on the runtime's own command line. This file
never inspects, validates or rewrites the URL or any start.sh argument - that
refusal (a credential embedded in the URL, REPO_URL and a positional URL
together) is entrypoint.sh's job (task 2), unchanged.

Wrapper options (must come first; use -- to separate them from a start.sh
argument that itself begins with a dash, e.g. --branch with REPO_URL set):
  --runtime docker|podman   force a runtime instead of auto-detecting
  --image TAG               image tag to run or build (default heliograph-toolkit:local)
  --dockerfile PATH         Dockerfile to build from (default: alongside this script)
  --build                   rebuild the image even if the tag already exists
  --no-build                refuse to build; error out if the image is missing
  --detach, -d              run detached; print the container id and return
  --name NAME                container name, passed through
  --volume HOSTDIR          bind-mount HOSTDIR onto the working directory, so a
                             restart reuses the checkout instead of re-cloning
                             (opt-in - see this file's own header comment)
  --token-file PATH         bind-mount PATH read-only and set GIT_TOKEN_FILE to
                             it - the credential path docker/podman inspect
                             cannot see
  --ssh                     forward $SSH_AUTH_SOCK; builds or reuses an image
                             whose heliograph user's uid matches the socket's
                             owner, without which the forwarded agent cannot
                             be used
  --print, --dry-run        print the run command instead of executing it
  -h, --help                 this text

REPO_URL, GIT_TOKEN, GIT_AUTH_HEADER and GIT_TOKEN_USER, if already exported
in this shell, are forwarded to the container by NAME only (`-e NAME`, never
`-e NAME=value`) - their values never appear on this script's own command
line. --token-file is the recommended way to supply a token: unlike GIT_TOKEN
or GIT_AUTH_HEADER passed with `-e`, its value never appears in `docker
inspect`/`podman inspect` at all, only the mounted path does.
USAGE
}

# print_cmd <argv...> - a shell-quoted preview of a command about to run,
# used both for --print/--dry-run and for the command this suggests under
# --no-build when the image is missing. %q rather than a plain space-join so
# a host path containing a space is shown as something safe to paste back.
print_cmd() {
  local first=1 a
  for a in "$@"; do
    if [ "$first" = 1 ]; then printf '%s' "$a"; first=0; else printf ' %q' "$a"; fi
  done
  printf '\n'
}

# --- option parsing ------------------------------------------------------------
# Wrapper flags only, and only before the first token that is not one of them.
# That first remaining token - a repo URL, a start.sh flag, or (with REPO_URL
# already set) the first start.sh argument - and everything after it is
# opaque CMD_ARGS, handed to the runtime's own `run ... $IMAGE` unexamined.
# Mirrors start.sh's own `--) shift; AGENT_ARGS=("$@"); break` for the same
# reason: a start.sh argument that itself starts with a dash (--branch, with
# REPO_URL already set) needs an explicit way to say "wrapper parsing ends
# here" rather than being mistaken for one of this script's own flags.
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --runtime)
      FORCE_RUNTIME="${2:-}"
      [ -z "$FORCE_RUNTIME" ] && { echo "--runtime requires docker or podman" >&2; exit 2; }
      shift ;;
    --image)
      IMAGE="${2:-}"
      [ -z "$IMAGE" ] && { echo "--image requires a tag" >&2; exit 2; }
      shift ;;
    --dockerfile)
      DOCKERFILE="${2:-}"
      [ -z "$DOCKERFILE" ] && { echo "--dockerfile requires a path" >&2; exit 2; }
      shift ;;
    --build) BUILD_MODE="force" ;;
    --no-build) BUILD_MODE="refuse" ;;
    --detach|-d) DETACH=1 ;;
    --name)
      NAME="${2:-}"
      [ -z "$NAME" ] && { echo "--name requires a value" >&2; exit 2; }
      shift ;;
    --volume)
      VOLUME_HOST="${2:-}"
      [ -z "$VOLUME_HOST" ] && { echo "--volume requires a host directory" >&2; exit 2; }
      shift ;;
    --token-file)
      TOKEN_FILE="${2:-}"
      [ -z "$TOKEN_FILE" ] && { echo "--token-file requires a path" >&2; exit 2; }
      shift ;;
    --ssh) FORWARD_SSH=1 ;;
    --print|--dry-run) DRY_RUN=1 ;;
    --) shift; break ;;
    -*)
      echo "heliograph.sh: unknown option: $1" >&2
      echo "  (wrapper options must come first - use -- before a start.sh argument" >&2
      echo "  that begins with a dash, such as --branch with REPO_URL already set)" >&2
      exit 2 ;;
    *) break ;;
  esac
  shift
done
CMD_ARGS=("$@")

# --- the runtime -----------------------------------------------------------
# Same probe tests/test-container.sh already uses: on PATH, and its `info`
# actually answers - a stale/unreachable daemon or a rootless podman store
# that has never been initialised both fail `info`, not just `command -v`.
detect_runtime() {
  if [ -n "$FORCE_RUNTIME" ]; then
    if ! command -v "$FORCE_RUNTIME" >/dev/null 2>&1; then
      echo "heliograph.sh: --runtime $FORCE_RUNTIME was given but it is not on PATH" >&2
      exit 1
    fi
    if ! "$FORCE_RUNTIME" info >/dev/null 2>&1; then
      echo "heliograph.sh: --runtime $FORCE_RUNTIME is on PATH but 'info' did not answer -" >&2
      echo "  is its daemon (docker) or store (podman) actually up?" >&2
      exit 1
    fi
    RUNTIME="$FORCE_RUNTIME"
    return 0
  fi
  local candidate
  for candidate in docker podman; do
    if command -v "$candidate" >/dev/null 2>&1 && "$candidate" info >/dev/null 2>&1; then
      RUNTIME="$candidate"
      return 0
    fi
  done
  echo "heliograph.sh: no container runtime is reachable (checked: docker, podman -" >&2
  echo "  neither is on PATH with a daemon/store that answers 'info')." >&2
  exit 1
}
detect_runtime

# --- decision 1: build if absent, refuse or force on request -------------------
# tag: the image to ensure exists. build_args: zero or more KEY=VALUE pairs
# for --build-arg, already resolved by the caller (only --ssh supplies any).
ensure_image() {
  local tag="$1"; shift
  local -a build_args=("$@")
  local -a build_cmd=("$RUNTIME" build -f "$DOCKERFILE" -t "$tag")
  local a
  for a in ${build_args[@]+"${build_args[@]}"}; do
    build_cmd+=(--build-arg "$a")
  done
  build_cmd+=("$(dirname "$DOCKERFILE")")

  local exists=1
  "$RUNTIME" image inspect "$tag" >/dev/null 2>&1 && exists=0

  # Reuse silently: already there, and neither --build nor --no-build changes
  # that outcome for an image that already exists.
  if [ "$exists" -eq 0 ] && [ "$BUILD_MODE" != "force" ]; then
    return 0
  fi

  if [ "$exists" -ne 0 ] && [ "$BUILD_MODE" = "refuse" ]; then
    echo "heliograph.sh: no image tagged $tag, and --no-build was given. Build it first:" >&2
    printf '  ' >&2
    print_cmd "${build_cmd[@]}" >&2
    exit 1
  fi

  if [ "$exists" -eq 0 ]; then
    echo "heliograph.sh: rebuilding $tag (--build was given) ..."
  else
    echo "heliograph.sh: no image tagged $tag - building it now:"
  fi
  print_cmd "${build_cmd[@]}"
  if ! "${build_cmd[@]}"; then
    echo "heliograph.sh: build of $tag failed - see the output above." >&2
    exit 1
  fi
}

# --- decision 4 / SSH forwarding: resolve the image tag and mounts -------------
FINAL_IMAGE="$IMAGE"
declare -a BUILD_ARGS=()
declare -a RUN_ARGS=(run)

if [ "$FORWARD_SSH" -eq 1 ]; then
  if [ -z "${SSH_AUTH_SOCK:-}" ]; then
    echo "heliograph.sh: --ssh was given but SSH_AUTH_SOCK is not set in this shell." >&2
    echo "  Start or forward an agent first - 'eval \$(ssh-agent) && ssh-add' locally," >&2
    echo "  or 'ssh -A' onto this host if the agent lives elsewhere." >&2
    exit 1
  fi
  if [ ! -S "$SSH_AUTH_SOCK" ]; then
    echo "heliograph.sh: --ssh was given but SSH_AUTH_SOCK ($SSH_AUTH_SOCK) is not a" >&2
    echo "  socket. Confirm the agent is still running." >&2
    exit 1
  fi
  SSH_AUTH_SOCK_HOST="$SSH_AUTH_SOCK"
  sock_uid="$(stat -c %u "$SSH_AUTH_SOCK_HOST" 2>/dev/null)"
  if [ -z "$sock_uid" ]; then
    sock_uid="$(id -u)"
    echo "heliograph.sh: could not read $SSH_AUTH_SOCK_HOST's owner directly - falling" >&2
    echo "  back to this shell's own uid ($sock_uid). If that is wrong, the forwarded" >&2
    echo "  agent will not be usable as the heliograph user inside the container." >&2
  fi
  FINAL_IMAGE="${IMAGE}-uid${sock_uid}"
  BUILD_ARGS+=("HELIOGRAPH_UID=$sock_uid")
  RUN_ARGS+=(-v "$SSH_AUTH_SOCK_HOST:$SSH_SOCK_CONTAINER" -e "SSH_AUTH_SOCK=$SSH_SOCK_CONTAINER")
fi

if [ -n "$VOLUME_HOST" ]; then
  RUN_ARGS+=(-v "$VOLUME_HOST:$WORKDIR_CONTAINER" -e "HELIOGRAPH_WORKDIR=$WORKDIR_CONTAINER")
fi

if [ -n "$TOKEN_FILE" ]; then
  if [ ! -e "$TOKEN_FILE" ]; then
    echo "heliograph.sh: --token-file $TOKEN_FILE does not exist." >&2
    exit 1
  fi
  RUN_ARGS+=(-v "$TOKEN_FILE:$TOKEN_FILE_CONTAINER:ro" -e "GIT_TOKEN_FILE=$TOKEN_FILE_CONTAINER")
fi

# Bare `-e NAME` passthrough for whatever the operator already exported -
# never `-e NAME=value`, so a credential's actual value is never this
# script's own argv. Skip GIT_TOKEN_FILE here if --token-file already set it
# above to a different (in-container) value; the explicit flag wins.
for var in REPO_URL GIT_TOKEN GIT_AUTH_HEADER GIT_TOKEN_USER; do
  if [ -n "${!var:-}" ]; then
    RUN_ARGS+=(-e "$var")
  fi
done
if [ -z "$TOKEN_FILE" ] && [ -n "${GIT_TOKEN_FILE:-}" ]; then
  RUN_ARGS+=(-e GIT_TOKEN_FILE)
fi

# --- decision 2: foreground by default ------------------------------------------
if [ "$DETACH" -eq 1 ]; then
  RUN_ARGS+=(--detach)
else
  # --rm only for the foreground shape: a detached container that exits
  # unexpectedly is exactly the case an operator needs `docker logs` on
  # afterwards, and --rm would have already thrown that away.
  RUN_ARGS+=(--rm)
fi
[ -n "$NAME" ] && RUN_ARGS+=(--name "$NAME")

RUN_ARGS+=("$FINAL_IMAGE")
RUN_ARGS+=(${CMD_ARGS[@]+"${CMD_ARGS[@]}"})

FULL_CMD=("$RUNTIME" "${RUN_ARGS[@]}")

if [ "$DRY_RUN" -eq 1 ]; then
  print_cmd "${FULL_CMD[@]}"
  exit 0
fi

ensure_image "$FINAL_IMAGE" ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"}

# exec, not a child: the same reason entrypoint.sh execs start.sh - a signal
# sent to this script (an operator's Ctrl-C on a foreground run) has to reach
# the runtime client directly, which is what forwards it into the container.
exec "${FULL_CMD[@]}"
