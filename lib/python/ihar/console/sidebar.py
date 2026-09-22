"""What the console window shows beside the terminal (LLD 13.2).

Two read-only views, both assembled per request and neither of them a store:

* the sidebar, which is every project state on this machine, the sessions each one's
  index knows, the tabs this broker runs and the badge the status hook last wrote;
* the thread projection, which follows the handoff links of one chain and renders the
  sessions in order with a marker where each handoff cut the context.

The projection reads the vendor transcripts through the same reader the handoff builder
uses and keeps nothing: a rotated vendor session leaves a labelled gap rather than a
fabricated one, which is the deliberate consequence of ihar not owning transcripts.

Failure class: fail-soft throughout. A project whose index cannot be read is reported
as unreadable and never removes the others from the window.
"""

from __future__ import annotations

import json
import os
import time
from pathlib import Path

from ..handoff.export import export_transcript
from ..sessions import claude as claude_reader
from ..sessions import codex as codex_reader
from ..sessions import index as session_index

# The sidebar is polled; rebuilding every vendor read on each poll would spend a
# process' worth of work to redraw a list that changes on human timescales.
CACHE_SECONDS = 5.0


def _read_json(path: Path) -> dict | None:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def projects(state_root: Path) -> list[dict]:
    """Every project state under the root, named by its own marker.

    The marker is the authority on which project a state id belongs to (LLD 4.1); a
    directory without a valid one is skipped rather than guessed at.
    """
    found = []
    try:
        names = sorted(os.listdir(state_root))
    except OSError:
        return found
    for name in names:
        marker = _read_json(state_root / name / "home.json")
        if not marker or not marker.get("project_root"):
            continue
        found.append({"state_id": name, "project_root": marker["project_root"],
                      "vendors": marker.get("vendors") or []})
    return found


def statuses(state: Path) -> dict[tuple[str, str], dict]:
    """The last badge each session wrote, keyed the way the index joins."""
    out = {}
    directory = state / "status"
    try:
        names = os.listdir(directory)
    except OSError:
        return out
    for name in names:
        if not name.endswith(".json"):
            continue
        record = _read_json(directory / name)
        if record and record.get("vendor_session_id"):
            out[(record.get("vendor"), record["vendor_session_id"])] = record
    return out


def sessions(state: Path, project_root: str) -> list[dict]:
    """The project's sessions, merged from the index and both vendor stores (LLD 10.4).

    The vendor readers used here are the file and SQLite ones only: the broker starts no
    vendor process to draw a list, so a sidebar refresh cannot become a launch.
    """
    index_path = state / "sessions.jsonl"
    claude_rows = claude_reader.list_sessions(state / "st" / "claude", project_root)
    codex_rows = codex_reader.list_sqlite(state / "st" / "codex" / "state_5.sqlite", project_root)
    ephemeral = session_index.ephemeral_ids(state / "ephemeral.jsonl")
    return session_index.merge(index_path, claude_rows, codex_rows, ephemeral)


class Sidebar:
    """Assembles the window's list, with a short cache so polling stays cheap."""

    def __init__(self, state_root: Path):
        self.state_root = state_root
        self._cache: dict | None = None
        self._at = 0.0

    def build(self, tabs: list[dict], force: bool = False) -> dict:
        now = time.monotonic()
        if self._cache is None or force or now - self._at > CACHE_SECONDS:
            self._cache = {"schema": 1, "projects": self._projects()}
            self._at = now
        view = json.loads(json.dumps(self._cache))
        live = {tab.get("ihar_id"): tab for tab in tabs}
        for project in view["projects"]:
            for row in project["sessions"]:
                tab = live.get(row["ihar_id"])
                row["tab"] = {"sid": tab["sid"], "exit_code": tab.get("exit_code")} if tab else None
        return view

    def _projects(self) -> list[dict]:
        out = []
        for project in projects(self.state_root):
            state = self.state_root / project["state_id"]
            entry = dict(project)
            try:
                rows = sessions(state, project["project_root"])
                badges = statuses(state)
            except Exception as error:  # noqa: BLE001 - one unreadable project, not the window
                entry["sessions"] = []
                entry["error"] = str(error)
                out.append(entry)
                continue
            entry["sessions"] = [{
                "ihar_id": row.get("ihar_id"),
                "vendor": row.get("vendor"),
                "vendor_session_id": row.get("vendor_session_id"),
                "title": row.get("title"),
                "model": row.get("model"),
                "git_branch": row.get("git_branch"),
                "profile": row.get("profile"),
                "updated_at": row.get("updated_at"),
                "handoff_from": row.get("handoff_from"),
                "handoff_to": row.get("handoff_to"),
                "status": (badges.get((row.get("vendor"), row.get("vendor_session_id"))) or {})
                          .get("state", "unknown"),
            } for row in rows]
            out.append(entry)
        return out


def chain(records: dict[str, dict], ihar_id: str) -> list[dict]:
    """The sessions one piece of work passed through, oldest first.

    Walks `handoff_from` back to the first session and `handoff_to` forward to the last,
    so selecting any session in a chain shows the whole chain.
    """
    first = ihar_id
    seen = {ihar_id}
    while True:
        record = records.get(first) or {}
        previous = record.get("handoff_from")
        if not previous or previous in seen or previous not in records:
            break
        seen.add(previous)
        first = previous
    ordered = []
    current = first
    while current and current in records:
        ordered.append(records[current])
        following = records[current].get("handoff_to")
        if not following or following in {row["ihar_id"] for row in ordered}:
            break
        current = following
    return ordered


def _marker(state: Path, source_id: str) -> dict:
    """What the handoff between two sessions actually carried."""
    package = _read_json(state / "handoff" / f"{source_id}.json") or {}
    history = package.get("history") or {}
    return {"kind": "handoff", "source_ihar_id": source_id,
            "target_vendor": package.get("target_vendor"),
            "bytes": package.get("bytes"), "masking_level": package.get("masking_level"),
            "history_mode": history.get("mode"), "history_file": history.get("file"),
            "note": "the next agent received this package, not the messages above"}


def thread(state: Path, ihar_id: str, limit: int = 400) -> dict:
    """Render one chain as a single readable thread (R10).

    Assembled per request and held nowhere: this is a projection of the vendor stores,
    not a transcript ihar owns.
    """
    records = session_index.fold(state / "sessions.jsonl")
    ordered = chain(records, ihar_id)
    if not ordered:
        return {"schema": 1, "ihar_id": ihar_id, "items": [],
                "gaps": [{"ihar_id": ihar_id, "reason": "no such session in this project"}]}
    items: list[dict] = []
    gaps: list[dict] = []
    for position, record in enumerate(ordered):
        vendor = record.get("vendor") or ""
        session_id = record.get("vendor_session_id") or ""
        messages = []
        if session_id:
            try:
                messages = export_transcript(vendor, state / "st" / vendor, session_id)
            except OSError as error:
                messages = []
                gaps.append({"ihar_id": record.get("ihar_id"), "reason": str(error)})
        if session_id and not messages:
            gaps.append({"ihar_id": record.get("ihar_id"),
                         "reason": "the vendor store no longer holds this session"})
        items.extend({"kind": "message", "ihar_id": record.get("ihar_id"), "vendor": vendor,
                      "role": message.get("role"), "at": message.get("at"),
                      "text": message.get("text")} for message in messages)
        if position + 1 < len(ordered):
            items.append(_marker(state, record.get("ihar_id") or ""))
    return {"schema": 1, "ihar_id": ihar_id,
            "sessions": [row.get("ihar_id") for row in ordered],
            "items": items[:limit], "truncated": len(items) > limit, "gaps": gaps}
