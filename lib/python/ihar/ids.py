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
    """RFC 9562 version 7: 48-bit Unix milliseconds, then version and variant bits.

    rand_a and rand_b are drawn from disjoint slices of the same 80 random bits. An
    earlier version took rand_a from bits 12 to 23 while rand_b took bits 0 to 61, so
    twelve bits appeared in both fields and the high eighteen were discarded: the id
    carried 62 bits of entropy, not the 74 claimed here, and two ids minted in the
    same millisecond collided 4096 times more often than the format allows.
    """
    millis = int(time.time() * 1000) & ((1 << 48) - 1)
    rand = int.from_bytes(os.urandom(10), "big")   # 80 bits, 74 of them used

    value = millis << 80
    value |= (7 << 76)                             # version
    value |= ((rand >> 62) & ((1 << 12) - 1)) << 64  # rand_a, bits 62 to 73
    value |= (2 << 62)                             # variant
    value |= rand & ((1 << 62) - 1)                # rand_b, bits 0 to 61
    return uuid.UUID(int=value)


def main(argv: list[str]) -> int:
    count = int(argv[0]) if argv else 1
    for _ in range(count):
        print(uuid7())
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
