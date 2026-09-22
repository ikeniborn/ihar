#!/usr/bin/env python3
"""The console's ACP chat tab: its client, its gate and its label (LLD 13.3).

The protocol here is the one measured from @zed-industries/agent-client-protocol 0.4.5, and
the agent is `tests/fakes/acp-agent.py`, because neither adapter is installed on a machine
that runs this suite and a claim about a real adapter would not be evidence either way.
"""

import json
import os
import sys
import tempfile
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "lib" / "python"))

from ihar.console.acp import AcpClient  # noqa: E402

PASS = FAIL = 0


def check(label, condition):
    global PASS, FAIL
    if condition:
        PASS += 1
    else:
        FAIL += 1
        print(f"FAIL {label}")


class Collected:
    """Events the tab would have replayed, with a wait that does not race the agent."""

    def __init__(self):
        self.events = []
        self.ready = threading.Event()

    def __call__(self, event):
        self.events.append(event)
        self.ready.set()

    def wait_for(self, predicate, timeout=10.0):
        deadline = time.time() + timeout
        while time.time() < deadline:
            for event in list(self.events):
                if predicate(event):
                    return event
            self.ready.clear()
            self.ready.wait(0.2)
        return None

    def kinds(self):
        return [event.get("type") for event in self.events]


def main():
    global PASS, FAIL
    with tempfile.TemporaryDirectory() as raw:
        project = Path(raw)
        seen = Collected()
        client = AcpClient([sys.executable, str(ROOT / "tests" / "fakes" / "acp-agent.py")],
                           str(project), dict(os.environ), seen)
        client.start()

        initialized = seen.wait_for(lambda event: event["type"] == "initialized")
        check("the client initialises", initialized is not None)
        check("the client speaks the measured protocol version",
              (initialized or {}).get("protocol_version") == 1)

        session = seen.wait_for(lambda event: event["type"] == "session")
        check("a session is created", (session or {}).get("session_id") == "fake-session-1")

        client.prompt("do the thing")
        own = seen.wait_for(lambda event: event.get("kind") == "user_message_chunk")
        check("the prompt is echoed into the conversation", own is not None)
        thought = seen.wait_for(lambda event: event.get("kind") == "agent_thought_chunk")
        answer = seen.wait_for(lambda event: event.get("kind") == "agent_message_chunk")
        check("the agent's thinking reaches the tab", thought is not None)
        check("the agent's answer reaches the tab", answer is not None)

        # A permission request is held for the user, never answered by this process.
        permission = seen.wait_for(lambda event: event["type"] == "permission")
        check("a permission request is surfaced", permission is not None)
        check("the request names the tool call",
              ((permission or {}).get("tool_call") or {}).get("title") == "write a file")
        check("the request carries the agent's own options",
              [option["optionId"] for option in (permission or {}).get("options") or []]
              == ["allow", "reject"])
        time.sleep(0.5)
        check("nothing answered the permission on the user's behalf",
              "permission-answered" not in seen.kinds())

        # A capability the console does not offer is refused rather than implemented.
        refused = seen.wait_for(lambda event: event["type"] == "refused")
        check("an unoffered client method is refused", refused is not None)
        check("the refusal names the method",
              (refused or {}).get("method") == "fs/read_text_file")

        client.answer(str((permission or {}).get("request_id")), "allow")
        answered = seen.wait_for(lambda event: event["type"] == "permission-answered")
        check("the user's answer is recorded", (answered or {}).get("option_id") == "allow")
        completed = seen.wait_for(lambda event: event.get("kind") == "tool_call_update")
        check("the agent continues after the answer",
              ((completed or {}).get("update") or {}).get("status") == "completed")
        end = seen.wait_for(lambda event: event["type"] == "turn-end")
        check("the turn ends with the agent's stop reason",
              (end or {}).get("stop_reason") == "end_turn")

        client.stop()

        # A cancelled turn answers every pending request `cancelled`, which the protocol
        # requires of a client.
        second = Collected()
        other = AcpClient([sys.executable, str(ROOT / "tests" / "fakes" / "acp-agent.py")],
                          str(project), dict(os.environ), second)
        other.start()
        second.wait_for(lambda event: event["type"] == "session")
        other.prompt("start something")
        second.wait_for(lambda event: event["type"] == "permission")
        other.cancel()
        cancelled = second.wait_for(
            lambda event: event["type"] == "permission-answered" and event["option_id"] is None)
        check("cancelling answers the pending permission", cancelled is not None)
        other.stop()

    print(f"PASS={PASS} FAIL={FAIL}")
    return 1 if FAIL else 0


if __name__ == "__main__":
    raise SystemExit(main())
