# heliograph

Debug and change a machine you cannot log into, through an operator who cannot
debug it. **Git is the transport in both directions.**

## The problem it solves

The machine is in a client-owned, air-gapped or change-controlled environment.
You are the one who knows what to ask it, and you are never getting SSH. The
person who *can* reach it has their own work and should not be your terminal.

So the loop stops being a relay. You push a step; they run one command that never
changes; the whole run comes back as a log that is committed and pushed.

## How it works

1. **Bootstrap a transport repo** with `scripts/bootstrap.sh`. Private, its own
   repo, because captured logs are committed to it
2. **Baseline** with `./run.sh env` before theorising about anything
3. **One branch per investigation**, one step per question, `TASK.md` holding
   what was measured apart from what was concluded
4. **The operator runs `./start.sh` once** and stops relaying. It proves the
   machine can capture and that git can push from it, then starts the agent,
   which watches the branch and runs when the request `id` changes
5. **Read the whole log**, record the measurement, decide the next step

## The two properties that make it work

**Every captured line carries a UTC timestamp**, so a hang shows as a gap. In an
untimed log, a hang and slow progress are indistinguishable after the fact.

**The log is pushed even on failure**, with the real exit code intact, so a
failed run reads as clearly as a successful one and no round trip is wasted.

## What is where

| | |
|---|---|
| [`SKILL.md`](SKILL.md) | the workflow and the hard rules |
| [`references/method.md`](references/method.md) | how to debug across a gap. The expensive lessons |
| [`references/steps.md`](references/steps.md) | writing a step, and the traps that cost round trips |
| [`references/runner.md`](references/runner.md) | every runner, `cap_*` function and knob |
| [`references/transport.md`](references/transport.md) | how the control node authenticates to the git host |
| [`references/remote-repo.md`](references/remote-repo.md) | changing a repo that is also on the far side |
| [`references/secrets.md`](references/secrets.md) | `secret.sh`, for a value that has to reach the far side |
| [`scripts/bootstrap.sh`](scripts/bootstrap.sh) | installs the toolkit into a transport repo |
| [`toolkit/`](toolkit/) | the payload: `start.sh`, `run.sh`, `agent.sh`, `caprun.sh`, `caplib.sh`, `secret.sh`, `lib/`, `steps/` |

Nothing in `toolkit/` runs from here. It is copied out and runs on a machine you
will never see, in front of someone who cannot debug it. Edit it accordingly.

## What it will not do

Give you access you do not have. There is no tunnel, no proxy and no held
connection. Every command runs because someone with legitimate access chose to
run it, and the only thing crossing the gap is a git commit.
