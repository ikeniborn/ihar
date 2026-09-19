"""Codex app-server and SQLite session readers (LLD 5.4 and 10.4)."""

from __future__ import annotations

import datetime as dt
import sqlite3
from pathlib import Path

from ihar.sessions.index import discovered_id


def _timestamp(value) -> str:
    if isinstance(value, str) and value.endswith("Z"):
        return value
    return dt.datetime.fromtimestamp(float(value), dt.timezone.utc).isoformat().replace("+00:00", "Z")


def map_thread(thread: dict, source: str = "vendor") -> dict:
    sid = str(thread["id"])
    cwd = thread.get("cwd") or "."
    return {"schema": 1, "ihar_id": discovered_id("codex", sid), "vendor": "codex",
            "vendor_session_id": sid, "project": Path(cwd).name, "cwd": cwd,
            "git_branch": thread.get("gitBranch") or thread.get("git_branch"), "title": thread.get("name") or thread.get("title"),
            "model": thread.get("model"), "profile": "standard",
            "started_at": _timestamp(thread.get("createdAt") or thread.get("created_at") or 0),
            "updated_at": _timestamp(thread.get("updatedAt") or thread.get("updated_at") or 0),
            "parent_ihar_id": None, "handoff_from": None, "handoff_to": None,
            "tags": [], "source": source}


def list_appserver(client, cwd: str) -> list[dict]:
    rows = []; cursor = None
    while True:
        params = {"cwd": cwd, "limit": 200, "sortKey": "updated_at", "sortDirection": "desc", "archived": False}
        if cursor: params["cursor"] = cursor
        result = client.request("thread/list", params) or {}
        rows.extend(map_thread(row) for row in result.get("data", []))
        cursor = result.get("nextCursor")
        if not cursor: return rows


def list_sqlite(path: str | Path, cwd: str) -> list[dict]:
    uri = f"file:{Path(path)}?mode=ro"
    try:
        connection = sqlite3.connect(uri, uri=True)
        version = connection.execute("pragma user_version").fetchone()[0]
        if version > 5: return []
        columns = {row[1] for row in connection.execute("pragma table_info(threads)")}
        required = {"id", "cwd", "created_at", "updated_at"}
        if not required <= columns: return []
        selected = ["id", "cwd", "created_at", "updated_at"]
        selected += [name for name in ("title", "name", "model", "git_branch") if name in columns]
        query = f"select {','.join(selected)} from threads where cwd=? order by updated_at desc"
        rows = []
        for values in connection.execute(query, (cwd,)):
            raw = dict(zip(selected, values))
            if raw.get("name"):
                raw["title"] = raw["name"]
            rows.append(map_thread(raw, "sqlite"))
        return rows
    except sqlite3.Error:
        return []
    finally:
        if "connection" in locals(): connection.close()
