# Windows

Three separate things, and they are worth keeping apart because they fail in
different places:

- **Running the loop on a Windows machine.** `agent.ps1` does this. It is a
  launcher, not a port.
- **Writing a step in PowerShell.** `ps_step` in `run.sh` does this. It works on
  any control node that has PowerShell, including Linux.
- **Reaching a Windows machine from elsewhere.** `rt_ps` in `lib/remote.sh` does
  this, over SSH. The control node can be anything.

Everything below was measured on Windows Server 2022 with PowerShell 5.1.20348
and Git for Windows 2.55, and on Linux with pwsh 7.6.5. Where a number is
quoted, it came from a run rather than from reasoning.

## Running the loop on Windows

```powershell
.\agent.ps1                 # preflight, then run the agent
.\agent.ps1 --check         # preflight only, change nothing
.\agent.ps1 -- --once       # everything after -- goes to agent.sh
```

`agent.ps1` finds the bash that Git for Windows installed and hands over to
`start.sh`. It reimplements nothing. `start.sh` then owns the preflight, the
credential checks, the branch checkout and the handover to `agent.sh`, exactly
as it does on every other host.

### Why a launcher and not a PowerShell port

There is one implementation of the capture pattern, in `caplib.sh`, and a port
would make two. The parts that look easiest to port are the ones that would
hurt. `sed -u` keeps the capture unbuffered, so a line is stamped when it is
produced. A PowerShell version that buffered would give you a log where every
line carries the same time, which reads like a working log while destroying the
one property that makes these logs worth having.

The dependency argument also runs the other way from what you might expect. Git
is the transport, so a control node without git cannot take part at all. On
Windows, git almost always means Git for Windows, and that ships bash. The bash
is already paid for.

The exception is **MinGit**, the stripped-down Git that VS Code and GitHub
Desktop bundle. It has no bash. On a machine where that is the only git, this
launcher cannot work and there is no answer here yet.

### What Git for Windows gives you

Every hard requirement in `start.sh`'s preflight is satisfied out of the box.
Measured on a clean Server 2022 with Git 2.55 installed and nothing else:

| check | result |
|---|---|
| bash version | 5.3.15, well above the 4 the toolkit needs |
| `sed -u` | present |
| `base64 -w0` | present |
| `sha256sum` | present |
| `date -u` | present |
| `setsid` | **absent**, which only warns: `agent.sh` falls back to `set -m` |

### How bash gets found

In order: `HELIOGRAPH_BASH` if set, then the registry, then the usual install
paths, then `PATH`.

The registry is not a nicety. On a clean Server 2022 with Git for Windows
installed, `bash.exe` **is not on `PATH` at all** - only `git.exe` is, from
`C:\Program Files\Git\cmd`. `HKLM:\SOFTWARE\GitForWindows` holds `InstallPath`,
and that is what actually locates it.

`PATH` is searched last, and a `bash.exe` in `System32` is ignored on purpose.
That one is WSL. It launches a Linux distribution, or prompts to install one,
and using it would fail in a way that says nothing about heliograph.

If git is somewhere unusual, point at it directly:

```powershell
$env:HELIOGRAPH_BASH = 'D:\tools\Git\bin\bash.exe'
```

## Line endings, and what is actually true

Git for Windows sets `core.autocrlf=true` when it installs. This is at the
system level, so it applies to every repo on the machine. A transport repo
cloned on Windows therefore arrives with CRLF throughout.

**On Windows that is harmless.** Git for Windows' bash strips CR transparently.
Measured both ways, executed and sourced: a CRLF script runs identically to an
LF one, `set -uo pipefail` takes effect, `set -u` still aborts on an unbound
variable, and the exit code matches. There is nothing to fix and nothing to
warn about.

**The damage is to every other machine.** If CRLF ever gets *committed* - a
contributor with `autocrlf=false`, a file written by a Windows editor, a
generated step - then every Linux clone gets it, and Linux bash does not
forgive it:

