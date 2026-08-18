#!/usr/bin/env bash
# =============================================================================
#  entrypoint.sh - clone the transport repo, then get out of the way
# =============================================================================
#     entrypoint.sh <repo-url> [start.sh args...]
#     REPO_URL=<repo-url> entrypoint.sh [start.sh args...]
#
#  THREE JOBS, and nothing else:
#    1. Work out where the transport repo is (a URL) and clone it, unless a
#       persistent volume already holds one from an earlier run of this
#       container.
#    2. cd into it.
#    3. exec ./start.sh, passing every remaining argument through untouched.
#
#  EVERYTHING AFTER THE CLONE IS start.sh's JOB. It already owns the
#  preflight, the credential resolution, the branch checkout and the handover
#  to agent.sh - PR 1 built and tested all of that. Duplicating any of it here
#  would leave no answer to "which copy is authoritative", so this file does
#  not try. In particular: there is no --branch flag here. A branch to switch
#  to AFTER the clone is start.sh's own --branch, reached by passing it
#  straight through; this file has no branch concept of its own.
#
#  THE CREDENTIAL. caplib.sh - and with it cap_git, the one place this
#  toolkit is supposed to attach a credential to git - is INSIDE the repo
#  this script clones. Before the clone it does not exist yet, so the small
#  amount of credential handling below (entrypoint_auth_header,
#  entrypoint_credential_desc, _entrypoint_git_env_ok) is a deliberate,
#  narrow re-implementation of cap_git's env-not-argv trick, scoped to the
#  one git invocation that has to run before caplib.sh is reachable. Once the
#  clone exists, this script hands over and never touches git's credentials
#  again - the restart path below (an already-cloned repo) reuses the real
#  caplib.sh/start.sh for every git operation that follows, deliberately,
#  rather than extending this duplication any further than it has to go.
#
#  THE ONE THING THIS FILE ACTIVELY REFUSES: a repo URL with a credential
#  embedded in it (https://user:token@host/...). That string becomes an
#  ARGUMENT to git clone, and /proc/<pid>/cmdline is world-readable inside
#  this container exactly as it is on a bare control node - PR 1's cap_git
#  moved the auth header out of argv for the same reason. Putting the
#  credential in the URL is the obvious route and it is the one that leaks;
#  see references/container.md for the full account and the honest limits of
#  what is closed here versus what Docker itself still exposes.
# =============================================================================
set -uo pipefail

# Never prompt. AGENTS.md's standing rule ("Steps never prompt... a prompt
# through the capture pipeline is invisible and the run simply hangs")
# applies here just as much as inside a step: with a tty attached (`docker
# run -it`, exactly what an operator does for a first smoke test) and no
# working credential, `git clone` over https blocks on a username prompt
# forever rather than failing. Confirmed by hand: unset, the container sat
# there past two minutes against an auth-required host; set, the same clone
# fails in about three seconds with "terminal prompts disabled". Exported,
# deliberately, so it survives the exec into start.sh/agent.sh below and
# nothing later in the run can prompt either.
export GIT_TERMINAL_PROMPT=0

# Where the transport repo lives inside the container. Overridable so a
# wrapper (task 3) or an operator can point it at a different mount without
# editing this file; $HOME rather than a hard-coded /home/heliograph so a
# rebuild with a different HELIOGRAPH_UID/username still resolves correctly.
WORKDIR="${HELIOGRAPH_WORKDIR:-$HOME/repo}"

# --- masking, for what THIS script prints directly ---------------------------
# cap_redact cannot help here for the same reason start.sh's own credential()
# function re-implements its two URL rules rather than calling cap_redact:
# both run before or entirely without caplib.sh, and both print directly
# rather than through cap_run's pipeline. Same two rules, same order, same
# reasoning - see caplib.sh's cap_redact and start.sh's credential() for the
# long version. Scoped to the two URL shapes because a repo URL is the only
# thing this file ever prints that could carry a credential; the key=value
# and Bearer/Basic-header rules in cap_redact exist for arbitrary COMMAND
# output, which nothing here produces.
# -u (unbuffered), the same reason caplib.sh's cap_run uses `sed -u`: this
# is used to stream the clone's own progress live below, and a buffered sed
# would sit on that output until the clone finishes, silently turning a
# large clone over a slow link into what looks like a hang.
mask_secrets() {
  sed -u -E \
    -e 's#(://[^/@:[:space:]]*):[^/@[:space:]]*@#\1:***@#g' \
    -e 's%(https?://)[^/@:?#,[:space:]]*@%\1***@%gI'
}

