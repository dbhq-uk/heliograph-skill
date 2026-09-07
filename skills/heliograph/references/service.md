# Surviving logout

`station.sh` says "run this ONCE on the control node and walk away". Until
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
./service.sh install -- --interval 15              # after -- goes to station.sh
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
`station.sh` traps `INT` and `TERM` but not `HUP`, and the default action for `HUP`
is to terminate. Measured:

```
$ PUSH=0 ./station.sh --interval 3 &
$ kill -HUP %1
Hangup    PUSH=0 ./station.sh --interval 3
```

The loop is gone. Close the laptop, and the machine nobody can log into stops
being watched.

This went unnoticed for a long time because every host added since gets survival
free from a restart policy: the container, the four Azure hosts, AKS, the
pipelines. The plainest case of all, somebody with a shell on a box, was the one
still broken.

## Three mechanisms

`service.sh` picks the best it can reach and **says which it used**, because
they are not equivalent.

| | systemd `--user` | launchd | `setsid` + `nohup` |
|---|---|---|---|
| survives logout | yes, with lingering | yes | yes |
| survives reboot | yes | yes | **no** |
| restarts on failure | yes, 5 tries per 5 minutes | yes | no |
| logs | `journalctl --user` | `.station-service.log` | `.station-service.log` |
| needs root | no | no | no |

launchd is the macOS answer, and it exists because the fallback was the only
thing a Mac control node could use and it does not survive a reboot.

`KeepAlive` is set to fire on a **non-zero exit only**, never unconditionally,
and that is the same lesson the systemd unit learned by running one. `stop: yes`
in `station/request` is how the far side ends a loop it can no longer reach, and
`station.sh` honours it by exiting 0. Under an unconditional `KeepAlive` launchd
restarts it, it reads the same stop flag, exits again, and round it goes - every
cycle a commit pushed to the transport repo.

`./service.sh stop` **unloads** rather than calling `launchctl stop`, for the
same reason: with `KeepAlive` set, a stop is followed by launchd starting it
straight back up, which looks exactly like a stop that did not work.

## The two Linux mechanisms

`service.sh` picks the better one it can reach and **says which it used**, because
they are not equivalent.

| | systemd `--user` | `setsid` + `nohup` |
|---|---|---|
| survives logout | yes, with lingering | yes |
| survives reboot | yes | **no** |
| restarts on failure | yes, 5 tries per 5 minutes | no |
| logs | `journalctl --user` | `.station-service.log` |
| needs root | no | no |

The fallback is used only where there is no user systemd to talk to. It is a
real answer, not a placeholder, but it does not survive a reboot and the install
output says so rather than letting you assume otherwise.

## A deliberate stop must stick

The unit uses `Restart=on-failure`, **not** `Restart=always`, and that was learned
by running one.

`stop: yes` in `station/request` is how the far side ends a loop it can no longer
reach, and `station.sh` honours it by exiting 0. Under `Restart=always` systemd
started it straight back up, it read the same stop flag, exited again, and round
it went. Measured on a live control node:

Captured before `agent` was renamed to `station`, and left as it was recorded:
this is evidence, and the line the loop prints today reads `stopped`.

```
21:33:35  agent: stopped (egress-3)
21:33:55  agent: stopped (egress-3)
21:34:15  agent: stopped (egress-3)
21:34:35  agent: stopped (egress-3)
NRestarts=3   Active: activating (auto-restart)   status=0/SUCCESS
```

Every one of those is a commit **pushed to the transport repo**, and it only ends
when `StartLimitBurst` trips and leaves the unit `failed` - which reads like a
breakage when the station had done exactly what it was told.

`station.sh` runs forever unless deliberately stopped, so exit 0 means "I was told
to stop" and must stick. A crash, or a preflight refusing a bad credential, is
non-zero and still restarts.

One consequence worth knowing: systemd treats `SIGHUP`, `SIGINT`, `SIGTERM` and
`SIGPIPE` as **clean** terminations, so `on-failure` will not restart after one.
That is fine here. A systemd-managed process has no controlling terminal, so a
closing ssh session cannot send it `SIGHUP` at all; what protects it is the
detachment, not the restart policy.

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
`./station.sh` reaches the station. `GIT_TOKEN` typed before `./service.sh install`
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
three-way split `start.sh` uses. A local path remote is not questioned at all,
since git needs no credential for one.

An `ssh://` remote gets said something about either way, because both cases are
traps:

- **with** a station in the shell, a warning: the service will not inherit it, and
  a station key lasts only as long as the session that this whole feature exists
  to outlive
- **without** one, a note: the service will depend on a key ssh can find by
  itself, and `./start.sh --check` settles that in one step

It does **not** try to resolve the key itself. ssh's own config resolution is
richer than anything reimplemented here, and a second resolver that disagreed
would report a key git never uses. What settles it is the write check, which
`start.sh` runs at every service start and which refuses to start the station if
the push would fail.

## station.sh deliberately does NOT trap HUP

This looks like the obvious one-line fix and it is the wrong one.

`cleanup` signals the running step's process group, so trapping `HUP` would
**kill an in-flight step whenever a connection dropped**. An hour-long terraform
plan destroyed because somebody's wifi blinked is far worse than the station
exiting while the step finishes and pushes its log on its own.

The stale lock this leaves behind is not a problem either. `station.sh` already
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

It registers the task against **`station.ps1`**, not against a bash path, so the
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
