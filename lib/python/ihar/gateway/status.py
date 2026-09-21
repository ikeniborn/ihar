"""Read structured status for every explicit gateway instance.

Failure class: fail-soft per instance. Missing or malformed state is represented by
nullable facts and unavailable metrics; status collection never rewrites state.

Usage: python3 -m ihar.gateway.status <gateway-state-root>
"""

from __future__ import annotations

import http.client
import json
import os
import sys
from pathlib import Path


_EMPTY_METRICS = {
    "state": "unavailable",
    "masked": None,
    "refused": None,
    "relayed": None,
    "uptime_seconds": None,
}
_METRIC_NAMES = ("masked", "refused", "relayed", "uptime_seconds")


def _read_int(path: Path, *, minimum: int, maximum: int | None = None) -> int | None:
    try:
        value = int(path.read_text(encoding="utf-8").strip())
    except (OSError, ValueError):
        return None
    if value < minimum or (maximum is not None and value > maximum):
        return None
    return value


def _process_exists(pid: int | None) -> bool:
    if pid is None:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def _local(port: int, path: str) -> dict | None:
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=0.5)
    try:
        connection.request("GET", path)
        response = connection.getresponse()
        payload = response.read()
        if response.status != 200 or response.getheader("x-ihar-gateway") != "1":
            return None
        body = json.loads(payload)
        return body if isinstance(body, dict) else None
    except (OSError, http.client.HTTPException, json.JSONDecodeError):
        return None
    finally:
        connection.close()


def _metrics(port: int) -> dict:
    body = _local(port, "/api/metrics")
    if body is None:
        return dict(_EMPTY_METRICS)
    values = {name: body.get(name) for name in _METRIC_NAMES}
    if any(isinstance(value, bool) or not isinstance(value, int) or value < 0
           for value in values.values()):
        return dict(_EMPTY_METRICS)
    return {"state": "available", **values}


def _consumers(path: Path) -> int:
    count = 0
    for record in path.glob("*.pid"):
        try:
            pid = int(record.stem)
        except ValueError:
            continue
        if _process_exists(pid):
            count += 1
    return count


def collect(root: Path) -> list[dict]:
    instances = []
    if not root.is_dir():
        return instances
    for directory in sorted(path for path in root.iterdir() if path.is_dir()):
        pid = _read_int(directory / "pid", minimum=1)
        port = _read_int(directory / "port", minimum=1, maximum=65535)
        alive = _process_exists(pid)
        probe = _local(port, "/api/ihar-probe") if alive and port is not None else None
        healthy = probe is not None and probe.get("ok") is True
        instances.append({
            "key": directory.name,
            "mode": "explicit",
            "port": port,
            "pid": pid,
            "consumers": _consumers(directory / "consumers"),
            "healthy": healthy,
            "metrics": _metrics(port) if healthy and port is not None else dict(_EMPTY_METRICS),
        })
    return instances


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        print(__doc__, file=sys.stderr)
        return 2
    print(json.dumps(collect(Path(argv[0])), separators=(",", ":"), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
