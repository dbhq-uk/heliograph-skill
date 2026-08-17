# Running the agent anywhere

Design, 2026-08-17. Six independent pieces of work, one per PR, that let
`agent.sh` run somewhere other than a hand-driven shell on a Linux control node.

## The problem

Today the loop needs an operator with a bash 4 shell, GNU coreutils, git, and
whatever the step invokes already installed. That is a narrower set of machines
than the situations the skill claims to serve:

- The control node is locked down and nothing can be installed on it, so a step
  needing terraform or the Azure CLI cannot run at all.
- There is no willing human at a terminal, but there is a subscription the
  estate's own staff can deploy into.
- The only shell anyone has is Azure Cloud Shell in a browser tab.
- The control node is Windows Server, which `lib/remote.sh` already assumes the
  far side often is, but which cannot host the loop itself.
- The operator starts `./agent.sh`, closes their SSH session, and the loop dies
  with it. The pitch is "start it once and walk away", and that is not currently
  true.

## The spine

Two decisions make the rest cheap.

**One entry point, five callers.** There is no single answer to "I have a shell
on the far side, now what". `toolkit/start.sh` owns it once, and the container
entrypoint, the Cloud Shell one-liner, the ACI command line and the PowerShell
launcher all become callers rather than parallel implementations. This is the
same separation the toolkit already keeps between `agent.sh` (decides *when*) and
`run.sh` (owns the log): `start.sh` decides *where*, and owns nothing else.

**It does not clone.** `start.sh` ships inside the transport repo, so by the time
it runs the clone has already happened. The container entrypoint owns the clone,
in about twenty lines, and then calls the repo's own `start.sh`. Putting the clone
in `start.sh` would mean two copies of the file, one baked into the image and one
in the repo, and no clear answer about which is authoritative.

**Everything the far side needs arrives over git.** The Dockerfile, the bicep,
the package payloads and the PowerShell launcher all live under `toolkit/`, so
they land on the control node by `git clone` and nothing has to reach the public
internet. This is what keeps the design honest at the "egress to the git host and
nothing else" extreme rather than only working at the easy one. A hosted
`curl | bash` one-liner is still worth shipping, but as a convenience for the
full-internet case, never as the mechanism.

`bootstrap.sh` walks `toolkit/` with `find`, so every file added there ships to
new transport repos with no wiring. Existing transport repos pick it up by
re-running the bootstrap, which is already safe.

## Credential resolution

The credential is the one thing none of these runtimes work without, and it is
the part with real consequences: a long-lived token baked into an image that gets
deployed into someone else's subscription is a liability, not a convenience.

**The remote URL decides which credential is relevant**, so detection branches on
the scheme before it looks for anything:

| remote | resolves | in order |
|---|---|---|
| `git@host:...` or `ssh://` | an SSH key | nothing resolves anything. git and ssh already own that, so `start.sh` reports what `ssh-add -l` offers (by exit status: keys, agent-but-empty, or no agent) and then lets the read and write checks settle it |
| `https://` | a token | `GIT_AUTH_HEADER`, `GIT_TOKEN`, `GIT_TOKEN_FILE`, `./.git-token`, `~/.git-token` |

The SSH row deliberately describes **no chain**. An earlier draft of this table
had one - agent key, then a mounted key, then `~/.ssh/id_*` - and nothing
implements it because nothing should: ssh's own config resolution is richer than
anything reimplemented here, and a second resolver that disagreed with it would
report a key git never used. Report, then measure. Do not build the chain.

The HTTPS chain is `_cap_auth_header`'s existing precedence, unchanged.
`start.sh` resolves it, reports it and verifies it; `cap_git` remains the only
thing that uses it.

In Azure, a managed identity reads the token from Key Vault and exports it as
`GIT_TOKEN` **before** that chain runs, so Key Vault is a source that feeds the
existing mechanism rather than a fourth branch in it. Nothing about `cap_git`
changes.

**It reports the mechanism and never the value.** For SSH, the key fingerprint,
which is public information and is the fastest way to settle "is that the key you
put on the repo". For a token, the source and the length only: a token mangled or
truncated by an ARM template parameter is a real failure mode, and the length
settles it without printing a secret into a log that gets committed.

