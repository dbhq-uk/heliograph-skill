---
name: heliograph
description: Debug and change a machine you cannot log into, through an operator who cannot debug it, using git as the transport in both directions. Sets up a transport repo, writes capture steps, drives an unattended runner, and reads the pushed logs. Trigger on phrases like "heliograph", "I can't get on that box", "no access to that environment", "the only person who can reach it is X", "air-gapped", "can you give me something to run", "they keep pasting output at me", "run it on the control node", "capture the log and push it back". Not for machines you can SSH into yourself.
---

# heliograph

Someone can reach the machine. You cannot, and you are the one who knows what to
ask it. This skill runs that gap as a loop instead of a relay: **git carries the
step out and the log back**, and the operator types one command that never
changes.

```
you        push a step ──────────────────────────────▶ transport repo
operator                                        ──────▶ git pull && ./run.sh
           the log is captured and pushed ──────▶ transport repo
you        git pull, read ops-logs/<step>-<UTC>.txt ◀──
```

Every captured line carries a UTC timestamp, ANSI is stripped, obvious secrets
are masked, and the log is committed and pushed **whether the run passed or
failed**.

## When this applies

- The machine is in an environment you have no interactive access to.
- The only person who can reach it has other work to do and should not be your terminal.
- Several rounds of "run this and paste the output" have already gone badly.
- The repo that has to *change* is also on the far side (see
  [references/remote-repo.md](references/remote-repo.md)).

If you can SSH in yourself, do that instead and do not use this skill.

## Prerequisites

Bash 4+, git, GNU coreutils. Nothing to install and no credentials of the
skill's own. The control node needs git and whatever the step itself invokes.

The GNU spellings are load-bearing (`sed -u` keeps the capture unbuffered, so a
line is stamped when it is produced). On macOS, `coreutils` and `gnu-sed` must be
first on `PATH`.

**Or run it in a container**, when installing anything on the control node is
its own change request:

```bash
${CLAUDE_SKILL_DIR}/toolkit/docker/heliograph.sh <transport-repo-url>
```

It builds the image if needed, clones the transport repo, and hands over to
that repo's own `start.sh` - nothing below this point changes. The
unprivileged user inside is not a security boundary; the full account,
including the two ways the image gets built, is in
[references/container.md](references/container.md).

## 1. Set up the transport repo

```bash
${CLAUDE_SKILL_DIR}/scripts/bootstrap.sh <target-dir>
```

Then `git init`, add a **private** remote, and push.

**The transport repo must be private, and must be its own repo.** Captured logs
are committed to it, so everything the operator's commands print lands in that
history permanently. Never bootstrap into a repo that holds anything else, and
never into a public one.

Re-running the bootstrap over an existing transport repo is safe: it installs
what is missing and leaves what is already there alone.

Ask the operator to clone it on the control node. That is the only setup they do.

**If the loop is to run unattended, decide the credential now.** A forwarded ssh
agent key is the nicest option for an attended run and is no use at all once the
operator disconnects, which is exactly when `toolkit/service.sh` is keeping the
loop alive. An unattended loop needs a key on disk, a deploy key, or a token in
`~/.git-token`. See [references/transport.md](references/transport.md).

## 2. Baseline before theorising

```bash
./run.sh env                      # OS, tools, auth, proxy, DNS, git, this repo's commit
HOSTS="hosta hostb" ./run.sh net  # DNS + ICMP + TCP, and the reverse direction
```

`env` is the right first step of any investigation, whatever it turns out to be
about. A prior finding is a hypothesis to re-test, never a premise to build on.

## 3. Start a task

1. `git checkout -b task/<slug>`
2. Fill in `TASK.md`: the question, what is known, what would settle it. Do this
   first. It is what stops the steps becoming a fishing trip.
3. Write one step per question: `cp steps/_template.sh steps/<name>.sh`
4. Register it in the `case` table in `run.sh` **and** in the step-list comment
   above it, so `--list` stays honest.
5. Set `DEFAULT_STEP` to the one to run next, and push.

**`main` is the template; `task/<slug>` is one investigation.** Task branches are
not merged back. Only genuinely generic tooling returns to `main`, stripped of
anything task-specific, via a normal PR.

Writing the step itself: [references/steps.md](references/steps.md). Read it
before the first one. Every rule in it cost a round trip.

## 4. Drive it

Ask the operator to run `./start.sh` once, then stop relaying runs. It checks that
the machine can capture properly and that git can push from it, then starts the
agent, which watches `agent/request` and runs when the `id:` changes:

