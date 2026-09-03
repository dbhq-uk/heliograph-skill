# intercom - design

**Date:** 2026-09-03
**Status:** approved, ready to implement

A sixth transport: the control node calls the agent over HTTP, submits a step, and polls for its log.

## Why

heliograph has five hosts and two transports. Both transports assume the agent reaches *out* - git pushes a log to a remote, the pigeonhole writes a blob. That assumption is what the whole skill is built around, because in a locked-down estate the agent usually cannot be reached *in*.

The Azure Function host breaks the assumption in the useful direction. It has a public HTTPS endpoint that the control node can reach, and it sits inside the VNet. When that is true, routing a request through blob storage is indirection with no purpose: the operator has to hold storage credentials, the request waits a timer interval, and every round trip costs two blob writes and two reads to move text between two machines that can already talk.

So when the agent is reachable, talk to it.

The pigeonhole is not replaced. It remains the only thing that works where there is no inbound path, which is still the common case and still the reason the Function host exists. `intercom` is additive.

## What it is

Two endpoints on the Function App.

```
POST /api/run              submit a step, get its log or a task id
GET  /api/task/{taskId}    poll a task
```

The caller supplies the script itself. That is the point: heliograph's loop is *write a probe, run it, read the log, write the next probe*, and there is no git in the Function image, so a step that arrives only by redeployment turns a thirty-second loop into a five-minute one.

## The three decisions, and what they cost

### 1. The caller supplies the script, so the mode header stops being a control

`run.sh` gates on a `# heliograph-mode: read-only|action` header read from the file it is about to execute. When the file ships with the code, that header is evidence. When the caller writes the file, the caller writes the header, and it is a claim about itself.

This breaks no promise. [run.sh:176-179](../../../skills/heliograph/toolkit/run.sh) already says so in as many words: the gate *"does NOT stop an author declaring read-only and then writing `rm -rf`. Nothing in a shell runner can."*

What follows from it is that **the only real control on this endpoint is who can reach it**. The design says that plainly rather than dressing the mode header up as security.

`HELIOGRAPH_ALLOW_ACTIONS` is kept as an app setting, default off, refusing a script that declares `action` before it runs. It guards against a mistake - a probe pasted with the wrong header, an action step submitted to the wrong lane. It does not guard against a caller who wants to do harm, and the reference will not imply that it does.

### 2. Two controls on the endpoint, neither sufficient alone

- **Function key.** `auth_level=FUNCTION` on both routes; the caller sends `x-functions-key`.
- **IP allowlist.** `site_config.ip_restriction` in terraform, so the endpoint answers only known addresses.

A leaked key is useless off-network. An on-network caller still needs the key. Either alone is one mistake away from arbitrary code execution inside the VNet, which is what this endpoint does by design.

### 3. Work runs in a queue invocation, never in the HTTP one

Work must not outlive the invocation that started it. A thread that survives the HTTP response is not guaranteed to run: Flex Consumption may freeze or recycle the instance as soon as the response is sent, and the task disappears with no record that it ever existed. A debugging tool that silently loses runs is worse than one that refuses them.

So `POST` never executes anything. It writes a task record, enqueues the id, and then **waits on the result blob** for up to `wait` seconds. A queue-triggered function does the work in its own invocation, with its own timeout budget, and writes the log back.

This is why "synchronous by default, asynchronous for long steps" is one code path rather than two. `wait` decides only whether the POST stays on the line for the answer.

```
POST /api/run ──▶ write tasks/<id>.json  ──▶ enqueue id ──▶ poll blob up to `wait`s
                                                │                    │
                                       queue trigger:                ├─ finished  ─▶ 200 + log
                                       run.sh <script>               └─ not yet   ─▶ 202 + taskId
                                       write logs/<id>.txt                              │
                                       write tasks/<id>.json done      GET /api/task/<id> ◀┘
```

Storage is invisible to the operator throughout. No SAS, no `az storage`, no identity token. That is the pigeonhole's actual cost, and this removes it while keeping the durability that made the pigeonhole trustworthy.

## Contract

### `POST /api/run`

```json
{
  "name":   "dns-check",
  "script": "#!/usr/bin/env bash\n# heliograph-mode: read-only\ndig +short sql.privatelink...",
  "env":    {"HOSTS": "a b"},
  "wait":   25
}
```

