<div align="center">

<img src="assets/logo.svg" alt="heliograph skill for Claude Code, by DBHQ" width="420">

# heliograph

**Debug a machine you cannot log into, through someone who cannot debug it**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Claude Code](https://img.shields.io/badge/Claude_Code-Plugin-blueviolet)](https://code.claude.com/docs/en/plugins)
[![Platform](https://img.shields.io/badge/Platform-Linux%20%7C%20WSL%20%7C%20macOS%20(GNU%20coreutils)-lightgrey)]()

A free, open-source tool by [DBHQ](https://dbhq.uk)

</div>

---

## Does this sound familiar

- You have **no SSH access to production**, and you are not going to be given any.
- The environment is **air-gapped**, or behind a bastion, a jump host or a VPN you are not on.
- It is a **client-owned or customer-managed estate**. Only their staff can log in.
- An **MSP, an offshore team or a colleague on site** owns the console, and they have their own work to do.
- Access is blocked by **policy, not capability**: regulated, restricted, change-controlled.
- You are on the fourth round of **"can you run this and paste the output"**, and what came back was a screenshot of half a terminal.
- You are an **AI coding agent** driving an investigation, and you need the evidence rather than somebody's summary of it.

If you can just SSH in, you do not need this.

## What it does

A heliograph signals across a valley by flashing sunlight off a mirror. No wire,
no connection, just a message that gets across a gap and an answer that comes
back the same way. This is that, for operations work: **git is the transport in
both directions.**

You write the step. Someone on the far side runs one command they never have to
change. The whole run comes back as a log: every line timestamped in UTC, ANSI
stripped, obvious secrets masked, committed and pushed.

```
you        push a step ──────────────────────────────▶ transport repo
operator                                        ──────▶ git pull && ./run.sh
           the log is captured and pushed ──────▶ transport repo
you        git pull, read ops-logs/<step>-<UTC>.txt ◀──
```

It is deliberately generic. Ansible, Terraform, Terragrunt, a Kubernetes cluster
that will not form, a Windows Server box over SSH, a hung service, a failing
cluster join: anything you can express as a command.

**Better still, nobody relays anything.** The operator starts `./start.sh` once
and walks away. It proves the machine can capture and push, then hands off to the
agent, which watches the branch, runs what you ask for, and pushes the log back.
After that the loop is git in both directions, and nobody has to be sitting on the
far side.

## Two properties that make a log-only loop workable

**Every line carries a UTC timestamp**, so a hang shows up as a *gap*. After the
fact, in an untimed log, a hang and slow progress are indistinguishable. This is
the single most useful property of these logs.

**The exit code survives and the log is pushed even on failure**, so a failed run
reads as clearly as a successful one and a round trip is never wasted.

## Install

### As a Claude Code plugin (recommended)

```
/plugin marketplace add dbhq-uk/marketplace
/plugin install heliograph@dbhq
```

### Any agent (Cursor, Copilot, Windsurf, Gemini, Cline and more)

```bash
npx skills add dbhq-uk/heliograph-skill
```

The [skills.sh](https://skills.sh) CLI installs into whichever agent directories
it finds, so this works outside Claude Code and Codex too.

### Local install (Claude Code or Codex)

```bash
git clone https://github.com/dbhq-uk/heliograph-skill.git
cd heliograph-skill
./install.sh          # Claude Code: symlinks into ~/.claude/skills (edits are live)
./install-codex.sh    # Codex: installs into ~/.codex/skills
```

### Without an agent at all

The toolkit is plain bash and stands on its own. Copy it into a fresh private
repo and drive it by hand:

```bash
git clone https://github.com/dbhq-uk/heliograph-skill.git
./heliograph-skill/skills/heliograph/scripts/bootstrap.sh ~/my-investigation
```

Bash 4+, git and GNU coreutils. No packages, no credentials, no network beyond
the git remote itself. The GNU spellings matter: `sed -u` is what keeps the
capture unbuffered, so each line is stamped when it is produced rather than when
the block flushes. On macOS, install `coreutils` and `gnu-sed` and put them first
on `PATH`.

## Usage

Ask in any session:

```
"heliograph: set up a transport repo for the payments cluster"
"heliograph a step that proves whether node A can reach node B on 5985"
"read the log that just came back and tell me what it measured"
```

The skill bootstraps the transport repo, writes the steps, drives the runner and
reads the logs. What you decide is which question to ask next.

## How it works

1. **Bootstrap a transport repo.** Private, its own repo, cloned on the control node by whoever can reach it
2. **Baseline first.** `./run.sh env` answers what that box actually is: OS, tools, sudo, proxy, DNS, cloud auth, and which commit of the repo is checked out
3. **One branch per investigation.** `TASK.md` holds the question, the measurements and the conclusions, and keeps the last two apart
4. **One step per question.** Copy the template, write the probes, register it, push
5. **The operator pulls and runs**, or `./start.sh` checks the machine and starts the agent unattended
6. **The log comes back over git**, timestamped and complete, whether the step passed or failed

## What ships

| | |
|---|---|
| `start.sh` | the first command on a new machine: proves it can capture and push, then starts the agent |
| `run.sh` | the step runner. The operator's one command |
| `agent.sh` | the unattended loop: watches for a request, runs it, pushes. Cancellable mid-run |
| `caprun.sh` | wrap any ad-hoc command in the same capture and push |
| `caplib.sh` | the shared capture, log and push functions |
| `secret.sh` | carry a value the *other* way, as ciphertext, when the far side needs one |
| `steps/env-snapshot.sh` | control-node baseline: OS, tools, auth, proxy, DNS, git |
| `steps/net-probe.sh` | DNS, ICMP and a TCP matrix, in both directions |
| `lib/` | `probe.sh`, `remote.sh` (SSH and Windows), `terraform.sh`, `ansible.sh`, `tfguard.sh` |
| `docker/` | `Dockerfile`, `entrypoint.sh`, `heliograph.sh` - run the control node in a container instead |
| `ops-logs/` | the captured runs. Tracked deliberately |

Plus the half that is not code: the method the tooling exists to serve. Measure
rather than infer, keep a control, run it in all directions, never truncate. See
[`references/method.md`](skills/heliograph/references/method.md), which is worth
reading before a hard investigation.

## Running it in a container

For a control node where installing bash, git and coreutils by hand is its
own change request:

```bash
skills/heliograph/toolkit/docker/heliograph.sh <transport-repo-url>
```

It builds the image if it is missing, clones the transport repo, and hands
over to that repo's own `start.sh` - nothing about the loop itself changes.
The image ships two ways: on a pushed version tag, so an estate can say
exactly which one they ran, or built locally from the same `Dockerfile` for
an estate that will not pull a third-party image. The user inside is
unprivileged but has passwordless sudo, which is **not a security
boundary** - see
[`references/container.md`](skills/heliograph/references/container.md) for
what it buys instead, and for what has and has not actually been proven
about the publishing side of this.

## Logs and secrets

`ops-logs/*.txt` is **tracked, not ignored**. The log is the deliverable, and
committing it is how a run escapes a machine nobody can reach.

Because logs are committed and pushed, anything a command prints is in git
history permanently. `cap_redact` masks the obvious shapes (`password=`,
`Bearer`, `Basic`, a credential carried in a URL, private keys) on the way out.
**It is a safety net, not a guarantee.** Do not run things that print secrets,
and keep the transport repo private.

Occasionally a value has to travel the other way: something the far side needs
and cannot fetch for itself. `secret.sh` carries it as ciphertext, with the
passphrase defined by a human on both machines and never committed, so git
carries something useless on its own. It is transport rather than storage, and
[`references/secrets.md`](skills/heliograph/references/secrets.md) is honest
about the limits of that.

## What this will not do

Give you access you do not have. It does not tunnel, proxy or hold a connection
open, and there is nothing here to punch through a firewall with. Every command
runs on the far side because someone with legitimate access chose to run it, and
the only thing that crosses the gap is a git commit.

It will not resolve a merge conflict, force a push, or discard the operator's
local work either. When the loop cannot proceed it says so, keeps the log, and
carries on polling.

## Development

[`CONTRIBUTING.md`](CONTRIBUTING.md) covers working on it and
[`AGENTS.md`](AGENTS.md) is for an AI agent doing so. The skill itself is
[`skills/heliograph/SKILL.md`](skills/heliograph/SKILL.md), and
[`docs/dev-setup.md`](docs/dev-setup.md) sets it up from source with live edits.

## License

[MIT](LICENSE) © 2026 DBHQ Consulting Ltd
