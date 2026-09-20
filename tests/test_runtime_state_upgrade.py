#!/usr/bin/env python3
"""Transactional upgrade tests for pre-manifest runtime state."""

from __future__ import annotations

import json
import os
import subprocess
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


def run_upgrade(module, manifest: Path, state: Path, vendor: str, *pids: int):
    processes = [Path(f"/proc/{pid}") for pid in pids]
    with mock.patch.object(module, "_proc_processes", return_value=processes):
        return module.upgrade(manifest, state, vendor)


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

        run_upgrade(module, manifest, state, "codex")

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
        assert (recovery[0] / ".canonical-before").is_dir()
        assert not list((state / "st").glob(".runtime-upgrade-*"))

        run_upgrade(module, manifest, state, "codex")
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
            run_upgrade(module, manifest, state, "codex")
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
            run_upgrade(module, manifest, state, "codex")
        except module.UpgradeError as error:
            assert "ambiguous" in str(error)
        else:
            raise AssertionError("two runtime owners were silently merged")

        assert (runtimes[0] / "history.jsonl").read_text() == "one\n"
        assert (runtimes[1] / "sessions" / "two").read_text() == "two\n"
        assert not any((state / "st" / "codex").iterdir())


def test_sqlite_family_alias_is_rejected_before_any_state_mutation():
    module = implementation()
    with tempfile.TemporaryDirectory() as tmp:
        manifest, state, (runtime,) = fixture(Path(tmp), "44444445")
        write_materialized(runtime)
        document = json.loads(manifest.read_text(encoding="utf-8"))
        document["entries"].append(
            {"vendor": "codex", "path": "state.sqlite-wal", "kind": "file"}
        )
        manifest.write_text(json.dumps(document), encoding="utf-8")

        try:
            run_upgrade(module, manifest, state, "codex")
        except module.UpgradeError as error:
            assert "expanded path" in str(error)
        else:
            raise AssertionError("an explicit sqlite-family alias was accepted")

        assert_materialized(runtime)
        assert (runtime / "state.sqlite-wal").read_text(encoding="utf-8") == "wal\n"
        assert not any((state / "st" / "codex").iterdir())
        assert not (state / "recovery").exists()


def test_source_mutation_discards_stage_and_preserves_runtime():
    module = implementation()
    with tempfile.TemporaryDirectory() as tmp:
        manifest, state, (runtime,) = fixture(Path(tmp), "55555555")
        write_materialized(runtime)
        real_copy = module._copy_entry
        mutated = False

        def copy_then_mutate(*args):
            nonlocal mutated
            real_copy(*args)
            if not mutated:
                mutated = True
                (runtime / "history.jsonl").write_text("changed during copy\n", encoding="utf-8")

        with mock.patch.object(module, "_copy_entry", side_effect=copy_then_mutate):
            try:
                run_upgrade(module, manifest, state, "codex")
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
        def fail_exchange(*_args, **_kwargs):
            raise OSError("injected publication failure")

        with mock.patch.object(module, "_exchange_directories", side_effect=fail_exchange):
            try:
                run_upgrade(module, manifest, state, "codex")
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
                run_upgrade(module, manifest, state, "codex")
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
        real_exchange = module._exchange_directories
        exchanges = 0

        def publish_mutate_then_fail_rollback(*args, **kwargs):
            nonlocal exchanges
            exchanges += 1
            if exchanges == 1:
                result = real_exchange(*args, **kwargs)
                (runtime / "history.jsonl").write_text("late rollback\n", encoding="utf-8")
                return result
            raise OSError("injected exchange rollback failure")

        with mock.patch.object(
            module, "_exchange_directories", side_effect=publish_mutate_then_fail_rollback
        ):
            try:
                run_upgrade(module, manifest, state, "codex")
            except module.UpgradeError as error:
                assert "rollback is incomplete" in str(error)
                assert "preserved" in str(error)
            else:
                raise AssertionError("incomplete publication rollback was hidden")

        assert not (runtime / "history.jsonl").is_symlink()
        assert (runtime / "history.jsonl").read_text(encoding="utf-8") == "late rollback\n"
        stages = list((state / "st").glob(".runtime-upgrade-*"))
        assert len(stages) == 1
        assert (stages[0] / "vendor").is_dir()


def test_symlinked_runtime_ancestry_is_rejected_without_touching_external_state():
    module = implementation()
    for topology in ("runtime-root", "generation", "vendor"):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            manifest, state, _ = fixture(root)
            external = root / "external" / topology
            external_runtime = external / "11111111" / "codex"
            external_runtime.mkdir(parents=True)
            (external_runtime / "history.jsonl").write_text("external\n", encoding="utf-8")

            if topology == "runtime-root":
                os.symlink(external, state / "r")
            elif topology == "generation":
                (state / "r").mkdir()
                os.symlink(external / "11111111", state / "r" / "11111111")
            else:
                (state / "r" / "11111111").mkdir(parents=True)
                os.symlink(external_runtime, state / "r" / "11111111" / "codex")

            try:
                run_upgrade(module, manifest, state, "codex")
            except module.UpgradeError as error:
                assert "symlink" in str(error) or "real directory" in str(error)
            else:
                raise AssertionError(f"{topology} symlink ancestry was followed")

            assert (external_runtime / "history.jsonl").read_text() == "external\n"
            assert not any((state / "st" / "codex").iterdir())
            assert not (state / "recovery").exists()


