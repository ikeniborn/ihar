"""Build bounded, sanitised handoff packages (LLD section 11)."""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
import time
import argparse
import sys
import re
from pathlib import Path

from ihar.jsonio import check
from ihar.mask.engine import Masker

MAX_BYTES = 8192


def _git(cwd: Path, *args: str) -> str:
    result = subprocess.run(["git", *args], cwd=cwd, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False)
    return result.stdout.strip() if result.returncode == 0 else ""


def _git_state(cwd: Path) -> tuple[dict, list[str]]:
    status = _git(cwd, "status", "--porcelain").splitlines()
    files = [line[3:] for line in status if len(line) > 3]
    shortstat = _git(cwd, "diff", "--shortstat", "HEAD")
    return ({"branch": _git(cwd, "rev-parse", "--abbrev-ref", "HEAD") or None,
             "head": _git(cwd, "rev-parse", "HEAD") or None,
             "dirty": bool(status), "shortstat": shortstat,
             "files_changed": len(files)}, files)


def _mask(value, masker: Masker):
    if isinstance(value, str):
        return masker.mask(value)[0]
    if isinstance(value, list):
        return [_mask(item, masker) for item in value]
    if isinstance(value, dict):
        return {key: _mask(item, masker) for key, item in value.items()}
    return value


def _encoded(package: dict) -> bytes:
    return json.dumps(package, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def _set_size(package: dict) -> bytes:
    while True:
        size = len(_encoded(package))
        if package.get("bytes") == size:
            break
        package["bytes"] = size
    return _encoded(package)


def _bound(package: dict) -> None:
    package["files_touched_truncated"] = len(package["files_touched"]) > 50
    package["files_touched"] = package["files_touched"][:50]
    while len(_set_size(package)) > MAX_BYTES:
        if package["recent_messages"]:
            package["recent_messages"].pop(0)
        elif package.get("summary"):
            package.pop("summary")
        elif package["decisions_heuristic"]:
            package["decisions_heuristic"].pop()
        elif len(package["decisions"]) > 20:
            package["decisions"] = package["decisions"][:20]
        elif len(package["open_items"]) > 30:
            package["open_items"] = package["open_items"][:30]
        elif package["files_touched"]:
            package["files_touched"].pop()
            package["files_touched_truncated"] = True
        else:
            raise ValueError("handoff identity and git state exceed 8192 bytes")


def render_markdown(package: dict) -> str:
    lines = ["# ihar handoff", "", f"From: {package['source_vendor']} / {package['source_session_id']}",
             f"To: {package['target_vendor']}", f"Project: {package['project']}",
             f"Branch: {package['git']['branch'] or 'detached'}", f"HEAD: {package['git']['head'] or 'none'}", ""]
    for heading, key in (("Open items", "open_items"), ("Decisions", "decisions"),
                         ("Advisory heuristic decisions", "decisions_heuristic"),
                         ("Files touched", "files_touched")):
        values = package.get(key) or []
        if values:
            lines.extend([f"## {heading}", "", *[f"- {value}" for value in values], ""])
    if package.get("summary"):
        lines.extend(["## Summary", "", package["summary"], ""])
    return "\n".join(lines).rstrip() + "\n"


def _atomic(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data)
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def build_package(source: dict, target_vendor: str, cwd: str | Path, state: str | Path,
                  token: str, masking_level: str, context: dict, ledger: dict | None = None) -> dict:
    cwd = Path(cwd)
    state = Path(state)
    git_state, files = _git_state(cwd)
    package = {
        "schema": 1, "source_vendor": source["vendor"],
        "source_session_id": source["vendor_session_id"], "source_ihar_id": source["ihar_id"],
        "target_vendor": target_vendor,
        "created_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "project": cwd.name, "cwd": str(cwd), "git": git_state,
        "files_touched": files, "files_touched_truncated": False,
        "open_items": list(context.get("open_items") or []),
        "decisions": list(context.get("decisions") or []),
        "decisions_heuristic": list(context.get("decisions_heuristic") or []),
        "recent_messages": list(context.get("recent_messages") or []),
        "masked": False, "masking_level": masking_level, "bytes": 0,
    }
    if ledger is None and (cwd / ".iwiki.toml").is_file():
        branch = git_state["branch"] or ""
        if branch.startswith("dev-"):
            topic = re.sub(r"-s\d+$", "", branch[4:])
            ledger = {"topic": topic, "task_page": f"reference/tasks/{topic}", "slices_open": []}
    if ledger:
        package["ledger"] = ledger
    if context.get("summary"):
        package["summary"] = context["summary"]
    package = _mask(package, Masker(masking_level))
    package["masked"] = True
    _bound(package)
    check("handoff", package)
    markdown = render_markdown(package).encode()
    directory = state / "handoff"
    _atomic(directory / f"{source['ihar_id']}.json", _encoded(package) + b"\n")
    _atomic(directory / f"{source['ihar_id']}.md", markdown)
    _atomic(directory / "pending" / f"{token}.md", markdown)
    return package


def main(argv=None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--target", required=True, choices=("claude", "codex"))
    parser.add_argument("--cwd", required=True); parser.add_argument("--state", required=True)
    parser.add_argument("--token", required=True); parser.add_argument("--masking-level", required=True)
    args = parser.parse_args(argv)
    payload = json.load(sys.stdin)
    package = build_package(payload["source"], args.target, args.cwd, args.state,
                            args.token, args.masking_level, payload.get("context") or {},
                            payload.get("ledger"))
    print(json.dumps(package, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
