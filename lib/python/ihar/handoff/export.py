"""Extract a small vendor-neutral context from native JSONL transcripts."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path


def _text(value):
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        return " ".join(part.get("text", "") for part in value if isinstance(part, dict)).strip()
    if isinstance(value, dict):
        return _text(value.get("content"))
    return ""


def _candidates(home: Path, session_id: str) -> list[Path]:
    return [path for path in home.rglob("*.jsonl") if session_id in path.name]


def export_transcript(vendor: str, home: str | Path, session_id: str) -> list[dict]:
    """Every user and assistant message of one session, oldest first (LLD 11.2 step 6).

    Unlike `export_context`, nothing is dropped here: the byte budget belongs to the
    builder, which is where the truncation is recorded and reported to the reader.
    """
    messages = []
    for path in _candidates(Path(home), session_id)[:1]:
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            try:
                item = json.loads(line)
            except ValueError:
                continue
            message = item.get("message") or item.get("payload") or item
            role = message.get("role") if isinstance(message, dict) else None
            text = _text(message)
            if role in ("user", "assistant") and text:
                messages.append({"role": role, "text": text, "at": item.get("timestamp") or ""})
    return messages


def export_context(vendor: str, home: str | Path, session_id: str) -> dict:
    home = Path(home)
    candidates = _candidates(home, session_id)
    messages = []
    open_items = []
    decisions = []
    heuristic = []
    for path in candidates[:1]:
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            try:
                item = json.loads(line)
            except ValueError:
                continue
            structured = item.get("ihar") if isinstance(item.get("ihar"), dict) else item
            for decision in structured.get("decisions", []) if isinstance(structured, dict) else []:
                if isinstance(decision, str): decisions.append(decision)
            message = item.get("message") or item.get("payload") or item
            role = message.get("role") if isinstance(message, dict) else None
            text = _text(message)
            if role in ("user", "assistant") and text:
                messages.append({"role": role, "text": text})
                open_items.extend(re.findall(r"^- \[ \] (.+)$", text, re.MULTILINE))
                for sentence in re.split(r"(?<=[.!?])\s+", text):
                    if re.search(r"\b(decided|we will|chosen|agreed|instead of)\b", sentence, re.I):
                        heuristic.append(sentence.strip())
    return {"open_items": list(dict.fromkeys(open_items)),
            "decisions": list(dict.fromkeys(decisions)),
            "decisions_heuristic": list(dict.fromkeys(heuristic)),
            "recent_messages": messages[-6:]}


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(); parser.add_argument("vendor", choices=("claude", "codex"))
    parser.add_argument("home"); parser.add_argument("session_id")
    parser.add_argument("--transcript", action="store_true",
                        help="print the whole session instead of the bounded context")
    args = parser.parse_args(argv)
    reader = export_transcript if args.transcript else export_context
    print(json.dumps(reader(args.vendor, args.home, args.session_id), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
