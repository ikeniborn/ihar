"""Create or upgrade the project state marker (LLD 4.1).

Failure class: runtime. A marker that cannot be written aborts the launch, because
without it the state directory is untraceable to its project — the defect that left
icodex with gigabytes of homes nobody could attribute.

Schema 1 is the iclaude marker and schema 2 was LLD revision 2's; both predate the
split of project state from runtime configuration, so an upgrade adds the missing
keys and never rewrites what is already there.

Usage: python3 -m ihar.state_marker <marker-path> <project-root>
"""

from __future__ import annotations

import datetime
import json
import os
import sys

from . import jsonio

SCHEMA = 3


def _now() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def upgrade(existing: dict, project_root: str) -> dict:
    """Bring a marker of any known schema to schema 3 without losing its history."""
    marker = dict(existing)
    marker["schema"] = SCHEMA
    marker.setdefault("project_root", project_root)
    marker.setdefault("created", _now())
    marker.setdefault("vendors", [])
    marker.setdefault("runtimes", {})
    marker.setdefault("migrated_from", {})
    return marker


def read_root(path: str) -> int:
    """Print the project a marker records, for the listing in lib/state/gc.sh."""
    try:
        with open(path, "r", encoding="utf-8") as handle:
            marker = json.load(handle)
    except (OSError, json.JSONDecodeError):
        return 1
    root = marker.get("project_root")
    if not isinstance(root, str) or not root:
        return 1
    print(root)
    return 0


def main(argv: list[str]) -> int:
    if len(argv) == 2 and argv[0] == "--read":
        return read_root(argv[1])
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    path, project_root = argv

    if os.path.exists(path):
        try:
            with open(path, "r", encoding="utf-8") as handle:
                existing = json.load(handle)
        except (OSError, json.JSONDecodeError) as error:
            print(f"ihar: state marker {path} is unreadable: {error}", file=sys.stderr)
            return 1
        marker = upgrade(existing, project_root)
        # An existing marker recording a different project means this state directory
        # belongs to something else: two roots hashed to one id, or the file was moved.
        # Guessing which one is right would attach a session to the wrong project.
        if marker["project_root"] != project_root:
            print(
                f"ihar: state marker {path} records project {marker['project_root']!r}, "
                f"not {project_root!r}",
                file=sys.stderr,
            )
            return 1
    else:
        marker = {
            "schema": SCHEMA,
            "project_root": project_root,
            "created": _now(),
            "vendors": [],
            "runtimes": {},
            "migrated_from": {},
        }

    try:
        jsonio.write("home-marker", path, marker)
    except (jsonio.SchemaError, OSError) as error:
        print(f"ihar: cannot write {path}: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
