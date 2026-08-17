#!/usr/bin/env bash
# =============================================================================
#  caplib.sh - shared capture / log / push helpers
# =============================================================================
# The ONE implementation of the pattern this repo exists for: run a command,
# timestamp every line, strip colour, redact obvious secrets, tee it to a file,
# then commit + push that file so someone with no access to the box can read it.
#
# Not executable on its own - `source` it, then call the cap_* functions.
#
#   . "$REPO_ROOT/caplib.sh"
#   cap_header "$OUT" "MY STEP" "context line"
#   cap_run    "$OUT" some-command --with args
#   cap_footer "$OUT" $?
#   cap_push   "$OUT" "step: whatever (exit=$?)"
#
# Requires bash 4+, git, and GNU coreutils/sed in practice: `sed -u` keeps the
# capture unbuffered so a line is stamped when it is produced rather than when
# the block flushes, and `base64 -w0` builds the HTTPS auth header. Neither
# spelling is universal - `sed -u` is absent from busybox, `base64 -w0` is
# absent from BSD/macOS base64 - so a control node is a Linux box in practice;
# on macOS install GNU coreutils and gnu-sed, and put them first on PATH.
#
# Honoured environment variables:
#   PUSH=0        cap_push captures only; does not commit or push
#   REDACT=0      disable the best-effort secret masking in cap_run
#   NO_COLOUR=1   plain banners (no ANSI)
#   GIT_TOKEN     token for the git push over HTTPS (see _cap_auth_header below)
#   GIT_TOKEN_FILE  path to a file whose first line is that token
# =============================================================================

# The division of labour: a RUNNER (run.sh / caprun.sh) owns the log file and
# calls these functions; a STEP SCRIPT just prints to stdout and knows nothing
# about logging. Keep it that way - it's what makes steps runnable standalone.
#
# --- a visible progress banner to the terminal (not the log) -----------------
cap_banner() {
  if [ -n "${NO_COLOUR:-}" ]; then printf '\n==> %s\n' "$*"
  else printf '\n\033[1;36m==> %s\033[0m\n' "$*"; fi
}

# --- the closing line on the operator's terminal ------------------------------
# cap_result <label> <rc> <logfile>
# Honours NO_COLOUR for the same reason cap_banner does: this is the last thing
# the operator reads, and on a terminal that does not interpret escapes it is
# the line most likely to be pasted back to you with the codes still in it.
cap_result() {
  local label="$1" rc="$2" out="$3"
  echo
  if [ "$rc" -eq 0 ]; then
    if [ -n "${NO_COLOUR:-}" ]; then printf 'DONE - %s finished OK.\n' "$label"
    else printf '\033[1;32mDONE - %s finished OK.\033[0m\n' "$label"; fi
  else
    if [ -n "${NO_COLOUR:-}" ]; then
      printf 'DONE - %s FAILED (exit %s). See %s\n' "$label" "$rc" "$(basename "$out")"
    else
      printf '\033[1;31mDONE - %s FAILED (exit %s). See %s\033[0m\n' "$label" "$rc" "$(basename "$out")"
    fi
  fi
}

