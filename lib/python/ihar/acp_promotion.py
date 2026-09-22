"""Measure whether the ACP chat tab may leave experimental status (LLD 13.3, plan S13.4).

The condition was written as prose in the plan and then re-checked by hand, which is how a
promotion decision turns into a recollection. This runs it instead: each condition is a row
in `manifests/acp-promotion.json`, each measurement answers `passed`, `failed` or
`unmeasured`, and the verdict is `promotable` only when every row passed.

`unmeasured` is not a near-pass. A closed issue nobody could read, a probe that needs an
adapter this machine does not have, a probe whose assertion has never been measured against
a real adapter: each keeps the verdict at `not promotable`, because the point of the gate is
that promotion rests on evidence rather than on the absence of contrary evidence.

Failure class: fail-soft. The gate reports; it changes no profile and promotes nothing by
itself. Exit code 0 when promotable, 1 when not, 2 on a usage error.

Usage: python3 -m ihar.acp_promotion --manifest <f> [--json] [--record <f>]
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

from . import jsonio
from .console.acp import AcpClient

GITHUB_API = "https://api.github.com"
TIMEOUT = 15


def _now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def fetch_issue(repo: str, number: int) -> dict:
    """One issue's state, through `gh` when it is installed and plain HTTPS otherwise.

    A network this machine does not have is `unmeasured`, never `passed`: an unreachable
    tracker says nothing about whether the behaviour landed.
    """
    if shutil.which("gh"):
        result = subprocess.run(
            ["gh", "api", f"repos/{repo}/issues/{number}", "--jq",
             "{state: .state, title: .title, closed_at: .closed_at}"],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=TIMEOUT)
        if result.returncode == 0:
            try:
                return json.loads(result.stdout)
            except ValueError:
                pass
    request = urllib.request.Request(
        f"{GITHUB_API}/repos/{repo}/issues/{number}",
        headers={"Accept": "application/vnd.github+json", "User-Agent": "ihar"})
    with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
        payload = json.load(response)
    return {"state": payload.get("state"), "title": payload.get("title"),
            "closed_at": payload.get("closed_at")}


def measure_issue(condition: dict, fetch=fetch_issue) -> dict:
    repo, number = condition["repo"], condition["issue"]
    try:
        issue = fetch(repo, number)
    except (urllib.error.URLError, OSError, subprocess.SubprocessError, ValueError) as error:
        return {"state": "unmeasured", "detail": f"the tracker could not be read: {error}"}
    state = (issue or {}).get("state")
    title = (issue or {}).get("title") or ""
    if state == "closed":
        return {"state": "passed", "detail": f"{repo}#{number} is closed: {title}"}
    if state == "open":
        return {"state": "failed", "detail": f"{repo}#{number} is open: {title}"}
    return {"state": "unmeasured", "detail": f"{repo}#{number} answered no usable state"}


def adapter_present(vendor: str) -> str | None:
    """The installed adapter's executable, or None when it was never installed."""
    name = {"claude": "IHAR_CLAUDE_ACP_BIN", "codex": "IHAR_CODEX_ACP_BIN"}[vendor]
    path = os.environ.get(name, "")
    return path if path and os.path.exists(path) else None


def vendor_authenticated(vendor: str) -> bool:
    """Whether the vendor has credentials here; without them no session can start."""
    store = os.environ.get("IHAR_STORE", "")
    directory = Path(store) / "auth" / vendor
    try:
        return any(directory.iterdir())
    except OSError:
        return False


def measure_probe(condition: dict, probes=None) -> dict:
    """Run one behavioural probe, or say plainly why it could not run."""
    vendor = condition["vendor"]
    if condition.get("unimplemented"):
        return {"state": "unmeasured", "detail": condition["unimplemented"]}
    if not adapter_present(vendor):
        return {"state": "unmeasured",
                "detail": f"the {vendor} ACP adapter is not installed; run 'ihar install --acp'"}
    if not vendor_authenticated(vendor):
        return {"state": "unmeasured",
                "detail": f"{vendor} has no credentials in this store, so no session can start"}
    probe = (probes or {}).get(condition["id"])
    if probe is None:
        return {"state": "unmeasured", "detail": "no probe is wired for this condition"}
    return probe()


def probe_claude_hooks(project: str, state: str, cli: str, timeout: float = 60.0) -> dict:
    """Observe whether a shipped hook fires inside a real ACP session.

    The observation uses the `session-status` hook the console already ships: it writes one
    record per session on `SessionStart`, so a record appearing for this session is the
    adapter firing settings hooks, and its absence is the behaviour issue #144 describes.
    No probe-only hook is installed, because a hook written for the measurement would prove
    that hook fires rather than that the shipped ones do.
    """
    before = set(_status_names(state))
    seen: list[dict] = []
    client = AcpClient([cli, "acp", "claude"], project, dict(os.environ), seen.append)
    try:
        client.start()
        deadline = time.time() + timeout
        session = False
        while time.time() < deadline:
            session = session or any(event.get("type") == "session" for event in seen)
            if session:
                appeared = set(_status_names(state)) - before
                if appeared:
                    return {"state": "passed",
                            "detail": f"a session start hook wrote {sorted(appeared)[0]}"}
            if any(event.get("type") == "exit" for event in seen):
                break
            time.sleep(0.5)
        if not session:
            return {"state": "unmeasured",
                    "detail": "the adapter never reported a session; nothing could be observed"}
        return {"state": "failed",
                "detail": "the session started and no hook record appeared (issue #144)"}
    except OSError as error:
        return {"state": "unmeasured", "detail": f"the adapter could not be started: {error}"}
    finally:
        client.stop()


def _status_names(state: str) -> list[str]:
    try:
        return [name for name in os.listdir(os.path.join(state, "status"))
                if name.startswith("claude-")]
    except OSError:
        return []


def measure(manifest: dict, fetch=fetch_issue, probes=None) -> dict:
    results = []
    for condition in manifest["conditions"]:
        if condition["kind"] == "issue":
            outcome = measure_issue(condition, fetch)
        else:
            outcome = measure_probe(condition, probes)
        results.append({"id": condition["id"], "kind": condition["kind"],
                        "requirement": condition["requirement"], **outcome})
    promotable = bool(results) and all(row["state"] == "passed" for row in results)
    return {"schema": 1, "measured_at": _now(), "promotable": promotable,
            "conditions": results}


def render_text(report: dict) -> str:
    lines = [f"acp promotion  {'promotable' if report['promotable'] else 'not promotable'}"]
    for row in report["conditions"]:
        lines.append(f"  {row['state']:<10} {row['id']}: {row['detail']}")
    if not report["promotable"]:
        lines.append("  the chat tab stays experimental; nothing here promotes it by itself")
    return "\n".join(lines) + "\n"


def main(argv=None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--record")
    args = parser.parse_args(argv)
    try:
        manifest = jsonio.read("acp-promotion", args.manifest)
    except (OSError, jsonio.SchemaError) as error:
        print(f"the promotion manifest is unusable: {error}", file=sys.stderr)
        return 2
    project = os.environ.get("IHAR_PROJECT_ROOT") or os.getcwd()
    state = os.environ.get("IHAR_STATE") or ""
    cli = os.environ.get("IHAR_CLI") or "ihar"
    probes = {}
    if state:
        probes["claude-hooks-fire"] = lambda: probe_claude_hooks(project, state, cli)
    report = measure(manifest, probes=probes)
    if args.record:
        jsonio.write("acp-promotion-result", args.record, report)
    print(json.dumps(report, indent=2, sort_keys=True) if args.json else render_text(report),
          end="" if not args.json else "\n")
    return 0 if report["promotable"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
