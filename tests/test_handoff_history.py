#!/usr/bin/env python3
"""Handoff history modes from LLD section 11.1 and 11.2, phase S14."""

import io
import json
import subprocess
import tempfile
from contextlib import redirect_stderr
from pathlib import Path

from ihar.handoff import build as build_module
from ihar.handoff.build import MAX_BYTES, build_package
from ihar.handoff.export import export_transcript

SECRET = "sk-ant-abcdefghijklmnopqrstuvwxyz0123"
PASS = FAIL = 0


def check(label, condition):
    global PASS, FAIL
    if condition:
        PASS += 1
    else:
        FAIL += 1
        print(f"FAIL {label}")


def git(cwd, *args):
    subprocess.run(["git", *args], cwd=cwd, check=True, stdout=subprocess.DEVNULL)


def repository(tmp):
    root = Path(tmp) / "repo"
    root.mkdir()
    git(root, "init", "-q")
    git(root, "config", "user.email", "test@example.invalid")
    git(root, "config", "user.name", "Test")
    (root / "tracked").write_text("base\n", encoding="utf-8")
    git(root, "add", "tracked")
    git(root, "commit", "-qm", "base")
    return root


def transcript_home(tmp, session_id, messages):
    home = Path(tmp) / "home"
    home.mkdir(parents=True, exist_ok=True)
    path = home / f"{session_id}.jsonl"
    with path.open("w", encoding="utf-8") as stream:
        for index, (role, text) in enumerate(messages):
            record = {"timestamp": f"2026-09-21T10:{index:02d}:00Z",
                      "message": {"role": role, "content": text}}
            stream.write(json.dumps(record) + "\n")
    return home


SOURCE = {"vendor": "claude", "vendor_session_id": "ses-1",
          "ihar_id": "0199f3a1-7c2e-7a41-9b0d-3f9a1cbd2e41"}


def build(root, state, context, **kwargs):
    return build_package(SOURCE, "codex", root, state, "0199f3a1-7c2e-7a41-9b0d-3f9a1cbd2e42",
                         kwargs.pop("masking_level", "standard"), context, **kwargs)


def main():
    global PASS, FAIL
    with tempfile.TemporaryDirectory() as tmp:
        root = repository(tmp)
        state = Path(tmp) / "state"
        context = {"open_items": ["finish the reader"], "decisions": [],
                   "decisions_heuristic": [], "recent_messages": [{"role": "user", "text": "hello"}]}

        # A reader that returns the whole session, oldest first, with timestamps.
        home = transcript_home(tmp, "ses-1", [("user", "first question"),
                                              ("assistant", "first answer"),
                                              ("user", f"the key is {SECRET}")])
        messages = export_transcript("claude", home, "ses-1")
        check("transcript reader returns every message", len(messages) == 3)
        check("transcript reader keeps order", [item["role"] for item in messages]
              == ["user", "assistant", "user"])
        check("transcript reader carries timestamps", messages[0]["at"] == "2026-09-21T10:00:00Z")

        # summary is the default and writes no transcript file.
        package = build(root, state, context)
        check("default mode is summary", package["history"]["mode"] == "summary")
        check("summary mode has no file", package["history"]["file"] is None)
        check("summary mode counts nothing", package["history"]["messages"] == 0)
        check("summary package is bounded", package["bytes"] <= MAX_BYTES)
        check("summary mode writes no transcript",
              not list((state / "handoff").glob("*-transcript.md")))

        # transcript mode renders beside the package and points at it.
        package = build(root, state, context, history_mode="transcript", transcript=messages)
        exported = Path(package["history"]["file"])
        check("transcript mode records the file", exported.name.endswith("-transcript.md"))
        check("transcript file exists", exported.is_file())
        check("transcript file is owner-only", oct(exported.stat().st_mode & 0o777) == "0o600")
        check("transcript mode counts the messages", package["history"]["messages"] == 3)
        check("transcript package stays bounded", package["bytes"] <= MAX_BYTES)
        rendered = exported.read_text(encoding="utf-8")
        check("transcript keeps the conversation order",
              rendered.index("first question") < rendered.index("first answer"))
        check("planted secret never reaches the transcript", SECRET not in rendered)
        check("transcript is masked by the same engine", "REDACTED" in rendered)
        markdown = (state / "handoff" / f"{SOURCE['ihar_id']}.md").read_text(encoding="utf-8")
        check("package points at the transcript", exported.name in markdown)
        check("package does not inline the transcript", "first answer" not in markdown)

        # the byte budget truncates oldest first and says so.
        package = build(root, state, context, history_mode="transcript",
                        transcript=messages, transcript_bytes=120)
        rendered = Path(package["history"]["file"]).read_text(encoding="utf-8")
        check("budget marks the transcript truncated", package["history"]["truncated"] is True)
        check("budget keeps the real message count", package["history"]["messages"] == 3)
        check("budget drops the oldest message", "first question" not in rendered)
        check("budget respects its bound", package["history"]["bytes"] <= 120)

        # a render or masking failure degrades instead of writing an unmasked file.
        for name in list((state / "handoff").glob("*-transcript.md")):
            name.unlink()
        original = build_module._render_transcript

        def exploding(*_args, **_kwargs):
            raise RuntimeError("masking engine unavailable")

        build_module._render_transcript = exploding
        try:
            captured = io.StringIO()
            with redirect_stderr(captured):
                package = build(root, state, context, history_mode="transcript", transcript=messages)
        finally:
            build_module._render_transcript = original
        check("failure degrades to summary", package["history"]["mode"] == "summary")
        check("failure leaves no file reference", package["history"]["file"] is None)
        check("failure writes no transcript",
              not list((state / "handoff").glob("*-transcript.md")))
        check("failure is named on stderr", "transcript" in captured.getvalue().lower())

        # an empty session is a summary, not an empty file.
        package = build(root, state, context, history_mode="transcript", transcript=[])
        check("empty transcript degrades to summary", package["history"]["mode"] == "summary")

    print(f"PASS={PASS} FAIL={FAIL}")
    return 1 if FAIL else 0


if __name__ == "__main__":
    raise SystemExit(main())