# --- best-effort secret masking ----------------------------------------------
# Logs in this repo are COMMITTED AND PUSHED, so anything a command echoes ends
# up in git history forever. This filter masks the obvious shapes (key=value
# passwords, Bearer/Basic headers, private keys). It is a safety net, NOT a
# guarantee - never deliberately run a command that prints a secret. Set
# REDACT=0 when masking is hiding something you actually need to read.
#
# Note `secret_name=pw-foo` is intentionally NOT masked (the name of a Key Vault
# secret is useful and harmless); `admin_password=...` is.
#
# `scheme://user:password@host` is masked because steps print git and registry
# URLs constantly and the token-in-URL clone is a form people really do arrive
# with. git redacts userinfo in its own messages; a command that echoes its own
# argv does not, and none of the other patterns here catch this shape - it is
# neither key=value nor a Bearer/Basic header. Only what sits between `://` and
# the first `/` is touched, so `git@host:path` and a local path are left alone.
# A password containing `/` (a base64 registry password) is deliberately NOT
# caught: allowing `/` in the class lets the pattern run past a path segment and
# mask an `@` that belongs to a path, and losing evidence is the more expensive
# mistake here. Best effort, as the paragraph above says.
#
# The BARE userinfo form - `https://ghp_TOKEN@github.com/org/repo.git`, no colon
# and no password - needs a second rule, because the rule above REQUIRES a colon
# and this is the commonest GitHub PAT clone URL there is.
#
# It cannot re-mask what the colon rule already produced: `user:***REDACTED***@`
# leaves a colon between `://` and the `@`, and the bare rule's class excludes
# `:`, so that match just fails. Masking is therefore idempotent, which matters
# because a log line quoting an earlier log line is ordinary. The exclusion was
# measured rather than assumed, and the same property makes the two rules
# COMMUTE - swapping them gives byte-identical output on every shape tried. The
# colon rule is written first because it is the more specific of the two, not
# because correctness rests on it.
#
# A deliberate trade-off, taken with eyes open: `https://username@github.com/...`
# is a legitimate, non-secret form and this masks the username too. That is the
# right call. Nothing in a line of text can tell a username from a token in that
# position; the cost of hiding a username is a name the reader can find elsewhere
# in seconds, and the cost of missing a token is a live PAT sitting in a git
# history that cannot be unpublished. This is NOT the `/` trade-off above - that
# one is about not running past a path segment, and the classes here stay exactly
# as narrow for exactly that reason.
#
# The bare rule is limited to http/https because that is where the risk lives. A
# bare userinfo on an ssh:// remote is a login name (`ssh://git@host:2222/...` is
# the form this skill recommends) and carries no secret, so masking it would
# delete evidence from every log for nothing. `ssh://user:pass@host` is still
# caught by the colon rule, which stays scheme-neutral.
cap_redact() {
  if [ "${REDACT:-1}" = "0" ]; then cat; return 0; fi
  sed -u -E \
    -e "s/((password|passwd|pwd|secret|token|api[_-]?key|client_secret|sas|connectionstring)[\"\x27]?[[:space:]]*[:=][[:space:]]*[\"\x27]?)[^\"\x27[:space:],;}]+/\1***REDACTED***/gI" \
    -e "s#(://[^/@:[:space:]]*):[^/@[:space:]]*@#\1:***REDACTED***@#g" \
    -e "s#(https?://)[^/@:[:space:]]*@#\1***REDACTED***@#gI" \
    -e "s/(Bearer[[:space:]]+)[A-Za-z0-9._~+\/-]{16,}=*/\1***REDACTED***/g" \
    -e "s/(Basic[[:space:]]+)[A-Za-z0-9+\/]{16,}=*/\1***REDACTED***/g" \
    -e "s/-----BEGIN [A-Z ]*PRIVATE KEY-----/***REDACTED PRIVATE KEY***/g"
}

# --- stop the classic sudo hang before it starts -----------------------------
# A command that escalates on the control node will wait on stdin FOREVER if
# sudo needs a password and none is cached, with no error and no prompt visible
# through the capture pipeline. Prompt once here, up front, then keep the sudo
# timestamp warm for the whole run. Call this only for runs that escalate.
cap_sudo_precache() {
  if ! sudo -n true 2>/dev/null; then
    cap_banner "sudo needs a password - caching it now so the run cannot hang"
    if ! sudo -v; then
      echo "ERROR: could not cache sudo credential; the run would hang. Aborting." >&2
      return 1
    fi
  fi
  ( while true; do sudo -n true 2>/dev/null || exit; sleep 60; done ) &
  _CAP_SUDO_KEEPALIVE=$!
  trap 'kill "${_CAP_SUDO_KEEPALIVE:-}" 2>/dev/null || true' EXIT
}

# --- header ------------------------------------------------------------------
# cap_header <outfile> <label> [context-line ...]
# Truncates the file and writes the provenance block. Always record enough for
# the reader to reproduce the run: which commit, which host, which user.
cap_header() {
  local out="$1" label="$2"; shift 2
  {
    echo "============================================================"
    echo " $label"
    echo " started UTC : $(date -u +%Y%m%dT%H%M%SZ)"
    echo " control node: $(hostname -f 2>/dev/null || hostname)"
    echo " user        : $(whoami)"
    echo " git branch  : $(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
    echo " git commit  : $(git log --oneline -1 2>/dev/null)"
    local line
    for line in "$@"; do [ -n "$line" ] && echo " context     : $line"; done
    echo "============================================================"
    echo
  } > "$out"
}