# url_has_credential <url> - true if masking it changes it, i.e. it carries
# userinfo of either shape. Same detection cap_redact and start.sh use.
url_has_credential() {
  local u="$1" masked
  masked="$(printf '%s' "$u" | mask_secrets)"
  [ "$masked" != "$u" ]
}

# --- the credential, for the one clone that runs before caplib.sh exists -----
# Same names, same precedence order as caplib.sh's _cap_token_source, so the
# one credential an operator configures for this container (GIT_TOKEN,
# GIT_TOKEN_FILE or GIT_AUTH_HEADER, set once when the container is started)
# is what BOTH this clone and every later cap_git call inside start.sh
# resolve, without the operator needing to know there are two mechanisms
# underneath. Deliberately narrower than _cap_token_source: no ./.git-token
# (there is no repo yet to hold one) - but the "unreadable:" diagnosis IS
# kept, unlike an earlier version of this file, because a GIT_TOKEN_FILE that
# exists but cannot be read is exactly the shape a root-owned Docker/
# Kubernetes secret mount arrives in, which is the very mitigation this
# file's own usage text recommends for keeping a token out of `docker
# inspect`. Reporting that as a flat "none" - rather than naming the file and
# the permissions problem - denies a variable the operator did set, at the
# one moment (an unauthenticated https clone failing outright) where
# start.sh is never reached to correct it a few seconds later.
entrypoint_credential_desc() {
  local tok
  if [ -n "${GIT_AUTH_HEADER:-}" ]; then
    printf 'GIT_AUTH_HEADER, used verbatim (%s chars)' "${#GIT_AUTH_HEADER}"
  elif [ -n "${GIT_TOKEN:-}" ]; then
    printf 'GIT_TOKEN from the environment (%s chars)' "${#GIT_TOKEN}"
  elif [ -n "${GIT_TOKEN_FILE:-}" ] && [ -r "${GIT_TOKEN_FILE}" ]; then
    tok="$(sed -n '1p' "$GIT_TOKEN_FILE" 2>/dev/null)"
    printf '%s (%s chars)' "$GIT_TOKEN_FILE" "${#tok}"
  elif [ -n "${GIT_TOKEN_FILE:-}" ] && [ -e "${GIT_TOKEN_FILE}" ]; then
    printf '%s exists but is not readable by %s, so no credential is attached to this clone. Fix its permissions, or run the container as a user that can read it' \
      "$GIT_TOKEN_FILE" "$(whoami 2>/dev/null || echo 'this user')"
  elif [ -r "$HOME/.git-token" ]; then
    tok="$(sed -n '1p' "$HOME/.git-token" 2>/dev/null)"
    printf '%s (%s chars)' "$HOME/.git-token" "${#tok}"
  else
    printf 'none (relying on a forwarded ssh-agent key, or a public repository)'
  fi
}

# entrypoint_auth_header - prints an `Authorization: ...` header value, or
# nothing when no credential is configured. NEVER prints the token alone.
entrypoint_auth_header() {
  local tok=""
  if [ -n "${GIT_AUTH_HEADER:-}" ]; then
    printf 'Authorization: %s' "$GIT_AUTH_HEADER"
    return 0
  fi
  if [ -n "${GIT_TOKEN:-}" ]; then
    tok="$GIT_TOKEN"
  elif [ -n "${GIT_TOKEN_FILE:-}" ] && [ -r "${GIT_TOKEN_FILE}" ]; then
    tok="$(sed -n '1p' "$GIT_TOKEN_FILE" 2>/dev/null)"
  elif [ -r "$HOME/.git-token" ]; then
    tok="$(sed -n '1p' "$HOME/.git-token" 2>/dev/null)"
  fi
  [ -z "$tok" ] && return 0
  printf 'Authorization: Basic %s' \
    "$(printf '%s:%s' "${GIT_TOKEN_USER:-}" "$tok" | base64 -w0)"
}

