"""Fingerprint the legacy state subset copied by ``ihar homes migrate``."""

from __future__ import annotations

import hashlib
import os
import stat
import sys
from pathlib import Path


ENTRIES = (
    "projects",
    "sessions",
    "session-env",
    "history.jsonl",
    "file-history",
    "state_5.sqlite",
    "state_5.sqlite-wal",
    "thread_history_1.sqlite",
    "thread_history_1.sqlite-wal",
)


def fingerprint(root: Path) -> str:
    digest = hashlib.sha256()

    def add(path: Path) -> None:
        relative = path.relative_to(root).as_posix().encode()
        info = path.lstat()
        if stat.S_ISLNK(info.st_mode):
            return
        if stat.S_ISDIR(info.st_mode):
            digest.update(b"d\0" + relative + b"\0" + oct(stat.S_IMODE(info.st_mode)).encode() + b"\0")
            for child in sorted(path.iterdir(), key=lambda item: os.fsencode(item.name)):
                add(child)
            return
        if not stat.S_ISREG(info.st_mode):
            return
        digest.update(
            b"f\0"
            + relative
            + b"\0"
            + oct(stat.S_IMODE(info.st_mode)).encode()
            + b"\0"
            + str(info.st_size).encode()
            + b"\0"
            + str(info.st_mtime_ns).encode()
            + b"\0"
        )
        with path.open("rb") as handle:
            while chunk := handle.read(1024 * 1024):
                digest.update(chunk)

    for entry in ENTRIES:
        path = root / entry
        if path.exists() or path.is_symlink():
            add(path)
    return digest.hexdigest()


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        return 2
    try:
        print(fingerprint(Path(argv[0])))
    except OSError as error:
        print(f"ihar: cannot fingerprint migration source {argv[0]}: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
