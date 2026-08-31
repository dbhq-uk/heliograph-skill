#!/usr/bin/env bash
# =============================================================================
#  test-remote.sh - reaching a Windows host, and the CR that comes back with it
# =============================================================================
# Two things, and only the first needs a Windows host to observe:
#
#   1. cap_run strips the TRAILING CR from every captured line and leaves a
#      mid-line one alone. Windows is where the CR comes from, but the fix is in
#      the one capture path, so it is testable anywhere and is tested here.
#
#   2. rt_ps builds a command that survives cmd. A Windows host running OpenSSH
#      defaults its shell to cmd, so cmd parses the command line before
#      PowerShell sees it, and a pipe in the script gets eaten. Everything about
#      the encoded form exists for that.
#
# --- what this file cannot do ------------------------------------------------
# It does NOT reach a Windows host. Nothing in CI has one. What it checks is the
# command rt_ps CONSTRUCTS, by substituting rt_ssh for a stub that prints its
# arguments, plus a real round trip of the encoder. The behaviour on the far
# side was measured by hand against Windows Server 2022 with OpenSSH and
# PowerShell 5.1, and the numbers are recorded in references/windows.md. Reading
# a green run here as proof that a remote capture works would be wrong.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=assert.sh disable=SC1091
. "$HERE/assert.sh"
REPO="$(cd "$HERE/.." && pwd)"
TOOLKIT="$REPO/skills/heliograph/toolkit"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# =============================================================================
#  1. cap_run and the trailing CR
# =============================================================================
TR="$WORK/transport"
mkdir -p "$TR"
git -C "$TR" init -q .
git -C "$TR" config user.email test@example.invalid
git -C "$TR" config user.name test
bash "$REPO/skills/heliograph/scripts/bootstrap.sh" "$TR" >/dev/null 2>&1

cat > "$TR/steps/crlf.sh" <<'EOF'
#!/usr/bin/env bash
# heliograph-mode: read-only
printf 'windows line one\r\n'
printf 'windows line two\r\n'
printf 'midline\rprogress on one line\n'
printf 'plain unix line\n'
EOF
chmod +x "$TR/steps/crlf.sh"
sed -i 's|^  net)  CMD=(./steps/net-probe.sh) ;;|  net)  CMD=(./steps/net-probe.sh) ;;\
  crlf) CMD=(./steps/crlf.sh) ;;|' "$TR/run.sh"

( cd "$TR" && PUSH=0 ./run.sh crlf >/dev/null 2>&1 )
LOG="$(ls -t "$TR"/ops-logs/crlf-*.txt 2>/dev/null | head -1)"

if [ -z "$LOG" ]; then
  t_no "the CRLF step produced no log"
else
  # The step's own text must be present, or every "no CR" assertion below would
  # be satisfied by an empty capture.
  assert_contains "the step's output reached the log" "windows line one" "$(cat "$LOG")"

  # COUNT THE CR BYTES, do not grep for them. On Git for Windows' bash, MSYS
  # grep and MSYS shell redirection disagree about text translation, so
  # `grep -cE $'\r$'` reported 20 CRLF line endings in this very log while `tr`,
  # `git status` and the blob all agreed there was exactly one CR in it. `tr` is
  # the one that matched git, so `tr` is what this file uses. The first version
  # of these assertions used grep and failed only on Windows, which is precisely
  # the platform they exist to describe.
  #
  # One number says everything. The step writes two CRLF lines and one deliberate
  # mid-line CR, so:
  #     1  cap_run stripped both trailing CRs and kept the mid-line one, correct
  #     3  nothing was stripped
  #     0  every CR was deleted, including the mid-line one, which would join
  #        output that was never on the same line
  total_cr="$(tr -cd '\r' < "$LOG" | wc -c | tr -d ' ')"
  assert_eq "exactly one CR survives: both trailing ones stripped, the mid-line one kept" "1" "$total_cr"

  # And the same property stated without counting anything, so a wrong count
  # cannot pass unnoticed. If the mid-line CR had been deleted, the two halves
  # would have been joined into one word.
  if grep -q 'midlineprogress' "$LOG"; then
    t_no "the mid-line CR was deleted, joining output that was never on one line"
  else
    t_ok "the two halves of the progress line are still separated by their CR"
  fi
  assert_contains "the progress line itself survived intact" "progress on one line" "$(cat "$LOG")"
fi

# Mutation, run for real: put cap_run back the way it was and require the CR to
# return. If it does not, nothing above is testing the fix.
#
# The pattern matches `do l=<anything without a semicolon>; printf` on purpose.
# Spelling the CR out means writing $'\r' inside a sed expression inside a shell
# quote, and the first version of this got that wrong in a way that only showed
# up on Windows: the substitution silently matched nothing, the mutation did not
# apply, and the test then reported that cap_run was not doing the stripping.
# `[^;]*` sidesteps the quoting entirely.
cp "$TR/caplib.sh" "$WORK/caplib.bak"
before_sum="$(cksum < "$TR/caplib.sh")"
sed -i 's/do l=[^;]*; printf/do printf/' "$TR/caplib.sh"
after_sum="$(cksum < "$TR/caplib.sh")"
if [ "$before_sum" = "$after_sum" ]; then
  t_no "the mutation did not change caplib.sh at all, so the check below would prove nothing about cap_run"
