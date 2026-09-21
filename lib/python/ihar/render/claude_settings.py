"""Add the managed keys to a rendered Claude settings.json (LLD 4.3, 9.1).

The hook block is already in the file; this adds `sandbox` when the profile asks for
one and nothing when it does not. An absent key means the vendor's own default, which
is what `vendor-default` promises.

`ANTHROPIC_BASE_URL` is an environment variable rather than a settings key, so the
base URL argument only records that the gateway is explicit; the adapter exports it.

Usage:
    python3 -m ihar.render.claude_settings <settings-path> <sandbox-mode> <protected-roots-json> <base-url>
"""

from __future__ import annotations

import json
import os
import sys


def render_sandbox(mode: str, protected_roots: list[str]) -> dict | None:
    if mode == "vendor-default":
        return None
    if mode == "read-only":
        return {"enabled": True, "filesystem": "read-only"}
    roots = sorted({os.path.abspath(path) for path in protected_roots})
    return {
        "enabled": True,
        "allowUnsandboxedCommands": False,
        "failIfUnavailable": True,
        "filesystem": {"denyWrite": roots},
    }


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    path, sandbox_mode, protected_roots_json, base_url = argv

    try:
        with open(path, "r", encoding="utf-8") as handle:
            settings = json.load(handle)
    except (OSError, json.JSONDecodeError) as error:
        print(f"ihar: {path}: {error}", file=sys.stderr)
        return 3

    try:
        protected_roots = json.loads(protected_roots_json)
        sandbox = render_sandbox(sandbox_mode, protected_roots)
    except (json.JSONDecodeError, TypeError) as error:
        print(f"ihar: protected roots are not a JSON array of paths: {error}", file=sys.stderr)
        return 3

    if sandbox is None:
        settings.pop("sandbox", None)
    else:
        settings["sandbox"] = sandbox

    if base_url:
        # Recorded so `ihar check --diff` can show which gateway a home was rendered
        # against. The vendor reads the environment variable, not this.
        settings["_iharGateway"] = base_url
    else:
        settings.pop("_iharGateway", None)

    with open(path, "w", encoding="utf-8") as handle:
        json.dump(settings, handle, indent=2, sort_keys=True)
        handle.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
