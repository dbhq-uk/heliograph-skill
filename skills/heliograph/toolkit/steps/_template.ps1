# =============================================================================
#  _template.ps1 - copy this to start a PowerShell step
# =============================================================================
# heliograph-mode: read-only     # the runner refuses a step that declares nothing.
#                                # Use `action` for a step that changes state.
#  A step PRINTS TO STDOUT AND NOTHING ELSE.
#
#  It does not open the log, write timestamps, commit, or push. run.sh and
#  caplib.sh own all of that, which is what lets you run this file straight to
#  a terminal while you are writing it:
#
#      pwsh -File ./steps/my-step.ps1
#
#  Wire it up by adding one line to run.sh's table:
#
#      mystep) ps_step ./steps/my-step.ps1 ;;
#
#  ps_step is what pins the output to UTF-8 and LF. Do not invoke PowerShell
#  yourself in the table: Windows PowerShell emits UTF-16LE when redirected,
#  which fills the captured log with NUL bytes, and CRLF endings leave a stray
#  CR on every line.
#
#  RULES, all of them paid for by an investigation that went wrong first:
#
#    NEVER PROMPT. No Read-Host, no -Confirm, no credential dialog. A prompt
#    through the capture pipeline is invisible and the run just hangs until
#    somebody notices, which is a wasted round trip through an operator.
#
#    NEVER BUFFER OUTPUT AND PRINT IT AT THE END. Every line is timestamped
#    when it is produced. Collecting into a variable and writing it in one go
#    gives every line the same time, which is worse than no timestamp because
#    it looks like one.
#
#    READ-ONLY UNLESS THE STEP IS DECLARED AN ACTION. If it changes anything,
#    add its name to run.sh's CONFIRM gate and never make it the default step.
# =============================================================================

$ErrorActionPreference = 'Continue'

# Wrap each probe. On a locked-down box any single command can be refused, and
# the value of a diagnostic is the other twenty answers rather than the first
# failure. This is the PowerShell spelling of the toolkit's `probe`.
function Probe($name, [scriptblock]$body) {
    try {
        $out = & $body 2>&1
        if ($null -eq $out) { Write-Output "${name}: (no result)" } else { Write-Output $out }
    } catch {
        Write-Output "${name}: FAILED - $($_.Exception.Message)"
    }
}

Write-Output "--- what this step is for ---"

Probe "example" { Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version | Format-List }

# Exit non-zero to report failure. run.sh still writes the footer, still records
# the real code, and still pushes the log: a failed run ships like any other.
# exit 1
