#!/usr/bin/env python3
"""The live conformance suite (LLD 6.6), which is the whole of gate G2.

Every case here runs against the pinned vendor binary. A fixture cannot answer the
question the suite exists to ask: does this vendor, at this version, load the hook,
fire it, and honour what it decided?
"""

import json
import os
import re
import shutil
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib", "python"))

from ihar import jsonio                     # noqa: E402
from ihar.codex import hooks_trust          # noqa: E402
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
        "cases": {
            name: {"status": "passed", "detail": "x"}
            for name in conformance.REQUIRED_CASES["codex"]
        },
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


def test_records_require_every_vendor_live_case_without_skips():
    """A partial or skipped live matrix must never unlock an enforced profile."""
    base = {
        "schema": 1,
        "version": "pinned-vendor",
        "binary_sha256": "a" * 64,
        "manifest_digest": "b" * 64,
        "created_at": "2026-09-18T10:00:00Z",
    }
    for vendor, required in conformance.REQUIRED_CASES.items():
        complete = {
            **base,
            "vendor": vendor,
            "cases": {
                name: {"status": "passed", "detail": "live vendor evidence"}
                for name in required
            },
        }
        jsonio.check("conformance", complete)

        missing = {**complete, "cases": dict(complete["cases"])}
        missing["cases"].pop(next(iter(required)))
        skipped = {**complete, "cases": dict(complete["cases"])}
        skipped["cases"][next(iter(required))] = {
            "status": "skipped",
            "detail": "not evidence",
        }
        for broken in (missing, skipped):
            try:
                jsonio.check("conformance", broken)
            except jsonio.SchemaError:
                continue
            raise AssertionError(f"incomplete {vendor} live evidence validated: {broken}")


def test_run_routes_every_mandatory_live_case_through_the_vendor():
    store = _store()
    binary = os.path.join(store, "codex")
    with open(binary, "w", encoding="utf-8") as handle:
        handle.write("#!/bin/sh\nprintf 'codex-cli pinned-test\\n'\n")
    os.chmod(binary, 0o755)

    seen = []
    original = conformance._run_live_case
    original_cases = conformance.CASES

    def fake_live_case(vendor, selected_binary, home, workdir, name):
        assert vendor == "codex"
        assert selected_binary == binary
        seen.append(name)
        return "passed", "vendor loaded, fired and honoured the hook"

    conformance._run_live_case = fake_live_case
    conformance.CASES = {
        name: (lambda _vendor, _binary, _home, _workdir: ("passed", "existing proof"))
        for name in original_cases
    }
    try:
        record = conformance.run("codex", binary, store, MANIFEST)
    finally:
        conformance._run_live_case = original
        conformance.CASES = original_cases
        shutil.rmtree(store, ignore_errors=True)

    assert set(seen) == conformance.LIVE_CASES, seen
    assert all(record["cases"][name]["status"] == "passed"
               for name in conformance.LIVE_CASES)


def test_resealing_codex_replaces_only_the_generated_trust_region():
    home = tempfile.mkdtemp(prefix="ihar-conf-home-")
    config = os.path.join(home, "config.toml")
    with open(config, "w", encoding="utf-8") as handle:
        handle.write('model = "x"\n')
        handle.write("# ihar:hook-trust:start\nold trust bytes\n# ihar:hook-trust:end\n")
        handle.write("[mcp_servers.ihar-conformance]\ncommand = \"python3\"\n")

    real_seal = hooks_trust.seal_quiet

    def fake_seal(_binary, selected_home, _workdir):
        with open(os.path.join(selected_home, "config.toml"), encoding="utf-8") as handle:
            content = handle.read()
        assert "old trust bytes" not in content
        assert "[mcp_servers.ihar-conformance]" in content
        return 0, "sealed"

    hooks_trust.seal_quiet = fake_seal
    try:
        ready, detail = conformance._prepare_codex_hooks("codex", home, "/repo")
    finally:
        hooks_trust.seal_quiet = real_seal
        shutil.rmtree(home, ignore_errors=True)
    assert ready, detail


