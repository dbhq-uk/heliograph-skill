#!/usr/bin/env bash
# =============================================================================
#  test-start.sh - start.sh refuses a machine that cannot capture properly
# =============================================================================
# Be honest about the limit of these: they exercise the checks and the exit
# codes against a local bare repo, and prove nothing about whether a real
# token authenticates against a real git host. That is the one thing that
# matters most and no test here asserts it.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=assert.sh disable=SC1091
. "$HERE/assert.sh"
ROOT="$(cd "$HERE/.." && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

GIT="git -c user.email=ci@example.com -c user.name=ci"

# A transport repo with a real, pushable origin. A bare repo on disk is enough
# to exercise ls-remote and push --dry-run for real.
make_repo() {
  local d="$1"
  "$ROOT/skills/heliograph/scripts/bootstrap.sh" "$d" >/dev/null 2>&1
  git init -q --bare "$d.origin.git"
  ( cd "$d" \
      && git init -q \
      && git remote add origin "$d.origin.git" \
      && $GIT add -A \
      && $GIT commit -qm init \
      && $GIT push -q -u origin HEAD ) >/dev/null 2>&1
}

run_start() {  # run_start <repodir> [args...] - prints output, sets RC
  local d="$1"; shift
  RC=0
  OUT="$( cd "$d" && ./start.sh "$@" 2>&1 )" || RC=$?
}

# --- the happy path ----------------------------------------------------------
make_repo "$TMP/good"
run_start "$TMP/good" --check
assert_eq "--check exits 0 on a sound machine" "0" "$RC"
assert_contains "--check says the preflight is clear" "preflight: clear" "$OUT"
assert_contains "it reports the sed -u result" "sed -u" "$OUT"
assert_contains "it reports base64 -w0" "base64 -w0" "$OUT"
assert_contains "it proves read access rather than assuming it" "git read" "$OUT"
assert_contains "it proves write access rather than assuming it" "git write" "$OUT"

# --check must not touch the working tree: it is what an operator runs to answer
# "will this work here", often on a node where they are not allowed to change
# anything yet.
before="$( cd "$TMP/good" && git status --porcelain && git rev-parse HEAD )"
run_start "$TMP/good" --check
after="$( cd "$TMP/good" && git status --porcelain && git rev-parse HEAD )"
assert_eq "--check leaves the working tree and HEAD alone" "$before" "$after"

# --- usage -------------------------------------------------------------------
run_start "$TMP/good" --nonsense
assert_eq "an unknown option exits 2" "2" "$RC"

run_start "$TMP/good" --help
assert_eq "--help exits 0" "0" "$RC"
assert_contains "--help shows the usage" "start.sh" "$OUT"

# --- a sed without -u is the failure this check exists for --------------------
# busybox sed has no -u, and the damage is silent: every captured line gets the
# same timestamp, which reads like a working log.
mkdir -p "$TMP/badbin"
real_sed="$(command -v sed)"
cat > "$TMP/badbin/sed" <<EOF
#!/bin/sh
for a in "\$@"; do
  [ "\$a" = "-u" ] && { echo "sed: unrecognized option: u" >&2; exit 1; }
done
exec "$real_sed" "\$@"
EOF
chmod +x "$TMP/badbin/sed"

make_repo "$TMP/badsed"
RC=0
OUT="$( cd "$TMP/badsed" && PATH="$TMP/badbin:$PATH" ./start.sh --check 2>&1 )" || RC=$?
assert_eq "a sed without -u is a blocking failure" "1" "$RC"
assert_contains "and it names the problem" "sed -u" "$OUT"
assert_contains "and it says what to do about it" "GNU sed" "$OUT"

# --- detached HEAD -----------------------------------------------------------
make_repo "$TMP/detached"
( cd "$TMP/detached" && git checkout -q --detach HEAD ) >/dev/null 2>&1
run_start "$TMP/detached" --check
assert_eq "a detached HEAD blocks, because agent.sh would refuse to start" "1" "$RC"
assert_contains "and it says so in those terms" "detached HEAD" "$OUT"

# --- no origin ---------------------------------------------------------------
make_repo "$TMP/noremote"
( cd "$TMP/noremote" && git remote remove origin ) >/dev/null 2>&1
run_start "$TMP/noremote" --check
assert_eq "no origin blocks: git is the transport" "1" "$RC"
assert_contains "and it says which remote is missing" "origin" "$OUT"

