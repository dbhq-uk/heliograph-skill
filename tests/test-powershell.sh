#!/usr/bin/env bash
# =============================================================================
#  test-powershell.sh - a Windows control node, and steps written in PowerShell
# =============================================================================
# Two things ship together here and they fail in different places:
#
#   1. LINE ENDINGS. .gitattributes pins the transport repo to LF. The point is
#      NOT to protect Windows from itself - Git for Windows' bash strips CR and
#      runs a CRLF checkout perfectly well, measured on Server 2022 with Git
#      2.55. The point is that CRLF which gets COMMITTED breaks every Linux
#      clone afterwards, and breaks it silently when the file is sourced.
#
#   2. ps_step. A .ps1 step goes through the same capture as a .sh one, so the
#      log has to come out with the same properties: every line stamped, no
#      stray CR, no ANSI escapes, and the step's OWN exit code.
#
# --- what is asserted against what -------------------------------------------
# Every value below is read back from a real run: a real bootstrap into a real
# git repo, a real capture into a real log file. Nothing here asserts against a
# fixture this file already knows the answer to. That "echoes its own input
# back" shape is the recurring defect on this project - fourteen assertions
# across earlier PRs turned out unable to fail - and the defence is to make git
# and the capture do the comparing.
#
# --- the skip ----------------------------------------------------------------
# PowerShell is not guaranteed on the machine running this suite, and on a
# Linux dev box it usually is not there. The line-ending assertions need only
# git and run unconditionally; the ps_step ones need pwsh. When it is absent
# this file says so LOUDLY and names what went unchecked, rather than quietly
# reporting a clean run. A scrollback that reads as though everything was
# checked, when half of it was not, is the same defect as a silently skipped
# checksum.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=assert.sh disable=SC1091
. "$HERE/assert.sh"
REPO="$(cd "$HERE/.." && pwd)"
BOOTSTRAP="$REPO/skills/heliograph/scripts/bootstrap.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- a real transport repo, made the way an operator would make one ----------
TR="$WORK/transport"
mkdir -p "$TR"
git -C "$TR" init -q .
git -C "$TR" config user.email test@example.invalid
git -C "$TR" config user.name test
bash "$BOOTSTRAP" "$TR" >/dev/null 2>&1

# =============================================================================
#  1. LINE ENDINGS
# =============================================================================

# bootstrap has to restore the dot, exactly as it does for gitignore. Shipping
# the file as `gitattributes` is deliberate so it governs the transport repo
# rather than the skill repo carrying it.
if [ -f "$TR/.gitattributes" ]; then
  t_ok ".gitattributes is installed with its dot restored"
else
  t_no ".gitattributes missing from a bootstrapped repo (found: $(ls -a "$TR" | tr '\n' ' '))"
fi

if [ -f "$TR/gitattributes" ]; then
  t_no "the undotted gitattributes was copied through as well, so the transport repo has both"
else
  t_ok "the undotted gitattributes is not left behind in the transport repo"
fi

# THE functional test, and the only one that proves the file does anything.
# Commit a CRLF file with autocrlf=true, then ask git what it actually STORED.
# If .gitattributes is working, the blob is LF whatever the local setting says,
# which is what stops a Windows contributor breaking every Linux clone.
git -C "$TR" add -A >/dev/null 2>&1
git -C "$TR" commit -qm "toolkit" >/dev/null 2>&1
git -C "$TR" config core.autocrlf true
printf '#!/usr/bin/env bash\r\nset -uo pipefail\r\necho hi\r\n' > "$TR/steps/crlf-probe.sh"
git -C "$TR" add steps/crlf-probe.sh >/dev/null 2>&1
git -C "$TR" commit -qm "a file written with CRLF" >/dev/null 2>&1
stored_cr="$(git -C "$TR" cat-file blob HEAD:steps/crlf-probe.sh | tr -cd '\r' | wc -c | tr -d ' ')"
if [ "$stored_cr" = "0" ]; then
  t_ok "a CRLF file committed with autocrlf=true is stored as LF, so Linux clones are safe"
else
  t_no "git stored $stored_cr CR bytes in the blob, so .gitattributes is not pinning line endings"
fi

# The working tree is pinned as well as the blob: eol=lf means checkout hands
# back LF even with autocrlf=true asking for the opposite. Restoring the file
# here also leaves the checkout clean for the preflight assertions below, which
# would otherwise find this deliberately broken file and fail on it.
rm -f "$TR/steps/crlf-probe.sh"
git -C "$TR" checkout -q -- steps/crlf-probe.sh
wt_cr="$(tr -cd '\r' < "$TR/steps/crlf-probe.sh" | wc -c | tr -d ' ')"
if [ "$wt_cr" = "0" ]; then
  t_ok "checkout hands that file back as LF, so eol=lf beats a local autocrlf=true"
else
  t_no "checkout produced $wt_cr CR bytes despite eol=lf, so the working tree is not pinned"
