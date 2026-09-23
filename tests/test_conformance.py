#!/usr/bin/env python3
"""The live conformance suite (LLD 6.6), which is the whole of gate G2.

Every case here runs against the pinned vendor binary. A fixture cannot answer the
question the suite exists to ask: does this vendor, at this version, load the hook,
fire it, and honour what it decided?
"""

import hashlib
import io
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib", "python"))

from ihar import jsonio                     # noqa: E402
from ihar.codex import auth_owner, guardian, hooks_trust  # noqa: E402
from ihar.conformance import run as conformance   # noqa: E402
from ihar.conformance import check as conformance_check  # noqa: E402

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
MANIFEST = os.path.join(ROOT, "manifests", "hooks.json")
LOCKFILE = os.path.join(ROOT, ".ihar-lockfile.json")
CODEX = os.environ.get(
    "IHAR_CODEX_BIN",
    "/home/ikeniborn/Documents/Project/icodex/.codex-isolated/bin/codex",
)


def _main(argv):
    original_begin = conformance._begin_codex_conformance
    original_finish = conformance._finish_codex_conformance
    conformance._begin_codex_conformance = lambda _store: None
    conformance._finish_codex_conformance = lambda _store, _stage, _failed: None
    try:
        return conformance.main(argv)
    finally:
        conformance._begin_codex_conformance = original_begin
        conformance._finish_codex_conformance = original_finish

EXPECTED_REQUIRED_CASES = {
    "claude": {
        "deny-blocks-the-tool",
        "rewrite-reaches-the-tool",
        "session-start-context",
        "mcp-matcher-fires",
        "timeout-behaviour",
        "sandbox-direct-write",
        "sandbox-child-write",
        "sandbox-workspace-write",
    },
    "codex": {
        "deny-blocks-the-tool",
        "rewrite-reaches-the-tool",
        "session-start-context",
        "mcp-matcher-fires",
        "timeout-behaviour",
        "hook-is-loaded",
        "trust-is-recordable",
        "tampering-is-detected",
    },
}


def _record(vendor, binary, manifest, failed=()):
    with open(binary, "rb") as handle:
        binary_digest = hashlib.sha256(handle.read()).hexdigest()
    with open(manifest, "rb") as handle:
        manifest_digest = hashlib.sha256(handle.read()).hexdigest()
    return {
        "schema": 1, "vendor": vendor, "version": "pinned-vendor",
        "binary_sha256": binary_digest, "manifest_digest": manifest_digest,
        "created_at": "2026-09-18T10:00:00Z",
        "cases": {
            name: {"status": "failed" if name in failed else "passed", "detail": "safe"}
            for name in EXPECTED_REQUIRED_CASES[vendor]
        },
    }


def test_main_reports_failed_case_without_dynamic_detail():
    store = tempfile.mkdtemp(prefix="ihar-conf-output-")
    binary = os.path.join(store, "binary")
    manifest = os.path.join(store, "manifest")
    for path in (binary, manifest):
        with open(path, "w", encoding="utf-8") as handle:
            handle.write("fixture\n")
    record = _record("codex", binary, manifest, {"deny-blocks-the-tool"})
    record["cases"]["deny-blocks-the-tool"]["detail"] = "SECRET-SENTINEL"
    real_run = conformance.run
    conformance.run = lambda *_args, **_kwargs: record
    out, err = io.StringIO(), io.StringIO()
    try:
        with redirect_stdout(out), redirect_stderr(err):
            result = _main([
                "codex", binary, store, manifest,
                "--auth-store", store, "--lockfile", LOCKFILE,
            ])
    finally:
        conformance.run = real_run
        shutil.rmtree(store, ignore_errors=True)
    assert result == 1
    assert "deny-blocks-the-tool" in out.getvalue()
    assert "SECRET-SENTINEL" not in out.getvalue() + err.getvalue()


def test_main_aborts_guarded_stage_when_required_case_is_unmeasured():
    store = tempfile.mkdtemp(prefix="ihar-conf-unmeasured-owner-")
    binary = os.path.join(store, "binary")
    manifest = os.path.join(store, "manifest")
    for path in (binary, manifest):
        with open(path, "w", encoding="utf-8") as handle:
            handle.write("fixture\n")
    record = _record("codex", binary, manifest)
    name = sorted(EXPECTED_REQUIRED_CASES["codex"])[0]
    record["cases"][name] = {
        "status": "unmeasured",
        "detail": f"{name}: unmeasured",
        "reason": "vendor-unreachable",
    }
    real_run = conformance.run
    real_begin = conformance._begin_codex_conformance
    real_finish = conformance._finish_codex_conformance
    finished = []
    conformance.run = lambda *_args, **_kwargs: record
    conformance._begin_codex_conformance = lambda _store: "synthetic-stage"
    conformance._finish_codex_conformance = lambda *args: finished.append(args)
    out, err = io.StringIO(), io.StringIO()
    try:
        with redirect_stdout(out), redirect_stderr(err):
            result = conformance.main([
                "codex", binary, store, manifest,
                "--auth-store", store, "--lockfile", LOCKFILE,
            ])
    finally:
        conformance.run = real_run
        conformance._begin_codex_conformance = real_begin
        conformance._finish_codex_conformance = real_finish
        shutil.rmtree(store, ignore_errors=True)
    assert result == 1
    assert finished == [(store, "synthetic-stage", True)]
    assert f"unmeasured {name} (vendor-unreachable)" in out.getvalue()


