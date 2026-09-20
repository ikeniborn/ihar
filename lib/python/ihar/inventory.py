"""Validated queries over ihar's canonical manifests."""

from __future__ import annotations

import hashlib
import json
import os
import stat
import sys
from collections.abc import Iterator

from ihar import jsonio


def state_entries(
    manifest: str | os.PathLike[str], vendor: str
) -> Iterator[tuple[str, str]]:
    document = jsonio.read("state-manifest", manifest)
    for entry in document["entries"]:
        if entry["vendor"] == vendor:
            yield entry["path"], entry["kind"]


def state_manifest_digest(manifest: str | os.PathLike[str]) -> str:
    """Return a stable digest of the validated semantic manifest document."""
    document = jsonio.read("state-manifest", manifest)
    encoded = json.dumps(
        document, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def asset_entries(
    manifest: str | os.PathLike[str], vendor: str
) -> Iterator[tuple[str, str, str, bool, bool]]:
    document = jsonio.read("asset-manifest", manifest)
    for entry in document["entries"]:
        if vendor == "all" or entry["vendor"] in ("common", vendor):
            yield entry["source"], entry["target"], entry["kind"], entry["required"], entry["runtime"]


def asset_manifest_identity(
    manifest: str | os.PathLike[str], vendor: str, root: str | os.PathLike[str]
) -> str:
    """Return canonical identity for runtime-affecting asset topology.

    Asset bytes live behind store links and therefore do not select a runtime
    generation. The validated entry semantics do, as does store-source presence:
    an optional installed source changes which links the next runtime owns.
    """
    document = jsonio.read("asset-manifest", manifest)
    root_path = os.path.abspath(os.fspath(root))
    entries = []
    for entry in document["entries"]:
        if not entry["runtime"]:
            continue
        if vendor != "all" and entry["vendor"] not in ("common", vendor):
            continue
        source = os.path.join(root_path, entry["source"])
        present = os.path.isdir(source) if entry["kind"] == "directory" else os.path.isfile(source)
        entries.append({**entry, "present": present})
    entries.sort(
        key=lambda entry: (
            entry["vendor"],
            entry["target"],
            entry["source"],
            entry["kind"],
            entry["required"],
            entry["runtime"],
        )
    )
    encoded = json.dumps(
        {"schema": document["schema"], "entries": entries},
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def mutable_link_entries(
    manifest: str | os.PathLike[str], vendor: str
) -> Iterator[tuple[str, str, str]]:
    document = jsonio.read("mutable-link-manifest", manifest)
    for entry in document["entries"]:
        if vendor == "all" or entry["vendor"] == vendor:
            yield entry["source"], entry["target"], entry["kind"]


def _unsafe_mutable_source(source: str, detail: str) -> jsonio.SchemaError:
    return jsonio.SchemaError(f"mutable-link source {source!r} is unsafe: {detail}")


def _preflight_directory_chain(path: str, source: str) -> None:
    current = os.path.sep
    for component in os.path.abspath(path).split(os.path.sep)[1:]:
        current = os.path.join(current, component)
        try:
            metadata = os.lstat(current)
        except FileNotFoundError:
            return
        except NotADirectoryError:
            raise _unsafe_mutable_source(source, f"non-directory parent {current!r}") from None
        if stat.S_ISLNK(metadata.st_mode):
            raise _unsafe_mutable_source(source, f"symlinked parent {current!r}")
        if not stat.S_ISDIR(metadata.st_mode):
            raise _unsafe_mutable_source(source, f"non-directory parent {current!r}")


def _preflight_mutable_entry(root: str, source: str, kind: str) -> None:
    root = os.path.abspath(root)
    candidate = os.path.abspath(os.path.join(root, source))
    try:
        contained = os.path.commonpath((root, candidate)) == root
    except ValueError:
        contained = False
    if not contained:
        raise _unsafe_mutable_source(source, "path escapes the mutable store root")

    _preflight_directory_chain(root, source)
    current = root
    components = source.split("/")
    for index, component in enumerate(components):
        current = os.path.join(current, component)
        try:
            metadata = os.lstat(current)
        except FileNotFoundError:
            return
        except NotADirectoryError:
            raise _unsafe_mutable_source(source, f"non-directory parent {current!r}") from None

        leaf = index == len(components) - 1
        if stat.S_ISLNK(metadata.st_mode):
            raise _unsafe_mutable_source(
                source, f"symlinked {'leaf' if leaf else 'parent'} {current!r}"
            )
        if not leaf and not stat.S_ISDIR(metadata.st_mode):
            raise _unsafe_mutable_source(source, f"non-directory parent {current!r}")
        if leaf and kind == "file" and not stat.S_ISREG(metadata.st_mode):
            raise _unsafe_mutable_source(source, f"file leaf {current!r} is not regular")
        if leaf and kind == "directory" and not stat.S_ISDIR(metadata.st_mode):
            raise _unsafe_mutable_source(source, f"directory leaf {current!r} is not real")


def preflight_mutable_sources(
    manifest: str | os.PathLike[str], vendor: str, root: str | os.PathLike[str]
) -> list[tuple[str, str, str]]:
    entries = list(mutable_link_entries(manifest, vendor))
    for source, _target, kind in entries:
        _preflight_mutable_entry(os.fspath(root), source, kind)
    return entries


def _open_real_directory(parent_fd: int, component: str, source: str) -> int:
    try:
        os.mkdir(component, mode=0o700, dir_fd=parent_fd)
    except FileExistsError:
        pass
    try:
        return os.open(
            component,
            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
            dir_fd=parent_fd,
        )
    except OSError as error:
        raise _unsafe_mutable_source(source, f"cannot open real directory {component!r}: {error}") from None


def _open_absolute_directory(path: str, source: str) -> int:
    descriptor = os.open(
        os.path.sep, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
    )
    try:
        for component in os.path.abspath(path).split(os.path.sep)[1:]:
            child = _open_real_directory(descriptor, component, source)
            os.close(descriptor)
            descriptor = child
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def _prepare_mutable_entry(root_fd: int, source: str, kind: str) -> None:
    descriptor = os.dup(root_fd)
    try:
        components = source.split("/")
        directory_components = components if kind == "directory" else components[:-1]
        for component in directory_components:
            child = _open_real_directory(descriptor, component, source)
            os.close(descriptor)
            descriptor = child

        if kind == "file":
            leaf = components[-1]
            try:
                metadata = os.stat(leaf, dir_fd=descriptor, follow_symlinks=False)
            except FileNotFoundError:
                return
            if not stat.S_ISREG(metadata.st_mode):
                raise _unsafe_mutable_source(source, "file leaf is not regular")
    finally:
        os.close(descriptor)


def prepare_mutable_sources(
    manifest: str | os.PathLike[str], vendor: str, root: str | os.PathLike[str]
) -> None:
    root_path = os.path.abspath(os.fspath(root))
    entries = preflight_mutable_sources(manifest, vendor, root_path)
    root_fd = _open_absolute_directory(root_path, root_path)
    try:
        for source, _target, kind in entries:
            _prepare_mutable_entry(root_fd, source, kind)
        if any(source.startswith("auth/") for source, _target, _kind in entries):
            auth_fd = _open_real_directory(root_fd, "auth", "auth")
            try:
                os.fchmod(auth_fd, 0o700)
            finally:
                os.close(auth_fd)
    finally:
        os.close(root_fd)


def main(argv: list[str]) -> int:
    query_commands = ("state", "state-digest", "assets", "mutable-links")
    mutable_commands = ("mutable-preflight", "mutable-prepare")
    commands = (*query_commands, "asset-identity", *mutable_commands)
    if len(argv) not in (3, 4) or argv[0] not in commands:
        return 2
    command, manifest, vendor = argv[:3]
    if command in query_commands and len(argv) != 3:
        return 2
    if command == "asset-identity" and len(argv) != 4:
        return 2
    if command in mutable_commands and len(argv) != 4:
        return 2
    try:
        if command == "state":
            for path, kind in state_entries(manifest, vendor):
                print(f"{path}\t{kind}")
        elif command == "state-digest":
            print(state_manifest_digest(manifest))
        elif command == "assets":
            for source, target, kind, required, runtime in asset_entries(manifest, vendor):
                print(f"{source}\t{target}\t{kind}\t{str(required).lower()}\t{str(runtime).lower()}")
        elif command == "asset-identity":
            print(asset_manifest_identity(manifest, vendor, argv[3]))
        elif command == "mutable-links":
            for source, target, kind in mutable_link_entries(manifest, vendor):
                print(f"{source}\t{target}\t{kind}")
        elif command == "mutable-preflight":
            preflight_mutable_sources(manifest, vendor, argv[3])
        else:
            prepare_mutable_sources(manifest, vendor, argv[3])
    except (OSError, jsonio.SchemaError) as error:
        print(f"ihar: cannot read {command} inventory {manifest}: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
