# The pigeonhole: a transport for a control node that cannot reach git

Heliograph normally uses git both ways: you push a step, the runner pushes the log back. That needs the control node to reach the git host. Sometimes it cannot - not awkwardly, but at all - and then git is not a transport, it is a dependency that cannot be met.

This is the transport for that case. Everything else about heliograph stays the same.

## When it applies

Use it when **the control node has no route to the git host and no route to the internet**, but you and it can both reach one storage account.

That shape is common in a locked-down cloud subnet: a firewall appliance holds the default route and has no policy for the subnet the runner sits in, so nothing outbound works - while traffic to a *private endpoint* stays inside the virtual network, never reaches that appliance, and works normally.

Do not reach for it because a token was awkward to get, or because a proxy is annoying. Git is better when git works: it carries its own history, and the log arriving as a commit is the audit trail. Use the pigeonhole only when the measurement says the runner cannot get out.

**Measure that before believing it.** The trap is that an image pull can succeed on a host with no network at all - a container platform pulls images on its own side, never from inside the subnet - so "the container started" tells you nothing. Run a probe that opens a TCP connection from inside, with a control target you expect to fail.

## How it works

```
you        write requests/<lane>.txt ──────────────▶ storage account
agent      polls it, sees the id change, runs the step
           writes logs/<step>-<UTC>.txt ───────────▶ storage account
           writes status/<lane>.txt
you        poll the status, read the log ◀──────────
```

Neither side reaches the other. Both reach the account. That is a dead letter drop, and it is where the name comes from.

Four containers on one account:

| Container | Holds | Written by |
|---|---|---|
| `requests` | one request per lane, overwritten in place | you |
| `logs` | every captured log, kept | the agent |
| `status` | one heartbeat per lane, overwritten | the agent |
| `agent` | `bundle.tgz`, the agent's own code | you |

## The lane replaces branch binding

Two runners must never answer one request. A heliograph log's whole value is that it says what **one** machine saw; two logs seconds apart from two hosts is a failure that looks like success.

Git gets that from branch binding - each runner reads a different branch, so a different copy of `agent/request`. There are no branches in a blob store, so the **lane** is the path: a runner reads `requests/<lane>.txt` and nothing else, and **no two runners may share a lane**.

Set it with `PIGEONHOLE_LANE` on both sides.

## The agent's code arrives as a blob

The toolkit's container image bootstraps by cloning the transport repo, which is exactly what a host in this situation cannot do. So the code travels the same way the requests do:

```bash
./drop.sh bundle       # packs pigeonhole.sh, caplib.sh, run.sh, steps/, lib/
```

The host downloads and extracts that at start. The useful consequence is that **updating the agent is an upload, not a redeploy** - which matters more than it sounds, because redeploying is often the operation that gives you no logs when it goes wrong.

## Authentication is deliberately asymmetric

**You** use your normal identity - `az ... --auth-mode login` - because you have internet and can reach the identity provider.

**The agent uses a SAS**, and it is not a shortcut. Every other credential needs a network call before it can be used: a managed identity needs the instance metadata service, a service principal needs `login.microsoftonline.com`. A host with no egress has neither, and on a VNet-injected Azure Container Instance there is no instance metadata service at all. A SAS is validated by the storage service itself with no token round trip, so it is the only credential that works from in there.

Two consequences worth stating plainly:

- **The account must allow shared keys**, because minting a SAS requires the account key. If your other storage accounts have shared keys disabled, this one is a deliberate exception and should say so in its own configuration.
- **An expired SAS does not fail loudly.** The agent keeps polling, every request returns 403, and you see a request that is never answered - indistinguishable from a step that is still running. Know the expiry date, and check the status blob's timestamp before assuming a step is slow.

Scope the SAS to read and write, **not delete**. A runner that can delete its own logs can destroy the evidence the investigation exists to collect, and this credential sits somewhere several people can read.

## Getting at it from your side

`drop.sh` is the whole interface:

```bash
./drop.sh send <id> <step> [ENV=val ...]   # queue a step; the id is the trigger
./drop.sh watch <id>                       # wait for it, then print the log
./drop.sh status                           # what is it doing right now
./drop.sh logs                             # what has come back
./drop.sh get <blob>                       # print one log
./drop.sh bundle                           # ship updated agent code
./drop.sh stop                             # clean exit
```

It needs `PIGEONHOLE_ACCOUNT`, or `TF_DIR` pointing at a terraform directory whose `transport_account_name` output names the account. Neither is guessed: reading an account name from the wrong stack would write a request into somebody else's drop.

**The trigger is the `id`, not a changed blob.** The request gets rewritten for all sorts of reasons - a corrected note, a fixed typo - and none of those should set a step running.

## What it does not change

`pigeonhole.sh` calls `run.sh` with `LOG_DIR` and `PUSH=0`, so the capture itself is untouched: the same timestamps, the same ANSI stripping, the same redaction, the same header and footer. A log from the pigeonhole and a log from a git runner are the same document. Only the poll source and the publish sink differ.

It is a separate file from `agent.sh` on purpose. Wherever this is needed, a git runner is usually still working elsewhere in the same estate, and two transports in one loop would mean reasoning about every future change twice - with a runner answering a request it should never have seen as the failure mode.

## Traps

Each of these cost a full round trip.

**The image needs `curl`, and may not have one.** A minimal image can fail with `/bin/sh: 1: curl: not found` and exit 127 before the agent exists to report anything.

**It may also have no `tar`.** Extract the bundle with Python's `tarfile` as a fallback, which the toolkit's bootstrap does. Nothing can be installed to fix this at runtime - the package manager cannot reach a repository either.

**It may have no `hostname`.** `pigeonhole.sh` falls back through `/etc/hostname` and `$HOSTNAME`, because the host name is the one field that says which machine the log came from.

**Ship `lib/` in the bundle.** Without it every probe helper is missing, the step still runs, and the log fills with confident falsehoods - `curl -- not installed --` on a host where curl is installed. A log that lies is worse than one that fails.

**Create the bundle before the runner starts.** A host that boots and finds no `bundle.tgz` crash-loops until one appears. Recoverable, but a crash-looping VNet-injected container returns no logs, so it is a bad place to be.

**A container that runs to completion is readable when a crash-looping one is not.** When the agent itself will not start, deploy a throwaway container in the same subnet that runs a probe and exits. Its logs come back normally, and that is how nearly every finding in this document was obtained.
