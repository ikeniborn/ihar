"""Decide whether a stored conformance record still applies (LLD 6.6).

A record proves that one binary, running one manifest, honoured a hook decision.
Change either and the proof no longer covers what is about to run, so the record is
stale rather than merely old.

Failure class: fail-closed. Exit 0 only when the record covers exactly this binary
and this manifest and every case passed.

Usage: python3 -m ihar.conformance.check <record> <binary> <manifest>
       python3 -m ihar.conformance.check --failed-record <record> <binary> <manifest>
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
    failed_record_mode = len(argv) == 4 and argv[0] == "--failed-record"
    if failed_record_mode:
        argv = argv[1:]
    elif len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    record_path, binary, manifest = argv

    try:
        record = jsonio.read("conformance", record_path)
    except (jsonio.SchemaError, OSError, UnicodeError):
        print("the record is unreadable")
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
    if failed_record_mode:
        return 0 if REQUIRED_CASES[record["vendor"]].intersection(failed) else 1
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
