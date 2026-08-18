#!/usr/bin/env bash
# =============================================================================
#  heliograph.sh - the docker run, turned into one line an operator can be given
# =============================================================================
#     heliograph.sh [wrapper options] <repo-url> [-- start.sh args...]
#     REPO_URL=<repo-url> heliograph.sh [wrapper options] [-- start.sh args...]
#
#  This wraps entrypoint.sh's own contract, unchanged - it does not add a URL
#  argument of its own, does not decide whether an existing checkout should be
#  reused. All of that is entrypoint.sh's job (task 2), which this file never
#  re-implements: past its own flags, everything on the command line is passed
#  straight through to `$RUNTIME run ... $IMAGE <that>`, opaque to this script.
#
#  ONE EXCEPTION, and it exists because of WHERE the leak happens: a value on
#  this script's command line that embeds a credential (https://user:token@...)
#  is refused HERE as well as inside the container. entrypoint.sh's own refusal
#  is about /proc/<pid>/cmdline INSIDE the container, and by the time it fires
#  the same string has already been typed into the operator's shell (history),
#  has already been this script's own world-readable /proc/<pid>/cmdline, and
#  would have been composed into `$RUNTIME run`'s argv - the host process table
#  and `docker inspect .Config.Cmd`, which no refusal inside the container can
#  reach back and undo. Refusing at the point of composition is the only place
#  that stops the runtime-side half of it, so this file refuses too, and says
#  plainly that the credential is already exposed and should be rotated. That
#  is a different fact from anything entrypoint.sh can know, not a second copy
#  of its check for its own reasons - see FOUND-URL CREDENTIALS below.
#
#  RUNTIME: docker or podman, whichever is on PATH with a daemon/store that
#  answers `info` - the same probe tests/test-container.sh already uses.
#  Nothing below reaches for a flag one of the two lacks: `run`, `build`,
#  `create`, `image inspect`, `-d`, `-v`, `-e`, `--build-arg`, `--name` and
#  `--rm` are all part of the CLI surface podman deliberately mirrors from
#  docker. Confirmed by hand against a real podman 4.9.3 (rootless) install,
#  not assumed - see the task report for exactly what was run.
#
#  ONE PODMAN-ONLY FLAG IS ADDED, deliberately, never offered to Docker:
#  `--userns=keep-id`, only when $RUNTIME is podman (see the RUN_ARGS
#  assembly below). Rootless podman remaps every non-root container uid to
#  an unrelated host uid by default, which silently broke both --volume and
#  --ssh's own uid-matching in testing - a bind-mounted file genuinely owned
#  by the invoking host user showed up owned by something else entirely
#  inside the container. This is not "a Docker-only flag" in the sense the
#  brief warns against: it is the reverse, a flag Docker has no equivalent
#  of and does not need, added only on the runtime that needs it, so the
#  single command line an operator is given still works unchanged either
#  way.
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
#       EXCEPT FOR A TAG THAT NAMES A REGISTRY, which is PULLED, not built.
#       `--image ghcr.io/org/heliograph-toolkit:v9.9.9` used to build the
#       local Dockerfile and tag the result with the published name - the
#       exact drift the publish workflow's "the image can only be what this
#       Dockerfile produces at this tag's commit" argument exists to make
#       impossible, undone at the consumer end where nobody would look for
#       it. A reference whose first segment looks like a registry host
#       (it contains a dot or a colon, or is "localhost") is therefore
#       pulled; a pull that fails is a refusal, never a silent fall back to
#       building. --build still builds, because that is an explicit
#       instruction rather than a guess, and it says what it is doing.
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
#    3. THE CONTAINER IS KEPT UNLESS THE CHECKOUT SURVIVES ELSEWHERE. This
#       used to add `--rm` to every foreground run, reasoning that "a
#       container removed on exit does not lose anything that matters,
#       because what matters already left over git before that happened".
#       That traces only the success path. cap_push exists precisely for the
#       failure one: when the push cannot be made it commits the log locally
#       and prints "PUSH FAILED - run 'git push' manually. The file is
#       committed locally: <path>". In this wrapper's DEFAULT shape -
#       foreground, no --volume - that path is inside a container `--rm`
#       deletes the instant the process exits, so the one copy of the log
#       went with it and the printed remedy named a container that no longer
#       existed. Reproduced end to end against a remote that refuses the
#       push: with --rm the log is gone, and with it omitted `docker cp
#       <name>:/home/heliograph/repo/ops-logs/ .` recovers the file.
#       The triggers are ordinary, not exotic: --once, `stop: yes`, Ctrl-C on
#       the foreground run the docs recommend for a first run, `docker stop`,
#       a host reboot. AGENTS.md constraint 2 - "a failed run still ships,
#       and a failed push never loses a log" - is the rule that decides this.
#       So `--rm` is added ONLY when the checkout survives the container's
#       death anyway (--volume was given), or when the operator opts in
#       explicitly with --rm. Otherwise the container is kept, --name is
#       DEFAULTED so this script can name it, and the recovery command is
#       printed BEFORE the run rather than after the evidence has gone.
#       Persisting the WHOLE working tree (ops-logs/ included) across
#       restarts is still exactly what --volume is for, reusing
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
#  FOUND-URL CREDENTIALS, and why the refusal is repeated here. See the
#  exception at the top of this file: composing a credentialed URL into
#  `$RUNTIME run`'s argv puts it in the HOST's process table and in `docker
#  inspect .Config.Cmd` for the container's whole life, neither of which
#  anything running inside the container can undo. So this script refuses
#  before it execs the runtime, and its message says the part entrypoint.sh
#  cannot know: by the time either refusal is read, that credential has
#  already been typed into a shell (history) and been this process's own
#  world-readable /proc/<pid>/cmdline, so it should be treated as compromised
#  and rotated, not merely re-passed a safer way. The detection is the same
#  two rules entrypoint.sh's mask_secrets applies (userinfo carrying a colon
#  on any scheme; any userinfo at all on http/https), written with bash's own
#  parameter expansion rather than a third copy of the sed, so a host whose
#  sed lacks GNU's `I` flag cannot turn the check into a false refusal of
#  every URL. An ssh URL's `git@host` is a username, not a secret, and is not
#  refused - by either file.
#
#  REPO_URL ALREADY EXPORTED IS NOT FORWARDED WHEN A URL WAS ALSO TYPED.
#  entrypoint.sh refuses REPO_URL and a positional argument together, on the
#  genuine ambiguity between them. This script used to forward an exported
#  REPO_URL unconditionally, so `REPO_URL=... heliograph.sh <url>` died on a
#  refusal naming a variable the operator had not put on that command line
#  and telling them to "drop REPO_URL" - which this wrapper had added. The
#  typed URL wins, REPO_URL is left behind, and a line on stderr says so.
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
#  A LIMIT THIS FILE DIAGNOSES RATHER THAN SOLVES: --volume has the identical
#  ownership problem (the container's uid needs write access to whatever
#  host directory is given), and --ssh's own image-rebuilding uid-matching
#  machinery is deliberately NOT extended to it. Three reasons, weighed
#  again when the whole-PR review found that a --volume uid mismatch was
#  being MISDIAGNOSED (as a clone of a different repository, with advice to
#  empty the directory), which is the part that actually needed fixing:
#    - a combined `--volume --ssh` run has two possibly-different uids (the
#      volume directory's owner, the ssh socket's owner) and no principled
#      way to choose between them;
#    - the two failures are not the same shape. An ssh-agent socket is mode
#      0600, so a uid mismatch makes --ssh impossible outright; a --volume
#      directory is usually 0755, and what is actually needed is WRITE
#      access, which many host directories already grant;
#    - auto-matching would silently pick the container's user identity from
#      whatever happens to own a path an operator pointed at, which is a
#      surprise worth avoiding on a system-owned directory.
#  What was missing was never the automation - it was a correct diagnosis.
#  entrypoint.sh now names an ownership mismatch as one, with the uid on
#  each side and the exact --build-arg line for the uid that owns the
#  directory. Under PODMAN specifically, --userns=keep-id (above) happens to
#  cover the common case anyway - a --volume directory owned by the person
#  who actually ran this script, which is by far the usual shape - because
#  it maps the container's uid to that same invoking user, not to an
#  arbitrary chosen target the way --ssh's build-arg does. It does nothing
#  for a directory owned by a THIRD uid, and nothing at all under Docker,
#  which has no such flag. An operator in either remaining case: build for
#  the uid that matters with `--image` naming a tag of their own and `docker
#  build --build-arg HELIOGRAPH_UID=...` by hand, or chown the host
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
FORCE_RM=0
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
argument that itself begins with a dash, e.g. --branch with REPO_URL set).
Every option below that takes a value refuses a value that is missing, or
that begins with a dash: `--image --help` would otherwise reach the runtime
as one of ITS flags and exit 0 having run nothing at all.
  --runtime docker|podman   force a runtime instead of auto-detecting
  --image TAG               image tag to run or build (default heliograph-toolkit:local)
  --dockerfile PATH         Dockerfile to build from (default: alongside this script)
  --build                   rebuild the image even if the tag already exists
  --no-build                refuse to build; error out if the image is missing
  --detach, -d              run detached; print the container id and return
  --name NAME                container name (defaulted, so the container this
                             run leaves behind can always be named back at you)
  --rm                      remove the container on exit even with no --volume,
                             accepting that a log committed but not pushed dies
                             with it. NOT the default: see below
  --volume HOSTDIR          bind-mount HOSTDIR (an ABSOLUTE path) onto the
                             working directory, so a restart reuses the checkout
                             instead of re-cloning - and so a log that was
                             committed but not pushed is already on the host
  --token-file PATH         bind-mount PATH (an ABSOLUTE path) read-only and set
                             GIT_TOKEN_FILE to it - the credential path
                             docker/podman inspect cannot see
  --ssh                     forward $SSH_AUTH_SOCK; builds or reuses an image
                             whose heliograph user's uid matches the socket's
                             owner, without which the forwarded agent cannot
                             be used
  --print, --dry-run        print the run command instead of executing it
  -h, --help                 this text

