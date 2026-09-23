"""Decide whether a stored conformance record still applies (LLD 6.6).

A record proves that one binary, running one manifest, honoured a hook decision.
Change either and the proof no longer covers what is about to run, so the record is
stale rather than merely old.

Failure class: fail-closed. Exit 0 only when the record covers exactly this binary
and this manifest and every case passed.

Usage: python3 -m ihar.conformance.check <record> <binary> <manifest>
       python3 -m ihar.conformance.check --failed-record <vendor> <record> <binary> <manifest>
       python3 -m ihar.conformance.check --unmeasured-record <vendor> <record> <binary> <manifest>

`--unmeasured-record` answers 0 when every required case that is not passed is
`unmeasured` — a quota, a missing login, an unreachable endpoint — and at least one is.
An install may then activate the generation while recording the vendor as unproven; an
enforced profile still refuses to launch, because an unmeasured case proves nothing.
"""

from __future__ import annotations

import hashlib
import sys

from .. import jsonio
from . import REQUIRED_CASES


def _digest(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main(argv: list[str]) -> int:
    failed_record_mode = bool(argv) and argv[0] == "--failed-record"
    unmeasured_record_mode = bool(argv) and argv[0] == "--unmeasured-record"
    if failed_record_mode or unmeasured_record_mode:
        if len(argv) != 5 or argv[1] not in REQUIRED_CASES:
            print(__doc__, file=sys.stderr)
            return 2
        expected_vendor = argv[1]
        argv = argv[2:]
    elif len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    record_path, binary, manifest = argv

    try:
        record = jsonio.read("conformance", record_path)
    except (jsonio.SchemaError, OSError, UnicodeError):
        print("the record is unreadable")
        return 1
    if (failed_record_mode or unmeasured_record_mode) and record["vendor"] != expected_vendor:
        print("the record does not match the vendor")
        return 1

    try:
        binary_matches = record["binary_sha256"] == _digest(binary)
        manifest_matches = record["manifest_digest"] == _digest(manifest)
    except OSError:
        print("the binary or hook manifest is unreadable")
        return 1
    if not binary_matches or not manifest_matches:
        print("the record does not match the binary or hook manifest")
        return 1

    failed = sorted(name for name, case in record["cases"].items()
                    if case["status"] == "failed")
    required = REQUIRED_CASES[record["vendor"]]
    unmeasured = sorted(name for name, case in record["cases"].items()
                        if case["status"] == "unmeasured")
    if failed_record_mode:
        return 0 if required.intersection(failed) else 1
    if unmeasured_record_mode:
        # Only when nothing actually failed: one real failure among the required cases
        # and the record is a failure, whatever else could not be measured.
        if required.intersection(failed):
            return 1
        return 0 if required.intersection(unmeasured) else 1
    if required.intersection(unmeasured):
        print("these cases could not be measured: "
              + ", ".join(sorted(required.intersection(unmeasured))))
        return 1
    if failed:
        required_failed = sorted(REQUIRED_CASES[record["vendor"]].intersection(failed))
        if required_failed:
            print(f"these cases failed: {', '.join(required_failed)}")
        else:
            print("non-required cases failed")
        return 1

    # A record of nothing but skips proves nothing. The schema already refuses an
    # empty case set; this refuses one that is empty in substance.
    if all(case["status"] == "skipped" for case in record["cases"].values()):
        print("every case was skipped, so nothing was proven")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
