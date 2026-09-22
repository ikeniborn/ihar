"""Protected, one-use Codex login staging and credential publication.

The caller must hold the exclusive Codex auth-owner lease and prove vendor
quiescence before calling ``publish``. This module does not launch a vendor.
"""

from __future__ import annotations

import hashlib
import json
import os
import secrets
import stat
from contextlib import ExitStack
from pathlib import Path


class AuthOwnerError(RuntimeError):
    """Credential ownership or publication could not be proved; fail closed."""


class ApprovalRequired(AuthOwnerError):
    """Replacing an existing credential needs direct human approval."""


_DIR_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
_FILE_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC
_CREATE_FLAGS = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC
_MARKER = ".ihar-stage"
_PENDING = ".auth-publish-pending"
_COMPLETE = ".auth-publish-complete"


def _open_store(store: Path, stack: ExitStack) -> int:
    path = Path(os.path.abspath(store))
    descriptor = os.open(os.path.sep, _DIR_FLAGS)
    stack.callback(os.close, descriptor)
    for part in path.parts[1:]:
        child = os.open(part, _DIR_FLAGS, dir_fd=descriptor)
        stack.callback(os.close, child)
        descriptor = child
    metadata = os.fstat(descriptor)
    if metadata.st_uid != os.geteuid():
        raise AuthOwnerError("Codex credential store must belong to current user")
    return descriptor


def _private_directory(parent: int, name: str, stack: ExitStack, *, create: bool) -> int:
    made = False
    if create:
        try:
            os.mkdir(name, mode=0o700, dir_fd=parent)
            made = True
        except FileExistsError:
            pass
    descriptor = os.open(name, _DIR_FLAGS, dir_fd=parent)
    stack.callback(os.close, descriptor)
    if made:
        os.fchmod(descriptor, 0o700)
        os.fsync(parent)
    metadata = os.fstat(descriptor)
    if metadata.st_uid != os.geteuid() or stat.S_IMODE(metadata.st_mode) != 0o700:
        raise AuthOwnerError("Codex credential owner directory must be mode 0700")
    return descriptor


def _owner_directories(store: Path, stack: ExitStack, *, create: bool) -> tuple[int, int, int]:
    root = _open_store(store, stack)
    auth = _private_directory(root, "auth", stack, create=create)
    owner = _private_directory(auth, "codex", stack, create=create)
    return root, auth, owner


def _identity(descriptor: int) -> dict[str, int | str]:
    before = os.fstat(descriptor)
    if not stat.S_ISREG(before.st_mode) or before.st_uid != os.geteuid() or before.st_nlink != 1:
        raise AuthOwnerError("Codex credential must be an owned regular file")
    digest = hashlib.sha256()
    os.lseek(descriptor, 0, os.SEEK_SET)
    while chunk := os.read(descriptor, 65536):
        digest.update(chunk)
    after = os.fstat(descriptor)
    fields = ("st_dev", "st_ino", "st_size", "st_mtime_ns", "st_ctime_ns")
    if any(getattr(before, field) != getattr(after, field) for field in fields):
        raise AuthOwnerError("Codex credential changed while being checked")
    return {
        "dev": after.st_dev,
        "ino": after.st_ino,
        "size": after.st_size,
        "mtime_ns": after.st_mtime_ns,
        "ctime_ns": after.st_ctime_ns,
        "sha256": digest.hexdigest(),
    }


def _canonical_identity(owner: int) -> dict[str, int | str] | None:
    try:
        descriptor = os.open("auth.json", _FILE_FLAGS, dir_fd=owner)
    except FileNotFoundError:
        return None
    with os.fdopen(descriptor, "rb", closefd=True) as handle:
        result = _identity(handle.fileno())
        metadata = os.stat("auth.json", dir_fd=owner, follow_symlinks=False)
        if (metadata.st_dev, metadata.st_ino) != (result["dev"], result["ino"]):
            raise AuthOwnerError("Codex credential owner changed during inspection")
        return result


def _copy_file(source: int, target: int) -> None:
    os.lseek(source, 0, os.SEEK_SET)
    while chunk := os.read(source, 65536):
        _write_all(target, chunk)
    os.fsync(target)


def _write_all(descriptor: int, content: bytes) -> None:
    view = memoryview(content)
    while view:
        view = view[os.write(descriptor, view):]


def _write_marker(stage_fd: int, record: dict) -> None:
    descriptor = os.open(_MARKER, _CREATE_FLAGS, 0o600, dir_fd=stage_fd)
    try:
        payload = json.dumps(record, sort_keys=True).encode("ascii")
        _write_all(descriptor, payload)
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    os.fsync(stage_fd)


def _guard_no_pending(owner: int) -> None:
    for name in (_PENDING, _COMPLETE):
        try:
            os.stat(name, dir_fd=owner, follow_symlinks=False)
        except FileNotFoundError:
            continue
        raise AuthOwnerError("Codex auth publication needs manual recovery")


