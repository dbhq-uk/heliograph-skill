# Runner reference

Two runners, one library. A **runner** owns the log file, the timestamps and the push; a
**step script** just prints to stdout. That split is deliberate - it's what lets you run
`./steps/foo.sh` straight to the terminal while you're writing it, and get the full captured
treatment from `./run.sh foo` without changing a line.

`agent.sh` sits above both: it decides *when* a runner runs, and nothing else.

---

## `agent.sh` - the unattended loop

```bash
./agent.sh                     # poll, run, push, repeat
./agent.sh --allow-actions     # ...including steps that change state
./agent.sh --once              # one requested run, then exit
./agent.sh --interval 15       # seconds between polls (default 5)
```

Start it once on the control node and leave it. It polls this branch, and when the `id:` in
[`agent/request`](../toolkit/agent/request) changes it runs that step and pushes the log back:

```
Claude   edits agent/request (new id), pushes ─────────────▶ repo
agent    sees it within seconds, runs ./run.sh
         pushes agent/status "running" ────────────────────▶ repo
         run.sh pushes ops-logs/<step>-<UTC>.txt ──────────▶ repo
         pushes agent/status "idle exit=N" ────────────────▶ repo
Claude   polls, reads the log, decides the next step ◀──────
```

The operator types one command, once. After that the loop is git in both directions, and nobody
has to be sitting on the far side to relay each run.

**The trigger is `id`, not "a new commit."** Docs, step edits and payload changes land on a task
branch constantly; if any commit fired a run, the agent would run on all of them. Only a changed
`id` starts anything, so a run is always something someone asked for on purpose.

### agent/request

| field | |
|---|---|
| `id` | **the trigger.** Any unique string; a UTC stamp plus the step name reads well |
| `step` | which step to run. Blank means `DEFAULT_STEP` from `run.sh` |
| `env` | extra environment for the run - `CONFIRM=yes`, `PREPROD_REPO=/path`, ... |
| `stop` | `yes` makes the agent exit cleanly after its current run |
| `note` | free text for the next human. Ignored by the agent |

`stop: yes` matters more than it looks: the whole point is that nobody is at that terminal, so the
agent has to be stoppable from the same side that starts its work.

### agent/status

Pushed on every transition, so the far side can tell "running for four minutes" from "never woke
up" - which is otherwise invisible until a log appears.

```
state:    running | idle | refused | stopped
id:       the request it is working on
step:     which step
host:     which control node
started:  finished:  exit:  log:      (on completion)
```

### Safety

`--allow-actions` (or `ALLOW_ACTIONS=1`) is required before the agent will run a step listed in
`ACTION_STEPS` - `apply deploy destroy reset` by default. Without it the request is **refused**,
recorded in `agent/status`, and not retried. An unattended loop that can change infrastructure
because a file changed is a different proposition from one that only reads, and it should be a
deliberate choice made when starting the agent, not a default.

This does not replace `run.sh`'s own `CONFIRM=yes` gate - a step gated there still needs
`env: CONFIRM=yes` in the request.

### Operational notes

- **One agent per checkout.** `.agent.lock` holds the pid; a second refuses to start rather than
  double-running every request. A stale lock from a dead pid is cleared automatically.
- **A fetch failure is a blip, not a death.** The loop is meant to outlive a flapping link: it
  reports, backs off and carries on, and says so when the fetch recovers.
- **It never resolves conflicts.** If `pull --rebase` fails it aborts the rebase, says so and keeps
  polling. It will not force anything or discard local work.
- **`.agent-state` and `.agent.lock` are gitignored** - they are per-node facts, not shared ones.
- **An interrupted run is retried, not skipped.** `.agent-state` is written after
  a run finishes, so an agent killed mid-step picks the same request up again on
  restart. That is the right default for a read-only diagnostic and the reason
  state-changing steps are gated twice: if you do not want a retry, change the
  `id` before restarting.
- The agent decides *when*; `run.sh` still owns the log, the timestamps and the push. Keep it that
  way, for the same reason steps don't own their own logging.

