#!/usr/bin/env python3
"""Transactional upgrade tests for pre-manifest runtime state."""

from __future__ import annotations

import json
import os
import sys
import tempfile
from pathlib import Path
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib", "python"))


def implementation():
    try:
        from ihar import runtime_state_upgrade
    except ImportError as error:
        raise AssertionError("runtime state upgrade helper is missing") from error
    return runtime_state_upgrade


def fixture(root: Path, *runtime_hashes: str) -> tuple[Path, Path, list[Path]]:
    manifest = root / "state.json"
    manifest.write_text(json.dumps({
        "schema": 1,
        "entries": [
            {"vendor": "codex", "path": "sessions", "kind": "directory"},
            {"vendor": "codex", "path": "history.jsonl", "kind": "file"},
            {"vendor": "codex", "path": "nested/history.jsonl", "kind": "file"},
            {"vendor": "codex", "path": "state.sqlite", "kind": "sqlite-family"},
        ],
    }), encoding="utf-8")
    state = root / "state"
    (state / "st" / "codex").mkdir(parents=True)
    runtimes = []
    for runtime_hash in runtime_hashes:
        runtime = state / "r" / runtime_hash / "codex"
        runtime.mkdir(parents=True)
        runtimes.append(runtime)
    return manifest, state, runtimes


def write_materialized(runtime: Path) -> None:
    (runtime / "sessions").mkdir()
    (runtime / "sessions" / "thread.jsonl").write_text("thread\n", encoding="utf-8")
    (runtime / "history.jsonl").write_text("history\n", encoding="utf-8")
    (runtime / "nested").mkdir()
    (runtime / "nested" / "history.jsonl").write_text("nested\n", encoding="utf-8")
    for suffix, content in (("", "db\n"), ("-wal", "wal\n"), ("-shm", "shm\n")):
        (runtime / f"state.sqlite{suffix}").write_text(content, encoding="utf-8")


def assert_materialized(runtime: Path) -> None:
    assert not (runtime / "sessions").is_symlink()
    assert (runtime / "sessions" / "thread.jsonl").read_text(encoding="utf-8") == "thread\n"
    assert not (runtime / "history.jsonl").is_symlink()
    assert (runtime / "history.jsonl").read_text(encoding="utf-8") == "history\n"


def test_upgrade_publishes_canonical_state_preserves_recovery_and_is_idempotent():
    module = implementation()
    with tempfile.TemporaryDirectory() as tmp:
        manifest, state, (runtime,) = fixture(Path(tmp), "11111111")
        write_materialized(runtime)

        module.upgrade(manifest, state, "codex")

        canonical = state / "st" / "codex"
        assert (canonical / "sessions" / "thread.jsonl").read_text() == "thread\n"
        assert (canonical / "history.jsonl").read_text() == "history\n"
        assert (canonical / "state.sqlite-wal").read_text() == "wal\n"
        assert runtime.joinpath("sessions").is_symlink()
        assert os.readlink(runtime / "sessions") == str(canonical / "sessions")
        recovery = list((state / "recovery" / "runtime-state" / "codex").glob("11111111-*"))
        assert len(recovery) == 1
        assert (recovery[0] / "sessions" / "thread.jsonl").read_text() == "thread\n"
        assert (recovery[0] / "history.jsonl").read_text() == "history\n"
        assert not list((state / "st").glob(".runtime-upgrade-*"))

        module.upgrade(manifest, state, "codex")
        assert list((state / "recovery" / "runtime-state" / "codex").glob("11111111-*")) == recovery
        assert (canonical / "history.jsonl").read_text() == "history\n"


def test_conflicting_canonical_state_fails_without_mutation():
    module = implementation()
    with tempfile.TemporaryDirectory() as tmp:
        manifest, state, (runtime,) = fixture(Path(tmp), "22222222")
        write_materialized(runtime)
        canonical = state / "st" / "codex"
        (canonical / "history.jsonl").write_text("canonical\n", encoding="utf-8")

        try:
            module.upgrade(manifest, state, "codex")
        except module.UpgradeError as error:
            assert "conflict" in str(error)
        else:
            raise AssertionError("conflicting canonical state was overwritten")

        assert_materialized(runtime)
        assert (canonical / "history.jsonl").read_text() == "canonical\n"
        assert not (state / "recovery").exists()


def test_two_materialized_runtime_owners_are_ambiguous():
    module = implementation()
    with tempfile.TemporaryDirectory() as tmp:
        manifest, state, runtimes = fixture(Path(tmp), "33333333", "44444444")
        (runtimes[0] / "history.jsonl").write_text("one\n", encoding="utf-8")
        (runtimes[1] / "sessions").mkdir()
        (runtimes[1] / "sessions" / "two").write_text("two\n", encoding="utf-8")

        try:
            module.upgrade(manifest, state, "codex")
        except module.UpgradeError as error:
            assert "ambiguous" in str(error)
        else:
            raise AssertionError("two runtime owners were silently merged")

        assert (runtimes[0] / "history.jsonl").read_text() == "one\n"
        assert (runtimes[1] / "sessions" / "two").read_text() == "two\n"
        assert not any((state / "st" / "codex").iterdir())


