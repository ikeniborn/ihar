"""UUIDv7 generation (LLD 10.1).

Time-ordered, so session ids sort by creation without a separate timestamp field,
and 74 bits of randomness rather than the 24 an eight-hex suffix would carry.

Usage: python3 -m ihar.ids [count]
"""

from __future__ import annotations

import os
import sys
import time
import uuid


def uuid7() -> uuid.UUID:
    """RFC 9562 version 7: 48-bit Unix milliseconds, then version and variant bits."""
    millis = int(time.time() * 1000) & ((1 << 48) - 1)
    rand = int.from_bytes(os.urandom(10), "big")

    value = millis << 80
    value |= (7 << 76)                      # version
    value |= ((rand >> 12) & ((1 << 12) - 1)) << 64   # rand_a
    value |= (2 << 62)                      # variant
    value |= rand & ((1 << 62) - 1)         # rand_b
    return uuid.UUID(int=value)


def main(argv: list[str]) -> int:
    count = int(argv[0]) if argv else 1
    for _ in range(count):
        print(uuid7())
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
