"""A minimal JSON-RPC client for the Codex app-server (LLD 5.4).

Framing, id allocation and the rule that a server-initiated request is declined are
lifted from icodex:lib/profile/app_server.py. The transport here is a stdio child;
the daemon socket arrives with slice S8, which owns the daemon lifecycle.

Failure class: the caller's. This module raises; it never decides.
"""

from __future__ import annotations

import json
import os
import subprocess


class AppServerError(RuntimeError):
    pass


class AppServer:
    """One short-lived `codex app-server` child, used for a handful of requests."""

    def __init__(self, binary: str, home: str, timeout: float = 30.0):
        self._binary = binary
        self._home = home
        self._timeout = timeout
        self._proc: subprocess.Popen | None = None
        self._next_id = 0

    def __enter__(self):
        env = dict(os.environ, CODEX_HOME=self._home)
        self._proc = subprocess.Popen(
            [self._binary, "app-server"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env=env, text=True, bufsize=1,
        )
        self.request("initialize", {
            "clientInfo": {"name": "ihar", "title": "ihar", "version": "0"},
        })
        self.notify("initialized", {})
        return self

    def __exit__(self, *_):
        proc = self._proc
        if proc is None:
            return False
        try:
            if proc.stdin:
                proc.stdin.close()
            proc.wait(timeout=5)
        except (subprocess.TimeoutExpired, OSError):
            proc.kill()
        self._proc = None
        return False

    # ----------------------------------------------------------------- #

    def _write(self, obj) -> None:
        proc = self._proc
        if proc is None or proc.stdin is None:
            raise AppServerError("the app-server is not running")
        proc.stdin.write(json.dumps(obj) + "\n")
        proc.stdin.flush()

    def notify(self, method: str, params) -> None:
        self._write({"method": method, "params": params})

    def request(self, method: str, params):
        proc = self._proc
        if proc is None or proc.stdout is None:
            raise AppServerError("the app-server is not running")

        self._next_id += 1
        request_id = self._next_id
        self._write({"id": request_id, "method": method, "params": params})

        # Bounded: a malformed stream must not hang a launch. Notifications and
        # server-initiated requests arrive interleaved with the answer.
        for _ in range(500):
            line = proc.stdout.readline()
            if not line:
                stderr = proc.stderr.read() if proc.stderr else ""
                raise AppServerError(f"the app-server closed the stream: {stderr.strip()[:300]}")
            try:
                message = json.loads(line)
            except json.JSONDecodeError:
                continue

            if message.get("id") == request_id:
                if "error" in message:
                    raise AppServerError(f"{method}: {json.dumps(message['error'])[:300]}")
                return message.get("result")

            if "method" in message and "id" in message:
                # A server-initiated request. ihar answers none of them, and leaving
                # it unanswered would leave the server waiting.
                self._write({"id": message["id"],
                             "error": {"code": -32601, "message": "ihar declines server requests"}})

        raise AppServerError(f"{method}: no answer within the message budget")


def hooks_list(binary: str, home: str, cwds: list[str]) -> list[dict]:
    """Every hook the vendor sees for the given directories, with its trust state."""
    with AppServer(binary, home) as server:
        result = server.request("hooks/list", {"cwds": cwds})
    entries = (result or {}).get("data", []) or []
    hooks: list[dict] = []
    for entry in entries:
        for hook in entry.get("hooks", []) or []:
            hooks.append(hook)
    return hooks