The header travels to git through the environment rather than the command line,
because `git -c http.extraHeader=...` lands in `/proc/<pid>/cmdline`, which any
other user on the control node can read; the environment is owner-only. Neither
route hides the value from root, a core dump or a debugger, which is why the
advice remains a short-lived, narrowly scoped credential and SSH wherever
possible. `transport.md` is the authoritative account of both routes, including
the git-2.31 boundary below which there is no environment route to fall back
from.

**It measures rather than assumes.** `transport.md` already records the trap: a
token that works against the host's REST API tells you nothing about whether git
can authenticate, because they are different credentials on different paths.
`start.sh` therefore runs `git ls-remote` against origin and refuses to start the
agent if that fails, naming the branch of the table it took and what to fix.

Read access is not write access, and the expensive failure is an agent that polls
happily for an hour, captures a perfect log, and cannot push it. `start.sh` proves
write access with `git push --dry-run origin HEAD:refs/heads/heliograph-write-check`
- a ref that deliberately **does not exist** on the remote.

Two properties make that reliable. The push negotiates with `git-receive-pack`,
which is the service write access is granted on, so a read-only credential fails
it. And a ref that does not exist cannot be refused as a non-fast-forward, so a
checkout that is merely *behind* origin is not misreported as a credential
failure - which the current branch's own refspec did, on every reboot and after
every push by the author, blaming a perfectly good credential and refusing to
start. `--dry-run` creates nothing, so nothing is left on the remote.

A refusal is therefore classified rather than blamed on the credential: a
fast-forward complaint is a warning about history and does not block, anything
else is a blocking failure that names both write access and remote branch-name
policy as the things to check.

## The PR ladder

| # | Ships | Depends on |
|---|---|---|
| 1 | `toolkit/start.sh`, preflight and credential resolution | - |
| 2 | `toolkit/toolbox.sh` and `payload/toolbox/`, tooling carried over git | - |
| 3 | `toolkit/docker/`, the slim image and its wrapper | 1 |
| 4 | `toolkit/azure/`, bicep for ACI, deployed by them | 3 |
| 5 | `toolkit/agent.ps1`, a Windows control node | 1 |
| 6 | Surviving logout: systemd user unit, scheduled task | 1 |

2, 5 and 6 can proceed in parallel once 1 lands. 4 waits on 3.

## PR 1: start.sh

```bash
./start.sh                          # preflight, verify auth, exec agent.sh
./start.sh --check                  # preflight and auth only, exit without running
./start.sh --branch task/foo        # check that branch out first, then sync
./start.sh -- --once --interval 15  # everything after -- goes to agent.sh
```

The valuable half is the preflight, and none of it exists today. Each check earns
its place by being a failure that is currently silent or misleading.

| check | why it matters |
|---|---|
| bash 4+ | the toolkit's baseline, stated in AGENTS.md |
| `git`, and its version | git is the transport; without it nothing works |
| `sed -u` is honoured | **the load-bearing one.** `sed -u` is what keeps the capture unbuffered so each line is stamped when produced. busybox `sed` has no `-u`. Today this is prose in a README, and breaking it produces a log where every line carries the same time, which is worse than no timestamp because it looks like one |
| `base64 -w0` is honoured | `caplib.sh` uses it to build the HTTPS auth header, and a `base64` that wraps makes the header silently malformed. **Not GNU-only:** a real BusyBox 1.36.1 accepts `-w0` and its output is byte-identical to GNU's, so busybox fails the `sed -u` row and passes this one. BSD/macOS `base64` is the case this row catches |
| `sha256sum` present | `agent.sh` uses it for the self-update check and swallows failure with `2>/dev/null`, so on a machine without it self-update silently never happens and a pushed fix to `agent.sh` never takes effect. Surfacing this is a finding in its own right |
| `date -u`, `wc`, `ls -t`, `hostname` | GNU spellings the capture and the status pushes assume |
| `setsid` | optional. `agent.sh` falls back to `set -m`; report which path cancel will take |
| on a branch, not detached HEAD | `agent.sh` exits 2 on detached HEAD; say so before the clone looks fine |
| `ops-logs/` writable | a capture that cannot write its log fails at the worst moment |
| current UTC time, reported | a skewed clock makes every timestamp in every log misleading. Report, do not fail: only the reader can judge it |

Then, in order: resolve and verify the credential as above, check out the
requested branch if one was given, `pull --rebase` to bring the checkout up to
date (idempotent and safe to re-run), and `exec ./agent.sh "$@"`. No step here
clones: the repo is already on disk by the time `start.sh` runs.