def test_main_hides_pre_record_exception_detail():
    store = tempfile.mkdtemp(prefix="ihar-conf-output-")
    real_run = conformance.run

    def fail_run(*_args, **_kwargs):
        raise RuntimeError("SECRET-SENTINEL")

    conformance.run = fail_run
    out, err = io.StringIO(), io.StringIO()
    try:
        with redirect_stdout(out), redirect_stderr(err):
            result = _main([
                "codex", "binary", store, "manifest",
                "--auth-store", store, "--lockfile", LOCKFILE,
            ])
    finally:
        conformance.run = real_run
        shutil.rmtree(store, ignore_errors=True)
    assert result == 3
    assert "codex" in err.getvalue()
    assert "RuntimeError" in err.getvalue()
    assert "SECRET-SENTINEL" not in out.getvalue() + err.getvalue()


def test_main_treats_record_write_error_as_pre_record_failure():
    store = tempfile.mkdtemp(prefix="ihar-conf-output-")
    binary = os.path.join(store, "binary")
    manifest = os.path.join(store, "manifest")
    for path in (binary, manifest):
        with open(path, "w", encoding="utf-8") as handle:
            handle.write("fixture\n")
    record = _record("codex", binary, manifest, {"deny-blocks-the-tool"})
    real_run = conformance.run
    real_write = conformance.jsonio.write

    def fail_write(*_args, **_kwargs):
        raise OSError("SECRET-SENTINEL")

    conformance.run = lambda *_args, **_kwargs: record
    conformance.jsonio.write = fail_write
    out, err = io.StringIO(), io.StringIO()
    try:
        with redirect_stdout(out), redirect_stderr(err):
            result = _main([
                "codex", binary, store, manifest,
                "--auth-store", store, "--lockfile", LOCKFILE,
            ])
    finally:
        conformance.run = real_run
        conformance.jsonio.write = real_write
        shutil.rmtree(store, ignore_errors=True)
    assert result == 3
    assert "OSError" in err.getvalue()
    assert "SECRET-SENTINEL" not in out.getvalue() + err.getvalue()


def test_main_persists_only_fixed_case_details():
    store = tempfile.mkdtemp(prefix="ihar-conf-record-")
    binary = os.path.join(store, "binary")
    manifest = os.path.join(store, "manifest")
    for path in (binary, manifest):
        with open(path, "w", encoding="utf-8") as handle:
            handle.write("fixture\n")
    real_cases = conformance.CASES
    real_live_case = conformance._run_live_case
    real_stage = conformance._stage
    real_version = conformance.vendor_version
    real_validate = conformance._validate_release_pin
    conformance.CASES = {
        name: (lambda *_args: ("failed", "SECRET-SENTINEL"))
        for name in EXPECTED_REQUIRED_CASES["codex"] - conformance.LIVE_CASES
    }
    conformance._run_live_case = lambda *_args: ("passed", "SECRET-SENTINEL")
    conformance._stage = lambda *_args, **_kwargs: None
    conformance.vendor_version = lambda *_args: "pinned-vendor"
    conformance._validate_release_pin = lambda *_args: None
    out, err = io.StringIO(), io.StringIO()
    try:
        with redirect_stdout(out), redirect_stderr(err):
            result = _main([
                "codex", binary, store, manifest,
                "--auth-store", store, "--lockfile", LOCKFILE, "--json",
            ])
        record_path = os.path.join(store, "verification", "codex-pinned-vendor.json")
        with open(record_path, encoding="utf-8") as handle:
            saved = handle.read()
    finally:
        conformance.CASES = real_cases
        conformance._run_live_case = real_live_case
        conformance._stage = real_stage
        conformance.vendor_version = real_version
        conformance._validate_release_pin = real_validate
        shutil.rmtree(store, ignore_errors=True)
    assert result == 1
    assert "SECRET-SENTINEL" not in saved
    assert "SECRET-SENTINEL" not in out.getvalue() + err.getvalue()
    record = json.loads(saved)
    assert json.loads(out.getvalue()) == record
    assert record["cases"]["hook-is-loaded"]["detail"] == "hook-is-loaded: failed"


def test_vendor_version_rejects_extra_output_without_echoing_it():
    store = tempfile.mkdtemp(prefix="ihar-conf-version-")
    binary = os.path.join(store, "vendor")
    try:
        for vendor, output in (
            ("codex", "codex-cli 0.154.0 SECRET-SENTINEL"),
            ("claude", "2.1.274 (Claude Code) SECRET-SENTINEL"),
        ):
            with open(binary, "w", encoding="utf-8") as handle:
                handle.write(f"#!/bin/sh\nprintf '%s\\n' '{output}'\n")
            os.chmod(binary, 0o755)
            try:
                conformance.vendor_version(vendor, binary)
            except RuntimeError as error:
                assert "SECRET-SENTINEL" not in str(error)
            else:
                raise AssertionError(f"{vendor} accepted unbounded version output")
            out, err = io.StringIO(), io.StringIO()
            with redirect_stdout(out), redirect_stderr(err):
                result = _main([
                    vendor, binary, store, MANIFEST,
                    "--auth-store", store, "--lockfile", LOCKFILE,
                ])
            assert result == 3
            assert "SECRET-SENTINEL" not in out.getvalue() + err.getvalue()
            assert not os.path.exists(os.path.join(store, "verification"))
    finally:
        shutil.rmtree(store, ignore_errors=True)


