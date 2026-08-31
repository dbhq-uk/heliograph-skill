# Writing a step

A **step** is one script that answers one question. The runner owns the log file,
the timestamps and the push; a step just prints to stdout and knows nothing about
logging. That split is what lets you run `./steps/foo.sh` straight to the
terminal while writing it, and get the full captured treatment from
`./run.sh foo` without changing a line.

```bash
cp steps/_template.sh steps/cluster-state.sh && chmod +x steps/cluster-state.sh
```

```bash
# in run.sh, the case table:
  cluster)  CMD=(./steps/cluster-state.sh) ;;
```

```bash
# and the comment block above it, so --list stays honest:
#      cluster  is the cluster formed, and do both nodes agree?   (~1 min)
```

Both registrations, every time. `--list` prints that comment block verbatim, so a
step missing from it is invisible to the operator.

## The rules

- **Name it for the question it answers**, not the tool it runs.
  `cluster-state`, not `run-powershell`.
- **No `set -e`.** A diagnostic wants every probe's result, not the first
  failure. Use `probe`, which records a failure and carries on.
- **Never prompt.** No interactive sudo (use `SUDO=1` on the runner, which
  pre-caches it), no host-key questions, no `read`. A prompt through the capture
  pipeline is invisible, and the run just hangs.
- **Declare what it is, or it will not run.** Every step carries
  `# heliograph-mode: read-only` or `# heliograph-mode: action` in its first 30
  lines. `run.sh` reads that line out of the step's own file; a step declaring
  neither is refused with exit 3, and an `action` needs `CONFIRM=yes` as well, so
  a stale `DEFAULT_STEP` can never do damage on its own. Both templates already
  carry the line - keep it when you copy one, and change it to `action` the
  moment the step starts changing something.
- **Never truncate.** No `head`, no `tail -20`, no `2>/dev/null` on the thing you
  are actually diagnosing.
- **Carry a control.** Where you can, measure something known-good in the same
  run: the other node, another host in the same subnet, the environment where it
  works. A result with nothing to compare against is an anecdote.
- **One question per step.** If you cannot write the question in one sentence,
  the step is doing too much. Split it.

## Helpers

From `lib/probe.sh`, sourced by every step:

| | |
|---|---|
| `sec <title...>` | a divider, so a long log stays skimmable |
| `probe <label> <cmd...>` | run it, print it, record a failure, carry on |
| `probe_opt <label> <cmd...>` | same, but a non-zero exit is expected and not counted |
| `probe_summary` | print the tally. Returns 1 if anything failed |
| `have <tool>` | quiet "is this on PATH" |

`lib/remote.sh`, `lib/terraform.sh`, `lib/ansible.sh` and `lib/tfguard.sh` are
opt-in: source the ones the step needs. See
[runner.md](runner.md#lib---helpers-for-step-scripts).

## Traps that have cost round trips

Each of these produced a log that looked like a finding about the estate and was
actually a bug in the step. Across a gap that costs a full cycle, so they are
worth knowing by heart.

- **Backticks inside double quotes execute.** A label like
  ``probe "check the `service` key"`` runs `service` and substitutes its output.
  Use single quotes for a label containing backticks. This bit four times in one
  investigation.
- **`/bin/sh` is dash on Debian and Ubuntu, not bash.** No process substitution
  `<(...)`, no ANSI-C quoting `$'\t'`. Both fail in ways that look like data
  problems: `IFS=$'\t'` silently splits on the letter "t". Use `bash -c` for
  anything beyond plain POSIX.
- **`| head` can kill the script.** Under `set -euo pipefail`, `head` closing the
  pipe gives the producer SIGPIPE, `pipefail` propagates 141 and `set -e` exits.
  It is timing-dependent, so it passes the dry run and fails the real one. Use
  `awk 'NR<=N'`, which reads to the end.
- **An expanded `case` pattern is a literal.** `case $x in $pat)` with
  `pat='*a*|*b*'` matches a literal pipe, not alternation, and silently matches
  nothing. Use `[[ $x =~ $re ]]`.
- **`"${VAR:-${ARRAY[@]}}"` collapses to one word.** Build the list with an
  explicit if/else, or the loop runs once.
- **A diagnostic must never abort the operation it describes.** Put `|| true`
  behind anything that only exists to make the log readable.
- **Beware the guaranteed pass.** Before trusting a check, ask what it would look
  like if the thing were broken. A sudo-password test run as an account with
  `NOPASSWD:ALL` passes no matter what. If a probe cannot fail, it is not a
  probe.

## Ad-hoc runs

When it is not worth a step:

```bash
./caprun.sh tf-plan -- terraform plan -no-color -input=false
./caprun.sh disk    -- ssh appserver01 df -h
PUSH=0 ./caprun.sh quicklook -- systemctl status nginx      # capture, do not push
```

Same capture, same push, no entry in the step table. If the thing to run lives in
another repo with its own entrypoint, call **that** through `caprun.sh` rather
than reimplementing it as a step.