def _write_pending(owner: int, token: str) -> None:
    descriptor = os.open(_PENDING, _CREATE_FLAGS, 0o600, dir_fd=owner)
    try:
        _write_all(descriptor, token.encode("ascii"))
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    os.fsync(owner)


def _read_marker(stage_fd: int) -> dict:
    descriptor = os.open(_MARKER, _FILE_FLAGS, dir_fd=stage_fd)
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.geteuid():
            raise AuthOwnerError("Codex auth stage marker is not an owned regular file")
        if metadata.st_size > 4096 or stat.S_IMODE(metadata.st_mode) != 0o600:
            raise AuthOwnerError("Codex auth stage marker is invalid")
        record = json.loads(os.read(descriptor, 4097))
        if not isinstance(record, dict):
            raise ValueError("invalid marker")
        return record
    finally:
        os.close(descriptor)


def stage(store: str | os.PathLike[str]) -> Path:
    """Create a private real-file CODEX_HOME for one human login attempt.

    Raises AuthOwnerError without returning a staging path on unsafe topology.
    """
    store_path = Path(os.path.abspath(store))
    try:
        with ExitStack() as stack:
            root, _auth, owner = _owner_directories(store_path, stack, create=True)
            _guard_no_pending(owner)
            stages = _private_directory(owner, "staging", stack, create=True)
            baseline = _canonical_identity(owner)
            token = secrets.token_hex(16)
            stage_fd = _private_directory(stages, token, stack, create=True)
            record = {
                "schema": 1,
                "token": token,
                "store": [os.fstat(root).st_dev, os.fstat(root).st_ino],
                "stage": [os.fstat(stage_fd).st_dev, os.fstat(stage_fd).st_ino],
                "baseline": baseline,
            }
            _write_marker(stage_fd, record)
            os.fsync(stages)
            return store_path / "auth" / "codex" / "staging" / token
    except (OSError, ValueError, json.JSONDecodeError) as error:
        raise AuthOwnerError("Codex auth staging topology or durability check failed") from error


def _validated_stage(
    stage_path: Path, store_path: Path, root: int, owner: int, stack: ExitStack
) -> tuple[int, str, dict]:
    expected_parent = store_path / "auth" / "codex" / "staging"
    token = stage_path.name
    if (
        stage_path.parent != expected_parent
        or len(token) != 32
        or any(c not in "0123456789abcdef" for c in token)
    ):
        raise AuthOwnerError("Codex auth stage does not belong to this owner")
    stages = _private_directory(owner, "staging", stack, create=False)
    stage_fd = _private_directory(stages, token, stack, create=False)
    record = _read_marker(stage_fd)
    if (
        record.get("schema") != 1
        or record.get("token") != token
        or record.get("store") != [os.fstat(root).st_dev, os.fstat(root).st_ino]
        or record.get("stage") != [os.fstat(stage_fd).st_dev, os.fstat(stage_fd).st_ino]
        or "baseline" not in record
    ):
        raise AuthOwnerError("Codex auth stage provenance is invalid")
    return stage_fd, token, record


def _same_published_file(owner: int, published: os.stat_result) -> bool:
    try:
        current = os.stat("auth.json", dir_fd=owner, follow_symlinks=False)
    except FileNotFoundError:
        return False
    return (current.st_dev, current.st_ino) == (published.st_dev, published.st_ino)


def _rollback(
    owner: int,
    recovery: int | None,
    token: str,
    published: os.stat_result,
    baseline: dict[str, int | str] | None,
) -> None:
    if not _same_published_file(owner, published):
        raise AuthOwnerError("Codex auth owner changed; manual recovery required")
    if recovery is None:
        os.unlink("auth.json", dir_fd=owner)
    else:
        rollback_name = f".auth-rollback-{token}"
        source = os.open("auth.json", _FILE_FLAGS, dir_fd=recovery)
        try:
            source_identity = _identity(source)
            if baseline is None or any(
                source_identity[field] != baseline[field] for field in ("size", "sha256")
            ):
                raise AuthOwnerError("Codex auth recovery copy changed")
            target = os.open(rollback_name, _CREATE_FLAGS, 0o600, dir_fd=owner)
            try:
                _copy_file(source, target)
            finally:
                os.close(target)
            if _identity(source) != source_identity:
                raise AuthOwnerError("Codex auth recovery copy changed during rollback")
        finally:
            os.close(source)
        os.replace(rollback_name, "auth.json", src_dir_fd=owner, dst_dir_fd=owner)
    os.fsync(owner)