def test_main_bounds_invalid_utf8_vendor_version():
    store = tempfile.mkdtemp(prefix="ihar-conf-version-bytes-")
    binary = os.path.join(store, "vendor")
    try:
        with open(binary, "w", encoding="utf-8") as handle:
            handle.write("#!/usr/bin/env python3\nimport os\nos.write(1, bytes([255]))\n")
        os.chmod(binary, 0o755)
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            result = _main([
                "codex", binary, store, MANIFEST,
                "--auth-store", store, "--lockfile", LOCKFILE,
            ])
        assert result == 3
        assert out.getvalue() == ""
        assert "codex: RuntimeError" in err.getvalue()
        assert binary not in err.getvalue()
        assert not os.path.exists(os.path.join(store, "verification"))
    finally:
        shutil.rmtree(store, ignore_errors=True)


def test_failed_record_mode_bounds_invalid_utf8_record():
    store = tempfile.mkdtemp(prefix="ihar-conf-record-bytes-")
    binary = os.path.join(store, "binary")
    manifest = os.path.join(store, "manifest")
    record_path = os.path.join(store, "record.json")
    try:
        for path in (binary, manifest):
            with open(path, "w", encoding="utf-8") as handle:
                handle.write("fixture\n")
        with open(record_path, "wb") as handle:
            handle.write(bytes([255]))
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            result = conformance_check.main([
                "--failed-record", "codex", record_path, binary, manifest,
            ])
        assert result == 1
        assert out.getvalue().strip() == "the record is unreadable"
        assert record_path not in out.getvalue() + err.getvalue()
    finally:
        shutil.rmtree(store, ignore_errors=True)


def test_failed_record_mode_requires_complete_matching_failed_required_case():
    store = tempfile.mkdtemp(prefix="ihar-conf-check-")
    binary = os.path.join(store, "binary")
    manifest = os.path.join(store, "manifest")
    record_path = os.path.join(store, "record.json")
    for path in (binary, manifest):
        with open(path, "w", encoding="utf-8") as handle:
            handle.write("fixture\n")
    try:
        failed = _record("codex", binary, manifest, {"deny-blocks-the-tool"})
        passing = _record("codex", binary, manifest)
        stale = {**failed, "manifest_digest": "0" * 64}
        malformed = {**failed, "cases": {}}
        other_vendor = _record("claude", binary, manifest, {"deny-blocks-the-tool"})
        optional_only = {**passing, "cases": {
            **passing["cases"], "optional": {"status": "failed", "detail": "SECRET-SENTINEL"},
        }}
        for record, expected in ((failed, 0), (passing, 1), (stale, 1),
                                 (malformed, 1), (other_vendor, 1), (optional_only, 1)):
            with open(record_path, "w", encoding="utf-8") as handle:
                json.dump(record, handle)
            out, err = io.StringIO(), io.StringIO()
            with redirect_stdout(out), redirect_stderr(err):
                actual = conformance_check.main([
                    "--failed-record", "codex", record_path, binary, manifest,
                ])
            assert actual == expected, (record["cases"], actual)
            assert record_path not in out.getvalue() + err.getvalue()
            assert "SECRET-SENTINEL" not in out.getvalue() + err.getvalue()
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            invalid_result = conformance_check.main([
                "--failed-record", record_path, binary, manifest,
            ])
        assert invalid_result == 2
        assert out.getvalue() == ""
        assert err.getvalue() == conformance_check.__doc__ + "\n"
    finally:
        shutil.rmtree(store, ignore_errors=True)


def _store():
    store = tempfile.mkdtemp(prefix="ihar-conf-store-")
    shutil.copytree(os.path.join(ROOT, "hooks"), os.path.join(store, "hooks"))
    return store


