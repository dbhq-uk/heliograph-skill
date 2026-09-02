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
# =============================================================================
import logging
import os
import pathlib
import subprocess

import azure.functions as func

app = func.FunctionApp()

# The toolkit ships beside this file in the deployment package. Resolved from
# __file__ rather than the working directory, which the host does not promise.
TOOLKIT = pathlib.Path(__file__).parent


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
