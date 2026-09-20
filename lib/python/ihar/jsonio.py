"""Schema registry, validation and atomic writes for ihar's JSON contracts.

Every contract in LLD section 15 carries a `schema` field and is validated here on
read and on write. An unknown key or a wrong type is an error, never a warning: a
tolerated key silently becomes an undocumented contract.

Failure class: fail-closed. Validation raises `SchemaError`; a caller on a security
path must let it abort rather than substitute a default.

Two contracts of section 15 are deliberately absent. `ihar-policy.json` (LLD 6.2) and
the adapter stdout shapes have no document-level shape in the LLD, so registering one
here would invent it; slice S3 owns the first and S2 the second. Everything the LLD
specifies concretely is registered now, because a later slice that drifts from a
contract should fail at its first write rather than at review.

No third-party dependency: a validator library would be a new external dependency,
which the intent places in the proposal-first autonomy zone. The subset implemented
here is the subset the contracts use.
"""

from __future__ import annotations

import json
import os
import posixpath
import re
import tempfile
from typing import Any, Mapping

from .conformance import REQUIRED_CASES as REQUIRED_CONFORMANCE_CASES

__all__ = ["SchemaError", "check", "read", "write", "merge_managed", "KINDS"]


class SchemaError(ValueError):
    """A document does not satisfy its contract. Always fail-closed."""


# --------------------------------------------------------------------------- #
# Field-level validation
# --------------------------------------------------------------------------- #

_TYPE_NAMES = {str: "string", int: "integer", bool: "boolean", list: "array", dict: "object"}

# ISO-8601 in UTC, the only timestamp representation any contract uses. A reader
# converting from epoch seconds converts before the check, never after (LLD 10.1).
_TS = r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z"
# Integrity pins are length-checked, not merely hex-shaped. A truncated digest that
# validates here would compare unequal at launch and abort the session, turning a
# write-time defect into a fail-closed abort at the worst possible moment.
_SHA256 = r"[0-9a-f]{64}"
_HASH8 = r"[0-9a-f]{8}"
_UUID = r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
_SLUG = r"[a-z][a-z0-9-]*"
_ENVVAR = r"[A-Z][A-Z0-9_]*"
# A path that stays inside the directory it is resolved against: no leading slash,
# no `..` segment. Both `netpolicy` and a hook `script` are interpolated into a path,
# one by the renderer and one into the command a vendor executes.
_SAFE_REL = r"(?!.*(^|/)\.\.(/|$))[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*"
_VENDOR = ("claude", "codex")


def _type_name(spec: Any) -> str:
    if isinstance(spec, tuple):
        return " or ".join(_type_name(one) for one in spec)
    if spec is type(None):
        return "null"
    return _TYPE_NAMES.get(spec, getattr(spec, "__name__", str(spec)))


def _check_field(path: str, value: Any, spec: Mapping[str, Any]) -> None:
    expected = spec["type"]
    # bool is a subclass of int in Python; an integer field must not accept True.
    if expected is int and isinstance(value, bool):
        raise SchemaError(f"{path}: expected integer, got boolean")
    if not isinstance(value, expected):
        raise SchemaError(f"{path}: expected {_type_name(expected)}, got {_type_name(type(value))}")

    if value is None:
        return

    if "const" in spec and value != spec["const"]:
        raise SchemaError(f"{path}: must be {spec['const']!r}, got {value!r}")

    if "enum" in spec and value not in spec["enum"]:
        allowed = ", ".join(repr(one) for one in spec["enum"])
        raise SchemaError(f"{path}: {value!r} is not one of {allowed}")

    if "pattern" in spec and isinstance(value, str) and not re.fullmatch(spec["pattern"], value):
        raise SchemaError(f"{path}: {value!r} does not match {spec['pattern']}")

    if spec.get("min_len") and len(value) < spec["min_len"]:
        raise SchemaError(f"{path}: shorter than {spec['min_len']}")

    if "min" in spec and value < spec["min"]:
        raise SchemaError(f"{path}: {value!r} is below {spec['min']}")

    if "max" in spec and value > spec["max"]:
        raise SchemaError(f"{path}: {value!r} is above {spec['max']}")

    if "items" in spec:
        for index, item in enumerate(value):
            _check_field(f"{path}[{index}]", item, spec["items"])

    # A free-form map: arbitrary keys, one value shape. Used where the contract keys
    # by something the schema cannot enumerate, such as a file path or a config hash.
    if "values" in spec and isinstance(value, dict):
        for key, item in value.items():
            if not isinstance(key, str):
                raise SchemaError(f"{path}: map key {key!r} is not a string")
            if "key_pattern" in spec and not re.fullmatch(spec["key_pattern"], key):
                raise SchemaError(f"{path}: map key {key!r} does not match {spec['key_pattern']}")
            _check_field(f"{path}.{key}", item, spec["values"])

    if "fields" in spec:
        _check_object(path, value, spec["fields"], spec.get("optional", {}))


