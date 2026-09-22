"""Read and verify the lockfile (LLD 14.1, 14.2).

Failure class: fail-closed for the hook maps, because those files are the
enforcement. This module reports; the shell decides the exit code.

Usage:
    python3 -m ihar.lockfile --get <dotted.path> <lockfile>
    python3 -m ihar.lockfile --verify-map <key> <lockfile> <store>

`--verify-map` prints the first path that does not satisfy its pin, prefixed by what is
wrong with it — `missing` or `changed` — and nothing when every entry agrees. A file the
lockfile pins but the store does not have counts as a mismatch: a pinned hook that is
missing is not a hook that passed. The two are told apart because they are different
situations for whoever reads the refusal: a missing file means this store predates the
pin, a changed one means something rewrote it.
"""

from __future__ import annotations

import hashlib
import os
import sys

from . import jsonio


def _load(path: str) -> dict:
    return jsonio.read("lockfile", path)


def get(dotted: str, path: str) -> int:
    value = _load(path)
    for part in dotted.split("."):
        if not isinstance(value, dict) or part not in value:
            return 1
        value = value[part]
    print(value)
    return 0


def _digest(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_map(key: str, path: str, store: str) -> int:
    lock = _load(path)
    entries = lock.get(key) or {}
    for relative, pinned in sorted(entries.items()):
        target = os.path.join(store, relative)
        if not os.path.isfile(target):
            print(f"missing {target}")
            return 1
        if _digest(target) != pinned:
            print(f"changed {target}")
            return 1
    return 0


def main(argv: list[str]) -> int:
    try:
        if len(argv) == 3 and argv[0] == "--get":
            return get(argv[1], argv[2])
        if len(argv) == 4 and argv[0] == "--verify-map":
            return verify_map(argv[1], argv[2], argv[3])
    except (jsonio.SchemaError, OSError) as error:
        # Exit 3, not 1. The caller treats 1 as "verified, and something differs";
        # an error means it could not verify at all, and a fail-closed check must be
        # able to tell those apart or a broken reader reads as a clean bill.
        print(f"ihar: {error}", file=sys.stderr)
        return 3
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
