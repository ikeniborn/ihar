#!/usr/bin/env python3
"""Every conformance flag must exist on the pinned vendor CLI contract."""

import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "lib" / "python"))

from ihar.conformance import run  # noqa: E402

PASS = FAIL = SKIP = 0


def check(label, condition):
    global PASS, FAIL
    if condition:
        PASS += 1
    else:
        FAIL += 1
        print(f"FAIL {label}")


def argv_for(vendor: str, binary: str) -> list[str]:
    captured = {}

    def fake_run(argv, **kwargs):
        captured["argv"] = argv
        raise RuntimeError("the vendor is not started by this test")

    original = subprocess.run
    subprocess.run = fake_run  # type: ignore[assignment]
    try:
        run._vendor_turn(vendor, binary, "/tmp/home", "/tmp/work", "prompt",
                         allowed_tool="Bash", mcp_config="/tmp/mcp.json")
    except RuntimeError:
        pass
    finally:
        subprocess.run = original  # type: ignore[assignment]
    return captured.get("argv", [])


def help_text(binary: str, subcommand: list[str]) -> str:
    result = subprocess.run([binary, *subcommand, "--help"], text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
    return result.stdout or ""


def main():
    global PASS, FAIL, SKIP
    vendors = (
        ("claude", os.environ.get("IHAR_CLAUDE_BIN", ""), []),
        ("codex", os.environ.get("IHAR_CODEX_BIN", ""), ["exec"]),
    )
    for vendor, binary, subcommand in vendors:
        if not binary or not os.path.exists(binary):
            SKIP += 1
            print(f"SKIP {vendor} is not installed here")
            continue
        argv = argv_for(vendor, binary)
        check(f"{vendor}: the runner builds an argv", bool(argv))
        text = help_text(binary, subcommand)
        check(f"{vendor}: its help could be read", bool(text))
        flags = [token for token in argv if token.startswith("--")]
        check(f"{vendor}: the argv carries flags to check", bool(flags))
        for flag in flags:
            check(f"{vendor}: {flag} exists on the pinned binary", flag in text)

    codex_binary = os.environ.get("IHAR_CODEX_BIN", "") or "codex"
    argv = argv_for("codex", codex_binary)
    check("codex: the approval policy travels as a configuration override",
          "-c" in argv and 'approval_policy="never"' in argv)
    check("codex: the flag the binary rejects is gone",
          "--ask-for-approval" not in argv)

    print(f"PASS={PASS} FAIL={FAIL} SKIP={SKIP}")
    return 1 if FAIL else 0


if __name__ == "__main__":
    raise SystemExit(main())