def _check_object(
    path: str,
    obj: Any,
    fields: Mapping[str, Mapping[str, Any]],
    optional: Mapping[str, Mapping[str, Any]],
    *,
    partial: bool = False,
    partial_required: tuple[str, ...] = (),
) -> None:
    if not isinstance(obj, dict):
        raise SchemaError(f"{path or 'document'}: expected object, got {_type_name(type(obj))}")

    known = set(fields) | set(optional)
    for key in obj:
        if key not in known:
            raise SchemaError(f"{path or 'document'}: unknown key {key!r}")

    for key, spec in fields.items():
        if key not in obj:
            if partial and key not in partial_required:
                continue
            raise SchemaError(f"{path or 'document'}: missing required key {key!r}")
        _check_field(f"{path}.{key}" if path else key, obj[key], spec)

    for key, spec in optional.items():
        if key in obj:
            _check_field(f"{path}.{key}" if path else key, obj[key], spec)


# --------------------------------------------------------------------------- #
# Semantic rules — invariants a document must satisfy beyond its field types
# --------------------------------------------------------------------------- #


def _profile_rules(obj: Mapping[str, Any]) -> None:
    name = obj["name"]

    # LLD 12.3: masking is an enforcement point. A level above `off` with no gateway
    # would sanitise handoff packages while model requests left the machine untouched.
    if obj["masking_level"] != "off" and obj["gateway"] == "off":
        raise SchemaError(
            f"profile {name!r}: masking_level is {obj['masking_level']!r} but gateway is 'off'; "
            "masking without a model egress gateway is a guarantee nothing enforces"
        )

    # LLD 12.1 and 13.2: a profile whose guarantees depend on hooks must refuse ACP
    # mode, because settings hooks are not known to fire under the ACP adapters.
    if obj["hooks"] == "enforced" and obj["acp"] != "refuse":
        raise SchemaError(
            f"profile {name!r}: hooks are enforced but acp is {obj['acp']!r}; "
            "hook enforcement is not available under the ACP adapters"
        )

    # LLD 9.2: deny-by-default is only enforceable at the guest boundary, so a
    # microVM profile must name the policy enforced there.
    if obj["sandbox"] == "microvm" and not obj["netpolicy"]:
        raise SchemaError(
            f"profile {name!r}: sandbox is 'microvm' but no netpolicy is named; "
            "the guest boundary is where a network policy is enforced"
        )

    # LLD 13.1: Claude Remote Control refuses a custom ANTHROPIC_BASE_URL, so a
    # profile that offers a Claude web surface cannot also run an explicit gateway.
    # Without this the contradiction surfaces as an exit 2 when the user asks for
    # --web, rather than when the profile is written.
    if "claude" in obj["remote"] and obj["gateway"] == "explicit":
        raise SchemaError(
            f"profile {name!r}: lists 'claude' in remote but the gateway is 'explicit'; "
            "Claude Remote Control refuses a custom base URL, so the web surface "
            "would never start"
        )


def _overlap(left: list[str], right: list[str]) -> set[str]:
    """Entries that both lists select, treating `*` as every value."""
    if "*" in left:
        return set(right)
    if "*" in right:
        return set(left)
    return set(left) & set(right)


def _hook_manifest_rules(obj: Mapping[str, Any]) -> None:
    """At most one input-rewriting hook can match any single tool call (LLD 6.1).

    Codex runs the matching command hooks of one event concurrently, so two hooks
    that both return `updatedInput` race and one rewrite is silently lost.

    The hazard is that two entries *can match the same call*, which is tool-set
    intersection, not tool-set equality: entries on `["shell", "file-write"]` and on
    `["shell"]` both fire for a Bash call. Conversely two entries that never run in
    the same process, because they target different vendors or disjoint profiles,
    cannot race and must not be rejected.
    """
    ids: set[str] = set()
    rewriters: list[Mapping[str, Any]] = []
    for entry in obj["entries"]:
        if entry["id"] in ids:
            raise SchemaError(f"hook manifest: duplicate entry id {entry['id']!r}")
        ids.add(entry["id"])
        if entry.get("rewrites_input"):
            rewriters.append(entry)

    for index, left in enumerate(rewriters):
        for right in rewriters[index + 1:]:
            if left["event"] != right["event"]:
                continue
            vendors = _overlap(left["vendors"], right["vendors"])
            if not vendors:
                continue
            if not _overlap(left["profiles"], right["profiles"]):
                continue
            tools = _overlap(left["tools"], right["tools"])
            if not tools:
                continue
            raise SchemaError(
                f"hook manifest: {left['id']!r} and {right['id']!r} both rewrite input on "
                f"{left['event']} for {', '.join(sorted(tools))} "
                f"under {', '.join(sorted(vendors))}; the winning rewrite would be a race"
            )


