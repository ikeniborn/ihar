"""Which requests are masked, which are relayed, and which are refused (LLD 8.3).

The default is refuse, and that is the whole point. HLD section 10 requires that the
gateway cannot mask what it cannot parse and must fail closed; a routing table whose
last rule is "relay anything else" would quietly carry a new vendor endpoint straight
past the masker on the day the vendor ships one.

Three named classes, and everything outside them is refused when masking is on:

  model    a request whose body is a model payload; parsed and masked
  transit  a request known to carry no model payload; relayed byte for byte
  local    answered by the gateway itself
  unknown  refused with 502, logged with method, host and path

The transit list is an allowlist of shapes ihar has decided are safe to relay, not a
catch-all. Adding to it is a decision, which is what makes it reviewable.
"""

from __future__ import annotations

import re

MODEL = "model"
TRANSIT = "transit"
LOCAL = "local"
UNKNOWN = "unknown"

ANTHROPIC = "anthropic"
OPENAI = "openai"
CHATGPT = "chatgpt"

# (method, path pattern, upstream)
_MODEL_ROUTES = (
    ("POST", re.compile(r"^/v1/messages(/count_tokens|/batches.*)?$"), ANTHROPIC),
    ("POST", re.compile(r"^/v1/responses$"), OPENAI),
    ("POST", re.compile(r"^/v1/chat/completions$"), OPENAI),
    ("POST", re.compile(r"^/backend-api/codex/responses$"), CHATGPT),
)

_LOCAL_PATHS = re.compile(r"^/api/(ihar-probe|health|meta|metrics)$")

# Requests that carry no model payload. Each entry is a decision about one shape.
_TRANSIT_PATHS = (
    re.compile(r"^/v1/models(/.*)?$"),          # capability discovery
    re.compile(r"^/v1/organizations(/.*)?$"),   # account metadata
    re.compile(r"^/oauth(/.*)?$"),              # login
    re.compile(r"^/api/auth(/.*)?$"),
    re.compile(r"^/backend-api/(accounts|me|wham)(/.*)?$"),
    re.compile(r"^/v1/me$"),
    re.compile(r"^/\.well-known(/.*)?$"),
)


def classify(method: str, path: str, headers) -> tuple[str, str | None]:
    """(class, upstream). `upstream` is set only for the model class."""
    bare = path.split("?", 1)[0]

    if _LOCAL_PATHS.match(bare):
        return LOCAL, None

    # A WebSocket upgrade is never a model request and cannot be parsed as one. The
    # ChatGPT remote-control relay rides on this, and breaking it would take the web
    # surface down for a profile that never asked the gateway to touch it.
    if _is_upgrade(headers):
        return TRANSIT, None

    for wanted, pattern, upstream in _MODEL_ROUTES:
        if method == wanted and pattern.match(bare):
            return MODEL, upstream

    for pattern in _TRANSIT_PATHS:
        if pattern.match(bare):
            return TRANSIT, None

    return UNKNOWN, None


def _is_upgrade(headers) -> bool:
    if headers is None:
        return False
    value = headers.get("Upgrade") or headers.get("upgrade") or ""
    return "websocket" in str(value).lower()
