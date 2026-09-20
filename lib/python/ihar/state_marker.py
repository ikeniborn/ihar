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


def validate_root(path: str) -> int:
    """Validate a current ihar marker before an explicit cleanup target is used."""
    try:
        marker = jsonio.read("home-marker", path)
    except (OSError, jsonio.SchemaError):
        return 1
    print(marker["project_root"])
    return 0


def record_migration(path: str, vendor: str, source: str) -> int:
    """Record one successfully copied legacy home in the project marker."""
    if vendor not in {"claude", "codex"} or not source:
        return 2
    try:
        marker = jsonio.read("home-marker", path)
        marker["migrated_from"][vendor] = source
        jsonio.write("home-marker", path, marker)
    except (jsonio.SchemaError, OSError) as error:
        print(f"ihar: cannot record migration in {path}: {error}", file=sys.stderr)
        return 1
    return 0


def touch_runtime(path: str, runtime_hash: str, profile: str, vendor: str) -> int:
    """Record authoritative use of one configuration-keyed runtime."""
    if vendor not in {"claude", "codex"}:
        return 2
    try:
        marker = jsonio.read("home-marker", path)
        now = _now()
        current = marker["runtimes"].get(runtime_hash, {})
        marker["runtimes"][runtime_hash] = {
            "profile": profile,
            "created": current.get("created", now),
            "last_used": now,
        }
        marker["vendors"] = sorted(set(marker["vendors"]) | {vendor})
        jsonio.write("home-marker", path, marker)
    except (jsonio.SchemaError, OSError) as error:
        print(f"ihar: cannot refresh runtime use in {path}: {error}", file=sys.stderr)
        return 1
    return 0


def expired_runtimes(path: str, days: str) -> int:
    """Print runtime hashes whose recorded last use predates the cutoff."""
    try:
        age = int(days)
        if age < 0:
            raise ValueError
        marker = jsonio.read("home-marker", path)
        cutoff = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=age)
        for runtime_hash, record in sorted(marker["runtimes"].items()):
            last_used = datetime.datetime.fromisoformat(record["last_used"].replace("Z", "+00:00"))
            if last_used < cutoff:
                print(runtime_hash)
    except (ValueError, jsonio.SchemaError, OSError) as error:
        print(f"ihar: cannot read runtime ages from {path}: {error}", file=sys.stderr)
        return 1
    return 0


def remove_runtimes(path: str, runtime_hashes: list[str]) -> int:
    """Forget runtime records only after their directories were removed."""
    try:
        marker = jsonio.read("home-marker", path)
        for runtime_hash in runtime_hashes:
            marker["runtimes"].pop(runtime_hash, None)
        jsonio.write("home-marker", path, marker)
    except (jsonio.SchemaError, OSError) as error:
        print(f"ihar: cannot update runtime inventory in {path}: {error}", file=sys.stderr)
        return 1
    return 0


def main(argv: list[str]) -> int:
    if len(argv) == 2 and argv[0] == "--read":
        return read_root(argv[1])
    if len(argv) == 2 and argv[0] == "--validate-root":
        return validate_root(argv[1])
    if len(argv) == 4 and argv[0] == "--record-migration":
        return record_migration(argv[1], argv[2], argv[3])
    if len(argv) == 5 and argv[0] == "--touch-runtime":
        return touch_runtime(argv[1], argv[2], argv[3], argv[4])
    if len(argv) == 3 and argv[0] == "--expired-runtimes":
        return expired_runtimes(argv[1], argv[2])
    if len(argv) >= 3 and argv[0] == "--remove-runtimes":
        return remove_runtimes(argv[1], argv[2:])
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
