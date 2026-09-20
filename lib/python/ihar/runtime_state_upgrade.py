"""Transactional migration of persistent state materialized in old runtime homes."""

from __future__ import annotations

import ctypes
import hashlib
import os
import secrets
import stat
import sys
from dataclasses import dataclass
from pathlib import Path

from ihar import jsonio
from ihar.inventory import state_entries


class UpgradeError(RuntimeError):
    """A runtime-state upgrade could not prove a lossless transaction."""


_DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
_FILE_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC
_RENAME_EXCHANGE = 2
_IHAR_PROCESS_NAMES = frozenset(("ihar", "ihar.sh"))
_VENDOR_PROCESS_NAMES = {
    "claude": frozenset(("claude", "claude-agent-acp")),
    "codex": frozenset(("codex", "codex-acp")),
}


@dataclass
class RuntimeView:
    path: Path
    generation: str
    descriptor: int
    materialized: list[tuple[str, str]]


def _expanded_entries(manifest: Path, vendor: str) -> list[tuple[str, str]]:
    expanded: list[tuple[str, str]] = []
    for path, kind in state_entries(manifest, vendor):
        if kind == "sqlite-family":
            expanded.extend((path + suffix, "file") for suffix in ("", "-wal", "-shm"))
        else:
            expanded.append((path, kind))
    return expanded


def _open_absolute_directory(path: Path, description: str) -> int:
    absolute = path.absolute()
    descriptor = os.open(os.path.sep, _DIRECTORY_FLAGS)
    try:
        for component in absolute.parts[1:]:
            try:
                child = os.open(component, _DIRECTORY_FLAGS, dir_fd=descriptor)
            except OSError as error:
                raise UpgradeError(
                    f"{description} must have only real directory ancestors: {absolute}: {error}"
                ) from error
            os.close(descriptor)
            descriptor = child
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def _open_directory_at(parent_fd: int, name: str, description: str, *, create: bool = False) -> int:
    if create:
        try:
            os.mkdir(name, mode=0o700, dir_fd=parent_fd)
        except FileExistsError:
            pass
    try:
        return os.open(name, _DIRECTORY_FLAGS, dir_fd=parent_fd)
    except OSError as error:
        raise UpgradeError(f"{description} must be a real directory: {error}") from error


def _open_parent(
    root_fd: int, relative: str, description: str, *, create: bool = False
) -> tuple[int, str]:
    components = relative.split("/")
    descriptor = os.dup(root_fd)
    try:
        for component in components[:-1]:
            child = _open_directory_at(
                descriptor, component, f"{description} ancestor {component!r}", create=create
            )
            os.close(descriptor)
            descriptor = child
        return descriptor, components[-1]
    except BaseException:
        os.close(descriptor)
        raise


def _entry_metadata(root_fd: int, relative: str, description: str) -> os.stat_result | None:
    components = relative.split("/")
    descriptor = os.dup(root_fd)
    try:
        for component in components[:-1]:
            try:
                child = os.open(component, _DIRECTORY_FLAGS, dir_fd=descriptor)
            except FileNotFoundError:
                return None
            except OSError as error:
                raise UpgradeError(
                    f"{description} ancestor {component!r} must be a real directory: {error}"
                ) from error
            os.close(descriptor)
            descriptor = child
        try:
            return os.stat(components[-1], dir_fd=descriptor, follow_symlinks=False)
        except FileNotFoundError:
            return None
    finally:
        os.close(descriptor)


def _validate_directory(descriptor: int, display: Path) -> None:
    for name in sorted(os.listdir(descriptor), key=os.fsencode):
        metadata = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
        child_display = display / name
        if stat.S_ISREG(metadata.st_mode):
            continue
        if not stat.S_ISDIR(metadata.st_mode):
            raise UpgradeError(
                f"materialized runtime state {display} contains unsupported entry {child_display}"
            )
        child = _open_directory_at(descriptor, name, f"materialized directory {child_display}")
        try:
            _validate_directory(child, child_display)
        finally:
            os.close(child)