---

## `run.sh` - the step runner

```bash
git pull && ./run.sh              # the current step (DEFAULT_STEP)
./run.sh <step>                   # a specific one
./run.sh --list                   # what this branch can do
```

The operator's whole interface. You set `DEFAULT_STEP` near the top of the file and push;
they pull and run. They never type a host name, an inventory or an extra-var.

Anatomy, in order:

1. `--list` prints the step-table comment - so keeping that comment current is not optional.
2. The `case` table maps a step name to an argv array, and **validates the step before any
   side effect**. An unknown step exits 2 having done nothing.
3. A second `case` gates state-changing steps behind `CONFIRM=yes`, so a stale `DEFAULT_STEP`
   can't destroy anything on its own.
4. `cap_header` → `cap_run` → `cap_footer` → `cap_push`.

Log: `ops-logs/<step>-<UTC>.txt`. Exit code is the step's real exit code.

## `caprun.sh` - anything else

```bash
./caprun.sh <label> [--] <command> [args...]
```

For a one-off that doesn't justify a step. Use `--` when the command takes flags of its own.

```bash
./caprun.sh tf-plan      -- terraform plan -no-color -input=false
./caprun.sh ansible-ping -- ansible -i inv.ini all -m win_ping
./caprun.sh dbplay       -- ../ops-repo/run-playbook.sh prod cluster.yml inv.json
SUDO=1 ./caprun.sh mount -- ./script-that-escalates.sh
```

Log: `ops-logs/<label>-<UTC>.txt`. Exit code is the command's real exit code, so it's safe to
chain or gate on.

---

## Knobs (both runners)

| var | default | effect |
|---|---|---|
| `PUSH` | `1` | `PUSH=0` captures to `ops-logs/` but does **not** commit/push |
| `SUDO` | `0` | `SUDO=1` pre-caches sudo up front, with a 60s keep-alive. Use for anything that escalates on the control node - otherwise it hangs on an invisible password prompt |
| `CONFIRM` | unset | required (`CONFIRM=yes`) for gated state-changing steps in `run.sh` |
| `REDACT` | `1` | `REDACT=0` disables secret masking, when it's hiding something you need |
| `LOG_DIR` | `ops-logs/` | where the log is written |
| `NO_COLOUR` | unset | plain banners, no ANSI |
| `GIT_TOKEN` / `GIT_TOKEN_FILE` | unset | token for the git push over an HTTPS remote (see *Pushing* below) |

---

## `caplib.sh` - the shared functions

`source` it, then call the `cap_*` functions. One implementation of the pattern; don't fork it.

| function | purpose |
|---|---|
| `cap_banner <msg...>` | cyan progress banner to the terminal only (not the log) |
| `cap_sudo_precache` | prompt for sudo once, up front, + a 60s keep-alive. Call only for runs that escalate |
| `cap_header <out> <label> [context...]` | truncate the file and write the provenance block: UTC, host, user, git branch + commit |
| `cap_section <out> <title...>` | a labelled divider, teed to both the log and the terminal |
| `cap_run <out> <cmd...>` | run a command; strip ANSI, redact, **timestamp every line**, `tee -a`, return the real exit code via `PIPESTATUS` |
| `cap_footer <out> <rc>` | finished-UTC / exit-code / OK-or-FAILED block |
| `cap_redact` | stdin filter masking `password=`, `Bearer ...`, `Basic ...`, private keys. Honours `REDACT=0` |
| `cap_git <args...>` | `git`, with an auth header attached when a token is configured (HTTPS remotes only) |
| `cap_push <out> <msg>` | stage **only** that file, commit, `pull --rebase`, push. On failure prints the local path instead of dying - a failed push must never lose the log |

### Why every line is timestamped

Because after the fact, in an untimed log, a hang and slow progress look identical. With a UTC
clock on every line, a gap in the column tells you exactly which operation stalled and for how
long. It is the single most useful property of these logs - don't strip it for tidiness.

---

## `lib/` - helpers for step scripts

**`probe.sh`** - the core of any step.