def test_source_mutation_discards_stage_and_preserves_runtime():
    module = implementation()
    with tempfile.TemporaryDirectory() as tmp:
        manifest, state, (runtime,) = fixture(Path(tmp), "55555555")
        write_materialized(runtime)
        real_copy = module._copy_entry
        mutated = False

        def copy_then_mutate(source, target):
            nonlocal mutated
            real_copy(source, target)
            if not mutated:
                mutated = True
                (runtime / "history.jsonl").write_text("changed during copy\n", encoding="utf-8")

        with mock.patch.object(module, "_copy_entry", side_effect=copy_then_mutate):
            try:
                module.upgrade(manifest, state, "codex")
            except module.UpgradeError as error:
                assert "changed during migration" in str(error)
            else:
                raise AssertionError("a changing source was published")

        assert (runtime / "history.jsonl").read_text() == "changed during copy\n"
        assert not runtime.joinpath("history.jsonl").is_symlink()
        assert not any((state / "st" / "codex").iterdir())
        assert not list((state / "st").glob(".runtime-upgrade-*"))


def test_publication_failure_restores_canonical_root_and_preserves_source():
    module = implementation()
    with tempfile.TemporaryDirectory() as tmp:
        manifest, state, (runtime,) = fixture(Path(tmp), "66666666")
        write_materialized(runtime)
        canonical = state / "st" / "codex"
        real_replace = module.os.replace

        def fail_stage_publish(source, target):
            if Path(target) == canonical and Path(source).name == "vendor":
                raise OSError("injected publication failure")
            return real_replace(source, target)

        with mock.patch.object(module.os, "replace", side_effect=fail_stage_publish):
            try:
                module.upgrade(manifest, state, "codex")
            except module.UpgradeError as error:
                assert "publish" in str(error)
            else:
                raise AssertionError("publication failure was ignored")

        assert_materialized(runtime)
        assert canonical.is_dir() and not any(canonical.iterdir())
        assert not list((state / "st").glob(".runtime-upgrade-*"))


def test_link_failure_rolls_back_publication_and_restores_original_runtime_entries():
    module = implementation()
    with tempfile.TemporaryDirectory() as tmp:
        manifest, state, (runtime,) = fixture(Path(tmp), "77777777")
        write_materialized(runtime)
        canonical = state / "st" / "codex"
        real_symlink = module.os.symlink
        link_calls = 0

        def fail_third_link(source, target, *args, **kwargs):
            nonlocal link_calls
            link_calls += 1
            if link_calls == 3:
                raise OSError("injected link failure")
            return real_symlink(source, target, *args, **kwargs)

        with mock.patch.object(module.os, "symlink", side_effect=fail_third_link):
            try:
                module.upgrade(manifest, state, "codex")
            except module.UpgradeError as error:
                assert "link" in str(error)
            else:
                raise AssertionError("link failure was ignored")

        assert_materialized(runtime)
        assert canonical.is_dir() and not any(canonical.iterdir())
        recovery_root = state / "recovery" / "runtime-state" / "codex"
        assert not recovery_root.exists() or not any(recovery_root.iterdir())


def test_failed_publication_rollback_preserves_the_recovery_stage():
    module = implementation()
    with tempfile.TemporaryDirectory() as tmp:
        manifest, state, (runtime,) = fixture(Path(tmp), "88888888")
        write_materialized(runtime)
        canonical = state / "st" / "codex"
        real_replace = module.os.replace

        def fail_publish_and_restore(source, target):
            source_path = Path(source)
            target_path = Path(target)
            if target_path == canonical and source_path.name in ("vendor", "canonical-before"):
                raise OSError("injected publish/restore failure")
            return real_replace(source, target)

        with mock.patch.object(module.os, "replace", side_effect=fail_publish_and_restore):
            try:
                module.upgrade(manifest, state, "codex")
            except module.UpgradeError as error:
                assert "rollback is incomplete" in str(error)
                assert "preserved" in str(error)
            else:
                raise AssertionError("incomplete publication rollback was hidden")

        assert_materialized(runtime)
        stages = list((state / "st").glob(".runtime-upgrade-*"))
        assert len(stages) == 1
        assert (stages[0] / "canonical-before").is_dir()


if __name__ == "__main__":
    tests = [value for name, value in sorted(globals().items()) if name.startswith("test_")]
    for test in tests:
        test()
    print(f"PASS={len(tests)} FAIL=0")