def _validate_materialized(root_fd: int, relative: str, kind: str, display: Path) -> bool:
    metadata = _entry_metadata(root_fd, relative, f"materialized state {display}")
    if metadata is None:
        return False
    parent_fd, name = _open_parent(root_fd, relative, f"materialized state {display}")
    try:
        if kind == "file":
            if not stat.S_ISREG(metadata.st_mode):
                raise UpgradeError(f"materialized runtime state {display} has unexpected type")
            descriptor = os.open(name, _FILE_FLAGS, dir_fd=parent_fd)
            os.close(descriptor)
            return True
        if not stat.S_ISDIR(metadata.st_mode):
            raise UpgradeError(f"materialized runtime state {display} has unexpected type")
        descriptor = _open_directory_at(parent_fd, name, f"materialized directory {display}")
        try:
            _validate_directory(descriptor, display)
        finally:
            os.close(descriptor)
        return True
    finally:
        os.close(parent_fd)


def _fingerprint_node(digest: object, parent_fd: int, name: str, relative: str) -> None:
    metadata = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    encoded = os.fsencode(relative)
    if stat.S_ISDIR(metadata.st_mode):
        descriptor = _open_directory_at(parent_fd, name, f"fingerprint directory {relative}")
        try:
            opened = os.fstat(descriptor)
            if (opened.st_dev, opened.st_ino) != (metadata.st_dev, metadata.st_ino):
                raise UpgradeError(f"materialized runtime state changed during migration: {relative}")
            digest.update(b"d\0" + encoded + b"\0" + oct(stat.S_IMODE(opened.st_mode)).encode() + b"\0")
            for child in sorted(os.listdir(descriptor), key=os.fsencode):
                _fingerprint_node(digest, descriptor, child, f"{relative}/{child}")
        finally:
            os.close(descriptor)
        return
    if not stat.S_ISREG(metadata.st_mode):
        raise UpgradeError(f"materialized runtime state has unsupported entry: {relative}")
    descriptor = os.open(name, _FILE_FLAGS, dir_fd=parent_fd)
    try:
        opened = os.fstat(descriptor)
        if (opened.st_dev, opened.st_ino) != (metadata.st_dev, metadata.st_ino):
            raise UpgradeError(f"materialized runtime state changed during migration: {relative}")
        digest.update(
            b"f\0"
            + encoded
            + b"\0"
            + oct(stat.S_IMODE(opened.st_mode)).encode()
            + b"\0"
            + str(opened.st_size).encode()
            + b"\0"
            + str(opened.st_mtime_ns).encode()
            + b"\0"
        )
        while chunk := os.read(descriptor, 1024 * 1024):
            digest.update(chunk)
        finished = os.fstat(descriptor)
        if (
            finished.st_size != opened.st_size
            or finished.st_mtime_ns != opened.st_mtime_ns
            or finished.st_ctime_ns != opened.st_ctime_ns
        ):
            raise UpgradeError(f"materialized runtime state changed during migration: {relative}")
    finally:
        os.close(descriptor)


def _fingerprint_entries(root_fd: int, entries: list[str]) -> str:
    digest = hashlib.sha256()
    for relative in entries:
        parent_fd, name = _open_parent(root_fd, relative, f"fingerprint path {relative}")
        try:
            _fingerprint_node(digest, parent_fd, name, relative)
        finally:
            os.close(parent_fd)
    return digest.hexdigest()


def _write_all(descriptor: int, data: bytes) -> None:
    offset = 0
    while offset < len(data):
        offset += os.write(descriptor, data[offset:])


