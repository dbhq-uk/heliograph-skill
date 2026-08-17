#!/usr/bin/env bash
# =============================================================================
#  start.sh - one command that gets the loop running on this machine
# =============================================================================
#     ./start.sh                     # check this machine, then run the agent
#     ./start.sh --check             # check only, change nothing, exit
#     ./start.sh --branch task/foo   # check that branch out first
#     ./start.sh -- --once           # everything after -- goes to agent.sh
#
#  Three jobs, and nothing else:
#
#    1. Prove this machine can produce a usable capture AT ALL. The toolkit
#       depends on `sed -u` and `base64 -w0`, and neither spelling is
#       universal: `sed -u` is absent from busybox, `base64 -w0` is absent
#       from BSD/macOS base64. A busybox sed does not fail loudly: it produces
#       a log where every line carries the same timestamp, which is worse than
#       no timestamp because it looks like one.
#    2. Prove git can PUSH from here, before an hour-long step discovers that it
#       cannot. Read access is not write access, and a token that works against
#       a host's REST API says nothing about the git path.
#    3. Hand over to agent.sh.
#
#  IT DOES NOT CLONE. This file ships inside the transport repo, so by the time
#  it runs the clone has already happened. Whoever cloned owns that step.
#
#  IT INSTALLS NOTHING, and that separation is the point: this has to run on a
#  node where installing is forbidden.
#
#  `--check` CHANGES NOTHING. It is what an operator runs to answer "will this
#  work here", often before they are permitted to alter anything.
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT" || exit 1
# shellcheck source=caplib.sh disable=SC1091
. "$REPO_ROOT/caplib.sh"

CHECK_ONLY=0
WANT_BRANCH=""
AGENT_ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --check)   CHECK_ONLY=1 ;;
    --branch)
      WANT_BRANCH="${2:-}"
      if [ -z "$WANT_BRANCH" ]; then
        echo "--branch requires a branch name" >&2
        exit 2
      fi
      shift ;;
    --)
      shift
      AGENT_ARGS=("$@")
      break ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

FAILED=0
# report <ok|warn|FAIL> <label> <detail...>
# A warn is a fact worth knowing that does not stop a run. A FAIL always names
# what to do about it: this output is often the only thing the person on the far
# side has to work from.
report() {
  local status="$1" label="$2"; shift 2
  [ "$status" = "FAIL" ] && FAILED=$((FAILED + 1))
  printf '%-4s  %-12s  %s\n' "$status" "$label" "$*"
}

preflight() {
  if [ "${BASH_VERSINFO[0]:-0}" -ge 4 ]; then
    report ok bash "$BASH_VERSION"
  else
    report FAIL bash "need 4 or newer, found ${BASH_VERSION:-unknown}. Install bash 4 or newer and put it first on PATH"
  fi

  if command -v git >/dev/null 2>&1; then
    report ok git "$(git --version)"
  else
    report FAIL git "git is the transport, so nothing here works without it. Install git and put it first on PATH"
  fi

  # THE load-bearing check, and the reason this script exists.
  if [ "$(printf 'x\n' | sed -u 's/x/y/' 2>/dev/null)" = "y" ]; then
    report ok "sed -u" "the capture can run unbuffered"
  else
    report FAIL "sed -u" "this sed has no -u, so every captured line would carry the same timestamp and a hang would be invisible. Install GNU sed and put it first on PATH"
  fi

  # base64 -w0 is how caplib builds the HTTPS auth header. BSD base64 wraps.
  if printf 'x' | base64 -w0 >/dev/null 2>&1; then
    report ok "base64 -w0" "an HTTPS auth header can be built"
  else
    report FAIL "base64 -w0" "this base64 has no -w0, so cap_git cannot build an auth header for an HTTPS remote. Install GNU coreutils and put them first on PATH"
  fi

  if command -v sha256sum >/dev/null 2>&1; then
    report ok sha256sum "agent.sh can detect its own updates"
  else
    report warn sha256sum "absent, so agent.sh cannot detect its own updates: a pushed fix to agent.sh will not take effect until someone restarts it by hand"
  fi

  if date -u +%Y-%m-%dT%H:%M:%SZ >/dev/null 2>&1; then
    report ok "date -u" "$(date -u +%Y-%m-%dT%H:%M:%SZ)  <- compare this with a clock you trust"
  else
    report FAIL "date -u" "cannot produce a UTC stamp, and every line of every log needs one. Install GNU coreutils and put date first on PATH"
  fi

  if command -v setsid >/dev/null 2>&1; then
    report ok setsid "cancel can signal the step's whole process group"
  else
    report warn setsid "absent, so agent.sh falls back to 'set -m' job control"
  fi

  local br
  br="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
  if [ -n "$br" ] && [ "$br" != "HEAD" ]; then
    report ok branch "$br"
  else
    report FAIL branch "detached HEAD, and agent.sh refuses to start on one. Check out the task branch first"
  fi

  if [ -d ops-logs ] && [ -w ops-logs ]; then
    report ok ops-logs "writable"
  else
    report FAIL ops-logs "missing or not writable, so a capture would have nowhere to go. Run 'mkdir -p ops-logs', or fix its permissions"
  fi
}

