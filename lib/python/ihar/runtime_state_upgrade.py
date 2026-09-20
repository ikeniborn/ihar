"""Transactional migration of persistent state materialized in old runtime homes."""

from __future__ import annotations

import os
import shutil
import stat
import sys
import tempfile
from pathlib import Path

from ihar import jsonio
from ihar.inventory import state_entries
from ihar.migration_fingerprint import fingerprint


class UpgradeError(RuntimeError):
    """A runtime-state upgrade could not prove a lossless transaction."""


def _expanded_entries(manifest: Path, vendor: str) -> list[tuple[str, str]]:
    expanded: list[tuple[str, str]] = []
    for path, kind in state_entries(manifest, vendor):
        if kind == "sqlite-family":
            expanded.extend((path + suffix, "file") for suffix in ("", "-wal", "-shm"))
        else:
            expanded.append((path, kind))
    return expanded


def _validate_real_tree(path: Path, kind: str) -> None:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise UpgradeError(f"cannot inspect materialized runtime state {path}: {error}") from error
    if kind == "file":
        if not stat.S_ISREG(metadata.st_mode):
            raise UpgradeError(f"materialized runtime state {path} has unexpected type")
        return
    if not stat.S_ISDIR(metadata.st_mode):
        raise UpgradeError(f"materialized runtime state {path} has unexpected type")
    for root, directories, files in os.walk(path, followlinks=False):
        root_path = Path(root)
        for name in (*directories, *files):
            child = root_path / name
            child_mode = child.lstat().st_mode
            if not (stat.S_ISDIR(child_mode) or stat.S_ISREG(child_mode)):
                raise UpgradeError(
                    f"materialized runtime state {path} contains unsupported entry {child}"
                )


def _copy_entry(source: Path, target: Path) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    if source.is_dir():
        shutil.copytree(source, target, copy_function=shutil.copy2)
    else:
        shutil.copy2(source, target)


def _active_runtime_pid(runtime: Path) -> int | None:
    expected = os.fsencode(f"IHAR_RUNTIME={runtime}")
    proc = Path("/proc")
    if not proc.is_dir():
        return None
    # The helper and its invoking ihar shell inherit IHAR_RUNTIME during reuse;
    # neither is a vendor writer. Exclude that ancestry, but retain independently
    # running vendor/wrapper processes as quiescence blockers.
    ignored = {os.getpid()}
    parent = os.getppid()
    while parent > 1 and parent not in ignored:
        ignored.add(parent)
        try:
            status = (proc / str(parent) / "status").read_text(encoding="utf-8")
            parent = int(next(line.split()[1] for line in status.splitlines() if line.startswith("PPid:")))
        except (OSError, StopIteration, ValueError):
            break
    for process in proc.iterdir():
        if not process.name.isdigit():
            continue
        if int(process.name) in ignored:
            continue
        try:
            environment = (process / "environ").read_bytes().split(b"\0")
        except OSError:
            continue
        if expected in environment:
            return int(process.name)
    return None


def _runtime_owners(
    state: Path, vendor: str, entries: list[tuple[str, str]]
) -> dict[Path, list[tuple[str, str]]]:
    owners: dict[Path, list[tuple[str, str]]] = {}
    runtime_parent = state / "r"
    if not runtime_parent.is_dir():
        return owners
    canonical = state / "st" / vendor
    for generation in sorted(runtime_parent.iterdir()):
        if generation.name.startswith(".") or not generation.is_dir():
            continue
        runtime = generation / vendor
        if not runtime.is_dir():
            continue
        materialized: list[tuple[str, str]] = []
        for relative, kind in entries:
            target = runtime / relative
            if target.is_symlink():
                expected = str(canonical / relative)
                if os.readlink(target) != expected:
                    raise UpgradeError(
                        f"runtime state link {target} has ambiguous ownership: "
                        f"it points to {os.readlink(target)}, not {expected}; "
                        "remove or recover the wrong link, then retry"
                    )
                continue
            if not target.exists():
                continue
            _validate_real_tree(target, kind)
            materialized.append((relative, kind))
        if materialized:
            owners[runtime] = materialized
    return owners


def _restore_runtime_entries(
    runtime: Path, recovery: Path, moved: list[tuple[str, str]]
) -> list[str]:
    failures: list[str] = []
    for relative, _kind in reversed(moved):
        source = runtime / relative
        saved = recovery / relative
        try:
            if source.is_symlink():
                source.unlink()
            elif source.exists():
                raise OSError("replacement path is no longer the migration link")
            source.parent.mkdir(parents=True, exist_ok=True)
            os.replace(saved, source)
        except OSError as error:
            failures.append(f"{source}: {error}")
    return failures