def _copy_node(
    source_parent_fd: int,
    source_name: str,
    target_parent_fd: int,
    target_name: str,
    display: str,
    *,
    allow_symlink: bool,
) -> None:
    metadata = os.stat(source_name, dir_fd=source_parent_fd, follow_symlinks=False)
    if stat.S_ISLNK(metadata.st_mode):
        if not allow_symlink:
            raise UpgradeError(f"materialized runtime state has unsupported entry: {display}")
        os.symlink(os.readlink(source_name, dir_fd=source_parent_fd), target_name, dir_fd=target_parent_fd)
        return
    if stat.S_ISDIR(metadata.st_mode):
        source_fd = _open_directory_at(source_parent_fd, source_name, f"copy source {display}")
        try:
            opened = os.fstat(source_fd)
            if (opened.st_dev, opened.st_ino) != (metadata.st_dev, metadata.st_ino):
                raise UpgradeError(f"materialized runtime state changed during migration: {display}")
            os.mkdir(target_name, stat.S_IMODE(opened.st_mode), dir_fd=target_parent_fd)
            target_fd = _open_directory_at(target_parent_fd, target_name, f"copy target {display}")
            try:
                for child in sorted(os.listdir(source_fd), key=os.fsencode):
                    _copy_node(
                        source_fd,
                        child,
                        target_fd,
                        child,
                        f"{display}/{child}",
                        allow_symlink=allow_symlink,
                    )
                os.fchmod(target_fd, stat.S_IMODE(opened.st_mode))
                os.utime(target_fd, ns=(opened.st_atime_ns, opened.st_mtime_ns))
            finally:
                os.close(target_fd)
        finally:
            os.close(source_fd)
        return
    if not stat.S_ISREG(metadata.st_mode):
        raise UpgradeError(f"materialized runtime state has unsupported entry: {display}")
    source_fd = os.open(source_name, _FILE_FLAGS, dir_fd=source_parent_fd)
    try:
        opened = os.fstat(source_fd)
        if (opened.st_dev, opened.st_ino) != (metadata.st_dev, metadata.st_ino):
            raise UpgradeError(f"materialized runtime state changed during migration: {display}")
        target_fd = os.open(
            target_name,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC,
            stat.S_IMODE(opened.st_mode),
            dir_fd=target_parent_fd,
        )
        try:
            while chunk := os.read(source_fd, 1024 * 1024):
                _write_all(target_fd, chunk)
            os.fchmod(target_fd, stat.S_IMODE(opened.st_mode))
            os.utime(target_fd, ns=(opened.st_atime_ns, opened.st_mtime_ns))
        finally:
            os.close(target_fd)
    finally:
        os.close(source_fd)


def _copy_entry(
    source_root_fd: int, target_root_fd: int, relative: str, *, allow_symlink: bool = False
) -> None:
    source_parent_fd, source_name = _open_parent(
        source_root_fd, relative, f"copy source {relative}"
    )
    target_parent_fd, target_name = _open_parent(
        target_root_fd, relative, f"copy target {relative}", create=True
    )
    try:
        _copy_node(
            source_parent_fd,
            source_name,
            target_parent_fd,
            target_name,
            relative,
            allow_symlink=allow_symlink,
        )
    finally:
        os.close(target_parent_fd)
        os.close(source_parent_fd)


def _copy_directory_contents(source_fd: int, target_fd: int) -> None:
    for name in sorted(os.listdir(source_fd), key=os.fsencode):
        _copy_node(source_fd, name, target_fd, name, name, allow_symlink=True)


def _remove_tree_at(parent_fd: int, name: str) -> None:
    metadata = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    if not stat.S_ISDIR(metadata.st_mode):
        os.unlink(name, dir_fd=parent_fd)
        return
    descriptor = _open_directory_at(parent_fd, name, f"cleanup directory {name}")
    try:
        for child in os.listdir(descriptor):
            _remove_tree_at(descriptor, child)
    finally:
        os.close(descriptor)
    os.rmdir(name, dir_fd=parent_fd)


def _mkdir_unique(parent_fd: int, prefix: str) -> str:
    for _attempt in range(100):
        name = f"{prefix}{secrets.token_hex(6)}"
        try:
            os.mkdir(name, mode=0o700, dir_fd=parent_fd)
            return name
        except FileExistsError:
            continue
    raise UpgradeError(f"cannot allocate unique migration directory with prefix {prefix}")