def _fake_claude(store):
    binary = os.path.join(store, "claude")
    with open(binary, "w", encoding="utf-8") as handle:
        handle.write(r'''#!/usr/bin/env python3
import json
import os
import re
import shlex
import subprocess
import sys

if sys.argv[1:] == ["--version"]:
    print("2.1.274 (Claude Code)")
    raise SystemExit(0)

home = os.environ["CLAUDE_CONFIG_DIR"]
with open(os.path.join(home, "settings.json"), encoding="utf-8") as stream:
    settings = json.load(stream)


def run_hooks(event, tool="", tool_input=None):
    payload = {"hook_event_name": event, "tool_name": tool,
               "tool_input": tool_input or {}, "session_id": "fake-session"}
    decisions = []
    updated = None
    contexts = []
    for group in settings["hooks"].get(event, []):
        matcher = group.get("matcher")
        if matcher is not None and re.fullmatch(matcher, tool) is None:
            continue
        for hook in group["hooks"]:
            timeout = None if os.environ.get("IHAR_FAKE_IGNORE_TIMEOUT") else hook["timeout"]
            try:
                result = subprocess.run(
                    hook["command"], input=json.dumps(payload), text=True,
                    capture_output=True, env=os.environ, timeout=timeout,
                    shell=True, executable="/bin/bash",
                )
            except subprocess.TimeoutExpired:
                continue
            body = json.loads(result.stdout) if result.stdout.strip() else {}
            output = body.get("hookSpecificOutput", {})
            if output.get("permissionDecision"):
                decisions.append(output["permissionDecision"])
            if output.get("updatedInput"):
                updated = output["updatedInput"]
            if output.get("additionalContext"):
                contexts.append(output["additionalContext"])
    return decisions, updated, contexts


_, _, contexts = run_hooks("SessionStart")
prompt = sys.argv[2]
if "MCP server's prove tool" in prompt:
    tool = "mcp__ihar-conformance__prove"
    decisions, _, _ = run_hooks("PreToolUse", tool, {})
    if "deny" not in decisions:
        path = sys.argv[sys.argv.index("--mcp-config") + 1]
        with open(path, encoding="utf-8") as stream:
            config = json.load(stream)["mcpServers"]["ihar-conformance"]
        server = subprocess.Popen(
            [config["command"], *config["args"]], stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, text=True,
        )
        for request in (
            {"jsonrpc": "2.0", "id": 1, "method": "initialize",
             "params": {"protocolVersion": "2025-06-18"}},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}},
            {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
             "params": {"name": "prove", "arguments": {}}},
        ):
            server.stdin.write(json.dumps(request) + "\n")
            server.stdin.flush()
            json.loads(server.stdout.readline())
        server.stdin.close()
        server.wait(timeout=5)
elif "SessionStart hook supplied" in prompt:
    target = prompt.rsplit(" to ", 1)[1].removesuffix(".")
    token = next(value for value in contexts if value.startswith("IHAR-CONFORMANCE-"))
    command = f"printf '%s' {shlex.quote(token)} > {target}"
    decisions, updated, _ = run_hooks("PreToolUse", "Bash", {"command": command})
    if "deny" not in decisions:
        subprocess.run((updated or {"command": command})["command"], shell=True, check=True)
else:
    command = prompt.split("tool: ", 1)[1]
    decisions, updated, _ = run_hooks("PreToolUse", "Bash", {"command": command})
    if "deny" not in decisions:
        subprocess.run((updated or {"command": command})["command"], shell=True, check=True)
print("{}")
''')
    os.chmod(binary, 0o755)
    return binary


def test_the_record_validates_as_a_contract():
    """A conformance record is a contract like any other: a malformed one must not
    read as a pass."""
    record = {
        "schema": 1, "vendor": "codex", "version": "0.154.0",
        "binary_sha256": "a" * 64, "manifest_digest": "b" * 64,
        "created_at": "2026-09-18T10:00:00Z",
        "cases": {
            name: {"status": "passed", "detail": "x"}
            for name in EXPECTED_REQUIRED_CASES["codex"]
        },
    }
    jsonio.check("conformance", record)
    api_error_record = json.loads(json.dumps(record))
    api_error_record["cases"]["deny-blocks-the-tool"] = {
        "status": "unmeasured",
        "detail": "deny-blocks-the-tool: unmeasured",
        "reason": "vendor-api-error",
    }
    jsonio.check("conformance", api_error_record)

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
    assert conformance.REQUIRED_CASES == EXPECTED_REQUIRED_CASES
    for vendor, required in EXPECTED_REQUIRED_CASES.items():
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


def test_fake_native_vendor_executes_every_mandatory_live_hook_protocol():
    store = _store()
    binary = _fake_claude(store)
    home = tempfile.mkdtemp(prefix="ihar-conf-home-")
    workdir = tempfile.mkdtemp(prefix="ihar-conf-work-")
    try:
        conformance._stage(store, MANIFEST, "claude", home, auth_store=store)
        results = {
            name: conformance._run_live_case("claude", binary, home, workdir, name)
            for name in (
                "deny-blocks-the-tool",
                "rewrite-reaches-the-tool",
                "session-start-context",
                "mcp-matcher-fires",
                "timeout-behaviour",
            )
        }
    finally:
        for directory in (store, home, workdir):
            shutil.rmtree(directory, ignore_errors=True)
    assert all(status == "passed" for status, _ in results.values()), results


def test_codex_mcp_case_uses_the_normalized_hook_tool_name():
    home = tempfile.mkdtemp(prefix="ihar-conf-home-")
    workdir = tempfile.mkdtemp(prefix="ihar-conf-work-")
    real_reset = conformance._reset_probe_hooks
    real_add = conformance._add_probe_hook
    real_configure = conformance._configure_mcp
    real_prepare = conformance._prepare_codex_hooks
    real_turn = conformance._vendor_turn
    seen = {}

    def fake_add(_home, _vendor, _event, _mode, marker, *, matcher=None, **_kwargs):
        seen["matcher"] = matcher
        seen["marker"] = marker

    def fake_configure(_home, _vendor, marker):
        seen["target"] = marker

    def fake_turn(_vendor, binary, _home, _workdir, _prompt, *, allowed_tool, **_kwargs):
        seen["allowed_tool"] = allowed_tool
        Path(seen["marker"]).write_text("observed\n", encoding="utf-8")
        Path(seen["target"]).write_text("called\n", encoding="utf-8")
        return conformance.subprocess.CompletedProcess([binary], 0, "{}", "")

    conformance._reset_probe_hooks = lambda *_args: None
    conformance._add_probe_hook = fake_add
    conformance._configure_mcp = fake_configure
    conformance._prepare_codex_hooks = lambda *_args: (True, "ready")
    conformance._vendor_turn = fake_turn
    try:
        status, detail = conformance._run_live_case(
            "codex", "/pinned/codex", home, workdir, "mcp-matcher-fires"
        )
    finally:
        conformance._reset_probe_hooks = real_reset
        conformance._add_probe_hook = real_add
        conformance._configure_mcp = real_configure
        conformance._prepare_codex_hooks = real_prepare
        conformance._vendor_turn = real_turn
        shutil.rmtree(home, ignore_errors=True)
        shutil.rmtree(workdir, ignore_errors=True)

    assert status == "passed", detail
    assert seen["matcher"] == "mcp__ihar_conformance__prove", seen
    assert seen["allowed_tool"] == "mcp__ihar_conformance__prove", seen


