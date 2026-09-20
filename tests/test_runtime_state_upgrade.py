#!/usr/bin/env python3
"""Transactional upgrade tests for pre-manifest runtime state."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import threading
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


def spawn_session_process(
    identity: str,
    *,
    environment: dict[str, str] | None = None,
    opaque: bool = False,
    open_path: Path | None = None,
    cwd: Path | None = None,
) -> subprocess.Popen[str]:
    script = "import sys; "
    arguments = [identity, "-c"]
    if open_path is not None:
        script += "handle=open(sys.argv[1], 'rb'); "
    if opaque:
        script += "import ctypes; assert ctypes.CDLL(None).prctl(4,0,0,0,0) == 0; "
    script += "print('ready', flush=True); sys.stdin.read()"
    arguments.append(script)
    if open_path is not None:
        arguments.append(str(open_path))
    process = subprocess.Popen(
        arguments,
        executable=sys.executable,
        env=environment,
        cwd=cwd,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
    )
    assert process.stdout is not None and process.stdout.readline().strip() == "ready"
    return process


def stop_session_process(process: subprocess.Popen[str]) -> None:
    assert process.stdin is not None
    process.stdin.close()
    process.wait(timeout=5)


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


def test_unreadable_environment_still_reports_runtime_file_descriptor_consumer():
    module = implementation()
    with tempfile.TemporaryDirectory() as tmp:
        manifest, state, (runtime,) = fixture(Path(tmp), "99999989")
        write_materialized(runtime)
        target = runtime / "history.jsonl"
        process = spawn_session_process("unrelated-worker", open_path=target)
        real_read_bytes = module.Path.read_bytes

        def unreadable_environment(path):
            if path.name == "environ":
                raise PermissionError("injected unreadable environment")
            return real_read_bytes(path)

        try:
            with mock.patch.object(module.Path, "read_bytes", new=unreadable_environment):
                try:
                    run_upgrade(module, manifest, state, "codex", process.pid)
                except module.UpgradeError as error:
                    message = str(error)
                    assert "runtime-state open file consumer" in message
                    assert str(target) in message
                else:
                    raise AssertionError("unreadable environment skipped runtime fd inspection")
        finally:
            stop_session_process(process)

        assert_materialized(runtime)
        assert not any((state / "st" / "codex").iterdir())


def test_production_session_ignores_opaque_daemons_but_blocks_vendor_candidates():
    module = implementation()
    with tempfile.TemporaryDirectory() as tmp:
        _manifest, state, runtimes = fixture(Path(tmp), "99999976", "99999977")
        canonical = state / "st" / "codex"
        daemons = []
        readable = unreadable = None
        try:
            for identity in ("systemd", "(sd-pam)", "ssh-agent"):
                daemons.append(spawn_session_process(identity, opaque=True))
            with mock.patch.object(
                module, "_proc_processes", return_value=[Path(f"/proc/{p.pid}") for p in daemons]
            ):
                module._require_quiescent(runtimes, canonical, runtimes[0])

            readable = spawn_session_process(
                "codex",
                environment={**os.environ, "CODEX_HOME": str(runtimes[1])},
            )
            with mock.patch.object(
                module,
                "_proc_processes",
                return_value=[*(Path(f"/proc/{p.pid}") for p in daemons), Path(f"/proc/{readable.pid}")],
            ):
                try:
                    module._require_quiescent(runtimes, canonical, runtimes[0])
                except module.UpgradeError as error:
                    assert f"process {readable.pid}" in str(error)
                    assert f"CODEX_HOME={runtimes[1]}" in str(error)
                else:
                    raise AssertionError("readable Codex runtime selector was ignored")
            stop_session_process(readable)
            readable = None

            unreadable = spawn_session_process("codex", opaque=True)
            with mock.patch.object(
                module,
                "_proc_processes",
                return_value=[
                    *(Path(f"/proc/{p.pid}") for p in daemons),
                    Path(f"/proc/{unreadable.pid}"),
                ],
            ):
                try:
                    module._require_quiescent(runtimes, canonical, runtimes[0])
                except module.UpgradeError as error:
                    message = str(error)
                    assert f"process {unreadable.pid}" in message
                    assert "candidate command line 'codex'" in message
                    assert all(f"process {daemon.pid}" not in message for daemon in daemons)
                else:
                    raise AssertionError("unreadable Codex candidate was ignored")
        finally:
            if readable is not None:
                stop_session_process(readable)
            if unreadable is not None:
                stop_session_process(unreadable)
            for daemon in daemons:
                stop_session_process(daemon)


def test_candidate_generation_requires_quiescence_without_materialized_state():
    module = implementation()
    with tempfile.TemporaryDirectory() as tmp:
        manifest, state, (runtime,) = fixture(Path(tmp), "99999974")
        config = runtime / "config.toml"
        config.write_text("runtime config\n", encoding="utf-8")
        generation_config = runtime.parent / "generation.config"
        generation_config.write_text("generation config\n", encoding="utf-8")

        cases = (
            (
                "generation open file",
                spawn_session_process("unrelated-worker", open_path=generation_config),
                "runtime-state open file consumer",
            ),
            (
                "opaque candidate",
                spawn_session_process("codex", opaque=True),
                "cannot prove that runtime-state consumers are quiescent",
            ),
        )
        try:
            for description, process, diagnostic in cases:
                with mock.patch.object(
                    module, "_proc_processes", return_value=[Path(f"/proc/{process.pid}")]
                ):
                    try:
                        module.upgrade(manifest, state, "codex", "99999974")
                    except module.UpgradeError as error:
                        assert diagnostic in str(error)
                    else:
                        raise AssertionError(
                            f"link-only candidate ignored {description} consumer"
                        )
                assert config.read_text(encoding="utf-8") == "runtime config\n"
                assert generation_config.read_text(encoding="utf-8") == "generation config\n"
                assert not any((state / "st" / "codex").iterdir())
        finally:
            for _description, process, _diagnostic in cases:
                stop_session_process(process)


def test_partial_environment_requires_independent_vendor_identity():
    module = implementation()
    unrelated = spawn_session_process("python-worker")
    candidate = spawn_session_process("codex")
    real_read_bytes = module.Path.read_bytes

    def partial_environment(path):
        if path.name == "environ":
            return b"LANG=C"
        return real_read_bytes(path)

    try:
        with mock.patch.object(module.Path, "read_bytes", new=partial_environment), \
             mock.patch.object(
                 module, "_proc_processes", return_value=[Path(f"/proc/{unrelated.pid}")]
             ):
            module._require_quiescent(
                [Path("/state/r/generation/codex")],
                Path("/state/st/codex"),
                Path("/state/r/generation/codex"),
            )

        with mock.patch.object(module.Path, "read_bytes", new=partial_environment), \
             mock.patch.object(
                 module, "_proc_processes", return_value=[Path(f"/proc/{candidate.pid}")]
             ):
            try:
                module._require_quiescent(
                    [Path("/state/r/generation/codex")],
                    Path("/state/st/codex"),
                    Path("/state/r/generation/codex"),
                )
            except module.UpgradeError as error:
                message = str(error)
                assert "environment is incomplete" in message
                assert "candidate command line 'codex'" in message
            else:
                raise AssertionError("partial Codex environment was accepted")
    finally:
        stop_session_process(candidate)
        stop_session_process(unrelated)


def test_partial_environment_blocks_a_readable_runtime_selector_without_identity():
    module = implementation()
    process = spawn_session_process("python-worker")
    selected = Path("/state/r/sibling/codex")
    real_read_bytes = module.Path.read_bytes

    def partial_environment(path):
        if path.name == "environ":
            return os.fsencode(f"LANG=C\0CODEX_HOME={selected}")
        return real_read_bytes(path)

    try:
        with mock.patch.object(module.Path, "read_bytes", new=partial_environment), \
             mock.patch.object(
                 module, "_proc_processes", return_value=[Path(f"/proc/{process.pid}")]
             ):
            try:
                module._require_quiescent(
                    [Path("/state/r/generation/codex"), selected],
                    Path("/state/st/codex"),
                    Path("/state/r/generation/codex"),
                )
            except module.UpgradeError as error:
                assert f"CODEX_HOME={selected}" in str(error)
            else:
                raise AssertionError("readable selector in a partial environment was ignored")
    finally:
        stop_session_process(process)


def test_duplicate_readable_selectors_cannot_hide_a_protected_runtime():
    module = implementation()
    process = spawn_session_process("python-worker")
    selected = Path("/state/r/sibling/codex")
    real_read_bytes = module.Path.read_bytes

    def duplicate_environment(path):
        if path.name == "environ":
            return os.fsencode(f"CODEX_HOME=/outside\0CODEX_HOME={selected}\0")
        return real_read_bytes(path)

    try:
        with mock.patch.object(module.Path, "read_bytes", new=duplicate_environment), \
             mock.patch.object(
                 module, "_proc_processes", return_value=[Path(f"/proc/{process.pid}")]
             ):
            try:
                module._require_quiescent(
                    [Path("/state/r/generation/codex"), selected],
                    Path("/state/st/codex"),
                    Path("/state/r/generation/codex"),
                )
            except module.UpgradeError as error:
                assert f"CODEX_HOME={selected}" in str(error)
            else:
                raise AssertionError("a duplicate protected runtime selector was hidden")
    finally:
        stop_session_process(process)


def test_command_line_root_reference_preserves_equals_in_absolute_path():
    module = implementation()
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / "project=fixture"
        root.mkdir()
        _manifest, state, runtimes = fixture(root, "99999975")
        target = runtimes[0] / "consumer-state"
        target.write_text("consumer\n", encoding="utf-8")
        process = spawn_session_process("python-worker", opaque=True, open_path=target)
        try:
            with mock.patch.object(
                module, "_proc_processes", return_value=[Path(f"/proc/{process.pid}")]
            ):
                try:
                    module._require_quiescent(runtimes, state / "st" / "codex", runtimes[0])
                except module.UpgradeError as error:
                    message = str(error)
                    assert "candidate command-line root reference" in message
                    assert str(target) in message
                else:
                    raise AssertionError("an opaque command-line root reference was ignored")
        finally:
            stop_session_process(process)


def test_candidate_command_identities_are_vendor_specific_and_include_wrappers():
    module = implementation()
    cases = (
        ("codex", "codex", True),
        ("codex", "codex-acp", True),
        ("codex", "ihar", True),
        ("codex", "ihar.sh", True),
        ("codex", "claude", False),
        ("codex", "claude-agent-acp", False),
        ("claude", "claude", True),
        ("claude", "claude-agent-acp", True),
        ("claude", "ihar", True),
        ("claude", "ihar.sh", True),
        ("claude", "codex", False),
        ("claude", "codex-acp", False),
    )
    real_read_bytes = module.Path.read_bytes

    def partial_environment(path):
        if path.name == "environ":
            return b"LANG=C"
        return real_read_bytes(path)

    for vendor, identity, should_block in cases:
        process = spawn_session_process(identity)
        owner = Path(f"/state/r/generation/{vendor}")
        try:
            with mock.patch.object(module.Path, "read_bytes", new=partial_environment), \
                 mock.patch.object(
                     module, "_proc_processes", return_value=[Path(f"/proc/{process.pid}")]
                 ):
                try:
                    module._require_quiescent([owner], Path(f"/state/st/{vendor}"), owner)
                except module.UpgradeError as error:
                    if not should_block:
                        raise AssertionError(
                            f"wrong-vendor identity {identity!r} blocked {vendor}"
                        ) from error
                    assert f"candidate command line {identity!r}" in str(error)
                else:
                    if should_block:
                        raise AssertionError(f"candidate identity {identity!r} was ignored")
        finally:
            stop_session_process(process)


def test_candidate_executable_identity_fails_closed_on_unreadable_environment():
    module = implementation()
    process = spawn_session_process("python-worker")
    real_read_bytes = module.Path.read_bytes
    real_readlink = module.os.readlink

    def unreadable_environment(path):
        if path.name == "environ":
            raise PermissionError("injected unreadable environment")
        return real_read_bytes(path)

    def codex_executable(path):
        if Path(path).name == "exe":
            return "/store/bin/codex"
        return real_readlink(path)

    try:
        with mock.patch.object(module.Path, "read_bytes", new=unreadable_environment), \
             mock.patch.object(module.os, "readlink", side_effect=codex_executable), \
             mock.patch.object(
                 module, "_proc_processes", return_value=[Path(f"/proc/{process.pid}")]
             ):
            try:
                module._require_quiescent(
                    [Path("/state/r/generation/codex")],
                    Path("/state/st/codex"),
                    Path("/state/r/generation/codex"),
                )
            except module.UpgradeError as error:
                assert "candidate executable 'codex'" in str(error)
            else:
                raise AssertionError("Codex executable identity was ignored")
    finally:
        stop_session_process(process)


def test_candidate_cwd_and_fd_uncertainty_blocks_with_complete_environment():
    module = implementation()
    real_readlink = module.os.readlink
    real_iterdir = module.Path.iterdir

    for unavailable in ("cwd", "fd"):
        process = spawn_session_process("codex")

        def selective_readlink(path):
            if unavailable == "cwd" and Path(path).name == "cwd":
                raise PermissionError("injected unreadable cwd")
            return real_readlink(path)

        def selective_iterdir(path):
            if unavailable == "fd" and path.name == "fd":
                raise PermissionError("injected unreadable file descriptors")
            return real_iterdir(path)

        try:
            with mock.patch.object(module.os, "readlink", side_effect=selective_readlink), \
                 mock.patch.object(module.Path, "iterdir", new=selective_iterdir), \
                 mock.patch.object(
                     module, "_proc_processes", return_value=[Path(f"/proc/{process.pid}")]
                 ):
                try:
                    module._require_quiescent(
                        [Path("/state/r/generation/codex")],
                        Path("/state/st/codex"),
                        Path("/state/r/generation/codex"),
                    )
                except module.UpgradeError as error:
                    message = str(error)
                    assert "candidate command line 'codex'" in message
                    assert ("cwd:" if unavailable == "cwd" else "file descriptors:") in message
                else:
                    raise AssertionError(f"candidate {unavailable} uncertainty was ignored")
        finally:
            stop_session_process(process)


def test_sibling_runtime_cwd_and_file_descriptor_consumers_block_migration():
    module = implementation()
    with tempfile.TemporaryDirectory() as tmp:
        manifest, state, runtimes = fixture(Path(tmp), "99999978", "99999979")
        write_materialized(runtimes[0])
        sibling_file = runtimes[1] / "consumer-state"
        sibling_file.write_text("sibling\n", encoding="utf-8")
        cases = (
            ("cwd", {"cwd": runtimes[1]}, "runtime-state cwd consumer", str(runtimes[1])),
            (
                "open file",
                {"open_path": sibling_file},
                "runtime-state open file consumer",
                str(sibling_file),
            ),
        )
        for evidence, process_options, diagnostic, target in cases:
            process = spawn_session_process("unrelated-worker", **process_options)
            try:
                try:
                    run_upgrade(module, manifest, state, "codex", process.pid)
                except module.UpgradeError as error:
                    assert diagnostic in str(error)
                    assert target in str(error)
                else:
                    raise AssertionError(f"sibling runtime {evidence} consumer was ignored")
            finally:
                stop_session_process(process)

        assert_materialized(runtimes[0])
        assert sibling_file.read_text(encoding="utf-8") == "sibling\n"
        assert not any((state / "st" / "codex").iterdir())


def test_detached_unreadable_native_selector_and_runtime_fd_fail_closed():
    module = implementation()
    with tempfile.TemporaryDirectory() as tmp:
        manifest, state, runtimes = fixture(Path(tmp), "99999983", "99999984")
        write_materialized(runtimes[0])
        environment = {**os.environ, "CODEX_HOME": str(runtimes[1])}
        process = subprocess.Popen(
            [
                sys.executable,
                "-c",
                (
                    "import ctypes,sys; f=open(sys.argv[1], 'rb'); "
                    "assert ctypes.CDLL(None).prctl(4,0,0,0,0) == 0; "
                    "print('ready', flush=True); sys.stdin.read()"
                ),
                str(runtimes[0] / "history.jsonl"),
            ],
            env=environment,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )
        assert process.stdout is not None and process.stdout.readline().strip() == "ready"
        try:
            try:
                run_upgrade(module, manifest, state, "codex", process.pid)
            except module.UpgradeError as error:
                assert "cannot prove" in str(error)
                assert str(process.pid) in str(error)
            else:
                raise AssertionError("detached unreadable runtime consumer was ignored")
        finally:
            assert process.stdin is not None
            process.stdin.close()
            process.wait(timeout=5)

        assert_materialized(runtimes[0])
        assert not any((state / "st" / "codex").iterdir())


def test_detached_partial_environment_still_checks_runtime_file_descriptors():
    module = implementation()
    with tempfile.TemporaryDirectory() as tmp:
        manifest, state, (runtime,) = fixture(Path(tmp), "99999982")
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
            start_new_session=True,
        )
        assert process.stdout is not None and process.stdout.readline().strip() == "ready"
        try:
            with mock.patch.object(
                module.Path, "read_bytes", return_value=b"CODEX_HOME=/partial"
            ):
                try:
                    run_upgrade(module, manifest, state, "codex", process.pid)
                except module.UpgradeError as error:
                    assert "consumer" in str(error)
                    assert str(runtime / "history.jsonl") in str(error)
                else:
                    raise AssertionError("partial environment skipped runtime fd inspection")
        finally:
            assert process.stdin is not None
            process.stdin.close()
            process.wait(timeout=5)

        assert_materialized(runtime)
        assert not any((state / "st" / "codex").iterdir())


def test_current_helper_is_excluded_by_pid_even_when_environment_is_unreadable():
    module = implementation()
    with mock.patch.object(module, "_proc_processes", return_value=[Path(f"/proc/{os.getpid()}")]), \
         mock.patch.object(module.Path, "read_bytes", side_effect=PermissionError("unreadable")):
        module._require_quiescent(
            [Path("/state/r/generation/codex")],
            Path("/state/st/codex"),
            Path("/state/r/generation/codex"),
        )


def test_parent_consumers_are_not_excluded_from_child_upgrade_scan():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        for generation, target_kind in (("99999980", "materialized"), ("99999981", "canonical")):
            case_root = root / target_kind
            case_root.mkdir()
            manifest, state, (runtime,) = fixture(case_root, generation)
            write_materialized(runtime)
            canonical = state / "st" / "codex"
            target = runtime / "history.jsonl"
            if target_kind == "canonical":
                target = canonical / "consumer-state"
                target.write_text("canonical\n", encoding="utf-8")
            with target.open("rb"):
                script = (
                    "import os,sys; from pathlib import Path; "
                    "from ihar import runtime_state_upgrade as m; "
                    "m._proc_processes=lambda proc:[Path(f'/proc/{os.getppid()}')]; "
                    "sys.exit(m.main(sys.argv[1:]))"
                )
                result = subprocess.run(
                    [sys.executable, "-c", script, str(manifest), str(state), "codex"],
                    env={**os.environ, "PYTHONPATH": str(Path(__file__).parents[1] / "lib/python")},
                    capture_output=True,
                    text=True,
                    check=False,
                )
            assert result.returncode == 1, result.stderr
            assert str(os.getpid()) in result.stderr
            assert_materialized(runtime)
            assert canonical.is_dir()
            if target_kind == "materialized":
                assert not any(canonical.iterdir())
            else:
                assert target.read_text(encoding="utf-8") == "canonical\n"


def test_native_runtime_selectors_block_owner_sibling_and_canonical_state():
    module = implementation()
    cases = (
        ("CODEX_HOME", "sibling"),
        ("CLAUDE_CONFIG_DIR", "owner"),
        ("CODEX_HOME", "canonical"),
    )
    for selector, target_kind in cases:
        with tempfile.TemporaryDirectory() as tmp:
            manifest, state, runtimes = fixture(Path(tmp), "99999987", "99999988")
            write_materialized(runtimes[0])
            targets = {
                "owner": runtimes[0],
                "sibling": runtimes[1],
                "canonical": state / "st" / "codex",
            }
            environment = {**os.environ, selector: str(targets[target_kind])}
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
                    assert selector in str(error)
                    assert str(targets[target_kind]) in str(error)
                else:
                    raise AssertionError(f"active native selector {selector} was ignored")
            finally:
                assert process.stdin is not None
                process.stdin.close()
                process.wait(timeout=5)

            assert_materialized(runtimes[0])
            assert not any((state / "st" / "codex").iterdir())


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


def test_atomic_exchange_uses_one_renameat2_exchange_syscall():
    module = implementation()
    calls = []

    class RenameAt2:
        argtypes = None
        restype = None

        def __call__(self, *args):
            calls.append(args)
            return 0

    renameat2 = RenameAt2()
    libc = type("LibC", (), {"renameat2": renameat2})()
    with mock.patch.object(module.ctypes, "CDLL", return_value=libc):
        module._exchange_directories(10, "staged", 20, "canonical")

    assert calls == [(10, b"staged", 20, b"canonical", module._RENAME_EXCHANGE)]


def test_atomic_exchange_never_exposes_a_missing_canonical_directory():
    module = implementation()
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / "staged").mkdir()
        (root / "canonical").mkdir()
        parent_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
        started = threading.Event()
        stop = threading.Event()
        missing = []

        def observe():
            started.set()
            while not stop.is_set():
                if not (root / "canonical").is_dir():
                    missing.append(True)
                    return

        observer = threading.Thread(target=observe)
        observer.start()
        assert started.wait(timeout=5)
        try:
            for _attempt in range(500):
                module._exchange_directories(parent_fd, "staged", parent_fd, "canonical")
        finally:
            stop.set()
            observer.join(timeout=5)
            os.close(parent_fd)

        assert not observer.is_alive()
        assert not missing, "canonical directory disappeared during publication"


def test_missing_atomic_exchange_support_preserves_every_original_byte():
    module = implementation()
    with tempfile.TemporaryDirectory() as tmp:
        manifest, state, (runtime,) = fixture(Path(tmp), "99999986")
        write_materialized(runtime)
        canonical = state / "st" / "codex"
        before = (runtime / "history.jsonl").read_bytes()

        with mock.patch.object(module.ctypes, "CDLL", return_value=object()):
            try:
                run_upgrade(module, manifest, state, "codex")
            except module.UpgradeError as error:
                assert "atomic directory exchange is unavailable" in str(error)
            else:
                raise AssertionError("migration published without atomic exchange support")

        assert (runtime / "history.jsonl").read_bytes() == before
        assert_materialized(runtime)
        assert canonical.is_dir() and not any(canonical.iterdir())
        assert not list((state / "st").glob(".runtime-upgrade-*"))


def test_exchange_rollback_failure_reports_existing_recovery_with_original_bytes():
    module = implementation()
    with tempfile.TemporaryDirectory() as tmp:
        manifest, state, (runtime,) = fixture(Path(tmp), "99999985")
        write_materialized(runtime)
        real_exchange = module._exchange_directories
        real_fingerprint = module._fingerprint_entries
        exchange_calls = 0
        recovery_checks = 0

        def publish_then_fail_rollback(*args, **kwargs):
            nonlocal exchange_calls
            exchange_calls += 1
            if exchange_calls == 1:
                return real_exchange(*args, **kwargs)
            raise OSError("injected recovery exchange failure")

        def fail_after_relink(root_fd, entries):
            nonlocal recovery_checks
            result = real_fingerprint(root_fd, entries)
            recovery_checks += 1
            if recovery_checks == 7:
                return "mismatch"
            return result

        with mock.patch.object(module, "_exchange_directories", side_effect=publish_then_fail_rollback), \
             mock.patch.object(module, "_fingerprint_entries", side_effect=fail_after_relink):
            try:
                run_upgrade(module, manifest, state, "codex")
            except module.UpgradeError as error:
                message = str(error)
                assert "rollback is incomplete" in message
            else:
                raise AssertionError("incomplete rollback was hidden")

        marker = "preserved recovery at "
        reported = Path(message.split(marker, 1)[1].split(": ", 1)[0])
        assert reported.is_dir(), f"reported recovery directory is missing: {reported}"
        assert (reported / "history.jsonl").read_text(encoding="utf-8") == "history\n"
        assert (reported / "sessions" / "thread.jsonl").read_text(encoding="utf-8") == "thread\n"


if __name__ == "__main__":
    tests = [value for name, value in sorted(globals().items()) if name.startswith("test_")]
    for test in tests:
        test()
    print(f"PASS={len(tests)} FAIL=0")