def _open_or_create_chain(root_fd: int, components: tuple[str, ...], description: str) -> int:
    descriptor = os.dup(root_fd)
    try:
        for component in components:
            child = _open_directory_at(
                descriptor, component, f"{description} {component!r}", create=True
            )
            os.close(descriptor)
            descriptor = child
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def _runtime_views(
    state_path: Path,
    state_fd: int,
    vendor: str,
    entries: list[tuple[str, str]],
) -> list[RuntimeView]:
    try:
        runtime_parent_fd = _open_directory_at(state_fd, "r", "runtime root")
    except UpgradeError as error:
        try:
            os.stat("r", dir_fd=state_fd, follow_symlinks=False)
        except FileNotFoundError:
            return []
        raise error
    views: list[RuntimeView] = []
    try:
        for generation in sorted(os.listdir(runtime_parent_fd), key=os.fsencode):
            if generation.startswith("."):
                continue
            generation_fd = _open_directory_at(
                runtime_parent_fd, generation, f"runtime generation {generation!r}"
            )
            runtime_fd = -1
            try:
                try:
                    runtime_fd = _open_directory_at(
                        generation_fd, vendor, f"runtime vendor {generation}/{vendor}"
                    )
                except UpgradeError as error:
                    try:
                        os.stat(vendor, dir_fd=generation_fd, follow_symlinks=False)
                    except FileNotFoundError:
                        continue
                    raise error
                materialized = []
                for relative, kind in entries:
                    metadata = _entry_metadata(
                        runtime_fd,
                        relative,
                        f"runtime state link {state_path / 'r' / generation / vendor / relative}",
                    )
                    if metadata is not None and stat.S_ISLNK(metadata.st_mode):
                        parent_fd, name = _open_parent(
                            runtime_fd, relative, f"runtime state link {relative}"
                        )
                        try:
                            target = os.readlink(name, dir_fd=parent_fd)
                        finally:
                            os.close(parent_fd)
                        expected = os.fspath(state_path / "st" / vendor / relative)
                        if target != expected:
                            raise UpgradeError(
                                f"runtime state link {state_path / 'r' / generation / vendor / relative} "
                                f"has ambiguous ownership: it points to {target}, not {expected}; "
                                "remove or recover the wrong link, then retry"
                            )
                        continue
                    if _validate_materialized(
                        runtime_fd,
                        relative,
                        kind,
                        state_path / "r" / generation / vendor / relative,
                    ):
                        materialized.append((relative, kind))
                views.append(
                    RuntimeView(
                        state_path / "r" / generation / vendor,
                        generation,
                        runtime_fd,
                        materialized,
                    )
                )
                runtime_fd = -1
            finally:
                if runtime_fd >= 0:
                    os.close(runtime_fd)
                os.close(generation_fd)
    except BaseException:
        for view in views:
            os.close(view.descriptor)
        raise
    finally:
        os.close(runtime_parent_fd)
    return views


def _path_within(path: str, root: Path) -> bool:
    deleted_suffix = " (deleted)"
    if path.endswith(deleted_suffix):
        path = path[: -len(deleted_suffix)]
    try:
        return os.path.commonpath((path, os.fspath(root))) == os.fspath(root)
    except ValueError:
        return False


def _process_exists(process: Path) -> bool:
    return process.exists()


def _proc_processes(proc: Path) -> list[Path]:
    return list(proc.iterdir())


def _selected_runtime(
    environment: list[bytes], runtime_paths: list[Path], canonical: Path, owner: Path
) -> tuple[str, Path] | None:
    roots = [*runtime_paths, canonical, owner]
    resolved_roots = [Path(os.path.realpath(root)) for root in roots]
    for selector in ("IHAR_RUNTIME", "CODEX_HOME", "CLAUDE_CONFIG_DIR"):
        prefix = os.fsencode(selector + "=")
        for item in environment:
            if not item.startswith(prefix):
                continue
            selected = Path(os.path.realpath(os.fsdecode(item[len(prefix) :])))
            if any(
                selected == root or _path_within(os.fspath(selected), root)
                for root in resolved_roots
            ):
                return selector, selected
    return None