THE CONTAINER IS KEPT ON EXIT unless --volume was given (the checkout is on
the host, so nothing is lost) or --rm was asked for. A run whose push fails
commits the captured log inside the container's own checkout and says so; the
container has to still exist for that log to be recoverable. This script
prints the exact `cp` command, naming this run's container, before it starts.

REPO_URL, GIT_TOKEN, GIT_AUTH_HEADER and GIT_TOKEN_USER, if already exported
in this shell, are forwarded to the container by NAME only (`-e NAME`, never
`-e NAME=value`) - their values never appear on this script's own command
line. REPO_URL is the one exception: with a URL also given on the command
line it is NOT forwarded, because entrypoint.sh refuses both together and the
operator did not type it. --token-file is the recommended way to supply a
token: unlike GIT_TOKEN or GIT_AUTH_HEADER passed with `-e`, its value never
appears in `docker inspect`/`podman inspect` at all, only the mounted path
does. A credential embedded in the URL itself is refused outright, here as
well as inside the container, and treated as already compromised.
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

# require_value <flag> <what> <value> - the one gate every wrapper option that
# takes a value goes through. Refuses an EMPTY value (what each flag used to
# check for itself, six near-identical copies) and, new here, refuses a value
# that BEGINS WITH A DASH.
#
# The dash rule closes this: `heliograph.sh --image --help` exited 0 having
# run nothing at all. "--help" passes --image's own shape check further down
# (every character in it is one a real image reference is built from), so it
# became the image name, reached `image inspect --help` - which prints help
# and exits 0, so the image "existed" and nothing was built - and then
# reached `run ... --help ...`, where the runtime parsed it as ITS OWN flag,
# printed its usage and exited 0. An operator got a clean exit code and a
# wall of docker help text for a run that never happened. Any wrapper option
# value colliding with a real runtime flag does the same.
#
# Scoped to THIS WRAPPER'S OWN option values, deliberately, and no further.
# The repo URL and every start.sh argument stay opaque passthrough - they are
# entrypoint.sh's to validate, and this file re-implementing any of that is
# the thing its own header forbids.
#
# No legitimate value for any of the six is excluded: a runtime is docker or
# podman; docker/podman reject a repository or container name that does not
# begin with an alphanumeric, so neither an --image tag nor a --name can
# start with a dash; and a genuine path that does can always be written
# ./-name or absolute, which is what the message says.
require_value() {
  local flag="$1" what="$2" value="$3"
  if [ -z "$value" ]; then
    echo "heliograph.sh: $flag requires $what." >&2
    exit 2
  fi
  case "$value" in
    -*)
      echo "heliograph.sh: $flag expects $what, but got '$value', which begins with a dash" >&2
      echo "  and reads as another option. Most often that means $flag was typed with its" >&2
      echo "  value left out and the next option was swallowed as it. Passed through, a" >&2
      echo "  value like that is parsed by docker/podman as one of THEIR flags, and the" >&2
      echo "  run exits cleanly having done nothing at all - so it is refused here." >&2
      echo "  Give $flag its value; a path that genuinely begins with a dash can be" >&2
      echo "  written ./$value or as an absolute path." >&2
      exit 2 ;;
  esac
}

