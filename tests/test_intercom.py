# =============================================================================
#  test_intercom.py - the HTTP transport's logic, with no Azure anywhere
# =============================================================================
#  intercom.py imports nothing from Azure on purpose: the storage client lives
#  in store.py and is passed in. So every property that matters here - what is
#  refused, what is clamped, what a failing step is recorded as, how a large log
#  is paged - is testable against a dictionary.
#
#  unittest rather than pytest, because this repository promises no packages and
#  its other thirteen test files are plain bash. A test suite that needs a pip
#  install to run is a test suite that stops being run.
#
#  execute() genuinely runs run.sh and caplib.sh through bash. That is the point:
#  the thing most likely to break is the seam between the Python and the toolkit,
#  and a mock of subprocess would assert only that the mock was called.
# =============================================================================
import json
import os
import pathlib
import sys
import tempfile
import unittest

FUNCTION_DIR = (
    pathlib.Path(__file__).resolve().parent.parent
    / "skills"
    / "heliograph"
    / "toolkit"
    / "azure"
    / "function"
)
sys.path.insert(0, str(FUNCTION_DIR))

import intercom  # noqa: E402


READ_ONLY = "#!/usr/bin/env bash\n# heliograph-mode: read-only\necho hello\n"
ACTION = "#!/usr/bin/env bash\n# heliograph-mode: action\necho changing things\n"
UNDECLARED = "#!/usr/bin/env bash\necho no header here\n"


class MemoryStore:
    """The store protocol, backed by dictionaries.

    Records are round-tripped through JSON on the way in and out because the
    real store does, and a test that shares a mutable dict with the code under
    test would pass while the real one failed on anything unserialisable.
    """

    def __init__(self):
        self.tasks = {}
        self.logs = {}
        self.queue = []

    def put_task(self, task_id, record):
        self.tasks[task_id] = json.dumps(record)

    def get_task(self, task_id):
        raw = self.tasks.get(task_id)
        return json.loads(raw) if raw is not None else None

    def put_log(self, task_id, data):
        self.logs[task_id] = data

    def get_log(self, task_id, offset, length):
        data = self.logs.get(task_id, b"")
        total = len(data)
        if offset >= total:
            return b"", total, total
        chunk = data[offset : offset + length]
        return chunk, offset + len(chunk), total

    def enqueue(self, task_id):
        self.queue.append(task_id)


def body(**over):
    out = {"name": "probe", "script": READ_ONLY}
    out.update(over)
    return out


class Validation(unittest.TestCase):
    def test_a_good_body_is_accepted(self):
        task = intercom.validate(body())
        self.assertEqual(task["status"], "queued")
        self.assertEqual(task["name"], "probe")

    def test_name_may_not_traverse(self):
        # The name becomes a filename. This is the case that makes the regex a
        # security control rather than a tidiness one.
        for bad in ("../../host", "/etc/passwd", "probe/../x", "Probe", "", "a" * 65):
            with self.assertRaises(intercom.Refused, msg=bad):
                intercom.validate(body(name=bad))

    def test_script_is_required_and_bounded(self):
        with self.assertRaises(intercom.Refused):
            intercom.validate(body(script=""))
        with self.assertRaises(intercom.Refused):
            intercom.validate(body(script="x" * (intercom.MAX_SCRIPT + 1)))

    def test_env_keys_and_values_are_checked(self):
        with self.assertRaises(intercom.Refused):
            intercom.validate(body(env={"lower": "x"}))
        with self.assertRaises(intercom.Refused):
            intercom.validate(body(env={"OK": 1}))
        with self.assertRaises(intercom.Refused):
            intercom.validate(body(env=["NOT", "AN", "OBJECT"]))
        self.assertEqual(intercom.validate(body(env={"HOSTS": "a b"}))["env"], {"HOSTS": "a b"})

    def test_wait_is_clamped_rather_than_refused(self):
        # A caller asking for ten minutes gets 200 seconds and a task id, NOT an
        # error: the front end would drop the connection at 230s and the running
        # step would be lost with it.
        self.assertEqual(intercom.validate(body(wait=600))["wait"], intercom.MAX_WAIT)
        self.assertEqual(intercom.validate(body(wait=-5))["wait"], 0)
        self.assertEqual(intercom.validate(body())["wait"], intercom.DEFAULT_WAIT)
        with self.assertRaises(intercom.Refused):
            intercom.validate(body(wait="soon"))

    def test_a_body_that_is_not_an_object_is_refused(self):
        with self.assertRaises(intercom.Refused):
            intercom.validate(["not", "an", "object"])

    def test_submit_records_and_enqueues(self):
        store = MemoryStore()
        task = intercom.submit(store, body())
        self.assertEqual(store.queue, [task["taskId"]])
        self.assertEqual(store.get_task(task["taskId"])["status"], "queued")


