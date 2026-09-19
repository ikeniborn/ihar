#!/usr/bin/env python3
"""Observable handoff package contracts from LLD section 11."""

import json
import os
import subprocess
import tempfile
import time
from pathlib import Path

from ihar.handoff.build import build_package
from ihar.handoff.export import export_context
from ihar.handoff.distill import codex as distill_codex


def git(cwd, *args):
    subprocess.run(["git", *args], cwd=cwd, check=True, stdout=subprocess.DEVNULL)


def main():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / "repo"
        state = Path(tmp) / "state"
        root.mkdir()
        git(root, "init", "-q")
        git(root, "config", "user.email", "test@example.invalid")
        git(root, "config", "user.name", "Test")
        (root / "tracked").write_text("base\n", encoding="utf-8")
        (root / ".iwiki.toml").write_text('primary = "ihar"\n', encoding="utf-8")
        git(root, "add", "tracked", ".iwiki.toml")
        git(root, "commit", "-qm", "base")
        git(root, "branch", "-m", "dev-unified-harness-implementation-s10")
        for number in range(500):
            (root / f"changed-{number:03}.txt").write_text("x\n", encoding="utf-8")

        source = {
            "ihar_id": "0199f3a1-7c2e-7a41-9b0d-3f9a1cbd2e41",
            "vendor": "claude",
            "vendor_session_id": "claude-session",
        }
        context = {
            "open_items": ["- [ ] explicit item"],
            "decisions": ["Use the shared masking engine"],
            "decisions_heuristic": ["Решили оставить формат узким"],
            "recent_messages": [{"role": "user", "text": "mail me at dev@example.com"}],
        }
        first = build_package(source, "codex", root, state, "target-one", "standard", context)
        second = build_package(source, "codex", root, state, "target-two", "standard", context)

        encoded = json.dumps(first, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
        assert len(encoded) <= 8192
        assert len((state / "handoff" / "pending" / "target-one.md").read_bytes()) <= 8192
        assert first["bytes"] == len(encoded)
        assert first["git"]["files_changed"] == 500
        assert first["files_touched_truncated"] is True
        assert len(first["files_touched"]) <= 50
        assert first["decisions"] == ["Use the shared masking engine"]
        assert first["decisions_heuristic"] == ["Решили оставить формат узким"]
        assert first["masked"] is True
        assert first["ledger"]["topic"] == "unified-harness-implementation"
        assert "dev@example.com" not in json.dumps(first)
        assert (state / "handoff" / "pending" / "target-one.md").exists()
        assert (state / "handoff" / "pending" / "target-two.md").exists()
        assert first["source_ihar_id"] == second["source_ihar_id"]
        assert first["created_at"] <= second["created_at"]
        assert oct((state / "handoff" / f"{source['ihar_id']}.json").stat().st_mode & 0o777) == "0o600"

        transcript_home = root / "vendor"
        transcript_home.mkdir()
        (transcript_home / "session-1.jsonl").write_text("\n".join([
            json.dumps({"ihar": {"decisions": ["Keep packages bounded"]}}),
            json.dumps({"message": {"role": "user", "content": "- [ ] ship the hook"}}),
            json.dumps({"message": {"role": "assistant", "content": "Решили оставить простой путь."}}),
            json.dumps({"message": {"role": "assistant", "content": "We agreed to test the boundary."}}),
        ]) + "\n", encoding="utf-8")
        exported = export_context("claude", transcript_home, "session-1")
        assert exported["decisions"] == ["Keep packages bounded"]
        assert exported["open_items"] == ["ship the hook"]
        assert exported["decisions_heuristic"] == ["We agreed to test the boundary."]

        fake = root / "fake-codex"
        fork_id = "0199f3a1-7c2e-7a41-9b0d-3f9a1cbd2e42"
        fake.write_text(f"""#!/usr/bin/env bash
if [[ "$1" == archive ]]; then exit 0; fi
printf '{{"thread_id":"{fork_id}"}}\\n'
grep -q '{fork_id}' "$EPHEMERAL" || exit 9
printf '{{"message":"fork summary"}}\\n'
""", encoding="utf-8")
        fake.chmod(0o755)
        ephemeral = state / "ephemeral.jsonl"
        os.environ["EPHEMERAL"] = str(ephemeral)
        started = time.monotonic()
        assert distill_codex(str(fake), str(root), "source", ephemeral, 5) == "fork summary"
        assert time.monotonic() - started < 1
        assert fork_id in ephemeral.read_text(encoding="utf-8")

    print("PASS handoff builder")


if __name__ == "__main__":
    main()
