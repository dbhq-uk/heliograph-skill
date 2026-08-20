# =============================================================================
#  service.ps1 - make the loop outlive the session, on a Windows control node
# =============================================================================
#     .\service.ps1 install     # survive logout and reboot, and start now
#     .\service.ps1 status
#     .\service.ps1 logs
#     .\service.ps1 stop
#     .\service.ps1 uninstall
#
#  This is service.sh's counterpart. Same job, same division of labour: it
#  decides only HOW THE LOOP OUTLIVES THE SESSION, and it starts agent.ps1 so
#  that the bash discovery and start.sh's preflight both still happen. It
#  reimplements neither.
#
#  IT DOES NOT LOOK FOR BASH. agent.ps1 already does that, including the
#  registry lookup that is the only thing which finds bash.exe on a default Git
#  for Windows install. Registering the task against agent.ps1 rather than
#  against a bash path keeps one copy of that logic.
#
#  WHY A SCHEDULED TASK rather than a service. A Windows service needs
#  installation rights and a service wrapper for a script; a scheduled task
#  needs neither, runs as the operator, and can be told to run whether that
#  operator is logged on or not, which is the whole requirement.
# =============================================================================

$ErrorActionPreference = 'Stop'

# Overridable for the same reason service.sh's unit name is: one transport repo
# per investigation is ordinary, a fixed name would let the second install
# silently replace the first, and CI must not unregister a task somebody is
# relying on.
$TaskName = if ($env:HELIOGRAPH_SERVICE_NAME) { $env:HELIOGRAPH_SERVICE_NAME } else { 'heliograph' }
$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogFile  = Join-Path $RepoRoot '.agent-service.log'

function Assert-Prereqs {
    if (-not (Test-Path (Join-Path $RepoRoot 'agent.ps1'))) {
        throw "service.ps1: no agent.ps1 beside this script. Run it from inside a transport repo."
    }
    if (-not (Test-Path (Join-Path $RepoRoot 'start.sh'))) {
        throw "service.ps1: no start.sh beside this script. Run it from inside a transport repo."
    }
}

# The credential is where an unattended loop actually fails, and a scheduled task
# inherits nothing from the shell that registered it. GIT_TOKEN typed before
# .\agent.ps1 reaches the agent; GIT_TOKEN typed before .\service.ps1 install
# does NOT reach the task. The loop then starts, polls happily and cannot push a
# single log, which is discovered hours later by somebody waiting on the far
# side.
#
# caplib owns the credential chain, so this only reports what a detached run
# would find: a file it can read, or nothing.
function Test-Credential {
    $url = (& git -C $RepoRoot remote get-url origin 2>$null)
    if (-not $url) {
        Write-Warning "there is no origin remote. Git is the transport, so there is nowhere to push a log."
        return $false
    }
    # Only an http(s) remote needs a token. ssh uses a key, and a local path
    # needs nothing at all.
    if ($url -notmatch '^https?://') { return $true }

    foreach ($p in @($env:GIT_TOKEN_FILE, (Join-Path $RepoRoot '.git-token'), (Join-Path $HOME '.git-token'))) {
        if ($p -and (Test-Path $p)) { return $true }
    }
    if ($env:GIT_TOKEN -or $env:GIT_AUTH_HEADER) {
        Write-Warning "the credential is in THIS shell's environment, which the scheduled task will not inherit."
        Write-Warning "  A detached task starts with a fresh environment, so the loop would run and never push."
        Write-Warning "  Write it to a file the task can read instead:"
        Write-Warning "      `$env:GIT_TOKEN | Out-File -NoNewline -Encoding ascii `"`$HOME\.git-token`""
        Write-Warning "  caplib reads ~/.git-token already, so nothing else has to change."
        return $false
    }
    Write-Warning "no credential found at all. The loop will start and be unable to push."
    Write-Warning "  See references/transport.md, then run this again."
    return $false
}

