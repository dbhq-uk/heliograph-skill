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
| `run <script> [KEY=VAL ...]` | submit, run, print the log. Follows a 202 automatically in queue mode |
| `poll <taskId>` | one look: status, exit code, size |
| `watch <taskId>` | poll until it settles, then print the log |
| `logs <taskId>` | just the log, paged, to stdout |

`INTERCOM_WAIT` (default 25) is how long the step is given before it is killed, and how long `run` stays on the line. `INTERCOM_DETACH=1` makes it print the task id and return instead. `INTERCOM_POLL` (default 2) is the polling interval.

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
// 200 - the normal answer: it ran, here is the log
{"taskId": "7f3a", "name": "dns-check", "status": "done", "exit": 0,
 "log": "...", "offset": 0, "nextOffset": 4211, "logBytes": 4211}

// 200 - it outran `wait` and was killed. The partial log is still here
{"taskId": "7f3a", "name": "dns-check", "status": "timeout", "exit": null, "log": "..."}

// 202 - QUEUE MODE ONLY: still running, poll for it
{"taskId": "7f3a", "name": "dns-check", "status": "running", "poll": "/api/task/7f3a"}
```

### `GET /api/task/{taskId}?offset=N`

The same record. `status` is one of `queued`, `running`, `done`, `refused`, `failed`, `timeout`.

**A step that exits non-zero is `done`, not `failed`.** It produced a log, and the log is the deliverable. `failed` means the agent could not run the step at all, which needs a different reaction. `refused` means the action gate stopped it before it ran, and `timeout` that it was killed at `wait` with a partial log.

**Never truncate**, so a large log is paged rather than cut: `offset` returns bytes from that position and `nextOffset` says where to ask next. When `nextOffset` reaches `logBytes` the caller has all of it. A log that came back short would be a log missing exactly the part worth reading, with no way for the reader to tell.

The submitted script is not echoed back. The caller sent it and already has it.

## How it works

```
POST /api/run ──▶ write tasks/<id>.json ──▶ run.sh <script>, bounded by `wait`
                                                   │
                                                   ├─ finished ─▶ 200 + log
                                                   └─ overran  ─▶ 200 + partial log,
                                                                  status: timeout
