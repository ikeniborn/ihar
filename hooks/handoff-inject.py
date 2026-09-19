#!/usr/bin/env python3
"""Inject and consume the pending package for a Codex SessionStart (LLD 11.5)."""

from __future__ import annotations

import json
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "_shared"))

import hookio  # noqa: E402
import policy  # noqa: E402


def _ihar_id(index_path: str, vendor: str, vendor_session_id: str):
    folded = {}
    try:
        stream = open(index_path, encoding="utf-8")
    except OSError:
        return None
    with stream:
        for line in stream:
            try:
                row = json.loads(line)
            except (ValueError, TypeError):
                continue
            identity = row.get("ihar_id")
            if not identity:
                continue
            current = folded.setdefault(identity, {})
            current.update({key: value for key, value in row.items() if value is not None})
    for identity, row in folded.items():
        if row.get("vendor") == vendor and row.get("vendor_session_id") == vendor_session_id:
            return identity
    return None


def _remainder(data: bytes, limit: int = 2048) -> str:
    boundary = min(limit, len(data))
    while boundary and (data[boundary:boundary + 1] and data[boundary] & 0xC0 == 0x80):
        boundary -= 1
    return data[boundary:].decode("utf-8")


def main():
    try:
        event = hookio.read_event()
        active = policy.load(event)
        pending_dir = os.path.join(active["state"], "handoff", "pending")
        try:
            if not any(name.endswith(".md") for name in os.listdir(pending_dir)):
                return 0
        except OSError:
            return 0
        index = os.path.join(active["state"], "sessions.jsonl")
        identity = None
        deadline = time.monotonic() + 4.5
        while identity is None and time.monotonic() < deadline:
            identity = _ihar_id(index, active.get("vendor") or event.vendor, event.session_id)
            if identity is None:
                time.sleep(0.05)
        if not identity:
            return 0
        pending = os.path.join(pending_dir, identity + ".md")
        with open(pending, "rb") as stream:
            text = _remainder(stream.read())
        os.unlink(pending)
        if not text:
            return 0
        hookio.context(event, text)
    except (OSError, KeyError, hookio.HookIOError):
        return 0
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