# --- a checkout that is merely behind origin is not a credential failure -------
# This is the modal state every time start.sh runs and the agent is not already
# going: after a reboot, after the SSH session died, or any time a step or a
# request was pushed since the clone. `push --dry-run HEAD:refs/heads/<current>`
# is refused LOCALLY as a non-fast-forward in exactly that state, and reporting
# that as an auth problem made a container entrypoint that refuses to start after
# any push, while blaming a credential that was perfect. The write check therefore
# dry-runs against a ref that cannot conflict.
make_repo "$TMP/behind"
br="$( cd "$TMP/behind" && git rev-parse --abbrev-ref HEAD )"
( cd "$TMP/behind" \
    && date > pushed-since-the-clone.txt \
    && $GIT add -A && $GIT commit -qm "the author pushes a step" \
    && $GIT push -q origin HEAD \
    && git reset -q --hard HEAD~1 ) >/dev/null 2>&1
assert_eq "the fixture really is behind origin by one" "1" \
  "$( cd "$TMP/behind" && git rev-list --count "HEAD..origin/$br" )"
run_start "$TMP/behind" --check
assert_eq "a checkout behind origin still passes the preflight" "0" "$RC"
assert_contains "and the write check is accepted, not blamed on the credential" \
  "ok    git write" "$OUT"

# --dry-run must leave nothing behind: a preflight that created a branch on the
# operator's remote every time it ran would be a defect of its own.
assert_eq "the write check creates no ref on the remote" "" \
  "$( cd "$TMP/behind" && git ls-remote --heads origin | grep -o heliograph-write-check )"

# --- and write genuinely refused still blocks ---------------------------------
# Read succeeds, git-receive-pack refuses: what a read-only credential looks like.
# The check above would be worthless if it had become an unconditional pass.
make_repo "$TMP/readonly"
cat > "$TMP/denypack" <<'EOF'
#!/bin/sh
echo "remote: You are not allowed to push code to this project." >&2
exit 1
EOF
chmod +x "$TMP/denypack"
( cd "$TMP/readonly" && git config remote.origin.receivepack "$TMP/denypack" ) >/dev/null 2>&1
run_start "$TMP/readonly" --check
assert_eq "a remote that refuses receive-pack blocks" "1" "$RC"
assert_contains "read having passed is still reported, so the two are told apart" \
  "ok    git read" "$OUT"
assert_contains "and the write failure says what to check" "write access" "$OUT"
# `tail -1` handed over git's wrapped continuation instead. The remote's own words
# are the diagnostic, and this is the FAIL most likely to fire on a new machine.
assert_contains "and the remote's own refusal survives into the line" \
  "not allowed to push code" "$OUT"

# --- GitHub writes its cause in UPPERCASE, without a remote: prefix -----------
# The single highest-value case for the whole write check: a read-only deploy key
# on GitHub is what that check exists to catch. GitHub's own words are
#
#   ERROR: The key you are authenticating with has been marked as read only.
#   fatal: Could not read from remote repository.
#
# and a case-sensitive cause pattern misses the first line, matches the trailer,
# and hands the operator the trailer - Finding 5's exact defect surviving where it
# costs most. `ERROR: Repository not found.` and the SAML SSO line are identical in
# shape. The CR is in the fixture because that is how it really arrives.
make_repo "$TMP/deploykey"
cat > "$TMP/ghdeploykey" <<'EOF'
#!/bin/sh
printf 'ERROR: The key you are authenticating with has been marked as read only.\r\n' >&2
exit 1
EOF
chmod +x "$TMP/ghdeploykey"
( cd "$TMP/deploykey" && git config remote.origin.receivepack "$TMP/ghdeploykey" ) >/dev/null 2>&1
run_start "$TMP/deploykey" --check
assert_eq "a read-only deploy key blocks" "1" "$RC"
assert_contains "GitHub's uppercase ERROR: line survives into the table" \
  "ERROR: The key you are authenticating with has been marked as read only" "$OUT"
assert_eq "and the generic trailer does not stand in for it" "" \
  "$(printf '%s' "$OUT" | grep -o 'refused: fatal: Could not read from remote repository')"