fi

# And the negative: without the attributes file, the same commit keeps its CRLF.
# This is what makes the assertion above capable of failing.
BARE="$WORK/noattrs"
mkdir -p "$BARE"
git -C "$BARE" init -q .
git -C "$BARE" config user.email test@example.invalid
git -C "$BARE" config user.name test
git -C "$BARE" config core.autocrlf false
printf 'echo hi\r\n' > "$BARE/f.sh"
git -C "$BARE" add f.sh >/dev/null 2>&1
git -C "$BARE" commit -qm x >/dev/null 2>&1
bare_cr="$(git -C "$BARE" cat-file blob HEAD:f.sh | tr -cd '\r' | wc -c | tr -d ' ')"
if [ "$bare_cr" != "0" ]; then
  t_ok "without .gitattributes the same commit keeps its CRLF, so the check above can fail"
else
  t_no "a repo with no .gitattributes also normalised to LF, so the test above proves nothing"
fi

# --- start.sh's probe, which must give opposite answers on different bashes --
# It asks THIS bash whether it tolerates CR rather than assuming. On Linux the
# answer is no; under Git for Windows it is yes, and reporting a blanket
# failure there would refuse to start a control node that works.
probe="$WORK/crprobe"
printf 'hg_crlf_probe=1\r\n' > "$probe"
# shellcheck disable=SC1090
if ( . "$probe" 2>/dev/null; [ "${hg_crlf_probe:-}" = "1" ] ); then
  tolerant=yes
else
  tolerant=no
fi
out="$(cd "$TR" && ./start.sh --check 2>&1 | grep -i 'line endings')"
if [ "$tolerant" = yes ]; then
  assert_contains "on a CR-tolerant bash the preflight says so instead of failing" "tolerates CR" "$out"
else
  assert_contains "on a CR-intolerant bash a clean checkout passes" "LF throughout" "$out"
fi

# Mutation, run for real: break one SOURCED file and require the preflight to
# notice. On a tolerant bash it must NOT fail, which is the whole point of the
# probe, so the expectation flips with the platform.
cp "$TR/lib/probe.sh" "$WORK/probe.sh.bak"
sed -i 's/$/\r/' "$TR/lib/probe.sh"
mut="$(cd "$TR" && ./start.sh --check 2>&1 | grep -i 'line endings')"
cp "$WORK/probe.sh.bak" "$TR/lib/probe.sh"
if [ "$tolerant" = yes ]; then
  if printf '%s' "$mut" | grep -q '^FAIL'; then
    t_no "a CR-tolerant bash was told its working checkout is broken, which would block a good Windows node"
  else
    t_ok "a CR-tolerant bash is not blocked by a CRLF checkout it can actually run"
  fi
else
  if printf '%s' "$mut" | grep -q 'lib/probe.sh'; then
    t_ok "a CRLF sourced file is caught and named on a bash that cannot run it"
  else
    t_no "a CRLF lib/probe.sh went unreported on a bash that cannot source it: got [$mut]"
  fi
fi

# =============================================================================
#  2. ps_step
# =============================================================================
PS_BIN=""
for c in pwsh powershell.exe powershell; do
  command -v "$c" >/dev/null 2>&1 && { PS_BIN="$c"; break; }
done

if [ -z "$PS_BIN" ]; then
  echo
  echo "SKIPPING every PowerShell assertion in this file: no pwsh, powershell.exe"
  echo "or powershell on PATH. NOT CHECKED, and none of it is covered elsewhere:"
  echo "  - a .ps1 step reaches the log with every line timestamped"
  echo "  - no stray CR and no ANSI escape survives into the committed log"
  echo "  - the step's OWN exit code is reported, not one leaked from a native"
  echo "    command inside it"
  echo "  - the capture stays unbuffered, so a hang is still visible"
  echo "  - agent.ps1 and the shipped .ps1 files parse"
  echo "Install PowerShell 7 (https://aka.ms/powershell) to run them."
  echo
  t_summary
  exit 0
fi

t_ok "a PowerShell interpreter is present ($PS_BIN), so the assertions below ran"

# Every .ps1 the toolkit ships has to parse. Nothing else in CI reads them, so
# without this a syntax error would ship and only fail on a Windows box.
parse_out="$("$PS_BIN" -NoProfile -Command '
  $bad = 0
  Get-ChildItem -Path $args[0] -Filter *.ps1 -Recurse -File | ForEach-Object {
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) { $bad++; Write-Output "BAD $($_.Name): $($errors[0].Message)" }
  }
  Write-Output "count=$((Get-ChildItem -Path $args[0] -Filter *.ps1 -Recurse -File).Count) bad=$bad"
' "$TR" 2>&1)"
assert_contains "every .ps1 shipped into a transport repo parses" "bad=0" "$parse_out"
if printf '%s' "$parse_out" | grep -q 'count=0'; then
  t_no "no .ps1 files were found to parse, so the assertion above checked nothing"