**What it must not do.** It never resolves a conflict, never forces a push, never
discards the operator's local work, and never prints a credential. It installs
nothing: that is PR 2's job, and keeping the two apart is what lets `start.sh`
run on a node where installing is forbidden.

CI additions: a case asserting a `sed` without `-u` is refused, and one asserting
`--check` exits without starting the agent.

Done when a bootstrapped copy runs `./start.sh --check` on a clean machine and on
a deliberately broken one, and the output names the specific fix in both cases.

## PR 2: toolbox.sh

Two modes, because the network is unknown and often unknowable in advance:

- **With egress**, `apt-get` or `dnf` the named packages.
- **Without**, install from `payload/toolbox/`: debs, tarballs and wheelhouses
  committed to the task branch. This is the mode your constraint asks for, and it
  is the existing `payload/` idea from `remote-repo.md` applied to tooling rather
  than to configuration.

It runs as a **step**, so it is captured, timestamped and pushed like anything
else, and the log proves what actually landed rather than what was intended. It
is a state-changing step and carries the `CONFIRM=yes` gate accordingly.

This PR carries an honest warning in the style the repo already uses for
`ops-logs/` and `secret.sh`: a 90MB terraform binary committed to a transport
repo is in that history permanently. The mitigation is the one the docs already
insist on, a fresh private transport repo per engagement, which is cheap to
create and cheap to delete.

## PR 3: the container

`debian:bookworm-slim` plus `git`, `ca-certificates` and `bash`. Around 90MB, and
the GNU userland is already correct. Alpine is smaller but busybox `sed` has no
`-u`, and installing GNU userland back in spends the size advantage to buy a
footgun in the one place the toolkit cannot tolerate one.

Entrypoint is `start.sh`. Root inside the container, so `toolbox.sh` can install:
that is what the container is for, and the isolation is the point.
`docker/heliograph.sh` wraps the `docker run` into one line and works with podman
unchanged.

## PR 4: Azure

Azure Container Instances, deployed from a bicep file in `toolkit/azure/`. ACI
because it needs no cluster, costs little, can be injected into a VNet, and
because the security story is strong: **it needs no inbound at all.** Egress to
the git host, and nothing else.

A user-assigned managed identity reads the token from Key Vault, so no secret
appears in the template.

The part that matters more than the template: this is a file **they** deploy into
**their** subscription, reviewable before it runs. That preserves the property the
README stakes its reputation on, that every command runs on the far side because
someone with legitimate access chose to run it. A container we deploy ourselves
into an estate we have no access to would be a different tool with a different
name, and this design should not drift into it.

## PR 5: PowerShell

A thin launcher, not a port. Git for Windows ships bash 4.4 with GNU coreutils
and a `sed` that honours `-u`, at `C:\Program Files\Git\bin\bash.exe`. If git is
installed the dependency is already satisfied, and git is the transport, so a
control node without it cannot participate anyway. `agent.ps1` locates that bash,
runs the same preflight through it, and hands off to `start.sh`.

A native port would mean forking `caplib.sh`, `run.sh` and every step into
PowerShell, which breaks AGENTS.md constraint 3 (one implementation of the capture
pattern). It is explicitly out of scope. Should a control node with PowerShell but
no Git for Windows ever turn up, that is the moment to reconsider, not before.

CI needs PSScriptAnalyzer: nothing lints `.ps1` today.

## PR 6: surviving logout

A plain `./agent.sh` dies when the operator's SSH session closes, which
contradicts the pitch. A systemd `--user` unit plus `loginctl enable-linger`
fixes it without root; a scheduled task does the same on Windows; PR 3 gets it
free from the container restart policy. Mostly a unit file and documentation.

## Out of scope

AKS manifests. Container Apps as well as ACI. A fat kitchen-sink image. The
native PowerShell toolkit. Cloud Shell as a home for the unattended loop: it
idles out after about 20 minutes, so it is genuinely useful for bootstrapping and
for `--once`, and bad at the thing the agent exists for. Saying so is better than
shipping something that dies quietly.

## What this trades

The README currently promises "Bash 4+, git and GNU coreutils. No packages, no
credentials, no network beyond the git remote itself". PRs 2, 3 and 4 spend part
of that, and the documentation should say which part rather than quietly
weakening the claim. What must survive intact is the property the tool is built
on: nothing here grants access that was not already granted, and every command
still runs on the far side because someone entitled to run it chose to.
