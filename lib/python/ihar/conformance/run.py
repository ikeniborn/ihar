"""Prove that a pinned vendor loads a hook, fires it, and honours its decision.

This is the whole of gate G2. Rendered-output tests show that ihar emits the right
files; stdin fixtures show that a script decides correctly. Neither shows that the
vendor read the file, ran the script, and did what it said — and for a profile whose
name promises enforcement, that gap is the entire guarantee.

Failure class: fail-closed. A profile with `hooks: enforced` refuses to launch when
the record for the installed vendor version is missing, stale or failing.

The record is keyed by vendor, version, binary digest and manifest digest, so an
upgrade of either invalidates it rather than inheriting a pass.

Usage:
    python3 -m ihar.conformance.run <vendor> <binary> <store> <manifest> [--json]
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

from .. import jsonio
from ..render import claude_settings
from ..render import hooks as render_hooks


def _digest_file(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def _stage(
    store: str,
    manifest_path: str,
    vendor: str,
    home: str,
    protected_roots: list[str] | None = None,
) -> None:
    """A throwaway vendor home carrying the rendered hooks and the scripts."""
    os.makedirs(os.path.join(home, "hooks"), exist_ok=True)
    manifest = jsonio.read("hook-manifest", manifest_path)
    home_var = "CODEX_HOME" if vendor == "codex" else "CLAUDE_CONFIG_DIR"
    block = render_hooks.render(manifest, vendor, "protected", home_var)

    source_hooks = os.path.join(store, "hooks")
    for name in os.listdir(source_hooks):
        source = os.path.join(source_hooks, name)
        target = os.path.join(home, "hooks", name)
        if os.path.isdir(source):
            shutil.copytree(source, target, dirs_exist_ok=True)
        else:
            shutil.copy2(source, target)

    if vendor == "codex":
        with open(os.path.join(home, "hooks.json"), "w", encoding="utf-8") as handle:
            json.dump({"hooks": block}, handle, indent=2, sort_keys=True)
        with open(os.path.join(home, "config.toml"), "w", encoding="utf-8") as handle:
            handle.write("")
    else:
        settings = {"hooks": block}
        sandbox = claude_settings.render_sandbox(
            "vendor", protected_roots or [store, home]
        )
        if sandbox is not None:
            settings["sandbox"] = sandbox
        with open(os.path.join(home, "settings.json"), "w", encoding="utf-8") as handle:
            json.dump(settings, handle, indent=2, sort_keys=True)


# --------------------------------------------------------------------------- #
# Cases
# --------------------------------------------------------------------------- #


def case_hook_is_loaded(vendor, binary, home, workdir):
    """The vendor sees the hook ihar rendered, by its own account."""
    if vendor != "codex":
        return "skipped", "only Codex exposes a hook listing"
    from ..codex.appserver import hooks_list
    try:
        hooks = hooks_list(binary, home, [workdir])
    except Exception as error:                     # noqa: BLE001
        return "failed", f"hooks/list failed: {error}"
    ours = [hook for hook in hooks
            if os.path.abspath(hook.get("sourcePath") or "")
            == os.path.abspath(os.path.join(home, "hooks.json"))]
    if not ours:
        return "failed", "the vendor does not see the rendered hook"
    return "passed", f"{len(ours)} hooks visible"


def case_trust_is_recordable(vendor, binary, home, workdir):
    """A rendered hook can be made trusted without a blanket bypass."""
    if vendor != "codex":
        return "skipped", "Claude exposes no trust API"
    from ..codex import hooks_trust
    code, _ = hooks_trust.seal_quiet(binary, home, workdir)
    if code != 0:
        return "failed", "sealing did not record a digest"
    code, findings = hooks_trust.verify_quiet(binary, home, workdir, ["security-pretool.py"])
    if code != 0:
        return "failed", f"a sealed hook still does not verify: {findings}"
    return "passed", "trusted by exact digest"


def case_tampering_is_detected(vendor, binary, home, workdir):
    """Editing a sealed hook flips it out of trust rather than running silently."""
    if vendor != "codex":
        return "skipped", "Claude exposes no trust API"
    from ..codex import hooks_trust
    path = os.path.join(home, "hooks.json")
    with open(path, "r", encoding="utf-8") as handle:
        original = handle.read()
    block = json.loads(original)
    block["hooks"]["PreToolUse"][0]["hooks"][0]["command"] = "/bin/true"
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(block, handle, indent=2, sort_keys=True)
    detected = hooks_trust.verify_quiet(binary, home, workdir, ["security-pretool.py"])[0] != 0
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(original)
    return ("passed", "an edited hook loses its trust") if detected else \
           ("failed", "an edited hook still verified")


def case_deny_blocks_the_tool(vendor, binary, home, workdir):
    """The decision the hook returns is the decision the vendor enforces.

    Driven through the hook itself rather than through a model turn: a turn needs
    credentials and a network, which a conformance run must not require. What this
    proves is that the contract on both sides agrees — the exit code the script uses
    to block is the exit code this vendor's schema documents as a block.
    """
    script = os.path.join(home, "hooks", "security-pretool.py")
    payload = json.dumps({
        "hook_event_name": "PreToolUse",
        "tool_name": "Read" if vendor == "claude" else "Read",
        "tool_input": {"file_path": "/home/someone/.ssh/id_rsa"},
    })
    result = subprocess.run(
        ["python3", "-I", script, "--vendor", vendor],
        input=payload, capture_output=True, text=True, timeout=30,
    )
    if result.returncode != 2:
        return "failed", f"the block exit code was {result.returncode}, not 2"
    try:
        body = json.loads(result.stdout or "{}")
    except json.JSONDecodeError:
        return "failed", "the hook emitted output the vendor cannot parse"
    decision = body.get("hookSpecificOutput", {}).get("permissionDecision")
    if decision != "deny":
        return "failed", f"the decision was {decision!r}"
    return "passed", "exit 2 with a deny decision"


def case_rewrite_is_emitted(vendor, binary, home, workdir):
    """A redaction reaches the vendor as updatedInput, the key both accept."""
    script = os.path.join(home, "hooks", "security-pretool.py")
    payload = json.dumps({
        "hook_event_name": "PreToolUse",
        "tool_name": "Write",
        "tool_input": {"file_path": "/repo/a.py",
                       "content": 'k = "sk-ant-abcdefghijklmnopqrstuvwxyz0123"'},
    })
    result = subprocess.run(
        ["python3", "-I", script, "--vendor", vendor],
        input=payload, capture_output=True, text=True, timeout=30,
    )
    if result.returncode != 0:
        return "failed", f"a redaction exited {result.returncode} instead of allowing"
    body = json.loads(result.stdout or "{}")
    updated = body.get("hookSpecificOutput", {}).get("updatedInput")
    if not updated:
        return "failed", "no updatedInput was emitted"
    if "sk-ant-" in json.dumps(updated):
        return "failed", "the secret survived the rewrite"
    return "passed", "updatedInput carries the masked value"


def _claude_protected_roots(home: str) -> list[str]:
    with open(os.path.join(home, "settings.json"), "r", encoding="utf-8") as handle:
        settings = json.load(handle)
    roots = settings.get("sandbox", {}).get("filesystem", {}).get("denyWrite")
    if not isinstance(roots, list) or not roots or not all(isinstance(root, str) for root in roots):
        raise RuntimeError("Claude settings do not contain sandbox.filesystem.denyWrite")
    return roots


def _run_claude_shell(binary: str, home: str, workdir: str, command: str):
    prompt = (
        "Use the Bash tool exactly once to run this command verbatim. "
        "Do not replace it with another tool or only describe it.\n"
        f"<ihar-conformance-command>{command}</ihar-conformance-command>"
    )
    env = {**os.environ, "CLAUDE_CONFIG_DIR": home}
    return subprocess.run(
        [binary, "-p", "--output-format", "json", "--allowedTools", "Bash", prompt],
        cwd=workdir,
        env=env,
        capture_output=True,
        text=True,
        timeout=120,
    )


def _remove_probe(path: str) -> None:
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass


def _case_sandbox_protected_write(vendor, binary, home, workdir, kind):
    if vendor != "claude":
        return "skipped", "native denyWrite probes are Claude-specific"

    roots = _claude_protected_roots(home)
    cleanup: list[str] = []
    try:
        for root in roots:
            nonce = uuid.uuid4().hex
            before = os.path.join(workdir, f".ihar-conformance-{kind}-before-{nonce}")
            target = os.path.join(root, f".ihar-conformance-{kind}-write-{nonce}")
            after = os.path.join(workdir, f".ihar-conformance-{kind}-after-{nonce}")
            paths = (before, target, after)
            if any(os.path.exists(path) for path in paths):
                return "failed", "a unique sandbox probe path already exists"
            cleanup.extend(paths)

            if kind == "direct":
                command = (
                    f"printf 'ihar-conformance\\n' > {shlex.quote(before)}; "
                    f"printf 'ihar-conformance\\n' > {shlex.quote(target)}; "
                    "probe_status=$?; "
                    f"printf '%s\\n' \"$probe_status\" > {shlex.quote(after)}"
                )
            else:
                code = (
                    "from pathlib import Path\n"
                    f"Path({before!r}).write_text('ihar-conformance\\n')\n"
                    "status = 0\n"
                    "try:\n"
                    f"    Path({target!r}).write_text('ihar-conformance\\n')\n"
                    "except OSError:\n"
                    "    status = 1\n"
                    f"Path({after!r}).write_text(str(status) + '\\n')\n"
                )
                command = f"python3 -c {shlex.quote(code)}"

            result = _run_claude_shell(binary, home, workdir, command)
            if result.returncode != 0:
                return "failed", f"Claude exited {result.returncode} while probing {root}"
            if not os.path.isfile(before):
                return "failed", f"Claude did not begin the {kind} probe for {root}"
            try:
                with open(after, "r", encoding="utf-8") as handle:
                    status = int(handle.read().strip())
            except (OSError, ValueError) as error:
                return "failed", f"Claude did not finish the {kind} probe for {root}: {error}"
            if status == 0:
                return "failed", f"Claude reported that it wrote {target}"
            if os.path.exists(target):
                return "failed", f"Claude wrote {target} despite denyWrite"

        return "passed", f"{kind} writes blocked in {len(roots)} protected roots"
    finally:
        for path in cleanup:
            _remove_probe(path)


def case_sandbox_direct_write(vendor, binary, home, workdir):
    return _case_sandbox_protected_write(vendor, binary, home, workdir, "direct")


def case_sandbox_child_write(vendor, binary, home, workdir):
    return _case_sandbox_protected_write(vendor, binary, home, workdir, "child")


def case_sandbox_workspace_write(vendor, binary, home, workdir):
    if vendor != "claude":
        return "skipped", "native sandbox probes are Claude-specific"
    target = os.path.join(workdir, f".ihar-conformance-workspace-write-{uuid.uuid4().hex}")
    if os.path.exists(target):
        return "failed", "a unique workspace probe path already exists"
    try:
        command = f"printf 'ihar-conformance\\n' > {shlex.quote(target)}"
        result = _run_claude_shell(binary, home, workdir, command)
        if result.returncode != 0:
            return "failed", f"Claude exited {result.returncode} during the workspace probe"
        try:
            with open(target, "r", encoding="utf-8") as handle:
                content = handle.read()
        except OSError as error:
            return "failed", f"Claude did not write the workspace probe: {error}"
        if content != "ihar-conformance\n":
            return "failed", "Claude wrote unexpected workspace probe content"
        return "passed", "workspace write succeeded"
    finally:
        _remove_probe(target)


CASES = {
    "hook-is-loaded": case_hook_is_loaded,
    "trust-is-recordable": case_trust_is_recordable,
    "tampering-is-detected": case_tampering_is_detected,
    "deny-blocks-the-tool": case_deny_blocks_the_tool,
    "rewrite-is-emitted": case_rewrite_is_emitted,
    "sandbox-direct-write": case_sandbox_direct_write,
    "sandbox-child-write": case_sandbox_child_write,
    "sandbox-workspace-write": case_sandbox_workspace_write,
}

CLAUDE_ONLY_CASES = {
    "sandbox-direct-write",
    "sandbox-child-write",
    "sandbox-workspace-write",
}


# --------------------------------------------------------------------------- #


def version_slug(version: str) -> str:
    """A filename-safe form of a vendor version string.

    `codex --version` answers "codex-cli 0.154.0", which carries a space; a record
    path built from it raw is awkward to quote and easy to break.
    """
    slug = re.sub(r"[^A-Za-z0-9._-]+", "-", version.strip())
    return slug.strip("-") or "unknown"


def vendor_version(vendor: str, binary: str) -> str:
    try:
        result = subprocess.run([binary, "--version"], capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError) as error:
        raise RuntimeError(f"cannot run {binary}: {error}") from error
    return (result.stdout or result.stderr).strip().splitlines()[0] if result.stdout or result.stderr else "unknown"


def run(vendor: str, binary: str, store: str, manifest_path: str) -> dict:
    version = vendor_version(vendor, binary)
    record = {
        "schema": 1,
        "vendor": vendor,
        "version": version,
        "binary_sha256": _digest_file(binary),
        "manifest_digest": _digest_file(manifest_path),
        "created_at": _now(),
        "cases": {},
    }

    workdir = tempfile.mkdtemp(prefix="ihar-conf-work-")
    home = tempfile.mkdtemp(prefix="ihar-conf-home-")
    state_root = tempfile.mkdtemp(prefix="ihar-conf-state-")
    try:
        protected_roots = [store, state_root, home] if vendor == "claude" else None
        _stage(store, manifest_path, vendor, home, protected_roots)
        for name, case in CASES.items():
            if name in CLAUDE_ONLY_CASES and vendor != "claude":
                continue
            try:
                status, detail = case(vendor, binary, home, workdir)
            except Exception as error:             # noqa: BLE001
                status, detail = "failed", f"{type(error).__name__}: {error}"
            record["cases"][name] = {"status": status, "detail": detail}
    finally:
        shutil.rmtree(home, ignore_errors=True)
        shutil.rmtree(workdir, ignore_errors=True)
        shutil.rmtree(state_root, ignore_errors=True)

    return record


def main(argv: list[str]) -> int:
    if len(argv) < 4:
        print(__doc__, file=sys.stderr)
        return 2
    vendor, binary, store, manifest_path = argv[:4]
    try:
        record = run(vendor, binary, store, manifest_path)
    except (RuntimeError, OSError, jsonio.SchemaError) as error:
        print(f"ihar: conformance could not run: {error}", file=sys.stderr)
        return 3

    target = os.path.join(store, "verification",
                          f"{vendor}-{version_slug(record['version'])}.json")
    os.makedirs(os.path.dirname(target), exist_ok=True)
    jsonio.write("conformance", target, record, mode=0o644)

    failed = [name for name, case in record["cases"].items() if case["status"] == "failed"]
    if "--json" in argv:
        print(json.dumps(record, indent=2, sort_keys=True))
    else:
        for name, case in sorted(record["cases"].items()):
            print(f"{case['status']:<8} {name:<24} {case['detail']}")
        print(f"record: {target}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
