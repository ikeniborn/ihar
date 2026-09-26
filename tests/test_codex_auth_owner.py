#!/usr/bin/env python3
"""Synthetic credential tests for the protected Codex authentication owner."""

from __future__ import annotations

import os
import stat
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib", "python"))

from ihar.codex.auth_owner import ApprovalRequired, AuthOwnerError, publish, stage


class AuthOwnerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.store = self.root / "store"
        self.store.mkdir(mode=0o700)

    @property
    def canonical(self) -> Path:
        return self.store / "auth" / "codex" / "auth.json"

    def test_first_login_publishes_real_private_file(self) -> None:
        staged = stage(self.store)
        self.assertEqual(stat.S_IMODE(staged.stat().st_mode), 0o700)
        self.assertFalse(staged.is_symlink())
        (staged / "auth.json").write_text("synthetic-new", encoding="utf-8")

        publish(staged, self.store, approve_existing=False)

        self.assertEqual(self.canonical.read_text(encoding="utf-8"), "synthetic-new")
        self.assertEqual(stat.S_IMODE(self.canonical.stat().st_mode), 0o600)
        with self.assertRaises(AuthOwnerError):
            publish(staged, self.store, approve_existing=True)
        next_stage = stage(self.store)
        self.assertTrue(next_stage.is_dir())

    def test_store_may_be_readable_while_auth_owner_stays_private(self) -> None:
        self.store.chmod(0o755)

        staged = stage(self.store)

        self.assertEqual(stat.S_IMODE((self.store / "auth").stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(staged.stat().st_mode), 0o700)

    def test_failed_login_without_regular_candidate_preserves_absence(self) -> None:
        staged = stage(self.store)
        with self.assertRaises(AuthOwnerError):
            publish(staged, self.store, approve_existing=False)
        self.assertFalse(self.canonical.exists())

        (staged / "auth.json").symlink_to(self.root / "other")
        with self.assertRaises(AuthOwnerError):
            publish(staged, self.store, approve_existing=False)
        self.assertFalse(self.canonical.exists())

    def test_existing_canonical_needs_approval_and_keeps_recovery(self) -> None:
        stage(self.store)
        self.canonical.write_text("synthetic-old", encoding="utf-8")
        staged = stage(self.store)
        (staged / "auth.json").write_text("synthetic-new", encoding="utf-8")

        with self.assertRaises(ApprovalRequired):
            publish(staged, self.store, approve_existing=False)
        self.assertEqual(self.canonical.read_text(encoding="utf-8"), "synthetic-old")
        with self.assertRaises(ApprovalRequired):
            publish(staged, self.store, approve_existing="--assume-yes")  # type: ignore[arg-type]
        self.assertEqual(self.canonical.read_text(encoding="utf-8"), "synthetic-old")

        publish(staged, self.store, approve_existing=True)
        self.assertEqual(self.canonical.read_text(encoding="utf-8"), "synthetic-new")
        recovered = list((self.canonical.parent / "recovery").glob("*/auth.json"))
        self.assertEqual(len(recovered), 1)
        self.assertEqual(recovered[0].read_text(encoding="utf-8"), "synthetic-old")
        self.assertTrue(stage(self.store).is_dir())

    def test_symlinked_owner_ancestor_is_rejected_without_following(self) -> None:
        target = self.root / "target"
        target.mkdir()
        (self.store / "auth").symlink_to(target, target_is_directory=True)
        with self.assertRaises(AuthOwnerError):
            stage(self.store)
        self.assertEqual(list(target.iterdir()), [])

    def test_canonical_mutation_after_stage_is_not_overwritten(self) -> None:
        stage(self.store)
        self.canonical.write_text("synthetic-old", encoding="utf-8")
        staged = stage(self.store)
        (staged / "auth.json").write_text("synthetic-new", encoding="utf-8")
        self.canonical.write_text("synthetic-third", encoding="utf-8")

        with self.assertRaises(AuthOwnerError):
            publish(staged, self.store, approve_existing=True)
        self.assertEqual(self.canonical.read_text(encoding="utf-8"), "synthetic-third")
        self.assertEqual((staged / "auth.json").read_text(encoding="utf-8"), "synthetic-new")

    def test_publication_fsync_failure_restores_old_and_retains_recovery(self) -> None:
        from ihar.codex import auth_owner

        stage(self.store)
        self.canonical.write_text("synthetic-old", encoding="utf-8")
        staged = stage(self.store)
        (staged / "auth.json").write_text("synthetic-new", encoding="utf-8")
        real_fsync = auth_owner.os.fsync
        interrupted = False

        def interrupt_after_replace(fd: int) -> None:
            nonlocal interrupted
            if not interrupted and self.canonical.read_text(encoding="utf-8") == "synthetic-new":
                interrupted = True
                raise OSError("synthetic publication interruption")
            real_fsync(fd)

        with mock.patch.object(auth_owner.os, "fsync", side_effect=interrupt_after_replace):
            with self.assertRaises(AuthOwnerError):
                publish(staged, self.store, approve_existing=True)

        self.assertTrue(interrupted)
        self.assertEqual(self.canonical.read_text(encoding="utf-8"), "synthetic-old")
        self.assertEqual(self.canonical.stat().st_nlink, 1)
        self.assertEqual((staged / "auth.json").read_text(encoding="utf-8"), "synthetic-new")
        recovered = list((self.canonical.parent / "recovery").glob("*/auth.json"))
        self.assertEqual(len(recovered), 1)
        self.assertEqual(recovered[0].read_text(encoding="utf-8"), "synthetic-old")
        self.assertNotEqual(self.canonical.stat().st_ino, recovered[0].stat().st_ino)
        with self.assertRaises(AuthOwnerError):
            stage(self.store)

    def test_cleanup_sync_failure_keeps_reuse_blocked(self) -> None:
        from ihar.codex import auth_owner

        staged = stage(self.store)
        (staged / "auth.json").write_text("synthetic-new", encoding="utf-8")
        real_fsync = auth_owner.os.fsync
        interrupted = False

        def interrupt_cleanup_sync(fd: int) -> None:
            nonlocal interrupted
            pending = self.canonical.parent / ".auth-publish-pending"
            if not interrupted and self.canonical.exists() and not pending.exists():
                interrupted = True
                raise OSError("synthetic cleanup sync failure")
            real_fsync(fd)

        with mock.patch.object(auth_owner.os, "fsync", side_effect=interrupt_cleanup_sync):
            with self.assertRaises(AuthOwnerError):
                publish(staged, self.store, approve_existing=False)

        self.assertTrue(interrupted)
        self.assertEqual(self.canonical.read_text(encoding="utf-8"), "synthetic-new")
        with self.assertRaises(AuthOwnerError):
            stage(self.store)

    def test_first_publication_interruption_keeps_canonical_absent(self) -> None:
        from ihar.codex import auth_owner

        staged = stage(self.store)
        (staged / "auth.json").write_text("synthetic-new", encoding="utf-8")
        real_unlink = auth_owner.os.unlink
        interrupted = False

        def interrupt_cleanup(path: str, *, dir_fd: int | None = None) -> None:
            nonlocal interrupted
            if path.startswith(".auth-publish-") and self.canonical.exists():
                interrupted = True
                raise OSError("synthetic publication interruption")
            real_unlink(path, dir_fd=dir_fd)

        with mock.patch.object(auth_owner.os, "unlink", side_effect=interrupt_cleanup):
            with self.assertRaises(AuthOwnerError):
                publish(staged, self.store, approve_existing=False)

        self.assertTrue(interrupted)
        self.assertFalse(self.canonical.exists())
        self.assertEqual((staged / "auth.json").read_text(encoding="utf-8"), "synthetic-new")
        with self.assertRaises(AuthOwnerError):
            stage(self.store)

    def test_candidate_hardlink_to_external_file_is_rejected(self) -> None:
        external = self.root / "external"
        external.write_text("synthetic-external", encoding="utf-8")
        staged = stage(self.store)
        os.link(external, staged / "auth.json")

        with self.assertRaises(AuthOwnerError):
            publish(staged, self.store, approve_existing=False)
        self.assertFalse(self.canonical.exists())

    def test_unsyncable_staged_file_is_never_published(self) -> None:
        from ihar.codex import auth_owner

        staged = stage(self.store)
        candidate = staged / "auth.json"
        candidate.write_text("synthetic-new", encoding="utf-8")
        candidate_inode = candidate.stat().st_ino
        real_fsync = auth_owner.os.fsync

        def refuse_candidate_sync(fd: int) -> None:
            if os.fstat(fd).st_ino == candidate_inode:
                raise OSError("synthetic staged-file sync failure")
            real_fsync(fd)

        with mock.patch.object(auth_owner.os, "fsync", side_effect=refuse_candidate_sync):
            with self.assertRaises(AuthOwnerError):
                publish(staged, self.store, approve_existing=False)

        self.assertFalse(self.canonical.exists())

    def test_vendor_recreates_staged_auth_without_touching_runtime_link(self) -> None:
        stage(self.store)
        self.canonical.write_text("synthetic-old", encoding="utf-8")
        runtime = self.root / "runtime"
        runtime.mkdir()
        runtime_auth = runtime / "auth.json"
        runtime_auth.symlink_to(self.canonical)
        staged = stage(self.store)
        candidate = staged / "auth.json"
        candidate.write_text("synthetic-transient", encoding="utf-8")
        candidate.unlink()
        candidate.write_text("synthetic-new", encoding="utf-8")

        publish(staged, self.store, approve_existing=True)

        self.assertTrue(runtime_auth.is_symlink())
        self.assertEqual(os.readlink(runtime_auth), str(self.canonical))
        self.assertEqual(runtime_auth.read_text(encoding="utf-8"), "synthetic-new")


if __name__ == "__main__":
    unittest.main()
