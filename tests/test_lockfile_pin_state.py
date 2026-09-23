#!/usr/bin/env python3
"""A pinned file that is absent is named absent, not changed (LLD 14.2).

Observed: a store that predated a pin refused every launch with `… differs from the
lockfile`, which reads as tampering. The file was simply not there. The two situations
have different remedies and different implications, so the refusal names which it is.
"""

import json
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "lib" / "python"))

from ihar.lockfile import verify_map  # noqa: E402

PASS = FAIL = 0


def check(label, condition):
    global PASS, FAIL
    if condition:
        PASS += 1
    else:
        FAIL += 1
        print(f"FAIL {label}")


def main():
    global PASS, FAIL
    import io
    from contextlib import redirect_stdout

    with tempfile.TemporaryDirectory() as raw:
        store = Path(raw)
        lock = store / "lock.json"
        pinned = "0" * 64
        lock.write_text(json.dumps({"schema": 1, "hooks": {"hooks/one.py": pinned}}),
                        encoding="utf-8")

        out = io.StringIO()
        with redirect_stdout(out):
            status = verify_map("hooks", str(lock), str(store))
        check("an absent pin is a mismatch", status == 1)
        check("and is reported as missing", out.getvalue().startswith("missing "))
        check("the path is named", "hooks/one.py" in out.getvalue())

        (store / "hooks").mkdir()
        (store / "hooks" / "one.py").write_text("not the pinned bytes\n", encoding="utf-8")
        out = io.StringIO()
        with redirect_stdout(out):
            status = verify_map("hooks", str(lock), str(store))
        check("a rewritten pin is a mismatch", status == 1)
        check("and is reported as changed", out.getvalue().startswith("changed "))

        import hashlib
        digest = hashlib.sha256((store / "hooks" / "one.py").read_bytes()).hexdigest()
        lock.write_text(json.dumps({"schema": 1, "hooks": {"hooks/one.py": digest}}),
                        encoding="utf-8")
        out = io.StringIO()
        with redirect_stdout(out):
            status = verify_map("hooks", str(lock), str(store))
        check("a satisfied pin says nothing", status == 0 and out.getvalue() == "")

    print(f"PASS={PASS} FAIL={FAIL}")
    return 1 if FAIL else 0


if __name__ == "__main__":
    raise SystemExit(main())
