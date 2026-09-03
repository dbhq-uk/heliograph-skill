# =============================================================================
#  function_app.py - the heliograph agent as an Azure Function
# =============================================================================
#  A timer fires, the agent answers at most one request, and the invocation
#  ends. That is the whole design, and it is a better fit than it first looks:
#  the Azure DevOps pipeline runner already works this way, one job per
#  request, and nobody has missed the loop.
#
#  WHY A HOST WITH NO LOOP IS WORTH HAVING. Every other runner is a process
#  that stays up. That needs somewhere to keep a process, which is exactly what
#  a locked-down estate is reluctant to give you - and on the estate this was
#  written for, three container hosts were refused before this one worked. A
#  Function App needs no VM quota, no inbound path and no long-lived compute.
#
#  IT SHELLS OUT TO THE BASH TOOLKIT RATHER THAN REIMPLEMENTING IT. The image
#  is Debian bookworm with bash 5.2 and GNU sed 4.9, which is what caplib.sh
#  needs - `sed -u` is honoured, so a captured line is stamped when it is
#  produced rather than when the buffer flushes. A Python reimplementation
#  would be a second copy of the timestamping, ANSI stripping and redaction,
#  and there would be no answer to which copy is authoritative.
#
#  There is no git in the image, so the transport is the pigeonhole. That is
#  not a limitation here: blob storage behind a private endpoint needs no
#  egress at all, which is the reason this host can work where the others
#  could not.
#
#  THIS HOST CARRIES BOTH TRANSPORTS, and which one to use is a property of the
#  estate rather than a preference:
#
#    the timer + pigeonhole   when nothing can reach the agent. Still the
#                             common case, and still why this host exists.
#    the intercom HTTP pair   when the agent's endpoint IS reachable, which a
#                             Function App's is. The operator then needs no
#                             storage credentials and waits no timer interval.
#
#  They share run.sh and caplib.sh and disagree about nothing. Deploying with
#  HELIOGRAPH_SCHEDULE set to a date that never comes leaves intercom alone;
#  leaving HELIOGRAPH_ACCOUNT unset leaves the pigeonhole alone.
# =============================================================================
import asyncio
import json
import logging
import os
import pathlib
import subprocess
import time
import traceback

import azure.functions as func

import intercom

app = func.FunctionApp()

# The toolkit ships beside this file in the deployment package, and two levels
# up in the repository. intercom.py finds it by looking for run.sh and caplib.sh
# rather than by counting directories, and there is no reason for a second copy
# of that here - see the note there for what the counted version got wrong.
TOOLKIT = intercom.TOOLKIT


@app.timer_trigger(
    schedule=os.environ.get("HELIOGRAPH_SCHEDULE", "0 */5 * * * *"),
    arg_name="timer",
    # FALSE, AND DELIBERATELY. run_on_startup makes a Function run on every
    # host restart, which the platform does for its own reasons at times
    # nobody chose. A runner that answers a request because Azure recycled an
    # instance is exactly the unattended rerun the startup rule exists to
    # prevent.
    run_on_startup=False,
)
def agent(timer: func.TimerRequest) -> None:
    """Answer at most one request, then return."""
    if timer.past_due:
        # Worth saying rather than swallowing: a late timer on a runner that
        # answers one request per tick means requests waited longer than the
        # schedule implies.
        logging.warning("heliograph: timer is past due")

    env = dict(os.environ)

    # THE TWO SETTINGS THAT MAKE A LOOP BEHAVE LIKE AN INVOCATION, and neither
    # is optional.
    #
    # RESUME, because this process has no memory. Without it the agent absorbs
    # whatever id is in the drop at startup - correct for a long-running loop,
    # where a restart is ambiguous - and would therefore answer nothing, ever.
    # The failure is silent: requests simply go unanswered.
    #
    # ONCE, because the loop must end for the invocation to end. Without it the
    # agent polls until the host kills it at the function timeout, and the log
    # of a step that was still running is lost with it.
    env["PIGEONHOLE_RESUME"] = "1"
    env["PIGEONHOLE_ONCE"] = "1"

    # IDENTITY BY DEFAULT ON THIS HOST, because a SAS may not be mintable at
    # all: an estate can set allowSharedKeyAccess = false on the account, and
    # then there is no key to sign one with. A Function is handed
    # IDENTITY_ENDPOINT, a LOCAL token endpoint needing no egress - which is
    # the thing a VNet-injected container group does not have, and the reason
    # the SAS path exists for that host and not this one.
    #
    # Overridable: an estate that does allow shared keys can set
    # PIGEONHOLE_AUTH=sas and pass PIGEONHOLE_SAS instead.
    if "IDENTITY_ENDPOINT" in env:
        env.setdefault("PIGEONHOLE_AUTH", "identity")

    # One poll. The timer is the schedule; a second poll inside one invocation
    # would only burn wall-clock the platform is already billing for.
    env.setdefault("PIGEONHOLE_POLL", "1")

    logging.info("heliograph: polling lane %s", env.get("PIGEONHOLE_LANE", "default"))

    # check=False on purpose. A step that fails is a result, not an error: the
    # log has been captured and delivered, and raising here would mark the
    # invocation failed and bury a successful capture under a stack trace.
    result = subprocess.run(
        ["bash", str(TOOLKIT / "pigeonhole.sh")],
        cwd=str(TOOLKIT),
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )

    # The agent's own console, not the step's - the step's output is in the
    # captured log, which went to the drop. This is how a failure to reach the
    # drop at all becomes visible, since by definition it cannot report itself.
    for line in result.stdout.splitlines():
        logging.info("heliograph: %s", line)
    for line in result.stderr.splitlines():
        logging.warning("heliograph: %s", line)

    if result.returncode != 0:
        logging.error("heliograph: agent exited %s", result.returncode)


