"""Validate and render the collect-once ``ihar check`` result."""

from __future__ import annotations

import hashlib
import json
import os
import sys

from . import jsonio


def render_json(result: dict) -> str:
    jsonio.check("check-result", result)
    return json.dumps(result, indent=2, sort_keys=True, ensure_ascii=False)


def render_text(result: dict) -> str:
    jsonio.check("check-result", result)
    lines = [
        f"profile      {result['profile']['name']}",
        f"guarantee    {result['profile']['guarantee']}",
        "masking      "
        f"{result['masking']['level']} (floor {result['masking']['floor']}, "
        f"engine {result['masking']['engine']})",
        f"dropped env  {', '.join(result['masking']['dropped_env']) or 'none'}",
        f"gateway      {result['gateway']['mode']}",
        f"network      {result['gateway']['network_policy'] or 'not enforced'}",
    ]
    lines.extend(f"             {item}" for item in result["gateway"]["instances"])
    for vendor in ("claude", "codex"):
        item = result["vendors"][vendor]
        hooks = ", ".join(f"{hook['id']}={hook['trust']}" for hook in item["hooks"]) or "none"
        lines.append(
            f"{vendor:<12} receipt {item['receipt']}; hooks {hooks}; "
            f"conformance {item['conformance']}"
        )
        lines.append(f"             capabilities {', '.join(item['capabilities']) or 'none'}")
    for asset in result["assets"]:
        lines.append(
            f"asset        {asset['requirement']} {asset['presence']} "
            f"{asset['source']} -> {asset['target']}"
        )
    lines.append(f"mcp          {'strict' if result['mcp']['strict'] else 'not enforced'}")
    for vendor in ("claude", "codex"):
        lines.extend(f"             {vendor}: {note}" for note in result["mcp"]["notes"][vendor])
    lines.extend(f"known gap    {gap}" for gap in result["known_gaps"])
    return "\n".join(lines) + "\n"


def _split_lines(name: str) -> list[str]:
    return [line for line in os.environ.get(name, "").splitlines() if line]


def _hook_facts(vendor: str) -> list[dict[str, str]]:
    """Report each selected hook's observed vendor trust state without probing it."""
    manifest = jsonio.read("hook-manifest", os.environ["_IHAR_CHECK_MANIFEST"])
    runtime = os.environ[f"_IHAR_CHECK_{vendor.upper()}_RUNTIME"]
    config_name = "settings.json" if vendor == "claude" else "hooks.json"
    try:
        with open(os.path.join(runtime, config_name), encoding="utf-8") as handle:
            rendered = json.load(handle)
    except (OSError, json.JSONDecodeError):
        rendered = {}

    commands: set[str] = set()

    def collect_commands(value: object) -> None:
        if isinstance(value, dict):
            command = value.get("command")
            if isinstance(command, str):
                commands.add(command)
            for child in value.values():
                collect_commands(child)
        elif isinstance(value, list):
            for child in value:
                collect_commands(child)

    collect_commands(rendered)

    codex_recorded = False
    if vendor == "codex" and os.path.isfile(os.path.join(runtime, ".ihar-sealed")):
        try:
            with open(os.path.join(runtime, "config.toml"), encoding="utf-8") as handle:
                codex_recorded = "# ihar:hook-trust:start" in handle.read()
        except OSError:
            pass

    profile = os.environ["IHAR_PROFILE"]
    facts = []
    for entry in manifest["entries"]:
        if vendor not in entry["vendors"]:
            continue
        if "*" not in entry["profiles"] and profile not in entry["profiles"]:
            continue
        home_var = "CLAUDE_CONFIG_DIR" if vendor == "claude" else "CODEX_HOME"
        expected = f'python3 -I "${home_var}/hooks/{entry["script"]}"'
        if entry["args"]:
            expected += " " + " ".join(entry["args"])
        expected += f" --vendor {vendor}"
        configured = expected in commands
        trust = "unavailable"
        if configured:
            trust = "configured" if vendor == "claude" else ("recorded" if codex_recorded else "unavailable")
        facts.append({"id": entry["id"], "trust": trust})
    return sorted(facts, key=lambda item: item["id"])


