# =============================================================================
#  intercom.py - submit a step over HTTP, poll for its log
# =============================================================================
#  The pigeonhole exists because the agent usually cannot be reached. When it
#  CAN be - a Function App has a public HTTPS endpoint and sits inside the VNet
#  - routing a request through blob storage is indirection with no purpose: the
#  operator has to hold storage credentials, the request waits a timer interval,
#  and moving text between two machines that can already talk costs two blob
#  writes and two reads.
#
#  So this module is the other half of that: the caller submits the script, and
#  storage becomes task STATE rather than the transport. The operator never sees
#  it.
#
#  WHY THE WORK RUNS IN A QUEUE INVOCATION AND NEVER IN THE HTTP ONE. Work must
#  not outlive the invocation that started it. A thread that survives the HTTP
#  response is not guaranteed to run: Flex Consumption may freeze or recycle the
#  instance the moment the response is sent, and the task vanishes with no
#  record it ever existed. A debugging tool that silently loses runs is worse
#  than one that refuses them.
#
#  So POST executes nothing. It records the task, enqueues the id, and then
#  waits on the result blob for up to `wait` seconds. That is why "synchronous
#  by default, asynchronous for long steps" is ONE code path: `wait` decides
#  only whether the caller stays on the line, not where the work happens.
#
#  IT SHELLS OUT TO run.sh RATHER THAN REIMPLEMENTING THE CAPTURE, for the same
#  reason the timer host does: caplib.sh owns timestamping, ANSI stripping and
#  redaction, and a second copy in Python would raise the question of which one
#  is authoritative. run.sh also owns the mode gate, which is why the action
#  check below asks `run.sh --mode` instead of parsing the header itself.
# =============================================================================
from __future__ import annotations

import glob
import json
import os
import pathlib
import re
import subprocess
import time
import uuid

# THE TOOLKIT LIVES IN TWO SHAPES and this has to find it in both.
#
# In the deployment package it is flattened beside this file, so `.parent` is
# right. In the repository this file is at toolkit/azure/function/, two levels
# below run.sh, so `.parent` is a directory with no run.sh in it - and the
# failure is not a clean ImportError but a captured log reading
# "bash: .../azure/function/run.sh: No such file or directory", which looks like
# a broken step rather than a broken path.
#
# So it searches for the marker files instead of counting directories. Costs two
# stat calls at import and cannot be wrong in either layout.
def _find_toolkit() -> pathlib.Path:
    here = pathlib.Path(__file__).resolve().parent
    for candidate in (here, *here.parents):
        if (candidate / "run.sh").is_file() and (candidate / "caplib.sh").is_file():
            return candidate
    raise RuntimeError(f"no heliograph toolkit (run.sh + caplib.sh) at or above {here}")


TOOLKIT = _find_toolkit()

# `name` becomes a filename, so it is constrained to what is safe as one. This
# is not politeness about tidy names: without it a name of "../../host" is a
# path traversal that writes wherever the worker can reach.
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,63}$")
ENV_KEY_RE = re.compile(r"^[A-Z_][A-Z0-9_]*$")

MAX_SCRIPT = 256 * 1024

# 200, NOT the 30 minutes host.json allows a step. The Azure front end kills an
# HTTP request at 230 seconds whatever functionTimeout says, so a caller asking
# to wait 600 would not get a longer answer - they would get a dropped
# connection and no task id, which is the one outcome that loses a running step.
# Clamping means they get a task id at 200s and can poll for the rest.
MAX_WAIT = 200
DEFAULT_WAIT = 25

# Mirrors ACTION_ENV in pigeonhole.sh. A step can be made to change state by its
# environment as well as by its own code, so the gate looks at both.
ACTION_ENV = ("APPLY", "CONFIRM", "DESTROY", "FORCE", "WRITE")

# One megabyte per page. NEVER TRUNCATE is a heliograph rule, so a large log is
# paged rather than cut: the caller walks it with `offset` and the interesting
# part is never the part that went missing.
CHUNK = 1024 * 1024


class Refused(Exception):
    """A request that will not run, with the reason the caller should see."""


# --- the record ---------------------------------------------------------------
# status is one of: queued, running, done, refused, failed.
#
# `done` means the step ran to completion and `exit` says how it went. A step
# that exits non-zero is DONE, not FAILED - it produced a log, and the log is
# the deliverable. `failed` is reserved for the agent itself failing to run the
# step at all, which is a different thing and needs a different reaction.


def _now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def validate(body: object) -> dict:
    """Turn a request body into a task record, or raise Refused."""
    if not isinstance(body, dict):
        raise Refused("body must be a JSON object")

    name = body.get("name")
    if not isinstance(name, str) or not NAME_RE.match(name):
        raise Refused("name must match ^[a-z0-9][a-z0-9._-]{0,63}$")

    script = body.get("script")
    if not isinstance(script, str) or not script:
        raise Refused("script is required")
    if len(script.encode()) > MAX_SCRIPT:
        raise Refused(f"script is larger than {MAX_SCRIPT} bytes")

    env = body.get("env", {})
    if not isinstance(env, dict):
        raise Refused("env must be an object")
    for key, value in env.items():
        if not isinstance(key, str) or not ENV_KEY_RE.match(key):
            raise Refused(f"env key {key!r} must match ^[A-Z_][A-Z0-9_]*$")
        if not isinstance(value, str):
            raise Refused(f"env value for {key} must be a string")

    wait = body.get("wait", DEFAULT_WAIT)
    if isinstance(wait, bool) or not isinstance(wait, (int, float)):
        raise Refused("wait must be a number of seconds")
    wait = max(0, min(MAX_WAIT, int(wait)))

    return {
        "taskId": uuid.uuid4().hex,
        "name": name,
        "script": script,
        "env": env,
        "wait": wait,
        "status": "queued",
        "created": _now(),
    }