# --- a labelled divider inside the log ---------------------------------------
# cap_section <outfile> <title...>
cap_section() {
  local out="$1"; shift
  { echo; echo "---------- $* ----------"; } | tee -a "$out"
}

# --- run a command, timestamped + colour-stripped + redacted, teed to the log -
# cap_run <outfile> <cmd> [args...] - returns the command's REAL exit code.
# Every line is prefixed with a UTC HH:MM:SS so a HANG shows as a visible gap in
# the timestamps rather than being indistinguishable from slow progress. That
# property is the whole reason this wrapper exists - do not remove it.
cap_run() {
  local out="$1"; shift
  "$@" 2>&1 \
    | sed -u 's/\x1b\[[0-9;]*[mGKHF]//g' \
    | cap_redact \
    | while IFS= read -r l; do printf '%s | %s\n' "$(date -u +%H:%M:%S)" "$l"; done \
    | tee -a "$out"
  return "${PIPESTATUS[0]}"
}

# --- footer ------------------------------------------------------------------
# cap_footer <outfile> <rc>
cap_footer() {
  local out="$1" rc="$2"
  {
    echo
    echo "============================================================"
    echo " finished UTC : $(date -u +%Y%m%dT%H%M%SZ)"
    echo " exit code    : $rc"
    echo " RESULT       : $([ "$rc" -eq 0 ] && echo OK || echo FAILED)"
    echo "============================================================"
  } | tee -a "$out"
}

# --- git auth for an HTTPS remote ---------------------------------------------
# An SSH remote with a forwarded agent key needs nothing from this file - plain
# `git push` just works, and it is the setup to prefer.
#
# The token path below is a FALLBACK for a clone set up over HTTPS. On a locked
# down control node there is often no usable credential helper, and some hosts
# reject the token-in-URL form outright, so the push fails with a bare
# "Authentication failed" even though the token is perfectly valid. Setting one
# of these attaches an explicit auth header to every network op instead:
#
#   GIT_AUTH_HEADER  the full header value, used verbatim  (e.g. "Bearer eyJ...")
#   GIT_TOKEN        a token, sent as HTTP Basic
#   GIT_TOKEN_FILE   a file whose first line is that token
#   GIT_TOKEN_USER   Basic username. Default empty, which is what Azure DevOps
#                    wants; GitHub wants x-access-token, GitLab oauth2
#
# Prints nothing when none of them is set, in which case git is used unmodified.
# That is right for an SSH remote and wrong for an https one, and nothing in this
# file can tell which: the caller knows the remote's scheme, so the caller draws
# that conclusion. See cap_auth_describe.

# Which mechanism supplies the credential, by NAME. One precedence list, used
# both to build the header and to report it: a report that could disagree with
# what git actually uses would be worse than no report at all.
#
# Prints exactly one of:
#   header:GIT_AUTH_HEADER   env:GIT_TOKEN   file:<path>   unreadable:<path>   none
_cap_token_source() {
  [ -n "${GIT_AUTH_HEADER:-}" ] && { printf 'header:GIT_AUTH_HEADER'; return 0; }
  [ -n "${GIT_TOKEN:-}" ]       && { printf 'env:GIT_TOKEN'; return 0; }
  local f
  for f in "${GIT_TOKEN_FILE:-}" ./.git-token "$HOME/.git-token"; do
    [ -n "$f" ] && [ -r "$f" ] && { printf 'file:%s' "$f"; return 0; }
  done
  # Nothing readable. Before reporting that, find out whether a candidate is
  # sitting right there with the wrong permissions: a root-owned mounted secret
  # read by a non-root process is exactly how Docker and Kubernetes present one,
  # and "GIT_TOKEN_FILE is not set" is a flat denial of something the operator did
  # set. The path is the actionable fact, so it has to reach them.
  #
  # A SECOND pass, deliberately, and not a widening of the loop above. Selecting
  # an unreadable candidate inside that loop would let an unreadable
  # GIT_TOKEN_FILE shadow a readable ./.git-token and send the push out with no
  # credential at all - a worse failure than the one being reported. Precedence
  # is unchanged: this runs only once the readable list is exhausted, so a
  # readable candidate always wins.
  #
  # `-e` is "it is there and I cannot read it". A GIT_TOKEN_FILE inside a
  # directory the process cannot even traverse fails -e as well as -r, and still
  # reports none: bash cannot tell that apart from the file not existing.
  for f in "${GIT_TOKEN_FILE:-}" ./.git-token "$HOME/.git-token"; do
    [ -n "$f" ] && [ -e "$f" ] && { printf 'unreadable:%s' "$f"; return 0; }
  done
  printf 'none'
}