# require_absolute <flag> <what> <value> - the second gate, for the two flags
# whose value becomes the HOST SIDE of a bind mount.
#
# docker and podman read a `-v` source that does not begin with `/` as a NAMED
# VOLUME, not as a path, and they CREATE one on the spot rather than failing.
# So `--token-file mytoken` composed `-v mytoken:/run/heliograph/git-token:ro`
# and mounted a brand new, empty volume where the credential should have been -
# the clone then went out unauthenticated, and the only clue was a credential
# line reporting an unreadable file. `--volume somedir` is the same trap with a
# worse ending: the checkout the operator meant to keep on the host is not the
# one the container uses, so the very persistence --volume exists to provide is
# silently absent, and with it the copy of a log that a failed push leaves
# behind. Both are refused rather than resolved, in require_value's own voice
# and for its own reason: a value that quietly means something other than what
# it says is worse than a refusal that names it.
require_absolute() {
  local flag="$1" what="$2" value="$3"
  case "$value" in
    /*) return 0 ;;
  esac
  echo "heliograph.sh: $flag expects an ABSOLUTE path to $what, but got '$value'." >&2
  echo "  docker and podman read a bind-mount source that does not begin with / as a" >&2
  echo "  NAMED VOLUME rather than a path, and create it empty rather than refusing -" >&2
  echo "  so '$value' would mount an empty volume of that name instead of the file or" >&2
  echo "  directory you meant, silently. Give the absolute path, for example:" >&2
  echo "    $flag $PWD/${value#./}" >&2
  exit 2
}

# --- a credential embedded in a URL: refused before it reaches the runtime -----
# See FOUND-URL CREDENTIALS in this file's header for why this is not a second
# copy of entrypoint.sh's check for entrypoint.sh's reasons. The two rules
# below are entrypoint.sh's mask_secrets rules, written with parameter
# expansion instead of sed so no host's sed dialect can turn the check into a
# refusal of every URL:
#   1. userinfo carrying a colon, on any scheme  (https://user:token@host/...)
#   2. any userinfo at all, on http/https        (https://token@host/...)
# `git@host` on an ssh URL is a username, not a secret, and matches neither.
#
# url_userinfo <value> - what sits between "://" and the last "@" of the
# authority (everything up to the first "/"), or nothing.
url_userinfo() {
  local v="$1" rest authority
  case "$v" in
    *://*) rest="${v#*://}" ;;
    *) return 0 ;;
  esac
  authority="${rest%%/*}"
  case "$authority" in
    *@*) printf '%s' "${authority%@*}" ;;
  esac
}

url_has_credential() {
  local v="$1" userinfo
  userinfo="$(url_userinfo "$v")"
  [ -z "$userinfo" ] && return 1
  case "$userinfo" in
    *:*) return 0 ;;
  esac
  case "$v" in
    [hH][tT][tT][pP]://*|[hH][tT][tT][pP][sS]://*) return 0 ;;
  esac
  return 1
}

# mask_url_credential <value> - the same value with the secret replaced, so the
# refusal can quote what it is refusing without reprinting the credential.
# Rebuilt from measured offsets rather than a pattern substitution: a token
# containing *, ? or [ is a perfectly ordinary token and must not be read as a
# glob by the very code that is trying not to print it.
mask_url_credential() {
  local v="$1" scheme rest authority userinfo host tail
  userinfo="$(url_userinfo "$v")"
  if [ -z "$userinfo" ]; then printf '%s' "$v"; return 0; fi
  scheme="${v%%://*}"
  rest="${v#*://}"
  authority="${rest%%/*}"
  host="${authority##*@}"
  tail="${rest:${#authority}}"
  case "$userinfo" in
    *:*) printf '%s://%s:***@%s%s' "$scheme" "${userinfo%%:*}" "$host" "$tail" ;;
    *)   printf '%s://***@%s%s' "$scheme" "$host" "$tail" ;;
  esac
}

refuse_url_credential() {
  local value="$1"
  echo "heliograph.sh: that URL embeds a credential ($(mask_url_credential "$value"))." >&2
  echo "  Refused here, before it is composed into 'docker run'/'podman run', because" >&2
  echo "  passing it on would put it in the HOST's process table and in 'docker inspect'" >&2
  echo "  output (.Config.Cmd) for as long as the container exists - neither of which" >&2
  echo "  anything running inside the container can undo." >&2
  echo "  TREAT THAT CREDENTIAL AS COMPROMISED AND ROTATE IT. It has already been typed" >&2
  echo "  into this shell (and its history), and has already been this script's own" >&2
  echo "  /proc/<pid>/cmdline, which is world-readable on this machine. Refusing the run" >&2
  echo "  stops the next exposure, not the ones that have happened." >&2
  echo "  Then pass the credential separately, with a plain URL: --token-file PATH (the" >&2
  echo "  one route that never appears in 'docker inspect' at all), or GIT_TOKEN /" >&2
  echo "  GIT_TOKEN_FILE / GIT_AUTH_HEADER already exported in this shell." >&2
  exit 2
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
      require_value "$1" "docker or podman" "${2:-}"
      FORCE_RUNTIME="$2"
      shift ;;
    --image)
      require_value "$1" "a tag" "${2:-}"
      IMAGE="$2"
      # Not a full OCI reference parser (registry/repo/tag/digest grammar is
      # more than this wrapper needs to own) - just the shapes an operator
      # actually mistypes: whitespace, and anything outside the character set
      # a reference is ever built from (which also catches uppercase, since
      # docker/podman repository names are lowercase-only). Left through
      # uncaught: colon count, segment ordering, tag length - those reach
      # "$RUNTIME build"/"run" and come back as their own "invalid reference
      # format", which at least is docker/podman's real, current wording
      # rather than a guess this wrapper would need to keep in sync.
      case "$IMAGE" in
        *[!a-z0-9._/:@-]*)
          echo "heliograph.sh: --image '$IMAGE' does not look like a valid image reference." >&2
          echo "  Expected lowercase letters, digits, and . _ / : @ - only (docker/podman" >&2
          echo "  reject uppercase, and any other character, as 'invalid reference format')." >&2
          exit 2 ;;
      esac
      shift ;;
    --dockerfile)
      require_value "$1" "a path" "${2:-}"
      DOCKERFILE="$2"
      if [ ! -e "$DOCKERFILE" ]; then
        echo "heliograph.sh: --dockerfile $DOCKERFILE does not exist." >&2
        exit 1
      fi
      shift ;;
    --build) BUILD_MODE="force" ;;
    --no-build) BUILD_MODE="refuse" ;;
    --detach|-d) DETACH=1 ;;
    --rm) FORCE_RM=1 ;;
    --name)
      require_value "$1" "a container name" "${2:-}"
      NAME="$2"
      shift ;;
    --volume)
      require_value "$1" "a host directory" "${2:-}"
      require_absolute "$1" "the host directory" "$2"
      VOLUME_HOST="$2"
      # --volume takes ONE host path, never a host:target pair - the target is
      # fixed by this script (WORKDIR_CONTAINER, above), never chosen by the
      # caller. Without this, "host:target" is composed straight into
      # "-v host:target:$WORKDIR_CONTAINER" (a THREE-field mount), and
      # docker/podman refuse it with "invalid mode: <target>" - naming
      # neither --volume nor the value the operator actually gave.
      case "$VOLUME_HOST" in
        *:*)
          echo "heliograph.sh: --volume takes a single host directory, not a host:target pair -" >&2
          echo "  got '$VOLUME_HOST'. This flag always mounts onto the container's own working" >&2
          echo "  directory, which this script chooses; pass just the host-side path, e.g." >&2
          echo "  --volume /path/on/host" >&2
          exit 2 ;;
      esac
      shift ;;
    --token-file)
      require_value "$1" "a path" "${2:-}"
      require_absolute "$1" "the token file" "$2"
      TOKEN_FILE="$2"
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

# --- the one passthrough value this file does look at --------------------------
# Every element, not only the first: with REPO_URL set the first token is a
# start.sh argument rather than the URL, and a credentialed URL arriving as
# start.sh's own argument leaks identically. Checked before detect_runtime, so
# a machine with no working runtime still gets the credential message rather
# than a runtime one - the credential is the more urgent of the two facts.
for arg in ${CMD_ARGS[@]+"${CMD_ARGS[@]}"}; do
  url_has_credential "$arg" && refuse_url_credential "$arg"
done

# Was a URL given positionally? Used below to decide whether an exported
# REPO_URL should be forwarded at all. A first token beginning with a dash (or
# "--" already consumed by the parser above) is a start.sh argument, which is
# the REPO_URL-and-passthrough shape; anything else is the URL itself.
POSITIONAL_URL=0
if [ "${#CMD_ARGS[@]}" -gt 0 ]; then
  case "${CMD_ARGS[0]}" in
    -*) ;;
    *) POSITIONAL_URL=1 ;;
  esac
fi

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
# names_a_registry <tag> - docker's own rule, and the only part of a reference
# grammar this file needs: the first segment is a registry host if it contains
# a dot or a colon, or is exactly "localhost". Everything else ("ubuntu",
# "my-team/heliograph:v1", "heliograph-toolkit:local") is a local or Docker Hub
# name, which is what this wrapper builds.
names_a_registry() {
  local tag="$1" first="${1%%/*}"
  [ "$first" = "$tag" ] && return 1     # no "/" at all: never a registry
  case "$first" in
    localhost|*.*|*:*) return 0 ;;
  esac
  return 1
}

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
  # `--` before the tag, and before the image in RUN_ARGS below, for the same
  # reason: belt and braces behind require_value's dash rule. If a value that
  # begins with a dash ever reaches here again by some route that check does
  # not cover, `--` makes the runtime treat it as the positional argument it
  # is rather than as one of its own flags - which is what turned
  # `--image --help` into a clean exit 0 that ran nothing. Measured on both
  # runtimes before being relied on, exactly as this file's header demands of
  # anything it reaches for: `docker image inspect -- <tag>`, `podman image
  # inspect -- <tag>` and `docker run --rm -- <image> <cmd>` all behave
  # identically to the same command without it.
  "$RUNTIME" image inspect -- "$tag" >/dev/null 2>&1 && exists=0

  # Reuse silently: already there, and neither --build nor --no-build changes
  # that outcome for an image that already exists.
  if [ "$exists" -eq 0 ] && [ "$BUILD_MODE" != "force" ]; then
    return 0
  fi

  # A REGISTRY-QUALIFIED TAG IS PULLED, NOT BUILT (see decision 1's header
  # note). Building the local Dockerfile and tagging the result
  # ghcr.io/org/heliograph-toolkit:v9.9.9 produces an image that claims to be
  # the published one and is not - the publish workflow's whole argument is
  # that the image at a tag can only be what that tag's own commit builds, and
  # a consumer-side build silently undoes it. NAMES_A_REGISTRY is not consulted
  # when --ssh derived this tag (IMAGE-uid<N>), because that tag has never been
  # published by anyone and building it locally is the only way it can exist;
  # that case says what it is doing instead.
  if [ "$exists" -ne 0 ] && [ "$IMAGE_IS_DERIVED" -eq 0 ] && names_a_registry "$tag" \
     && [ "$BUILD_MODE" != "force" ]; then
    if [ "$BUILD_MODE" = "refuse" ]; then
      echo "heliograph.sh: no image tagged $tag here, and --no-build was given. That tag" >&2
      echo "  names a registry, so the thing to do is pull it, not build it:" >&2
      echo "    $RUNTIME pull $tag" >&2
      exit 1
    fi
    echo "heliograph.sh: no image tagged $tag here, and that tag names a registry - pulling it:"
    print_cmd "$RUNTIME" pull -- "$tag"
    if ! "$RUNTIME" pull -- "$tag"; then
      echo "heliograph.sh: pull of $tag failed - see the output above." >&2
      echo "  Refusing to build the local Dockerfile and tag the result $tag: that would" >&2
      echo "  produce an image claiming to be the published one when it is not, which is" >&2
      echo "  exactly the drift publishing from a tagged commit exists to rule out." >&2
      echo "  Either fix the pull (registry reachable, tag exists, logged in), or build" >&2
      echo "  under a name of your own with --image <your-tag>, or say --build to build" >&2
      echo "  this Dockerfile under that registry name deliberately." >&2
      exit 1
    fi
    return 0
  fi

  if [ "$exists" -ne 0 ] && [ "$BUILD_MODE" = "refuse" ]; then
    echo "heliograph.sh: no image tagged $tag, and --no-build was given. Build it first:" >&2
    printf '  ' >&2
    print_cmd "${build_cmd[@]}" >&2
    exit 1
  fi

  if [ "$IMAGE_IS_DERIVED" -eq 0 ] && names_a_registry "$tag"; then
    echo "heliograph.sh: NOTE - building $tag locally because --build was given. This tag" >&2
    echo "  names a registry, so the image that comes out will carry a published name it" >&2
    echo "  did not come from. Deliberate here; do not push it." >&2
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
# 1 once --ssh has rewritten the tag into one only a local build can satisfy.
IMAGE_IS_DERIVED=0
declare -a BUILD_ARGS=()
declare -a RUN_ARGS=(run)

# Rootless podman's DEFAULT user namespace remaps every non-root container
# uid to an unrelated subordinate host uid (/etc/subuid) - so the
# `heliograph` user (uid 1000, or whatever --ssh's build-arg set it to)
# never actually corresponds to a real host identity, and a bind-mounted
# file or directory owned by the ACTUAL host user shows up owned by
# something else entirely from inside the container. Confirmed by hand: a
# host directory owned by the invoking user showed as "root 0" inside a
# rootless podman container running as heliograph, and git's own dubious-
# ownership check (CVE-2022-24765) then refused it outright - silently at the
# time, because entrypoint.sh's `git remote get-url origin` discarded stderr
# and rendered the failure as a clone of a different repository. That half is
# fixed in entrypoint.sh (see its three-outcomes comment): an ownership
# mismatch now names itself, with the uid on each side, and never suggests
# emptying the checkout. This flag is what stops the mismatch arising at all
# under podman, which is still worth having. The identical scenario under Docker
# needs none of this: Docker does not remap uids by default, so container
# uid 1000 already IS host uid 1000. `--userns=keep-id` is podman's own,
# documented fix - it maps the CURRENT rootless user's uid to the SAME uid
# inside the container - so it is added only when podman is the runtime,
# never offered to Docker (which has no such flag and does not need one).
# This is what makes --volume and --ssh's own uid-matching (below) actually
# hold under rootless podman, not just under Docker - confirmed by hand both
# ways; see the task report.
if [ "$RUNTIME" = "podman" ]; then
  RUN_ARGS+=(--userns=keep-id)
fi

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
  IMAGE_IS_DERIVED=1
  if names_a_registry "$FINAL_IMAGE"; then
    echo "heliograph.sh: NOTE - --ssh needs an image whose heliograph user owns uid" >&2
    echo "  $sock_uid, so it uses the tag $FINAL_IMAGE, derived from --image. No registry" >&2
    echo "  publishes that tag, so it is built here from $DOCKERFILE even though the name" >&2
    echo "  looks like a published one. Do not push it." >&2
  fi
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
#
# REPO_URL is skipped when a URL was typed on this command line. Forwarding it
# regardless made entrypoint.sh refuse the run with "both REPO_URL and a
# command-line argument were given ... drop REPO_URL" - naming a variable the
# operator had merely left exported in their shell and had not put anywhere
# near this command, and telling them to drop the thing THIS SCRIPT added. The
# typed URL is the unambiguous instruction, so it wins, and the variable that
# is being left behind is named on stderr rather than silently dropped.
if [ "$POSITIONAL_URL" -eq 1 ] && [ -n "${REPO_URL:-}" ]; then
  echo "heliograph.sh: REPO_URL is exported in this shell, and a URL was also given on" >&2
  echo "  this command line. The URL you typed wins: REPO_URL is NOT forwarded to the" >&2
  echo "  container (entrypoint.sh refuses both together, and only one of them is" >&2
  echo "  something you asked for here). Unset REPO_URL, or drop the URL argument, if" >&2
  echo "  the other one was what you meant." >&2
fi
for var in REPO_URL GIT_TOKEN GIT_AUTH_HEADER GIT_TOKEN_USER; do
  if [ "$var" = "REPO_URL" ] && [ "$POSITIONAL_URL" -eq 1 ]; then
    continue
  fi
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
fi

# --- decision 3: the container outlives the run unless the log survives elsewhere
# --rm is added only when the checkout is not the only copy of a log a failed
# push has committed: either --volume put the checkout on the host, or the
# operator opted in with --rm and accepted the loss. A detached container is
# kept regardless, as before - it is the case that most needs `docker logs`
# afterwards.
if [ "$FORCE_RM" -eq 1 ] || { [ -n "$VOLUME_HOST" ] && [ "$DETACH" -eq 0 ]; }; then
  RUN_ARGS+=(--rm)
fi

# --name is DEFAULTED, not merely passed through: a container that is kept has
# to be nameable in the recovery command printed below, and "docker cp
# <the-id-you-did-not-write-down>" is not a command anyone can paste. UTC plus
# this shell's pid, so two runs a second apart, or two shells at once, do not
# collide on a name the runtime would then refuse.
if [ -z "$NAME" ]; then
  NAME="heliograph-$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null)-$$"
fi
RUN_ARGS+=(--name "$NAME")

# `--` ends the runtime's own flag parsing here (see ensure_image's comment):
# everything from $FINAL_IMAGE onward is positional, which is what CMD_ARGS
# already relied on implicitly and now does explicitly.
RUN_ARGS+=(-- "$FINAL_IMAGE")
RUN_ARGS+=(${CMD_ARGS[@]+"${CMD_ARGS[@]}"})

FULL_CMD=("$RUNTIME" "${RUN_ARGS[@]}")

# --- what to do if the push fails, said BEFORE the run, not after --------------
# cap_push's own message at that moment is "PUSH FAILED - run 'git push'
# manually. The file is committed locally: <path>" - and with no --volume that
# path is inside this container. So the container has to survive (it does now,
# see decision 3) AND the operator has to know how to reach into it. Printed
# up front because by the time the message that needs it appears, the run is
# over and scrollback is long. On stderr, so a piped or pasted --print stays
# exactly the command and nothing else.
if [ -z "$VOLUME_HOST" ] && [ "$FORCE_RM" -eq 0 ]; then
  echo "heliograph.sh: this container is NOT removed when it exits, deliberately." >&2
  echo "  With no --volume the checkout lives only inside it, and a run whose push fails" >&2
  echo "  commits the captured log THERE and nowhere else ('PUSH FAILED - run git push" >&2
  echo "  manually. The file is committed locally: ...')." >&2
  echo "  Recover it before removing anything:" >&2
  echo "    $RUNTIME cp $NAME:$WORKDIR_CONTAINER/ops-logs/ ." >&2
  echo "  Then, once the log is somewhere safe:" >&2
  echo "    $RUNTIME rm $NAME" >&2
  echo "  --volume /abs/path keeps the checkout on the host instead, and the container is" >&2
  echo "  removed on exit; --rm removes it regardless and accepts losing an unpushed log." >&2
elif [ -z "$VOLUME_HOST" ] && [ "$FORCE_RM" -eq 1 ]; then
  echo "heliograph.sh: --rm with no --volume - this container, and the whole checkout" >&2
  echo "  inside it, are destroyed when it exits. If the run ends with 'PUSH FAILED' the" >&2
  echo "  captured log is committed in that checkout and nowhere else, and goes with it." >&2
  echo "  That is what --rm asks for; --volume /abs/path is how to keep both." >&2
fi

if [ "$DRY_RUN" -eq 1 ]; then
  print_cmd "${FULL_CMD[@]}"
  exit 0
fi

ensure_image "$FINAL_IMAGE" ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"}

# exec, not a child: the same reason entrypoint.sh execs start.sh - a signal
# sent to this script (an operator's Ctrl-C on a foreground run) has to reach
# the runtime client directly, which is what forwards it into the container.
exec "${FULL_CMD[@]}"
