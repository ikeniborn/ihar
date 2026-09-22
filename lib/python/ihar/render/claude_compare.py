"""Compare Claude settings while excluding its vendor-owned top-level theme.

Failure class: fail-closed. The CLI exits 3 for drift or unreadable JSON and
prints only the first differing field path, never a field value.
"""

from __future__ import annotations

import copy
import json
import sys


def compare_objects(desired: dict, active: dict) -> str | None:
    """Return first differing field path, or None; leave both inputs untouched."""
    desired = copy.deepcopy(desired)
    active = copy.deepcopy(active)
    if not isinstance(desired, dict) or not isinstance(active, dict):
        return "$"
    if isinstance(active.get("theme"), str):
        active.pop("theme")
    return _first_difference(desired, active, "")


def _first_difference(desired: dict, active: dict, prefix: str) -> str | None:
    for key in sorted(desired.keys() | active.keys()):
        path = f"{prefix}.{key}" if prefix else key
        if key not in desired or key not in active:
            return path
        expected, actual = desired[key], active[key]
        if isinstance(expected, dict) and isinstance(actual, dict):
            difference = _first_difference(expected, actual, path)
            if difference is not None:
                return difference
        elif not _same_json_value(expected, actual):
            return path
    return None


def _same_json_value(expected: object, actual: object) -> bool:
    if type(expected) is not type(actual):
        return False
    if isinstance(expected, dict):
        return expected.keys() == actual.keys() and all(
            _same_json_value(expected[key], actual[key]) for key in expected
        )
    if isinstance(expected, list):
        return len(expected) == len(actual) and all(
            _same_json_value(left, right) for left, right in zip(expected, actual)
        )
    return expected == actual


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        return 2
    try:
        with open(argv[0], encoding="utf-8") as handle:
            desired = json.load(handle)
        with open(argv[1], encoding="utf-8") as handle:
            active = json.load(handle)
    except (OSError, UnicodeError, json.JSONDecodeError):
        print("$")
        return 3
    difference = compare_objects(desired, active)
    if difference is not None:
        print(difference)
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