def test_vendor_turn_uses_supported_native_cli_and_exact_claude_tool_allowlist():
    seen = []
    real_run = conformance.subprocess.run

    def fake_run(argv, **kwargs):
        seen.append((argv, kwargs))
        return conformance.subprocess.CompletedProcess(argv, 0, "", "")

    conformance.subprocess.run = fake_run
    try:
        conformance._vendor_turn(
            "claude", "/pinned/claude", "/runtime", "/work", "prompt",
            allowed_tool="Bash",
        )
        conformance._vendor_turn(
            "codex", "/pinned/codex", "/runtime", "/work", "prompt",
            allowed_tool="Bash",
        )
    finally:
        conformance.subprocess.run = real_run

    claude_argv, claude_kwargs = seen[0]
    codex_argv, codex_kwargs = seen[1]
    assert claude_argv[:2] == ["/pinned/claude", "-p"], claude_argv
    assert claude_argv[claude_argv.index("--allowedTools") + 1] == "Bash", claude_argv
    assert claude_kwargs["env"]["CLAUDE_CONFIG_DIR"] == "/runtime"
    assert codex_argv[:2] == ["/pinned/codex", "exec"], codex_argv
    assert codex_kwargs["env"]["CODEX_HOME"] == "/runtime"


def test_staged_vendor_home_links_the_stable_shared_login():
    store = _store()
    try:
        for vendor, name in (("claude", ".credentials.json"), ("codex", "auth.json")):
            source_dir = os.path.join(store, "auth", vendor)
            os.makedirs(source_dir, exist_ok=True)
            source = os.path.join(source_dir, name)
            with open(source, "w", encoding="utf-8") as handle:
                handle.write("login evidence\n")
            home = tempfile.mkdtemp(prefix=f"ihar-conf-{vendor}-")
            try:
                conformance._stage(store, MANIFEST, vendor, home)
                target = os.path.join(home, name)
                assert os.path.islink(target), f"{vendor} login was copied or omitted"
                assert os.path.realpath(target) == os.path.realpath(source)
            finally:
                shutil.rmtree(home, ignore_errors=True)
    finally:
        shutil.rmtree(store, ignore_errors=True)