- Executed, it stops clearly:
  `/usr/bin/env: 'bash\r': No such file or directory`
- Sourced, which is how `caplib.sh` is loaded, **it does not stop**:
  `caplib.sh: line 2: set: pipefail: invalid option name`

The second one is the reason this is documented at all. The CR attaches to
`pipefail`, so the whole `set` call fails and *neither* `-u` nor `-o pipefail`
is applied. The loop then runs with both safety options silently off, on a
machine nobody can log in to, and the first thing you learn about it is a log
that is wrong rather than a log that is missing.

### What protects against it

The toolkit ships `gitattributes`, which `bootstrap.sh` installs as
`.gitattributes`, the same trick it already uses for `gitignore`. It pins the
repo to LF whatever anyone's `core.autocrlf` says:

```
* text=auto eol=lf
```

Verified two ways. With the file present, a CRLF file committed under
`autocrlf=true` is **stored as LF** in the blob, and checkout hands it back as
LF. Without it, the same commit keeps its CRLF. That second half is what makes
the first half meaningful.

This is what lets a Windows operator and a Linux container share one transport
repo, which is the point.

### The preflight probe

`start.sh` asks *this* bash whether it tolerates CR rather than assuming:

```bash
printf 'hg_crlf_probe=1\r\n' > "$probe"
( . "$probe"; [ "${hg_crlf_probe:-}" = "1" ] )
```

On Linux that fails, because the value keeps its CR. Under Git for Windows it
passes. The check only reports a blocking failure when this bash cannot tolerate
CR **and** CRLF files are present. A blanket check would refuse to start a
Windows control node that works perfectly, which is worse than not checking.

An older draft of `agent.ps1` carried a guard that did exactly that. It was
removed once the behaviour was measured.

### Fixing a checkout that already has committed CRLF

```
git config --global core.autocrlf false
```

Then clone again. The checkout is disposable and anything already pushed is
safe. If the repo predates `.gitattributes`, re-run `bootstrap.sh` to install
it.

## Steps written in PowerShell

A step is an argv array, so the runner does not care what language it is in.
`caplib` sees a process that prints to stdout, and that is the whole contract.
Add one line to `run.sh`'s table:

```bash
win)   ps_step ./steps/win-snapshot.ps1 ;;
```

Copy `steps/_template.ps1` to start one. The rules are the same as for a bash
step: print to stdout and nothing else, never prompt, never buffer output and
print it at the end, and stay read-only unless the step is declared an action.

`toolkit/steps/win-snapshot.ps1` is a worked example, and is what
`env-snapshot.sh` is for a Windows box: OS and uptime, tooling, disk, network
and proxy, automatic services that are not running, errors from the System and
Application logs in the last 24 hours, and whether a reboot is pending.

### Why ps_step exists rather than calling PowerShell directly

Four things need fixing once, in one place, rather than by every step author who
remembers.

**Exit codes, and this is the one that would have shipped a wrong answer.**
Running a step in-process as `& './step.ps1'` leaves `$LASTEXITCODE` holding
whatever the last *native* command inside it returned. `win-snapshot.ps1` ends
by probing `git config --get core.autocrlf`, which exits 1 when the key is
unset, so a perfectly good snapshot reported failure. Invoking the step as a
child process with `-File` fixes it. Measured: 0 for a clean run, 3 for a
genuine `exit 3`, and 0 for a run whose internal native command exited 7.

**Line endings.** `powershell.exe -File` emits CRLF: CR=8 LF=8 for an eight line
script, to a file or through a pipe. A stray CR on every captured line is
invisible in a terminal, wrong in the file, and quietly breaks any later grep
anchored with `$`. Rewriting each line with an explicit LF takes CR to 0.

