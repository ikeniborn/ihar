"""The effective profile, read from disk rather than from the environment.

A Codex hook may run under the shared app-server daemon, which the vendor documents
as handing every client the environment it inherited when it started. A hook that
read IHAR_PROFILE from its environment would therefore apply an earlier launch's
policy to this one. The renderer writes the answer next to the vendor configuration
instead, and a hook reads it from there.

Failure class: fail-closed for the security hook. A policy file that cannot be read
means the hook does not know what it is enforcing, and the caller treats that as a
denial rather than as permission.
"""

from __future__ import annotations

import json
import os

POLICY_NAME = "ihar-policy.json"


def _runtime_home(event=None) -> str | None:
    """The vendor configuration directory this hook is running inside.

    Taken from the vendor's own variable, which the vendor sets for its own reasons
    and which therefore describes the session actually running, unlike anything ihar
    exports.
    """
    vendor = getattr(event, "vendor", None)
    names = {
        "codex": ("CODEX_HOME",),
        "claude": ("CLAUDE_CONFIG_DIR",),
    }.get(vendor, ("CODEX_HOME", "CLAUDE_CONFIG_DIR"))
    for name in names:
        value = os.environ.get(name)
        if value:
            return value
    if event is not None and getattr(event, "cwd", ""):
        return None
    return None


def load(event=None) -> dict:
    """The effective policy, or an empty dict when there is none to read."""
    home = _runtime_home(event)
    if not home:
        return {}
    path = os.path.join(home, POLICY_NAME)
    try:
        with open(path, "r", encoding="utf-8") as handle:
            loaded = json.load(handle)
    except (OSError, json.JSONDecodeError):
        return {}
    return loaded if isinstance(loaded, dict) else {}


def enforced(policy: dict) -> bool:
    return policy.get("hooks") == "enforced"


def masking_level(policy: dict) -> str:
    level = policy.get("masking_level")
    return level if level in ("off", "secrets", "standard") else "standard"


def protected_paths(policy: dict) -> list[str]:
    """Directories no agent may write: the store, the state root, the runtime home.

    Verifying a hook at launch does not stop an agent from rewriting it before the
    next hook runs, so the paths are refused as well as pinned.
    """
    paths = policy.get("protected_paths")
    return [path for path in paths if isinstance(path, str)] if isinstance(paths, list) else []