def _netpolicy_rules(obj: Mapping[str, Any]) -> None:
    name = obj["name"]

    # A deny-by-default policy that allows nothing cannot reach a model provider, so
    # the profile using it could never run. Catch it here rather than at launch.
    if obj["default"] == "deny" and not obj["allow"]:
        raise SchemaError(
            f"netpolicy {name!r}: default is 'deny' with an empty allow list; "
            "nothing, including the gateway, would be reachable"
        )

    # Every rule must name something a renderer can turn into a filter. An entry with
    # neither a kind nor a host is unenforceable, and a non-empty list of such entries
    # would satisfy the check above while the policy still denies everything.
    for index, entry in enumerate(obj["allow"]):
        where = f"netpolicy {name!r}: allow[{index}]"
        if ("kind" in entry) == ("host" in entry):
            raise SchemaError(
                f"{where} must name exactly one of 'kind' or 'host'; "
                "an entry naming neither, or both, is not enforceable"
            )
        if "port" in entry and "host" not in entry:
            raise SchemaError(f"{where} names a port without a host")


def _mcp_registry_rules(obj: Mapping[str, Any]) -> None:
    names: set[str] = set()
    for server in obj["servers"]:
        if server["name"] in names:
            raise SchemaError(f"mcp registry: duplicate server name {server['name']!r}")
        names.add(server["name"])
        if server["transport"] == "stdio" and not server.get("command"):
            raise SchemaError(f"mcp registry: {server['name']!r} is stdio but names no command")
        if server["transport"] == "http" and not server.get("url"):
            raise SchemaError(f"mcp registry: {server['name']!r} is http but names no url")


def _session_rules(obj: Mapping[str, Any]) -> None:
    if obj.get("parent_ihar_id") == obj["ihar_id"]:
        raise SchemaError(f"session {obj['ihar_id']}: parent_ihar_id points at itself")


def _conformance_rules(obj: Mapping[str, Any]) -> None:
    if not obj["cases"]:
        raise SchemaError(
            f"conformance {obj['vendor']} {obj['version']}: no cases recorded; "
            "an empty record would let an enforced profile launch unproven"
        )
    required = REQUIRED_CONFORMANCE_CASES[obj["vendor"]]
    missing = sorted(required - obj["cases"].keys())
    if missing:
        raise SchemaError(
            f"conformance {obj['vendor']} {obj['version']}: missing mandatory cases: "
            f"{', '.join(missing)}"
        )
    incomplete = sorted(
        name for name in required if obj["cases"][name]["status"] == "skipped"
    )
    if incomplete:
        raise SchemaError(
            f"conformance {obj['vendor']} {obj['version']}: mandatory cases were skipped: "
            f"{', '.join(incomplete)}"
        )


def _state_manifest_rules(obj: Mapping[str, Any]) -> None:
    keys: set[tuple[str, str]] = set()
    for entry in obj["entries"]:
        key = (entry["vendor"], entry["path"])
        if key in keys:
            raise SchemaError(
                f"state manifest: duplicate entry for vendor {key[0]!r} and path {key[1]!r}"
            )
        keys.add(key)


def _asset_manifest_rules(obj: Mapping[str, Any]) -> None:
    forbidden = {"auth", "cache", "caches", "plugins", "st", "transcripts"}
    generated = {"settings.json", "config.toml", "router.json"}
    keys: set[tuple[str, str]] = set()
    for entry in obj["entries"]:
        key = (entry["vendor"], entry["target"])
        if key in keys:
            raise SchemaError(
                f"asset manifest: duplicate target for vendor {key[0]!r} and target {key[1]!r}"
            )
        keys.add(key)
        parts = set(entry["source"].split("/")) | set(entry["target"].split("/"))
        if forbidden & parts or any(part.endswith(".cache") for part in parts):
            raise SchemaError("asset manifest: authentication, caches, plugins, transcripts and state are not tracked assets")
        if generated & parts:
            raise SchemaError("asset manifest: generated settings are not tracked assets")


def _mutable_link_manifest_rules(obj: Mapping[str, Any]) -> None:
    sources: set[str] = set()
    targets: set[tuple[str, str]] = set()
    for entry in obj["entries"]:
        raw_source = entry["source"]
        raw_target = entry["target"]
        source = posixpath.normpath(raw_source)
        target_path = posixpath.normpath(raw_target)
        target = (entry["vendor"], target_path)
        if source in sources:
            raise SchemaError(f"mutable-link manifest: duplicate source {source!r}")
        if target in targets:
            raise SchemaError(
                f"mutable-link manifest: duplicate target for vendor {target[0]!r} "
                f"and path {target[1]!r}"
            )
        sources.add(source)
        targets.add(target)

        if "." in raw_source.split("/"):
            raise SchemaError(
                f"mutable-link manifest: source {raw_source!r} contains a non-canonical dot segment"
            )
        if "." in raw_target.split("/"):
            raise SchemaError(
                f"mutable-link manifest: target {raw_target!r} contains a non-canonical dot segment"
            )
        if source != raw_source:
            raise SchemaError(
                f"mutable-link manifest: source {raw_source!r} is not canonical; use {source!r}"
            )
        if target_path != raw_target:
            raise SchemaError(
                f"mutable-link manifest: target {raw_target!r} is not canonical; "
                f"use {target_path!r}"
            )

        parts = source.split("/")
        if len(parts) < 2 or parts[0] not in ("auth", "plugins") \
                or parts[1] != entry["vendor"]:
            raise SchemaError(
                "mutable-link manifest: source must belong to vendor auth or plugins"
            )
        if parts[0] == "auth" and entry["kind"] != "file":
            raise SchemaError("mutable-link manifest: auth entries must be files")
        if parts[0] == "plugins" and (len(parts) != 2 or entry["kind"] != "directory"):
            raise SchemaError("mutable-link manifest: plugin entries must be vendor directories")


