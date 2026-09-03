# intercom - HTTP submit and poll

The transport for an agent you *can* reach: submit a step over HTTPS, poll for its log. Storage stays behind the agent, and the operator never touches it.

## When to use it

Only when the agent's endpoint is reachable from the control node. That is unusual, because heliograph exists for the case where it is not - but an Azure Function App has a public HTTPS endpoint while sitting inside the VNet, and when that is true the [pigeonhole](pigeonhole.md) is indirection with no purpose: credentials for the operator to hold, a timer interval to wait, and four blob operations to move text between two machines that can already talk.

| | reaches the agent | operator needs | round trip |
|---|---|---|---|
| git | agent reaches a remote | a git remote both can see | a push and a pull |
| pigeonhole | neither reaches the other | storage credentials | one timer interval |
| **intercom** | **control node reaches the agent** | **a URL and a function key** | **seconds** |

The pigeonhole is not deprecated by this and is still the right answer far more often. The Function host ships both; see [azure.md](azure.md).

## What it costs

**The caller supplies the script, so `heliograph-mode:` stops being a control.** The mode gate reads the declaration out of the file it is about to run. When the file ships with the code, that is evidence. When the caller writes the file, the caller writes the header too, and it is a claim about itself.

That breaks no promise heliograph ever made - `run.sh` has always said that nothing in a shell runner can stop an author declaring `read-only` and then writing `rm -rf`. But it does mean **the only real control is who can reach the endpoint**, and this transport must be deployed with both of these or neither:

- **A function key.** Both routes are `authLevel: function`. The client sends it as an `x-functions-key` header rather than `?code=`, so it stays out of proxy logs and shell history.
- **An IP allowlist.** `site_config.ip_restriction` on the Function App, and `scm_use_main_ip_restriction` so the deployment host follows the same list.

A leaked key is useless off-network. An on-network caller still needs the key. Either alone is one mistake away from arbitrary code execution inside the VNet, which is exactly what this endpoint does by design.

`HELIOGRAPH_ALLOW_ACTIONS` is off by default and refuses a script declaring `action`, or an environment carrying `APPLY`, `CONFIRM`, `DESTROY`, `FORCE` or `WRITE`. **It guards against the mistake, not against a hostile caller** - a probe pasted with the wrong header, an action step sent to the wrong agent. Do not read it as a security boundary.

## Using it

```bash
export INTERCOM_URL=https://func-heliograph-eun-dev-01.azurewebsites.net
export INTERCOM_KEY=$(az functionapp keys list -g <rg> -n <app> --query functionKeys.default -o tsv)

${CLAUDE_SKILL_DIR}/toolkit/intercom.sh run steps/net-probe.sh HOSTS="sql.example db.example" PORTS=1433
```

It prints the log, keeps a copy under `ops-logs/`, and **exits with the step's own exit code**, so it composes in a script the way `run.sh` does. A step that fails is still a result: the log comes back either way.

| command | does |
|---|---|
| `run <script> [KEY=VAL ...]` | submit, wait, print the log. Follows a 202 automatically |
| `poll <taskId>` | one look: status, exit code, size |
| `watch <taskId>` | poll until it settles, then print the log |
| `logs <taskId>` | just the log, paged, to stdout |

`INTERCOM_WAIT` (default 25) is how long `run` stays on the line before falling back to polling. `INTERCOM_DETACH=1` makes it print the task id and return instead. `INTERCOM_POLL` (default 2) is the polling interval.

## The contract

### `POST /api/run`

```json
{
  "name":   "dns-check",
  "script": "#!/usr/bin/env bash\n# heliograph-mode: read-only\ndig +short sql.example\n",
  "env":    {"HOSTS": "a b"},
  "wait":   25
}
```

| field | required | rule |
|---|---|---|
| `name` | yes | `^[a-z0-9][a-z0-9._-]{0,63}$` - it becomes a filename, so this is a path-traversal control rather than a tidiness one |
| `script` | yes | 1 byte to 256 KB |
| `env` | no | keys `^[A-Z_][A-Z0-9_]*$`, values strings |
| `wait` | no | seconds, default 25, **clamped** to 0-200 |