# --- the credential ----------------------------------------------------------
# WHICH credential is even relevant is decided by the remote's scheme: an SSH
# key is useless against an https:// remote and a token useless against git@.
# So branch on the scheme, then report the mechanism without its value.
credential() {
  local url scheme fps rc desc st
  url="$(git remote get-url origin 2>/dev/null)"
  if [ -z "$url" ]; then
    report FAIL remote "no remote named 'origin'. Git is the transport, so there is nowhere to push a log. Add one: git remote add origin <url>"
    return 0
  fi
  case "$url" in
    git@*|ssh://*)      scheme=ssh ;;
    https://*|http://*) scheme=https ;;
    *)                  scheme=other ;;
  esac
  # People really do arrive with the token-in-URL form (transport.md says so), and
  # git redacts userinfo in its own messages while this did not: the whole
  # https://ci-user:glpat-...@host/... went to stdout, which in PR 3 and PR 4 is
  # container stdout. cap_redact does not catch this shape either, so mask it
  # here. Only a `user:password@` between `://` and the first `/` is touched, so
  # git@host:path, ssh://git@host:2222/... and a local filesystem path all pass
  # through unaltered.
  report ok remote "$(printf '%s' "$url" | sed -E 's#(://[^/@:]*):[^/@]*@#\1:***@#')  ($scheme)"

  case "$scheme" in
    ssh)
      # ssh-add's EXIT STATUS is the answer here, not its stdout. With a live
      # agent holding no keys it prints "The agent has no identities." and exits
      # 1, and piping that through `awk '{print $2}'` produced
      # `ok  ssh key  agent offers: agent` - an ok line for the transport this
      # skill recommends, in the state where the key is missing.
      #
      # 0 keys present, 1 agent reachable but empty, 2 no agent at all. The
      # operator's next move differs between the last two, so all three are told
      # apart rather than collapsed into "no key".
      fps="$(ssh-add -l 2>/dev/null)"; rc=$?
      case "$rc" in
        0) report ok "ssh key" "agent offers: $(printf '%s\n' "$fps" | awk '{print $2}' | tr '\n' ' ')" ;;
        1) report warn "ssh key" "an ssh agent is reachable but holds no keys, so nothing can authenticate through it. Run 'ssh-add <path-to-key>'. A key in ~/.ssh may still work: the read and write checks below settle it" ;;
        2) report warn "ssh key" "no ssh agent is reachable (SSH_AUTH_SOCK is ${SSH_AUTH_SOCK:-unset}). Forward one with 'ssh -A', or start one here with 'eval \$(ssh-agent)' then 'ssh-add'. A key in ~/.ssh may still work: the read and write checks below settle it" ;;
        *) report warn "ssh key" "ssh-add exited $rc, so which key is offered is unknown - it may not be installed. Install openssh-client to see the fingerprint; the read and write checks below are what settle it" ;;
      esac
      ;;
    https)
      # cap_auth_describe cannot see the remote, so it names what it looked for
      # and opines on nothing. start.sh DOES know the scheme, so the advice
      # belongs here - and the status is derived from the description rather than
      # asserted over it. "none" on an https remote is not an ok: it is the
      # commonest single reason the read check below fails.
      desc="$(cap_auth_describe)"
      st=ok
      case "$desc" in
        none*)
          st=warn
          desc="$desc. An https remote needs one of those. Set GIT_TOKEN, or re-point origin at ssh:// and use an agent key, which references/transport.md recommends" ;;
        *"no header is sent"*)
          st=warn ;;
      esac
      report "$st" token "$desc"
      ;;
    other) report warn remote "unrecognised scheme, so the checks below are what settle it" ;;
  esac
}