def _process_candidate_evidence(
    process: Path, vendor: str, protected_roots: tuple[Path, ...]
) -> list[str]:
    names = _IHAR_PROCESS_NAMES | _VENDOR_PROCESS_NAMES.get(vendor, frozenset())
    evidence: list[str] = []

    try:
        executable = os.readlink(process / "exe")
    except OSError:
        executable = None
    if executable is not None:
        executable_path = executable.removesuffix(" (deleted)")
        executable_name = Path(executable_path).name
        if executable_name in names:
            evidence.append(f"candidate executable {executable_name!r}")
        if os.path.isabs(executable_path):
            resolved = os.path.realpath(executable_path)
            if any(_path_within(resolved, root) for root in protected_roots):
                evidence.append(f"candidate executable root reference {resolved!r}")

    try:
        command_line = (process / "cmdline").read_bytes()
    except OSError:
        command_line = b""
    if command_line and command_line.endswith(b"\0"):
        for raw_argument in command_line.split(b"\0")[:-1]:
            argument = os.fsdecode(raw_argument)
            argument_path = argument.removesuffix(" (deleted)")
            argument_name = Path(argument_path).name
            if argument_name in names:
                evidence.append(f"candidate command line {argument_name!r}")
            path_values = [argument_path]
            if (
                not argument_path.startswith("unix://")
                and not os.path.isabs(argument_path)
                and "=" in argument_path
            ):
                path_values.append(argument_path.split("=", 1)[1])
            for path_value in path_values:
                if path_value.startswith("unix://"):
                    path_value = path_value[len("unix://") :]
                if not os.path.isabs(path_value):
                    continue
                resolved = os.path.realpath(path_value)
                if any(_path_within(resolved, root) for root in protected_roots):
                    evidence.append(f"candidate command-line root reference {resolved!r}")

    return list(dict.fromkeys(evidence))


def _require_quiescent(runtime_paths: list[Path], canonical: Path, owner: Path) -> None:
    proc = Path("/proc")
    if not proc.is_dir():
        raise UpgradeError("cannot prove runtime-state quiescence: /proc is unavailable")
    ignored = {os.getpid()}
    current_uid = os.getuid()
    protected_roots = tuple(dict.fromkeys((*runtime_paths, canonical, owner)))
    vendor = owner.name
    uncertainties: list[str] = []
    for process in _proc_processes(proc):
        if not process.name.isdigit() or int(process.name) in ignored:
            continue
        pid = int(process.name)
        try:
            uid = process.stat(follow_symlinks=False).st_uid
        except FileNotFoundError:
            continue
        except OSError as error:
            if not _process_exists(process):
                continue
            uncertainties.append(f"process {pid} identity: {error}")
            continue
        if uid != current_uid:
            continue
        candidate_evidence = _process_candidate_evidence(process, vendor, protected_roots)
        process_uncertainties: list[str] = []
        try:
            environment_bytes = (process / "environ").read_bytes()
        except OSError as error:
            if not _process_exists(process):
                continue
            process_uncertainties.append(f"environment: {error}")
            environment_bytes = None
        if environment_bytes is not None:
            environment = environment_bytes.split(b"\0")
            selected = _selected_runtime(environment, runtime_paths, canonical, owner)
            if selected is not None:
                selector, active_runtime = selected
                raise UpgradeError(
                    f"runtime state is active in process {pid}: {selector}={active_runtime}"
                )
            if not environment_bytes or not environment_bytes.endswith(b"\0"):
                process_uncertainties.append("environment is incomplete")

        try:
            cwd = os.readlink(process / "cwd")
        except OSError as error:
            if _process_exists(process):
                process_uncertainties.append(f"cwd: {error}")
        else:
            if any(_path_within(cwd, root) for root in protected_roots):
                raise UpgradeError(f"runtime-state cwd consumer is active in process {pid}: {cwd}")

        try:
            file_descriptors = list((process / "fd").iterdir())
        except OSError as error:
            if _process_exists(process):
                process_uncertainties.append(f"file descriptors: {error}")
            file_descriptors = []
        for link in file_descriptors:
            try:
                target = os.readlink(link)
            except FileNotFoundError:
                continue
            except OSError as error:
                if not _process_exists(process):
                    continue
                process_uncertainties.append(f"open file {link.name}: {error}")
                continue
            if any(_path_within(target, root) for root in protected_roots):
                raise UpgradeError(
                    f"runtime-state open file consumer is active in process {pid}: {target}"
                )
        if candidate_evidence and process_uncertainties and _process_exists(process):
            uncertainties.append(
                f"process {pid} {', '.join(candidate_evidence)}: "
                + "; ".join(process_uncertainties)
            )
    if uncertainties:
        raise UpgradeError(
            "cannot prove that runtime-state consumers are quiescent: " + "; ".join(uncertainties)
        )