| | |
|---|---|
| `sec <title...>` | a divider, so a long log stays skimmable |
| `probe <label> <cmd...>` | run it, print it, record a failure, **carry on** |
| `probe_opt <label> <cmd...>` | same, but a non-zero exit is expected and not counted |
| `probe_summary` | print the tally; returns 1 if anything failed |
| `have <tool>` | quiet "is this on PATH" |

`probe` never aborts, and step scripts never `set -e`: a diagnostic wants every result, not
the first failure.

**`remote.sh`** - `rt_dns`, `rt_ping`, `rt_tcp` (pure bash, no `nc`), `rt_matrix` (host × port
table), `rt_ssh` (BatchMode, time-bounded), `rt_ps` / `rt_win_info` (Windows over SSH - PowerShell invoked explicitly because a Windows host running OpenSSH commonly defaults its shell to cmd; pass a plain string,
`-EncodedCommand` is known to break through this path).

`rt_ssh` turns host-key checking **off** by default, because a locked-down control
node routinely has no `known_hosts` and strict checking would turn every first
connection into the silent hang `BatchMode` exists to prevent. The cost is that
these probes do not detect a man-in-the-middle: treat what they return as
diagnostic evidence rather than an authenticated channel, never send a secret over
one, and set `RT_SSH_STRICT=1` wherever `known_hosts` is provisioned.

**`tfguard.sh`** - for running terragrunt against a repo you do not own.

| | |
|---|---|
| `tf_lock_guard <repo> <slice>` | restores that slice's tracked `.terraform.lock.hcl` to HEAD if something moved it, loudly, and reports the azurerm version in force either way |
| `tg <args...>` | terragrunt in `$TG_SLICE`, retrying **only** when the subcommand name was rejected |

Both exist because the same two mistakes were made twice each.

**`terraform init -upgrade` is not "fetch the new module ref".** It re-resolves
*providers* to latest, ignoring the lock file - which here means azurerm 5.x over a locked 3.x or
4.x, breaking `azurerm_private_dns_a_record`, `azurerm_private_dns_zone_virtual_network_link` and
`azurerm_linux_virtual_machine` in modules the change never touched. The errors then point at files
nobody edited. A changed module `?ref=` is re-fetched by a **plain** init anyway: module
installation is not governed by the lock file.

**`.terraform.lock.hcl` is tracked in these slices**, so an accidental upgrade leaves the next
person a slice that breaks on init. Restoring it is undoing damage, not tidying, and it has to
happen *before* terragrunt runs.

`tg` retries only on "unknown command" because retrying on any non-zero re-runs a plan that failed
on its merits - doubling the wait for no new information.

**`terraform.sh`** - `tf_init`, `tf_validate`, `tf_plan` (translates `-detailed-exitcode` 2
from "failure" to "changes pending"), `tf_state_list`, `tf_output`, `tf_workspace`,
`tf_providers`. Read-only on purpose: **no destroy, no `state rm`**. Those get typed out by a
human who means it.

**`ansible.sh`** - `an_ping` / `an_win_ping`, `an_facts`, `an_play`, `an_check`, `an_list`,
`an_inventory`. For ad-hoc use from this repo. If the playbook lives in a repo with its own
entrypoint (one that resolves the environment and fetches the inventory, say), run *that*
through `caprun.sh` rather than reimplementing it here.

---

## Pushing

`cap_push` stages only the log file, commits, rebases, pushes. It stages nothing
else, ever - a captured run must not sweep up whatever else was in the working
tree.

If the push fails, the log is still committed locally and the path is printed.
Nothing is lost; it needs a manual `git push`.

How the control node should authenticate to the git host - SSH with a forwarded
agent key, the HTTPS token fallback `cap_git` carries, and the traps in both - is
in [transport.md](transport.md).

---

## Logs

`ops-logs/*.txt` is tracked deliberately - the log is the deliverable, and committing it is how
it gets out of an environment you cannot reach. Clear them with `git rm ops-logs/*.txt` when an
investigation closes; history keeps them.
