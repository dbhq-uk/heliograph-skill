# =============================================================================
#  agent.ps1 - start the heliograph loop on a Windows control node
# =============================================================================
#     .\agent.ps1                 # preflight, then run the agent
#     .\agent.ps1 --check         # preflight only, change nothing
#     .\agent.ps1 -- --once       # everything after -- goes to agent.sh
#
#  THIS IS A LAUNCHER, NOT A PORT. It finds the bash that Git for Windows
#  already installed and hands over to start.sh. It reimplements nothing.
#
#  Why not a real PowerShell port. The capture pattern lives in caplib.sh and
#  there is exactly one of it: run.sh and caprun.sh own the log, the timestamps
#  and the push, and every step is bash. Porting would mean a second
#  implementation of the thing this toolkit is most careful about, and the two
#  would drift. The parts that look easiest to port are the ones that would
#  hurt: `sed -u` keeps the capture unbuffered so a line is stamped when it is
#  produced, and losing that gives you a log where every line carries the same
#  time, which reads like a working log while destroying the only property that
#  makes these logs worth having.
#
#  Git for Windows ships bash 4.4 or newer with GNU coreutils and a sed that
#  honours -u. Git is the transport, so a control node without git cannot
#  participate at all: the dependency is already paid for.
#
#  WHAT THIS DOES NOT SOLVE. The far side still needs bash to run the steps.
#  This makes a Windows machine able to HOST the loop; it does not make the
#  steps run natively on Windows. lib/remote.sh already reaches Windows hosts
#  over SSH and PowerShell, and that is the right shape for a Windows target.
# =============================================================================

$ErrorActionPreference = 'Stop'

# Find bash. Order matters: an explicit override first, then the registry,
# which is authoritative for where Git for Windows actually landed, then the
# usual paths, then PATH.
#
# PATH IS LAST ON PURPOSE. WSL puts a bash.exe in System32 that is not Git
# bash: it launches a Linux distribution, or fails with an install prompt if
# none exists. If a lookup found that first, the failure would be a confusing
# WSL message rather than anything about heliograph.
function Find-GitBash {
    if ($env:HELIOGRAPH_BASH) {
        if (Test-Path $env:HELIOGRAPH_BASH) { return $env:HELIOGRAPH_BASH }
        throw "HELIOGRAPH_BASH is set to '$($env:HELIOGRAPH_BASH)' but nothing is there."
    }

    foreach ($key in @(
        'HKLM:\SOFTWARE\GitForWindows',
        'HKLM:\SOFTWARE\WOW6432Node\GitForWindows',
        'HKCU:\SOFTWARE\GitForWindows'
    )) {
        try {
            $install = (Get-ItemProperty -Path $key -Name InstallPath -ErrorAction Stop).InstallPath
            $candidate = Join-Path $install 'bin\bash.exe'
            if (Test-Path $candidate) { return $candidate }
        } catch { }
    }

    foreach ($p in @(
        "$env:ProgramFiles\Git\bin\bash.exe",
        "${env:ProgramFiles(x86)}\Git\bin\bash.exe",
        "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe"
    )) {
        if ($p -and (Test-Path $p)) { return $p }
    }

    $onPath = Get-Command bash.exe -ErrorAction SilentlyContinue
    if ($onPath -and $onPath.Source -notmatch '\\System32\\') { return $onPath.Source }

    throw @"
agent.ps1: cannot find the bash that Git for Windows installs.

heliograph runs its steps in bash, and git is its transport, so a control node
needs Git for Windows either way. Install it from https://git-scm.com/download/win
and run this again.

If git is installed somewhere unusual, point at it directly:
    `$env:HELIOGRAPH_BASH = 'D:\tools\Git\bin\bash.exe'

A bash.exe in System32 is deliberately ignored. That one is WSL, which launches
a Linux distribution rather than Git bash, and using it would fail in a way that
says nothing about heliograph.
"@
}

$bash = Find-GitBash
Write-Host "agent.ps1: using $bash"

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not (Test-Path (Join-Path $repoRoot 'start.sh'))) {
    throw @"
agent.ps1: no start.sh beside this script.

This has to run from inside a transport repo. Clone the repo the far side gave
you and run it from there, or bootstrap one with
skills/heliograph/scripts/bootstrap.sh.
"@
}

# Hand over. start.sh owns the preflight, the credential checks, the branch
# checkout and the handover to agent.sh, exactly as on any other host.
#
# The path is converted to the form bash understands, and every argument is
# passed through untouched.
$repoUnix = $repoRoot -replace '\\', '/' -replace '^([A-Za-z]):', '/$1'
$argline = ($args | ForEach-Object { "'" + ($_ -replace "'", "'\''") + "'" }) -join ' '

& $bash -lc "cd '$repoUnix' && ./start.sh $argline"
exit $LASTEXITCODE