| field | required | rule |
|---|---|---|
| `name` | yes | `^[a-z0-9][a-z0-9._-]{0,63}$` - it becomes a filename |
| `script` | yes | 1 byte to 256 KB |
| `env` | no | keys `^[A-Z_][A-Z0-9_]*$`, values are strings |
| `wait` | no | seconds, default 25, clamped to 0-200 |

`wait` is clamped at 200 because the Azure front end kills an HTTP request at 230 seconds regardless of `functionTimeout`. A caller asking for 600 gets 200 and a task id, not a dropped connection.

Responses:

```jsonc
// 200 - finished inside `wait`
{"taskId": "7f3a…", "status": "done", "exit": 0, "log": "…", "started": "…", "finished": "…"}

// 202 - still running
{"taskId": "7f3a…", "status": "running", "poll": "/api/task/7f3a…"}
```

### `GET /api/task/{taskId}?offset=N`

Same record. `status` is one of `queued`, `running`, `done`, `refused`, `failed`.

**Never truncate** is a heliograph rule, so a large log is paged rather than cut: `offset` returns bytes from that position with `nextOffset` alongside. A caller that omits `offset` gets the whole log. A 40 MB capture comes back in pieces; it never comes back shortened with the interesting part missing.

## Components

| unit | does | depends on |
|---|---|---|
| `toolkit/run.sh` | gains a path arm: a `$STEP` that names an existing file *is* the step | nothing new |
| `azure/function/intercom.py` | validate, enqueue, poll, execute, store | blob + queue clients |
| `azure/function/function_app.py` | three triggers: two HTTP routes, one queue | `intercom.py` |
| `toolkit/intercom.sh` | operator client - `run`, `poll`, `watch` | curl |
| `infra` (devtools) | queue, container, ip_restriction, app settings | - |

### The `run.sh` change

`run.sh` dispatches on a closed table - `env|net|win|tools`, everything else is `unknown step`. It cannot run a file, and a Flex Consumption package is mounted read-only so one cannot be dropped into `steps/` either.

The arm is small: if `$STEP` names an existing readable file, that file is the step. The mode gate is unchanged and still reads the header from the file about to run. Every host gains it, not just the Function - naming a step by path is useful anywhere.

The queue trigger writes the caller's script to `/tmp/heliograph/<taskId>/<name>.sh` and calls `run.sh` with that path, `LOG_DIR` pointing at the same directory and `PUSH=0`. The capture, timestamping, ANSI stripping and redaction are `caplib.sh`'s, unchanged and unduplicated.

## Storage

One container and one queue, both reachable over the existing private endpoint using the Function's managed identity.

```
queue:  <prefix>tasks
blobs:  <prefix>tasks/tasks/<taskId>.json     the record
        <prefix>tasks/logs/<taskId>.txt       the capture, verbatim
```

`<prefix>` is `PIGEONHOLE_PREFIX`, so an intercom drop can share an account with a pigeonhole drop.

## Error handling

| case | result |
|---|---|
| bad `name`, oversized `script`, malformed `env` | `400`, nothing enqueued |
| script declares `action`, `HELIOGRAPH_ALLOW_ACTIONS` off | task recorded `refused` with the reason; `200` |
| script declares no mode or an unknown one | `run.sh` refuses; task `refused`, its stderr is the log |
| step exits non-zero | `status: done`, `exit: <code>` - **a failing step is a result, not an error** |
| queue trigger crashes | task stays `running`; the queue's own retry re-runs it |
| unknown `taskId` | `404` |

The fourth row is the one that matters and it is the same rule the timer host already follows: a step that fails has produced a log, and the log is the deliverable.

## Testing

- `tests/test-intercom.sh` - the operator client against a fake `curl`, in the style of `test-pigeonhole.sh`.
- `tests/test_intercom.py` - validation, clamping, refusal, paging and the queue handler, against in-memory fakes for the blob and queue clients. No Azure needed.
- `run.sh --list` and the mode gate keep their existing coverage; the path arm adds cases for a file that exists, one that does not, and one with no mode header.
- The six repository validate gates run locally before every push.

End to end, on the deployed Function: submit `tools-inventory`, get a log back, and confirm the same task id reads identically from `GET`.

## Out of scope

- Streaming a log while the step runs. `offset` paging already lets a caller tail a finished-or-running blob; incremental *writes* during a run are a separate change and not needed to make this useful.
- Cancelling a running task. The pigeonhole has `cancel:`; intercom will not until something wants it.
- Removing the pigeonhole from the Function host. It stays, and here it deploys with its timer schedule off.