def _exchange_directories(
    first_parent_fd: int, first_name: str, second_parent_fd: int, second_name: str
) -> None:
    libc = ctypes.CDLL(None, use_errno=True)
    renameat2 = getattr(libc, "renameat2", None)
    if renameat2 is None:
        raise OSError("atomic directory exchange is unavailable")
    renameat2.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    renameat2.restype = ctypes.c_int
    if renameat2(
        first_parent_fd,
        os.fsencode(first_name),
        second_parent_fd,
        os.fsencode(second_name),
        _RENAME_EXCHANGE,
    ) != 0:
        error_number = ctypes.get_errno()
        raise OSError(error_number, os.strerror(error_number))


def _restore_runtime_entries(
    runtime_fd: int,
    recovery_fd: int,
    moved: list[tuple[str, str]],
) -> list[str]:
    failures: list[str] = []
    for relative, _kind in reversed(moved):
        source_parent_fd = saved_parent_fd = -1
        try:
            source_parent_fd, source_name = _open_parent(
                runtime_fd, relative, f"runtime rollback {relative}", create=True
            )
            saved_parent_fd, saved_name = _open_parent(
                recovery_fd, relative, f"recovery rollback {relative}"
            )
            try:
                metadata = os.stat(source_name, dir_fd=source_parent_fd, follow_symlinks=False)
            except FileNotFoundError:
                metadata = None
            if metadata is not None:
                if not stat.S_ISLNK(metadata.st_mode):
                    raise OSError("replacement path is no longer the migration link")
                os.unlink(source_name, dir_fd=source_parent_fd)
            os.rename(
                saved_name,
                source_name,
                src_dir_fd=saved_parent_fd,
                dst_dir_fd=source_parent_fd,
            )
        except (OSError, UpgradeError) as error:
            failures.append(f"{relative}: {error}")
        finally:
            if saved_parent_fd >= 0:
                os.close(saved_parent_fd)
            if source_parent_fd >= 0:
                os.close(source_parent_fd)
    return failures


def _rollback_transaction(
    runtime_fd: int,
    recovery_fd: int,
    moved: list[tuple[str, str]],
    published: bool,
    committed: bool,
    stage_fd: int,
    st_fd: int,
    vendor: str,
) -> tuple[list[str], bool]:
    failures: list[str] = []
    if published and not committed and stage_fd >= 0:
        try:
            _exchange_directories(stage_fd, "vendor", st_fd, vendor)
            published = False
        except OSError as error:
            failures.append(f"canonical state rollback: {error}")
            # Runtime links still address the published canonical tree. Keep
            # originals in recovery until canonical publication can be repaired.
            return failures, published
    if moved and recovery_fd >= 0:
        failures.extend(_restore_runtime_entries(runtime_fd, recovery_fd, moved))
        if not failures:
            moved.clear()
    return failures, published


