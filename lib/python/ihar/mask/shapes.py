"""What a model request contains, and what may be sent (LLD 8.4).

This is where R4 is either true or not, so the rules are stated as rules rather than
left implicit in the traversal:

1. Every string is inspected. There is no field the masker skips.
2. A string under a structural key is scanned with the secrets ruleset only. Mangling
   a path, a command or an identifier breaks the call; a credential embedded in one
   still has to be caught.
3. Everything else is masked at the effective level. The Anthropic top-level `system`
   field is masked, because it carries project instructions that may contain personal
   data. Harness-authored `developer` content and the OpenAI `instructions` field get
   the secrets ruleset, on the same reasoning as structural keys.
4. An unknown content block type, an unknown top-level key or an unknown schema
   version is refused. A masker cannot promise anything about a shape it has never
   seen, and relaying it would be a promise.
5. A non-text payload — an image, a document, a large base64 blob, a file reference —
   is refused under an enforced profile. A text masker cannot certify an image, and
   the honest answer to "can you clean this?" is no.

Failure class: this module raises `Unsupported`; the gateway turns that into a 502.
"""

from __future__ import annotations

from typing import Any

# Values whose shape is load-bearing. Masking them would break the request rather
# than protect it, so they are scanned for credentials and otherwise left alone.
# The list is icodex's, which was derived from real breakage (server.py:28-31).
STRUCTURAL_KEYS = frozenset({
    "file_path", "path", "notebook_path", "command", "pattern", "glob",
    "tool_call_id", "call_id", "id", "name", "role", "type", "model",
    "cache_control", "stop_reason", "service_tier", "encoding_format",
})

# Content blocks a text masker can honestly handle.
_TEXT_BLOCKS = frozenset({"text", "input_text", "output_text", "tool_use", "tool_result",
                          "function_call", "function_call_output", "reasoning",
                          "thinking", "redacted_thinking", "refusal"})

# Blocks that are legitimate but not text. Refused under an enforced profile rather
# than passed, because nothing here can clean them.
_BINARY_BLOCKS = frozenset({"image", "input_image", "document", "input_file", "file",
                            "audio", "input_audio", "video"})

_BASE64_LIMIT = 4096


class Unsupported(Exception):
    """A payload this masker cannot promise anything about."""


def family_for(path: str) -> str:
    if path.startswith("/v1/messages"):
        return "anthropic"
    return "openai"


def transform(body: Any, masker, *, family: str, enforced: bool) -> tuple[Any, list[str]]:
    """Return the masked body and the kinds found, or raise Unsupported."""
    kinds: list[str] = []
    if not isinstance(body, dict):
        raise Unsupported("the request body is not an object")
    return _walk(body, masker, kinds, enforced=enforced, secrets_only=False), kinds


def _walk(value, masker, kinds, *, enforced: bool, secrets_only: bool):
    if isinstance(value, str):
        masked, found = (masker.secrets_only(value) if secrets_only else masker.mask(value))
        kinds.extend(found)
        if enforced and not secrets_only and _looks_like_blob(value):
            raise Unsupported("a large base64 value cannot be masked")
        return masked

    if isinstance(value, list):
        return [_walk(item, masker, kinds, enforced=enforced, secrets_only=secrets_only)
                for item in value]

    if isinstance(value, dict):
        kind = value.get("type")
        if isinstance(kind, str):
            if kind in _BINARY_BLOCKS:
                if enforced:
                    raise Unsupported(f"a {kind!r} block is not text and cannot be masked")
            elif kind not in _TEXT_BLOCKS and _looks_like_block(value):
                if enforced:
                    raise Unsupported(f"unknown content block type {kind!r}")

        out = {}
        for key, item in value.items():
            out[key] = _walk(
                item, masker, kinds,
                enforced=enforced,
                secrets_only=secrets_only or key in STRUCTURAL_KEYS or _instructional(key),
            )
        return out

    return value


def _instructional(key: str) -> bool:
    """Harness-authored text: scanned for credentials, not reshaped.

    `system` is deliberately absent. On the Anthropic wire it carries the project's
    own instructions, which routinely include paths, names and other personal data,
    so it is masked like any other content.
    """
    return key in ("instructions", "baseInstructions", "developerInstructions")


def _looks_like_block(value: dict) -> bool:
    """A content block, rather than an arbitrary object that happens to have `type`."""
    return bool({"text", "source", "content", "input", "data"} & set(value))


def _looks_like_blob(value: str) -> bool:
    if len(value) < _BASE64_LIMIT:
        return False
    sample = value[:512]
    allowed = set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=\n\r")
    return set(sample) <= allowed