`wait` is clamped rather than refused because the Azure front end kills an HTTP request at 230 seconds whatever `functionTimeout` says. A caller asking for 600 would get a dropped connection and no task id, which is the one outcome that loses a running step; clamping gives them a task id instead.

```jsonc
// 200 - finished inside `wait`
{"taskId": "7f3a…", "name": "dns-check", "status": "done", "exit": 0,
 "log": "…", "offset": 0, "nextOffset": 4211, "logBytes": 4211}

// 202 - still running
{"taskId": "7f3a…", "name": "dns-check", "status": "running", "poll": "/api/task/7f3a…"}
```

### `GET /api/task/{taskId}?offset=N`

The same record. `status` is one of `queued`, `running`, `done`, `refused`, `failed`.

**A step that exits non-zero is `done`, not `failed`.** It produced a log, and the log is the deliverable. `failed` means the agent could not run the step at all, which needs a different reaction. `refused` means the action gate stopped it before it ran.

**Never truncate**, so a large log is paged rather than cut: `offset` returns bytes from that position and `nextOffset` says where to ask next. When `nextOffset` reaches `logBytes` the caller has all of it. A log that came back short would be a log missing exactly the part worth reading, with no way for the reader to tell.

The submitted script is not echoed back. The caller sent it and already has it.

## How it works

```
POST /api/run ──▶ write tasks/<id>.json ──▶ enqueue id ──▶ poll blob up to `wait`s
                                              │                     │
                                     queue trigger:                 ├─ settled  ─▶ 200 + log
                                     run.sh <script>                └─ not yet  ─▶ 202 + taskId
                                     write logs/<id>.txt                              │
                                     write tasks/<id>.json             GET /api/task/<id> ◀┘
```

**The POST executes nothing.** Work must not outlive the invocation that started it: Flex Consumption may freeze or recycle an instance the moment a response is sent, and a background thread would take the task with it, leaving no record it ever existed. So the HTTP call records the task and *waits on the result blob*, while a queue-triggered function does the work in its own invocation with its own timeout budget.

That is why "synchronous by default, asynchronous for long steps" is one code path rather than two. `wait` decides only whether the caller stays on the line.

The queue trigger writes the script to `/tmp/heliograph/<taskId>/<name>.sh`, `chmod 0700`, and runs `run.sh` against that path with `LOG_DIR` set and `PUSH=0`. Timestamping, ANSI stripping and redaction are `caplib.sh`'s, unchanged - there is no second capture implementation here.

`run.sh` grew one arm for this: **a `$STEP` that names an existing file is that file**. A name in the step table always wins, so nothing can be shadowed, and the mode gate is untouched. It is useful anywhere, not only here - `./run.sh ./probe.sh` now works on any host.

## Configuration

On the Function App:

| setting | for |
|---|---|
| `HELIOGRAPH_ACCOUNT` | the storage account holding tasks and logs. **Unset leaves intercom off** |
| `HELIOGRAPH_QUEUE` | the queue name. The binding is `%HELIOGRAPH_QUEUE%`, so **the app will not index without it** - the timer trigger goes down with it |
| `HELIOGRAPH_PREFIX` | container and queue prefix, for a drop sharing an account |
| `HELIOGRAPH_ALLOW_ACTIONS` | `1` permits a step that changes state. Default `0` |
| `AzureWebJobsStorage__accountName` | identity-based host storage, and the queue trigger's connection |

The identity needs **Storage Blob Data Contributor** and **Storage Queue Data Contributor** on the account. Without the queue role the app indexes, the routes answer, and nothing ever runs - which looks like a hung step rather than a missing grant.

## Limits

- **No cancel.** The pigeonhole has one; intercom will not until something wants it.
- **No streaming while a step runs.** `offset` pages a settled log; the log blob is written once at the end, so a running step shows `status: running` and nothing else. Watching a slow probe live is a separate change.
- **One instance.** `maximum_instance_count = 1` is a correctness bound: a heliograph log's value is that it says what *one* machine saw.
