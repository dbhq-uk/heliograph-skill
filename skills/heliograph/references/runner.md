# Runner reference

Two runners, one library. A **runner** owns the log file, the timestamps and the push; a
**step script** just prints to stdout. That split is deliberate - it's what lets you run
`./steps/foo.sh` straight to the terminal while you're writing it, and get the full captured
treatment from `./run.sh foo` without changing a line.

`agent.sh` sits above both: it decides *when* a runner runs, and nothing else.
`start.sh` sits above that: it decides *whether this machine can run one at all*.

---

## `start.sh` - the first command on a new machine

```bash
./start.sh                     # check this machine, then run the agent
./start.sh --check             # check only, change nothing, exit
./start.sh --branch task/foo   # check that branch out first
./start.sh -- --once           # everything after -- goes to agent.sh
```

`agent.sh` decides *when* a runner runs. `start.sh` decides *whether this machine
can run one at all*, and owns nothing else: no log, no push, like `secret.sh`.

It answers two questions that were previously answered by a failed round trip.

**Can this machine produce a usable capture?** The toolkit depends on `sed -u`
and `base64 -w0`, and until now that was prose in a README rather than
something checked. Neither spelling is universal: `sed -u` is absent from
busybox, `base64 -w0` is absent from BSD/macOS base64. A busybox `sed` does
not fail loudly: the capture still runs and every line carries the same
timestamp, which reads like a working log while destroying the single
property these logs exist for. `start.sh` refuses to start the agent on
one, and says what to install.

**Can git push from here?** A token that authenticates against the host's REST API
says nothing about the git path, and read access says nothing about write access.
It runs `ls-remote`, then `push --dry-run origin HEAD:refs/heads/heliograph-write-check`
against a ref that deliberately **does not exist** on the remote. The push still
negotiates with `git-receive-pack`, which is the service write access is granted
on, so a read-only credential fails it; and because the ref does not exist it
cannot be refused as a non-fast-forward, so a checkout that is merely *behind*
origin is not misreported as a credential failure. `--dry-run` creates nothing, so
the ref is never actually left on the remote. A fast-forward refusal is reported
as a `warn` about history and does not block; anything else blocks. The failure
this prevents is an hour-long step that captures perfect evidence and cannot
deliver it.

It also reports which credential is in force, by mechanism and length, **never by
value**: `cap_auth_describe` shares one precedence list with `_cap_auth_header`, so
what it reports cannot disagree with what git uses.

`--check` changes nothing at all: no fetch, no checkout, no pull. It is what gets
run on a node where nobody is permitted to alter anything yet, so the answer to
"will this work here" can be had before asking for permission.

**It does not clone**, because it ships inside the transport repo and the clone has
already happened by the time it runs. **It installs nothing**, which is what lets it
run where installing is forbidden.

| exit | |
|---|---|
| 0 | clear, or `--check` and clear |
| 1 | a blocking problem, named, with what to do about it |
| 2 | a usage error |

---

## `agent.sh` - the unattended loop

