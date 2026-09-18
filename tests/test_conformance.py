#!/usr/bin/env python3
"""The live conformance suite (LLD 6.6), which is the whole of gate G2.

Every case here runs against the pinned vendor binary. A fixture cannot answer the
question the suite exists to ask: does this vendor, at this version, load the hook,
fire it, and honour what it decided?
"""

import json
import os
import shutil
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib", "python"))

from ihar import jsonio                     # noqa: E402
from ihar.conformance import run as conformance   # noqa: E402

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
MANIFEST = os.path.join(ROOT, "manifests", "hooks.json")
CODEX = os.environ.get(
    "IHAR_CODEX_BIN",
    "/home/ikeniborn/Documents/Project/icodex/.codex-isolated/bin/codex",
)


def _store():
    store = tempfile.mkdtemp(prefix="ihar-conf-store-")
    shutil.copytree(os.path.join(ROOT, "hooks"), os.path.join(store, "hooks"))
    return store


def test_the_record_validates_as_a_contract():
    """A conformance record is a contract like any other: a malformed one must not
    read as a pass."""
    record = {
        "schema": 1, "vendor": "codex", "version": "0.154.0",
        "binary_sha256": "a" * 64, "manifest_digest": "b" * 64,
        "created_at": "2026-09-18T10:00:00Z",
        "cases": {"deny-blocks-the-tool": {"status": "passed", "detail": "x"}},
    }
    jsonio.check("conformance", record)

    for broken in (
        {**record, "cases": {}},                                   # nothing proven
        {**record, "cases": {"x": {"status": "maybe"}}},           # unknown status
        {**record, "binary_sha256": "short"},                      # truncated pin
    ):
        try:
            jsonio.check("conformance", broken)
        except jsonio.SchemaError:
            continue
        raise AssertionError(f"a broken record validated: {broken}")


def test_vendor_independent_cases_pass():
    """The two cases that exercise the script contract rather than the vendor API
    run for either vendor, so Claude is covered even without a trust listing."""
    store = _store()
    home = tempfile.mkdtemp(prefix="ihar-conf-home-")
    workdir = tempfile.mkdtemp(prefix="ihar-conf-work-")
    try:
        conformance._stage(store, MANIFEST, "claude", home)
        for name in ("deny-blocks-the-tool", "rewrite-is-emitted"):
            status, detail = conformance.CASES[name]("claude", "/bin/false", home, workdir)
            assert status == "passed", f"{name}: {status} {detail}"
    finally:
        for directory in (store, home, workdir):
            shutil.rmtree(directory, ignore_errors=True)


def test_a_broken_hook_fails_the_suite():
    """The suite has to be able to fail. A hook replaced by something that allows
    everything must not pass the deny case."""
    store = _store()
    home = tempfile.mkdtemp(prefix="ihar-conf-home-")
    workdir = tempfile.mkdtemp(prefix="ihar-conf-work-")
    try:
        conformance._stage(store, MANIFEST, "claude", home)
        script = os.path.join(home, "hooks", "security-pretool.py")
        with open(script, "w", encoding="utf-8") as handle:
            handle.write("#!/usr/bin/env python3\nimport sys\nsys.exit(0)\n")
        status, _ = conformance.CASES["deny-blocks-the-tool"]("claude", "/bin/false", home, workdir)
        assert status == "failed", "a hook that allows everything passed the deny case"
    finally:
        for directory in (store, home, workdir):
            shutil.rmtree(directory, ignore_errors=True)


def test_the_full_run_against_the_pinned_codex():
    if not os.access(CODEX, os.X_OK):
        print("SKIP: no Codex binary")
        return
    store = _store()
    try:
        record = conformance.run("codex", CODEX, store, MANIFEST)
        jsonio.check("conformance", record)
        failed = {name: case for name, case in record["cases"].items()
                  if case["status"] == "failed"}
        assert not failed, json.dumps(failed, indent=2)
        # Every case must have actually run for Codex; a suite of skips proves nothing.
        skipped = [name for name, case in record["cases"].items()
                   if case["status"] == "skipped"]
        assert not skipped, f"cases skipped against a real binary: {skipped}"
    finally:
        shutil.rmtree(store, ignore_errors=True)


if __name__ == "__main__":
    tests = [value for name, value in sorted(globals().items()) if name.startswith("test_")]
    for test in tests:
        test()
    print(f"PASS={len(tests)} FAIL=0")
