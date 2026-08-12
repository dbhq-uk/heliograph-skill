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

Ask the operator to run `./agent.sh` once, then stop relaying runs. It watches
`agent/request` and runs when the `id:` changes:

```
you       edit agent/request (new id), push ───────────────▶ transport repo
agent     picks it up within seconds, runs ./run.sh
          pushes agent/status, then the log ───────────────▶ transport repo
you       poll, read the log, decide the next step ◀────────
```

The trigger is the **`id`**, not a new commit: docs and step edits land
constantly and would otherwise fire runs nobody asked for. `stop: yes` ends the
agent from your side, which matters because nobody is sitting at that terminal.

State-changing steps need `--allow-actions` on the agent **and** `CONFIRM=yes` in
the request's `env:`. Both, deliberately.

While an agent is running, **say so and wait for the log**. Ask the operator only
for what git cannot carry: an interactive cloud login, a decision, or a fact only
they have.

Without an agent, the operator's whole interface is `git pull && ./run.sh`. Never
send them a command to paste; set `DEFAULT_STEP` and push.

Every runner, function and knob: [references/runner.md](references/runner.md).

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

## Secrets

Logs are committed and pushed, so anything a command prints is in git history
permanently.

- `cap_redact` masks the obvious shapes (`password=`, `Bearer`, `Basic`, private
  keys). It is a safety net, **not** a guarantee. Never deliberately run
  something that prints a secret.
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
| [references/runner.md](references/runner.md) | `run.sh`, `agent.sh`, `caprun.sh`, every `cap_*` and knob |
| [references/method.md](references/method.md) | how to debug across a gap. The expensive lessons |
| [references/transport.md](references/transport.md) | how the control node authenticates to the git host |
| [references/secrets.md](references/secrets.md) | `secret.sh`, for a value that has to reach the far side |
| [references/remote-repo.md](references/remote-repo.md) | changing a repo that is also on the far side |