function Install-Service {
    param([switch]$Force)
    Assert-Prereqs
    if (-not (Test-Credential) -and -not $Force) {
        throw "Refusing to install a loop that cannot push. Fix the above, or pass -Force if you know better."
    }

    # Redirect through -Command rather than -File, because a task's output goes
    # nowhere by default and a loop you cannot read is not much better than one
    # that died. 6>&1 catches the information stream too; agent.ps1 reports the
    # bash it picked with Write-Host.
    $inner = "& '$RepoRoot\agent.ps1' *>&1 | Out-File -FilePath '$LogFile' -Encoding utf8 -Append"
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command `"$inner`"" `
        -WorkingDirectory $RepoRoot

    # AtStartup so it comes back after a reboot without anyone logging in, which
    # is the part setsid+nohup cannot do on the Linux side either.
    $trigger = New-ScheduledTaskTrigger -AtStartup

    # S4U runs the task whether the operator is logged on or not and stores no
    # password. The trade-off is that it gets no network CREDENTIALS, which does
    # not matter here: git authenticates with a token from a file or an ssh key,
    # not with the Windows identity.
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
        -LogonType S4U -RunLevel Limited

    # ExecutionTimeLimit Zero means no limit. THE DEFAULT IS THREE DAYS, after
    # which Windows stops the task, and a loop that quietly stops after three
    # days is precisely the failure this file exists to prevent.
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 1) `
        -MultipleInstances IgnoreNew `
        -StartWhenAvailable

    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings `
        -Description "heliograph agent loop ($RepoRoot)" | Out-Null

    Start-ScheduledTask -TaskName $TaskName
    Start-Sleep -Seconds 3

    Write-Output ""
    Write-Output "installed: scheduled task '$TaskName'"
    Write-Output "mechanism: scheduled task, runs whether logged on or not, starts at boot"
    Write-Output "log      : $LogFile"
    Write-Output ""
    Write-Output "  .\service.ps1 status     what it is doing"
    Write-Output "  .\service.ps1 logs       follow the log"
    Get-Status
}

function Get-Status {
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $t) {
        Write-Output "not installed. Run: .\service.ps1 install"
        return
    }
    $info = Get-ScheduledTaskInfo -TaskName $TaskName
    Write-Output "task     : $TaskName"
    Write-Output "state    : $($t.State)"
    Write-Output "last run : $($info.LastRunTime)  result=$($info.LastTaskResult)"
    Write-Output "next run : $($info.NextRunTime)"
    Write-Output "log      : $LogFile"
    # LastTaskResult 267009 is "currently running", which reads like an error
    # code to anybody who has not looked it up.
    if ($info.LastTaskResult -eq 267009) {
        Write-Output "           (267009 means it is running now, not a failure)"
    }
}

function Show-Logs {
    if (-not (Test-Path $LogFile)) {
        throw "no log yet at $LogFile. Has it started? Run .\service.ps1 status"
    }
    Get-Content -Path $LogFile -Tail 50 -Wait
}

function Stop-Service_ {
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $t) { Write-Output "nothing was running"; return }
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Write-Output "stopped '$TaskName'"
}

function Uninstall-Service {
    Stop-Service_
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Output "removed the scheduled task '$TaskName'"
    Write-Output "the log is left at $LogFile"
}

switch ($args[0]) {
    'install'   { Install-Service -Force:($args -contains '-Force') }
    'status'    { Get-Status }
    'logs'      { Show-Logs }
    'stop'      { Stop-Service_ }
    'uninstall' { Uninstall-Service }
    default {
        Write-Output "service.ps1 - make the loop outlive the session"
        Write-Output ""
        Write-Output "  .\service.ps1 install     survive logout and reboot, and start now"
        Write-Output "  .\service.ps1 status"
        Write-Output "  .\service.ps1 logs"
        Write-Output "  .\service.ps1 stop"
        Write-Output "  .\service.ps1 uninstall"
        exit 2
    }
}