_cap_auth_header() {
  local src tok=""
  # The sentinel round-trip (append a byte, then strip it) is deliberate: a bare
  # $(_cap_token_source) would let command substitution eat a trailing newline
  # that is part of a GIT_TOKEN_FILE path, silently turning a valid file: source
  # into a no-op and pushing unauthenticated. Keep this identical at both call
  # sites below.
  src="$(_cap_token_source; printf x)"; src="${src%x}"
  case "$src" in
    header:*) printf 'Authorization: %s' "$GIT_AUTH_HEADER"; return 0 ;;
    env:*)    tok="$GIT_TOKEN" ;;
    # 2>/dev/null because GIT_TOKEN_FILE=/run/secrets - a mounted secrets
    # DIRECTORY rather than a file inside it - is the realistic mistake, and sed
    # then writes "read error on /run/secrets: Is a directory" straight into
    # whatever the caller was printing. An unreadable file yields no token, which
    # is already handled below.
    file:*)   tok="$(sed -n '1p' "${src#file:}" 2>/dev/null)" ;;
    # Reached by `none`, by `unreadable:<path>` (there is nothing to send: the
    # file cannot be read), and when a variable this needs (e.g. $HOME, under
    # `set -u`) is unset - the inner _cap_token_source subshell aborts, src comes
    # back empty, and we land here. Status is deliberately 0 either way - stdout
    # being empty is the signal callers must use; do not rely on $? to detect
    # "no credential".
    *)        return 0 ;;
  esac
  [ -z "$tok" ] && return 0
  printf 'Authorization: Basic %s' \
    "$(printf '%s:%s' "${GIT_TOKEN_USER:-}" "$tok" | base64 -w0)"
}

