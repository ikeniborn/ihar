"""Claude session reader: local JSONL fallback (LLD 5.3 and 10.4)."""

from __future__ import annotations

import json
import os
import re
from pathlib import Path

from ihar.sessions.index import discovered_id

MAX_VERSION = 1


def _mangle(cwd: str) -> str:
    return re.sub(r"[^a-zA-Z0-9]", "-", cwd)


def _text(message) -> str | None:
    content = message.get("content") if isinstance(message, dict) else None
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        texts = [part.get("text") for part in content if isinstance(part, dict) and isinstance(part.get("text"), str)]
        return " ".join(texts) or None
    return None


def list_sessions(home: str | Path, cwd: str) -> list[dict]:
    directory = Path(home) / "projects" / _mangle(cwd)
    rows = []
    for path in directory.glob("*.jsonl") if directory.exists() else []:
        first = None; title = None; prompt = None; branch = None; actual_cwd = cwd
        try:
            for line in path.read_text(encoding="utf-8").splitlines():
                item = json.loads(line)
                if first is None:
                    first = item
                    if isinstance(item.get("version"), int) and item["version"] > MAX_VERSION:
                        raise ValueError("unsupported Claude JSONL version")
                actual_cwd = item.get("cwd") or actual_cwd
                branch = item.get("gitBranch") or branch
                if item.get("type") in ("custom-title", "ai-title"):
                    title = item.get("customTitle") or item.get("title") or title
                if prompt is None and item.get("type") == "user":
                    prompt = _text(item.get("message"))
        except (OSError, ValueError, json.JSONDecodeError):
            continue
        if first is None:
            continue
        sid = path.stem
        started = first.get("timestamp") or "1970-01-01T00:00:00Z"
        updated = __import__("datetime").datetime.fromtimestamp(path.stat().st_mtime, __import__("datetime").timezone.utc).isoformat().replace("+00:00", "Z")
        rows.append({"schema": 1, "ihar_id": discovered_id("claude", sid), "vendor": "claude",
                     "vendor_session_id": sid, "project": Path(actual_cwd).name, "cwd": actual_cwd,
                     "git_branch": branch, "title": title or ((prompt or "")[:80] or None), "model": None,
                     "profile": "standard", "started_at": started, "updated_at": updated,
                     "parent_ihar_id": None, "handoff_from": None, "handoff_to": None,
                     "tags": [], "source": "vendor"})
    return rows