def _test_inventory_rules(obj: Mapping[str, Any]) -> None:
    seen: set[str] = set()
    for path in obj["paths"]:
        if path in seen:
            raise SchemaError(f"test inventory: duplicate path {path!r}")
        seen.add(path)
        if not re.fullmatch(r"tests/test_[A-Za-z0-9._-]+\.(sh|py)", path):
            raise SchemaError(
                f"test inventory: {path!r} is not a discovered tests/test_*.sh or tests/test_*.py path"
            )


def _check_result_rules(obj: Mapping[str, Any]) -> None:
    for instance in obj["gateway"]["instances"]:
        for name in ("port", "pid"):
            if isinstance(instance[name], bool):
                raise SchemaError(f"check result: gateway {name} must be an integer or null")
        metrics = instance["metrics"]
        metric_names = ("masked", "refused", "relayed", "uptime_seconds")
        values = [metrics[name] for name in metric_names]
        for name in metric_names:
            if isinstance(metrics[name], bool):
                raise SchemaError(f"check result: gateway metric {name} must be an integer or null")
        if metrics["state"] == "available" and any(value is None for value in values):
            raise SchemaError("check result: available metrics must carry every counter")
        if metrics["state"] == "unavailable" and any(value is not None for value in values):
            raise SchemaError("check result: unavailable metrics must not fabricate counters")
    expected_scope = "guest-boundary" if obj["network"]["state"] == "enforced" else "none"
    if obj["network"]["scope"] != expected_scope:
        raise SchemaError(
            f"check result: network state {obj['network']['state']!r} "
            f"requires scope {expected_scope!r}"
        )


# --------------------------------------------------------------------------- #
# Registry
# --------------------------------------------------------------------------- #

_NULLABLE_STR = {"type": (str, type(None))}