```
you       git pull --rebase, edit agent/request (new id), push ──▶ transport repo
agent     picks it up within seconds, runs ./run.sh
          pushes agent/status, then the log ───────────────▶ transport repo
you       poll, read the log, decide the next step ◀────────
```

**Always `git pull --rebase` before you push.** You and the agent push to the same
branch, and it pushes far more often than you do: a status commit when a run
starts and again when it ends, a progress snapshot every 60 seconds during a long
step, and the log itself. So the remote moves under you while you are writing the
next request, and a plain push is rejected:

```
! [rejected]  task/foo -> task/foo (fetch first)
```

That is not a fault, it is two writers on one branch working as intended. The
agent already does exactly this on its own side before every push. Rebase rather
than merge: it keeps the history readable as a sequence of requests and answers
instead of threading it with merge commits. Conflicts are rare in practice, since
the agent only ever writes `agent/status` and `ops-logs/` while you write
`agent/request` and `steps/`.

If they want to know whether the machine will work before committing to anything,
`./start.sh --check` answers that and changes nothing.

The trigger is the **`id`**, not a new commit: docs and step edits land
constantly and would otherwise fire runs nobody asked for. `stop: yes` ends the
agent from your side, which matters because nobody is sitting at that terminal.

Every step declares itself in its own file - `# heliograph-mode: read-only` or
`action` - and a step that declares neither will not run. A state-changing step
needs `CONFIRM=yes` in the request's `env:` **and** `run.sh`'s own gate, and the
agent refuses it altogether unless the operator started it with
`--allow-actions`. The loop is read-only by default; a refusal is published to
`agent/status` within seconds, so you find out on the next poll rather than after
a wasted round trip.

`cancel: yes` kills the step running right now, and `cancel: <id>` kills it only
if that id is the one running. The agent stays responsive while a step runs, so a
long or wrong run does not have to be waited out. A new `id` does **not** cancel:
it queues behind the running step, because an in-flight step may be mid-change.

A long run is not a black box: the partial log is pushed every 60 seconds with a
line count and the last real line, so `git pull` shows where it has got to.

While an agent is running, **say so and wait for the log**. Ask the operator only
for what git cannot carry: an interactive cloud login, a decision, or a fact only
they have.

Without an agent, the operator's whole interface is `git pull && ./run.sh`. Never
send them a command to paste; set `DEFAULT_STEP` and push.

Every runner, function and knob: [references/runner.md](references/runner.md).

### When the control node cannot reach git at all

Everything above assumes the control node can reach the git host. Sometimes it
cannot - a locked-down subnet whose default route goes to a firewall with no
policy for it has no outbound path at all, and git stops being a transport and
becomes a dependency that cannot be met.

`pigeonhole.sh` and `drop.sh` carry the same contract over Azure Blob Storage
instead. You write the request to a container, the agent polls it and writes the
log back, and neither side ever reaches the other - a private endpoint is
VNet-local, so that traffic never touches the route that is blocking everything
else. The capture is untouched: it still calls `run.sh`, so the log is the same
document.

```bash
./drop.sh send <id> <step>    # queue a step
./drop.sh watch <id>          # wait, then print the log
```

**Measure before reaching for it.** Git is better when git works, and an image
pull succeeding proves nothing - a container platform pulls on its own side, so
a container can start cleanly on a host with no network at all. When to use it,
how the lane replaces branch binding, and the traps:
[references/pigeonhole.md](references/pigeonhole.md).

## 5. Read the log

- **Header block first**: branch, commit, host, user. A divergence between the
  commit you pushed and the one they ran explains a surprising share of "but I
  fixed that".
- **Scan the timestamp column for gaps before reading the content.** A gap is a
  finding: in an untimed log a hang and slow progress are indistinguishable.
- `probe_summary` gives the tally, the footer gives the real exit code.
- **Read the whole log, including the parts that worked.** A passing probe beside
  a failing one is the control that tells you what the failure means.
- Record what was *measured* in `TASK.md`, separately from what you concluded.
  Measurements stay true; conclusions get revised.

**A green exit means the probes that ran passed, not that the work happened.**
Verify the outcome, not the exit code.

## Hard rules

These outrank convenience. Each one is here because breaking it cost a full
round trip or worse.

1. **Never truncate.** No `head`, no `tail -20`, no `2>/dev/null` on the thing
   being diagnosed. The line you cut is the one you needed.
2. **Measure, do not infer.** Say what a log showed, not what it implies.
3. **Keep a control.** A probe with nothing to compare against is an anecdote.
4. **Change one thing between runs.** Two changes and a different result tells
   you nothing.
