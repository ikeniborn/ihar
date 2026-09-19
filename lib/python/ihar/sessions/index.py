"""Append-only canonical session index (LLD 10.1, 10.2 and 10.4).

Failure class: fail-soft at shell callers. Functions raise so callers can warn.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import uuid
from pathlib import Path

from ihar.ids import uuid7
from ihar.jsonio import check

DISCOVERED_NAMESPACE = uuid.UUID("de7a9db8-3788-5e56-85cf-b839273cea2d")


def discovered_id(vendor: str, vendor_session_id: str) -> str:
    return str(uuid.uuid5(DISCOVERED_NAMESPACE, f"{vendor}:{vendor_session_id}"))


def append(path: str | Path, record: dict) -> None:
    check("session", record, partial=len(record) < 18)
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    with target.open("a", encoding="utf-8") as stream:
        stream.write(json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n")
    os.chmod(target, 0o600)


def fold(path: str | Path) -> dict[str, dict]:
    result: dict[str, dict] = {}
    try:
        stream = Path(path).open(encoding="utf-8")
    except OSError:
        return result
    with stream:
        for line in stream:
            try:
                row = json.loads(line)
                check("session", row, partial=len(row) < 18)
            except (ValueError, TypeError):
                continue
            current = result.setdefault(row["ihar_id"], {})
            current.update({key: value for key, value in row.items() if value is not None})
            for key, value in row.items():
                current.setdefault(key, value)
    return result


def ephemeral_ids(path: str | Path | None) -> set[str]:
    found: set[str] = set()
    if not path:
        return found
    try:
        lines = Path(path).read_text(encoding="utf-8").splitlines()
    except OSError:
        return found
    for line in lines:
        try:
            value = json.loads(line).get("ihar_id")
        except (ValueError, AttributeError):
            continue
        if isinstance(value, str):
            found.add(value)
    return found


def merge(path: str | Path, claude_rows: list[dict], codex_rows: list[dict], ephemeral: set[str]) -> list[dict]:
    indexed = fold(path)
    by_vendor = {(row.get("vendor"), row.get("vendor_session_id")): row for row in indexed.values()}
    for vendor_row in [*claude_rows, *codex_rows]:
        key = (vendor_row["vendor"], vendor_row["vendor_session_id"])
        current = by_vendor.get(key)
        if current is None:
            current = dict(vendor_row)
            current["ihar_id"] = discovered_id(*key)
            append(path, current)
            indexed[current["ihar_id"]] = current
            by_vendor[key] = current
        else:
            for field in ("title", "updated_at", "model", "git_branch", "cwd", "project"):
                if vendor_row.get(field) is not None:
                    current[field] = vendor_row[field]
    rows = [row for key, row in indexed.items() if key not in ephemeral]
    return sorted(rows, key=lambda row: row.get("updated_at") or "", reverse=True)


def write_claim(vendor: str, profile: str, runtime_hash: str, directory: str | Path,
                ihar_id: str | None = None) -> Path:
    target_dir = Path(directory); target_dir.mkdir(parents=True, exist_ok=True)
    claim_id = ihar_id or str(uuid7())
    record = {"schema": 1, "ihar_id": claim_id, "vendor": vendor, "profile": profile,
              "runtime_hash": runtime_hash, "counter": time.time_ns(),
              "created_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    check("launch-claim", record)
    target = target_dir / f"{record['counter']}-{claim_id}.json"
    target.write_text(json.dumps(record, sort_keys=True) + "\n", encoding="utf-8")
    os.chmod(target, 0o600)
    return target


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    add = sub.add_parser("append"); add.add_argument("path")
    launch = sub.add_parser("launch"); launch.add_argument("path"); launch.add_argument("ihar_id")
    launch.add_argument("vendor"); launch.add_argument("vendor_session_id")
    launch.add_argument("project"); launch.add_argument("cwd"); launch.add_argument("profile")
    show = sub.add_parser("list"); show.add_argument("path"); show.add_argument("--ephemeral")
    claim = sub.add_parser("claim"); claim.add_argument("vendor"); claim.add_argument("profile"); claim.add_argument("runtime_hash"); claim.add_argument("directory"); claim.add_argument("--ihar-id")
    resolve = sub.add_parser("resolve"); resolve.add_argument("path"); resolve.add_argument("ihar_id")
    inspect = sub.add_parser("show"); inspect.add_argument("path"); inspect.add_argument("ihar_id")
    handoff = sub.add_parser("handoff"); handoff.add_argument("path"); handoff.add_argument("source_id")
    handoff.add_argument("target_id"); handoff.add_argument("target_vendor"); handoff.add_argument("profile")
    handoff.add_argument("project"); handoff.add_argument("cwd")
    name = sub.add_parser("name"); name.add_argument("path"); name.add_argument("ihar_id"); name.add_argument("title")
    args = parser.parse_args(argv)
    if args.command == "append":
        append(args.path, json.load(sys.stdin)); return 0
    if args.command == "launch":
        now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        append(args.path, {"schema": 1, "ihar_id": args.ihar_id, "vendor": args.vendor,
                           "vendor_session_id": args.vendor_session_id, "project": args.project,
                           "cwd": args.cwd, "git_branch": None, "title": None, "model": None,
                           "profile": args.profile, "started_at": now, "updated_at": now,
                           "parent_ihar_id": None, "handoff_from": None, "handoff_to": None,
                           "tags": [], "source": "launch"})
        return 0
    if args.command == "list":
        rows = [row for key, row in fold(args.path).items() if key not in ephemeral_ids(args.ephemeral)]
        print(json.dumps(sorted(rows, key=lambda row: row.get("updated_at") or "", reverse=True), sort_keys=True)); return 0
    if args.command == "resolve":
        row = fold(args.path).get(args.ihar_id)
        if not row or not row.get("vendor_session_id"):
            return 1
        print(f"{row['vendor']}\t{row['vendor_session_id']}\t{row['profile']}"); return 0
    if args.command == "show":
        row = fold(args.path).get(args.ihar_id)
        if not row:
            return 1
        print(json.dumps(row, sort_keys=True)); return 0
    if args.command == "handoff":
        source = fold(args.path).get(args.source_id)
        if not source:
            return 1
        now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        append(args.path, {"schema": 1, "ihar_id": args.source_id, "vendor": source["vendor"],
                           "source": "launch", "handoff_to": args.target_id})
        append(args.path, {"schema": 1, "ihar_id": args.target_id, "vendor": args.target_vendor,
                           "vendor_session_id": None, "project": args.project, "cwd": args.cwd,
                           "git_branch": None, "title": None, "model": None, "profile": args.profile,
                           "started_at": now, "updated_at": now, "parent_ihar_id": args.source_id,
                           "handoff_from": args.source_id, "handoff_to": None, "tags": [], "source": "launch"})
        return 0
    if args.command == "name":
        row = fold(args.path).get(args.ihar_id)
        if not row:
            return 1
        append(args.path, {"schema": 1, "ihar_id": args.ihar_id, "vendor": row["vendor"],
                           "source": "launch", "title": args.title})
        return 0
    print(write_claim(args.vendor, args.profile, args.runtime_hash, args.directory, args.ihar_id)); return 0


if __name__ == "__main__":
    raise SystemExit(main())