```

**Work never outlives the invocation that started it.** Flex Consumption may freeze or recycle an instance the moment a response is sent, so a thread left running past the response is not guaranteed to finish and the task would vanish with no record it ever existed.

Work *during* a request is a different thing and is safe: the request holds the instance alive for its own duration. So **by default the step runs inline in `POST /api/run`**, bounded by `wait`, and the log comes back in the same response.

A step that outruns `wait` is killed and its **partial log returned** with `status: timeout`. caplib writes the capture to a file as the step produces it, so that log is real evidence of how far it got - which is what tells a step that overran apart from one that hung producing nothing.

### The queue path, which is optional and off

`HELIOGRAPH_QUEUE_MODE=1` restores the original design: POST enqueues and polls the result blob, a queue-triggered function does the work in its own invocation, and a step that outlives the request returns `202` with a task id to poll. It is better **where it works**, because a step can then outlast the 230 seconds the Azure front end allows a request.

It did not work on the estate this was built for, and **the cause is now known** - the first account of it here was wrong, and said telemetry was unavailable. It was not. There are two faults, and only the second is fatal.

**One: the queue trigger would not index.** `AzureWebJobsStorage__accountName` is enough for blob, so the key store works and the HTTP routes work, but the queue extension cannot build its client from it:

```
The 'worker' function is in error: Error indexing method 'Functions.worker'.
Microsoft.Extensions.Azure: Unable to find matching constructor while trying
to create an instance of QueueServiceClient
```

Fixed by naming the endpoint: `AzureWebJobsStorage__queueServiceUri`. Add `__blobServiceUri` beside it. Do **not** add a table URI unless a table private endpoint exists, or you build in a hang.

**Two, and this one has no fix in the app: `SyncTriggers` cannot complete without egress.**

```
SyncTriggers operation failed.
The request was canceled due to the configured HttpClient.Timeout of 100 seconds elapsing.
```

SyncTriggers is how the platform tells the **scale controller** which triggers a Flex Consumption app has. It is an outbound call. In a subnet whose default route goes to a firewall with no policy for it, it times out - so the scale controller never learns there is a queue trigger, and nothing ever polls the queue. Messages accumulate while the host reports `Running`, the worker shows as registered, and every HTTP call succeeds.

HTTP triggers are unaffected because the front end routes straight to an always-ready instance without consulting the scale controller. That asymmetry is the whole reason inline works where the queue does not.

So on an estate with no egress, use the default. Queue mode needs a firewall policy for the platform's own control plane, not just for your dependencies.

Either way the script is written to `/tmp/heliograph/<taskId>/<name>.sh`, `chmod 0700`, and `run.sh` is called against that path with `LOG_DIR` set and `PUSH=0`. Timestamping, ANSI stripping and redaction are `caplib.sh`'s, unchanged - there is no second capture implementation here.

`run.sh` grew one arm for this: **a `$STEP` that names an existing file is that file**. A name in the step table always wins, so nothing can be shadowed, and the mode gate is untouched. It is useful anywhere, not only here - `./run.sh ./probe.sh` now works on any host.

## Configuration

On the Function App:

| setting | for |
|---|---|
| `HELIOGRAPH_ACCOUNT` | the storage account holding tasks and logs. **Unset leaves intercom off** |
| `HELIOGRAPH_QUEUE` | the queue name. The binding is `%HELIOGRAPH_QUEUE%`, so **the app will not index without it** - the timer trigger goes down with it |
| `HELIOGRAPH_PREFIX` | container and queue prefix, for a drop sharing an account |
| `HELIOGRAPH_ALLOW_ACTIONS` | `1` permits a step that changes state. Default `0` |
| `HELIOGRAPH_QUEUE_MODE` | `1` runs steps in a queue invocation instead of inline. Default `0` |
| `AzureWebJobsStorage__accountName` | identity-based host storage, and the queue trigger's connection |

The identity needs **Storage Blob Data Contributor** and **Storage Queue Data Contributor** on the account. Without the queue role the app indexes, the routes answer, and nothing ever runs - which looks like a hung step rather than a missing grant.

The container and queue are created on first use if they are absent, so terraform does not have to own them. That needs the two roles above, which is another way the missing grant shows up late.

## Deploying

```bash
${CLAUDE_SKILL_DIR}/toolkit/azure/function/build.sh /tmp/heliograph-function.zip
az functionapp deployment source config-zip -g <rg> -n <app> --src /tmp/heliograph-function.zip
```

`build.sh` flattens the toolkit into the package root, so `function_app.py`, `run.sh` and `caplib.sh` end up beside each other, and vendors the dependencies into `.python_packages/lib/site-packages`. **Dependencies are vendored rather than built remotely** because a remote build needs the platform to reach a package index, and this host exists for estates where outbound is the thing that does not work.

## Limits

- **A step is bounded by `wait`, and `wait` is bounded by 200 seconds.** Inline execution cannot outlast the request. A longer step needs `HELIOGRAPH_QUEUE_MODE=1` and a working queue listener.
- **No cancel.** The pigeonhole has one; intercom will not until something wants it.
- **No streaming while a step runs.** `offset` pages a settled log; the log blob is written once at the end. Watching a slow probe live is a separate change.
- **One instance.** `maximum_instance_count = 1` is a correctness bound: a heliograph log's value is that it says what *one* machine saw.

## Four traps this cost an afternoon to find

Every one of these presents as something other than what it is.

**`az functionapp deployment source config-zip` triggers a remote Oryx build**, which fetches the Python SDK list from an external endpoint. With no egress that returns nothing and the deploy dies inside Oryx's XML parser - `Value cannot be null. (Parameter 'node')`, which reads like a corrupt package. Deploy through OneDeploy with the build off instead, which is what the `Deploying` section above does. The dependencies are already vendored; there is nothing to build.

**The azurerm provider writes an `AzureWebJobsStorage` connection string with an EMPTY `AccountKey`** whenever the app is updated, even with `storage_authentication_type = "SystemAssignedIdentity"`. It cannot read a key, because the account has shared keys disabled - so it writes the string anyway with nothing in that field. The host then prefers it over `AzureWebJobsStorage__accountName`, fails to authenticate, and cannot reach its key store. Every call answers 401, and `listkeys` returns `Encountered an error (InternalServerError) from host runtime` - which reads like a broken runtime.

The fix is to declare the key empty so terraform owns it and overwrites the provider on every apply:

```hcl
app_settings = {
  AzureWebJobsStorage              = ""
  AzureWebJobsStorage__accountName = "<account>"
}
```

The host tolerates the empty value and falls back to `__accountName`. **It costs a permanent one-line diff**, because Azure drops an empty setting rather than storing it, so terraform reads it back as absent and proposes it again on every plan.

`ignore_changes` on that key removes the diff and **was measured to break it**: with the key ignored, a genuine app update - changing a tag was enough - had the provider write the broken string straight back. The declaration only works while it is live, so the noise is the price. Every plan says "1 to change" and shows that one key; anything else in a plan is real.

**A storage private endpoint is per sub-resource.** A `blob` endpoint does nothing for `queue`. In queue mode the symptom is a POST that never returns at all while the task blob sits at `status: queued`: the blob write succeeded and the enqueue is hanging on a public address routed to a firewall. Indistinguishable from a busy worker.

**Flex Consumption scales to zero, and this package carries the Azure SDKs.** A cold start outruns the front end, which answers `The service is unavailable.` **in plain text, not JSON**. Set one always-ready instance. `intercom.sh` now refuses a non-JSON body rather than writing that sentence into `ops-logs/` as though it were a capture.

**Telemetry is probably available, and assuming otherwise cost real time.** An earlier version of this page said Application Insights ingestion needs egress and was therefore unusable here. That was wrong. Where the estate has an Azure Monitor Private Link Scope the ingestion endpoint resolves to a **private** address and answers in milliseconds - measured at `10.100.3.26`, 21ms, in the same subnet where every public endpoint times out. The apparent failure was the broken `AzureWebJobsStorage` above, diagnosed while telemetry was wired and blamed on telemetry.

**Wire it before diagnosing anything else.** Both queue faults above were invisible at the API, invisible in `/admin/host/status`, and named exactly once each in `traces`. Set `APPLICATIONINSIGHTS_CONNECTION_STRING` and query:

```kusto
union traces, exceptions
| where timestamp > ago(30m)
| where message has_any ('indexing','SyncTriggers','QueueServiceClient')
```