KINDS: dict[str, dict[str, Any]] = {
    # LLD 12.1
    "profile": {
        "fields": {
            "schema": {"type": int, "const": 1},
            "name": {"type": str, "pattern": _SLUG},
            "guarantee": {"type": str, "min_len": 1},
            "hooks": {"type": str, "enum": ("enforced", "best-effort")},
            "gateway": {"type": str, "enum": ("off", "explicit")},
            "masking_level": {"type": str, "enum": ("off", "secrets", "standard")},
            "sandbox": {"type": str, "enum": ("vendor-default", "read-only", "vendor", "microvm")},
            # Resolved as manifests/netpolicy/<name>.json, so it is a slug, not a path.
            "netpolicy": {"type": (str, type(None)), "pattern": _SLUG},
            "remote": {"type": list, "items": {"type": str, "enum": _VENDOR}},
            "mcp": {"type": dict, "fields": {"strict": {"type": bool}}},
            "acp": {"type": str, "enum": ("allow", "refuse")},
            "env_passthrough": {"type": list, "items": {"type": str, "pattern": _ENVVAR}},
            "handoff": {"type": dict, "fields": {"system_prompt": {"type": bool}}},
        },
        "rules": [_profile_rules],
    },
    # LLD 9.2
    "netpolicy": {
        "fields": {
            "schema": {"type": int, "const": 1},
            "name": {"type": str, "pattern": _SLUG},
            "default": {"type": str, "enum": ("deny", "allow")},
            "allow": {
                "type": list,
                "items": {
                    "type": dict,
                    "fields": {},
                    "optional": {
                        "kind": {"type": str, "enum": ("gateway", "mcp-declared")},
                        "host": {"type": str, "min_len": 1},
                        "port": {"type": int, "min": 1, "max": 65535},
                        "reason": {"type": str, "min_len": 1},
                    },
                },
            },
        },
        "rules": [_netpolicy_rules],
    },
    # LLD 6.1
    "hook-manifest": {
        "fields": {
            "schema": {"type": int, "const": 1},
            "entries": {
                "type": list,
                "items": {
                    "type": dict,
                    "fields": {
                        "id": {"type": str, "pattern": _SLUG},
                        "event": {"type": str, "min_len": 1},
                        "tools": {"type": list, "items": {"type": str, "min_len": 1}},
                        # Rendered into the command a vendor executes, so it must stay
                        # inside the hooks directory it is resolved against.
                        "script": {"type": str, "pattern": _SAFE_REL},
                        "args": {"type": list, "items": {"type": str}},
                        # Neither vendor documents a non-positive timeout.
                        "timeout": {"type": int, "min": 1, "max": 300},
                        "vendors": {"type": list, "items": {"type": str, "enum": _VENDOR}},
                        "profiles": {"type": list, "items": {"type": str, "min_len": 1}},
                    },
                    "optional": {
                        "rewrites_input": {"type": bool},
                        "required_in": {"type": list, "items": {"type": str, "min_len": 1}},
                        "claude_only": {
                            "type": dict,
                            "fields": {"type": {"type": str, "min_len": 1}},
                        },
                    },
                },
            },
        },
        "rules": [_hook_manifest_rules],
    },
    # LLD 7.1
    "mcp-registry": {
        "fields": {
            "schema": {"type": int, "const": 1},
            "servers": {
                "type": list,
                "items": {
                    "type": dict,
                    "fields": {
                        "name": {"type": str, "min_len": 1},
                        "transport": {"type": str, "enum": ("stdio", "http")},
                        "scope": {"type": str, "enum": ("user", "project")},
                        "profiles": {"type": list, "items": {"type": str, "min_len": 1}},
                    },
                    "optional": {
                        "command": {"type": str, "min_len": 1},
                        "args": {"type": list, "items": {"type": str}},
                        "url": {"type": str, "min_len": 1},
                        "headers": {"type": dict, "values": {"type": str}},
                        "env": {"type": dict, "values": {"type": str}},
                        "env_names": {"type": list, "items": {"type": str, "pattern": _ENVVAR}},
                        "requires_env": {"type": list, "items": {"type": str, "pattern": _ENVVAR}},
                        "egress": {"type": list, "items": {"type": str, "min_len": 1}},
                    },
                },
            },
        },
        "rules": [_mcp_registry_rules],
    },
    # LLD 5.2
    "capabilities": {
        "fields": {
            "schema": {"type": int, "const": 1},
            "vendor": {"type": str, "enum": _VENDOR},
            "passthrough_separator": {"type": str, "enum": ("--", "none")},
            "remote_control": {"type": bool},
            "fork": {"type": bool},
            "archive": {"type": bool},
            "session_list_api": {"type": str, "min_len": 1},
            "session_id_preset": {"type": bool},
            "hook_trust_api": {"type": bool},
            "managed_hooks": {"type": bool},
            "hook_events": {"type": list, "items": {"type": str, "min_len": 1}},
            "hook_input_rewrite": {"type": bool},
            "sandbox_modes": {
                "type": list,
                "items": {
                    "type": str,
                    "enum": ("vendor-default", "read-only", "vendor", "microvm"),
                },
            },
            "context_injection": {"type": list, "items": {"type": str, "min_len": 1}},
        },
        "rules": [],
    },
    # LLD 10.1. `partial` is the shape the SessionStart hook appends, which the
    # index supersedes field by field (LLD 10.2, 10.3).
    "session": {
        "fields": {
            "schema": {"type": int, "const": 1},
            "ihar_id": {"type": str, "pattern": _UUID},
            "vendor": {"type": str, "enum": _VENDOR},
            "vendor_session_id": _NULLABLE_STR,
            "project": {"type": str, "min_len": 1},
            "cwd": {"type": str, "min_len": 1},
            "git_branch": _NULLABLE_STR,
            "title": _NULLABLE_STR,
            "model": _NULLABLE_STR,
            "profile": {"type": str, "pattern": _SLUG},
            "started_at": {"type": str, "pattern": _TS},
            "updated_at": {"type": str, "pattern": _TS},
            "parent_ihar_id": {"type": (str, type(None)), "pattern": _UUID},
            "handoff_from": {"type": (str, type(None)), "pattern": _UUID},
            "handoff_to": {"type": (str, type(None)), "pattern": _UUID},
            "tags": {"type": list, "items": {"type": str, "min_len": 1}},
            "source": {"type": str, "enum": ("launch", "hook", "vendor", "sqlite")},
        },
        "partial_required": ("schema", "ihar_id", "vendor", "source"),
        "rules": [_session_rules],
    },
    # LLD 10.3
    "launch-claim": {
        "fields": {
            "schema": {"type": int, "const": 1},
            "ihar_id": {"type": str, "pattern": _UUID},
            "vendor": {"type": str, "enum": _VENDOR},
            "profile": {"type": str, "pattern": _SLUG},
            "runtime_hash": {"type": str, "pattern": _HASH8},
            "counter": {"type": int},
            "created_at": {"type": str, "pattern": _TS},
        },
        "rules": [],
    },
    # LLD 11.1
    "handoff": {
        "fields": {
            "schema": {"type": int, "const": 1},
            "source_vendor": {"type": str, "enum": _VENDOR},
            "source_session_id": {"type": str, "min_len": 1},
            "source_ihar_id": {"type": str, "pattern": _UUID},
            "target_vendor": {"type": str, "enum": _VENDOR},
            "created_at": {"type": str, "pattern": _TS},
            "project": {"type": str, "min_len": 1},
            "cwd": {"type": str, "min_len": 1},
            "git": {
                "type": dict,
                "fields": {
                    "branch": _NULLABLE_STR,
                    "head": _NULLABLE_STR,
                    "dirty": {"type": bool},
                    "shortstat": {"type": str},
                    "files_changed": {"type": int},
                },
            },
            "files_touched": {"type": list, "items": {"type": str, "min_len": 1}},
            "files_touched_truncated": {"type": bool},
            "open_items": {"type": list, "items": {"type": str}},
            "decisions": {"type": list, "items": {"type": str}},
            "decisions_heuristic": {"type": list, "items": {"type": str}},
            "recent_messages": {
                "type": list,
                "items": {
                    "type": dict,
                    "fields": {
                        "role": {"type": str, "min_len": 1},
                        "text": {"type": str},
                    },
                },
            },
            "masked": {"type": bool},
            "masking_level": {"type": str, "enum": ("off", "secrets", "standard")},
            "bytes": {"type": int},
        },
        "optional": {
            "ledger": {
                "type": dict,
                "fields": {},
                "optional": {
                    "topic": {"type": str, "min_len": 1},
                    "task_page": {"type": str, "min_len": 1},
                    "slices_open": {"type": list, "items": {"type": str, "min_len": 1}},
                },
            },
            "summary": {"type": str},
        },
        "rules": [],
    },
    # LLD 5.5
    "daemon-record": {
        "fields": {
            "schema": {"type": int, "const": 1},
            "pid": {"type": int},
            "socket": {"type": str, "min_len": 1},
            "binary_sha256": {"type": str, "pattern": _SHA256},
            "codex_version": {"type": str, "min_len": 1},
            "config_hash": {"type": str, "pattern": _HASH8},
            "started_at": {"type": str, "pattern": _TS},
            "remote_control": {"type": bool},
        },
        "rules": [],
    },
    # LLD 6.6
    "conformance": {
        "fields": {
            "schema": {"type": int, "const": 1},
            "vendor": {"type": str, "enum": _VENDOR},
            "version": {"type": str, "min_len": 1},
            "binary_sha256": {"type": str, "pattern": _SHA256},
            "manifest_digest": {"type": str, "pattern": _SHA256},
            "created_at": {"type": str, "pattern": _TS},
            "cases": {
                "type": dict,
                "values": {
                    "type": dict,
                    "fields": {"status": {"type": str, "enum": ("passed", "failed", "skipped")}},
                    "optional": {"detail": {"type": str}},
                },
            },
        },
        "rules": [_conformance_rules],
    },
    # LLD 4.1
    "home-marker": {
        "fields": {
            "schema": {"type": int, "const": 3},
            "project_root": {"type": str, "min_len": 1},
            "created": {"type": str, "pattern": _TS},
            "vendors": {"type": list, "items": {"type": str, "enum": _VENDOR}},
            "runtimes": {
                "type": dict,
                "key_pattern": _HASH8,
                "values": {
                    "type": dict,
                    "fields": {
                        "profile": {"type": str, "pattern": _SLUG},
                        "created": {"type": str, "pattern": _TS},
                        "last_used": {"type": str, "pattern": _TS},
                    },
                },
            },
            "migrated_from": {"type": dict, "key_pattern": "|".join(_VENDOR), "values": {"type": str}},
        },
        "rules": [],
    },
    # LLD 14.1
    "lockfile": {
        "fields": {
            "schema": {"type": int, "const": 1},
        },
        "optional": {
            "node": {"type": dict, "fields": {"version": {"type": str, "min_len": 1}}},
            "claude": {
                "type": dict,
                "fields": {
                    "version": {"type": str, "min_len": 1},
                },
            },
            "codex": {
                "type": dict,
                "fields": {
                    "version": {"type": str, "min_len": 1},
                    "asset": {"type": str, "min_len": 1},
                    "sha256": {"type": str, "pattern": _SHA256},
                },
            },
            "uv": {"type": dict, "fields": {"version": {"type": str, "min_len": 1}}},
            "python": {"type": dict, "fields": {"requirementsSha256": {"type": str, "pattern": _SHA256}}},
            # Accepted only for schema-1 upgrade compatibility. S11 no longer
            # installs or consumes mitmproxy, but update must read old lockfiles.
            "mitmproxy": {"type": dict, "fields": {"version": {"type": str, "min_len": 1}}},
            "hooks": {"type": dict, "values": {"type": str, "pattern": _SHA256}},
            "managedHooks": {"type": dict, "values": {"type": str, "pattern": _SHA256}},
            "acp": {"type": dict, "values": {"type": str, "min_len": 1}},
            "microvm": {"type": dict, "values": {"type": str, "pattern": _SHA256}},
        },
        "rules": [],
    },
    # LLD 14.1: unlike the release lock above, this evidence is local to one store.
    "install-receipt": {
        "fields": {
            "schema": {"type": int, "const": 1},
            "release_lock_sha256": {"type": str, "pattern": _SHA256},
            "installed_at": {"type": str, "pattern": _TS},
            "components": {
                "type": dict,
                "fields": {},
                "optional": {
                    vendor: {
                        "type": dict,
                        "fields": {
                            "version": {"type": str, "min_len": 1},
                            "binary_sha256": {"type": str, "pattern": _SHA256},
                        },
                    }
                    for vendor in _VENDOR
                },
            },
        },
        "rules": [],
    },
    # LLD 2.4
    "state-manifest": {
        "fields": {
            "schema": {"type": int, "const": 1},
            "entries": {
                "type": list,
                "items": {
                    "type": dict,
                    "fields": {
                        "vendor": {"type": str, "enum": _VENDOR},
                        "path": {"type": str, "pattern": _SAFE_REL},
                        "kind": {
                            "type": str,
                            "enum": ("directory", "file", "sqlite-family"),
                        },
                    },
                },
            },
        },
        "rules": [_state_manifest_rules],
    },
    "asset-manifest": {
        "fields": {
            "schema": {"type": int, "const": 1},
            "entries": {
                "type": list,
                "items": {
                    "type": dict,
                    "fields": {
                        "vendor": {"type": str, "enum": ("common", *_VENDOR)},
                        "source": {"type": str, "pattern": _SAFE_REL},
                        "target": {"type": str, "pattern": _SAFE_REL},
                        "kind": {"type": str, "enum": ("directory", "file")},
                        "required": {"type": bool},
                        "runtime": {"type": bool},
                    },
                },
            },
        },
        "rules": [_asset_manifest_rules],
    },
    "mutable-link-manifest": {
        "fields": {
            "schema": {"type": int, "const": 1},
            "entries": {
                "type": list,
                "items": {
                    "type": dict,
                    "fields": {
                        "vendor": {"type": str, "enum": _VENDOR},
                        "source": {"type": str, "pattern": _SAFE_REL},
                        "target": {"type": str, "pattern": _SAFE_REL},
                        "kind": {"type": str, "enum": ("directory", "file")},
                    },
                },
            },
        },
        "rules": [_mutable_link_manifest_rules],
    },
    "test-inventory": {
        "fields": {
            "schema": {"type": int, "const": 1},
            "paths": {
                "type": list,
                "items": {"type": str, "pattern": _SAFE_REL},
            },
        },
        "rules": [_test_inventory_rules],
    },
    "check-result": {
        "fields": {
            "schema": {"type": int, "const": 1},
            "profile": {"type": dict, "fields": {
                "name": {"type": str, "pattern": _SLUG},
                "guarantee": {"type": str, "min_len": 1},
            }},
            "masking": {"type": dict, "fields": {
                "level": {"type": str, "enum": ("off", "secrets", "standard")},
                "floor": {"type": str, "enum": ("off", "secrets", "standard")},
                "engine": {"type": str, "min_len": 1},
                "dropped_env": {"type": list, "items": {"type": str, "min_len": 1}},
            }},
            "gateway": {"type": dict, "fields": {
                "mode": {"type": str, "enum": ("off", "explicit")},
                "instances": {"type": list, "items": {"type": dict, "fields": {
                    "key": {"type": str, "pattern": r"[0-9a-f]{12}"},
                    "mode": {"type": str, "enum": ("explicit",)},
                    "port": {"type": (int, type(None)), "min": 1, "max": 65535},
                    "pid": {"type": (int, type(None)), "min": 1},
                    "consumers": {"type": int, "min": 0},
                    "healthy": {"type": bool},
                    "metrics": {"type": dict, "fields": {
                        "state": {"type": str, "enum": ("available", "unavailable")},
                        "masked": {"type": (int, type(None)), "min": 0},
                        "refused": {"type": (int, type(None)), "min": 0},
                        "relayed": {"type": (int, type(None)), "min": 0},
                        "uptime_seconds": {"type": (int, type(None)), "min": 0},
                    }},
                }}},
            }},
            "network": {"type": dict, "fields": {
                "state": {"type": str, "enum": ("enforced", "not enforced")},
                "scope": {"type": str, "enum": ("none", "guest-boundary")},
                "default": {"type": str, "enum": ("allow", "deny")},
            }},
            "vendors": {"type": dict, "fields": {
                vendor: {"type": dict, "fields": {
                    "receipt": {"type": str, "enum": ("verified", "mismatched", "missing receipt")},
                    "hooks": {"type": list, "items": {"type": dict, "fields": {
                        "id": {"type": str, "pattern": _SLUG},
                        "trust": {"type": str, "enum": ("configured", "trusted", "untrusted", "unavailable")},
                        "trusted_hash": {"type": (str, type(None)), "pattern": r"sha256:[0-9a-f]{64}"},
                        "trustStatus": {"type": (str, type(None))},
                        "enabled": {"type": (bool, type(None))},
                        "source": {"type": (str, type(None))},
                        "currentHash": {"type": (str, type(None)), "pattern": r"sha256:[0-9a-f]{64}"},
                    }}},
                    "conformance": {"type": str, "enum": ("proven", "stale", "unproven", "not-installed")},
                    "capabilities": {"type": list, "items": {"type": str, "min_len": 1}},
                }} for vendor in _VENDOR
            }},
            "assets": {"type": list, "items": {"type": dict, "fields": {
                "requirement": {"type": str, "enum": ("required", "optional")},
                "presence": {"type": str, "enum": ("present", "missing")},
                "source": {"type": str, "pattern": _SAFE_REL},
                "target": {"type": str, "pattern": _SAFE_REL},
            }}},
            "mcp": {"type": dict, "fields": {
                "strict": {"type": bool},
                "notes": {"type": dict, "fields": {
                    vendor: {"type": list, "items": {"type": str, "min_len": 1}}
                    for vendor in _VENDOR
                }},
            }},
            "known_gaps": {"type": list, "items": {"type": str, "min_len": 1}},
        },
        "rules": [_check_result_rules],
    },
}


