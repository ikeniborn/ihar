"""Build and atomically publish machine-local installation evidence (LLD 14.1)."""

from __future__ import annotations

import hashlib
import json
import os
import sys
import tempfile
from collections.abc import Mapping
from datetime import datetime, timezone

from . import jsonio


def _digest(path: str | os.PathLike[str]) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _read_lock(path: str | os.PathLike[str]) -> tuple[dict, str]:
    target = os.fspath(path)
    with open(target, "rb") as handle:
        raw = handle.read()
    try:
        lock = json.loads(raw)
    except (json.JSONDecodeError, UnicodeDecodeError) as error:
        raise jsonio.SchemaError(f"{target}: not valid JSON: {error}") from error
    try:
        jsonio.check("lockfile", lock)
    except jsonio.SchemaError as error:
        raise jsonio.SchemaError(f"{target}: {error}") from None
    return lock, hashlib.sha256(raw).hexdigest()


def build_receipt(
    lockfile: str | os.PathLike[str],
    binaries: Mapping[str, str | os.PathLike[str] | None],
    installed_at: str,
) -> dict:
    """Build evidence for the Claude and Codex executables present at install time."""
    lock, release_digest = _read_lock(lockfile)
    components: dict[str, dict[str, str]] = {}
    for vendor in ("claude", "codex"):
        binary = binaries.get(vendor)
        if binary is None or os.fspath(binary) == "-":
            continue
        path = os.fspath(binary)
        if not os.path.isfile(path) or not os.access(path, os.X_OK):
            continue
        release = lock.get(vendor)
        if not isinstance(release, dict) or not release.get("version"):
            raise jsonio.SchemaError(
                f"lockfile has an installed {vendor} executable but no {vendor}.version"
            )
        components[vendor] = {
            "version": release["version"],
            "binary_sha256": _digest(path),
        }

    receipt = {
        "schema": 1,
        "release_lock_sha256": release_digest,
        "installed_at": installed_at,
        "components": components,
    }
    return jsonio.check("install-receipt", receipt)


def read_receipt(path: str | os.PathLike[str]) -> dict:
    """Read validated machine-local installation evidence."""
    return jsonio.read("install-receipt", path)


def write_receipt(path: str | os.PathLike[str], receipt: dict) -> None:
    """Validate and atomically replace a receipt, including its directory entry."""
    jsonio.check("install-receipt", receipt)
    target = os.fspath(path)
    directory = os.path.dirname(target) or "."
    handle = tempfile.NamedTemporaryFile(
        "w", encoding="utf-8", dir=directory, prefix=".install-receipt-", delete=False
    )
    try:
        os.fchmod(handle.fileno(), 0o600)
        json.dump(receipt, handle, indent=2, sort_keys=True, ensure_ascii=False)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
        handle.close()
        os.replace(handle.name, target)
        directory_fd = os.open(directory, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    except BaseException:
        handle.close()
        try:
            os.unlink(handle.name)
        except FileNotFoundError:
            pass
        raise


def _installed_at() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def main(argv: list[str]) -> int:
    if len(argv) != 5 or argv[0] != "build":
        print(__doc__, file=sys.stderr)
        return 2
    _, lockfile, target, claude_path, codex_path = argv
    try:
        receipt = build_receipt(
            lockfile,
            {"claude": claude_path, "codex": codex_path},
            _installed_at(),
        )
        write_receipt(target, receipt)
    except (jsonio.SchemaError, OSError) as error:
        print(f"ihar: {error}", file=sys.stderr)
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
