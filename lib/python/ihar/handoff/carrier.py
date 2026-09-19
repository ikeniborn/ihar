"""Split a UTF-8 handoff carrier on a safe boundary at or below 2048 bytes."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path


def split(data: bytes, limit: int = 2048) -> tuple[bytes, bytes]:
    boundary = min(limit, len(data))
    while boundary and (data[boundary:boundary + 1] and data[boundary] & 0xC0 == 0x80):
        boundary -= 1
    return data[:boundary], data[boundary:]


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(); parser.add_argument("part", choices=("prefix", "remainder"))
    parser.add_argument("path"); args = parser.parse_args(argv)
    prefix, remainder = split(Path(args.path).read_bytes())
    sys.stdout.buffer.write(prefix if args.part == "prefix" else remainder)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
