# =============================================================================
#  test-scheduled-task.ps1 - service.ps1 registers a task Windows will keep
# =============================================================================
#  The Windows runner already proves station.ps1 finds bash and hands over.
#  It has never installed the scheduled task, which is the whole point of
#  service.ps1 and the reason a Windows control node survives a reboot.
#
#  THE ASSERTION THAT EARNS THE RUNNER
#
#  ExecutionTimeLimit. The default is THREE DAYS, after which Windows stops the
#  task without comment. A loop that quietly dies after three days is precisely
#  the failure service.ps1 exists to prevent, and it is invisible for three days
#  - long after whoever installed it has stopped watching, on a machine that is
#  usually somebody else's.
#
#  That setting is our belief about what Windows will do. Reading it back from
#  the registered task is the only way to know Windows agrees. Same argument as
#  the launchd KeepAlive test: a setting in a file is a belief about somebody
#  else's software until something loads it.
#
#  Output format matches tests/assert.sh on purpose - `ok`, `FAIL`, `SKIP` and
#  a summary line - so the CI guard that refuses a silent skip greps for the
#  same thing here as everywhere else.
# =============================================================================
$ErrorActionPreference = 'Continue'

$script:Pass = 0
$script:Fail = 0
$script:Skip = 0
function t_ok   { param($m) $script:Pass++; Write-Output "ok   $m" }
function t_no   { param($m) $script:Fail++; Write-Output "FAIL $m" }
function t_skip { param($m) $script:Skip++; Write-Output "SKIP $m" }
function t_eq {
  param($what, $expected, $actual)
  if ("$expected" -eq "$actual") { t_ok $what }
  else { t_no $what; Write-Output "     expected: [$expected]"; Write-Output "     actual:   [$actual]" }
}

if (-not (Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue)) {
  t_skip "no ScheduledTasks module: the task was NOT registered."
  Write-Output ""
  Write-Output "test-scheduled-task.ps1: $script:Pass passed, $script:Fail failed, $script:Skip skipped"
  exit 0
}

# A name of its own, so this cannot stop or remove a real loop belonging to
# whoever is running the tests.
$env:HELIOGRAPH_SERVICE_NAME = "heliograph-selftest-$PID"
$TaskName = $env:HELIOGRAPH_SERVICE_NAME

$repoRoot = Split-Path -Parent $PSScriptRoot
$work = Join-Path ([System.IO.Path]::GetTempPath()) "hg-task-$PID"
$tr   = Join-Path $work "tr"
$bare = Join-Path $work "origin.git"

function Cleanup {
  Push-Location $tr -ErrorAction SilentlyContinue
  if ($?) { & powershell.exe -NoProfile -File .\service.ps1 uninstall *>&1 | Out-Null; Pop-Location }
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
  Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

try {
  # --- a transport repo, bootstrapped as an operator would -------------------
  New-Item -ItemType Directory -Force -Path $tr | Out-Null
  & git -C $tr init -q .
  & git -C $tr config user.email ci@example.invalid
  & git -C $tr config user.name ci
  & bash "$repoRoot/skills/heliograph/scripts/bootstrap.sh" $tr *>&1 | Out-Null
  & git init -q --bare $bare
  & git -C $tr remote add origin $bare
  & git -C $tr add -A
  & git -C $tr commit -qm "transport repo"
  & git -C $tr branch -M main
  & git -C $tr push -q -u origin main

  if (Test-Path (Join-Path $tr "service.ps1")) {
    t_ok "service.ps1 ships into a transport repo"
  } else {
    t_no "service.ps1 is missing from a bootstrapped repo"
    throw "cannot continue"
  }

  # --- install ---------------------------------------------------------------
  Push-Location $tr
  $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\service.ps1 install 2>&1 | Out-String
  Pop-Location
  Write-Output "--- service.ps1 install said ---"
  Write-Output $out.Trim()
  Write-Output "--------------------------------"

  $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  if ($task) {
    t_ok "a scheduled task called '$TaskName' is registered"
  } else {
    t_no "no scheduled task was registered"
    throw "cannot continue"
  }

  # --- THE ONE THAT MATTERS --------------------------------------------------
  # PT0S is "no limit". Anything else, and Windows stops the loop after that
  # long - three days by default, silently, on somebody else's machine.
  $limit = $task.Settings.ExecutionTimeLimit
  if ($limit -eq 'PT0S' -or [string]::IsNullOrEmpty($limit)) {
    t_ok "ExecutionTimeLimit is unlimited, so the loop is not stopped after three days"
  } else {
    t_no "ExecutionTimeLimit is '$limit', so Windows will stop the loop after that"
    Write-Output "     The default is three days. A loop that dies after three days is"
    Write-Output "     the exact failure service.ps1 exists to prevent, and it is"
    Write-Output "     invisible until long after anyone is still watching."
  }

  # --- the rest of the settings that were chosen for a reason ----------------
  # AtStartup is what brings the loop back after a reboot without a logon. It is
  # the property setsid+nohup cannot provide on the Linux side either.
  $triggerKinds = @($task.Triggers | ForEach-Object { $_.CimClass.CimClassName })
  if ($triggerKinds -contains 'MSFT_TaskBootTrigger') {
    t_ok "it triggers at startup, so a reboot does not end the investigation"
  } else {
    t_no "no boot trigger; the loop would not come back after a restart"
    Write-Output "     triggers: $($triggerKinds -join ', ')"
  }

  # Two stations on one checkout both answer the same request and race on the
  # push. station.ps1 has a lock file; this is the same rule at the task level.
  t_eq "a second instance is ignored rather than started alongside" `
    "IgnoreNew" $task.Settings.MultipleInstances

  # S4U: runs whether the operator is logged on or not, and stores no password.
  t_eq "it runs whether the operator is logged on or not" `
    "S4U" $task.Principal.LogonType

  # Limited, not Highest. The loop refuses to run as root on Linux for the same
  # reason: the blast radius should be one account.
  t_eq "it runs unelevated" "Limited" $task.Principal.RunLevel

  # --- it actually started ---------------------------------------------------
  $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
  $running = $false
  foreach ($i in 1..15) {
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($t -and $t.State -eq 'Running') { $running = $true; break }
    Start-Sleep -Seconds 2
  }
  if ($running) {
    t_ok "the task is Running, so Windows actually started the loop"
  } else {
    $st = (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue).State
    $rc = (Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue).LastTaskResult
    t_no "the task never reached Running (state=$st, LastTaskResult=$rc)"
  }

  # --- status reports what is true -------------------------------------------
  Push-Location $tr
  $st = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\service.ps1 status 2>&1 | Out-String
  Pop-Location
  if ($st -match [regex]::Escape($TaskName)) {
    t_ok "status names the task"
  } else {
    t_no "status does not name the task: $($st.Trim())"
  }

  # --- uninstall leaves nothing behind ---------------------------------------
  Push-Location $tr
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\service.ps1 uninstall *>&1 | Out-Null
  Pop-Location
  if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    t_no "uninstall left the task registered"
  } else {
    t_ok "uninstall removed the task"
  }
}
catch {
  t_no "the test could not complete: $_"
}
finally {
  Cleanup
}

Write-Output ""
Write-Output "test-scheduled-task.ps1: $script:Pass passed, $script:Fail failed, $script:Skip skipped"
if ($script:Fail -gt 0) { exit 1 } else { exit 0 }