**Colour, and it is not the colour that needs this.** `cap_run` already strips
ANSI with `s/\x1b\[[0-9;]*[mGKHF]//g`, and that covers everything pwsh 7 emits
for `Format-Table`: 8 ESC bytes in, 0 out. So a log assertion written against a
colour-producing step passes whether `ps_step` sets `NO_COLOR` or not, and
proves nothing.

The gap is **OSC 8 hyperlinks**. pwsh writes them as `ESC]8;;<url>`, that sed
only matches `ESC[` sequences, and they go straight through into the committed
log. Measured for a step calling `$PSStyle.FormatHyperlink`: 4 ESC bytes
surviving `cap_run` without `NO_COLOR`, and 0 with it. `NO_COLOR` is what earns
its place; `PlainText` in the parent does not, and is kept only because it costs
nothing.

`tests/test-powershell.sh` asserts this with a hyperlink-emitting step and then
removes `NO_COLOR` to confirm the escape comes back, because the obvious version
of the test cannot fail.

Windows PowerShell 5.1 has no `$PSStyle` and emits no ANSI at all, so this is
pwsh 7 insurance rather than a Windows fix.

**Encoding.** Forcing UTF-8 is about the OEM codepage mangling non-ASCII. It is
*not* about UTF-16: the redirected stream measured NUL=0, so the widely repeated
"PowerShell redirects as UTF-16" does not apply to this path.

### The capture stays unbuffered

PowerShell pipelines buffer by default, so this was worth proving rather than
assuming. A step printing a line, sleeping three seconds, printing another and
sleeping again produced:

```
12:25:56 | first at the start
12:25:59 | second after three seconds
12:26:02 | third after six seconds
```

Three seconds apart, as they happened. If `Out-String -Stream` had collected
the output and released it at the end, all three would carry one timestamp: a
log that looks fine and hides exactly the hang it was captured to find.

### Which interpreter

`ps_step` looks for `pwsh`, then `powershell.exe`, then `powershell`.

The fallback matters. **Windows Server 2022 has no pwsh 7 by default** - only
Windows PowerShell 5.1. A step that needs pwsh 7 features has to say so.

## Reaching a Windows host from somewhere else

This is the other direction: the loop runs wherever it likes, and a step points
at a Windows box. `rt_ps` in `lib/remote.sh` does it over SSH.

```bash
. lib/remote.sh
rt_ps "admin@winbox" 'Get-Service sshd | Select-Object Name,Status'
rt_win_info "admin@winbox"
```