# --- a GitLab-style banner is furniture, and it ate the whole budget ----------
# GitLab wraps its refusal in bare `remote:` lines and `remote: =====` rules.
# They start with `remote:`, so they match the cause pattern, and they spent all
# three lines of git_detail's budget: the operator got
#   remote:; remote: ==============================; remote: (+6 more line(s)...)
# and the sentence saying WHY was counted among the "more". The budget has to be
# spent on sentences.
make_repo "$TMP/gitlabbanner"
cat > "$TMP/glbanner" <<'EOF'
#!/bin/sh
printf 'remote: \n' >&2
printf 'remote: ========================================================\n' >&2
printf 'remote: \n' >&2
printf 'remote: GitLab: You are not allowed to push code to protected branches on this project.\n' >&2
printf 'remote: \n' >&2
printf 'remote: ========================================================\n' >&2
printf 'remote: \n' >&2
exit 1
EOF
chmod +x "$TMP/glbanner"
( cd "$TMP/gitlabbanner" && git config remote.origin.receivepack "$TMP/glbanner" ) >/dev/null 2>&1
run_start "$TMP/gitlabbanner" --check
assert_eq "a banner-wrapped refusal still blocks" "1" "$RC"
assert_contains "the sentence that says why survives the budget" \
  "You are not allowed to push code to protected branches" "$OUT"
assert_eq "a separator rule never spends a line of it" "" \
  "$(printf '%s' "$OUT" | grep -o 'remote: ====')"
assert_eq "nor does a bare remote: line" "" \
  "$(printf '%s' "$OUT" | grep -oE 'remote:(;| \(\+)')"

# --- the diagnostic must survive, and tail -1 threw it away -------------------
# git's transport failures end on a wrapped continuation ("...and the repository
# exists."), so the operator got a fragment plus a double full stop while the line
# that said what was wrong was discarded.
make_repo "$TMP/badhost"
( cd "$TMP/badhost" && git remote set-url origin git@nonexistent.invalid:x/y.git ) >/dev/null 2>&1
RC=0
OUT="$( cd "$TMP/badhost" \
        && GIT_SSH_COMMAND='ssh -o BatchMode=yes -o ConnectTimeout=5' ./start.sh --check 2>&1 )" || RC=$?
assert_eq "an unreachable ssh host blocks" "1" "$RC"
assert_contains "the line that named the cause survives" "Could not resolve hostname" "$OUT"
assert_eq "the wrapped fragment no longer stands in for it" "" \
  "$(printf '%s' "$OUT" | grep -o 'failed: and the repository exists')"
assert_eq "and the double full stop is gone" "" \
  "$(printf '%s' "$OUT" | grep -o '\.\. Check')"
# ssh writes its diagnostics with a trailing CR, which inside a printf'd table
# redraws the line over itself.
assert_eq "no carriage return reaches the table" "" \
  "$(printf '%s' "$OUT" | tr -dc '\r')"