# =============================================================================
#  intercom - the HTTP pair
# =============================================================================
#  Both routes are auth_level=FUNCTION, so a caller needs the function key. That
#  is ONE control and it is not enough on its own: this endpoint runs
#  caller-supplied shell inside the VNet, which is what makes it useful and also
#  what makes a leaked key arbitrary code execution. The second control is the
#  ip_restriction in terraform, and the two are meant to be deployed together.
#
#  The mode header is NOT a third control. When the caller writes the script the
#  caller writes its `heliograph-mode:` line too, so it is a claim about itself.
#  run.sh has always said as much: nothing in a shell runner can stop an author
#  declaring read-only and then writing `rm -rf`. HELIOGRAPH_ALLOW_ACTIONS
#  guards against the MISTAKE - a step pasted with the wrong header - and the
#  reference says so in those words rather than dressing it up as security.
# =============================================================================

# Built once per worker and reused. Lazily, because a missing HELIOGRAPH_ACCOUNT
# must not take the timer trigger down with it: a pigeonhole-only deployment
# configures no account at all, and an import-time failure here would stop the
# whole app indexing rather than only the routes that need a store.
_STORE = None


def _store():
    global _STORE
    if _STORE is None:
        import store

        _STORE = store.BlobStore()
        _STORE.ensure()
    return _STORE


def _json(body: dict, status: int) -> func.HttpResponse:
    return func.HttpResponse(
        json.dumps(body), status_code=status, mimetype="application/json"
    )


# AN UNHANDLED EXCEPTION HERE IS A 500 WITH AN EMPTY BODY, and across a gap that
# is the worst answer there is: it says something went wrong on a machine you
# cannot log into, and nothing else. This whole skill exists because that
# situation wastes days.
#
# Telemetry is not the answer on this host either. Application Insights ingestion
# needs egress, and the estates that need a Function agent are exactly the ones
# with none - wiring it here produced no traces at all, and worse, the SDK hung
# on an endpoint it could not reach until every request timed out.
#
# So the endpoint reports its own failures. The caller already holds a function
# key and is inside the IP allowlist, and already submits arbitrary shell, so a
# traceback tells them nothing they could not have learned by asking for it.
def _failed(exc: BaseException) -> func.HttpResponse:
    logging.exception("intercom: unhandled")
    return _json(
        {
            "error": f"{type(exc).__name__}: {exc}",
            "traceback": traceback.format_exc(),
        },
        500,
    )