def test_deny_needs_an_explicit_probe_decision_not_only_an_absent_sentinel():
    store = _store()
    binary = _fake_claude(store)
    home = tempfile.mkdtemp(prefix="ihar-conf-home-")
    workdir = tempfile.mkdtemp(prefix="ihar-conf-work-")
    real_turn = conformance._vendor_turn

    def incomplete_turn(_vendor, _binary, selected_home, selected_workdir, _prompt, **_kwargs):
        block, _ = conformance._hook_block(selected_home, "claude")
        command = next(
            hook["command"] for group in block["PreToolUse"]
            for hook in group["hooks"] if "conformance-probe.py" in hook["command"]
        )
        marker = shlex.split(command)[4]
        with open(marker, "w", encoding="utf-8") as handle:
            handle.write("invoked\n")
        return conformance.subprocess.CompletedProcess([_binary], 0, "{}", "")

    import shlex
    conformance._vendor_turn = incomplete_turn
    try:
        conformance._stage(store, MANIFEST, "claude", home, auth_store=store)
        status, detail = conformance._run_live_case(
            "claude", binary, home, workdir, "deny-blocks-the-tool"
        )
    finally:
        conformance._vendor_turn = real_turn
        for directory in (store, home, workdir):
            shutil.rmtree(directory, ignore_errors=True)
    assert status == "failed", detail
    assert "deny decision" in detail


def test_timeout_rejects_a_vendor_that_ignores_the_configured_limit():
    store = _store()
    binary = _fake_claude(store)
    home = tempfile.mkdtemp(prefix="ihar-conf-home-")
    workdir = tempfile.mkdtemp(prefix="ihar-conf-work-")
    os.environ["IHAR_FAKE_IGNORE_TIMEOUT"] = "1"
    try:
        conformance._stage(store, MANIFEST, "claude", home, auth_store=store)
        status, detail = conformance._run_live_case(
            "claude", binary, home, workdir, "timeout-behaviour"
        )
    finally:
        os.environ.pop("IHAR_FAKE_IGNORE_TIMEOUT", None)
        for directory in (store, home, workdir):
            shutil.rmtree(directory, ignore_errors=True)
    assert status == "failed", detail
    assert "timeout" in detail.lower()


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
    assert claude_argv.index("prompt") < claude_argv.index("--allowedTools"), claude_argv
    assert claude_argv[claude_argv.index("--allowedTools") + 1] == "Bash", claude_argv
    assert claude_kwargs["env"]["CLAUDE_CONFIG_DIR"] == "/runtime"
    assert codex_argv[:2] == ["/pinned/codex", "exec"], codex_argv
    assert codex_kwargs["env"]["CODEX_HOME"] == "/runtime"


def test_claude_shell_places_prompt_before_variadic_allowed_tools():
    seen = []
    real_run = conformance.subprocess.run

    def fake_run(argv, **kwargs):
        seen.append((argv, kwargs))
        return conformance.subprocess.CompletedProcess(argv, 0, "", "")

    conformance.subprocess.run = fake_run
    try:
        conformance._run_claude_shell(
            "/pinned/claude", "/runtime", "/work", "printf measured"
        )
    finally:
        conformance.subprocess.run = real_run

    argv, _kwargs = seen[0]
    prompt = argv[2]
    assert "printf measured" in prompt, argv
    assert argv.index(prompt) < argv.index("--allowedTools"), argv


def test_deny_probe_returns_json_decision_with_success_status():
    with tempfile.TemporaryDirectory(prefix="ihar-conf-probe-") as raw:
        script = Path(raw, "probe.py")
        marker = Path(raw, "marker")
        script.write_text(conformance._PROBE_SCRIPT, encoding="utf-8")
        result = subprocess.run(
            [sys.executable, str(script), "deny", str(marker)],
            input='{"hook_event_name":"PreToolUse"}',
            capture_output=True,
            text=True,
            check=False,
        )

    assert result.returncode == 0, result
    output = json.loads(result.stdout)["hookSpecificOutput"]
    assert output["hookEventName"] == "PreToolUse"
    assert output["permissionDecision"] == "deny"


def test_failed_rewrite_has_a_closed_reason():
    assert conformance._reason_for(
        "failed", "the vendor executed the unrewritten secret"
    ) == "rewrite-not-applied"