# --- measure it, rather than assume it ---------------------------------------
# transport.md records the trap this answers: a token that authenticates against
# a host's REST API tells you nothing about whether GIT can authenticate.
# Different credential, different path. So test the path we depend on.
#
# The write check dry-runs against a ref that DOES NOT EXIST on the remote, and
# the choice is load-bearing rather than arbitrary.
#
# `push --dry-run origin HEAD:refs/heads/<current-branch>` is refused LOCALLY as
# a non-fast-forward the moment origin holds a commit this checkout lacks, which
# is the ordinary state every time this script runs: after a reboot, after the
# SSH session died, or any time a step or a request was pushed since the clone.
# The credential is fine and the message blamed it, and the `pull --rebase` that
# would have resolved it is below and never ran. As a container entrypoint that
# is a container that refuses to start after any push.
#
# A ref that does not exist cannot be a non-fast-forward, and --dry-run creates
# nothing, so nothing is left behind on the remote. The push still negotiates
# with git-receive-pack, which is the service write access is granted on, so this
# proves write rather than merely read - which is the whole point of the check.
#
# The name is fixed rather than generated: it is greppable in a git host's audit
# log, it carries the tool's name so nobody mistakes it for someone's work, and a
# deterministic check is one an operator can reproduce by hand. It sits in
# refs/heads/ because that is the namespace agent.sh actually pushes to, and some
# hosts refuse a namespace they do not recognise - testing the path we depend on
# is the point.
WRITE_CHECK_REF="refs/heads/heliograph-write-check"

verify() {
  local out
  if out="$(cap_git ls-remote --heads origin 2>&1)"; then
    report ok "git read" "ls-remote returned $(printf '%s\n' "$out" | grep -c .) ref(s)"
  else
    report FAIL "git read" "ls-remote failed: $(printf '%s\n' "$out" | tail -1). Check the remote URL and the credential reported above"
    return 0
  fi

  # Read access is not write access, and the expensive failure is an hour-long
  # step that captures a perfect log and cannot deliver it.
  if out="$(cap_git push --dry-run origin "HEAD:$WRITE_CHECK_REF" 2>&1)"; then
    report ok "git write" "push --dry-run was accepted"
  elif printf '%s\n' "$out" | grep -qiE 'fast-forward|fetch first|behind'; then
    # Classify rather than blaming the credential for every refusal. A
    # fast-forward refusal is a statement about history, not about authorisation.
    report warn "git write" "the remote refused a fast-forward, so write access is unproven rather than denied. That is history, not the credential: the sync below pulls, and agent.sh keeps retrying. If it persists, run 'git pull --rebase' by hand"
  else
    report FAIL "git write" "push --dry-run of HEAD:$WRITE_CHECK_REF was refused: $(printf '%s\n' "$out" | tail -1). The agent would capture logs it could not deliver. Check the credential reported above has write access and not just read; a remote that restricts which branch names may be created refuses this check too"
  fi
}

echo "heliograph preflight on $(hostname -f 2>/dev/null || hostname)"
echo
preflight
credential
verify
echo

if [ "$FAILED" -gt 0 ]; then
  echo "preflight: $FAILED blocking problem(s) above. Not starting the agent."
  exit 1
fi

if [ "$CHECK_ONLY" = "1" ]; then
  echo "preflight: clear. --check was given, so stopping here without changing anything."
  exit 0
fi

# --- get on the right branch, up to date -------------------------------------
# Deliberately after the checks and after --check has already exited: this is
# the first thing here that touches the working tree.
#
# It never resolves a conflict, never forces and never discards the operator's
# work, for the same reason agent.sh does not: their local state may be the
# evidence, and destroying it to make a poll succeed is never the right trade.
if [ -n "$WANT_BRANCH" ]; then
  cap_git fetch --quiet origin >/dev/null 2>&1
  if git checkout --quiet "$WANT_BRANCH" 2>/dev/null; then
    report ok checkout "$WANT_BRANCH"
  else
    report FAIL checkout "cannot check out '$WANT_BRANCH'. It may not exist here yet, or the working tree may be dirty"
    echo
    echo "preflight: 1 blocking problem above. Not starting the agent."
    exit 1
  fi
fi

if cap_git pull --rebase --quiet >/dev/null 2>&1; then
  report ok pull "up to date with origin"
else
  # Bare git, not cap_git: abort touches no network, and cap_git would put the
  # auth header in this process's argv for nothing - visible to anyone else on
  # the box via ps. Do not "helpfully" wrap it back up.
  git rebase --abort >/dev/null 2>&1
  report warn pull "pull --rebase did not succeed, so the tree is being left alone. agent.sh will keep retrying"
fi

echo
echo "preflight: clear. Handing over to agent.sh."
echo
# exec, not a child: the operator's Ctrl-C has to reach the agent so its
# cleanup trap runs and a mid-run step gets signalled rather than orphaned.
exec ./agent.sh ${AGENT_ARGS[@]+"${AGENT_ARGS[@]}"}