@app.route(route="run", methods=["POST"], auth_level=func.AuthLevel.FUNCTION)
async def run(req: func.HttpRequest) -> func.HttpResponse:
    """Submit a step. Answers with the log, or with a task id to poll."""
    try:
        body = req.get_json()
    except ValueError:
        return _json({"error": "body must be JSON"}, 400)

    queue_mode = os.environ.get("HELIOGRAPH_QUEUE_MODE", "0") == "1"

    try:
        task = await asyncio.to_thread(
            intercom.submit, _store(), body, enqueue=queue_mode
        )
    except intercom.Refused as refused:
        return _json({"error": str(refused)}, 400)
    except Exception as exc:  # noqa: BLE001 - reported, see _failed
        return _failed(exc)

    logging.info("intercom: accepted %s (%s)", task["taskId"], task["name"])

    # INLINE BY DEFAULT. The step runs here, in this invocation, bounded by
    # `wait` - which is safe precisely because the request is still open, and is
    # the opposite of leaving a thread running after the response. See
    # intercom.py for why the queue path is no longer the default.
    if not queue_mode:
        try:
            settled = await asyncio.to_thread(
                intercom.execute, _store(), task["taskId"], timeout=task["wait"] or None
            )
            return _json(intercom.fetch(_store(), settled["taskId"], 0), 200)
        except Exception as exc:  # noqa: BLE001 - reported, see _failed
            return _failed(exc)

    # THE WAIT IS HERE AND THE WORK IS NOT. This polls the result blob; the
    # queue trigger below does the running. See intercom.py for why that
    # separation is not optional on Flex Consumption.
    #
    # asyncio.sleep rather than a sync sleep, and to_thread for the SDK calls,
    # so a 200-second wait holds no worker thread. A blocking wait here could
    # starve the queue trigger of the very thread it needs to answer it, and
    # that deadlock would present as "every request times out" with nothing in
    # the logs to say why.
    deadline = time.monotonic() + task["wait"]
    try:
        return await _wait_for(task, deadline)
    except Exception as exc:  # noqa: BLE001 - reported, see _failed
        return _failed(exc)


async def _wait_for(task: dict, deadline: float) -> func.HttpResponse:
    while True:
        settled = await asyncio.to_thread(_store().get_task, task["taskId"])
        if settled and settled["status"] in ("done", "refused", "failed"):
            done = await asyncio.to_thread(intercom.fetch, _store(), task["taskId"], 0)
            return _json(done, 200)
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return _json(
                {
                    "taskId": task["taskId"],
                    "name": task["name"],
                    "status": settled["status"] if settled else "queued",
                    "poll": f"/api/task/{task['taskId']}",
                },
                202,
            )
        await asyncio.sleep(min(0.5, remaining))


@app.route(route="task/{taskId}", methods=["GET"], auth_level=func.AuthLevel.FUNCTION)
async def task(req: func.HttpRequest) -> func.HttpResponse:
    """Poll a task. `offset` pages a large log rather than truncating it."""
    task_id = req.route_params.get("taskId")
    try:
        offset = int(req.params.get("offset", "0"))
    except ValueError:
        return _json({"error": "offset must be an integer"}, 400)
    if offset < 0:
        return _json({"error": "offset must not be negative"}, 400)

    try:
        found = await asyncio.to_thread(intercom.fetch, _store(), task_id, offset)
    except Exception as exc:  # noqa: BLE001 - reported, see _failed
        return _failed(exc)
    if found is None:
        return _json({"error": f"no such task: {task_id}"}, 404)
    return _json(found, 200)


# The queue name is a binding expression, so it comes from HELIOGRAPH_QUEUE and
# the app WILL NOT INDEX without it - every function in this file, the timer
# included, goes with it. Terraform always sets it; a hand-built deployment must
# too. The connection is AzureWebJobsStorage, which is already identity-based
# via AzureWebJobsStorage__accountName, so no second credential is configured.
@app.queue_trigger(
    arg_name="msg", queue_name="%HELIOGRAPH_QUEUE%", connection="AzureWebJobsStorage"
)
def worker(msg: func.QueueMessage) -> None:
    """Run one submitted step. Its own invocation, its own timeout budget."""
    task_id = msg.get_body().decode().strip()
    logging.info("intercom: running %s", task_id)

    # No try/except around this. A step that fails is a result and execute()
    # records it as one; an exception here means the AGENT failed, and letting
    # the queue retry it is the right answer to that.
    settled = intercom.execute(_store(), task_id)
    logging.info(
        "intercom: %s finished status=%s exit=%s bytes=%s",
        task_id,
        settled.get("status"),
        settled.get("exit"),
        settled.get("logBytes"),
    )
