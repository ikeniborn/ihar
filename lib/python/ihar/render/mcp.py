"""Render the MCP registry for one vendor (LLD 7.1, 7.2).

Failure class: fail-closed. A registry that does not validate, or a Codex render
carrying a reference Codex cannot expand, aborts rather than producing a
configuration whose server silently fails to start.

Secrets never appear in a rendered file. `env_names` forwards a variable by name and
the vendor reads it from the process environment; `headers` may reference one, and
`bearer_token_env_var` is how Codex spells the same thing.

Usage:
    python3 -m ihar.render.mcp <vendor> <profile> <registry> [--report|--identity]
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import sys

from .. import jsonio

# References the renderer itself resolves. Anything else is left in place for the
# vendor, which is only safe where the vendor expands.
_OURS = ("IHAR_PROJECT_ROOT", "IHAR_STATE", "IHAR_STORE", "IHAR_IWIKI_REMOTE_URL")

_REFERENCE = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}")


class Skipped(Exception):
    """A server this launch does not render, with the reason."""


def _expand(value: str, environment) -> str:
    def replace(match):
        name = match.group(1)
        if name in _OURS:
            resolved = environment.get(name)
            if not resolved:
                raise Skipped(f"{name} is not set")
            return resolved
        return match.group(0)
    return _REFERENCE.sub(replace, value)


def _expand_value(value, environment):
    if isinstance(value, str):
        return _expand(value, environment)
    if isinstance(value, list):
        return [_expand_value(item, environment) for item in value]
    if isinstance(value, dict):
        return {key: _expand_value(item, environment) for key, item in value.items()}
    return value


def _selected(server, profile):
    profiles = server["profiles"]
    return "*" in profiles or profile in profiles


def _prepare(server, profile, environment) -> dict:
    if not _selected(server, profile):
        raise Skipped(f"not offered to profile {profile}")
    for name in server.get("requires_env", []):
        if not environment.get(name):
            raise Skipped(f"{name} is not set")
    return {key: _expand_value(value, environment) for key, value in server.items()}


def render_claude(registry, profile, environment):
    servers, notes = {}, []
    for server in registry["servers"]:
        try:
            prepared = _prepare(server, profile, environment)
        except Skipped as reason:
            notes.append(f"{server['name']}: skipped, {reason}")
            continue
        if prepared["transport"] == "http":
            entry = {"type": "http", "url": prepared["url"]}
            if prepared.get("headers"):
                entry["headers"] = prepared["headers"]
        else:
            entry = {"command": prepared["command"], "args": prepared.get("args", [])}
            if prepared.get("env"):
                entry["env"] = prepared["env"]
        servers[prepared["name"]] = entry
    return {"mcpServers": servers}, notes


def _toml_string(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def render_codex(registry, profile, environment):
    lines, notes = [], []
    for server in registry["servers"]:
        try:
            prepared = _prepare(server, profile, environment)
        except Skipped as reason:
            notes.append(f"{server['name']}: skipped, {reason}")
            continue

        name = prepared["name"]
        if prepared["transport"] == "http":
            headers = prepared.get("headers") or {}
            bearer = None
            for key, value in headers.items():
                if key.lower() == "authorization":
                    match = _REFERENCE.fullmatch(value.replace("Bearer ", "").strip())
                    if match:
                        bearer = match.group(1)
                        continue
                # Codex expresses only the bearer token, so any other header is a
                # capability gap rather than something to render approximately.
                notes.append(f"{name}: header {key} rendered for Claude only; "
                             "Codex expresses only a bearer token")
            lines.append(f"[mcp_servers.{name}]")
            lines.append(f"url = {_toml_string(prepared['url'])}")
            if bearer:
                lines.append(f"bearer_token_env_var = {_toml_string(bearer)}")
        else:
            lines.append(f"[mcp_servers.{name}]")
            lines.append(f"command = {_toml_string(prepared['command'])}")
            if prepared.get("args"):
                rendered = ", ".join(_toml_string(arg) for arg in prepared["args"])
                lines.append(f"args = [{rendered}]")
            if prepared.get("env_names"):
                rendered = ", ".join(_toml_string(one) for one in prepared["env_names"])
                lines.append(f"env_vars = [{rendered}]")
            if prepared.get("env"):
                lines.append("")
                lines.append(f"[mcp_servers.{name}.env]")
                for key, value in sorted(prepared["env"].items()):
                    lines.append(f"{key} = {_toml_string(value)}")
        lines.append("")

    text = "\n".join(lines)
    # Codex does not expand environment references in its configuration, so one that
    # survived here would reach the vendor as a literal `${…}` and the server would
    # fail to start with a message about a path that does not exist.
    leftover = _REFERENCE.findall(text)
    if leftover:
        raise jsonio.SchemaError(
            "mcp: the Codex render still contains "
            f"{', '.join('${' + name + '}' for name in sorted(set(leftover)))}, "
            "which Codex does not expand"
        )
    return text, notes


def effective_identity(registry, profile, environment, vendor):
    rendered, _ = (
        render_claude(registry, profile, environment)
        if vendor == "claude"
        else render_codex(registry, profile, environment)
    )
    body = json.dumps(rendered, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(body.encode("utf-8")).hexdigest()


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    vendor, profile, registry_path = argv[:3]
    report = "--report" in argv
    identity = "--identity" in argv

    try:
        registry = jsonio.read("mcp-registry", registry_path)
        if identity:
            print(effective_identity(registry, profile, os.environ, vendor))
            return 0
        if vendor == "claude":
            rendered, notes = render_claude(registry, profile, os.environ)
            body = json.dumps(rendered, indent=2, sort_keys=True)
        else:
            body, notes = render_codex(registry, profile, os.environ)
    except (jsonio.SchemaError, OSError) as error:
        print(f"ihar: {error}", file=sys.stderr)
        return 3

    if report:
        for note in notes:
            print(note)
        return 0

    print(body)
    for note in notes:
        print(f"ihar: mcp: {note}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
