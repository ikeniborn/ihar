"""Render the hook manifest for one vendor (LLD 6.1).

Failure class: fail-closed. A manifest that does not validate, or a logical tool set
with no vendor spelling, aborts the render rather than producing a configuration
with a hook quietly missing.

Usage:
    python3 -m ihar.render.hooks <vendor> <profile> <manifest> <home-var> [--json-only]
"""

from __future__ import annotations

import json
import sys

from .. import jsonio

# Logical tool set to vendor matcher. Matchers are regular expressions, not globs:
# the vendors match them as patterns, so a `*` written literally would mean "zero or
# more of the preceding character" and match almost nothing.
_MATCHERS = {
    "shell": {"claude": "Bash", "codex": "Bash"},
    "file-write": {"claude": r"Write|Edit|MultiEdit", "codex": r"apply_patch|Write|Edit"},
    "file-read": {"claude": "Read", "codex": "Read"},
    # Codex exposes no Skill tool: `app-server generate-json-schema` leaves a hook's
    # `toolName` a free string with no enum, its `Skill*` definitions are the
    # app-server's own listing API rather than a tool, and the binary carries no such
    # tool name. An entry asking for one is therefore rendered for Claude alone rather
    # than given a matcher that can never fire — and a gate that needs to see a skill
    # on Codex asks for `file-read` and `shell` as well, which is how one shows up
    # there (LLD 6.1).
    "skill": {"claude": "Skill"},
    "any": {"claude": None, "codex": None},
}


def matcher_for(tools, vendor):
    """The vendor matcher for a logical tool set, or None when the set is `any`."""
    parts = []
    for tool in tools:
        if tool.startswith("mcp:"):
            pattern = tool[len("mcp:"):].replace("*", ".*")
            parts.append(f"mcp__{pattern}")
            continue
        if tool.startswith("tool:"):
            parts.append(tool[len("tool:"):])
            continue
        spelling = _MATCHERS.get(tool)
        if spelling is None:
            raise jsonio.SchemaError(f"unknown logical tool set {tool!r}")
        if vendor not in spelling:
            continue          # this vendor has no such tool; the entry drops out
        if spelling[vendor] is None:
            return None       # `any`: the vendor wants no matcher at all
        parts.append(spelling[vendor])
    if not parts:
        return ""             # nothing this vendor can match
    return "|".join(parts)


def _selected(entry, vendor, profile):
    if vendor not in entry["vendors"]:
        return False
    profiles = entry["profiles"]
    return "*" in profiles or profile in profiles


def render(manifest, vendor, profile, home_var):
    """{event: [{matcher, hooks: [...]}, ...]} for the given vendor and profile."""
    events: dict[str, list] = {}
    for entry in manifest["entries"]:
        if not _selected(entry, vendor, profile):
            continue
        matcher = matcher_for(entry["tools"], vendor)
        if matcher == "":
            continue

        command = f'python3 -I "${home_var}/hooks/{entry["script"]}"'
        for argument in entry["args"]:
            command += f" {argument}"
        command += f" --vendor {vendor}"

        rendered = {"hooks": [{"type": "command", "command": command,
                               "timeout": entry["timeout"]}]}
        if matcher is not None:
            rendered = {"matcher": matcher, **rendered}
        events.setdefault(entry["event"], []).append(rendered)
    return events


def main(argv):
    if len(argv) < 4:
        print(__doc__, file=sys.stderr)
        return 2
    vendor, profile, manifest_path, home_var = argv[:4]
    try:
        manifest = jsonio.read("hook-manifest", manifest_path)
        events = render(manifest, vendor, profile, home_var)
    except (jsonio.SchemaError, OSError) as error:
        print(f"ihar: {error}", file=sys.stderr)
        return 3

    if vendor == "codex":
        # Codex reads one file, whose whole content is the hook block.
        print(json.dumps({"hooks": events}, indent=2, sort_keys=True))
    else:
        # Claude reads the block as one key of settings.json.
        print(json.dumps({"hooks": events}, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