The target needs OpenSSH Server, which is an optional Windows capability:

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Start-Service sshd
Set-Service -Name sshd -StartupType Automatic
```

`rt_ssh` uses `BatchMode`, so it fails rather than prompting. Key auth is
therefore required, and for a user in the Administrators group the key goes in
`C:\ProgramData\ssh\administrators_authorized_keys`, not the user's `.ssh`
directory. That file must be owned by Administrators and SYSTEM only or sshd
ignores it.

### Everything here follows from the remote shell being cmd

A Windows OpenSSH host defaults its shell to cmd unless someone has set
`DefaultShell`. ssh joins its arguments into one command line and hands it to
that shell, so **cmd parses the command before PowerShell ever sees it**.

That ate the pipe. With a plain `-Command`, this is what came back:

```
$ rt_ps host 'Get-Service sshd | Select-Object Name,Status'
'Select-Object' is not recognized as an internal or external command,
operable program or batch file.
```

cmd took the `|` and tried to run `Select-Object` as a program. The same applies
to `&`, `<`, `>` and `^`. A PowerShell diagnostic that cannot use a pipe is
barely PowerShell, so this was the blocking problem.

`-EncodedCommand` fixes it, because base64 of UTF-16LE contains no
metacharacters for cmd to find. An older comment in `remote.sh` warned it "is
known to break through this path", and that was a real symptom with the wrong
cause: PowerShell decides it is not attached to a console and serialises its
non-stdout streams as CLIXML, so the log fills with

```
#< CLIXML
<Objs Version="1.1.0.1" ...><S S="Error">Get-Service : Cannot find ...
```

which is worst precisely when it matters most, because a remote error is usually
why you are reading the log. Two settings fix that rather than avoiding the
flag. Silencing `$ProgressPreference` removes the progress records, and merging
the streams inside PowerShell with `2>&1 | Out-String -Stream` renders errors as
text before anything can serialise them. Measured: CLIXML occurrences drop to 0
and the error reads

```
Get-Service : Cannot find any service with service name 'no-such-service-here'.
```

### Encoding, which is lossy rather than merely ugly

The remote console is IBM437 out of the box. Sent through unchanged, `é ü €`
came back as the bytes `202 201 ?`: not valid UTF-8, and the euro sign
**destroyed outright**, not merely mis-rendered. Forcing
`[Console]::OutputEncoding` to UTF-8 round-trips all three correctly.

This is not exotic. On a localised Windows estate, service descriptions and
error text are non-ASCII as a matter of course.

### The exit code, which merging the streams quietly broke

`2>&1` turns an error into an object in a pipeline that then succeeds, which
defeats PowerShell's own record of whether anything went wrong. Measured against
a real host, `Get-Service no-such-service` returned **1 before the rewrite and 0
after it** - a step would have stopped noticing that a remote probe failed.

`$Error.Clear()` first and `exit $(if ($Error.Count) { 1 } else { 0 })` last puts
it back. An explicit `exit N` inside the script still wins, because it never
reaches that line. Verified equal to the old behaviour for a bad command, an
explicit `exit 7`, a `throw`, an ordinary success and an unreachable host.

### Line endings are not handled here

PowerShell emits CRLF and ssh carries it through verbatim, so a captured line
used to end in a stray CR: invisible in a terminal, wrong in the file, and it
quietly breaks any later `grep` anchored with `$`. Measured against a real host,
6 CR bytes off the wire became 6 in the log.

That is fixed in `cap_run`, not here, because `cap_run` is the only capture path
in the toolkit and a second fix would be a second thing to keep in step. Only the
**trailing** CR is removed. A bare CR mid-line is a terminal doing
carriage-return progress, and deleting those would silently join output that was
never on the same line.

**Which control node you are on decides whether that fix does anything.** Under
Git for Windows' bash the MSYS runtime normalises the line ending further up the
pipeline, before `cap_run` ever sees it, so a Windows control node never had this
problem. On Linux the CR arrives intact and `cap_run` is what removes it. The
container and every host under `toolkit/azure/` are Linux, so that is the case
that matters in practice.

`tests/test-remote.sh` probes for this rather than assuming it, in the same shape
as `start.sh`'s CR-tolerance check: it asks whether a CRLF survives a pipe on
this shell, and only demands that reverting `cap_run` puts the CRs back where the
answer is yes.

## Counting CR bytes on Git bash, which is harder than it looks

`grep` is not a reliable way to find a CR under Git for Windows. MSYS grep and
MSYS shell redirection disagree about text translation, so `grep -lrU $'\r'`
reported **every** `.sh` file in a checkout as CRLF while `tr`, `git status` and
the blob all agreed the tree was clean LF. The same mistake in
`tests/test-remote.sh` passed on Linux and failed only on Windows.

Two things that do work:

- `tr -cd '\r' < file | wc -c` counts CR bytes and agreed with git every time.
- Comparing the file's size on disk to its blob's size. A file rewritten to CRLF
  is longer by exactly its line count, and neither `stat` nor a pipe translates
  anything. This is what CI uses to prove `.gitattributes` held, and it reported
  32 files byte-identical to their blobs against a real `core.autocrlf=true`.

### What is still not covered

`rt_ps` needs the target to run an SSH server. A Windows estate that only
permits WinRM has no route here, and nothing in this repo speaks WinRM or PSRP.
`rt_ps` also hardcodes `powershell`, which is Windows PowerShell 5.1; a target
with pwsh 7 installed will not use it.