```bash
./agent.sh                     # poll, run, push, repeat
./agent.sh --no-actions        # refuse any step that changes state
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
| `env` | extra environment for the run - `CONFIRM=yes`, `TARGET_REPO=/path`, ... |
| `cancel` | `yes` kills the step running right now; an id kills it only if that id is running |
| `stop` | `yes` makes the agent exit cleanly after its current run |
| `note` | free text for the next human. Ignored by the agent |

`stop: yes` matters more than it looks: the whole point is that nobody is at that terminal, so the
agent has to be stoppable from the same side that starts its work.

### Watching a run in progress

While a step runs, the agent pushes the **partial log** every `PROGRESS_EVERY` seconds (default
60, `0` disables) along with an `agent/status` carrying a line count and the last real line:

```
state:    running     progress: 412 lines
log:      ops-logs/tls-survey-20260813T134932Z.txt
last:     11:31:29 | ---------- openssl s_client -connect hostb:443 ----------
```

So `git pull` on a long run shows where it has got to. "Running for forty minutes" and "wedged"
used to look identical from the far side; the last line usually names the probe currently in
flight.

**It pushes but never pulls or rebases.** The step is appending to that log through an open file
descriptor - a rebase would rewrite the file underneath it and the appends would continue at a
stale offset, corrupting the evidence this exists to publish. A rejected push (because the remote
moved) is just retried next cycle, and `run.sh`'s own `cap_push` reconciles properly at the end.

The runner still owns the log. This publishes a snapshot and never writes to it.

### Cancelling a run

The step runs in its own process group, in the background, and the loop keeps polling while it
works. An hour-long step no longer makes the agent deaf for an hour.

```
cancel: yes                     # kill whatever is running
cancel: 20260813T1500Z-survey   # kill it only if that id is the one running
```

- **A cancel already in the file when a step starts is ignored.** Only a change is an instruction.
  Without that, the `cancel: yes` that stopped one run sits there and reaps the next request the
  moment it starts - observed in testing as a step that finished cleanly and was still published as
  `cancelled`. Clearing the field, then setting it again, counts as a change.
- `cancel: <id>` is the belt to that braces: it names what it is stopping, so it cannot reap a
  later, wanted run even in principle.
- `TERM` first, `KILL` after five seconds. The partial log is kept: a log that stops mid-sentence
  is still evidence, and usually the evidence you wanted.
- The run publishes state `cancelled` with exit `130`, so a cancelled run is never mistaken for a
  step that failed on its merits.
- **A new `id` does not cancel.** An in-flight step may be mid-change, and inferring "kill it" from
  a queued request would be guessing. The new request waits its turn, and the agent says so.
- While a step runs the agent reads the request from the **remote ref**, never by pulling. A rebase
  underneath a running step would corrupt the run it was only trying to observe.
- Ctrl-C on the agent signals the running step too, rather than leaving it detached to push a log
  with nothing watching it.

### agent/status

Pushed on every transition, so the far side can tell "running for four minutes" from "never woke
up" - which is otherwise invisible until a log appears.

```
state:    running | idle | cancelled | refused | stopped
id:       the request it is working on
step:     which step
host:     which control node
started:  finished:  exit:  log:      (on completion)
```

### Safety

A step that changes state is recognised two ways: by **name** (`ACTION_STEPS` - `apply deploy
destroy reset` by default) and by **env** (`ACTION_ENV` - anything matching `APPLY=1`, `CONFIRM=yes`,
`DESTROY=1`, `FORCE=1`, `WRITE=1` in the request's `env:` line). The name-only version had a hole: a
step named for a diagnostic that only writes once `env: APPLY=1` is passed sailed straight through.

Such a step still has to carry `env: CONFIRM=yes`, and `run.sh` gates it again on its own. **Both
gates, deliberately**, and neither has anything to do with how the agent was started.

`ALLOW_ACTIONS` decides whether this agent will run one at all. **It defaults to 1**, because it was
a flag typed once at agent start, often days before the request it gated: forgetting it surfaced as
a silent `refused` long after the request was pushed, which wastes the round trip this tooling
exists to save. Start with `--no-actions` (or `ALLOW_ACTIONS=0`) for a loop that must never write:
the request is then **refused**, recorded in `agent/status`, and not retried.

Making it the default is a real change in posture, so be plain about what still holds. `apply`,
`destroy` and friends will not run because a file changed: they need `CONFIRM=yes` in the request
**and** `run.sh`'s gate **and** whatever mode check the step itself has. What the default removes is
a fourth gate that could only be set at a moment when nobody knew yet what would be asked for.

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
| `PROGRESS_EVERY` | `60` | seconds between partial-log pushes while a step runs (`agent.sh`; `0` disables) |
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
| `cap_auth_describe` | which credential mechanism is in force, by name and length. Never the value |
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

---

## `secret.sh` - a value going the other way

```bash
./secret.sh key             # define the passphrase, on BOTH machines
./secret.sh key show        # its fingerprint, so the two can be compared
./secret.sh put <name>      # read from stdin, store encrypted under secrets/
./secret.sh get <name>      # decrypt to stdout, for $( ) capture in a step
./secret.sh check <name>    # prove it decrypts here, without printing it
./secret.sh list            # names, sizes, dates
./secret.sh rm <name>       # drop it from the working tree (not from history)
```

Not a runner: it owns no log and pushes nothing. It is here because a step
occasionally needs a value the far side cannot fetch for itself, and the transport
repo is the only channel. The ciphertext travels in git; the passphrase is typed
by a human on each machine and never committed.

`get` is the only part a step calls, and it never prompts. The full account, and
why each guard is there, is in [secrets.md](secrets.md).
