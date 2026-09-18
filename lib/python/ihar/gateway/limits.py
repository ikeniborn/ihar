"""Bounds on what the gateway will read before it decides (LLD 8.6).

The gateway parses a request body in full in order to mask it, which makes it a
memory amplifier for anything that can reach the loopback port. The limits exist so
that an oversized or deeply nested payload is refused rather than absorbed.

Failure class: fail-closed per request. Exceeding a limit under an enforced profile
is a refusal, never a truncation: sending a shortened body would be sending something
the caller did not write.
"""

from __future__ import annotations

import os

MAX_HEADER_COUNT = int(os.environ.get("IHAR_GATEWAY_MAX_HEADERS", "100"))
MAX_HEADER_BYTES = int(os.environ.get("IHAR_GATEWAY_MAX_HEADER_BYTES", str(16 * 1024)))
MAX_BODY_BYTES = int(os.environ.get("IHAR_GATEWAY_MAX_BODY_BYTES", str(32 * 1024 * 1024)))
MAX_JSON_DEPTH = int(os.environ.get("IHAR_GATEWAY_MAX_JSON_DEPTH", "64"))
MAX_STRING_BYTES = int(os.environ.get("IHAR_GATEWAY_MAX_STRING_BYTES", str(4 * 1024 * 1024)))
CONNECT_TIMEOUT = float(os.environ.get("IHAR_GATEWAY_CONNECT_TIMEOUT", "10"))
READ_TIMEOUT = float(os.environ.get("IHAR_GATEWAY_READ_TIMEOUT", "300"))


class TooLarge(Exception):
    """A payload beyond what the gateway will process."""


def check_headers(headers) -> None:
    items = list(headers.items()) if hasattr(headers, "items") else list(headers)
    if len(items) > MAX_HEADER_COUNT:
        raise TooLarge(f"{len(items)} headers, over {MAX_HEADER_COUNT}")
    total = sum(len(str(key)) + len(str(value)) for key, value in items)
    if total > MAX_HEADER_BYTES:
        raise TooLarge(f"{total} header bytes, over {MAX_HEADER_BYTES}")


def check_body_length(length: int) -> None:
    if length > MAX_BODY_BYTES:
        raise TooLarge(f"{length} body bytes, over {MAX_BODY_BYTES}")


def check_depth(value, depth: int = 0) -> None:
    """Bounded recursion before the masker walks the same tree.

    A deeply nested body would otherwise exhaust the stack inside the traversal,
    where the failure is a crash rather than a decision.
    """
    if depth > MAX_JSON_DEPTH:
        raise TooLarge(f"nested deeper than {MAX_JSON_DEPTH}")
    if isinstance(value, dict):
        for item in value.values():
            check_depth(item, depth + 1)
    elif isinstance(value, list):
        for item in value:
            check_depth(item, depth + 1)
    elif isinstance(value, str) and len(value) > MAX_STRING_BYTES:
        raise TooLarge(f"a string of {len(value)} bytes, over {MAX_STRING_BYTES}")
