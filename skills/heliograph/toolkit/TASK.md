# TASK

> On `main` this file is the template. Fill it in on your `task/<slug>` branch - it is the
> record of the investigation, and it is what stops the next round of steps becoming a fishing
> trip. Keep **measured** and **concluded** apart: measurements stay true, conclusions get
> revised.

---

## Question

<!-- One sentence. What would we know at the end that we don't know now? -->

## Environment

| | |
|---|---|
| Target(s) | <!-- hosts / resource group / subscription / cluster --> |
| Environment | <!-- dev / test / preprod / prod / ... --> |
| Repo(s) involved | <!-- the repos this touches, if any --> |
| Work item | <!-- ticket / issue id, if there is one --> |
| Operator | <!-- who runs ./run.sh --> |

## What we already know

<!-- Facts with a source. "The last run at 14:02Z showed X" - not "X is broken".
     Anything carried over from a previous investigation is a hypothesis to re-test. -->

## Hypotheses

| # | Hypothesis | How we'd settle it | Status |
|---|---|---|---|
| 1 | | | open |

## Steps on this branch

| step | answers | read-only? |
|---|---|---|
| `env` | control-node baseline | yes |
| `net` | can we reach the targets, and in both directions | yes |

## Measured

<!-- Append-only. One entry per run. Log file name, what the log actually showed.
     Resist writing interpretation here. -->

| when (UTC) | step | log | measured |
|---|---|---|---|
| | | | |

## Concluded

<!-- What the measurements support, and what they rule out. Revise freely - and when you do,
     say which measurement changed your mind. -->

## Next

<!-- The single next step, and why it's the one that moves this forward.
     This should match DEFAULT_STEP in run.sh. -->