else
  rm -f "$TR"/ops-logs/crlf-*.txt
  ( cd "$TR" && PUSH=0 ./run.sh crlf >/dev/null 2>&1 )
  MLOG="$(ls -t "$TR"/ops-logs/crlf-*.txt 2>/dev/null | head -1)"
  mut_cr="$(tr -cd '\r' < "$MLOG" 2>/dev/null | wc -c | tr -d ' ')"

  # DOES THIS PLATFORM EVEN DELIVER A CRLF INTO THE CAPTURE? Probe it rather
  # than assume, because the answer differs and the difference is the whole
  # reason this block is not a single assertion.
  #
  # On Linux a CRLF written by a step arrives at cap_run's read loop intact, so
  # removing the strip puts all the CRs back and the mutation proves the fix.
  # Under Git for Windows' bash the MSYS runtime normalises the line ending
  # further up the pipeline, before cap_run sees it, so the trailing CR is
  # already gone whether cap_run strips it or not. Asserting 3 there fails and
  # blames cap_run for something MSYS did.
  #
  # This mirrors the CR-tolerance probe in start.sh: the platform is asked, not
  # assumed.
  pipe_cr="$(printf 'a\r\n' | sed -u 's/x/x/' 2>/dev/null | tr -cd '\r' | wc -c | tr -d ' ')"
  if [ "${pipe_cr:-0}" -ge 1 ]; then
    if [ "${mut_cr:-0}" -eq 3 ]; then
      t_ok "reverting cap_run puts both trailing CRs back (3 total), so the assertion above can fail"
    else
      t_no "this platform delivers CRLF into the capture, but reverting cap_run left $mut_cr CR bytes instead of 3, so cap_run is not what strips them"
    fi
  else
    # Not a skip of the assertions above: those ran and passed. This says only
    # that the MUTATION cannot demonstrate anything here, and why.
    t_ok "this shell normalises CRLF before cap_run sees it, so the trailing CR never reaches the capture on this platform and the mutation cannot demonstrate the fix (it does on Linux, and the container is Linux)"
  fi
fi
cp "$WORK/caplib.bak" "$TR/caplib.sh"

# =============================================================================
#  2. what rt_ps actually sends
# =============================================================================
# shellcheck source=/dev/null
. "$TOOLKIT/lib/remote.sh"

# Substitute the transport. rt_ps's job is to BUILD a command; whether ssh can
# deliver it is rt_ssh's problem and is not what this file is about.
rt_ssh() { printf '%s\n' "$@"; }

sent="$(rt_ps host 'Get-Service sshd | Select-Object Name,Status')"

assert_contains "rt_ps uses -EncodedCommand, so cmd cannot eat a pipe" "-EncodedCommand" "$sent"
if printf '%s' "$sent" | grep -q -- '-Command'; then
  t_no "rt_ps still passes -Command, which cmd parses before PowerShell sees it"
else
  t_ok "rt_ps no longer passes a bare -Command"
fi

# Decode what would actually run on the far side and check the whole contract.
b64="$(printf '%s\n' "$sent" | tail -1)"
decoded="$(printf '%s' "$b64" | base64 -d 2>/dev/null | iconv -f utf-16le -t utf-8 2>/dev/null)"

assert_contains "the encoding survives a round trip, so the far side gets the script" \
  "Get-Service sshd | Select-Object Name,Status" "$decoded"
assert_contains "progress is silenced, or CLIXML fills the log" \
  'ProgressPreference = "SilentlyContinue"' "$decoded"
assert_contains "output is forced to UTF-8, or the IBM437 console mangles non-ASCII" \
  "[Console]::OutputEncoding" "$decoded"
assert_contains "the streams are merged inside PowerShell, so an error is text and not CLIXML" \
  "2>&1 | Out-String -Stream" "$decoded"
assert_contains "the error count is cleared first, so the exit code can be restored" \
  '$Error.Clear()' "$decoded"
assert_contains "a remote error still produces a non-zero exit, which merging the streams otherwise loses" \
  'exit $(if ($Error.Count) { 1 } else { 0 })' "$decoded"

# The encoder itself, round-tripped rather than compared against a fixture.
enc="$(_rt_ps_encode 'Write-Output "hello"')"
back="$(printf '%s' "$enc" | base64 -d | iconv -f utf-16le -t utf-8)"
assert_eq "_rt_ps_encode round trips exactly" 'Write-Output "hello"' "$back"

# UTF-16LE means every ASCII byte is followed by a NUL. If this came back equal
# to the plain text, the encoder would be emitting UTF-8 and PowerShell would
# reject it.
nulls="$(printf '%s' "$enc" | base64 -d | tr -cd '\0' | wc -c | tr -d ' ')"
if [ "$nulls" -eq 20 ]; then
  t_ok "the encoded form really is UTF-16LE: 20 NUL bytes for 20 ASCII characters"
else
  t_no "expected 20 NUL bytes in the UTF-16LE encoding of a 20 character string, got $nulls"
fi

t_summary
