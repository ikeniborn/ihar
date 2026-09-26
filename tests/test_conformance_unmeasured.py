#!/usr/bin/env python3
"""Unmeasured is not a softer failed (LLD 6.6, 14.2).

A quota, a missing login or an unreachable endpoint says nothing about whether a vendor
honours a hook decision. Recording those as failures blocked an install that had nothing
wrong with it — observed when this project's own debugging exhausted a Codex quota — and
treating them as passes would let an enforced profile run on no evidence at all. So they
are their own status, and these cases hold both halves of that.
"""

import json
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "lib" / "python"))

from ihar import jsonio  # noqa: E402
from ihar.conformance import REQUIRED_CASES, check as check_module, run as run_module  # noqa: E402

PASS = FAIL = 0


def check(label, condition):
    global PASS, FAIL
    if condition:
        PASS += 1
    else:
        FAIL += 1
        print(f"FAIL {label}")


def record_for(vendor: str, binary: str, manifest: str, statuses: dict) -> dict:
    import hashlib

    def digest(path):
        with open(path, "rb") as handle:
            return hashlib.sha256(handle.read()).hexdigest()

    cases = {}
    for name in sorted(REQUIRED_CASES[vendor]):
        status = statuses.get(name, "passed")
        entry = {"status": status, "detail": f"{name}: {status}"}
        if status == "unmeasured":
            entry["reason"] = "vendor-quota-exhausted"
        cases[name] = entry
    return {
        "schema": 1, "vendor": vendor, "version": "0.154.0",
        "binary_sha256": digest(binary), "manifest_digest": digest(manifest),
        "created_at": "2026-09-22T12:00:00Z", "cases": cases,
    }


def run_check(mode, vendor, path, binary, manifest) -> int:
    argv = ([mode, vendor] if mode else []) + [path, binary, manifest]
    return check_module.main(argv)


def main():
    global PASS, FAIL

    # Legacy non-JSON output is matched only to classify; nothing of it is kept.
    check("a usage limit is an environment, not a failure",
          run_module._environment_reason("You've hit your usage limit", "", 1)
          == "vendor-quota-exhausted")
    check("a missing login is an environment",
          run_module._environment_reason("Please log in to continue", "", 1)
          == "vendor-unauthenticated")
    check("an unreachable endpoint is an environment",
          run_module._environment_reason("connection refused", "", 1)
          == "vendor-unreachable")
    check("a clean exit is never an environment reason",
          run_module._environment_reason("You've hit your usage limit", "", 0) == "")
    check("an ordinary failure is not reclassified",
          run_module._environment_reason("the hook did not fire", "", 1) == "")

    with tempfile.TemporaryDirectory() as raw:
        root = Path(raw)
        binary = root / "binary"
        manifest = root / "manifest"
        for path in (binary, manifest):
            path.write_text("fixture\n", encoding="utf-8")
        target = root / "record.json"
        vendor = "codex"
        one = sorted(REQUIRED_CASES[vendor])[0]
        another = sorted(REQUIRED_CASES[vendor])[1]

        # An unmeasured required case can never satisfy an enforced profile.
        jsonio.write("conformance", str(target),
                     record_for(vendor, str(binary), str(manifest), {one: "unmeasured"}))
        check("the enforced gate refuses an unmeasured record",
              run_check(None, None, str(target), str(binary), str(manifest)) == 1)
        check("an install may activate on an unmeasured record",
              run_check("--unmeasured-record", vendor, str(target), str(binary),
                        str(manifest)) == 0)

        missing_reason = record_for(
            vendor, str(binary), str(manifest), {one: "unmeasured"})
        del missing_reason["cases"][one]["reason"]
        jsonio.write("conformance", str(target), missing_reason)
        check("an unmeasured case without an environment reason blocks the install",
              run_check("--unmeasured-record", vendor, str(target), str(binary),
                        str(manifest)) == 1)

        hook_reason = record_for(
            vendor, str(binary), str(manifest), {one: "unmeasured"})
        hook_reason["cases"][one]["reason"] = "hook-never-fired"
        jsonio.write("conformance", str(target), hook_reason)
        check("a hook reason cannot authorize unmeasured activation",
              run_check("--unmeasured-record", vendor, str(target), str(binary),
                        str(manifest)) == 1)

        # One real failure and the record is a failure, whatever else went unmeasured.
        jsonio.write("conformance", str(target),
                     record_for(vendor, str(binary), str(manifest),
                                {one: "unmeasured", another: "failed"}))
        check("a real failure beside an unmeasured one blocks the install",
              run_check("--unmeasured-record", vendor, str(target), str(binary),
                        str(manifest)) == 1)
        check("and still refuses the enforced gate",
              run_check(None, None, str(target), str(binary), str(manifest)) == 1)

        extra_failure = record_for(vendor, str(binary), str(manifest), {one: "unmeasured"})
        extra_failure["cases"]["optional-diagnostic"] = {
            "status": "failed",
            "detail": "optional-diagnostic: failed",
            "reason": "unclassified",
        }
        jsonio.write("conformance", str(target), extra_failure)
        check("an extra failed case blocks unmeasured activation",
              run_check("--unmeasured-record", vendor, str(target), str(binary),
                        str(manifest)) == 1)

        # A fully passing record is untouched by any of this.
        jsonio.write("conformance", str(target),
                     record_for(vendor, str(binary), str(manifest), {}))
        check("a passing record still passes",
              run_check(None, None, str(target), str(binary), str(manifest)) == 0)
        check("a passing record is not an unmeasured one",
              run_check("--unmeasured-record", vendor, str(target), str(binary),
                        str(manifest)) == 1)

        # The record carries the word, never the vendor's sentence.
        written = json.loads(target.read_text(encoding="utf-8"))
        check("the record holds no vendor text",
              all("usage limit" not in json.dumps(case)
                  for case in written["cases"].values()))

    print(f"PASS={PASS} FAIL={FAIL}")
    return 1 if FAIL else 0


if __name__ == "__main__":
    raise SystemExit(main())