def publish(
    stage_path: str | os.PathLike[str], store: str | os.PathLike[str], *, approve_existing: bool
) -> None:
    """Publish a quiescent staged credential, retaining prior bytes for recovery.

    Existing credentials need ``approve_existing is True``. A missing staged
    file never means logout. A failed commit restores the prior owner when it
    can prove the exact published inode; otherwise the pending marker blocks
    reuse for manual recovery. The caller owns the exclusive writer lease.
    """
    store_path = Path(os.path.abspath(store))
    supplied_stage = Path(os.path.abspath(stage_path))
    try:
        with ExitStack() as stack:
            root, _auth, owner = _owner_directories(store_path, stack, create=False)
            _guard_no_pending(owner)
            stage_fd, token, record = _validated_stage(
                supplied_stage, store_path, root, owner, stack
            )
            baseline = record["baseline"]
            if baseline != _canonical_identity(owner):
                raise AuthOwnerError("Codex credential owner changed since staging")
            if baseline is not None and approve_existing is not True:
                raise ApprovalRequired("existing Codex credential requires direct user approval")
            candidate_fd = os.open("auth.json", _FILE_FLAGS, dir_fd=stage_fd)
            stack.callback(os.close, candidate_fd)
            candidate_before = _identity(candidate_fd)
            candidate_stat = os.stat("auth.json", dir_fd=stage_fd, follow_symlinks=False)
            if not stat.S_ISREG(candidate_stat.st_mode) or stat.S_ISLNK(candidate_stat.st_mode):
                raise AuthOwnerError("staged Codex credential is not a regular file")
            if (candidate_stat.st_dev, candidate_stat.st_ino) != (
                candidate_before["dev"], candidate_before["ino"]
            ):
                raise AuthOwnerError("staged Codex credential changed during inspection")
            os.fsync(candidate_fd)
            os.fsync(stage_fd)
            if _identity(candidate_fd) != candidate_before:
                raise AuthOwnerError("staged Codex credential changed during sync")

            recovery_fd = None
            if baseline is not None:
                recovery_root = _private_directory(owner, "recovery", stack, create=True)
                recovery_fd = _private_directory(recovery_root, token, stack, create=True)
                old_fd = os.open("auth.json", _FILE_FLAGS, dir_fd=owner)
                stack.callback(os.close, old_fd)
                if _identity(old_fd) != baseline:
                    raise AuthOwnerError("Codex credential owner changed before recovery")
                backup_fd = os.open("auth.json", _CREATE_FLAGS, 0o600, dir_fd=recovery_fd)
                stack.callback(os.close, backup_fd)
                _copy_file(old_fd, backup_fd)
                if _identity(old_fd) != baseline:
                    raise AuthOwnerError("Codex credential owner changed during recovery")
                os.fsync(recovery_fd)
                os.fsync(recovery_root)

            temporary = f".auth-publish-{token}"
            published_fd = os.open(temporary, _CREATE_FLAGS, 0o600, dir_fd=owner)
            stack.callback(os.close, published_fd)
            _copy_file(candidate_fd, published_fd)
            published = os.fstat(published_fd)
            if _identity(candidate_fd) != candidate_before:
                raise AuthOwnerError("staged Codex credential changed during publication")
            if baseline != _canonical_identity(owner):
                raise AuthOwnerError("Codex credential owner changed before publication")

            _write_pending(owner, token)
            os.replace(_MARKER, ".ihar-used", src_dir_fd=stage_fd, dst_dir_fd=stage_fd)
            os.fsync(stage_fd)
            committed = False
            try:
                if baseline is None:
                    os.link(
                        temporary, "auth.json",
                        src_dir_fd=owner, dst_dir_fd=owner, follow_symlinks=False,
                    )
                else:
                    os.replace(temporary, "auth.json", src_dir_fd=owner, dst_dir_fd=owner)
                committed = True
                if baseline is None:
                    os.unlink(temporary, dir_fd=owner)
                os.fsync(owner)
            except OSError as error:
                if committed:
                    try:
                        _rollback(owner, recovery_fd, token, published, baseline)
                    except (OSError, AuthOwnerError) as rollback_error:
                        raise AuthOwnerError(
                            "Codex auth publication and rollback failed; recovery retained"
                        ) from rollback_error
                raise AuthOwnerError(
                    "Codex auth publication failed; staged and recovery bytes retained"
                ) from error
            try:
                os.replace(_PENDING, _COMPLETE, src_dir_fd=owner, dst_dir_fd=owner)
                os.fsync(owner)
                # A crash after this unlink may resurrect the marker, which
                # fails closed. Canonical publication is already durable.
                os.unlink(_COMPLETE, dir_fd=owner)
            except OSError as error:
                raise AuthOwnerError(
                    "Codex credential published; transaction cleanup needs manual review"
                ) from error
    except (OSError, ValueError, json.JSONDecodeError) as error:
        raise AuthOwnerError(
            "Codex auth publication topology or durability check failed"
        ) from error