def submit(store, body: object) -> dict:
    """Record a task and enqueue it. Raises Refused on a bad request."""
    task = validate(body)
    store.put_task(task["taskId"], task)
    store.enqueue(task["taskId"])
    return task


def await_done(store, task_id: str, deadline: float, sleep=time.sleep) -> dict | None:
    """Poll the task record until it settles or the deadline passes.

    Returns the settled record, or None if it is still running - which is not a
    failure, it is the 202 case.
    """
    while True:
        task = store.get_task(task_id)
        if task and task["status"] in ("done", "refused", "failed"):
            return task
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return None
        # Half a second is short enough that a two-second step still feels
        # synchronous, and long enough that a 200-second wait is 400 reads
        # rather than 200,000.
        sleep(min(0.5, remaining))


def fetch(store, task_id: str, offset: int = 0) -> dict | None:
    """The record as the caller sees it, with a page of the log."""
    task = store.get_task(task_id)
    if task is None:
        return None
    return _present(store, task, offset)


def _present(store, task: dict, offset: int = 0) -> dict:
    # The script is not echoed back. The caller sent it and already has it, and
    # a 256 KB script on every poll response is bandwidth spent on nothing.
    out = {k: v for k, v in task.items() if k not in ("script", "env", "wait")}
    if task["status"] in ("done", "refused", "failed"):
        chunk, next_offset, total = store.get_log(task["taskId"], offset, CHUNK)
        # errors="replace" because offset is a BYTE position, so a page boundary
        # can land inside a multi-byte character. Replacing one character is the
        # right trade for exact, resumable paging.
        out["log"] = chunk.decode("utf-8", errors="replace")
        out["offset"] = offset
        out["nextOffset"] = next_offset
        out["logBytes"] = total
    return out


# --- execution ----------------------------------------------------------------


def _allow_actions() -> bool:
    return os.environ.get("HELIOGRAPH_ALLOW_ACTIONS", "0") == "1"


def _is_action(script_path: pathlib.Path, env: dict) -> bool:
    """Same question pigeonhole.sh asks, asked the same way.

    run.sh --mode reads the declaration out of the file that is about to run, so
    the step table and the mode gate keep ONE owner. The environment is checked
    too because a read-only step can be made to change state by what it is
    handed - `CONFIRM=yes` on a step that branches on it.
    """
    proc = subprocess.run(
        ["bash", str(TOOLKIT / "run.sh"), "--mode", str(script_path)],
        cwd=str(TOOLKIT),
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.stdout.strip().splitlines()[:1] == ["action"]:
        return True
    return any(key in ACTION_ENV for key in env)


def execute(store, task_id: str, workdir: str = "/tmp/heliograph") -> dict:
    """Run one task to completion and store its log. The queue trigger's body."""
    task = store.get_task(task_id)
    if task is None:
        # Not an exception. The queue redelivers, and a task whose record is
        # gone will never appear - raising would retry it until the poison
        # queue, logging says so once.
        return {"taskId": task_id, "status": "failed", "error": "no such task"}

    task["status"] = "running"
    task["started"] = _now()
    store.put_task(task_id, task)

    run_dir = pathlib.Path(workdir) / task_id
    log_dir = run_dir / "logs"
    log_dir.mkdir(parents=True, exist_ok=True)

    script_path = run_dir / f"{task['name']}.sh"
    script_path.write_text(task["script"])
    # 0o700 and not 0o755: the step is the caller's code, and nothing else on
    # this host has any business reading or running it.
    script_path.chmod(0o700)

    env = dict(os.environ)
    if _is_action(script_path, task["env"]) and not _allow_actions():
        return _settle(
            store,
            task,
            "refused",
            None,
            "This step changes state, and this agent is read-only.\n"
            "Set HELIOGRAPH_ALLOW_ACTIONS=1 on the Function App to permit it.\n",
        )

    env.update(task["env"])
    env["LOG_DIR"] = str(log_dir)
    # PUSH=0 because there is no git here and nothing to push to. The log goes
    # to the task store instead, which is what the caller is polling.
    env["PUSH"] = "0"

    proc = subprocess.run(
        ["bash", str(TOOLKIT / "run.sh"), str(script_path)],
        cwd=str(TOOLKIT),
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )

    # run.sh writes <name>-<UTC>.txt into LOG_DIR. If it refused before
    # capturing anything - an undeclared mode, a root account - there is no such
    # file, and the console output IS the log. Storing that rather than an empty
    # blob is the difference between "here is why nothing ran" and a log that
    # reports nothing at all, which reads like the step succeeding silently.
    produced = sorted(glob.glob(str(log_dir / "*.txt")))
    if produced:
        text = pathlib.Path(produced[-1]).read_text(errors="replace")
    else:
        text = (proc.stdout or "") + (proc.stderr or "")
        if not text:
            text = f"the step produced no output and no log (exit {proc.returncode})\n"

    # exit 0 or 7, it ran and it told us what happened: that is `done`. See the
    # note on the record above for why a non-zero step is not `failed`.
    return _settle(store, task, "done", proc.returncode, text)


def _settle(store, task: dict, status: str, exit_code: int | None, log: str) -> dict:
    store.put_log(task["taskId"], log.encode())
    task["status"] = status
    task["exit"] = exit_code
    task["finished"] = _now()
    task["logBytes"] = len(log.encode())
    store.put_task(task["taskId"], task)
    return task
