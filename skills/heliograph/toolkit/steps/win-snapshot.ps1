# =============================================================================
#  win-snapshot.ps1 - what env-snapshot.sh is, for a Windows control node
# =============================================================================
#  Read-only. Prints to stdout and nothing else: run.sh owns the log, the
#  timestamps and the push, so this never opens a file and never calls git.
#
#  It never prompts. A prompt through the capture pipeline is invisible and the
#  run simply hangs, which is why every command here is non-interactive and why
#  run.sh invokes PowerShell with -NonInteractive.
#
#  Run it straight to a terminal while writing it:
#      pwsh -File ./steps/win-snapshot.ps1
# =============================================================================

$ErrorActionPreference = 'Continue'

# The tally, and it is load-bearing. Without it this script printed "FAILED" on
# every probe and still exited 0, so run.sh wrote "RESULT: OK" over a log in
# which nothing had worked. Found by running it on Linux, where pwsh exists but
# Get-CimInstance and Get-WinEvent do not: twenty-odd probes failed, the footer
# said OK, and one probe even reported "no pending reboot" as a positive finding
# about a machine that has no such concept. Method rule 11 says a green exit
# means the probes that ran passed - this did not even mean that.
$script:ProbeTotal = 0
$script:ProbeFailures = 0

function Section($name) {
    Write-Output ""
    Write-Output "--- $name ---"
}

# Every probe is wrapped: on a locked-down box any single one of these can be
# refused, and the point of a snapshot is the other twenty answers, not the
# first failure. This is the PowerShell spelling of the toolkit's `probe`.
function Probe($name, [scriptblock]$body) {
    $script:ProbeTotal++
    try {
        $out = & $body 2>&1
        # A caught terminating error is not the only way a probe fails. An
        # unrecognised cmdlet arrives here as an ErrorRecord in $out with the
        # pipeline still succeeding, so count that too or a missing command
        # reads as a clean answer.
        $errs = @($out | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
        if ($errs.Count -gt 0) {
            $script:ProbeFailures++
            Write-Output "${name}: FAILED - $($errs[0].Exception.Message)"
            return
        }
        if ($null -eq $out -or ($out -is [array] -and $out.Count -eq 0)) {
            Write-Output "${name}: (no result)"
        } else {
            Write-Output $out
        }
    } catch {
        $script:ProbeFailures++
        Write-Output "${name}: FAILED - $($_.Exception.Message)"
    }
}

# The PowerShell spelling of probe_summary. Same contract: print the tally and
# exit non-zero if anything failed, so run.sh's footer tells the truth.
function Probe-Summary {
    Write-Output ""
    Write-Output "---------- summary ----------"
    Write-Output "probes: $script:ProbeTotal   failed: $script:ProbeFailures"
    if ($script:ProbeFailures -gt 0) { exit 1 }
    exit 0
}

Section "identity"
Probe "whoami"   { whoami }
Probe "hostname" { [System.Net.Dns]::GetHostName() }
Probe "elevated" {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    "elevated: $($p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))"
}

Section "os"
Probe "os" {
    Get-CimInstance Win32_OperatingSystem |
        Select-Object Caption, Version, BuildNumber, OSArchitecture, LastBootUpTime |
        Format-List
}
Probe "uptime" {
    $b = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    "up since $($b.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')) UTC"
}

Section "powershell"
Write-Output "edition : $($PSVersionTable.PSEdition)"
Write-Output "version : $($PSVersionTable.PSVersion)"
Write-Output "policy  : $(Get-ExecutionPolicy)"

Section "tooling"
foreach ($t in 'git', 'pwsh', 'powershell', 'ssh', 'terraform', 'az', 'kubectl', 'python') {
    $c = Get-Command $t -ErrorAction SilentlyContinue
    if ($c) { Write-Output ("{0,-12} {1}" -f $t, $c.Source) }
    else    { Write-Output ("{0,-12} absent" -f $t) }
}

# THE check that matters on Windows, and the reason a Windows control node
# needs a snapshot of its own. autocrlf=true rewrites LF to CRLF on checkout,
# and bash cannot run a script with a stray CR. A sourced one does not even
# stop: it loses `set -uo pipefail` and carries on.
Section "git line endings"
Probe "autocrlf" {
    $v = git config --get core.autocrlf 2>$null
    if ([string]::IsNullOrWhiteSpace($v)) { $v = '(unset, which means true on a Git for Windows install)' }
    "core.autocrlf : $v"
}
Probe "attributes" {
    if (Test-Path .gitattributes) { ".gitattributes : present, so the working tree is pinned to LF" }
    else { ".gitattributes : ABSENT - a checkout here can arrive with CRLF and bash will not run it" }
}

Section "disk"
Probe "volumes" {
    Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' |
        Select-Object DeviceID,
            @{n = 'SizeGB';  e = { [math]::Round($_.Size / 1GB, 1) }},
            @{n = 'FreeGB';  e = { [math]::Round($_.FreeSpace / 1GB, 1) }},
            @{n = 'FreePct'; e = { if ($_.Size) { [math]::Round(100 * $_.FreeSpace / $_.Size) } } } |
        Format-Table -AutoSize
}

Section "network"
Probe "addresses" {
    Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
        Where-Object { $_.IPAddress -ne '127.0.0.1' } |
        Select-Object InterfaceAlias, IPAddress, PrefixLength |
        Format-Table -AutoSize
}
Probe "dns" { (Get-DnsClientServerAddress -AddressFamily IPv4).ServerAddresses | Sort-Object -Unique }
Probe "proxy" {
    $k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $p = Get-ItemProperty -Path $k -ErrorAction Stop
    "ProxyEnable : $($p.ProxyEnable)"
    "ProxyServer : $($p.ProxyServer)"
}
foreach ($v in 'HTTP_PROXY', 'HTTPS_PROXY', 'NO_PROXY') {
    $val = [Environment]::GetEnvironmentVariable($v)
    if ($val) { Write-Output "$v = $val" }
}

Section "services that should be running and are not"
Probe "services" {
    Get-CimInstance Win32_Service -Filter "StartMode='Auto' AND State!='Running'" |
        Select-Object Name, State, StartMode, ExitCode |
        Format-Table -AutoSize
}

Section "recent errors, System log, last 24h"
Probe "system-errors" {
    Get-WinEvent -FilterHashtable @{
        LogName   = 'System'
        Level     = 1, 2
        StartTime = (Get-Date).AddHours(-24)
    } -MaxEvents 25 -ErrorAction Stop |
        Select-Object @{n = 'TimeUTC'; e = { $_.TimeCreated.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }},
                      Id, ProviderName,
                      @{n = 'Message'; e = { ($_.Message -split "`r?`n")[0] } } |
        Format-Table -AutoSize -Wrap
}

Section "recent errors, Application log, last 24h"
Probe "app-errors" {
    Get-WinEvent -FilterHashtable @{
        LogName   = 'Application'
        Level     = 1, 2
        StartTime = (Get-Date).AddHours(-24)
    } -MaxEvents 25 -ErrorAction Stop |
        Select-Object @{n = 'TimeUTC'; e = { $_.TimeCreated.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }},
                      Id, ProviderName,
                      @{n = 'Message'; e = { ($_.Message -split "`r?`n")[0] } } |
        Format-Table -AutoSize -Wrap
}

Section "pending reboot"
Probe "reboot" {
    $reasons = @()
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
        $reasons += 'component based servicing'
    }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
        $reasons += 'windows update'
    }
    if ($reasons.Count) { "pending reboot: $($reasons -join ', ')" } else { 'no pending reboot' }
}

Probe-Summary
