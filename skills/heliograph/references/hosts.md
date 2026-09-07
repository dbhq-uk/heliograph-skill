# Hosts: where the station runs, and which ones are actually proven

The station is a bash loop. A **host** is whatever keeps it running: somebody's
terminal, a container, a service manager, or cloud infrastructure.

This page exists because the honest status of each one was scattered across
three files and absent for two of them, and an unproven template that looks
authoritative is worse than no template. Somebody deploys it into an estate they
cannot easily debug, on the strength of it being in the repository.

## The contract

A host has to provide five things. Anything that does is a host; anything that
does not will fail in a way that is hard to see from the near side.

| | |
|---|---|
| **a writable checkout** | the transport repo, on disk, that the loop can `git pull` and push from |
| **outbound reach to the transport** | git host, share, object store or relay. Nothing needs to reach *in* |
| **a credential that survives the session** | a forwarded ssh agent key dies at logout, which is exactly when an unattended loop needs it |
| **an unbuffered stdout** | `caplib.sh` stamps a line when it is produced. A host that buffers gives every line the same timestamp, which reads like a working log while destroying the only property that makes it worth having |
| **a way to see it died** | a restart policy, or a person who will notice |

Nothing needs an inbound port. The station only ever dials out, and no host here
opens a listener.

## Status, honestly

**Proven** means it has run the loop end to end, and something re-checks that.
**Validated** means the file is well-formed and reviewed but has never started a
station. The difference is the whole point of this table.

| host | status | evidence |
|---|---|---|
| operator's terminal (`start.sh`) | **proven** | `tests/test-start.sh`, 94 assertions, every CI run |
| Docker (`toolkit/docker/`) | **proven** | `tests/test-container.sh` builds the image and runs the loop in it, 228 assertions, every CI run |
| systemd (`toolkit/service.sh`) | **proven** | `tests/test-service.sh` installs a unit and finds a running loop, every CI run |
| Kubernetes (`toolkit/kubernetes/`) | **proven** | `tests/test-kubernetes.sh` applies the shipped manifest to a kind cluster and drives a run through it, every CI run |
| Windows scheduled task (`toolkit/service.ps1`) | **proven** | the Windows runner registers the task, reads `ExecutionTimeLimit` back off it, and removes it, every CI run |
| Azure Container Instances, VNet-injected (`toolkit/azure/aci/`) | **proven** | deployed live |
| Azure Web App for Containers (`toolkit/azure/webapp/`) | **proven** | deployed live |
| Azure Container Apps Job, scheduled (`toolkit/azure/containerappsjob/`) | **proven** | deployed live |
| launchd (`toolkit/service.sh`) | **validated** | `tests/test-launchd.sh` loads a real LaunchAgent on a macOS runner, and the `stop: yes` assertion has held; promoted only once it has run green consistently |
| Azure VM with a systemd unit (`toolkit/azure/vm/`) | **validated** | the template validates; the subscription had no quota to prove it |

### What "validated" costs you

A validated host is a good starting point and not a promise. The failures that
survive review are the ones that need a real deployment to find, and the Azure
notes are full of them: a provider that double-prefixed a registry host, a
container group that needed a port declared for a process that listens on
nothing, a boot log you cannot get with `log tail`.

If you deploy one of these and it works, that is worth a PR to this table.

## Choosing one

**Somebody is at a terminal anyway.** `./start.sh`. Nothing to install, and the
operator stops relaying after one command.

**The estate already runs containers.** Docker or Kubernetes. No new
infrastructure, egress is already configured, and `kubectl logs` works - which
matters more than it sounds, because a crash-looping container group in a
VNet-injected ACI returns no logs at all.

**The loop has to outlive the session.** systemd, launchd or a Windows scheduled
task, through `service.sh` or `service.ps1`. Decide the credential first: a
forwarded ssh agent key is the nicest thing for an attended run and is no use at
all once the operator disconnects.

**There is nowhere to keep a process.** The Azure hosts, or a Function App on a
timer. Not a loop: one request per tick.

## The one rule that is not negotiable

Whatever the host, **the log is captured with a timestamp on every line and
pushed whether the run passed or failed.** A host that breaks either of those
has not saved you anything: an untimed log cannot tell a hang from slow
progress, and a log that only ships on success wastes the round trip that
mattered most.
