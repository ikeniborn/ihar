#!/usr/bin/env python3
"""Record what a session is doing, for the console sidebar (LLD 13.2).

Failure class: fail-soft. The badge is a convenience: a session never fails because
its state could not be written, and a status that cannot be recorded is reported as
unknown rather than guessed at.

Identity comes from the hook payload, never from the environment, for the reason
`session-register.py` gives: under the Codex app-server daemon a hook inherits the
environment the daemon started with, so any launch variable may belong to another
session. The payload's own `session_id` always describes the session that fired.

The four events this runs on are the coarse lifecycle both vendors share. Nothing is
attached to PreToolUse, where two hooks already run per tool call and a third would be
paid on every call to move one badge.
"""

from __future__ import annotations

import json
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "_shared"))

import hookio      # noqa: E402
import policy      # noqa: E402

STATES = ("running", "waiting-approval", "idle", "stopped")


def _state_from(argv: list[str]) -> str:
    for index, token in enumerate(argv):
        if token == "--state" and index + 1 < len(argv):
            return argv[index + 1]
        if token.startswith("--state="):
            return token.split("=", 1)[1]
    return ""


def main(argv=None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    state_name = _state_from(argv)
    if state_name not in STATES:
        return 0

    try:
        event = hookio.read_event(argv)
    except hookio.HookIOError:
        return 0

    active = policy.load(event)
    state = active.get("state")
    session_id = event.raw.get("session_id") or ""
    if not state or not session_id:
        return 0

    vendor = active.get("vendor") or event.vendor
    record = {"schema": 1, "vendor": vendor, "vendor_session_id": session_id,
              "state": state_name,
              "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    directory = os.path.join(state, "status")
    target = os.path.join(directory, f"{vendor}-{session_id}.json")
    try:
        os.makedirs(directory, exist_ok=True)
        # Written whole and moved into place: a sidebar reading a half-written file
        # would show a state that never existed.
        temporary = target + f".{os.getpid()}"
        with open(temporary, "w", encoding="utf-8") as handle:
            json.dump(record, handle, sort_keys=True)
        os.chmod(temporary, 0o600)
        os.replace(temporary, target)
    except OSError:
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