# --------------------------------------------------------------------------- #
# Public API
# --------------------------------------------------------------------------- #


def check(kind: str, obj: Any, *, partial: bool = False) -> Any:
    """Validate `obj` against the registered contract `kind` and return it.

    Raises SchemaError on any violation. `partial` relaxes the required set to the
    kind's `partial_required` tuple, for the field-by-field records the session index
    supersedes.

    Semantic rules run on a partial document too. The partial session record is the
    one a SessionStart hook appends (LLD 10.3), so it is the shape those rules most
    need to police; a rule must therefore read optional fields with `.get`.
    """
    try:
        spec = KINDS[kind]
    except KeyError:
        known = ", ".join(sorted(KINDS))
        raise SchemaError(f"unknown contract kind {kind!r}; registered kinds are {known}") from None

    if partial and not spec.get("partial_required"):
        raise SchemaError(f"contract {kind!r} has no partial form")

    _check_object(
        "",
        obj,
        spec["fields"],
        spec.get("optional", {}),
        partial=partial,
        partial_required=spec.get("partial_required", ()),
    )
    for rule in spec["rules"]:
        rule(obj)
    return obj


def read(kind: str, path: str | os.PathLike[str]) -> Any:
    """Read and validate a contract document."""
    with open(path, "r", encoding="utf-8") as handle:
        try:
            obj = json.load(handle)
        except json.JSONDecodeError as error:
            raise SchemaError(f"{path}: not valid JSON: {error}") from error
    try:
        return check(kind, obj)
    except SchemaError as error:
        raise SchemaError(f"{path}: {error}") from None