# foreign_owners <dir> - prints one "<uid> <path>" line for every path git's
# own ownership check looks at whose owning uid differs from this process's,
# and nothing at all when none does.
#
# BOTH the working tree and the .git directory, because git refuses on
# EITHER of them. Measured directly rather than assumed: a checkout whose
# WORKTREE alone was chowned to another uid, and one whose .GIT alone was,
# both come back "fatal: detected dubious ownership in repository at ...".
# Checking only the directory this script was pointed at would therefore
# have diagnosed the second case as "the owner matches, cause unknown".
#
# Deliberately NOT a match against git's message text. That string is git's
# to change and is translated under a non-English locale, and a diagnosis
# that only fires for one wording would silently degrade back into the
# swallowed-and-misdiagnosed shape this whole function exists to end. The
# uids are a fact this script can measure for itself, and they are also
# exactly what the operator needs printed.
foreign_owners() {
  local dir="$1" me p owner
  me="$(id -u 2>/dev/null)"
  [ -z "$me" ] && return 0
  for p in "$dir" "$dir/.git"; do
    [ -e "$p" ] || continue
    owner="$(stat -c %u "$p" 2>/dev/null)"
    [ -z "$owner" ] && continue
    [ "$owner" != "$me" ] && printf '%s %s\n' "$owner" "$p"
  done
  return 0
}

# _entrypoint_git_env_ok - mirrors caplib.sh's _cap_git_env_config exactly
# (the version gate; git_clone_with_header below mirrors cap_git's
# append-at-next-free-index behaviour too - see its own comment). Duplicated
# rather than sourced for the reason at the top of this file: this runs
# before the repo (and caplib.sh with it) exists. git below 2.31 ignores
# GIT_CONFIG_COUNT silently, which would send the clone out with no
# credential at all and fail as a bare auth error - so the version is
# checked, never hoped for, exactly as cap_git does.
_entrypoint_git_env_ok() {
  local v maj rest min
  v="$(git --version 2>/dev/null)"
  v="${v#git version }"
  maj="${v%%.*}"
  rest="${v#*.}"
  min="${rest%%.*}"
  case "$maj" in ''|*[!0-9]*) return 1 ;; esac
  case "$min" in ''|*[!0-9]*) return 1 ;; esac
  [ "$maj" -gt 2 ] && return 0
  [ "$maj" -eq 2 ] && [ "$min" -ge 31 ]
}