class Execution(unittest.TestCase):
    def setUp(self):
        self.store = MemoryStore()
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self._env = dict(os.environ)
        self.addCleanup(lambda: (os.environ.clear(), os.environ.update(self._env)))
        os.environ.pop("HELIOGRAPH_ALLOW_ACTIONS", None)

    def run_task(self, **over):
        task = intercom.submit(self.store, body(**over))
        return intercom.execute(self.store, task["taskId"], workdir=self.tmp.name)

    def test_a_read_only_step_runs_and_its_output_is_captured(self):
        settled = self.run_task()
        self.assertEqual(settled["status"], "done")
        self.assertEqual(settled["exit"], 0)
        self.assertIn("hello", self.store.logs[settled["taskId"]].decode())

    def test_the_log_is_the_captured_one_with_its_header(self):
        # Proof that run.sh and caplib.sh did the work, rather than the Python
        # having quietly reimplemented a capture of its own.
        settled = self.run_task()
        log = self.store.logs[settled["taskId"]].decode()
        self.assertIn("started UTC", log)
        self.assertIn("RESULT", log)

    def test_env_reaches_the_step(self):
        settled = self.run_task(
            script="#!/usr/bin/env bash\n# heliograph-mode: read-only\necho \"got $HOSTS\"\n",
            env={"HOSTS": "a b"},
        )
        # Quoted with a space, which is the shape that broke the pigeonhole's
        # env line: word splitting turned HOSTS="a b" into two arguments and the
        # run died before run.sh started, producing no log at all.
        self.assertIn("got a b", self.store.logs[settled["taskId"]].decode())

    def test_a_failing_step_is_done_and_not_failed(self):
        # THE RULE. A step that exits non-zero produced a log, and the log is the
        # deliverable. `failed` is reserved for the agent failing to run it.
        settled = self.run_task(
            script="#!/usr/bin/env bash\n# heliograph-mode: read-only\nexit 7\n"
        )
        self.assertEqual(settled["status"], "done")
        self.assertEqual(settled["exit"], 7)

    def test_an_action_step_is_refused_by_default(self):
        settled = self.run_task(script=ACTION)
        self.assertEqual(settled["status"], "refused")
        self.assertIn("read-only", self.store.logs[settled["taskId"]].decode())
        # Refused means it did not run, which is the whole point.
        self.assertNotIn("changing things", self.store.logs[settled["taskId"]].decode())

    def test_an_action_step_runs_when_the_app_setting_allows_it(self):
        os.environ["HELIOGRAPH_ALLOW_ACTIONS"] = "1"
        settled = self.run_task(script=ACTION, env={"CONFIRM": "yes"})
        self.assertEqual(settled["status"], "done")
        self.assertIn("changing things", self.store.logs[settled["taskId"]].decode())

    def test_an_action_env_var_is_refused_even_on_a_read_only_script(self):
        # A read-only step can still change state through what it is handed.
        # pigeonhole.sh checks the same list for the same reason.
        settled = self.run_task(env={"DESTROY": "1"})
        self.assertEqual(settled["status"], "refused")

    def test_an_undeclared_script_does_not_run(self):
        # run.sh owns this gate and intercom does not second-guess it: the step
        # runs through the same refusal a committed step would get.
        settled = self.run_task(script=UNDECLARED)
        self.assertEqual(settled["status"], "done")
        self.assertNotEqual(settled["exit"], 0)
        log = self.store.logs[settled["taskId"]].decode()
        self.assertIn("declares no mode", log)
        self.assertNotIn("no header here", log)

    def test_a_step_that_outruns_its_deadline_is_killed_with_its_partial_log(self):
        # THE POINT OF THIS ONE. A killed step must still hand back what it
        # managed - caplib writes the capture to a file as it goes, so the
        # partial log is evidence of how far it got. Losing it would make a step
        # that hung indistinguishable from a step that produced nothing.
        task = intercom.submit(self.store, body(
            script="#!/usr/bin/env bash\n# heliograph-mode: read-only\n"
                   "echo before the wait\nsleep 30\necho after the wait\n"))
        settled = intercom.execute(
            self.store, task["taskId"], workdir=self.tmp.name, timeout=3)
        self.assertEqual(settled["status"], "timeout")
        log = self.store.logs[settled["taskId"]].decode()
        self.assertIn("before the wait", log)
        self.assertNotIn("after the wait", log)
        self.assertIn("killed after", log)

    def test_submit_can_skip_the_queue_for_inline_execution(self):
        # Enqueuing as well would run the step twice, and two logs for one
        # question is the failure this tool exists to prevent.
        task = intercom.submit(self.store, body(), enqueue=False)
        self.assertEqual(self.store.queue, [])
        self.assertIsNotNone(self.store.get_task(task["taskId"]))

    def test_an_unknown_task_is_reported_not_raised(self):
        settled = intercom.execute(self.store, "nosuchtask", workdir=self.tmp.name)
        self.assertEqual(settled["status"], "failed")


class Presentation(unittest.TestCase):
    def setUp(self):
        self.store = MemoryStore()

    def test_unknown_task_is_none(self):
        self.assertIsNone(intercom.fetch(self.store, "nope"))

    def test_the_script_is_not_echoed_back(self):
        task = intercom.submit(self.store, body())
        seen = intercom.fetch(self.store, task["taskId"])
        self.assertNotIn("script", seen)
        self.assertNotIn("env", seen)

    def test_a_running_task_carries_no_log_key(self):
        task = intercom.submit(self.store, body())
        self.assertNotIn("log", intercom.fetch(self.store, task["taskId"]))

    def test_a_large_log_is_paged_and_never_truncated(self):
        task = intercom.submit(self.store, body())
        whole = ("line\n" * 700_000).encode()
        self.assertGreater(len(whole), intercom.CHUNK)
        self.store.put_log(task["taskId"], whole)
        record = json.loads(self.store.tasks[task["taskId"]])
        record["status"] = "done"
        self.store.put_task(task["taskId"], record)

        # Walk it the way a client does, and assert the reassembly is byte-exact.
        got, offset = b"", 0
        while True:
            page = intercom.fetch(self.store, task["taskId"], offset)
            got += page["log"].encode()
            if page["nextOffset"] >= page["logBytes"]:
                break
            offset = page["nextOffset"]
        self.assertEqual(got, whole)
        self.assertEqual(len(got), len(whole))


if __name__ == "__main__":
    unittest.main(verbosity=2)