def write(kind: str, path: str | os.PathLike[str], obj: Any, *, mode: int = 0o600) -> None:
    """Validate, then write atomically: a partial contract file is never observable."""
    check(kind, obj)
    target = os.fspath(path)
    directory = os.path.dirname(target) or "."
    handle = tempfile.NamedTemporaryFile(
        "w", encoding="utf-8", dir=directory, prefix=".ihar-", delete=False
    )
    try:
        json.dump(obj, handle, indent=2, sort_keys=True, ensure_ascii=False)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
        handle.close()
        os.chmod(handle.name, mode)
        os.replace(handle.name, target)
        # Fsync the directory too: the contents are durable after the flush above,
        # but the rename itself is not, so a crash here could leave neither the old
        # file nor the new name. An absent home marker or daemon record is as bad as
        # a torn one.
        fd = os.open(directory, os.O_RDONLY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    except BaseException:
        handle.close()
        try:
            os.unlink(handle.name)
        except FileNotFoundError:
            pass
        raise


def merge_managed(base: Mapping[str, Any], managed: Mapping[str, Any], keys: list[str]) -> dict:
    """Overlay machine-owned keys onto a user-owned document.

    Every key in `keys` is dropped from `base` and taken from `managed` when present
    there, so a key the render no longer emits disappears instead of lingering. Keys
    outside the list are never touched: that is what keeps a user's own settings
    surviving a launch.

    A managed key missing from `keys` is an error, not a silent drop. The managed
    block carries the hook configuration; a render that starts emitting a new key
    while the caller's list lags behind would quietly write settings without it, and
    enforcement would be absent rather than failing closed.
    """
    unlisted = sorted(set(managed) - set(keys))
    if unlisted:
        raise SchemaError(
            f"merge_managed: rendered keys {', '.join(unlisted)} are not in the managed list; "
            "add them or they would be dropped from the written document"
        )
    result = {key: value for key, value in base.items() if key not in keys}
    for key in keys:
        if key in managed:
            result[key] = managed[key]
    return result