def upgrade(
    manifest: str | os.PathLike[str],
    state: str | os.PathLike[str],
    vendor: str,
) -> Path | None:
    """Migrate one unambiguous materialized runtime owner into canonical state.

    Caller holds the required project-state lock for the full operation.
    """
    manifest_path = Path(manifest)
    state_path = Path(state).absolute()
    try:
        entries = _expanded_entries(manifest_path, vendor)
    except (OSError, jsonio.SchemaError) as error:
        raise UpgradeError(f"cannot validate persistent-state manifest {manifest_path}: {error}") from error

    state_fd = _open_absolute_directory(state_path, "state root")
    views: list[RuntimeView] = []
    owners: list[RuntimeView] = []
    st_fd = canonical_fd = stage_fd = recovery_fd = -1
    stage_name: str | None = None
    recovery_path: Path | None = None
    published = False
    committed = False
    rollback_incomplete = False
    moved: list[tuple[str, str]] = []
    try:
        views = _runtime_views(state_path, state_fd, vendor, entries)
        owners = [view for view in views if view.materialized]
        if not owners:
            return None
        if len(owners) != 1:
            names = ", ".join(str(view.path) for view in owners)
            raise UpgradeError(f"materialized {vendor} runtime state has ambiguous owners: {names}")
        owner = owners[0]
        canonical_path = state_path / "st" / vendor
        runtime_paths = [view.path for view in views]
        _require_quiescent(runtime_paths, canonical_path, owner.path)
        st_fd = _open_directory_at(state_fd, "st", "canonical state root")
        canonical_fd = _open_directory_at(st_fd, vendor, f"canonical {vendor} state")

        for relative, _kind in owner.materialized:
            if _entry_metadata(canonical_fd, relative, f"canonical conflict {relative}") is None:
                continue
            raise UpgradeError(
                f"canonical state conflict at {canonical_path / relative}; materialized source "
                f"{owner.path / relative} was preserved; move it to a recovery location or "
                "resolve the canonical conflict, then retry"
            )

        relative_entries = [relative for relative, _kind in owner.materialized]
        source_before = _fingerprint_entries(owner.descriptor, relative_entries)
        stage_name = _mkdir_unique(st_fd, ".runtime-upgrade-")
        stage_fd = _open_directory_at(st_fd, stage_name, "runtime-state migration stage")
        os.mkdir("vendor", mode=0o700, dir_fd=stage_fd)
        staged_vendor_fd = _open_directory_at(stage_fd, "vendor", "staged vendor state")
        try:
            _copy_directory_contents(canonical_fd, staged_vendor_fd)
            for relative, _kind in owner.materialized:
                _copy_entry(owner.descriptor, staged_vendor_fd, relative)
            source_after_copy = _fingerprint_entries(owner.descriptor, relative_entries)
            staged = _fingerprint_entries(staged_vendor_fd, relative_entries)
            if source_before != source_after_copy or source_after_copy != staged:
                raise UpgradeError(
                    f"materialized runtime state {owner.path} changed during migration; staged copy discarded"
                )
            _require_quiescent(runtime_paths, canonical_path, owner.path)
            source_before_publish = _fingerprint_entries(owner.descriptor, relative_entries)
            if source_before_publish != source_after_copy:
                raise UpgradeError(
                    f"materialized runtime state {owner.path} changed during migration; staged copy discarded"
                )
        finally:
            os.close(staged_vendor_fd)

        try:
            _exchange_directories(stage_fd, "vendor", st_fd, vendor)
            published = True
        except OSError as error:
            raise UpgradeError(f"cannot publish migrated runtime state at {canonical_path}: {error}") from error

        os.close(canonical_fd)
        canonical_fd = -1
        canonical_fd = _open_directory_at(st_fd, vendor, f"published canonical {vendor} state")
        published_copy = _fingerprint_entries(canonical_fd, relative_entries)
        source_after_publish = _fingerprint_entries(owner.descriptor, relative_entries)
        if published_copy != staged or source_after_publish != source_before_publish:
            raise UpgradeError(
                f"materialized runtime state {owner.path} changed during migration; publication rolled back"
            )

        recovery_parent_fd = _open_or_create_chain(
            state_fd, ("recovery", "runtime-state", vendor), "runtime-state recovery"
        )
        try:
            recovery_name = _mkdir_unique(recovery_parent_fd, f"{owner.generation}-")
            recovery_path = state_path / "recovery" / "runtime-state" / vendor / recovery_name
            recovery_fd = _open_directory_at(
                recovery_parent_fd, recovery_name, "runtime-state recovery directory"
            )
        finally:
            os.close(recovery_parent_fd)

        for relative, kind in owner.materialized:
            source_parent_fd, source_name = _open_parent(
                owner.descriptor, relative, f"runtime source {relative}"
            )
            saved_parent_fd, saved_name = _open_parent(
                recovery_fd, relative, f"recovery target {relative}", create=True
            )
            try:
                os.rename(
                    source_name,
                    saved_name,
                    src_dir_fd=source_parent_fd,
                    dst_dir_fd=saved_parent_fd,
                )
                moved.append((relative, kind))
                os.symlink(
                    os.fspath(canonical_path / relative),
                    source_name,
                    dir_fd=source_parent_fd,
                )
            finally:
                os.close(saved_parent_fd)
                os.close(source_parent_fd)

        recovered = _fingerprint_entries(recovery_fd, relative_entries)
        if recovered != source_before_publish:
            raise UpgradeError(
                f"materialized runtime state {owner.path} changed during relink; publication rolled back"
            )

        os.rename(
            "vendor",
            ".canonical-before",
            src_dir_fd=stage_fd,
            dst_dir_fd=recovery_fd,
        )
        committed = True
        try:
            os.rmdir(stage_name, dir_fd=st_fd)
            stage_name = None
        except OSError:
            pass
        return recovery_path
    except UpgradeError:
        rollback_failures, published = _rollback_transaction(
            owners[0].descriptor if owners else -1,
            recovery_fd,
            moved,
            published,
            committed,
            stage_fd,
            st_fd,
            vendor,
        )
        if rollback_failures:
            rollback_incomplete = True
            location = recovery_path or (state_path / "st" / (stage_name or ""))
            raise UpgradeError(
                "runtime state rollback is incomplete; preserved recovery at "
                f"{location}: {'; '.join(rollback_failures)}"
            )
        raise
    except OSError as error:
        rollback_failures, published = _rollback_transaction(
            owners[0].descriptor if owners else -1,
            recovery_fd,
            moved,
            published,
            committed,
            stage_fd,
            st_fd,
            vendor,
        )
        if rollback_failures:
            rollback_incomplete = True
            location = recovery_path or (state_path / "st" / (stage_name or ""))
            raise UpgradeError(
                "runtime state rollback is incomplete; preserved recovery at "
                f"{location}: {'; '.join(rollback_failures)}"
            ) from error
        raise UpgradeError(
            f"cannot replace materialized runtime state with canonical links: {error}"
        ) from error
    finally:
        if stage_name is not None and not published and stage_fd >= 0:
            try:
                _remove_tree_at(st_fd, stage_name)
                stage_name = None
            except (OSError, UpgradeError):
                pass
        if (
            recovery_path is not None
            and not committed
            and not rollback_incomplete
            and not moved
            and recovery_fd >= 0
        ):
            try:
                recovery_parent_fd = _open_or_create_chain(
                    state_fd, ("recovery", "runtime-state", vendor), "runtime-state recovery"
                )
                try:
                    _remove_tree_at(recovery_parent_fd, recovery_path.name)
                finally:
                    os.close(recovery_parent_fd)
            except (OSError, UpgradeError):
                pass
        for descriptor in (recovery_fd, stage_fd, canonical_fd, st_fd):
            if descriptor >= 0:
                os.close(descriptor)
        for view in views:
            os.close(view.descriptor)
        os.close(state_fd)


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        return 2
    try:
        upgrade(argv[0], argv[1], argv[2])
    except (OSError, UpgradeError) as error:
        print(f"ihar: runtime state upgrade failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