# git_clone_with_header <url> <dir> - clones with the credential attached
# through the ENVIRONMENT, never through argv or the URL. `git -c
# http.extraHeader=...` puts the header on THIS process's command line, and
# /proc/<pid>/cmdline is mode 444: any other user able to run a command in
# this container could read it straight out of `ps`. `git clone` itself does
# not persist a `-c`/environment config override into the new repo's
# .git/config either way - it is process-scoped - so remote.origin.url comes
# out exactly as given: the plain URL, with nothing appended.
git_clone_with_header() {
  local url="$1" dir="$2" hdr
  hdr="$(entrypoint_auth_header)"
  if [ -z "$hdr" ]; then
    git clone -- "$url" "$dir"
  elif _entrypoint_git_env_ok; then
    # APPEND at the next free index rather than hard-coding slot 0 - this
    # used to hard-code it, which is exactly the mistake cap_git's own
    # comment warns against: an operator on a locked-down estate may already
    # inject their own GIT_CONFIG_COUNT/KEY_0/VALUE_0 into this container's
    # environment the same way (an ambient http.proxy, sslCAInfo,
    # safe.directory). Slot 0 silently overwrote and truncated it off the
    # list - and only on the AUTHENTICATED path, since the header-less branch
    # above never touches GIT_CONFIG_* at all, so the failure appeared only
    # once a token was added, on the one path that is actually deployed.
    # `10#` guards the same trap cap_git guards against: bash reads a leading
    # zero as octal, and a zero-padded ambient count (GIT_CONFIG_COUNT=08) is
    # a natural thing for a template to emit; without it `$((n + 1))` raises
    # a fatal arithmetic error under `set -uo pipefail` before git ever runs.
    local n="${GIT_CONFIG_COUNT:-0}"
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    n=$((10#$n))
    env "GIT_CONFIG_COUNT=$((n + 1))" \
        "GIT_CONFIG_KEY_$n=http.extraHeader" \
        "GIT_CONFIG_VALUE_$n=$hdr" \
        git clone -- "$url" "$dir"
  else
    # Old git: the same trade-off cap_git documents. The header reaches
    # argv here, which is strictly worse than the branch above, but strictly
    # better than sending the clone out unauthenticated and failing as a
    # bare "Authentication failed" that names nothing.
    git -c http.extraHeader="$hdr" clone -- "$url" "$dir"
  fi
}

usage() {
  cat <<'USAGE'
usage: entrypoint.sh <repo-url> [start.sh args...]
   or: REPO_URL=<repo-url> entrypoint.sh [start.sh args...]

Clones <repo-url> into ${HELIOGRAPH_WORKDIR:-$HOME/repo} - or reuses it
unchanged if a persistent volume already holds a clone of the SAME repo
there from an earlier run of this container (a clone of a DIFFERENT repo is
refused, not silently reused) - then hands over to that repo's own
./start.sh, which owns the preflight, the credential checks, the branch
checkout and the handover to agent.sh. Every argument after the URL (or
every argument at all, if REPO_URL is set with no positional URL) is passed
to start.sh untouched. REPO_URL and a positional URL together are refused,
rather than one silently winning.

Credential for an https:// URL: GIT_TOKEN, GIT_TOKEN_FILE or GIT_AUTH_HEADER
in the container's environment - never in the URL itself. Of the three,
GIT_TOKEN_FILE naming a bind- or secret-mounted file is the one that does
not appear in `docker inspect`; GIT_TOKEN and GIT_AUTH_HEADER, passed with
`-e`, do - that is a property of `docker inspect`, not of this script, and
nothing run inside the container can close it.
USAGE
}

main() {
  local url="" existing_url remote_rc remote_err errfile owners first_uid
  local owner_uid owner_path line

  # Both set is refused rather than one silently winning. It used to let
  # REPO_URL win and treat every argument as opaque passthrough to start.sh -
  # which meant a positional argument was NEVER checked by
  # url_has_credential below, and `docker run -e REPO_URL=A image B` cloned A
  # and hands B to start.sh untouched. start.sh's own arg parser echoes an
  # unrecognised option verbatim ("unknown option: $1"), so if B carried a
  # credential (a habit, a copy-paste mistake, an attacker-controlled value)
  # it reached stdout in full. Refusing outright keeps both legitimate shapes
  # working - REPO_URL alone with pure start.sh passthrough, or a plain
  # positional URL alone - without ever guessing which one the caller meant.
  if [ -n "${REPO_URL:-}" ] && [ $# -gt 0 ]; then
    echo "entrypoint: both REPO_URL and a command-line argument were given - that is" >&2
    echo "  ambiguous: is the first argument the repository URL, or the first argument" >&2
    echo "  meant for start.sh? Use one or the other. Either set REPO_URL and pass only" >&2
    echo "  start.sh's own arguments, or drop REPO_URL and give the URL as the first" >&2
    echo "  argument here." >&2
    exit 2
  elif [ -n "${REPO_URL:-}" ]; then
    url="$REPO_URL"
  elif [ $# -gt 0 ]; then
    url="$1"
    shift
  fi

  if [ -z "$url" ]; then
    echo "entrypoint: no repository URL given." >&2
    usage >&2
    exit 2
  fi

  if url_has_credential "$url"; then
    echo "entrypoint: the repository URL embeds a credential ($(printf '%s' "$url" | mask_secrets))." >&2
    echo "  That string becomes an argument to git clone, and /proc/<pid>/cmdline is" >&2
    echo "  world-readable in this container - anyone else who can run a command here" >&2
    echo "  could read it straight out of ps. Pass the credential separately instead:" >&2
    echo "  GIT_TOKEN, GIT_TOKEN_FILE or GIT_AUTH_HEADER in the environment, with a" >&2
    echo "  plain URL here." >&2
    exit 2
  fi

  mkdir -p "$WORKDIR" || { echo "entrypoint: cannot create $WORKDIR" >&2; exit 1; }

  if [ -e "$WORKDIR/.git" ] && [ -x "$WORKDIR/start.sh" ]; then
    # An already-cloned repo, most often a persistent volume surviving a
    # container restart. First confirm it is a clone of the SAME repo this
    # run was given - `git remote get-url origin` is a plain local config
    # read, no network and no credential involved, so there is no reason to
    # skip it just because caplib.sh is not sourced on this path. Without
    # this check, a restart with a different REPO_URL/argument (a moved
    # remote, a copy-paste mistake, a volume reused for a different task)
    # silently kept the OLD checkout and its OLD remote, and everything
    # start.sh and agent.sh do next - including pushing captured logs -
    # happened against the wrong transport repo. That is precisely the
    # failure this toolkit exists to prevent, so this refuses rather than
    # warns: an operator who only skims scrollback would miss a warning.
    #
    # THREE OUTCOMES, kept apart, because they are three different facts:
    #   1. the read succeeded and the URL matches  -> reuse it (below)
    #   2. the read succeeded and the URL DIFFERS  -> a genuinely different
    #      repo. Identified: this script knows what the directory holds.
    #   3. the read FAILED                         -> UNIDENTIFIED. This
    #      script knows nothing about what the directory holds.
    #
    # 2 and 3 used to be the same branch, and that was wrong in the worst
    # available direction. `2>/dev/null` swallowed git's own error,
    # `${existing_url:-<no origin remote>}` then rendered a failed read as a
    # POSITIVE CLAIM about the directory's contents, and the message went on
    # to advise emptying it by hand. A bind-mounted checkout owned by a
    # different uid than this container's user lands exactly there - git
    # refuses to read a repository it believes belongs to someone else
    # (CVE-2022-24765, "dubious ownership") - so it was reported as "a clone
    # of <no origin remote>", i.e. a different repository, and the remedy
    # offered destroys it. Reproduced under PLAIN DOCKER with a --volume
    # checkout owned by uid 4242, not only under rootless podman's known
    # remapping.
    #
    # What makes that a data-loss bug rather than a poor message: that
    # directory is the OPERATOR'S checkout, and it may hold a captured log
    # committed but not yet pushed - the one copy of the evidence this
    # toolkit exists to carry off a machine nobody can reach (AGENTS.md
    # constraint 2, "a failed run still ships, and a failed push never loses
    # a log"). So the standing rule below, which no future branch here may
    # break: NOTHING PRINTED BY THIS SCRIPT MAY RECOMMEND EMPTYING OR
    # DELETING A DIRECTORY WHOSE CONTENTS IT COULD NOT IDENTIFY. If the
    # remote could not be read, this script does not know the directory is
    # safe to destroy, and must not imply that it does.
    #
    # The refusal itself was right in all three cases and stays. Only the
    # diagnosis and the remedy change.
    remote_err=""
    errfile="$(mktemp 2>/dev/null)"
    if [ -n "$errfile" ]; then
      # git's stderr is the EVIDENCE, not noise, so it is captured and
      # printed rather than discarded - masked, because a remote URL can
      # appear in it. Kept apart from stdout deliberately: folded together,
      # an error message would be indistinguishable from the URL itself and
      # could be compared against $url as though it were one.
      existing_url="$(git -C "$WORKDIR" remote get-url origin 2>"$errfile")"
      remote_rc=$?
      remote_err="$(mask_secrets < "$errfile" 2>/dev/null)"
      rm -f "$errfile"
    else
      existing_url="$(git -C "$WORKDIR" remote get-url origin 2>/dev/null)"
      remote_rc=$?
    fi

    # An empty URL with a zero exit counts as UNIDENTIFIED too, not as a
    # match against an empty string: whatever produced it, it is not an
    # identification of this directory's contents either.
    if [ "$remote_rc" -ne 0 ] || [ -z "$existing_url" ]; then
      owners="$(foreign_owners "$WORKDIR")"
      echo "entrypoint: cannot identify what $WORKDIR holds - reading its origin remote" >&2
      echo "  failed (git exited $remote_rc). Refusing to go further rather than guess." >&2
      if [ -n "$owners" ]; then
        # Named for what it actually is, with the uid on each side. Note
        # what this branch does NOT say: it makes no claim about which
        # repository the directory is a clone of, because the failure that
        # brought us here is precisely the failure to find that out.
        echo "  The cause is an OWNERSHIP MISMATCH, not a different repository:" >&2
        while read -r owner_uid owner_path; do
          [ -n "$owner_path" ] && echo "    $owner_path is owned by uid $owner_uid" >&2
        done <<EOWNERS
$owners
EOWNERS
        echo "    this container runs as uid $(id -u) ($(whoami 2>/dev/null || echo 'unknown user'))" >&2
        echo "  git refuses to read a repository owned by another user (CVE-2022-24765," >&2
        echo "  \"dubious ownership\"). That is what failed, and it says NOTHING about which" >&2
        echo "  repository this directory holds - it may well already be a clone of" >&2
        echo "  $(printf '%s' "$url" | mask_secrets), the URL this run was given." >&2
      fi
      if [ -n "$remote_err" ]; then
        echo "  git said:" >&2
        while IFS= read -r line; do echo "    $line" >&2; done <<EGITERR
$remote_err
EGITERR
      fi
      echo "  DO NOT empty or delete $WORKDIR to get past this. Its contents could not be" >&2
      echo "  identified here, so nothing establishes it is safe to destroy: if an earlier" >&2
      echo "  run committed a captured log that was never pushed, that checkout holds the" >&2
      echo "  only copy, and it is the evidence this toolkit exists to carry off a machine" >&2
      echo "  nobody can log into." >&2
      if [ -n "$owners" ]; then
        first_uid="$(printf '%s\n' "$owners" | sed -n '1s/ .*//p')"
        echo "  Fix the ownership instead, whichever suits the estate:" >&2
        echo "    - run this container AS that uid: rebuild the image with" >&2
        echo "      --build-arg HELIOGRAPH_UID=$first_uid, tag it yourself, and run that tag" >&2
        echo "      (heliograph.sh --image <your-tag>)" >&2
        echo "    - or give the host directory to uid $(id -u): chown -R $(id -u) <the host path>" >&2
        echo "    - or, under rootless podman, use --userns=keep-id, which heliograph.sh" >&2
        echo "      already adds for you when podman is the runtime" >&2
        echo "  Either way the checkout survives, which is the point." >&2
      else
        echo "  Point HELIOGRAPH_WORKDIR at a different, empty location for this run, and" >&2
        echo "  investigate this directory separately, with its contents intact." >&2
      fi
      exit 1
    fi

    if [ "$existing_url" != "$url" ]; then
      # IDENTIFIED, and genuinely a different repository. Only here - where
      # this script can say what the directory actually is - is emptying it
      # mentioned at all, and even then with the caution below, because a
      # checkout of the WRONG repo can still hold that repo's own unpushed
      # log.
      echo "entrypoint: $WORKDIR already holds a clone of $(printf '%s' "$existing_url" | mask_secrets)," >&2
      echo "  but this run was given $(printf '%s' "$url" | mask_secrets) - refusing to reuse it." >&2
      echo "  Reusing a checkout of a different repo would run agent.sh against, and push" >&2
      echo "  captured logs to, the wrong transport repo. Point HELIOGRAPH_WORKDIR at a" >&2
      echo "  different, empty location for this repo, or empty $WORKDIR by hand first if" >&2
      echo "  reusing it for a new repo is genuinely what you want - checking first that it" >&2
      echo "  holds nothing unpushed, because a captured log that never left is lost with it." >&2
      exit 1
    fi
    # PULL, never re-clone: this container has no way to know whether the
    # last run died mid-step with an unpushed commit or a captured log still
    # sitting there uncommitted - the same evidence start.sh's own checkout
    # logic refuses to discard ("never resolves a conflict, never forces,
    # never discards the operator's work"). A re-clone would silently throw
    # that away. And there is no separate pull to write here either:
    # start.sh already does its own `cap_git pull --rebase --quiet` right
    # before it hands over to agent.sh, using whichever credential this
    # container's environment provides - the same one this script would
    # otherwise re-resolve. Reusing that rather than adding a second pull
    # with a second copy of the credential logic is the "must not duplicate
    # start.sh" rule applied to this path specifically.
    echo "entrypoint: $WORKDIR already holds a clone (persistent volume) - reusing it."
    echo "  Not re-cloning: that could discard a commit or a log this checkout holds"
    echo "  that has not been pushed yet. start.sh's own sync brings it up to date next."
  elif [ -d "$WORKDIR" ] && [ -n "$(ls -A "$WORKDIR" 2>/dev/null)" ]; then
    # Not empty and not a recognisable checkout: refuse rather than guess.
    # Cloning into it would fail anyway (git refuses a non-empty target
    # directory); silently deleting it first would be the wrong failure mode
    # to invent when the safe one - stop and say why - is right there.
    echo "entrypoint: $WORKDIR exists, is not empty, and is not a heliograph checkout" >&2
    echo "  (missing .git or start.sh). Refusing to clone over it or delete it -" >&2
    echo "  empty the directory by hand first, or set HELIOGRAPH_WORKDIR to somewhere else." >&2
    exit 1
  else
    echo "entrypoint: cloning $(printf '%s' "$url" | mask_secrets) into $WORKDIR"
    echo "entrypoint: credential: $(entrypoint_credential_desc)"
    local rc
    # STREAMED, not captured-then-printed: this used to buffer the whole
    # clone into a variable and print it only once git exited, so `docker
    # logs` showed nothing at all between "cloning" and completion - on a
    # large repo over a slow link, minutes of apparent hang with no way to
    # tell it apart from a real one. `git clone` writes its progress to
    # STDERR only (confirmed by hand: an ordinary clone puts zero bytes on
    # stdout), so this keeps it there rather than folding it into this
    # script's stdout the way a `2>&1` capture did - errors now arrive on
    # the stream they belong on. Piped through mask_secrets via process
    # substitution rather than a plain `|`, so `rc` below is git's own real
    # exit status (`$?` after a `|` pipeline would be the pipe's, not the
    # command's, without also reaching for PIPESTATUS). The one thing this
    # does not guarantee is that the masked tail end is fully flushed before
    # the next line of this script prints - a bash process-substitution
    # nuance - but nothing is ever lost, only, in the rare case, printed a
    # moment later than the line after it.
    git_clone_with_header "$url" "$WORKDIR" 2> >(mask_secrets >&2)
    rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "entrypoint: git clone failed (exit $rc). Check that the URL is reachable and" >&2
      echo "  that the credential is correct - GIT_TOKEN / GIT_TOKEN_FILE / GIT_AUTH_HEADER" >&2
      echo "  for an https:// URL, or a forwarded ssh-agent key for an ssh:// or git@ one." >&2
      exit 1
    fi
    if [ ! -x "$WORKDIR/start.sh" ]; then
      echo "entrypoint: cloned $(printf '%s' "$url" | mask_secrets) but it has no executable" >&2
      echo "  ./start.sh - is this a heliograph transport repo? Bootstrap one with" >&2
      echo "  skills/heliograph/scripts/bootstrap.sh." >&2
      # Clean up what was just cloned, rather than leaving a foreign, non-
      # empty directory behind: without this, the NEXT run of this same
      # container lands in the "not a heliograph checkout" refusal above
      # instead of trying the clone again, which names a less accurate
      # problem than the one that actually happened. Only reached inside
      # the branch that just created $WORKDIR itself, never on the reused-
      # checkout path above, so there is nothing here that could discard an
      # operator's own data.
      rm -rf "$WORKDIR"
      exit 1
    fi
  fi

  cd "$WORKDIR" || { echo "entrypoint: cannot cd into $WORKDIR" >&2; exit 1; }
  # exec, not a child: the same reason start.sh execs agent.sh rather than
  # running it as one - a signal sent to this container's pid 1 has to reach
  # start.sh (and, through its own exec, agent.sh) directly, or an operator's
  # `docker stop` would leave the real work orphaned and unsignalled.
  exec ./start.sh "$@"
}

if [ "${BASH_SOURCE[0]:-}" = "${0:-}" ]; then
  main "$@"
fi
