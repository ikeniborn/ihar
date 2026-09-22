"""Run an optional source-session fork without mutating the source transcript."""

from __future__ import annotations

import argparse
import json
import os
import selectors
import subprocess
import time
from pathlib import Path

from ihar.ids import uuid7

PROMPT = "Summarise current work for another coding agent: goal, completed work, open items, constraints, and decisions."


def _ephemeral(path: Path, ihar_id: str, vendor_session_id: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as stream:
        stream.write(json.dumps({"ihar_id": ihar_id, "vendor_session_id": vendor_session_id}) + "\n")
    os.chmod(path, 0o600)


def claude(binary: str, home: str, session: str, ephemeral: Path, timeout: int) -> str:
    fork_id = str(uuid7())
    _ephemeral(ephemeral, fork_id, fork_id)
    result = subprocess.run([binary, "-p", "--resume", session, "--fork-session",
                             "--session-id", fork_id, "--output-format", "text", PROMPT],
                            env={**os.environ, "CLAUDE_CONFIG_DIR": home}, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=timeout)
    return result.stdout.strip() if result.returncode == 0 else ""


def codex(binary: str, home: str, session: str, ephemeral: Path, timeout: int) -> str:
    process = subprocess.Popen([binary, "exec", "fork", session, "--json", PROMPT],
                               env={**os.environ, "CODEX_HOME": home}, text=True,
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    selector = selectors.DefaultSelector(); selector.register(process.stdout, selectors.EVENT_READ)
    deadline = time.monotonic() + timeout; fork_id = None; messages = []
    try:
        while time.monotonic() < deadline:
            ready = selector.select(0.2)
            if not ready and process.poll() is not None:
                break
            for key, _ in ready:
                line = key.fileobj.readline()
                if not line:
                    selector.unregister(key.fileobj)
                    continue
                try: event = json.loads(line)
                except ValueError: continue
                candidate = event.get("thread_id") or event.get("threadId")
                if not candidate and isinstance(event.get("thread"), dict):
                    candidate = event["thread"].get("id")
                if candidate and fork_id is None:
                    fork_id = str(candidate); _ephemeral(ephemeral, fork_id, fork_id)
                text = event.get("text") or event.get("message")
                if isinstance(text, str) and text: messages.append(text)
            if not selector.get_map() and process.poll() is not None:
                break
        if process.poll() is None: process.kill()
        process.wait()
    finally:
        selector.close()
    if fork_id:
        subprocess.run([binary, "archive", fork_id], env={**os.environ, "CODEX_HOME": home},
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    return "\n".join(messages).strip()


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(); parser.add_argument("vendor", choices=("claude", "codex"))
    parser.add_argument("binary"); parser.add_argument("home"); parser.add_argument("session")
    parser.add_argument("state"); parser.add_argument("--timeout", type=int, default=60)
    args = parser.parse_args(argv)
    if args.vendor == "codex":
        from ihar.codex import auth_owner, guardian
        try:
            guard_fd = os.environ.get("IHAR_GUARD_FD")
            if guard_fd is None:
                raise auth_owner.AuthOwnerError("Codex guardian admission is missing")
            guardian.request(int(guard_fd), "admit", {})
        except (auth_owner.AuthOwnerError, OSError, TypeError, ValueError):
            return 3
    try:
        summary = globals()[args.vendor](args.binary, args.home, args.session,
                                         Path(args.state) / "ephemeral.jsonl", args.timeout)
    except (OSError, subprocess.SubprocessError):
        summary = ""
    print(summary)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
