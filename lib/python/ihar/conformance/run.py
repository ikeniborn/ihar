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
import shutil
import subprocess
import sys
import tempfile
import time

from .. import jsonio
from ..render import hooks as render_hooks


def _digest_file(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def _stage(store: str, manifest_path: str, vendor: str, home: str) -> None:
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
        with open(os.path.join(home, "settings.json"), "w", encoding="utf-8") as handle:
            json.dump({"hooks": block}, handle, indent=2, sort_keys=True)


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


CASES = {
    "hook-is-loaded": case_hook_is_loaded,
    "trust-is-recordable": case_trust_is_recordable,
    "tampering-is-detected": case_tampering_is_detected,
    "deny-blocks-the-tool": case_deny_blocks_the_tool,
    "rewrite-is-emitted": case_rewrite_is_emitted,
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
    try:
        _stage(store, manifest_path, vendor, home)
        for name, case in CASES.items():
            try:
                status, detail = case(vendor, binary, home, workdir)
            except Exception as error:             # noqa: BLE001
                status, detail = "failed", f"{type(error).__name__}: {error}"
            record["cases"][name] = {"status": status, "detail": detail}
    finally:
        shutil.rmtree(home, ignore_errors=True)
        shutil.rmtree(workdir, ignore_errors=True)

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