5. **Read-only until earned.** A step changes state only when you can say
   precisely what it will do and why, and then it carries the `CONFIRM=yes` gate.
6. **Never commit task work to `main`.**
7. **Never ask the operator to hand-edit anything.** Deliver a change as a
   payload the step copies into place. An unlogged manual edit is exactly the
   divergence these logs exist to rule out.

The full method, and the mistakes behind each rule:
[references/method.md](references/method.md). Worth reading in full before a hard
investigation.

## Running it in Azure, instead of on somebody's terminal

Sometimes there is no willing human to start `./start.sh` and leave it running.
`toolkit/azure/` runs the agent as Azure infrastructure instead. Five hosts:

| host | state |
|---|---|
| Container Instances, VNet-injected | deployed and proven |
| Web App for Containers | deployed and proven |
| Container Apps Job, scheduled | deployed and proven |
| VM with a systemd unit | written and validates, never deployed |
| **Function App, Flex Consumption** | written and validates, Terraform only |

All bring-your-own: the estate passes in a VNet, subnet, plan or environment
that already exists, and the template creates the compute and nothing else. The
checkout is transient. Git is the persistence, so if the compute dies you run
the step again.

**The Function host is the exception to all of that**, and the one to reach for
when the estate will not give you anywhere to keep a process. It is not a loop:
a timer answers at most one request per tick, so it needs `PIGEONHOLE_RESUME=1`
to know what it already answered. There is no `git` in its image, so it uses the
blob transport - which means it needs no egress at all, and works in a subnet
with no route off it. See [references/azure.md](references/azure.md).

Two things that will waste your time if you do not know them:

- The published image tag has **no `v`**. The git tag is `v1.0.0-rc1`, the image
  is `ghcr.io/dbhq-uk/heliograph-toolkit:1.0.0-rc1`.
- For a GitHub transport repo, set **`GIT_TOKEN_USER=x-access-token`**. Without
  it git says `could not read Username`, which reads like a missing credential
  rather than a wrong one.

Everything else, including what only showed up by deploying these, is in
[references/azure.md](references/azure.md).

## Secrets

Logs are committed and pushed, so anything a command prints is in git history
permanently.

- `cap_redact` masks the obvious shapes (`password=`, `Bearer`, `Basic`, a
  credential carried in a URL, private keys). It is a safety net, **not** a
  guarantee. Never deliberately run something that prints a secret.
- **Name secrets, never read them.** Listing secret *names* settles "does this
  exist here". The value is never the question.
- The transport repo's `.gitignore` blocks the usual carriers. Do not `git add
  -f` around it.

### When a value has to go the other way

Occasionally the far side needs a secret it cannot fetch for itself. `secret.sh`
carries it as ciphertext, with the passphrase defined by a human on both machines
and never committed:

```bash
./secret.sh key                    # on BOTH machines, then compare fingerprints
./secret.sh put registry-pass      # paste the value, Ctrl-D
git add secrets/ && git commit && git push
```

and in a step on the far side, captured, never echoed:

```bash
PASS="$("$HERE/../secret.sh" get registry-pass)"; export PASS
```

**It is transport, not storage**: the ciphertext is in history forever. Prefer
short-lived, narrowly scoped credentials, and land the real secret in whatever
store the far side has. Details, and why each guard is there:
[references/secrets.md](references/secrets.md).

## References

| | |
|---|---|
| [references/steps.md](references/steps.md) | writing a step, and the traps that cost round trips |
| [references/runner.md](references/runner.md) | `start.sh`, `run.sh`, `agent.sh`, `caprun.sh`, every `cap_*` and knob |
| [references/method.md](references/method.md) | how to debug across a gap. The expensive lessons |
| [references/transport.md](references/transport.md) | how the control node authenticates to the git host |
| [references/pigeonhole.md](references/pigeonhole.md) | the blob transport, for a control node that cannot reach git at all |
| [references/azure.md](references/azure.md) | running the agent in Azure, and what deploying it taught us |
| [references/secrets.md](references/secrets.md) | `secret.sh`, for a value that has to reach the far side |
| [references/remote-repo.md](references/remote-repo.md) | changing a repo that is also on the far side |
| [references/container.md](references/container.md) | running the control node in a container: what ships, why, and the honest limits |
| [references/windows.md](references/windows.md) | a Windows control node, steps written in PowerShell, and what line endings really do |
| [references/service.md](references/service.md) | making the loop outlive the session that started it |
