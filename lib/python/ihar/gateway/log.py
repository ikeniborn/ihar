"""The only writer of the gateway log (LLD 8.6).

A security component's log is read when something went wrong, which is exactly when
the temptation to include the payload is strongest. So the contract is a whitelist,
enforced here rather than left to each call site:

never logged   Authorization and x-api-key values, any request or response body in
               either its original or its masked form, OAuth callback parameters, and
               query strings, which routinely carry tokens

always logged  a request id, the host and route class, byte counts, mask counts by
               kind, latency, and the reason for a refusal

Masked is not safe. A body that failed to parse was never masked, and a body that did
is still the user's content.

Failure class: fail-soft. A log that cannot be written warns once; it never stops a
request, because losing a line is better than losing the session.
"""

from __future__ import annotations

import json
import os
import sys
import threading
import time

_ALLOWED = frozenset({
    "at", "request_id", "event", "host", "route", "method", "path_class",
    "status", "request_bytes", "response_bytes", "duration_ms",
    "masked", "refused", "reason", "level", "engine", "mode", "port", "consumers",
})

_lock = threading.Lock()
_stream = None
_warned = False


def open_log(directory: str | None) -> None:
    global _stream
    if not directory:
        return
    try:
        os.makedirs(directory, exist_ok=True)
        name = time.strftime("gateway-%Y-%m-%d.log", time.gmtime())
        _stream = open(os.path.join(directory, name), "a", encoding="utf-8")
    except OSError as error:
        print(f"ihar: gateway log unavailable: {error}", file=sys.stderr)
        _stream = None


def record(**fields) -> None:
    """Write one line. A field outside the contract is dropped, not written.

    Dropping rather than raising is deliberate: a caller that adds a field by mistake
    should lose the field, not the request. The test asserts the drop.
    """
    global _warned
    safe = {key: value for key, value in fields.items() if key in _ALLOWED}
    safe["at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    line = json.dumps(safe, sort_keys=True)

    with _lock:
        if _stream is None:
            print(line, file=sys.stderr)
            return
        try:
            _stream.write(line + "\n")
            _stream.flush()
        except OSError as error:
            if not _warned:
                print(f"ihar: gateway log write failed: {error}", file=sys.stderr)
                _warned = True


def path_class(path: str) -> str:
    """A path with its query removed, which is where tokens hide."""
    return path.split("?", 1)[0]