def test_claude_structured_api_error_is_environmental_without_reading_result_text():
    payload = json.dumps({
        "type": "result",
        "subtype": "success",
        "is_error": True,
        "terminal_reason": "api_error",
        "api_error_status": 503,
        "result": "SECRET-SENTINEL",
    })

    assert conformance._environment_reason(payload, "", 1) == "vendor-api-error"
    assert conformance._environment_reason(
        json.dumps({
            "type": "result",
            "is_error": True,
            "terminal_reason": "api_error",
            "result": "SECRET-SENTINEL",
        }),
        "",
        1,
    ) == ""
    assert conformance._environment_reason(
        json.dumps({
            "type": "result",
            "subtype": "success",
            "is_error": True,
            "terminal_reason": "turn_setup_failed",
            "result": "Please log in because quota and connection refused SECRET-SENTINEL",
        }),
        "",
        1,
    ) == ""
    assert conformance._environment_reason(
        json.dumps({"result": "Please log in because quota and connection refused"}),
        "",
        1,
    ) == ""
    structured_lines = "\n".join((
        json.dumps({"type": "account", "message": "Please log in"}),
        json.dumps({"type": "model", "message": "quota connection refused"}),
    ))
    assert conformance._environment_reason(structured_lines, "", 1) == ""
    assert conformance._environment_reason(
        structured_lines + "\nordinary legacy diagnostic", "", 1
    ) == ""
    assert conformance._environment_reason(
        json.dumps({"result": "SECRET-SENTINEL"}),
        "connection refused",
        1,
    ) == "vendor-unreachable"
    assert conformance._environment_reason(
        "", "x" * conformance._ENVIRONMENT_SCAN_LIMIT + " connection refused", 1
    ) == ""


def test_claude_shell_records_structured_api_error_for_sandbox_cases():
    real_run = conformance.subprocess.run

    def fake_run(argv, **_kwargs):
        payload = json.dumps({
            "type": "result",
            "subtype": "success",
            "is_error": True,
            "terminal_reason": "api_error",
            "result": "SECRET-SENTINEL",
        })
        return conformance.subprocess.CompletedProcess(argv, 1, payload, "")

    conformance.subprocess.run = fake_run
    conformance._LAST_TURN.clear()
    try:
        conformance._run_claude_shell(
            "/pinned/claude", "/runtime", "/work", "printf measured"
        )
    finally:
        conformance.subprocess.run = real_run

    assert conformance._LAST_TURN == {"environment": "vendor-api-error"}


def test_observed_hook_marker_outranks_a_later_api_error():
    store = _store()
    home = tempfile.mkdtemp(prefix="ihar-conf-home-")
    workdir = tempfile.mkdtemp(prefix="ihar-conf-work-")
    original_turn = conformance._vendor_turn

    def post_dispatch_error(_vendor, binary, selected_home, _workdir, *_args, **_kwargs):
        block, _ = conformance._hook_block(selected_home, "claude")
        command = next(
            hook["command"] for group in block["PreToolUse"]
            for hook in group["hooks"] if "conformance-probe.py" in hook["command"]
        )
        Path(shlex.split(command)[4]).write_text("observed\n", encoding="utf-8")
        conformance._LAST_TURN["environment"] = "vendor-api-error"
        return conformance.subprocess.CompletedProcess([binary], 1, "{}", "")

    import shlex
    conformance._vendor_turn = post_dispatch_error
    conformance._LAST_TURN.clear()
    try:
        conformance._stage(store, MANIFEST, "claude", home, auth_store=store)
        status, detail = conformance._run_live_case(
            "claude", "claude", home, workdir, "deny-blocks-the-tool"
        )
    finally:
        conformance._vendor_turn = original_turn
        for directory in (store, home, workdir):
            shutil.rmtree(directory, ignore_errors=True)

    assert status == "failed", detail
    assert conformance._LAST_TURN["dispatch_observed"] is True


def test_session_start_marker_does_not_claim_tool_dispatch_before_api_error():
    store = _store()
    home = tempfile.mkdtemp(prefix="ihar-conf-home-")
    workdir = tempfile.mkdtemp(prefix="ihar-conf-work-")
    original_turn = conformance._vendor_turn

    def api_error_after_session_start(
        _vendor, binary, selected_home, _workdir, *_args, **_kwargs,
    ):
        block, _ = conformance._hook_block(selected_home, "claude")
        command = next(
            hook["command"] for group in block["SessionStart"]
            for hook in group["hooks"] if "conformance-probe.py" in hook["command"]
        )
        Path(shlex.split(command)[4]).write_text("observed\n", encoding="utf-8")
        payload = json.dumps({
            "type": "result",
            "subtype": "success",
            "is_error": True,
            "terminal_reason": "api_error",
            "result": "SECRET-SENTINEL",
        })
        conformance._LAST_TURN["environment"] = conformance._environment_reason(
            payload, "", 1,
        )
        return conformance.subprocess.CompletedProcess([binary], 1, payload, "")

    import shlex
    conformance._vendor_turn = api_error_after_session_start
    conformance._LAST_TURN.clear()
    try:
        conformance._stage(store, MANIFEST, "claude", home, auth_store=store)
        status, detail = conformance._run_live_case(
            "claude", "claude", home, workdir, "session-start-context"
        )
        downstream_target = Path(workdir, ".session-start-context-target")
        target_exists = downstream_target.exists()
    finally:
        conformance._vendor_turn = original_turn
        for directory in (store, home, workdir):
            shutil.rmtree(directory, ignore_errors=True)

    assert status == "failed", detail
    assert target_exists is False
    assert conformance._LAST_TURN["environment"] == "vendor-api-error"
    assert conformance._LAST_TURN["dispatch_observed"] is False


