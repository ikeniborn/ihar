"""Validate a profile and emit its fields as shell assignments.

Failure class: usage. A profile that does not validate aborts the launch, because
every later layer reads these values to decide what it enforces.

Emitting `IHAR_PROFILE_*` assignments keeps the parsing in Python, where the contract
already lives, rather than adding a second JSON reader in shell.

Usage: python3 -m ihar.profile_read <profile-path>
"""

from __future__ import annotations

import shlex
import sys

from . import jsonio

# Fields the shell reads. A field absent here is still validated; it is simply not
# needed by any shell caller yet.
_SCALARS = ("name", "guarantee", "hooks", "gateway", "masking_level", "sandbox", "acp")


def emit(profile: dict) -> str:
    lines = []
    for key in _SCALARS:
        value = profile[key]
        lines.append(f"IHAR_PROFILE_{key.upper()}={shlex.quote(str(value))}")

    netpolicy = profile["netpolicy"] or ""
    lines.append(f"IHAR_PROFILE_NETPOLICY={shlex.quote(netpolicy)}")
    lines.append(f"IHAR_PROFILE_MCP_STRICT={str(profile['mcp']['strict']).lower()}")
    lines.append(
        f"IHAR_PROFILE_HANDOFF_SYSTEM_PROMPT={str(profile['handoff']['system_prompt']).lower()}"
    )
    lines.append(f"IHAR_PROFILE_REMOTE={shlex.quote(' '.join(profile['remote']))}")
    lines.append(f"IHAR_PROFILE_ENV_PASSTHROUGH={shlex.quote(' '.join(profile['env_passthrough']))}")
    return "\n".join(lines)


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        print(__doc__, file=sys.stderr)
        return 2
    try:
        profile = jsonio.read("profile", argv[0])
    except (jsonio.SchemaError, OSError) as error:
        print(f"ihar: {error}", file=sys.stderr)
        return 2
    print(emit(profile))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