def upgrade(
    manifest: str | os.PathLike[str],
    state: str | os.PathLike[str],
    vendor: str,
) -> Path | None:
    """Migrate one unambiguous materialized runtime owner into canonical state.

    Caller holds the required project-state lock for the full operation.
    """
    manifest_path = Path(manifest)
    state_path = Path(state)
    try:
        entries = _expanded_entries(manifest_path, vendor)
    except (OSError, jsonio.SchemaError) as error:
        raise UpgradeError(f"cannot validate persistent-state manifest {manifest_path}: {error}") from error
    owners = _runtime_owners(state_path, vendor, entries)
    if not owners:
        return None
    if len(owners) != 1:
        names = ", ".join(str(path) for path in owners)
        raise UpgradeError(f"materialized {vendor} runtime state has ambiguous owners: {names}")

    runtime, materialized = next(iter(owners.items()))
    active_pid = _active_runtime_pid(runtime)
    if active_pid is not None:
        raise UpgradeError(
            f"materialized {vendor} runtime state is active in process {active_pid}: {runtime}"
        )

    canonical = state_path / "st" / vendor
    canonical.mkdir(parents=True, exist_ok=True)
    for relative, _kind in materialized:
        target = canonical / relative
        if target.exists() or target.is_symlink():
            raise UpgradeError(
                f"canonical state conflict at {target}; materialized source "
                f"{runtime / relative} was preserved; move it to a recovery "
                "location or resolve the canonical conflict, then retry"
            )

    relative_entries = [relative for relative, _kind in materialized]
    try:
        source_before = fingerprint(runtime, relative_entries)
    except OSError as error:
        raise UpgradeError(f"cannot fingerprint materialized runtime state {runtime}: {error}") from error

    stage = Path(tempfile.mkdtemp(prefix=".runtime-upgrade-", dir=state_path / "st"))
    staged_vendor = stage / "vendor"
    canonical_backup = stage / "canonical-before"
    published_copy = stage / "published-copy"
    recovery: Path | None = None
    moved: list[tuple[str, str]] = []
    published = False
    cleanup_stage = True
    try:
        shutil.copytree(
            canonical, staged_vendor, symlinks=True, copy_function=shutil.copy2
        )
        for relative, _kind in materialized:
            _copy_entry(runtime / relative, staged_vendor / relative)

        source_after = fingerprint(runtime, relative_entries)
        staged = fingerprint(staged_vendor, relative_entries)
        if source_before != source_after or source_after != staged:
            raise UpgradeError(
                f"materialized runtime state {runtime} changed during migration; staged copy discarded"
            )

        os.replace(canonical, canonical_backup)
        try:
            os.replace(staged_vendor, canonical)
            published = True
        except OSError as publish_error:
            try:
                os.replace(canonical_backup, canonical)
            except OSError as rollback_error:
                cleanup_stage = False
                raise UpgradeError(
                    "runtime state publication rollback is incomplete; preserved "
                    f"recovery stage at {stage}: {rollback_error}"
                ) from publish_error
            raise UpgradeError(
                f"cannot publish migrated runtime state at {canonical}: {publish_error}"
            ) from publish_error

        recovery_parent = state_path / "recovery" / "runtime-state" / vendor
        recovery_parent.mkdir(parents=True, mode=0o700, exist_ok=True)
        recovery = Path(tempfile.mkdtemp(prefix=f"{runtime.parent.name}-", dir=recovery_parent))
        for relative, kind in materialized:
            source = runtime / relative
            saved = recovery / relative
            saved.parent.mkdir(parents=True, exist_ok=True)
            os.replace(source, saved)
            moved.append((relative, kind))
            source.parent.mkdir(parents=True, exist_ok=True)
            os.symlink(canonical / relative, source)

        os.replace(canonical_backup, recovery / ".canonical-before")
        shutil.rmtree(stage, ignore_errors=True)
        return recovery
    except UpgradeError:
        rollback_failures = _restore_runtime_entries(runtime, recovery, moved) if recovery else []
        if published:
            try:
                os.replace(canonical, published_copy)
                os.replace(canonical_backup, canonical)
                published = False
            except OSError as error:
                rollback_failures.append(f"canonical state rollback: {error}")
        if recovery and recovery.exists() and not rollback_failures:
            shutil.rmtree(recovery)
        if rollback_failures:
            cleanup_stage = False
            location = recovery if recovery else stage
            raise UpgradeError(
                "runtime state rollback is incomplete; preserved recovery at "
                f"{location}: {'; '.join(rollback_failures)}"
            )
        raise
    except OSError as error:
        rollback_failures = _restore_runtime_entries(runtime, recovery, moved) if recovery else []
        if published:
            try:
                os.replace(canonical, published_copy)
                os.replace(canonical_backup, canonical)
                published = False
            except OSError as rollback_error:
                rollback_failures.append(f"canonical state rollback: {rollback_error}")
        if recovery and recovery.exists() and not rollback_failures:
            shutil.rmtree(recovery)
        if rollback_failures:
            cleanup_stage = False
            location = recovery if recovery else stage
            raise UpgradeError(
                "runtime state rollback is incomplete; preserved recovery at "
                f"{location}: {'; '.join(rollback_failures)}"
            ) from error
        raise UpgradeError(f"cannot replace materialized runtime state with canonical links: {error}") from error
    finally:
        if stage.exists() and cleanup_stage:
            shutil.rmtree(stage, ignore_errors=True)


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