# cap_auth_describe - which credential is in force, for a human. NEVER its value.
#
# The length is here on purpose: a token truncated by an ARM template parameter,
# or carrying a stray newline from a copy and paste, is a real failure mode and
# the length settles it in one line. The value is not, and must not be: this text
# is read aloud, pasted into tickets, and printed above a log that gets committed.
cap_auth_describe() {
  local src tok=""
  src="$(_cap_token_source; printf x)"; src="${src%x}"
  case "$src" in
    header:*) printf 'GIT_AUTH_HEADER, used verbatim (%s chars)' "${#GIT_AUTH_HEADER}"; return 0 ;;
    env:*)    tok="$GIT_TOKEN"; printf 'GIT_TOKEN from the environment (%s chars)' "${#tok}"; return 0 ;;
              # 2>/dev/null for the same reason as in _cap_auth_header: a
              # GIT_TOKEN_FILE pointing at a mounted secrets DIRECTORY made sed
              # print "read error on /run/secrets: Is a directory" into the middle
              # of the preflight table, and then the table explained it as an
              # empty first line.
    file:*)   tok="$(sed -n '1p' "${src#file:}" 2>/dev/null)"
              # _cap_auth_header sends no header at all when nothing readable
              # comes back (a directory, an unreadable file, or
              # `echo $UNSET_VAR >.git-token`). Reporting "(0 chars)" here would
              # tell an operator the token IS in force when git is actually
              # running with none - exactly the disagreement this function exists
              # to prevent. The wording covers all three, because from here they
              # are indistinguishable and the operator's check is the same: look
              # at the path.
              if [ -z "$tok" ]; then
                printf '%s is unreadable or its first line is empty, so no header is sent' "${src#file:}"
              else
                printf '%s (%s chars)' "${src#file:}" "${#tok}"
              fi
              return 0 ;;
              # The file IS there; the process just cannot read it. Root-owned
              # secret mounts in Docker and Kubernetes arrive exactly this way,
              # read by a non-root container process. This used to fall through
              # to the enumeration below, which said "no readable ... GIT_TOKEN_FILE
              # ...": true, and useless. The operator does not need a list of
              # things to try, they need the one fact that closes it - the file
              # they configured is right where they put it and the permissions
              # are wrong. So name the path and name the user who cannot read it.
              #
              # Deliberately still says "no header is sent": start.sh derives the
              # ok/warn status from that phrase, so an unreadable credential warns
              # exactly as an empty one does.
    unreadable:*)
              printf '%s exists but is not readable by %s, so no header is sent and the credential you configured is not the one in use. Fix that file'"'"'s permissions, or run as a user that can read it' \
                "${src#unreadable:}" "$(whoami 2>/dev/null || echo 'this user')"
              return 0 ;;
  esac
  # Scheme-neutral on purpose. This function cannot see the remote, so it named
  # what it looked for and left the conclusion to the caller. It used to assert
  # "correct for an SSH remote", which on an https remote with no token put an
  # `ok` line saying the credential was right immediately above a FAIL telling
  # the reader to check the credential - the commonest first-run state the
  # preflight exists to diagnose, reported as two contradictions.
  #
  # Reached only when NOTHING was found at all. A file that is there but cannot be
  # read no longer lands here - _cap_token_source reports it as `unreadable:`, and
  # the branch above names the path, which is the actionable fact. Saying "no
  # GIT_TOKEN_FILE" for it flatly denied a variable the operator did set.
  #
  # "no READABLE" stays, and still earns its place: a GIT_TOKEN_FILE inside a
  # directory this process cannot traverse fails `-e` as well as `-r`, so it is
  # indistinguishable from a path that does not exist and does still land here.
  printf 'none: no readable GIT_AUTH_HEADER, GIT_TOKEN, GIT_TOKEN_FILE or .git-token, so git is used unmodified'
}

