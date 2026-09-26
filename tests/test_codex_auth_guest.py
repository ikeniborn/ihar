#!/usr/bin/env python3
"""Synthetic, owner-held guest credential handoff tests."""

from __future__ import annotations

import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from contextlib import ExitStack
from pathlib import Path
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "lib", "python"))

from ihar.codex import auth_owner
from ihar.codex.auth_owner import AuthOwnerError


def _update_guarded(store: Path, update):
    with ExitStack() as stack:
        owner = auth_owner._locked_owner(auth_owner._lease_store(store), stack)
        record = auth_owner._read_owner(owner)
        result = update(owner, record)
        auth_owner._write_owner(owner, record)
        return result


def acquire(_runtime: Path, mode: str, *, store: Path) -> str | None:
    if mode != "guest":
        return auth_owner.acquire(_runtime, mode, store=store)
    with ExitStack() as stack:
        owner = auth_owner._locked_owner(store, stack)
        auth_owner._write_owner(owner, {
            "schema": 2,
            "state": "active",
            "guardian": auth_owner._identity_for(os.getpid()),
            "child": None,
            "children": [],
            "daemon": None,
            "guest": None,
            "guest_bundle": None,
            "guest_reconciled": False,
            "runtime": None,
            "config_hash": None,
        })


def register_guest_bundle(bundle: Path, image: Path, store: Path,
                          _owner: None, seed: Path) -> dict:
    def update(owner, record):
        auth_owner.register_guarded_guest_bundle(bundle, image, seed, owner, record)
        return record["guest_bundle"]["baseline"]
    return _update_guarded(store, update)


def bind_guest_vm(_owner: None, pid: int, binary: str, *, store: Path) -> None:
    def update(_descriptor, record):
        auth_owner.mark_guarded_guest_starting(record)
        auth_owner.bind_guarded_guest_vm(auth_owner._identity_for(pid, binary), record)
    _update_guarded(store, update)


def mark_guest_quiescent(_owner: None, *, store: Path) -> None:
    _update_guarded(store, lambda _descriptor, record:
                    auth_owner.mark_guarded_guest_quiescent(record))


def publish_guest(bundle: Path, _baseline: dict, store: Path, _owner: None) -> str:
    return _update_guarded(store, lambda descriptor, record:
                           auth_owner.publish_guarded_guest(bundle, store, descriptor, record))


def acknowledge_guest(bundle: Path, store: Path, acknowledgment: str) -> None:
    _update_guarded(store, lambda descriptor, record:
                    auth_owner.acknowledge_guarded_guest(
                        bundle, descriptor, record, acknowledgment))


def release(_owner: None, *, store: Path) -> None:
    if _owner is not None:
        auth_owner.release(_owner, store=store)
        return
    with ExitStack() as stack:
        owner = auth_owner._locked_owner(store, stack)
        record = auth_owner._read_owner(owner)
        if record.get("guest_bundle") is not None and not record.get("guest_reconciled"):
            raise AuthOwnerError("Codex guest credential return is incomplete; bundle retained")
        os.unlink(auth_owner._OWNER_RECORD, dir_fd=owner)
        os.fsync(owner)


def bundle_identity_matches(bundle: Path, _owner: None, *, store: Path) -> bool:
    try:
        with ExitStack() as stack:
            owner = auth_owner._locked_owner(store, stack)
            auth_owner._guest_record(auth_owner._read_owner(owner), bundle.resolve())
        return True
    except (OSError, KeyError, AuthOwnerError):
        return False


def abort_guest_prelaunch(store: Path) -> None:
    with ExitStack() as stack:
        owner = auth_owner._locked_owner(store, stack)
        record = auth_owner._read_owner(owner)
        auth_owner.abort_guarded_guest_prelaunch(owner, record)
        os.unlink(auth_owner._OWNER_RECORD, dir_fd=owner)
        os.fsync(owner)


def mark_guest_starting(store: Path) -> None:
    _update_guarded(store, lambda _descriptor, record:
                    auth_owner.mark_guarded_guest_starting(record))


class GuestAuthTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.store = self.root / "store"
        self.store.mkdir(mode=0o700)
        self.canonical = self.store / "auth" / "codex" / "auth.json"
        self.canonical.parent.mkdir(parents=True, mode=0o700)
        self.canonical.parent.parent.chmod(0o700)
        self.canonical.write_text("synthetic-old", encoding="utf-8")
        self.canonical.chmod(0o600)
        self.owner_id = acquire(self.root / "runtime", "guest", store=self.store)
        with ExitStack() as stack:
            _root, _auth, owner = auth_owner._owner_directories(self.store, stack, create=False)
            self.original_baseline = auth_owner._canonical_identity(owner)
        self.bundle = self.root / "bundle"
        self.bundle.mkdir(mode=0o700)
        self.image = self.bundle / "state.ext4"
        self.image.write_bytes(b"synthetic-image")
        self.image.chmod(0o600)
        self.guest_candidate = self.bundle / "auth.json"
        self.guest_candidate.write_text("synthetic-old", encoding="utf-8")
        self.guest_candidate.chmod(0o600)
        register_guest_bundle(self.bundle, self.image, self.store, self.owner_id,
                              self.guest_candidate)

    def quiesce(self) -> None:
        process = subprocess.Popen(["sleep", "60"], start_new_session=True)
        bind_guest_vm(self.owner_id, process.pid, "/usr/bin/sleep", store=self.store)
        process.terminate()
        process.wait()
        mark_guest_quiescent(self.owner_id, store=self.store)

    def registration_fixture(self, name: str) -> tuple[Path, Path, Path, Path]:
        root = self.root / name
        store = root / "store"
        store.mkdir(parents=True, mode=0o700)
        canonical = store / "auth" / "codex" / "auth.json"
        canonical.parent.mkdir(parents=True, mode=0o700)
        canonical.parent.parent.chmod(0o700)
        canonical.write_text("synthetic-registration", encoding="utf-8")
        canonical.chmod(0o600)
        acquire(root / "runtime", "guest", store=store)
        bundle = root / "bundle"
        bundle.mkdir(mode=0o700)
        seed = bundle / "seed.json"
        seed.write_text("synthetic-registration", encoding="utf-8")
        seed.chmod(0o600)
        return root, store, bundle, seed

    def test_process_disappearing_during_status_read_is_not_ambiguity(self) -> None:
        class VanishingProcess:
            name = "424242"

            def __init__(self) -> None:
                self.reads = 0

            def __truediv__(self, _name: str):
                return self

            def read_text(self) -> str:
                self.reads += 1
                if self.reads == 1:
                    return "424242 (synthetic) S 1 424242 " + "0 " * 18
                raise ProcessLookupError("synthetic vanished process")

        with mock.patch.object(Path, "iterdir", return_value=[VanishingProcess()]):
            self.assertEqual(auth_owner._process_table(), {})

    def test_unchanged_guest_is_noop_and_owner_can_release(self) -> None:
        self.quiesce()
        acknowledgment = publish_guest(
            self.bundle, self.original_baseline, self.store, self.owner_id)
        acknowledge_guest(self.bundle, self.store, acknowledgment)
        self.assertEqual(self.canonical.read_text(), "synthetic-old")
        release(self.owner_id, store=self.store)

    def test_changed_guest_is_published_with_private_recovery(self) -> None:
        self.guest_candidate.write_text("synthetic-refresh", encoding="utf-8")
        self.quiesce()
        acknowledgment = publish_guest(
            self.bundle, self.original_baseline, self.store, self.owner_id)
        acknowledge_guest(self.bundle, self.store, acknowledgment)
        self.assertEqual(self.canonical.read_text(), "synthetic-refresh")
        recovered = list((self.canonical.parent / "recovery").glob("*/auth.json"))
        self.assertEqual(len(recovered), 1)
        self.assertEqual(recovered[0].read_text(), "synthetic-old")
        self.assertEqual(stat.S_IMODE(recovered[0].parent.stat().st_mode), 0o700)
        self.assertTrue(self.guest_candidate.is_file())
        release(self.owner_id, store=self.store)

    def test_atomic_guest_auth_replacement_is_returned(self) -> None:
        replacement = self.bundle / ".auth-next"
        replacement.write_text("synthetic-atomic-refresh", encoding="utf-8")
        replacement.chmod(0o600)
        os.replace(replacement, self.guest_candidate)
        self.quiesce()
        acknowledgment = publish_guest(
            self.bundle, self.original_baseline, self.store, self.owner_id)
        acknowledge_guest(self.bundle, self.store, acknowledgment)
        self.assertEqual(self.canonical.read_text(), "synthetic-atomic-refresh")

    def test_ack_rejects_candidate_replaced_after_publication(self) -> None:
        self.guest_candidate.write_text("synthetic-refresh", encoding="utf-8")
        self.quiesce()
        acknowledgment = publish_guest(
            self.bundle, self.original_baseline, self.store, self.owner_id)
        replacement = self.bundle / ".auth-next"
        replacement.write_text("synthetic-refresh", encoding="utf-8")
        replacement.chmod(0o600)
        os.replace(replacement, self.guest_candidate)
        with self.assertRaisesRegex(AuthOwnerError, "publication changed"):
            acknowledge_guest(self.bundle, self.store, acknowledgment)
        with self.assertRaises(AuthOwnerError):
            release(self.owner_id, store=self.store)

    def test_ack_requires_token_delivered_by_publish_response(self) -> None:
        self.quiesce()
        publish_guest(self.bundle, self.original_baseline, self.store, self.owner_id)
        with self.assertRaisesRegex(AuthOwnerError, "acknowledgment is invalid"):
            acknowledge_guest(self.bundle, self.store, "0" * 64)
        with self.assertRaises(AuthOwnerError):
            release(self.owner_id, store=self.store)

    def test_ack_rejects_canonical_replaced_after_publication(self) -> None:
        self.guest_candidate.write_text("synthetic-refresh", encoding="utf-8")
        self.quiesce()
        acknowledgment = publish_guest(
            self.bundle, self.original_baseline, self.store, self.owner_id)
        replacement = self.canonical.parent / ".auth-next"
        replacement.write_text("synthetic-refresh", encoding="utf-8")
        replacement.chmod(0o600)
        os.replace(replacement, self.canonical)
        with self.assertRaisesRegex(AuthOwnerError, "publication changed"):
            acknowledge_guest(self.bundle, self.store, acknowledgment)
        with self.assertRaises(AuthOwnerError):
            release(self.owner_id, store=self.store)

    def test_publish_identity_cannot_bless_replacement_in_snapshot_gap(self) -> None:
        self.guest_candidate.write_text("synthetic-refresh", encoding="utf-8")
        self.quiesce()
        real_publish = auth_owner._publish_verified_refresh_locked

        def replace_after_commit(*arguments, **keywords):
            committed = real_publish(*arguments, **keywords)
            replacement = self.canonical.parent / ".foreign"
            replacement.write_text("synthetic-foreign", encoding="utf-8")
            replacement.chmod(0o600)
            os.replace(replacement, self.canonical)
            return committed

        with mock.patch.object(
                auth_owner, "_publish_verified_refresh_locked",
                side_effect=replace_after_commit):
            acknowledgment = publish_guest(
                self.bundle, self.original_baseline, self.store, self.owner_id)
        with self.assertRaisesRegex(AuthOwnerError, "publication changed"):
            acknowledge_guest(self.bundle, self.store, acknowledgment)
        self.assertEqual(self.canonical.read_text(encoding="utf-8"), "synthetic-foreign")
        self.assertEqual(self.guest_candidate.read_text(encoding="utf-8"), "synthetic-refresh")
        recovered = list((self.canonical.parent / "recovery").glob("*/auth.json"))
        self.assertEqual([path.read_text(encoding="utf-8") for path in recovered],
                         ["synthetic-old"])
        record = json.loads(
            (self.canonical.parent / ".owner.json").read_text(encoding="utf-8"))
        self.assertEqual(record["guest_bundle"]["state"], "published-pending")
        self.assertFalse(record["guest_reconciled"])
        with self.assertRaises(AuthOwnerError):
            release(self.owner_id, store=self.store)

    def test_fd_registration_rejects_public_image_parent(self) -> None:
        root, store, bundle, seed = self.registration_fixture("public-image-parent")
        public = root / "public"
        public.mkdir(mode=0o755)
        image = public / "state.ext4"
        image.write_bytes(b"synthetic-image")
        image.chmod(0o600)
        with ExitStack() as stack:
            owner = auth_owner._locked_owner(store, stack)
            record = auth_owner._read_owner(owner)
            image_fd = os.open(image, auth_owner._FILE_FLAGS)
            stack.callback(os.close, image_fd)
            with self.assertRaisesRegex(AuthOwnerError, "bundle must be private"):
                auth_owner.register_guarded_guest_bundle(
                    bundle, image, seed, owner, record, image_fd)

    def test_fd_registration_rejects_permissive_image_file(self) -> None:
        _root, store, bundle, seed = self.registration_fixture("permissive-image")
        image = bundle / "state.ext4"
        image.write_bytes(b"synthetic-image")
        image.chmod(0o644)
        with ExitStack() as stack:
            owner = auth_owner._locked_owner(store, stack)
            record = auth_owner._read_owner(owner)
            image_fd = os.open(image, auth_owner._FILE_FLAGS)
            stack.callback(os.close, image_fd)
            with self.assertRaisesRegex(AuthOwnerError, "state image is unsafe"):
                auth_owner.register_guarded_guest_bundle(
                    bundle, image, seed, owner, record, image_fd)

    def test_world_readable_guest_candidate_is_rejected(self) -> None:
        self.guest_candidate.chmod(0o644)
        self.quiesce()
        with self.assertRaises(AuthOwnerError):
            publish_guest(self.bundle, self.original_baseline, self.store, self.owner_id)
        self.assertEqual(self.canonical.read_text(), "synthetic-old")

    def test_state_image_swap_blocks_guest_return(self) -> None:
        self.quiesce()
        replacement = self.bundle / "state-other.ext4"
        replacement.write_bytes(b"synthetic-other-image")
        os.replace(replacement, self.image)
        with self.assertRaisesRegex(AuthOwnerError, "guest ownership or quiescence"):
            publish_guest(self.bundle, self.original_baseline, self.store, self.owner_id)
        self.assertTrue(self.guest_candidate.is_file())

    def test_changed_canonical_baseline_preserves_guest_candidate(self) -> None:
        self.guest_candidate.write_text("synthetic-refresh", encoding="utf-8")
        self.quiesce()
        self.canonical.write_text("synthetic-other-writer", encoding="utf-8")
        with self.assertRaises(AuthOwnerError) as refusal:
            publish_guest(self.bundle, self.original_baseline, self.store, self.owner_id)
        self.assertTrue(self.guest_candidate.is_file())
        self.assertEqual(self.canonical.read_text(encoding="utf-8"), "synthetic-other-writer")
        self.assertNotIn("synthetic-refresh", str(refusal.exception))
        with self.assertRaises(AuthOwnerError):
            release(self.owner_id, store=self.store)

    def test_missing_guest_is_not_logout(self) -> None:
        self.quiesce()
        self.guest_candidate.unlink()
        with self.assertRaisesRegex(AuthOwnerError, "guest credential missing"):
            publish_guest(self.bundle, self.original_baseline, self.store, self.owner_id)
        self.assertEqual(self.canonical.read_text(), "synthetic-old")

    def test_symlink_guest_is_rejected_without_following(self) -> None:
        self.quiesce()
        self.guest_candidate.unlink()
        self.guest_candidate.symlink_to(self.canonical)
        with self.assertRaises(AuthOwnerError):
            publish_guest(self.bundle, self.original_baseline, self.store, self.owner_id)
        self.assertEqual(self.canonical.read_text(), "synthetic-old")

    def test_wrong_bundle_identity_is_rejected(self) -> None:
        self.quiesce()
        substituted = self.root / "other-bundle"
        substituted.mkdir(mode=0o700)
        (substituted / "auth.json").write_text("synthetic-foreign")
        self.assertFalse(bundle_identity_matches(substituted, self.owner_id, store=self.store))
        with self.assertRaisesRegex(AuthOwnerError, "guest ownership or quiescence"):
            publish_guest(substituted, self.original_baseline, self.store, self.owner_id)

    def test_live_firecracker_blocks_return(self) -> None:
        process = subprocess.Popen(["sleep", "60"], start_new_session=True)
        self.addCleanup(lambda: process.poll() is None and (process.terminate(), process.wait()))
        bind_guest_vm(self.owner_id, process.pid, "/usr/bin/sleep", store=self.store)
        with self.assertRaises(AuthOwnerError):
            mark_guest_quiescent(self.owner_id, store=self.store)
        with self.assertRaisesRegex(AuthOwnerError, "guest ownership or quiescence"):
            publish_guest(self.bundle, self.original_baseline, self.store, self.owner_id)

    def test_vm_without_isolated_process_group_is_refused(self) -> None:
        process = subprocess.Popen(["sleep", "60"])
        self.addCleanup(lambda: process.poll() is None and (process.terminate(), process.wait()))
        with self.assertRaises(AuthOwnerError):
            bind_guest_vm(self.owner_id, process.pid, "/usr/bin/sleep", store=self.store)

    def test_failed_publication_keeps_candidate_and_blocks_reuse(self) -> None:
        self.guest_candidate.write_text("synthetic-refresh", encoding="utf-8")
        self.quiesce()
        real_fsync = auth_owner.os.fsync
        interrupted = False

        def fail_after_replace(fd: int) -> None:
            nonlocal interrupted
            if not interrupted and self.canonical.read_text() == "synthetic-refresh":
                interrupted = True
                raise OSError("synthetic interruption")
            real_fsync(fd)

        with mock.patch.object(auth_owner.os, "fsync", side_effect=fail_after_replace):
            with self.assertRaises(AuthOwnerError):
                publish_guest(self.bundle, self.original_baseline, self.store, self.owner_id)
        self.assertTrue(interrupted)
        self.assertEqual(self.canonical.read_text(), "synthetic-old")
        self.assertEqual(self.guest_candidate.read_text(), "synthetic-refresh")
        with self.assertRaises(AuthOwnerError):
            release(self.owner_id, store=self.store)

    def test_crash_before_return_retains_bundle_and_blocks_new_writer(self) -> None:
        self.guest_candidate.write_text("synthetic-refresh", encoding="utf-8")
        with self.assertRaises(AuthOwnerError):
            release(self.owner_id, store=self.store)
        with self.assertRaises(AuthOwnerError):
            acquire(self.root / "other", "foreground", store=self.store)
        self.assertEqual(self.guest_candidate.read_text(), "synthetic-refresh")

    def test_prelaunch_abort_releases_registered_owner_without_vm(self) -> None:
        abort_guest_prelaunch(self.store)
        self.assertTrue(self.guest_candidate.is_file())
        next_id = acquire(self.root / "next-runtime", "foreground", store=self.store)
        release(next_id, store=self.store)

    def test_prelaunch_abort_refuses_started_vm(self) -> None:
        process = subprocess.Popen(["sleep", "60"], start_new_session=True)
        self.addCleanup(lambda: process.poll() is None and (process.terminate(), process.wait()))
        bind_guest_vm(self.owner_id, process.pid, "/usr/bin/sleep", store=self.store)
        with self.assertRaises(AuthOwnerError):
            abort_guest_prelaunch(self.store)
        with self.assertRaises(AuthOwnerError):
            acquire(self.root / "next-runtime", "foreground", store=self.store)

    def test_start_marker_blocks_abort_before_vm_binding(self) -> None:
        mark_guest_starting(self.store)
        with self.assertRaises(AuthOwnerError):
            abort_guest_prelaunch(self.store)
        self.assertTrue(self.guest_candidate.is_file())

    def test_candidate_file_sync_failure_preserves_temporary_bytes(self) -> None:
        self.guest_candidate.unlink()
        temporary = self.bundle / ".auth-return-test"
        temporary.write_text("synthetic-fresh", encoding="utf-8")
        temporary.chmod(0o600)
        real_fsync = auth_owner.os.fsync

        def fail_file_sync(fd: int) -> None:
            if stat.S_ISREG(os.fstat(fd).st_mode):
                raise OSError("synthetic file sync failure")
            real_fsync(fd)

        with mock.patch.object(auth_owner.os, "fsync", side_effect=fail_file_sync):
            with self.assertRaises(AuthOwnerError):
                auth_owner.commit_guest_candidate(temporary, self.bundle)
        self.assertEqual(temporary.read_text(), "synthetic-fresh")
        self.assertFalse(self.guest_candidate.exists())

    def test_candidate_directory_sync_failure_retains_both_names(self) -> None:
        self.guest_candidate.unlink()
        temporary = self.bundle / ".auth-return-test"
        temporary.write_text("synthetic-fresh", encoding="utf-8")
        temporary.chmod(0o600)
        real_fsync = auth_owner.os.fsync

        def fail_directory_sync(fd: int) -> None:
            if stat.S_ISDIR(os.fstat(fd).st_mode):
                raise OSError("synthetic directory sync failure")
            real_fsync(fd)

        with mock.patch.object(auth_owner.os, "fsync", side_effect=fail_directory_sync):
            with self.assertRaises(AuthOwnerError):
                auth_owner.commit_guest_candidate(temporary, self.bundle)
        self.assertEqual(temporary.read_text(), "synthetic-fresh")
        self.assertEqual(self.guest_candidate.read_text(), "synthetic-fresh")

    def test_owner_id_guest_publish_cli_is_not_a_capability(self) -> None:
        self.guest_candidate.write_text("synthetic-cli-secret", encoding="utf-8")
        self.quiesce()
        environment = dict(os.environ, PYTHONPATH=os.path.join(os.path.dirname(__file__), "..", "lib", "python"))
        result = subprocess.run(
            [sys.executable, "-m", "ihar.codex.auth_owner", "guest-publish",
             str(self.store), "legacy-owner-id", str(self.bundle)],
            capture_output=True, text=True, env=environment, check=False,
        )
        self.assertEqual(result.returncode, 3)
        self.assertNotIn("synthetic-cli-secret", result.stdout + result.stderr)
        self.assertEqual(self.canonical.read_text(), "synthetic-old")

    def test_cli_guest_refusal_never_prints_candidate_bytes(self) -> None:
        self.guest_candidate.write_text("synthetic-cli-secret", encoding="utf-8")
        self.quiesce()
        self.canonical.write_text("synthetic-other-writer", encoding="utf-8")
        environment = dict(os.environ, PYTHONPATH=os.path.join(os.path.dirname(__file__), "..", "lib", "python"))
        result = subprocess.run(
            [sys.executable, "-m", "ihar.codex.auth_owner", "guest-publish",
             str(self.store), "legacy-owner-id", str(self.bundle)],
            capture_output=True, text=True, env=environment, check=False,
        )
        self.assertEqual(result.returncode, 3)
        self.assertNotIn("synthetic-cli-secret", result.stdout + result.stderr)
        self.assertEqual(self.canonical.read_text(), "synthetic-other-writer")

    def test_original_guardian_channel_reconciles_guest_without_second_lease(self) -> None:
        channel_root = self.root / "channel"
        channel_store = channel_root / "store"
        channel_store.mkdir(parents=True, mode=0o700)
        canonical = channel_store / "auth" / "codex" / "auth.json"
        canonical.parent.mkdir(parents=True, mode=0o700)
        canonical.parent.parent.chmod(0o700)
        canonical.write_text("synthetic-channel-old", encoding="utf-8")
        canonical.chmod(0o600)
        bundle = channel_root / "bundle"
        bundle.mkdir(mode=0o700)
        image = bundle / "state.ext4"
        image.write_bytes(b"synthetic-channel-image")
        image.chmod(0o600)
        seed = bundle / "seed.json"
        seed.write_text("synthetic-channel-old", encoding="utf-8")
        seed.chmod(0o600)
        candidate = bundle / "auth.json"
        candidate.write_text("synthetic-channel-refresh", encoding="utf-8")
        candidate.chmod(0o600)
        sleep = shutil.which("sleep")
        self.assertIsNotNone(sleep)
        script = f"""import os, subprocess
from ihar.codex import guardian
fd = int(os.environ['IHAR_GUARD_FD'])
guardian.request(fd, 'guest-register-bundle', {{
    'bundle': {str(bundle)!r},
    'image': {str(image)!r},
    'seed': {str(seed)!r},
}})
guardian.request(fd, 'guest-starting', {{}})
process = subprocess.Popen([{sleep!r}, '60'], start_new_session=True)
guardian.request(fd, 'guest-bind-vm', {{'pid': process.pid, 'binary': {sleep!r}}})
process.terminate()
process.wait()
guardian.request(fd, 'guest-quiescent', {{}})
published = guardian.request(fd, 'guest-publish', {{'bundle': {str(bundle)!r}}})
guardian.request(fd, 'guest-ack', {{'bundle': {str(bundle)!r}, 'ack': published['ack']}})
"""
        environment = dict(
            os.environ,
            PYTHONPATH=os.path.join(os.path.dirname(__file__), "..", "lib", "python"),
        )
        result = subprocess.run(
            [sys.executable, "-m", "ihar.codex.guardian", str(channel_store), "--",
             sys.executable, "-c", script],
            capture_output=True, text=True, env=environment, timeout=10, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(canonical.read_text(encoding="utf-8"), "synthetic-channel-refresh")
        self.assertFalse((canonical.parent / ".owner.json").exists())

    def test_lost_publish_response_retains_owner_and_blocks_contender(self) -> None:
        channel_root = self.root / "lost-response"
        channel_store = channel_root / "store"
        channel_store.mkdir(parents=True, mode=0o700)
        canonical = channel_store / "auth" / "codex" / "auth.json"
        canonical.parent.mkdir(parents=True, mode=0o700)
        canonical.parent.parent.chmod(0o700)
        canonical.write_text("synthetic-lost-old", encoding="utf-8")
        canonical.chmod(0o600)
        bundle = channel_root / "bundle"
        bundle.mkdir(mode=0o700)
        image = bundle / "state.ext4"
        image.write_bytes(b"synthetic-lost-image")
        image.chmod(0o600)
        seed = bundle / "seed.json"
        seed.write_text("synthetic-lost-old", encoding="utf-8")
        seed.chmod(0o600)
        candidate = bundle / "auth.json"
        candidate.write_text("synthetic-lost-refresh", encoding="utf-8")
        candidate.chmod(0o600)
        sleep = shutil.which("sleep")
        self.assertIsNotNone(sleep)
        script = f"""import array, json, os, socket, subprocess, time
from pathlib import Path
from ihar.codex import guardian
fd = int(os.environ['IHAR_GUARD_FD'])
guardian.request(fd, 'guest-register-bundle', {{'bundle': {str(bundle)!r}, 'image': {str(image)!r}, 'seed': {str(seed)!r}}})
guardian.request(fd, 'guest-starting', {{}})
process = subprocess.Popen([{sleep!r}, '60'], start_new_session=True)
guardian.request(fd, 'guest-bind-vm', {{'pid': process.pid, 'binary': {sleep!r}}})
process.terminate(); process.wait()
guardian.request(fd, 'guest-quiescent', {{}})
channel = socket.socket(fileno=os.dup(fd))
reply, receiver = socket.socketpair(socket.AF_UNIX, socket.SOCK_SEQPACKET)
reply.close()
message = json.dumps({{'operation': 'guest-publish', 'fields': {{'bundle': {str(bundle)!r}}}}}, separators=(',', ':')).encode('ascii')
rights = array.array('i', [receiver.fileno()])
channel.sendmsg([message], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, rights)])
receiver.close(); channel.close()
owner = Path({str(canonical.parent / '.owner.json')!r})
for _ in range(100):
    record = json.loads(owner.read_text(encoding='utf-8'))
    if record['guest_bundle']['state'] == 'published-pending': break
    time.sleep(.01)
else: raise SystemExit(4)
"""
        environment = dict(os.environ, PYTHONPATH=os.path.join(os.path.dirname(__file__), "..", "lib", "python"))
        result = subprocess.run(
            [sys.executable, "-m", "ihar.codex.guardian", str(channel_store), "--", sys.executable, "-c", script],
            capture_output=True, text=True, env=environment, timeout=10, check=False,
        )
        self.assertEqual(result.returncode, 3)
        self.assertNotIn("synthetic-lost-refresh", result.stdout + result.stderr)
        record = json.loads((canonical.parent / ".owner.json").read_text(encoding="utf-8"))
        self.assertEqual(record["guest_bundle"]["state"], "published-pending")
        self.assertFalse(record["guest_reconciled"])
        self.assertTrue(candidate.is_file())
        contender = subprocess.run(
            [sys.executable, "-m", "ihar.codex.guardian", str(channel_store), "--", sys.executable, "-c", "raise SystemExit(0)"],
            capture_output=True, text=True, env=environment, timeout=5, check=False,
        )
        self.assertEqual(contender.returncode, 3)

    def test_guardian_extract_uses_registered_image_fd_across_path_swap(self) -> None:
        if not shutil.which("debugfs") or not shutil.which("mkfs.ext4"):
            self.skipTest("ext4 tools unavailable")
        channel_root = self.root / "image-fd"
        channel_store = channel_root / "store"
        channel_store.mkdir(parents=True, mode=0o700)
        canonical = channel_store / "auth" / "codex" / "auth.json"
        canonical.parent.mkdir(parents=True, mode=0o700)
        canonical.parent.parent.chmod(0o700)
        canonical.write_text("synthetic-fd-old", encoding="utf-8")
        canonical.chmod(0o600)
        bundle = channel_root / "bundle"
        bundle.mkdir(mode=0o700)
        seed = bundle / "seed.json"
        seed.write_text("synthetic-fd-old", encoding="utf-8")
        seed.chmod(0o600)
        def make_image(path: Path, value: str) -> None:
            source = channel_root / (path.stem + "-root") / ".ihar-guest-codex-home"
            source.mkdir(parents=True)
            (source / "auth.json").write_text(value, encoding="utf-8")
            subprocess.run(["truncate", "-s", "16M", path], check=True)
            subprocess.run(["mkfs.ext4", "-q", "-d", source.parent, path], check=True)
            path.chmod(0o600)
        image = bundle / "state.ext4"
        substitute = bundle / "substitute.ext4"
        make_image(image, "synthetic-registered-refresh")
        make_image(substitute, "synthetic-substitute-secret")
        sleep = shutil.which("sleep")
        self.assertIsNotNone(sleep)
        parked = bundle / "registered.ext4"
        script = f"""import os, subprocess
from ihar.codex import guardian
fd = int(os.environ['IHAR_GUARD_FD'])
guardian.request(fd, 'guest-register-bundle', {{'bundle': {str(bundle)!r}, 'image': {str(image)!r}, 'seed': {str(seed)!r}}})
guardian.request(fd, 'guest-starting', {{}})
process = subprocess.Popen([{sleep!r}, '60'], start_new_session=True)
guardian.request(fd, 'guest-bind-vm', {{'pid': process.pid, 'binary': {sleep!r}}})
process.terminate(); process.wait()
guardian.request(fd, 'guest-quiescent', {{}})
os.rename({str(image)!r}, {str(parked)!r}); os.rename({str(substitute)!r}, {str(image)!r})
guardian.request(fd, 'guest-extract', {{'bundle': {str(bundle)!r}}})
os.rename({str(image)!r}, {str(substitute)!r}); os.rename({str(parked)!r}, {str(image)!r})
published = guardian.request(fd, 'guest-publish', {{'bundle': {str(bundle)!r}}})
guardian.request(fd, 'guest-ack', {{'bundle': {str(bundle)!r}, 'ack': published['ack']}})
"""
        environment = dict(os.environ, PYTHONPATH=os.path.join(os.path.dirname(__file__), "..", "lib", "python"))
        result = subprocess.run(
            [sys.executable, "-m", "ihar.codex.guardian", str(channel_store), "--", sys.executable, "-c", script],
            capture_output=True, text=True, env=environment, timeout=15, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(canonical.read_text(encoding="utf-8"), "synthetic-registered-refresh")
        self.assertNotIn("synthetic-substitute-secret", result.stdout + result.stderr)

    def test_guest_acquire_cli_is_not_an_owner_id_capability(self) -> None:
        legacy = self.root / "legacy"
        store = legacy / "store"
        canonical = store / "auth" / "codex" / "auth.json"
        canonical.parent.mkdir(parents=True, mode=0o700)
        canonical.parent.parent.chmod(0o700)
        canonical.write_text("synthetic-legacy", encoding="utf-8")
        canonical.chmod(0o600)
        runtime = legacy / "runtime"
        runtime.mkdir()
        (runtime / "auth.json").symlink_to(canonical)
        handoff = legacy / "owner-id"
        environment = dict(
            os.environ,
            PYTHONPATH=os.path.join(os.path.dirname(__file__), "..", "lib", "python"),
        )
        result = subprocess.run(
            [sys.executable, "-m", "ihar.codex.auth_owner", "guest-acquire",
             str(store), str(runtime), str(handoff)],
            capture_output=True, text=True, env=environment, check=False,
        )
        self.assertEqual(result.returncode, 3)
        self.assertFalse(handoff.exists())
        self.assertFalse((canonical.parent / ".owner.json").exists())

    def test_guardian_baseline_drift_retains_candidate_and_blocks_next_writer(self) -> None:
        channel_root = self.root / "drift-channel"
        channel_store = channel_root / "store"
        channel_store.mkdir(parents=True, mode=0o700)
        canonical = channel_store / "auth" / "codex" / "auth.json"
        canonical.parent.mkdir(parents=True, mode=0o700)
        canonical.parent.parent.chmod(0o700)
        canonical.write_text("synthetic-drift-old", encoding="utf-8")
        canonical.chmod(0o600)
        bundle = channel_root / "bundle"
        bundle.mkdir(mode=0o700)
        image = bundle / "state.ext4"
        image.write_bytes(b"synthetic-drift-image")
        image.chmod(0o600)
        seed = bundle / "seed.json"
        seed.write_text("synthetic-drift-old", encoding="utf-8")
        seed.chmod(0o600)
        candidate = bundle / "auth.json"
        candidate.write_text("synthetic-drift-secret", encoding="utf-8")
        candidate.chmod(0o600)
        sleep = shutil.which("sleep")
        self.assertIsNotNone(sleep)
        script = f"""import os, subprocess
from pathlib import Path
from ihar.codex import guardian
fd = int(os.environ['IHAR_GUARD_FD'])
guardian.request(fd, 'guest-register-bundle', {{
    'bundle': {str(bundle)!r},
    'image': {str(image)!r},
    'seed': {str(seed)!r},
}})
guardian.request(fd, 'guest-starting', {{}})
process = subprocess.Popen([{sleep!r}, '60'], start_new_session=True)
guardian.request(fd, 'guest-bind-vm', {{'pid': process.pid, 'binary': {sleep!r}}})
process.terminate()
process.wait()
guardian.request(fd, 'guest-quiescent', {{}})
Path({str(canonical)!r}).write_text('synthetic-other-writer', encoding='utf-8')
guardian.request(fd, 'guest-publish', {{'bundle': {str(bundle)!r}}})
"""
        environment = dict(
            os.environ,
            PYTHONPATH=os.path.join(os.path.dirname(__file__), "..", "lib", "python"),
        )
        result = subprocess.run(
            [sys.executable, "-m", "ihar.codex.guardian", str(channel_store), "--",
             sys.executable, "-c", script],
            capture_output=True, text=True, env=environment, timeout=10, check=False,
        )
        self.assertEqual(result.returncode, 3)
        self.assertNotIn("synthetic-drift-secret", result.stdout + result.stderr)
        self.assertEqual(candidate.read_text(encoding="utf-8"), "synthetic-drift-secret")
        self.assertEqual(canonical.read_text(encoding="utf-8"), "synthetic-other-writer")
        record = json.loads((canonical.parent / ".owner.json").read_text(encoding="utf-8"))
        self.assertEqual(record["state"], "blocked")
        contender = subprocess.run(
            [sys.executable, "-m", "ihar.codex.guardian", str(channel_store), "--",
             sys.executable, "-c", "raise SystemExit(0)"],
            capture_output=True, text=True, env=environment, timeout=5, check=False,
        )
        self.assertEqual(contender.returncode, 3)


if __name__ == "__main__":
    unittest.main()
