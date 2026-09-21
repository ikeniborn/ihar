"""Validate and render the collect-once ``ihar check`` result."""

from __future__ import annotations

import hashlib
import json
import os
import sys
import tomllib

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
        "network      "
        f"{result['network']['state']} (scope {result['network']['scope']}, "
        f"default {result['network']['default']}; "
        f"configured {str(result['network']['configured']).lower()}, "
        f"available {str(result['network']['available']).lower()}, "
        f"active {str(result['network']['active']).lower()}, "
        f"verified {str(result['network']['verified']).lower()})",
    ]
    for instance in result["gateway"]["instances"]:
        lines.append(
            f"             instance {instance['key']} mode {instance['mode']} "
            f"port {_status_value(instance['port'])} pid {_status_value(instance['pid'])} "
            f"consumers {instance['consumers']} healthy {_status_value(instance['healthy'])}"
        )
        metrics = instance["metrics"]
        lines.append(
            f"             metrics {metrics['state']} masked {_status_value(metrics['masked'])} "
            f"refused {_status_value(metrics['refused'])} relayed {_status_value(metrics['relayed'])} "
            f"uptime_seconds {_status_value(metrics['uptime_seconds'])}"
        )
    for vendor in ("claude", "codex"):
        item = result["vendors"][vendor]
        hooks = ", ".join(_render_hook_text(hook) for hook in item["hooks"]) or "none"
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


def _render_hook_text(hook: dict) -> str:
    def value(name: str) -> str:
        observed = hook[name]
        if observed is None:
            return "-"
        if isinstance(observed, bool):
            return str(observed).lower()
        return observed

    return (
        f"{hook['id']}={hook['trust']} ["
        f"trusted_hash {value('trusted_hash')}; trustStatus {value('trustStatus')}; "
        f"enabled {value('enabled')}; source {value('source')}; "
        f"currentHash {value('currentHash')}]"
    )


def _status_value(value: object) -> str:
    if value is None:
        return "-"
    if isinstance(value, bool):
        return str(value).lower()
    return str(value)


def _split_lines(name: str) -> list[str]:
    return [line for line in os.environ.get(name, "").splitlines() if line]


def _empty_hook_fact(hook_id: str, trust: str = "unavailable") -> dict:
    return {
        "id": hook_id,
        "trust": trust,
        "trusted_hash": None,
        "trustStatus": None,
        "enabled": None,
        "source": None,
        "currentHash": None,
    }


def _selected_entries(manifest: dict, vendor: str, profile: str) -> list[dict]:
    return [
        entry for entry in manifest["entries"]
        if vendor in entry["vendors"]
        and ("*" in entry["profiles"] or profile in entry["profiles"])
    ]


def _expected_command(entry: dict, vendor: str) -> str:
    home_var = "CLAUDE_CONFIG_DIR" if vendor == "claude" else "CODEX_HOME"
    command = f'python3 -I "${home_var}/hooks/{entry["script"]}"'
    if entry["args"]:
        command += " " + " ".join(entry["args"])
    return command + f" --vendor {vendor}"


def _rendered_commands(runtime: str, vendor: str) -> set[str]:
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
    return commands


def _trusted_hashes(runtime: str) -> dict[str, str]:
    try:
        with open(os.path.join(runtime, "config.toml"), "rb") as handle:
            config = tomllib.load(handle)
    except (OSError, tomllib.TOMLDecodeError):
        return {}
    state = config.get("hooks", {}).get("state", {})
    return {
        key: record["trusted_hash"]
        for key, record in state.items()
        if isinstance(record, dict) and isinstance(record.get("trusted_hash"), str)
    }