def test_claude_run_probes_native_sandbox_writes():
    store = _store()
    active_store = tempfile.mkdtemp(prefix="ihar-conf-active-store-")
    binary = os.path.join(store, "claude")
    with open(binary, "w", encoding="utf-8") as handle:
        handle.write("#!/bin/sh\nexit 0\n")
    os.chmod(binary, 0o755)

    real_run = conformance.subprocess.run
    seen = {"direct": set(), "child": set(), "workspace": set()}
    attempted = {"direct": set(), "child": set()}
    mode = ["protected"]
    probe_paths = []
    unsandboxed_targets = []

    def probe_path(invocation, prefix):
        match = re.search(re.escape(prefix) + r"[0-9a-f]+", invocation)
        return match.group(0) if match else None

    def fake_protected_write(target):
        if mode[0] == "unsandboxed":
            with open(target, "w", encoding="utf-8") as handle:
                handle.write("ihar-conformance\n")
            unsandboxed_targets.append(target)
            return 0
        raise PermissionError(target)

    def fake_vendor(argv, **kwargs):
        if argv[0] != binary:
            return real_run(argv, **kwargs)
        if argv[1:] == ["--version"]:
            return conformance.subprocess.CompletedProcess(argv, 0, "claude 2.1.274\n", "")
        if "-p" not in argv:
            return conformance.subprocess.CompletedProcess(argv, 2, "", "not non-interactive")
        if mode[0] == "unavailable":
            return conformance.subprocess.CompletedProcess(argv, 3, "", "sandbox unavailable")

        settings_path = os.path.join(kwargs["env"]["CLAUDE_CONFIG_DIR"], "settings.json")
        with open(settings_path, "r", encoding="utf-8") as handle:
            roots = json.load(handle)["sandbox"]["filesystem"]["denyWrite"]
        invocation = " ".join(argv)

        for kind in ("direct", "child"):
            for root in roots:
                target = probe_path(
                    invocation, os.path.join(root, f".ihar-conformance-{kind}-write-")
                )
                if target:
                    before = probe_path(
                        invocation,
                        os.path.join(kwargs["cwd"], f".ihar-conformance-{kind}-before-"),
                    )
                    after = probe_path(
                        invocation,
                        os.path.join(kwargs["cwd"], f".ihar-conformance-{kind}-after-"),
                    )
                    if not before or not after:
                        return conformance.subprocess.CompletedProcess(
                            argv, 2, "", "probe has no before/after markers"
                        )
                    seen[kind].add(root)
                    probe_paths.extend((before, target, after))
                    with open(before, "w", encoding="utf-8") as handle:
                        handle.write("ihar-conformance\n")
                    attempted[kind].add(root)
                    try:
                        status = fake_protected_write(target)
                    except PermissionError:
                        status = 1
                    with open(after, "w", encoding="utf-8") as handle:
                        handle.write(f"{status}\n")
                    return conformance.subprocess.CompletedProcess(argv, 0, "{}", "")

        target = probe_path(
            invocation, os.path.join(kwargs["cwd"], ".ihar-conformance-workspace-write-")
        )
        if target:
            seen["workspace"].add(target)
            probe_paths.append(target)
            with open(target, "w", encoding="utf-8") as handle:
                handle.write("ihar-conformance\n")
            return conformance.subprocess.CompletedProcess(argv, 0, "{}", "")
        return conformance.subprocess.CompletedProcess(argv, 2, "", "unknown probe")

    conformance.subprocess.run = fake_vendor
    try:
        record = conformance.run(
            "claude", binary, store, MANIFEST, protected_store=active_store
        )
        protected_paths = tuple(probe_paths)
        protected_seen = {kind: set(paths) for kind, paths in seen.items()}
        protected_attempted = {kind: set(paths) for kind, paths in attempted.items()}
        mode[0] = "unavailable"
        unavailable_record = conformance.run("claude", binary, store, MANIFEST)
        mode[0] = "unsandboxed"
        unsandboxed_record = conformance.run("claude", binary, store, MANIFEST)
    finally:
        conformance.subprocess.run = real_run
        shutil.rmtree(store, ignore_errors=True)
        shutil.rmtree(active_store, ignore_errors=True)

    assert record["cases"]["sandbox-direct-write"]["status"] == "passed", record["cases"]
    assert record["cases"]["sandbox-child-write"]["status"] == "passed", record["cases"]
    assert record["cases"]["sandbox-workspace-write"]["status"] == "passed", record["cases"]
    assert len(protected_seen["direct"]) == 3, protected_seen
    assert len(protected_seen["child"]) == 3, protected_seen
    assert len(protected_seen["workspace"]) == 1, protected_seen
    assert protected_attempted["direct"] == protected_seen["direct"], protected_attempted
    assert protected_attempted["child"] == protected_seen["child"], protected_attempted
    assert active_store in protected_seen["direct"], protected_seen
    assert active_store in protected_seen["child"], protected_seen
    assert store not in protected_seen["direct"], protected_seen
    assert store not in protected_seen["child"], protected_seen
    assert len(protected_paths) == len(set(protected_paths)), protected_paths
    assert not any(os.path.exists(path) for path in protected_paths), protected_paths
    assert unavailable_record["cases"]["sandbox-direct-write"]["status"] == "failed"
    assert unsandboxed_record["cases"]["sandbox-direct-write"]["status"] == "failed"
    assert unsandboxed_targets, "the fake did not exercise an unsandboxed write"
    assert not any(os.path.exists(path) for path in unsandboxed_targets), unsandboxed_targets


def test_the_full_run_against_the_pinned_codex():
    if not os.access(CODEX, os.X_OK):
        print("SKIP: no Codex binary")
        return
    with open(os.path.join(ROOT, ".ihar-lockfile.json"), encoding="utf-8") as handle:
        pinned = json.load(handle)["codex"]["version"].removeprefix("rust-v")
    installed = conformance.vendor_version("codex", CODEX)
    if installed != f"codex-cli {pinned}":
        print(f"SKIP: Codex {installed!r} is not pinned codex-cli {pinned}")
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
