# =============================================================================
#  store.py - where a task and its log live between two HTTP invocations
# =============================================================================
#  Two HTTP calls into a Function App share nothing. Not memory, and on Flex
#  Consumption not even an instance: it scales to zero and is recycled at times
#  nobody chose. So the submit/poll shape needs a durable store, and this is it.
#
#  THIS IS NOT THE PIGEONHOLE, and the distinction is worth keeping straight.
#  The pigeonhole makes storage the TRANSPORT: the operator writes a request
#  blob and reads a log blob, so the operator needs credentials on the account.
#  Here storage is task STATE. The operator talks HTTP and never sees it. That
#  is the whole reason intercom exists, so nothing in this file should ever grow
#  an operator-facing path.
#
#  requirements.txt says the agent adds no storage SDK, because the pigeonhole
#  talks to the drop with curl and a second implementation would raise the
#  question of which is authoritative. That reasoning holds and this does not
#  contradict it: the SDK here is not a second transport, it is the state store,
#  and no curl version of it exists to disagree with.
#
#  IDENTITY IS THE ONLY CREDENTIAL AVAILABLE. The workload account has shared
#  access keys disabled, so a connection string or SAS cannot be minted at all.
#  A Function is handed a LOCAL token endpoint (IDENTITY_ENDPOINT), so this
#  needs no egress - which is the same property that lets this host work in a
#  VNet whose default route goes to a firewall with no policy for it.
# =============================================================================
from __future__ import annotations

import json
import os

from azure.core.exceptions import ResourceExistsError, ResourceNotFoundError
from azure.identity import DefaultAzureCredential
from azure.storage.blob import BlobServiceClient
from azure.storage.queue import QueueClient, TextBase64EncodePolicy


class BlobStore:
    """Tasks as JSON blobs, logs as blobs, the work queue as a storage queue."""

    def __init__(self, account: str | None = None, prefix: str | None = None):
        self.account = account or os.environ["HELIOGRAPH_ACCOUNT"]
        self.prefix = prefix if prefix is not None else os.environ.get("HELIOGRAPH_PREFIX", "")
        self.container = f"{self.prefix}tasks"
        self.queue_name = f"{self.prefix}tasks"
        self._credential = DefaultAzureCredential()
        self._blobs = BlobServiceClient(
            f"https://{self.account}.blob.core.windows.net", credential=self._credential
        )
        self._queue = QueueClient(
            f"https://{self.account}.queue.core.windows.net",
            queue_name=self.queue_name,
            credential=self._credential,
            # BASE64, because the Functions host decodes queue messages that way
            # by default. The SDK sends plain text unless told otherwise, and the
            # mismatch surfaces as a trigger that fires and then fails to decode
            # - which looks like a broken message rather than a broken encoding.
            message_encode_policy=TextBase64EncodePolicy(),
        )

    # --- tasks ----------------------------------------------------------------

    def _task_blob(self, task_id: str):
        return self._blobs.get_blob_client(self.container, f"tasks/{task_id}.json")

    def put_task(self, task_id: str, record: dict) -> None:
        self._task_blob(task_id).upload_blob(json.dumps(record).encode(), overwrite=True)

    def get_task(self, task_id: str) -> dict | None:
        try:
            return json.loads(self._task_blob(task_id).download_blob().readall())
        except ResourceNotFoundError:
            return None

    # --- logs -----------------------------------------------------------------

    def _log_blob(self, task_id: str):
        return self._blobs.get_blob_client(self.container, f"logs/{task_id}.txt")

    def put_log(self, task_id: str, data: bytes) -> None:
        self._log_blob(task_id).upload_blob(data, overwrite=True)

    def get_log(self, task_id: str, offset: int, length: int) -> tuple[bytes, int, int]:
        """Return (chunk, next_offset, total_bytes).

        next_offset equals total when the caller has the whole log, which is how
        a poller knows to stop asking. NEVER TRUNCATE: a log longer than one page
        is paged, not cut.
        """
        try:
            blob = self._log_blob(task_id)
            total = blob.get_blob_properties().size
            if offset >= total:
                return b"", total, total
            chunk = blob.download_blob(offset=offset, length=length).readall()
            return chunk, offset + len(chunk), total
        except ResourceNotFoundError:
            return b"", 0, 0

    # --- the queue ------------------------------------------------------------

    def enqueue(self, task_id: str) -> None:
        self._queue.send_message(task_id)

    def ensure(self) -> None:
        """Create the container and queue if they are absent.

        Terraform creates both, so this is belt and braces - but a Function that
        500s because a container is missing gives the caller nothing to act on,
        and this costs one idempotent call at startup.
        """
        for create in (
            lambda: self._blobs.create_container(self.container),
            self._queue.create_queue,
        ):
            try:
                create()
            except ResourceExistsError:
                pass