else
  t_ok "the parse check actually found .ps1 files to read"
fi

# --- a real capture through the real runner ---------------------------------
cat > "$TR/steps/t-clean.ps1" <<'EOF'
Write-Output "plain line"
[PSCustomObject]@{ Name = 'alpha'; Value = 1 } | Format-Table -AutoSize
EOF
# A step whose last NATIVE command fails while the step itself succeeds. This
# is the shape that made win-snapshot report failure: `git config --get` on an
# unset key exits 1, and an in-process invocation leaked that as the step's
# exit code.
cat > "$TR/steps/t-leak.ps1" <<'EOF'
Write-Output "the step itself succeeded"
git config --get heliograph.no.such.key 2>$null | Out-Null
EOF
cat > "$TR/steps/t-fail.ps1" <<'EOF'
Write-Output "this one really did fail"
exit 3
EOF
cat > "$TR/steps/t-slow.ps1" <<'EOF'
Write-Output "first"
Start-Sleep -Seconds 2
Write-Output "second"
EOF
sed -i 's|^  win)  ps_step ./steps/win-snapshot.ps1 ;;|  win)   ps_step ./steps/win-snapshot.ps1 ;;\
  tclean) ps_step ./steps/t-clean.ps1 ;;\
  tleak)  ps_step ./steps/t-leak.ps1 ;;\
  tfail)  ps_step ./steps/t-fail.ps1 ;;\
  tslow)  ps_step ./steps/t-slow.ps1 ;;|' "$TR/run.sh"

( cd "$TR" && PUSH=0 ./run.sh tclean >/dev/null 2>&1 )
LOG="$(ls -t "$TR"/ops-logs/tclean-*.txt 2>/dev/null | head -1)"
if [ -z "$LOG" ]; then
  t_no "a PowerShell step produced no log at all"
else
  t_ok "a PowerShell step produced a log through the ordinary runner"

  body_lines="$(grep -cE '^[0-9]{2}:[0-9]{2}:[0-9]{2} \| ' "$LOG")"
  if [ "$body_lines" -gt 0 ]; then
    t_ok "the PowerShell step's output is timestamped in the log ($body_lines lines)"
  else
    t_no "no timestamped lines in a PowerShell step's log"
  fi

  # The step's own text has to be there. Without this, an empty capture would
  # satisfy every "no CR, no ESC" assertion below.
  assert_contains "the step's actual output reached the log" "plain line" "$(cat "$LOG")"
  assert_contains "formatted object output reached the log too" "alpha" "$(cat "$LOG")"

  cr="$(tr -cd '\r' < "$LOG" | wc -c | tr -d ' ')"
  assert_eq "no stray CR survives into the committed log" "0" "$cr"

  esc="$(tr -cd '\033' < "$LOG" | wc -c | tr -d ' ')"
  assert_eq "no ANSI escape survives into the committed log" "0" "$esc"
fi

# --- exit codes, the bug this file exists to keep fixed ----------------------
( cd "$TR" && PUSH=0 ./run.sh tleak >/dev/null 2>&1 ); leak_rc=$?
assert_eq "a step whose internal native command fails still reports success" "0" "$leak_rc"

( cd "$TR" && PUSH=0 ./run.sh tfail >/dev/null 2>&1 ); fail_rc=$?
assert_eq "a step that genuinely exits 3 reports 3" "3" "$fail_rc"

FLOG="$(ls -t "$TR"/ops-logs/tfail-*.txt 2>/dev/null | head -1)"
if [ -n "$FLOG" ]; then
  assert_contains "a failing PowerShell step still ships a log carrying its own output" "this one really did fail" "$(cat "$FLOG")"
  assert_contains "and that log records the real exit code" "exit code    : 3" "$(cat "$FLOG")"
else
  t_no "a failing PowerShell step produced no log, and a failed run must still ship"
fi

# --- unbuffered, which is the constraint the whole toolkit exists for --------
# PowerShell pipelines buffer by default. If Out-String -Stream collected the
# step's output and released it at the end, every line would carry one
# timestamp: a log that looks fine and hides exactly the hang it was captured
# to find.
( cd "$TR" && PUSH=0 ./run.sh tslow >/dev/null 2>&1 )
SLOG="$(ls -t "$TR"/ops-logs/tslow-*.txt 2>/dev/null | head -1)"
if [ -n "$SLOG" ]; then
  stamps="$(grep -E 'first|second' "$SLOG" | grep -oE '^[0-9]{2}:[0-9]{2}:[0-9]{2}' | sort -u | wc -l | tr -d ' ')"
  if [ "$stamps" -ge 2 ]; then
    t_ok "two seconds apart, the lines carry different stamps: the capture stays unbuffered"
  else
    t_no "both lines share one timestamp, so PowerShell output is being buffered and a hang would be invisible"
  fi
else
  t_no "the slow step produced no log"
fi

t_summary
