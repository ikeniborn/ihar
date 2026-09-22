#!/usr/bin/env python3
"""Synthetic, owner-held guest credential handoff tests."""

from __future__ import annotations

import os
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
from ihar.codex.auth_owner import (
    AuthOwnerError, acquire, bind_guest_vm, bundle_identity_matches,
    mark_guest_quiescent, publish_guest, register_guest_bundle, release,
)


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

    def test_unchanged_guest_is_noop_and_owner_can_release(self) -> None:
        self.quiesce()
        publish_guest(self.bundle, self.original_baseline, self.store, self.owner_id)
        self.assertEqual(self.canonical.read_text(), "synthetic-old")
        release(self.owner_id, store=self.store)

    def test_changed_guest_is_published_with_private_recovery(self) -> None:
        self.guest_candidate.write_text("synthetic-refresh", encoding="utf-8")
        self.quiesce()
        publish_guest(self.bundle, self.original_baseline, self.store, self.owner_id)
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
        publish_guest(self.bundle, self.original_baseline, self.store, self.owner_id)
        self.assertEqual(self.canonical.read_text(), "synthetic-atomic-refresh")

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
        auth_owner.abort_guest_prelaunch(self.owner_id, store=self.store)
        self.assertTrue(self.guest_candidate.is_file())
        next_id = acquire(self.root / "next-runtime", "foreground", store=self.store)
        release(next_id, store=self.store)

    def test_prelaunch_abort_refuses_started_vm(self) -> None:
        process = subprocess.Popen(["sleep", "60"], start_new_session=True)
        self.addCleanup(lambda: process.poll() is None and (process.terminate(), process.wait()))
        bind_guest_vm(self.owner_id, process.pid, "/usr/bin/sleep", store=self.store)
        with self.assertRaises(AuthOwnerError):
            auth_owner.abort_guest_prelaunch(self.owner_id, store=self.store)
        with self.assertRaises(AuthOwnerError):
            acquire(self.root / "next-runtime", "foreground", store=self.store)

    def test_start_marker_blocks_abort_before_vm_binding(self) -> None:
        auth_owner.mark_guest_starting(self.owner_id, store=self.store)
        with self.assertRaises(AuthOwnerError):
            auth_owner.abort_guest_prelaunch(self.owner_id, store=self.store)
        self.assertTrue(self.guest_candidate.is_file())

    def test_unregistered_prelaunch_abort_releases_owner(self) -> None:
        other = self.root / "other-store"
        (other / "auth" / "codex").mkdir(parents=True, mode=0o700)
        (other / "auth").chmod(0o700)
        (other / "auth" / "codex" / "auth.json").write_text("synthetic-other", encoding="utf-8")
        owner_id = acquire(self.root / "other-runtime", "guest", store=other)
        auth_owner.abort_guest_prelaunch(owner_id, store=other)
        next_id = acquire(self.root / "next-runtime", "foreground", store=other)
        release(next_id, store=other)

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

    def test_cli_guest_publication_never_prints_candidate_bytes(self) -> None:
        self.guest_candidate.write_text("synthetic-cli-secret", encoding="utf-8")
        self.quiesce()
        environment = dict(os.environ, PYTHONPATH=os.path.join(os.path.dirname(__file__), "..", "lib", "python"))
        result = subprocess.run(
            [sys.executable, "-m", "ihar.codex.auth_owner", "guest-publish",
             str(self.store), self.owner_id, str(self.bundle)],
            capture_output=True, text=True, env=environment, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("synthetic-cli-secret", result.stdout + result.stderr)
        self.assertEqual(self.canonical.read_text(), "synthetic-cli-secret")

    def test_cli_guest_refusal_never_prints_candidate_bytes(self) -> None:
        self.guest_candidate.write_text("synthetic-cli-secret", encoding="utf-8")
        self.quiesce()
        self.canonical.write_text("synthetic-other-writer", encoding="utf-8")
        environment = dict(os.environ, PYTHONPATH=os.path.join(os.path.dirname(__file__), "..", "lib", "python"))
        result = subprocess.run(
            [sys.executable, "-m", "ihar.codex.auth_owner", "guest-publish",
             str(self.store), self.owner_id, str(self.bundle)],
            capture_output=True, text=True, env=environment, check=False,
        )
        self.assertEqual(result.returncode, 3)
        self.assertNotIn("synthetic-cli-secret", result.stdout + result.stderr)
        self.assertEqual(self.canonical.read_text(), "synthetic-other-writer")


if __name__ == "__main__":
    unittest.main()