def _collect(target: str) -> None:
    assets = []
    for line in _split_lines("_IHAR_CHECK_ASSETS"):
        requirement, presence, source, destination = line.split("\t", 3)
        assets.append({"requirement": requirement, "presence": presence, "source": source, "target": destination})

    vendors = {}
    for vendor in ("claude", "codex"):
        prefix = f"_IHAR_CHECK_{vendor.upper()}_"
        capabilities = json.loads(os.environ[prefix + "CAPABILITIES"])
        names = [name.replace("_", "-") for name, value in capabilities.items() if value is True]
        vendors[vendor] = {
            "receipt": os.environ[prefix + "RECEIPT"],
            "hooks": _hook_facts(vendor),
            "conformance": os.environ[prefix + "CONFORMANCE"],
            "capabilities": sorted(names),
        }

    result = {
        "schema": 1,
        "profile": {"name": os.environ["IHAR_PROFILE"], "guarantee": os.environ["IHAR_PROFILE_GUARANTEE"]},
        "masking": {
            "level": os.environ["IHAR_GATEWAY_MASKING_LEVEL"],
            "floor": os.environ["IHAR_PROFILE_MASKING_LEVEL"],
            "engine": os.environ.get("_IHAR_CHECK_MASK_ENGINE", "unknown"),
            "dropped_env": sorted(_split_lines("_IHAR_CHECK_DROPPED_ENV")),
        },
        "gateway": {
            "mode": os.environ["IHAR_PROFILE_GATEWAY"],
            "network_policy": os.environ.get("IHAR_PROFILE_NETPOLICY") or None,
            "instances": _split_lines("_IHAR_CHECK_GATEWAY_INSTANCES"),
        },
        "vendors": vendors,
        "assets": assets,
        "mcp": {
            "strict": os.environ.get("IHAR_PROFILE_MCP_STRICT") == "true",
            "notes": {
                "claude": _split_lines("_IHAR_CHECK_MCP_CLAUDE"),
                "codex": _split_lines("_IHAR_CHECK_MCP_CODEX"),
            },
        },
        "known_gaps": _split_lines("_IHAR_CHECK_KNOWN_GAPS"),
    }
    jsonio.write("check-result", target, result)


def _sha256(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _receipt(argv: list[str]) -> int:
    receipt_path, lockfile, vendor, binary = argv
    if not os.path.isfile(binary) or not os.access(binary, os.X_OK):
        print("not-installed")
        return 0
    if not os.path.isfile(receipt_path):
        print("missing")
        return 0
    try:
        receipt = jsonio.read("install-receipt", receipt_path)
        component = receipt["components"].get(vendor)
        valid = (
            component is not None
            and receipt["release_lock_sha256"] == _sha256(lockfile)
            and component["binary_sha256"] == _sha256(binary)
        )
    except (OSError, jsonio.SchemaError):
        print("invalid")
        return 0
    print("valid" if valid else "stale")
    return 0


def main(argv: list[str]) -> int:
    try:
        if len(argv) == 2 and argv[0] in ("text", "json"):
            result = jsonio.read("check-result", argv[1])
            print(render_text(result) if argv[0] == "text" else render_json(result), end="")
            return 0
        if len(argv) == 2 and argv[0] == "collect":
            _collect(argv[1])
            return 0
        if len(argv) == 5 and argv[0] == "receipt":
            return _receipt(argv[1:])
        if len(argv) == 2 and argv[0] == "validate-receipt":
            jsonio.read("install-receipt", argv[1])
            return 0
    except (OSError, KeyError, ValueError, jsonio.SchemaError) as error:
        print(f"ihar: cannot produce check result: {error}", file=sys.stderr)
        return 3
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