def codex_hook_facts(manifest: dict, profile: str, runtime: str, observed: list[dict]) -> list[dict]:
    """Join rendered hook IDs to Codex's per-hook trust observations."""
    from .codex.hooks_trust import TRUSTED_SOURCES, TRUSTED_STATES

    entries = _selected_entries(manifest, "codex", profile)
    facts = {entry["id"]: _empty_hook_fact(entry["id"]) for entry in entries}
    command_ids = {_expected_command(entry, "codex"): entry["id"] for entry in entries}
    hooks_path = os.path.abspath(os.path.join(runtime, "hooks.json"))
    try:
        with open(hooks_path, encoding="utf-8") as handle:
            rendered = json.load(handle)
    except (OSError, json.JSONDecodeError):
        return sorted(facts.values(), key=lambda item: item["id"])

    key_ids = {}
    for event, groups in rendered.get("hooks", {}).items():
        for group_index, group in enumerate(groups):
            for hook_index, hook in enumerate(group.get("hooks", [])):
                hook_id = command_ids.get(hook.get("command"))
                if hook_id:
                    key_ids[f"{hooks_path}:{event}:{group_index}:{hook_index}"] = hook_id

    observed_by_key = {
        hook.get("key"): hook
        for hook in observed
        if os.path.abspath(hook.get("sourcePath") or "") == hooks_path
    }
    trusted_hashes = _trusted_hashes(runtime)
    for key, hook_id in key_ids.items():
        hook = observed_by_key.get(key)
        trusted_hash = trusted_hashes.get(key)
        if hook is None:
            facts[hook_id] = {**_empty_hook_fact(hook_id), "trusted_hash": trusted_hash}
            continue
        trust_status = hook.get("trustStatus") if isinstance(hook.get("trustStatus"), str) else None
        enabled = hook.get("enabled") if isinstance(hook.get("enabled"), bool) else None
        source = hook.get("source") if isinstance(hook.get("source"), str) else None
        current_hash = hook.get("currentHash") if isinstance(hook.get("currentHash"), str) else None
        trusted = (
            trust_status in TRUSTED_STATES
            and enabled is True
            and source in TRUSTED_SOURCES
            and trusted_hash is not None
            and trusted_hash == current_hash
        )
        facts[hook_id] = {
            "id": hook_id,
            "trust": "trusted" if trusted else "untrusted",
            "trusted_hash": trusted_hash,
            "trustStatus": trust_status,
            "enabled": enabled,
            "source": source,
            "currentHash": current_hash,
        }
    return sorted(facts.values(), key=lambda item: item["id"])


def _hook_facts(vendor: str) -> list[dict]:
    """Report each selected hook's observed vendor trust state."""
    manifest = jsonio.read("hook-manifest", os.environ["_IHAR_CHECK_MANIFEST"])
    runtime = os.environ[f"_IHAR_CHECK_{vendor.upper()}_RUNTIME"]
    profile = os.environ["IHAR_PROFILE"]
    if vendor == "codex":
        observed = []
        binary = os.environ.get("_IHAR_CHECK_CODEX_BINARY", "")
        if os.path.isfile(os.path.join(runtime, "hooks.json")) and os.access(binary, os.X_OK):
            try:
                from .codex.appserver import AppServerError, hooks_list
                observed = hooks_list(binary, runtime, [os.environ["IHAR_PROJECT_ROOT"]])
            except (AppServerError, OSError):
                observed = []
        return codex_hook_facts(manifest, profile, runtime, observed)

    commands = _rendered_commands(runtime, vendor)
    return sorted([
        _empty_hook_fact(
            entry["id"],
            "configured" if _expected_command(entry, vendor) in commands else "unavailable",
        )
        for entry in _selected_entries(manifest, vendor, profile)
    ], key=lambda item: item["id"])


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
            "instances": json.loads(os.environ["_IHAR_CHECK_GATEWAY_INSTANCES"]),
        },
        "network": _network_status(),
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


def _network_status() -> dict:
    policy_name = os.environ.get("IHAR_PROFILE_NETPOLICY", "")
    default = "allow"
    if policy_name:
        policy = jsonio.read(
            "netpolicy",
            os.path.join(os.environ["_IHAR_CHECK_NETPOLICY_DIR"], f"{policy_name}.json"),
        )
        default = policy["default"]
    facts = json.loads(os.environ["_IHAR_CHECK_NETWORK_EVIDENCE"])
    expected_keys = {"configured", "available", "active", "verified"}
    if set(facts) != expected_keys or any(type(facts[name]) is not bool for name in expected_keys):
        raise ValueError("network evidence is not a closed boolean fact set")
    configured = os.environ["IHAR_PROFILE_SANDBOX"] == "microvm" and bool(policy_name)
    if facts["configured"] is not configured:
        raise ValueError("network evidence does not match the resolved profile")
    enforced = all(facts.values())
    return {
        "state": "enforced" if enforced else "not enforced",
        "scope": "guest-boundary" if configured else "none",
        "default": default,
        **facts,
    }


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