# --- an unreachable https remote exercises the token branch ------------------
make_repo "$TMP/https"
( cd "$TMP/https" && git remote set-url origin https://example.invalid/x.git ) >/dev/null 2>&1
RC=0
OUT="$( cd "$TMP/https" && GIT_TOKEN=abcd ./start.sh --check 2>&1 )" || RC=$?
assert_eq "an unreachable remote blocks rather than starting the agent" "1" "$RC"
assert_contains "the token mechanism is named" "GIT_TOKEN" "$OUT"
assert_contains "the token length is reported" "4 chars" "$OUT"
assert_eq "the token value is never printed" "" "$(printf '%s' "$OUT" | grep -o abcd)"

# --- https with no credential at all: the commonest first-run state ------------
# The read check FAILs with "check the credential reported above"; the token line
# above it used to read `ok  token  none, so git is used unmodified - correct for
# an SSH remote` on an https remote. Two contradictory lines, neither actionable.
make_repo "$TMP/notoken"
( cd "$TMP/notoken" && git remote set-url origin https://example.invalid/x.git ) >/dev/null 2>&1
bare_env=( env -u GIT_AUTH_HEADER -u GIT_TOKEN -u GIT_TOKEN_FILE HOME="$TMP/notoken" )
RC=0
OUT="$( cd "$TMP/notoken" && "${bare_env[@]}" ./start.sh --check 2>&1 )" || RC=$?
assert_contains "no credential on an https remote is a warn, not an ok" "warn  token" "$OUT"
assert_eq "and it no longer calls that correct for an SSH remote" "" \
  "$(printf '%s' "$OUT" | grep -o 'correct for an SSH remote')"
assert_contains "and it names what was looked for" \
  "no readable GIT_AUTH_HEADER, GIT_TOKEN, GIT_TOKEN_FILE or .git-token" "$OUT"
assert_contains "and says what to do about it on an https remote" "ssh://" "$OUT"

# The status must be DERIVED from the description, not asserted over it: describe
# reports "so no header is sent" for a token file that is unreadable or whose
# first line is empty, and git then runs with no credential at all.
: > "$TMP/notoken/.git-token"
RC=0
OUT="$( cd "$TMP/notoken" && "${bare_env[@]}" ./start.sh --check 2>&1 )" || RC=$?
assert_contains "an empty token file is a warn, not an ok" "warn  token" "$OUT"
assert_contains "and the line says no header is sent" "no header is sent" "$OUT"

# --- a token embedded in the remote URL is a credential too --------------------
# transport.md records that people arrive with this form, git redacts userinfo in
# its own messages, and cap_redact does not catch this shape. The remote line
# printed it verbatim, which in PRs 3 and 4 is container stdout.
make_repo "$TMP/urltoken"
( cd "$TMP/urltoken" \
    && git remote set-url origin https://ci-user:glpat-SUPERSECRET@git.invalid/p/t.git \
  ) >/dev/null 2>&1
RC=0
OUT="$( cd "$TMP/urltoken" && ./start.sh --check 2>&1 )" || RC=$?
assert_eq "a token in the remote URL is never printed" "" \
  "$(printf '%s' "$OUT" | grep -o glpat-SUPERSECRET)"
assert_contains "the rest of the URL still is, or the line diagnoses nothing" \
  "https://ci-user:***@git.invalid/p/t.git" "$OUT"
# A bare "none" would read as "you have nothing configured" while git is about to
# authenticate perfectly well with what the URL carries.
assert_contains "and the token line says the URL carries its own credential" \
  "The remote URL carries its own credential" "$OUT"

# --- and so is a BARE token in the remote URL, which has no colon at all --------
# `https://ghp_...@github.com/org/repo.git` is the commonest GitHub PAT clone URL
# there is, and the mask above requires a colon, so this form was printed verbatim
# AND reported as "none" - the preflight telling an operator no credential is
# configured while git was about to authenticate with the one in the URL.
make_repo "$TMP/urlbaretoken"
( cd "$TMP/urlbaretoken" \
    && git remote set-url origin https://ghp_SUPERSECRETPAT@github.invalid/p/t.git \
  ) >/dev/null 2>&1
RC=0
OUT="$( cd "$TMP/urlbaretoken" \
        && env -u GIT_AUTH_HEADER -u GIT_TOKEN -u GIT_TOKEN_FILE \
               HOME="$TMP/urlbaretoken" ./start.sh --check 2>&1 )" || RC=$?
assert_eq "a bare token in the remote URL is never printed" "" \
  "$(printf '%s' "$OUT" | grep -o ghp_SUPERSECRETPAT)"
assert_contains "the host and path still are, or the line diagnoses nothing" \
  "https://***@github.invalid/p/t.git" "$OUT"
# The masked-vs-original comparison is what decides this, so masking the bare form
# is also what stops the token line reporting a bare "none" for it.
assert_contains "and the bare form counts as a credential too" \
  "The remote URL carries its own credential" "$OUT"

# ssh and local remotes must come through untouched: masking a colon in
# git@host:path would make the line useless for the transport we recommend.
make_repo "$TMP/urlssh"
( cd "$TMP/urlssh" && git remote set-url origin git@git.invalid:p/t.git ) >/dev/null 2>&1
RC=0
OUT="$( cd "$TMP/urlssh" && ./start.sh --check 2>&1 )" || RC=$?
assert_contains "an scp-form ssh remote is printed unaltered" \
  "git@git.invalid:p/t.git" "$OUT"
assert_contains "and a local path remote is too" \
  "$TMP/good.origin.git" "$( cd "$TMP/good" && ./start.sh --check 2>&1 )"

# --- ssh-add's exit status, not its stdout ------------------------------------
# With a live agent holding no keys, ssh-add prints "The agent has no identities."
# on stdout and exits 1, so `awk '{print $2}'` produced
# `ok  ssh key  agent offers: agent`: an ok line for the transport this skill
# recommends, in the state where the key is missing. 0 with identities, 1 for
# agent-but-empty, 2 for no agent, and the operator's next move differs between
# the last two, so all three are told apart.
make_repo "$TMP/sshkey"
( cd "$TMP/sshkey" && git remote set-url origin git@example.invalid:x/y.git ) >/dev/null 2>&1
mkdir -p "$TMP/sshbin"
fake_ssh_add() {  # fake_ssh_add <exit-status> <stdout-line>
  cat > "$TMP/sshbin/ssh-add" <<EOF
#!/bin/sh
echo "$2"
exit $1
EOF
  chmod +x "$TMP/sshbin/ssh-add"
}
ssh_out() {
  ( cd "$TMP/sshkey" && PATH="$TMP/sshbin:$PATH" \
      GIT_SSH_COMMAND='ssh -o BatchMode=yes -o ConnectTimeout=5' ./start.sh --check 2>&1 )
}

fake_ssh_add 0 "256 SHA256:AAAA0000 the-key (ED25519)"
OUT="$(ssh_out)"
assert_contains "ssh-add exit 0: the fingerprint is what gets reported" \
  "ok    ssh key       agent offers: SHA256:AAAA0000" "$OUT"

fake_ssh_add 1 "The agent has no identities."
OUT="$(ssh_out)"
assert_contains "ssh-add exit 1: an empty agent is a warn, not an ok" "warn  ssh key" "$OUT"
assert_eq "ssh-add exit 1: 'agent' is never mistaken for a fingerprint" "" \
  "$(printf '%s' "$OUT" | grep -o 'agent offers: agent')"
assert_contains "ssh-add exit 1: and it says to add a key" "ssh-add <path-to-key>" "$OUT"

fake_ssh_add 2 "Could not open a connection to your authentication agent."
OUT="$(ssh_out)"
assert_contains "ssh-add exit 2: no agent at all is a warn" "warn  ssh key" "$OUT"
assert_contains "ssh-add exit 2: and the action is a different one" "ssh -A" "$OUT"
assert_contains "ssh-add exit 2: naming the variable that decides it" "SSH_AUTH_SOCK" "$OUT"

fake_ssh_add 127 "ssh-add: not found"
OUT="$(ssh_out)"
assert_contains "an unexpected ssh-add status says so rather than guessing" \
  "ssh-add exited 127" "$OUT"

# --- the handover ------------------------------------------------------------
# start.sh must exec agent.sh rather than run it as a child, so that the
# operator's Ctrl-C reaches the agent and its cleanup trap fires. A stub agent
# that reports its own pid is how that gets proved.
make_repo "$TMP/handover"
cat > "$TMP/handover/agent.sh" <<'EOF'
#!/usr/bin/env bash
echo "STUB AGENT pid=$$ args=$*"
EOF
chmod +x "$TMP/handover/agent.sh"

RC=0
OUT="$( cd "$TMP/handover" && ./start.sh 2>&1 )" || RC=$?
assert_eq "without --check it runs the agent" "0" "$RC"
assert_contains "and the agent actually ran" "STUB AGENT" "$OUT"

RC=0
OUT="$( cd "$TMP/handover" && ./start.sh -- --once --interval 15 2>&1 )" || RC=$?
assert_contains "args after -- reach agent.sh" "args=--once --interval 15" "$OUT"

# exec, not a subshell: the agent must end up with start.sh's own pid.
RC=0
OUT="$( cd "$TMP/handover" && bash -c 'echo "SHELL pid=$$"; exec ./start.sh' 2>&1 )" || RC=$?
shell_pid="$(printf '%s\n' "$OUT" | sed -n 's/^SHELL pid=//p')"
agent_pid="$(printf '%s\n' "$OUT" | sed -n 's/.*STUB AGENT pid=\([0-9]*\).*/\1/p')"
assert_eq "agent.sh is exec'd, so Ctrl-C reaches it" "$shell_pid" "$agent_pid"

# --check must still not reach the agent.
RC=0
OUT="$( cd "$TMP/handover" && ./start.sh --check 2>&1 )" || RC=$?
assert_eq "--check does not run the agent" "" "$(printf '%s' "$OUT" | grep -o 'STUB AGENT')"

# --- --branch ----------------------------------------------------------------
make_repo "$TMP/branchy"
cp "$TMP/handover/agent.sh" "$TMP/branchy/agent.sh"
( cd "$TMP/branchy" && $GIT checkout -q -b task/probe && $GIT push -q -u origin task/probe \
    && git checkout -q - ) >/dev/null 2>&1
RC=0
OUT="$( cd "$TMP/branchy" && ./start.sh --branch task/probe 2>&1 )" || RC=$?
assert_eq "--branch checks the branch out" "task/probe" \
  "$( cd "$TMP/branchy" && git rev-parse --abbrev-ref HEAD )"
assert_contains "and says it did" "task/probe" "$OUT"

RC=0
OUT="$( cd "$TMP/branchy" && ./start.sh --branch task/nope 2>&1 )" || RC=$?
assert_eq "a branch that does not exist blocks" "1" "$RC"
assert_contains "and names it" "task/nope" "$OUT"

# --- --branch validation -------------------------------------------------------
# Harmless while WANT_BRANCH was inert; once the sync acts on it, a missing or
# empty value must not silently become a no-op checkout.
RC=0
OUT="$( cd "$TMP/good" && ./start.sh --branch 2>&1 )" || RC=$?
assert_eq "--branch with no value is a usage error" "2" "$RC"
assert_contains "and it names the problem" "--branch" "$OUT"

t_summary
