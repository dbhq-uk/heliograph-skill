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
mask_secrets() {
  sed -E \
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
# (there is no repo yet to hold one) and no separate "unreadable:" diagnosis
# (that level of detail is start.sh/cap_auth_describe's job, reached a few
# seconds later against the same variables).
entrypoint_credential_desc() {
  local tok
  if [ -n "${GIT_AUTH_HEADER:-}" ]; then
    printf 'GIT_AUTH_HEADER, used verbatim (%s chars)' "${#GIT_AUTH_HEADER}"
  elif [ -n "${GIT_TOKEN:-}" ]; then
    printf 'GIT_TOKEN from the environment (%s chars)' "${#GIT_TOKEN}"
  elif [ -n "${GIT_TOKEN_FILE:-}" ] && [ -r "${GIT_TOKEN_FILE}" ]; then
    tok="$(sed -n '1p' "$GIT_TOKEN_FILE" 2>/dev/null)"
    printf '%s (%s chars)' "$GIT_TOKEN_FILE" "${#tok}"
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

# _entrypoint_git_env_ok - mirrors caplib.sh's _cap_git_env_config exactly.
# Duplicated rather than sourced for the reason at the top of this file: this
# runs before the repo (and caplib.sh with it) exists. git below 2.31 ignores
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
    env GIT_CONFIG_COUNT=1 \
        GIT_CONFIG_KEY_0=http.extraHeader \
        GIT_CONFIG_VALUE_0="$hdr" \
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
unchanged if a persistent volume already holds a clone there from an earlier
run of this container - then hands over to that repo's own ./start.sh,
which owns the preflight, the credential checks, the branch checkout and
the handover to agent.sh. Every argument after the URL (or every argument at
all, if REPO_URL is set) is passed to start.sh untouched.

Credential for an https:// URL: GIT_TOKEN, GIT_TOKEN_FILE or GIT_AUTH_HEADER
in the container's environment - never in the URL itself. Of the three,
GIT_TOKEN_FILE naming a bind- or secret-mounted file is the one that does
not appear in `docker inspect`; GIT_TOKEN and GIT_AUTH_HEADER, passed with
`-e`, do - that is a property of `docker inspect`, not of this script, and
nothing run inside the container can close it.
USAGE
}

main() {
  local url=""

  if [ -n "${REPO_URL:-}" ]; then
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
    # container restart. PULL, never re-clone: this container has no way to
    # know whether the last run died mid-step with an unpushed commit or a
    # captured log still sitting there uncommitted - the same evidence
    # start.sh's own checkout logic refuses to discard ("never resolves a
    # conflict, never forces, never discards the operator's work"). A
    # re-clone would silently throw that away. And there is no separate pull
    # to write here either: start.sh already does its own `cap_git pull
    # --rebase --quiet` right before it hands over to agent.sh, using
    # whichever credential this container's environment provides - the same
    # one this script would otherwise re-resolve. Reusing that rather than
    # adding a second pull with a second copy of the credential logic is the
    # "must not duplicate start.sh" rule applied to this path specifically.
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
    local out rc
    out="$(git_clone_with_header "$url" "$WORKDIR" 2>&1)"; rc=$?
    [ -n "$out" ] && printf '%s\n' "$out" | mask_secrets
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