# git 2.31 (March 2021) honours GIT_CONFIG_COUNT. Older git ignores it SILENTLY,
# and silently is the whole problem: the request would go out with no credential
# and fail as a bare auth error, which is exactly the wasted round trip this
# toolkit exists to prevent. So the version is checked, never hoped for.
_cap_git_env_config() {
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

# cap_git <git-args...> - git, with the auth header attached when one is configured.
#
# The header goes through the ENVIRONMENT rather than argv. `git -c k=v` puts the
# value on this process's command line, and /proc/<pid>/cmdline is mode 444: any
# other user on the control node can read the token straight out of `ps`.
# /proc/<pid>/environ is mode 400, so the environment is owner-only. A heliograph
# control node is often a shared jump host in someone else's estate, and this
# token is frequently the only credential the tool is trusted with.
#
# It is a reduction in exposure, not a guarantee: root still reads either, and a
# core dump or a debugger sees the value in memory whichever route it took.
cap_git() {
  local hdr
  hdr="$(_cap_auth_header)"
  if [ -z "$hdr" ]; then
    git "$@"
  elif _cap_git_env_config; then
    # APPEND at the next free index rather than hard-coding slot 0: an operator
    # on a locked-down control node may already export their own GIT_CONFIG_*
    # (an ambient http.proxy, sslCAInfo, safe.directory) the same way. Slot 0
    # would silently overwrite and truncate theirs off the list, and every
    # authenticated push would start failing with a network error on a machine
    # nobody can log into to diagnose. The numeric guard matters too: a garbage
    # ambient count must fall back to 0 rather than feed a non-numeric index
    # into GIT_CONFIG_KEY_<n>, which git would then ignore while still counting
    # the slot.
    #
    # This goes through `env NAME=VALUE ... cmd` rather than a bash prefix
    # assignment (`GIT_CONFIG_KEY_$n=... git "$@"`) because bash's assignment
    # grammar requires the variable NAME to be a literal identifier in the
    # source; built from $n it isn't recognised as an assignment at all, and
    # bash instead tries to execute the literal string as a command. `env`
    # parses its own NAME=VALUE arguments regardless, and still composes with
    # (rather than replacing) the rest of the inherited environment.
    #
    # `10#` is not decoration. bash reads a leading zero as octal, so an ambient
    # GIT_CONFIG_COUNT=08 (a zero-padded count is a natural thing for a
    # template or a wrapper to emit) made `$((n + 1))` raise "08: value too great
    # for base", which under `set -uo pipefail` is a FATAL arithmetic error: git
    # was never invoked at all, and inside a `bash -c` caller it killed the
    # shell. The digit guard above cannot catch it, because 08 IS all digits.
    local n="${GIT_CONFIG_COUNT:-0}"
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    n=$((10#$n))
    env "GIT_CONFIG_COUNT=$((n + 1))" \
        "GIT_CONFIG_KEY_$n=http.extraHeader" \
        "GIT_CONFIG_VALUE_$n=$hdr" \
        git "$@"
  else
    git -c http.extraHeader="$hdr" "$@"
  fi
}

# --- ship the log back via git (the transport) -------------------------------
# cap_push <outfile> <commit-message>
# Stages ONLY that file, so nothing else is committed by accident; rebases first
# so the push can't be rejected for being behind; on push failure prints the
# local path rather than dying - a failed push must never lose the log.
cap_push() {
  local out="$1" msg="$2"
  if [ "${PUSH:-1}" = "0" ]; then
    echo "PUSH=0 - captured locally, not pushed:"
    echo "  $out"
    return 0
  fi
  cap_banner "Pushing results back"
  git add -f "$out" >/dev/null 2>&1
  # --quiet still prints a header for a newly added file, so silence it outright;
  # the operator's terminal should show progress, not a diff.
  if git diff --cached --quiet -- "$out" >/dev/null 2>&1; then
    echo "Nothing to push (no output produced?)"
    return 0
  fi
  git -c user.name="${GIT_AUTHOR_NAME:-$(whoami)}" \
      -c user.email="${GIT_AUTHOR_EMAIL:-$(whoami)@localhost}" \
      commit -q -m "$msg" -- "$out"
  # A failed rebase must not be left half-applied. Without the abort, the
  # operator is handed a checkout mid-rebase with no idea why, and the next run
  # fails before it starts - on a machine where nobody can investigate that.
  if ! cap_git pull --rebase --quiet 2>/dev/null; then
    cap_git pull --rebase 2>&1 | tail -3
    if [ -d "$(git rev-parse --git-path rebase-merge 2>/dev/null)" ] || \
       [ -d "$(git rev-parse --git-path rebase-apply 2>/dev/null)" ]; then
      echo "rebase left in progress - aborting it; the log is committed locally"
      # Bare git: abort touches no network, so cap_git would put the auth header
      # in this process's argv for nothing.
      git rebase --abort >/dev/null 2>&1
    fi
  fi
  if cap_git push --quiet 2>/dev/null; then
    echo "Pushed: $(basename "$out")"
  elif cap_git push --quiet -u origin HEAD 2>/dev/null; then
    # A branch created on the control node has no upstream, and a bare `git push`
    # refuses rather than guessing. Set it here - otherwise the very first run on
    # a new branch would capture the log and then fail to ship it.
    echo "Pushed: $(basename "$out")  (new branch - upstream set)"
  else
    # SELF-CONTAINED on purpose. This pointed at "'Pushing' in RUNNER.md", and no
    # such file ships: the operator has a transport repo of scripts and no
    # documentation at all. Sending someone to a document they do not have, at the
    # moment their push has just failed and the log is stuck on a machine nobody
    # can reach, is the worst possible time to do it. Name the next command and
    # the variables instead - everything below is in this repo or in their shell.
    echo "PUSH FAILED - run 'git push' manually. The file is committed locally:"
    echo "  $out"
    echo "  If that push fails on authentication: an ssh remote needs a key that"
    echo "  'ssh-add -l' can list; an https remote needs GIT_TOKEN, or"
    echo "  GIT_TOKEN_FILE naming a file whose first line is the token."
    echo "  './start.sh --check' reports which credential is in force here."
  fi
}