def test_observed_sandbox_sentinel_outranks_a_later_api_error():
    home = tempfile.mkdtemp(prefix="ihar-conf-home-")
    workdir = tempfile.mkdtemp(prefix="ihar-conf-work-")
    original_shell = conformance._run_claude_shell

    def post_dispatch_error(_binary, _home, _workdir, command):
        target = shlex.split(command)[-1]
        Path(target).write_text("ihar-conformance\n", encoding="utf-8")
        conformance._LAST_TURN["environment"] = "vendor-api-error"
        return conformance.subprocess.CompletedProcess([_binary], 1, "{}", "")

    import shlex
    conformance._run_claude_shell = post_dispatch_error
    conformance._LAST_TURN.clear()
    try:
        status, detail = conformance.case_sandbox_workspace_write(
            "claude", "claude", home, workdir
        )
    finally:
        conformance._run_claude_shell = original_shell
        for directory in (home, workdir):
            shutil.rmtree(directory, ignore_errors=True)

    assert status == "failed", detail
    assert conformance._LAST_TURN["dispatch_observed"] is True


def test_observed_sandbox_status_outranks_a_later_api_error():
    store = _store()
    home = tempfile.mkdtemp(prefix="ihar-conf-home-")
    workdir = tempfile.mkdtemp(prefix="ihar-conf-work-")
    protected = tempfile.mkdtemp(prefix="ihar-conf-protected-")
    original_shell = conformance._run_claude_shell

    def post_dispatch_error(_binary, _home, _workdir, command):
        redirects = re.findall(r"> ([^;]+)", command)
        before = shlex.split(redirects[0])[0]
        after = shlex.split(redirects[-1])[0]
        Path(before).write_text("ihar-conformance\n", encoding="utf-8")
        Path(after).write_text("1\n", encoding="utf-8")
        conformance._LAST_TURN["environment"] = "vendor-api-error"
        return conformance.subprocess.CompletedProcess([_binary], 1, "{}", "")

    import shlex
    conformance._run_claude_shell = post_dispatch_error
    conformance._LAST_TURN.clear()
    try:
        conformance._stage(
            store, MANIFEST, "claude", home, [protected], auth_store=store,
        )
        status, detail = conformance.case_sandbox_direct_write(
            "claude", "claude", home, workdir
        )
    finally:
        conformance._run_claude_shell = original_shell
        for directory in (store, home, workdir, protected):
            shutil.rmtree(directory, ignore_errors=True)

    assert status == "failed", detail
    assert conformance._LAST_TURN["dispatch_observed"] is True


def test_run_marks_only_api_stopped_cases_unmeasured():
    store = tempfile.mkdtemp(prefix="ihar-conf-api-error-")
    binary = os.path.join(store, "claude")
    manifest = os.path.join(store, "manifest")
    Path(binary).write_text("fixture\n", encoding="utf-8")
    Path(manifest).write_text("fixture\n", encoding="utf-8")
    original_cases = conformance.CASES
    original_live_cases = conformance.LIVE_CASES
    original_live_case = conformance._run_live_case
    original_stage = conformance._stage
    original_version = conformance.vendor_version
    original_validate = conformance._validate_release_pin

    def api_failure(*_args):
        conformance._LAST_TURN["environment"] = "vendor-api-error"
        conformance._LAST_TURN["dispatch_observed"] = False
        return "failed", "Claude exited before the sandbox probe"

    def hook_failure(*_args):
        return "failed", "the vendor exited 1 without firing the probe hook"

    def post_dispatch_api_failure(*_args):
        conformance._LAST_TURN["environment"] = "vendor-api-error"
        conformance._LAST_TURN["dispatch_observed"] = True
        return "failed", "the vendor fired the hook but the turn exited 1"

    conformance.CASES = {
        "sandbox-direct-write": api_failure,
        "sandbox-observed-api-error": post_dispatch_api_failure,
        "real-hook-failure": hook_failure,
    }
    conformance.LIVE_CASES = frozenset({
        "deny-blocks-the-tool", "session-start-context",
    })
    conformance._run_live_case = api_failure
    conformance._stage = lambda *_args, **_kwargs: None
    conformance.vendor_version = lambda *_args: "2.1.274 (Claude Code)"
    conformance._validate_release_pin = lambda *_args: None
    try:
        record = conformance.run(
            "claude", binary, store, manifest,
            auth_store=store, lockfile_path=LOCKFILE,
        )
    finally:
        conformance.CASES = original_cases
        conformance.LIVE_CASES = original_live_cases
        conformance._run_live_case = original_live_case
        conformance._stage = original_stage
        conformance.vendor_version = original_version
        conformance._validate_release_pin = original_validate
        shutil.rmtree(store, ignore_errors=True)

    assert record["cases"]["sandbox-direct-write"] == {
        "status": "unmeasured",
        "detail": "sandbox-direct-write: unmeasured",
        "reason": "vendor-api-error",
    }
    assert record["cases"]["deny-blocks-the-tool"]["status"] == "unmeasured"
    assert record["cases"]["sandbox-observed-api-error"]["status"] == "failed"
    assert record["cases"]["sandbox-observed-api-error"]["reason"] == \
        "vendor-exited-nonzero"
    assert record["cases"]["session-start-context"]["status"] == "unmeasured"
    assert record["cases"]["session-start-context"]["reason"] == "vendor-api-error"
    assert record["cases"]["real-hook-failure"]["status"] == "failed"
    assert record["cases"]["real-hook-failure"]["reason"] == "hook-never-fired"


