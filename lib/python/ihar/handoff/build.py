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
# The transcript export is pointed at, never inlined, so this budget bounds the file on
# disk and the masking work, not the package. LLD section 20 owns its measurement.
TRANSCRIPT_BYTES = 2_000_000


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
    while max(len(_set_size(package)), len(render_markdown(package).encode())) > MAX_BYTES:
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


def _render_transcript(source: dict, messages: list[dict], masker: Masker) -> str:
    """Render the source session as Markdown, masked by the engine of step 4."""
    lines = [f"# Handoff transcript: {source['vendor']} / {source['vendor_session_id']}", ""]
    for message in messages:
        stamp = f" — {message['at']}" if message.get("at") else ""
        lines.extend([f"## {message.get('role', 'unknown')}{stamp}", "", message.get("text", ""), ""])
    return masker.mask("\n".join(lines).rstrip() + "\n")[0]


def _write_transcript(source: dict, messages: list[dict], masker: Masker,
                      budget: int, path: Path) -> dict:
    """Write the masked transcript within its byte budget, oldest messages dropped first."""
    kept = list(messages)
    truncated = False
    while kept:
        data = _render_transcript(source, kept, masker).encode()
        if len(data) <= budget:
            _atomic(path, data)
            return {"mode": "transcript", "file": str(path), "messages": len(messages),
                    "bytes": len(data), "truncated": truncated}
        kept.pop(0)
        truncated = True
    raise ValueError(f"no transcript message fits {budget} bytes")


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
    history = package.get("history") or {}
    if history.get("file"):
        note = "oldest messages were dropped to fit the budget" if history["truncated"] \
            else "complete"
        lines.extend(["## History", "",
                      f"The source transcript is at {history['file']}"
                      f" ({history['messages']} messages, {note}).",
                      "Read that file if this package is not enough; it is not repeated here.", ""])
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
                  token: str, masking_level: str, context: dict, ledger: dict | None = None,
                  history_mode: str = "summary", transcript: list | None = None,
                  transcript_bytes: int | None = None) -> dict:
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
        "history": {"mode": "summary", "file": None, "messages": 0,
                    "bytes": 0, "truncated": False},
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
    masker = Masker(masking_level)
    package = _mask(package, masker)
    package["masked"] = True
    directory = state / "handoff"
    # A transcript is a convenience on top of a package that already stands on its own, so a
    # render or masking failure degrades the mode instead of shipping an unmasked file or
    # aborting the switch. The package's own sanitisation above stays fail-closed.
    if history_mode == "transcript" and transcript:
        try:
            package["history"] = _write_transcript(
                source, transcript, masker, transcript_bytes or TRANSCRIPT_BYTES,
                directory / f"{source['ihar_id']}-transcript.md")
        except Exception as error:  # noqa: BLE001 - the mode degrades whatever the cause
            print(f"warning: the handoff transcript was not written ({error}); "
                  "the package falls back to summary mode", file=sys.stderr)
    _bound(package)
    check("handoff", package)
    markdown = render_markdown(package).encode()
    _atomic(directory / f"{source['ihar_id']}.json", _encoded(package))
    _atomic(directory / f"{source['ihar_id']}.md", markdown)
    _atomic(directory / "pending" / f"{token}.md", markdown)
    return package


def main(argv=None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--target", required=True, choices=("claude", "codex"))
    parser.add_argument("--cwd", required=True); parser.add_argument("--state", required=True)
    parser.add_argument("--token", required=True); parser.add_argument("--masking-level", required=True)
    parser.add_argument("--history", choices=("summary", "transcript"), default="summary")
    args = parser.parse_args(argv)
    payload = json.load(sys.stdin)
    budget = int(os.environ.get("IHAR_HANDOFF_TRANSCRIPT_BYTES") or TRANSCRIPT_BYTES)
    package = build_package(payload["source"], args.target, args.cwd, args.state,
                            args.token, args.masking_level, payload.get("context") or {},
                            payload.get("ledger"), args.history,
                            payload.get("transcript"), budget)
    print(json.dumps(package, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