def test_active_canonical_file_consumer_blocks_migration():
    module = implementation()
    with tempfile.TemporaryDirectory() as tmp:
        manifest, state, (runtime,) = fixture(Path(tmp), "99999991")
        write_materialized(runtime)
        canonical_file = state / "st" / "codex" / "consumer-state"
        canonical_file.write_text("canonical\n", encoding="utf-8")
        process = subprocess.Popen(
            [
                sys.executable,
                "-c",
                "import sys; f=open(sys.argv[1], 'rb'); print('ready', flush=True); sys.stdin.read()",
                str(canonical_file),
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
        )
        assert process.stdout is not None and process.stdout.readline().strip() == "ready"
        try:
            try:
                run_upgrade(module, manifest, state, "codex", process.pid)
            except module.UpgradeError as error:
                assert "active" in str(error) or "consumer" in str(error)
            else:
                raise AssertionError("an open canonical-state consumer was ignored")
        finally:
            assert process.stdin is not None
            process.stdin.close()
            process.wait(timeout=5)

        assert_materialized(runtime)
        assert canonical_file.read_text() == "canonical\n"


def test_active_materialized_owner_file_consumer_blocks_migration():
    module = implementation()
    with tempfile.TemporaryDirectory() as tmp:
        manifest, state, (runtime,) = fixture(Path(tmp), "99999990")
        write_materialized(runtime)
        process = subprocess.Popen(
            [
                sys.executable,
                "-c",
                "import sys; f=open(sys.argv[1], 'rb'); print('ready', flush=True); sys.stdin.read()",
                str(runtime / "history.jsonl"),
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
        )
        assert process.stdout is not None and process.stdout.readline().strip() == "ready"
        try:
            try:
                run_upgrade(module, manifest, state, "codex", process.pid)
            except module.UpgradeError as error:
                assert "consumer" in str(error)
            else:
                raise AssertionError("an open materialized-state consumer was ignored")
        finally:
            assert process.stdin is not None
            process.stdin.close()
            process.wait(timeout=5)

        assert_materialized(runtime)
        assert not any((state / "st" / "codex").iterdir())


def test_unavailable_process_proof_fails_closed():
    module = implementation()
    with mock.patch.object(module.Path, "is_dir", return_value=False):
        try:
            module._require_quiescent(
                [Path("/state/r/generation/codex")],
                Path("/state/st/codex"),
                Path("/state/r/generation/codex"),
            )
        except module.UpgradeError as error:
            assert "cannot prove" in str(error)
        else:
            raise AssertionError("missing process evidence was treated as quiescence")


def test_active_sibling_runtime_blocks_materialized_owner_migration():
    module = implementation()
    with tempfile.TemporaryDirectory() as tmp:
        manifest, state, runtimes = fixture(Path(tmp), "99999992", "99999993")
        write_materialized(runtimes[0])
        environment = {**os.environ, "IHAR_RUNTIME": str(runtimes[1])}
        process = subprocess.Popen(
            [sys.executable, "-c", "import sys; print('ready', flush=True); sys.stdin.read()"],
            env=environment,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
        )
        assert process.stdout is not None and process.stdout.readline().strip() == "ready"
        try:
            try:
                run_upgrade(module, manifest, state, "codex", process.pid)
            except module.UpgradeError as error:
                assert str(runtimes[1]) in str(error)
            else:
                raise AssertionError("an active sibling runtime was ignored")
        finally:
            assert process.stdin is not None
            process.stdin.close()
            process.wait(timeout=5)

        assert_materialized(runtimes[0])
        assert not any((state / "st" / "codex").iterdir())


def test_post_stage_late_write_is_rejected_before_publication():
    module = implementation()
    assert hasattr(module, "_require_quiescent"), "quiescence gate is missing"
    with tempfile.TemporaryDirectory() as tmp:
        manifest, state, (runtime,) = fixture(Path(tmp), "99999994")
        write_materialized(runtime)
        real_quiescence = module._require_quiescent
        calls = 0

        def check_then_mutate(*args, **kwargs):
            nonlocal calls
            result = real_quiescence(*args, **kwargs)
            calls += 1
            if calls == 2:
                (runtime / "history.jsonl").write_text("late write\n", encoding="utf-8")
            return result

        with mock.patch.object(module, "_require_quiescent", side_effect=check_then_mutate):
            try:
                run_upgrade(module, manifest, state, "codex")
            except module.UpgradeError as error:
                assert "changed" in str(error)
            else:
                raise AssertionError("post-stage source mutation was published")

        assert (runtime / "history.jsonl").read_text() == "late write\n"
        assert not runtime.joinpath("history.jsonl").is_symlink()
        assert not any((state / "st" / "codex").iterdir())


def test_post_exchange_late_write_rolls_back_atomic_publication():
    module = implementation()
    assert hasattr(module, "_exchange_directories"), "atomic exchange helper is missing"
    with tempfile.TemporaryDirectory() as tmp:
        manifest, state, (runtime,) = fixture(Path(tmp), "99999995")
        write_materialized(runtime)
        real_exchange = module._exchange_directories
        calls = 0

        def exchange_then_mutate(*args, **kwargs):
            nonlocal calls
            result = real_exchange(*args, **kwargs)
            calls += 1
            if calls == 1:
                (runtime / "history.jsonl").write_text("after exchange\n", encoding="utf-8")
            return result

        with mock.patch.object(module, "_exchange_directories", side_effect=exchange_then_mutate):
            try:
                run_upgrade(module, manifest, state, "codex")
            except module.UpgradeError as error:
                assert "changed" in str(error)
            else:
                raise AssertionError("post-exchange source mutation was linked")

        assert calls == 2, "atomic exchange rollback did not run"
        assert (runtime / "history.jsonl").read_text() == "after exchange\n"
        assert not runtime.joinpath("history.jsonl").is_symlink()
        assert not any((state / "st" / "codex").iterdir())


if __name__ == "__main__":
    tests = [value for name, value in sorted(globals().items()) if name.startswith("test_")]
    for test in tests:
        test()
    print(f"PASS={len(tests)} FAIL=0")