def test_staged_vendor_home_uses_stable_login_without_exposing_codex_canonical():
    stage = _store()
    active = tempfile.mkdtemp(prefix="ihar-conf-active-store-")
    try:
        for vendor, name in (("claude", ".credentials.json"), ("codex", "auth.json")):
            source_dir = os.path.join(active, "auth", vendor)
            os.makedirs(source_dir, exist_ok=True)
            if vendor == "codex":
                os.chmod(os.path.join(active, "auth"), 0o700)
                os.chmod(source_dir, 0o700)
            source = os.path.join(source_dir, name)
            with open(source, "w", encoding="utf-8") as handle:
                handle.write("login evidence\n")
            home = (str(auth_owner.stage(active)) if vendor == "codex"
                    else tempfile.mkdtemp(prefix=f"ihar-conf-{vendor}-"))
            try:
                if vendor == "codex":
                    auth_owner._seed_stage_from_canonical(Path(home), Path(active))
                conformance._stage(stage, MANIFEST, vendor, home, auth_store=active)
                target = os.path.join(home, name)
                if vendor == "codex":
                    assert os.path.isfile(target) and not os.path.islink(target)
                    assert Path(target).read_bytes() == Path(source).read_bytes()
                    Path(target).write_text("synthetic-candidate", encoding="utf-8")
                    assert Path(source).read_text(encoding="utf-8") == "login evidence\n"
                else:
                    assert os.path.islink(target), f"{vendor} login was copied or omitted"
                    assert os.path.realpath(target) == os.path.realpath(source)
                assert not os.path.exists(os.path.join(stage, "auth", vendor, name))
            finally:
                if vendor == "codex":
                    guardian._cleanup_auth_stage(Path(active), Path(home))
                else:
                    shutil.rmtree(home, ignore_errors=True)
    finally:
        shutil.rmtree(stage, ignore_errors=True)
        shutil.rmtree(active, ignore_errors=True)


def test_failed_codex_conformance_retains_changed_auth():
    store = _store()
    binary = os.path.join(store, "codex")
    canonical = os.path.join(store, "auth", "codex", "auth.json")
    os.makedirs(os.path.dirname(canonical), mode=0o700, exist_ok=True)
    os.chmod(os.path.join(store, "auth"), 0o700)
    os.chmod(os.path.dirname(canonical), 0o700)
    with open(canonical, "w", encoding="utf-8") as handle:
        handle.write("synthetic-original")
    os.chmod(canonical, 0o600)
    with open(binary, "w", encoding="utf-8") as handle:
        handle.write("#!/bin/sh\nprintf 'codex-cli 0.154.0\\n'\n")
    os.chmod(binary, 0o700)

    original_cases = conformance.CASES
    original_live_cases = conformance.LIVE_CASES
    def change_auth(_vendor, _binary, home, _workdir):
        with open(os.path.join(home, "auth.json"), "w", encoding="utf-8") as handle:
            handle.write("synthetic-candidate")
        return "failed", "synthetic failure"

    conformance.CASES = {"changed-auth": change_auth}
    conformance.LIVE_CASES = frozenset()
    try:
        record = conformance.run(
            "codex", binary, store, MANIFEST,
            auth_store=store, lockfile_path=LOCKFILE,
        )
        recovery = list(Path(store, "auth", "codex", "recovery").glob("*/auth.json"))
        assert record["cases"]["changed-auth"]["status"] == "failed"
        assert Path(canonical).read_bytes() == b"synthetic-original"
        assert len(recovery) == 1, recovery
        assert recovery[0].read_bytes() == b"synthetic-candidate"
        assert stat.S_IMODE(recovery[0].stat().st_mode) == 0o600
        assert stat.S_IMODE(recovery[0].parent.stat().st_mode) == 0o700
        metadata = b"".join(
            path.read_bytes() for path in recovery[0].parent.rglob("*")
            if path.is_file() and path != recovery[0]
        )
        assert b"synthetic-candidate" not in metadata
    finally:
        conformance.CASES = original_cases
        conformance.LIVE_CASES = original_live_cases
        shutil.rmtree(store, ignore_errors=True)


def test_run_rejects_a_binary_that_does_not_match_the_release_pin():
    store = _store()
    binary = os.path.join(store, "codex")
    with open(binary, "w", encoding="utf-8") as handle:
        handle.write("#!/bin/sh\nprintf 'codex-cli 9.9.9\\n'\n")
    os.chmod(binary, 0o755)
    try:
        try:
            conformance.run(
                "codex", binary, store, MANIFEST,
                auth_store=store, lockfile_path=LOCKFILE,
            )
        except RuntimeError as error:
            assert "pinned" in str(error)
        else:
            raise AssertionError("an unpinned vendor binary produced conformance evidence")
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
            return conformance.subprocess.CompletedProcess(argv, 0, "2.1.274 (Claude Code)\n", "")
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
            "claude", binary, store, MANIFEST,
            auth_store=active_store,
            lockfile_path=LOCKFILE,
            protected_store=active_store,
        )
        protected_paths = tuple(probe_paths)
        protected_seen = {kind: set(paths) for kind, paths in seen.items()}
        protected_attempted = {kind: set(paths) for kind, paths in attempted.items()}
        mode[0] = "unavailable"
        unavailable_record = conformance.run(
            "claude", binary, store, MANIFEST,
            auth_store=active_store, lockfile_path=LOCKFILE,
        )
        mode[0] = "unsandboxed"
        unsandboxed_record = conformance.run(
            "claude", binary, store, MANIFEST,
            auth_store=active_store, lockfile_path=LOCKFILE,
        )
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
        record = conformance.run(
            "codex", CODEX, store, MANIFEST,
            auth_store=store, lockfile_path=LOCKFILE,
        )
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
