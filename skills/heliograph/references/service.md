# Surviving logout

`agent.sh` says "run this ONCE on the control node and walk away". Until
`service.sh` existed that was not true.

```bash
./service.sh install     # survive logout, and start now
./service.sh status
./service.sh logs
./service.sh stop
./service.sh uninstall
```

On a Windows control node, `service.ps1` with the same subcommands.

## Arguments reach start.sh

Everything except `--force` is forwarded verbatim, so a service-managed loop can
do anything `./start.sh` can:

```bash
./service.sh install --branch task/dns-timeouts    # run on a task branch
./service.sh install -- --interval 15              # after -- goes to agent.sh
```

This is not a nicety. **Branch per task is how the whole skill works**, and the
first version of `service.sh` hardcoded `start.sh` with no arguments, so a
service-managed loop was stuck on whichever branch happened to be checked out.
Nothing in the test suite noticed. Running a real investigation through it did,
within minutes of trying to move to a task branch.

`status` reports both the command the unit runs and the branch the repo is
actually on, so nobody has to infer which task a running loop is serving.

## The bug

`sshd` sends `SIGHUP` to the session's process group when the connection closes.
`agent.sh` traps `INT` and `TERM` but not `HUP`, and the default action for `HUP`
is to terminate. Measured:

```
$ PUSH=0 ./agent.sh --interval 3 &
$ kill -HUP %1
Hangup    PUSH=0 ./agent.sh --interval 3
```

The loop is gone. Close the laptop, and the machine nobody can log into stops
being watched.

This went unnoticed for a long time because every host added since gets survival
free from a restart policy: the container, the four Azure hosts, AKS, the
pipelines. The plainest case of all, somebody with a shell on a box, was the one
still broken.

## Two mechanisms

`service.sh` picks the better one it can reach and **says which it used**, because
they are not equivalent.

| | systemd `--user` | `setsid` + `nohup` |
|---|---|---|
| survives logout | yes, with lingering | yes |
| survives reboot | yes | **no** |
| restarts on failure | yes, 5 tries per 5 minutes | no |
| logs | `journalctl --user` | `.agent-service.log` |
| needs root | no | no |

The fallback is used only where there is no user systemd to talk to. It is a
real answer, not a placeholder, but it does not survive a reboot and the install
output says so rather than letting you assume otherwise.

## Lingering is the whole trick

A systemd `--user` unit lives in the user manager, and without lingering that
manager is torn down at logout and takes every unit with it. The service would
look perfectly installed and still die exactly when it was supposed to survive.

```bash
loginctl enable-linger "$USER"
```

`service.sh install` does this, falls back to `sudo -n` if the unprivileged call
is refused, and then **verifies** it rather than assuming it worked. If it is
still not enabled the install says so in the loudest terms it has, because that
one setting is the difference between the feature working and quietly not.

Verified detached, by asking `ps` rather than assuming:

```
parent : 1056 (systemd)      not the starting shell
cgroup : user.slice/user-1000.slice/user@1000.service/app.slice/heliograph.service
session: 64650               the starting shell was 65001
```

## XDG_RUNTIME_DIR, and a message that names nothing

`systemctl --user` talks to a per-user bus under `XDG_RUNTIME_DIR`. That variable
is set for a login shell and is routinely **unset** in the shells this toolkit
actually runs in: `ssh host command`, a sudo session, a cron job. Without it:

```
Failed to connect to bus: No medium found
```

which mentions neither systemd nor the variable, and sends the reader looking
for a broken unit that was never written. The directory exists regardless, so
`service.sh` points at `/run/user/$(id -u)` rather than giving up.

## The credential is where an unattended loop actually fails

**A detached process inherits no environment.** `GIT_TOKEN` typed before
`./agent.sh` reaches the agent. `GIT_TOKEN` typed before `./service.sh install`
does **not** reach the service. The loop then starts perfectly, polls happily,
and cannot push a single log, which is discovered hours later by whoever is
waiting on the far side.

So it is checked before anything is installed, and the install is refused:

```
warn  the credential is env:GIT_TOKEN, which lives in THIS shell and will not reach the service.
warn    A detached process inherits no environment, so the loop would run and never push.
warn    Write it to a file the service can read instead:
warn        printf '%s' "$GIT_TOKEN" > ~/.git-token && chmod 600 ~/.git-token
```

`caplib` already reads `~/.git-token`, so nothing else has to change. `--force`
overrides the refusal and says that it did.

Which credential is relevant is decided by the remote's scheme, the same
three-way split `start.sh` uses. An `ssh://` remote relying on an `ssh-agent`
gets a warning, because the service will not inherit that either. A local path
remote is not questioned at all, since git needs no credential for one.

## agent.sh deliberately does NOT trap HUP

This looks like the obvious one-line fix and it is the wrong one.

`cleanup` signals the running step's process group, so trapping `HUP` would
**kill an in-flight step whenever a connection dropped**. An hour-long terraform
plan destroyed because somebody's wifi blinked is far worse than the agent
exiting while the step finishes and pushes its log on its own.

The stale lock this leaves behind is not a problem either. `agent.sh` already
detects and clears it:

```
agent: clearing a stale lock from pid 69162
```

So the loop simply dying was left alone, and `service.sh` is the supported way to
survive. Do not "fix" the trap.

## Two repos on one box

The unit name comes from `HELIOGRAPH_SERVICE_NAME`, default `heliograph`. One
transport repo per investigation is ordinary, and a fixed name would mean the
second install silently replaced the first.

```bash
HELIOGRAPH_SERVICE_NAME=heliograph-payments ./service.sh install
```

It is also what stops `./tests/run-tests.sh` from uninstalling a real service
somebody is relying on.

## Windows

`service.ps1` registers a scheduled task rather than a service: a service needs
installation rights and a wrapper for a script, a task needs neither.

It registers the task against **`agent.ps1`**, not against a bash path, so the
registry lookup that finds `bash.exe` stays in one place. See
[windows.md](windows.md).

Two settings matter more than the rest:

- **`-LogonType S4U`** runs the task whether the operator is logged on or not
  and stores no password. The trade-off is no network *credentials*, which does
  not matter here: git authenticates with a token from a file or an ssh key, not
  with the Windows identity.
- **`-ExecutionTimeLimit ([TimeSpan]::Zero)`** means no limit. The default is
  **three days**, after which Windows stops the task. A loop that quietly stops
  after three days is exactly the failure this file exists to prevent.

`LastTaskResult` of `267009` means "currently running", not an error, and
`status` says so because it reads like a fault code to anyone who has not looked
it up.

## What is not covered

Survival across a reboot is asserted only for the systemd path, and by reading
the unit rather than by rebooting anything. Nothing here reboots a machine to
prove it.
