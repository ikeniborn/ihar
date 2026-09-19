#!/usr/bin/env python3
"""Record a vendor session id against the launch that started it (LLD 10.3).

Failure class: fail-soft. The session index is a convenience layer; a launch never
fails because its id was not recorded.

Identity comes from the hook payload, never from the environment. Under the Codex
app-server daemon a hook inherits the environment the daemon started with, so
IHAR_LAUNCH_ID may belong to an entirely different launch.
"""

from __future__ import annotations

import json
import os
import sys
import time
import uuid
import fcntl

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "_shared"))

import hookio      # noqa: E402
import policy      # noqa: E402

DISCOVERED_NAMESPACE = uuid.UUID("de7a9db8-3788-5e56-85cf-b839273cea2d")


def _now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def _claim(state: str, vendor: str, runtime_hash: str):
    """Take the oldest unclaimed launch for this vendor and runtime, and delete it.

    The claim is what links a vendor session id to the launch that produced it,
    without either of them being able to read the other's environment.
    """
    directory = os.path.join(state, "launches")
    try:
        names = sorted(os.listdir(directory))
    except OSError:
        return None
    for name in names:
        path = os.path.join(directory, name)
        try:
            with open(path, "r", encoding="utf-8") as handle:
                claim = json.load(handle)
        except (OSError, json.JSONDecodeError):
            continue
        if claim.get("vendor") != vendor:
            continue
        if runtime_hash and claim.get("runtime_hash") not in (None, runtime_hash):
            continue
        try:
            os.unlink(path)
        except OSError:
            return None
        return claim
    return None


def _lock_best_effort(handle, timeout: float = 5.0) -> bool:
    """Match ihar_with_lock --best-effort: wait briefly, then continue unlocked."""
    deadline = time.monotonic() + timeout
    while True:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return True
        except BlockingIOError:
            if time.monotonic() >= deadline:
                return False
            time.sleep(0.05)


def main():
    try:
        event = hookio.read_event()
    except hookio.HookIOError:
        return 0

    active = policy.load(event)
    state = active.get("state")
    if not state:
        return 0

    session_id = event.raw.get("session_id") or ""
    vendor = active.get("vendor") or event.vendor
    try:
        target = os.path.join(state, "sessions.jsonl")
        lock_path = os.path.join(state, ".ihar-sessions.lock")
        os.makedirs(state, exist_ok=True)
        with open(lock_path, "a", encoding="utf-8") as lock:
            _lock_best_effort(lock)
            claim = _claim(state, vendor, active.get("runtime_hash", ""))
            record = {
                "schema": 1,
                "vendor": vendor,
                "vendor_session_id": session_id or None,
                "source": "hook",
                "updated_at": _now(),
            }
            if claim:
                record["ihar_id"] = claim["ihar_id"]
                record["profile"] = claim.get("profile", active.get("profile", "standard"))
            else:
                record["ihar_id"] = str(uuid.uuid5(DISCOVERED_NAMESPACE, f"{vendor}:{session_id}"))
                record["profile"] = active.get("profile", "standard")
            with open(target, "a", encoding="utf-8") as handle:
                handle.write(json.dumps(record, sort_keys=True) + "\n")
            os.chmod(target, 0o600)
    except OSError:
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
