#!/usr/bin/env python3
"""Session reader and index contracts from LLD section 10."""

import json
import os
import sqlite3
import tempfile
from pathlib import Path

from ihar.sessions import claude, codex, index


def main():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)

        first = {
            "schema": 1, "ihar_id": index.discovered_id("claude", "c-1"),
            "vendor": "claude", "vendor_session_id": "c-1", "project": "ihar",
            "cwd": "/work/ihar", "git_branch": "main", "title": None,
            "model": None, "profile": "standard", "started_at": "2026-09-19T10:00:00Z",
            "updated_at": "2026-09-19T10:00:00Z", "parent_ihar_id": None,
            "handoff_from": None, "handoff_to": None, "tags": [], "source": "vendor",
        }
        index.append(root / "sessions.jsonl", first)
        index.append(root / "sessions.jsonl", {"schema": 1, "ihar_id": first["ihar_id"],
                     "vendor": "claude", "source": "hook", "title": "kept", "model": None})
        folded = index.fold(root / "sessions.jsonl")
        assert folded[first["ihar_id"]]["title"] == "kept"
        assert folded[first["ihar_id"]]["model"] is None

        claim_id = str(index.uuid7())
        claim = index.write_claim("claude", "standard", "deadbeef", root / "launches", claim_id)
        assert json.loads(claim.read_text(encoding="utf-8"))["ihar_id"] == claim_id

        project = root / "claude" / "projects" / "-work-ihar"
        project.mkdir(parents=True)
        transcript = project / "c-1.jsonl"
        transcript.write_text(
            '\n'.join([
                json.dumps({"version": 1, "timestamp": "2026-09-19T10:00:00Z",
                            "cwd": "/work/ihar", "gitBranch": "dev-s9",
                            "type": "user", "message": {"content": "first prompt"}}),
                json.dumps({"type": "custom-title", "customTitle": "chosen title"}),
            ]) + '\n', encoding="utf-8")
        rows = claude.list_sessions(root / "claude", "/work/ihar")
        assert rows[0]["vendor_session_id"] == "c-1"
        assert rows[0]["title"] == "chosen title"
        assert rows[0]["git_branch"] == "dev-s9"

        mapped = codex.map_thread({"id": "t-1", "cwd": "/work/ihar", "name": "thread",
                                   "createdAt": 1_758_278_400, "updatedAt": 1_758_282_000,
                                   "modelProvider": "openai", "source": "cli"})
        assert mapped["started_at"].endswith("Z") and mapped["updated_at"].endswith("Z")
        assert "modelProvider" not in mapped and mapped["source"] == "vendor"

        db = root / "state_5.sqlite"
        conn = sqlite3.connect(db)
        conn.execute("pragma user_version=5")
        conn.execute("create table threads(id text, cwd text, title text, name text, model text, git_branch text, created_at integer, updated_at integer)")
        conn.execute("insert into threads values('t-2','/work/ihar','sqlite title','named','gpt','dev-s9',1758278400,1758282000)")
        conn.commit(); conn.close()
        sqlite_rows = codex.list_sqlite(db, "/work/ihar")
        assert sqlite_rows[0]["vendor_session_id"] == "t-2"
        assert sqlite_rows[0]["source"] == "sqlite"
        assert sqlite_rows[0]["title"] == "named"
        assert sqlite_rows[0]["model"] == "gpt" and sqlite_rows[0]["git_branch"] == "dev-s9"

        merged = index.merge(root / "sessions.jsonl", rows, [mapped, *sqlite_rows], set())
        assert [row["updated_at"] for row in merged] == sorted(
            [row["updated_at"] for row in merged], reverse=True)
        assert all("content" not in row for row in merged)

    print("PASS sessions readers and index")


if __name__ == "__main__":
    main()
