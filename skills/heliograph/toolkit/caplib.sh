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
# Requires bash 4+, git, and GNU coreutils/sed: `sed -u` keeps the capture
# unbuffered so a line is stamped when it is produced rather than when the block
# flushes, and `base64 -w0` builds the HTTPS auth header. Both are GNU-only
# spellings. A control node is a Linux box in practice; on macOS install GNU
# coreutils and gnu-sed, and put them first on PATH.
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
cap_redact() {
  if [ "${REDACT:-1}" = "0" ]; then cat; return 0; fi
  sed -u -E \
    -e "s/((password|passwd|pwd|secret|token|api[_-]?key|client_secret|sas|connectionstring)[\"\x27]?[[:space:]]*[:=][[:space:]]*[\"\x27]?)[^\"\x27[:space:],;}]+/\1***REDACTED***/gI" \
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
# Prints nothing when none of them is set, in which case git is used unmodified
# - which is the SSH case, and is correct.

# Which mechanism supplies the credential, by NAME. One precedence list, used
# both to build the header and to report it: a report that could disagree with
# what git actually uses would be worse than no report at all.
#
# Prints exactly one of:
#   header:GIT_AUTH_HEADER   env:GIT_TOKEN   file:<path>   none
_cap_token_source() {
  [ -n "${GIT_AUTH_HEADER:-}" ] && { printf 'header:GIT_AUTH_HEADER'; return 0; }
  [ -n "${GIT_TOKEN:-}" ]       && { printf 'env:GIT_TOKEN'; return 0; }
  local f
  for f in "${GIT_TOKEN_FILE:-}" ./.git-token "$HOME/.git-token"; do
    [ -n "$f" ] && [ -r "$f" ] && { printf 'file:%s' "$f"; return 0; }
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
    file:*)   tok="$(sed -n '1p' "${src#file:}")" ;;
    # Also reached when a variable this needs (e.g. $HOME, under `set -u`) is
    # unset: the inner _cap_token_source subshell aborts, src comes back empty,
    # and we land here. Status is deliberately 0 either way - stdout being empty
    # is the signal callers must use; do not rely on $? to detect "no credential".
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
    file:*)   tok="$(sed -n '1p' "${src#file:}")"
              # _cap_auth_header sends no header at all when the file's first
              # line is empty (a directory, or `echo $UNSET_VAR >.git-token`).
              # Reporting "(0 chars)" here would tell an operator the token IS
              # in force when git is actually running with none - exactly the
              # disagreement this function exists to prevent.
              if [ -z "$tok" ]; then
                printf '%s, but its first line is empty, so no header is sent' "${src#file:}"
              else
                printf '%s (%s chars)' "${src#file:}" "${#tok}"
              fi
              return 0 ;;
  esac
  printf 'none, so git is used unmodified - correct for an SSH remote'
}

# cap_git <git-args...> - git, with the auth header attached when one is configured.
cap_git() {
  local hdr; hdr="$(_cap_auth_header)"
  if [ -n "$hdr" ]; then git -c http.extraHeader="$hdr" "$@"; else git "$@"; fi
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
      cap_git rebase --abort >/dev/null 2>&1
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
    echo "PUSH FAILED - run 'git push' manually. The file is committed locally:"
    echo "  $out"
    echo "  (if this is an auth failure, see 'Pushing' in RUNNER.md)"
  fi
}
